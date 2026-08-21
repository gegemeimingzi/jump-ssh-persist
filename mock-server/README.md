# 本地 mock：GoAnywhere 行为模拟器

无需真实比赛服务器即可端到端验证 `jump-ssh-persist` skill（或手工练习 SSH 跳板流程）。

## 它模拟什么

| 真实环境 | mock |
|---|---|
| GoAnywhere 跳板（token 即跳板用户名） | sshd 监听 **127.0.0.1:2222** |
| 目标机（root，密码认证） | sshd 监听 **容器内 22 端口**（宿主映射 127.0.0.1:2223） |
| token 有效（如 `jt_xxx:yyy`） | 跳板用户名用 `root`（存在即有效） |
| token 失效（`authorization denied`） | 跳板用户名不存在 → `Permission denied` |

凭据固定：**用户名 root / 密码 mockpass**。这是假凭据，只用于本地测试。

## 启动 / 停止

```bash
bash start_mock.sh    # 首次构建镜像，之后秒起；端口 2222/2223
bash stop_mock.sh     # 停止并清理容器
```

依赖：Docker（Windows 用 Docker Desktop）。构建后只需 `docker ps` 检查容器在即可复用。

## 用 skill 连 mock

配置（`~/.jump-ssh/config`）：
```
JUMP_HOST=127.0.0.1:2222
TARGET_HOST=root@127.0.0.1
TARGET_PASS=mockpass
```
token 文件写入 `root`（有效）或任何不存在用户（失效）：
```bash
printf 'root' > ~/.jump-ssh/token
```
然后按 skill 流程：启动 sshpty → sshsend 验证：
```bash
nohup bash ~/.jump-ssh/bin/sshpty.sh > /tmp/sshpty.log 2>&1 &
bash ~/.jump-ssh/bin/sshsend.sh "hostname"
```

## 手动直连（验证 mock 本身）

```bash
SSH_ASKPASS=/tmp/asktest.sh SSH_ASKPASS_REQUIRE=force \
  ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password \
  root@127.0.0.1 -p 2222 'echo hi'          # 直连跳板
ssh -o StrictHostKeyChecking=no -J root@127.0.0.1:2222 root@127.0.0.1 'echo hi'  # 经跳板到目标
```

## 已知注意点

- **Windows Git Bash 的权限显示**：若本机 `/tmp`（或其他盘）挂载为 `noacl,posix=0`，`stat` 恒显 `644`，即使 `chmod 600` 已生效。真实保护在 Windows ACL 层（`icacls` 移除继承、仅属主）。验证权限请用 `icacls` 或 `umask 077; stat -c %a`，不要只看裸 `stat`。
- **容器重建后目标机/跳板 key 会变**：如遇 `Host key verification failed`，清掉旧 key：
  `ssh-keygen -R 127.0.0.1`（Windows Git Bash 下 -J 跳板的 key 检查忽略 `UserKnownHostsFile` 选项，只能清默认 known_hosts）。
- **`-J` 目标机端口必须用默认 22**：Windows OpenSSH 对 `-J ... host:port` 的转发有 bug（`Name does not resolve`）。这就是 mock 目标机在容器内监听 22 端口的原因，与真实环境（目标机 22 端口）一致。
