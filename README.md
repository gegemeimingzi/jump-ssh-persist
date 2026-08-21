# jump-ssh-persist — 常驻 SSH 连接 Skill

建立并保持经 **GoAnywhere 跳板 + 短期 token** 的服务器常驻 SSH 连接（如昇腾比赛服务器）。

一句话：拿到 token 后 ≤1 分钟建连，靠心跳保持长连接；token 过期只影响断线重连，不影响已建立连接。

## 目录

```
jump-ssh-persist/
├── SKILL.md            # skill 主体（触发条件 + 完整流程 + 排障）
├── scripts/
│   ├── sshpty.sh       # 常驻会话：-tt PTY + FIFO + 心跳 + 自动重连 + PID 自清理
│   ├── sshsend.sh      # 发命令/回读：marker 机制，清洗 PTY 转义
│   └── ssht.sh         # 单次连接备用（带 -tt）
├── mock-server/        # 本地 GoAnywhere 模拟器（Docker），无需真实服务器即可验证/复现
└── evals/              # 测试用例（基于 mock）
```

## 核心设计

- **凭据与脚本分离**：脚本自身不含凭据。跳板/目标机/密码在 `~/.jump-ssh/config`，一次性 token 在 `~/.jump-ssh/token`。换 token = 覆写 token 文件 + 重启，不用改脚本。
- **GoAnywhere 限制**：只放行交互式会话 → 必须 `ssh -tt`；非 PTY 连接/scp 被拒（`platform authorization denied`）。
- **失败分级检测**：强认证失败签名（`Permission denied` / `platform authorization denied` / `stdio forwarding failed` / `Access denied`）→ 立即 `TOKEN_DEAD` 停止；模糊签名（`Connection closed by UNKNOWN port 65535` 等，网络故障也会出现）→ 靠重启上限兜底（连续 8 次快速失败才停），不误判 token 死。
- **Windows 兼容**：Git Bash 下 `pkill -f` 不可靠 → 用 PID 文件停旧会话（`/tmp/ssh_pty_pid`）；禁 `setsid`/`ControlMaster`。
- **多实例隔离**：`SSH_WS=/tmp/xxx` 环境变量可隔离 FIFO/LOG/状态/PID。

## 验证方式

1. **真实服务器**：按 SKILL.md 流程，提供 `ssh -J jt_xxx@跳板 root@目标机` 整行即可。
2. **本地 mock（无需真实服务器）**：`cd mock-server && bash start_mock.sh`，然后用 skill 连 `127.0.0.1:2222`（root/mockpass）。见 `mock-server/README.md`。

## 已通过的验证

- ✅ 真实过期 token → `TOKEN_DEAD` 1s 内干净停止，无无限重启
- ✅ 关闭端口（模糊签名）→ 8 次快速失败后 `CONNECT_FAILED` 停止
- ✅ mock 端到端：建连 → 发命令 → 心跳保持（20s+）→ 二次启动 PID 自清理 → 死 token 诊断
- ✅ 跨 Bash 调用持久（常驻会话不依赖发起进程）

## 安全

凭据（密码/token）明文在本地 `~/.jump-ssh/`，权限 600；不提交公开仓库。仅用于你有权访问的服务器。
