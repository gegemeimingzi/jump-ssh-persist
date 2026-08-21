#!/bin/bash
# ssht.sh — 单次连接备用（token 有效时的应急/探测）。每次新建一次 SSH 连接。
# 注意：GoAnywhere 只放行交互式会话，必须加 -tt，否则报 platform authorization denied。
# 用法: bash ssht.sh "命令"
CONFIG="$HOME/.jump-ssh/config"
TOKEN_FILE="$HOME/.jump-ssh/token"

[ -r "$CONFIG" ] && . "$CONFIG"
JUMP_HOST="${JUMP_HOST:-__JUMP_HOST__}"
TARGET_HOST="${TARGET_HOST:-__TARGET_HOST__}"
TARGET_PASS="${TARGET_PASS:-__TARGET_PASS__}"

if [ -r "$TOKEN_FILE" ]; then
  TOKEN=$(tr -d '\r\n' < "$TOKEN_FILE")
else
  TOKEN="__TOKEN__"
fi
JUMP="${TOKEN}@${JUMP_HOST}"

WS="${SSH_WS:-/tmp}"
ASK="$WS/askpass_ssht.sh"
cat > "$ASK" <<EOF
#!/bin/sh
echo "$TARGET_PASS"
EOF
chmod +x "$ASK"

CMD="${1:-hostname; whoami; uname -a}"

SSH_ASKPASS=$ASK SSH_ASKPASS_REQUIRE=force \
timeout 60 ssh -tt \
  -o StrictHostKeyChecking=no -o ConnectTimeout=20 -o NumberOfPasswordPrompts=1 \
  -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ControlMaster=no \
  -J "$JUMP" "$TARGET_HOST" "$CMD" < /dev/null
rc=$?
rm -f "$ASK"   # 删除临时 askpass（防密码残留）
exit $rc
