#!/bin/bash
# 构建并启动本地 mock（跳板 2222 + 目标机 2223）。
# 需要 Docker。构建一次后启动只需 ~1s。
set -e
cd "$(dirname "$0")"

NAME=jump-mock
if ! docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
  docker build -q -t jump-mock-img . >/dev/null
  # 跳板容器内 2222；目标机容器内 22（贴合生产：目标机默认 22 端口，-J 目标无端口写法）
  docker run -d --rm --name "$NAME" -p 2222:2222 -p 2223:22 jump-mock-img >/dev/null
  # 等 sshd 就绪
  for i in $(seq 1 20); do
    if docker exec "$NAME" sh -c 'ss -tln | grep -qE ":2222|:22 "' 2>/dev/null; then break; fi
    sleep 0.5
  done
fi
echo "mock ready: 跳板 127.0.0.1:2222 (token@...) / 目标机 root@127.0.0.1 容器内22端口→宿主2223 (密码 mockpass)"
