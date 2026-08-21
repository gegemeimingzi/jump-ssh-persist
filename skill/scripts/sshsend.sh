#!/bin/bash
# sshsend.sh — 通过常驻连接执行命令并回读输出
# 用法: bash sshsend.sh "命令" [等待秒数，默认 60]
WS="${SSH_WS:-/tmp}"   # 与 sshpty.sh 保持一致；多实例/测试用 SSH_WS 隔离
FIFO="$WS/ssh_in"
LOG="$WS/ssh_out"
STATUS="$WS/ssh_pty_status"

if [ -z "$1" ]; then echo "usage: sshsend.sh <command> [wait_seconds]"; exit 1; fi
if [ ! -p "$FIFO" ]; then echo "[sshsend] FIFO 不存在，先启动常驻会话（sshpty.sh）"; exit 1; fi

# 折叠换行为 ';'（远程 bash -s 需单行）；修复连接符后多余分号；修剪首尾
cmd=$(printf '%s' "$1" | tr '\n' ';' | sed -e 's/&&;/\&\& /g' -e 's/||;/\|\| /g' -e 's/&;/\& /g' -e 's/|;/\| /g' -e 's/^[;[:space:]]*//' -e 's/[;[:space:]]*$//')

marker="M$(date +%s)$$$RANDOM"
offset=$(stat -c%s "$LOG" 2>/dev/null || echo 0)

# 写入（6s 超时；FIFO 重定向放 timeout 内部，连接若已死不阻塞）
printf 'echo ">>%s<<"; %s; echo "<<%s>>"\n' "$marker" "$cmd" "$marker" | timeout 6 bash -c "cat > '$FIFO'" 2>/dev/null
write_rc=$?
if [ $write_rc -ne 0 ]; then
  # 读状态文件给更明确的诊断：是 token 死了，还是普通掉线
  if grep -qE 'TOKEN_DEAD|CONNECT_FAILED' "$STATUS" 2>/dev/null; then
    echo "[sshsend] 常驻会话已停止（TOKEN_DEAD / CONNECT_FAILED）。请换新 token 后按 skill 流程重连。"
  else
    echo "[sshsend] WARNING: 写入超时，常驻连接可能已断开（token 过期或会话掉了；重新按 skill 流程连接）"
  fi
  exit 2
fi

# 等待 end 标记（默认最多 60s）
WAIT="${2:-60}"
ITER=$((WAIT * 5))
n=0
while [ $n -lt $ITER ]; do
  if [ -f "$LOG" ]; then
    sz=$(stat -c%s "$LOG" 2>/dev/null || echo 0)
    if [ "$sz" -gt "$offset" ] && tail -c +$((offset+1)) "$LOG" 2>/dev/null | grep -q "<<$marker>>"; then
      break
    fi
  fi
  sleep 0.2
  n=$((n+1))
done

# 输出新增内容（去标记行 + 去 PTY 转义/回车 + 去提示符行）
tail -c +$((offset+1)) "$LOG" 2>/dev/null \
  | perl -pe 's/\e\[[0-9;?]*[a-zA-Z]//g; s/\e\][^\a]*\a//g; s/\e[=>]//g; s/\r//g' \
  | sed -e "/>>$marker<</d" -e "/<<$marker>>/d" \
  | grep -vE "^root@|^$" | head -c 9000000
