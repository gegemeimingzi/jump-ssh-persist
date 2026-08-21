#!/bin/bash
# connect.sh — 傻瓜式一键连接（jump-ssh-persist 配套）
# 不用记任何结构：传 token 或完整 ssh 行，脚本自动完成「解析→(首次)配置→写 token→
# 部署脚本→启动常驻会话→验证连通」。
#
# 用法（任选一种）：
#   bash connect.sh "ssh -J jt_xxx:yyy@跳板IP:端口 root@目标机IP"   # 传完整 ssh 行（推荐）
#   bash connect.sh "jt_xxx:yyy"                                    # 只传 token（用已有配置）
#   bash connect.sh                                                 # 交互式引导（首次）
D=~/.jump-ssh
mkdir -p "$D/bin"

# ---------- 1) 解析输入 ----------
parse_line() {
  local line="$1"
  if echo "$line" | grep -q ' -J '; then
    # 完整 ssh 行：ssh -J token@跳板:端口 user@host
    TOKEN=$(echo "$line" | sed -E 's/.*-J ([^@]+)@.*/\1/')
    JPH=$(echo "$line" | sed -E 's/.*-J [^@]+@([^ ]+).*/\1/')
    TH=$(echo "$line" | sed -E 's/.* ([^ ]+)$/\1/')
  else
    # 只有 token
    TOKEN=$(echo "$line" | tr -d '[:space:]')
    JPH=""; TH=""
  fi
}

if [ $# -ge 1 ] && [ -n "$1" ]; then
  parse_line "$1"
else
  echo "没有提供 token。请粘贴下面任一形式（直接回车则用已有 token）："
  echo '  ssh -J jt_xxx:yyy@跳板IP:端口 root@目标机IP'
  echo '  jt_xxx:yyy'
  read -rp "> " line
  [ -n "$line" ] && parse_line "$line"
fi

# ---------- 2) 确保 config（首次交互式，只填一次） ----------
CONFIG="$D/config"
need_config=0
[ ! -f "$CONFIG" ] && need_config=1
if [ $need_config -eq 1 ]; then
  echo "首次使用：需要你提供服务器信息（只填这一次，之后换 token 不用再填）。"
  read -rp "跳板 host:port（例如 跳板IP:2234）: " JUMP_HOST
  read -rp "目标机 user@host（例如 root@目标机IP）: " TARGET_HOST
  read -rsp "目标机密码: " TARGET_PASS; echo
  umask 077
  printf 'JUMP_HOST=%s\nTARGET_HOST=%s\nTARGET_PASS=%s\n' \
    "$JUMP_HOST" "$TARGET_HOST" "$TARGET_PASS" > "$CONFIG"
  chmod 600 "$CONFIG"
  echo "配置已写入 $CONFIG（600）"
fi

# 若本次给了完整行，顺手同步 config 里的跳板/目标机（防止服务器信息变更）
if [ -n "$JPH" ] && [ -n "$TH" ]; then
  umask 077
  cp "$CONFIG" "$CONFIG.bak" 2>/dev/null
  sed -i -e "s|^JUMP_HOST=.*|JUMP_HOST=$JPH|" -e "s|^TARGET_HOST=.*|TARGET_HOST=$TH|" "$CONFIG"
fi

# ---------- 3) 写 token ----------
if [ -n "$TOKEN" ]; then
  umask 077; printf '%s' "$TOKEN" > "$D/token"; chmod 600 "$D/token"
  echo "token 已写入（$(wc -c < "$D/token") 字节，600）"
fi

# ---------- 4) 部署脚本（幂等） ----------
SRC="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SRC/sshpty.sh" ]; then SRC_DIR="$SRC"; else SRC_DIR="$SRC/scripts"; fi
for f in sshpty.sh sshsend.sh ssht.sh connect.sh; do
  [ -f "$SRC_DIR/$f" ] && cp "$SRC_DIR/$f" "$D/bin/" 2>/dev/null && chmod +x "$D/bin/$f"
done

# ---------- 5) 停旧会话 + 启动 + 验证连通 ----------
WS="${SSH_WS:-/tmp}"   # 与 sshpty.sh 一致；多实例/测试可 SSH_WS 隔离
mkdir -p "$WS"         # 自定义工作区目录可能不存在，先建（否则重定向失败、sshpty 起不来）
[ -f "$WS/ssh_pty_pid" ] && kill "$(cat "$WS/ssh_pty_pid")" 2>/dev/null
rm -f "$WS/ssh_in" "$WS/ssh_out" "$WS/ssh_pty_status"
nohup bash "$D/bin/sshpty.sh" > "$WS/sshpty.log" 2>&1 &

for i in $(seq 1 25); do
  out=$(timeout 8 bash "$D/bin/sshsend.sh" "hostname" 2>/dev/null)
  # 只认「单个单词」的 hostname（字母/数字/点/横线，无空格无括号）：
  # 之前宽松正则把 sshsend 报错（如 "[sshsend] FIFO 不存在..."）误判成连接成功，必须排除
  if echo "$out" | grep -qE '^[a-zA-Z0-9._-]{1,64}$' && ! echo "$out" | grep -qE 'sshsend|FIFO|WARNING|超时'; then
    echo "✅ 已连接：$out"
    echo "   之后直接用： bash $D/bin/sshsend.sh \"你的命令\""
    exit 0
  fi
  # 尽早发现 token 死 / 连续失败
  if grep -qE 'TOKEN_DEAD|CONNECT_FAILED' "$WS/ssh_pty_status" 2>/dev/null; then
    echo "❌ token 无效或网络不通（$(grep -oE 'TOKEN_DEAD|CONNECT_FAILED' "$WS/ssh_pty_status" | head -1)）"
    echo "   请检查 token 后重试。"
    exit 1
  fi
  sleep 2
done
echo "❌ 连接超时（>60s）。请看 $WS/ssh_pty_status"
exit 1
