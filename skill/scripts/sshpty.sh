#!/bin/bash
# sshpty.sh — 常驻 SSH 会话（GoAnywhere 跳板 + 短期 token）
#
# 配置来源（脚本自身不含任何凭据）：
#   $HOME/.jump-ssh/config   → 跳板/目标机/密码（KEY=VALUE，可 source）
#   $HOME/.jump-ssh/token    → 一次性 token（如 jt_xxx:yyy）
# 换 token 只需覆写 token 文件并重启本脚本，不用改脚本。
#
# 启动: nohup bash sshpty.sh > /tmp/sshpty.log 2>&1 &
# 验证: bash sshsend.sh "hostname"
WS="${SSH_WS:-/tmp}"   # 工作区（FIFO/LOG/状态/PID），默认 /tmp；多实例/测试可 SSH_WS=/tmp/x 隔离
CONFIG="$HOME/.jump-ssh/config"
TOKEN_FILE="$HOME/.jump-ssh/token"
PIDFILE="$WS/ssh_pty_pid"   # 记录本进程 PID，供"启动前停旧会话"用（Windows 上 pkill -f 不可靠）

# 若已有 sshpty 在跑，先停掉（用 PID 文件，跨平台可靠）
if [ -f "$PIDFILE" ]; then
  old=$(cat "$PIDFILE" 2>/dev/null || true)
  if [ -n "$old" ] && [ "$old" != "$$" ] && kill -0 "$old" 2>/dev/null; then
    echo "[sshpty] stopping existing instance pid=$old" >> "$WS/ssh_pty_status"
    kill "$old" 2>/dev/null; sleep 1
  fi
fi
echo $$ > "$PIDFILE"

# 从配置文件读取跳板/目标机/密码（KEY=VALUE，可 source）
[ -r "$CONFIG" ] && . "$CONFIG"
JUMP_HOST="${JUMP_HOST:-__JUMP_HOST__}"     # 例如 <跳板IP:端口>
TARGET_HOST="${TARGET_HOST:-__TARGET_HOST__}" # 例如 root@<目标机IP>
TARGET_PASS="${TARGET_PASS:-__TARGET_PASS__}"

FIFO="$WS/ssh_in"
LOG="$WS/ssh_out"
STATUS="$WS/ssh_pty_status"
ASK="$WS/askpass_pty.sh"
SSHPID=0

# --- 平台检测：Windows Git Bash (MSYS2) 需要额外规避 ---
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) OS=msys ;;
  Darwin) OS=macos ;;
  *)      OS=linux ;;
esac

cat > "$ASK" <<EOF
#!/bin/sh
echo "$TARGET_PASS"
EOF
chmod +x "$ASK"

# 退出时：杀掉 ssh 子进程、FIFO keep-open、心跳，移除 PID 文件与 askpass（防密码残留）
cleanup() {
  [ "$SSHPID" != "0" ] && kill "$SSHPID" 2>/dev/null
  kill $KEEP $KEEPALIVE 2>/dev/null
  rm -f "$PIDFILE" "$ASK"
}
trap cleanup EXIT

rm -f "$FIFO" "$LOG"
mkfifo "$FIFO"
# 保持 FIFO 写端打开，防止 ssh 读到 EOF 退出。
# 用 while+sleep 循环而非 tail -f /dev/null：后者在 MSYS2 某些版本下会
# 因 /dev/null 特殊性提前退出，导致 FIFO 写端关闭 → ssh 读 EOF → 断连。
( while true; do sleep 3600; done ) > "$FIFO" &
KEEP=$!

# 心跳：每 20s 写一条 bash 注释，保持通道活跃（不依赖 token）
(
  while true; do sleep 20; printf '#ka\n' > "$FIFO" 2>/dev/null; done
) &
KEEPALIVE=$!

restart_count=0
max_fast_fails=8
min_uptime=25   # 必须 > ConnectTimeout=20：20s 连接超时不视为"曾连通"，否则计数器被清零导致无限重试
while true; do
  # 每次重连前重新读取 token（换 token = 覆写文件即自动生效，无需重启脚本）
  if [ -r "$TOKEN_FILE" ]; then
    TOKEN=$(tr -d '\r\n' < "$TOKEN_FILE")
  else
    TOKEN="__TOKEN__"
  fi
  JUMP="${TOKEN}@${JUMP_HOST}"

  start=$(date +%s)
  restart_count=$((restart_count+1))
  echo "[sshpty] #$restart_count starting (PTY+keepalive)..." >> "$STATUS"

  SSH_ASKPASS=$ASK SSH_ASKPASS_REQUIRE=force \
  ssh -tt \
    -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -o ConnectTimeout=20 -o ServerAliveInterval=25 -o ServerAliveCountMax=8 \
    -J "$JUMP" "$TARGET_HOST" 'stty -echo; export PS1="" PS2=""; unset PROMPT_COMMAND; bash --norc -s' \
    < "$FIFO" > "$LOG" 2>&1 &
  SSHPID=$!
  wait $SSHPID
  rc=$?
  SSHPID=0
  dur=$(( $(date +%s) - start ))
  echo "[sshpty] #$restart_count ssh exited rc=$rc after ${dur}s" >> "$STATUS"

  # 1) 明确认证失败签名 → token 可能过期。不退出，进入"等待新 token"循环：
  #    持续用当前 token 重试（若 token 在 5 分钟窗口内刷新则自动救回），
  #    并检测 token 文件是否被覆写（换新 token = 覆写文件即可，无需重启脚本）。
  if grep -qiE "Permission denied|platform authorization denied|stdio forwarding failed|Access denied" "$LOG" 2>/dev/null; then
    if [ "$dur" -lt "$min_uptime" ]; then
      echo "[sshpty] TOKEN_DEAD detected. 等待新 token（覆写 ~/.jump-ssh/token 自动重连）..." >> "$STATUS"
      # 记住当前 token 内容，检测变化
      cur_token="$(cat "$TOKEN_FILE" 2>/dev/null)"
      wait_rounds=0
      while true; do
        # 检测 token 文件是否被覆写
        new_token="$(cat "$TOKEN_FILE" 2>/dev/null)"
        if [ "$new_token" != "$cur_token" ]; then
          echo "[sshpty] 检测到新 token，重试连接..." >> "$STATUS"
          break
        fi
        # 每 5s 用当前 token 试一次（若 token 在窗口内刷新则救回）
        wait_rounds=$((wait_rounds+1))
        if [ $((wait_rounds % 12)) -eq 0 ]; then
          break
        fi
        sleep 5
      done
      # 继续外层 while 重连（token 文件可能已更新）
      sleep 2
      continue
    fi
  fi

  # 2) 曾连通（会话维持 >=min_uptime）后掉线 → 正常重连，重置快速失败计数
  if [ "$dur" -ge "$min_uptime" ]; then restart_count=0; fi

  # 3) 连续快速失败上限 → 不停止，进入"等待新 token"循环（与 1) 相同逻辑）
  if [ "$restart_count" -ge "$max_fast_fails" ]; then
    echo "[sshpty] CONNECT_FAILED ${restart_count}x in a row (fast). 等待新 token（覆写 ~/.jump-ssh/token 自动重连）..." >> "$STATUS"
    cur_token="$(cat "$TOKEN_FILE" 2>/dev/null)"
    while true; do
      new_token="$(cat "$TOKEN_FILE" 2>/dev/null)"
      if [ "$new_token" != "$cur_token" ]; then
        echo "[sshpty] 检测到新 token，重试连接..." >> "$STATUS"
        break
      fi
      sleep 5
    done
    restart_count=0
    sleep 2
    continue
  fi
  sleep 3
done
