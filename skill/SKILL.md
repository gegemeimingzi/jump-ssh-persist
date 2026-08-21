---
name: jump-ssh-persist
description: 建立并保持到昇腾比赛服务器（或任何经 GoAnywhere 跳板 + 短期 token 的服务器）的常驻 SSH 连接。务必在用户提到「连服务器」「连接比赛服务器」「跑评测」「在服务器上执行命令」「服务器上传/下载」「检查服务器」「SSH 连接」等任何需要远程操作服务器的场景使用，即使只是执行一条命令也应先建立常驻连接。token 有效期很短（约 5 分钟，实测更长），本 skill 的目标：拿到 token 后 ≤1 分钟建连并靠心跳保持长连接；token 过期只影响断线重连，不影响已建立连接。
compatibility: bash + ssh（OpenSSH 8+）。Windows 需 Git Bash/MSYS2（含 perl、timeout）。跳板 GoAnywhere 仅放行交互式会话，必须 -tt PTY。
---

# 常驻 SSH 连接（GoAnywhere 跳板 + 短期 token）

## 为什么需要这套机制

目标机只能经**跳板**（GoAnywhere）访问，跳板有两个硬限制：

1. **只放行交互式会话**：`scp` / 非 PTY 的 `ssh` 会被拒（`platform authorization denied`），必须用 `ssh -tt` 分配伪终端。
2. **token 短期失效**：token 只用于**建连**；连接建立后靠心跳保持，不依赖 token。token 过期只会导致**断线后无法自动重连**。

结论：**一条常驻 `ssh -tt` 会话 + FIFO 命令通道**，才是正确姿势。不要每次命令都新建连接（非 PTY 被拒、慢）。

## 配置布局（脚本自身不含任何凭据）

```
~/.jump-ssh/
├── config         # 跳板/目标机/密码（KEY=VALUE，可 source，权限 600）
├── token          # 一次性 token，如 jt_xxx:yyy（权限 600，换 token 只需覆写它）
└── bin/           # 部署的 sshpty.sh / sshsend.sh / ssht.sh
```

- **为什么 token 单独放文件**：token 频繁更换（几小时/一次会话），而跳板/目标机长期不变。放独立文件后，换 token = `printf '%s' 'jt_xxx:yyy' > ~/.jump-ssh/token` + 重启 sshpty，不用改任何脚本。config 保持不变。
- **为什么脚本读 config 而非内置**：改跳板/目标机只需编辑 config，脚本自动生效。

## 完整流程（拿到 token 后 ≤1 分钟连通）

```
拿 token（用户对话提供）→ 解析 → 首次配置(仅首回) → 写 token → 启动常驻会话 → 验证连通 → 返回就绪
```

### Step 0 — 前置检查（每次连接都做，快速）

1. 确认有 `ssh`（OpenSSH）、`perl`、`timeout`。Windows Git Bash 自带；macOS/Linux 原生有。
2. 检查是否已有常驻会话：`[ -f /tmp/ssh_pty_pid ] && kill -0 $(cat /tmp/ssh_pty_pid)` → 有则跳过建连，直接「验证连通」。
3. 换新连接才需停旧会话（见 Step 4 的开头）。

### Step 1 — 拿 token（从用户消息解析）

用户会发类似这样一行（或包含该行的文本）：

```
ssh -J jt_XXXX:YYYY@跳板IP:端口 root@目标机IP
```

从中解析：
- **token** = `-J` 后第一个 `@` 前的部分（`jt_XXXX:YYYY`）
- **跳板** = `-J` 参数里第二个 `@` 后的 `host:port`（`跳板IP:端口`）
- **目标机** = 最后的 `user@host`（`root@目标机IP`）

如果用户只给了 `jt_xxx:yyy` 没给整行，用 config 里的跳板/目标机默认值拼接。消息里没有 token 时，明确告诉用户需要提供整行或 token。

### 向用户索要 token/密钥时：告知使用场景与建议

在索要 token（或密码）时，**顺带用一两句话**告诉用户这个 skill 的使用场景和实用建议，让用户知道连上后能做什么、怎么配合最省事。示例话术：

> 这个 skill 用来建立到服务器的常驻 SSH 连接：拿到 token 后 1 分钟内连上，靠心跳长期保持。之后你说"跑评测 / 在服务器执行命令 / 上传下载文件"，我都会走同一条连接。请发我 `ssh -J jt_xxx@跳板 root@目标机` 整行（或 token）即可。

可选的建议要点（视对话节奏挑讲，不用全说）：
- **使用场景**：跑评测、服务器上执行命令、上传/下载文件、检查服务器状态。
- **省事配合**：给整行最省事（自动解析跳板/目标机）；只给 token 也能连（用配置里的默认值拼接）。
- **token 只用于建连**：连接建立后靠心跳保持，token 过期不影响当前会话，只影响断线重连。
- **安全**：token/密码只存本机 `~/.jump-ssh/`（权限 600），不会上传或公开。

### Step 2 — 首次配置（仅当 `~/.jump-ssh/config` 不存在）

`mkdir -p ~/.jump-ssh && umask 077`，写入 config（权限 600）：

```bash
# 跳板 host:port（不含 token）
JUMP_HOST=<跳板IP:端口>
# 目标机 user@host
TARGET_HOST=root@<目标机IP>
# 目标机密码
TARGET_PASS=<你的密码>
```

首次用上面的默认值引导用户确认/修改。已存在则读取即可。密码/token 敏感：config/token 权限 600，不进公开仓库。

### Step 3 — 写 token + 部署脚本

1. 把解析出的 token 写入文件（换 token 只需这一步）：

   ```bash
   umask 077
   printf '%s' 'jt_XXXX:YYYY' > ~/.jump-ssh/token
   ```

2. 部署脚本（幂等）：把 `scripts/` 下的 `sshpty.sh`、`sshsend.sh`、`ssht.sh` 复制到 `~/.jump-ssh/bin/`，`chmod +x`。脚本从 config/token 文件读取一切，**无需任何 sed 填充**。

### Step 4 — 启动常驻会话（≤1 分钟内连通）

```bash
# 停旧会话：优先按 PID 文件杀（Windows 上 pkill -f 不可靠，可能杀不干净）
[ -f /tmp/ssh_pty_pid ] && kill "$(cat /tmp/ssh_pty_pid)" 2>/dev/null
pkill -f "ssh -tt" 2>/dev/null; sleep 1
rm -f /tmp/ssh_in /tmp/ssh_out

nohup bash ~/.jump-ssh/bin/sshpty.sh > /tmp/sshpty.log 2>&1 &
```

sshpty.sh 内部也会自清理：启动时若 PID 文件存在且进程存活，先停掉旧实例（防止重复会话互相抢 FIFO）。

然后**轮询验证**（不要 sleep 固定太久）：

```bash
for i in $(seq 1 25); do
  out=$(timeout 8 bash ~/.jump-ssh/bin/sshsend.sh "hostname" 2>/dev/null)
  echo "$out" | grep -qE '[a-zA-Z0-9_-]+' && { echo "已连接: $out"; break; }
  sleep 2
done
```

- 成功：输出目标机 hostname，返回「**服务器已连接，可发命令**」。
- 超时（>60s）：读 `/tmp/ssh_pty_status`。
  - 见 `TOKEN_DEAD` → token 无效，请用户重发新 token（回到 Step 1）。
  - 见 `CONNECT_FAILED`（8 次快速失败）→ 检查 token/网络，请用户重发。

### Step 5 — 日常命令

建连后所有远程操作都走 `sshsend.sh`：

```bash
bash ~/.jump-ssh/bin/sshsend.sh "你要的命令"
# 长命令/大输出加第二个参数（等待秒数）：
bash ~/.jump-ssh/bin/sshsend.sh "./run_eval.sh rts" 200
```

- 一条命令对应一次往返，marker 自动取回输出。
- **长任务在服务器上务必 `nohup ... &` 脱离会话**（避免占住 PTY 挤掉连接、断线不影响任务）。
- 传输文件：跳板拒 scp，走 `base64` 多行分块经 sshpty 通道（`cat file | base64 | fold -w 76` 分块写入）。

### Step 6 — token 过期处理

- 现象：`sshsend.sh` 报「写入超时」或「常驻会话已停止（TOKEN_DEAD / CONNECT_FAILED）」。
- 处理：**已建立的连接不受影响**（心跳保持）；只有**断线重连**才需要新 token。若已断线，提示用户提供新 token，覆写 `~/.jump-ssh/token` 后回 Step 4。

## 关键脚本说明

- 工作区默认 `/tmp`（FIFO/LOG/状态/PID 都在 `/tmp`）。同一机器多实例/测试隔离时，可用环境变量 `SSH_WS=/tmp/xxx` 覆盖（sshpty/sshsend/ssht 三个脚本都尊重它）。

- `sshpty.sh`：常驻会话。`-tt` PTY + FIFO stdin + LOG 落盘 + 20s 心跳 + 自动重连 + PID 文件自清理。
  - **失败分级检测**：`Permission denied` / `platform authorization denied` / `stdio forwarding failed` / `Access denied` 等强认证失败签名 → 立即 `TOKEN_DEAD` 停止。`Connection closed by UNKNOWN port 65535` / `closed by remote host` 等模糊签名（网络故障也会出现）→ 不误判，靠**重启上限**兜底：连续 8 次快速失败（每次 <15s）才 `CONNECT_FAILED` 停止。
- `sshsend.sh`：发命令/回读。marker 机制（`>>M<< ... <<M>>`），自动清洗 PTY 转义/提示符，默认等 60s。写超时时读 `/tmp/ssh_pty_status` 给出明确诊断。
- `ssht.sh`：单次连接备用（应急/探测，带 `-tt`）。

## 平台差异

| 平台 | 注意 |
|---|---|
| Windows Git Bash (MSYS2) | **禁 `setsid`、禁 `ControlMaster`**（否则 askpass 回读挂起）。`pkill -f` 不可靠，用 PID 文件停会话。路径用 `/tmp`。 |
| macOS | 原生 OpenSSH；`SSH_ASKPASS_REQUIRE=force` 新版可用。无 MSYS2 禁项。 |
| Linux | 原生 OpenSSH；直接可用。 |

`sshpty.sh` 内部检测平台（`uname`）作 MSYS2 规避。

## 排障速查

| 现象 | 原因 | 处理 |
|---|---|---|
| `platform authorization denied` / `stdio forwarding failed` | 非 PTY 连接被拒或 token 死 | 命令模式加 `-tt`；传输走 base64 分块；token 死则换 token |
| `Permission denied`（target 认证） | 密码错 / token 死 | 核对 config 密码；换新 token |
| `TOKEN_DEAD` / 写入超时 | token 过期 | 换新 token（Step 1/3） |
| `CONNECT_FAILED`（8x fast） | token 死或网络不通（模糊签名） | 检查 token/网络，重发 token |
| `Host key verification failed` | 跳板/目标机 key 变更（如 mock 重建） | `ssh-keygen -R <host>:<port>` 清旧 key |
| 连上但命令无输出 | marker 超时 | `sshsend.sh "cmd" 300` 加长等待 |
| 服务器任务被断线影响 | 任务挂在 PTY | 服务器端 `nohup ... &` |
| 重复会话/状态混乱 | 旧 sshpty 残留 | `kill $(cat /tmp/ssh_pty_pid)` + `pkill -f "ssh -tt"` + `rm -f /tmp/ssh_in /tmp/ssh_out` |

## 安全

- 密码/token 明文在本地：`umask 077`，config/token 权限 `600`，不要提交到公开仓库。
- 仅用于你有权访问的服务器。
