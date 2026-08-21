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

# token 从独立文件读取（去换行/CR）。文件缺失时用占位符兜底，保证不崩溃。
if [ -r "$TOKEN_FILE" ]; then
  TOKEN=$(tr -d '\r\n' < "$TOKEN_FILE")
else
  TOKEN="__TOKEN__"
fi
JUMP="${TOKEN}@${JUMP_HOST}"

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
# 保持 FIFO 写端打开，防止 ssh 读到 EOF 退出
tail -f /dev/null > "$FIFO" &
KEEP=$!

# 心跳：每 20s 写一条 bash 注释，保持通道活跃（不依赖 token）
(
  while true; do sleep 20; printf '#ka\n' > "$FIFO" 2>/dev/null; done
) &
KEEPALIVE=$!

restart_count=0
max_fast_fails=8
min_uptime=15   # 会话维持 >=15s 视为"曾连通"
while true; do
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

  # 1) 明确认证失败签名 → 立即停。注意只匹配强信号：`Connection closed by UNKNOWN
  #    port 65535`/`closed by remote host` 在网络故障时也会出现，不能当 token 死。
  if grep -qiE "Permission denied|platform authorization denied|stdio forwarding failed|Access denied" "$LOG" 2>/dev/null; then
    if [ "$dur" -lt "$min_uptime" ]; then
      echo "[sshpty] TOKEN_DEAD (auth refused), stopping." >> "$STATUS"
      break
    fi
  fi

  # 2) 曾连通（会话维持 >=min_uptime）后掉线 → 正常重连，重置快速失败计数
  if [ "$dur" -ge "$min_uptime" ]; then restart_count=0; fi

  # 3) 连续快速失败上限 → 停止，避免 token 失效/网络不通时无限重启
  if [ "$restart_count" -ge "$max_fast_fails" ]; then
    echo "[sshpty] CONNECT_FAILED ${restart_count}x in a row (fast), stopping. 检查 token/网络，重新按 skill 流程连接。" >> "$STATUS"
    break
  fi
  sleep 3
done
