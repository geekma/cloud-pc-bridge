# cloud-pc-bridge

**English** — A small, dependency-free HTTPS control plane for cloud PCs and remote servers that have no public IP and no usable SSH / RDP. Put one Node.js gateway on the server you own, expose it through a tunnel, and any client that can send an HTTPS POST can list directories, read and write files, run PowerShell / cmd / shell commands, and read an audit log.

**中文** — 给云电脑和远程服务器加一层自建 HTTPS 控制面。网关只监听回环地址，公网入口交给隧道；客户端只需会发 `HTTPS POST + Bearer 令牌 + JSON`，就能列目录、读写文件、执行 `PowerShell` / `cmd` / `sh`、查看审计日志。已在一台中国电信 TeleAgent 云电脑上连续运行验证，见[背景](#背景在一台真实的-teleagent-云电脑上跑通)。

![license](https://img.shields.io/badge/license-MIT-blue.svg)
![node](https://img.shields.io/badge/node-%3E%3D18-brightgreen.svg)
![python](https://img.shields.io/badge/python-%3E%3D3.8-blue.svg)
![deps](https://img.shields.io/badge/runtime%20deps-0-success.svg)

---

## 适用场景

很多云电脑（Desktop-as-a-Service）只提供自家客户端或网页端：没有公网 IP、不开放 RDP 端口、桌面链接按登录态临时签发、空闲自动关机、并发连接有上限。这类机器上做 GUI 自动化既不稳定也不可审计。

本方案换一条路：**不碰厂商客户端，不破解登录，不调用未公开接口**，只在你拥有管理权限的机器上放一个自己写的小网关，自己开隧道，自己保管令牌。原有网站和业务不受影响，控制面可以随时停掉回退。

> 只在你自己拥有、或已获明确授权管理的服务器上使用；部署前请确认服务条款允许运行自建服务。

## 背景：在一台真实的 TeleAgent 云电脑上跑通

这套东西不是纸面方案。它在一台**中国电信 TeleAgent 云电脑**上实际部署并连续运行过，也正是那台机器的约束逼出了这里的设计取舍。

那台机器的条件很典型：

| 约束 | 实际表现 |
|---|---|
| 没有公网 IP，RDP 端口不可达 | 只能通过厂商客户端（桌面端 / 网页端）的 HTML5 远程桌面进入 |
| 访问入口按登录态临时签发 | 无法长期持有固定入口，也无法从外网直连 |
| 平台按空闲与会话状态回收实例 | 实测约 1～1.5 小时一次强制重置，系统事件为 `Kernel-Power 41`，没有正常关机记录 |
| 机器上另跑着既有 Web 服务 | 控制面必须与既有服务共存，不占端口、不改配置、不重启站点 |

实测结果：

- 七个动作全部跑通（`health` / `sysinfo` / `list` / `read` / `write` / `exec` / `log`），命令通道覆盖 64 位 `PowerShell`、32 位 `PowerShell` 与 `cmd`。
- 一次宿主层硬重启后，公网 `health` 在 **104 秒**后恢复 200；另一次公网探测超时后 **16 秒**自愈。
- 连续运行期间记录 **14 次**自动恢复，连续失败计数保持 0。
- 全程只用自建网关加标准隧道：**没有破解厂商客户端，没有调用未公开接口，没有改动既有 Web 服务**。

> 本项目与厂商无关联，不是官方方案。TeleAgent 名称仅用于说明实测环境；文中不含任何真实域名、地址、账号或业务路径。

## 特性

- **零第三方运行时依赖** — 网关只用 Node 标准库；命令行客户端只用 Python 标准库。
- **客户端无关** — `curl`、Python、Node、CI 流水线、自建 Agent、支持自定义动作的大模型客户端、支持 MCP 的客户端都能接。
- **默认最小暴露** — 网关只绑 `127.0.0.1` 与 `::1`；文件操作限制在白名单目录；命令执行默认关闭。
- **安全优先级正确** — 每个请求先做定时安全比较验令牌，再限流，再校验路径与命令策略；未授权请求不占限流配额。
- **可审计** — 每次调用的时间、来源、动作、成败、耗时都写入审计日志。
- **不动原服务** — 非控制面请求按原样反向代理给服务器上已有站点，保留 `Host`，不改端口、不改密码。
- **两条命令部署** — 服务器一条、本机一条；脚本自动建目录、生成令牌、注册自启与看门狗、跑完 8 项验证。
- **重启后自动恢复** — 开机自启 + 分钟级健康看门狗 + 隧道重建 + 客户端重试；实测恢复窗口约 1～2 分钟。
- **变更可回滚** — 换版本前可先在临时端口预启动验证，失败自动还原备份。

## 快速开始

只需要两个文件：`server/setup-server.ps1`（Windows，自包含，已内嵌网关代码）或 `server/setup-server.sh`（Linux / macOS），以及 `client/setup.py`（本机）。

### 第 1 步：服务器端

把 `server/setup-server.ps1` 放到目标机器，打开 PowerShell：

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-server.ps1 -TunnelCommand 'ngrok http 8787' -EnableExec
```

Linux / macOS（需要 Python 3.8+、Node 18+，写 systemd 需要 root）：

```bash
sudo bash server/setup-server.sh --enable-exec --tunnel-command 'ngrok http 8787'
```

- `-TunnelCommand` / `--tunnel-command` 换成你自己的隧道命令（`cloudflared`、FRP 同理）。
- `-EnableExec` / `--enable-exec` 表示允许远程执行命令，**不需要就去掉**（默认关闭）。
- 只想先在本机回环验证，不传隧道参数即可。

脚本会：建目录 → 用密码学安全随机数生成 64 位令牌 → 写配置并收紧权限 → 释放网关并做语法检查 → 注册开机自启、进程自愈、分钟级看门狗、隧道自启 → 自测 `health` 与「无令牌返回 401」→ 生成交接文件 `bridge-handoff.json`。

> `bridge-handoff.json` **含明文令牌，等同钥匙**。复制到本机后立刻删除服务器上的副本。
> Windows 版默认用「用户登录时触发」的计划任务，因此服务器需要开启自动登录；不能自动登录时按[服务器配置 · Step 6](docs/02-server-setup.md#step-6--变成后台服务--保活)改为 SYSTEM 账户 + 开机触发。

### 第 2 步：本机

```bash
python3 client/setup.py --from ./bridge-handoff.json --consume-handoff
```

`--consume-handoff` 读完即删除本机副本；隧道地址缺失时补 `--url https://<你的隧道域名>`。

脚本会：把令牌写入 `~/.config/remote-bridge/token`（`0600`）→ 写入地址与环境文件 → 生成 MCP 配置、填好地址的 OpenAPI 描述、给 AI Agent 的提示词 → 可选合并进已有 MCP 配置（合并前自动备份）→ 自动跑 8 项验证。

### 验收口径

第 1 步应输出 `local health: OK` 与 `no-token returns: 401 OK`；第 2 步应输出 `RESULT: OK`（`exec` 未开启时该项为 SKIP，不算失败）。任一项 FAIL，按[故障排查](docs/07-operations.md#故障排查)逐条定位。

### 之后怎么用

```bash
python3 client/bridge.py health
python3 client/bridge.py sysinfo
python3 client/bridge.py list /srv/data
python3 client/bridge.py exec 'df -h' --shell sh
```

也可以给支持 MCP 的客户端导入 `client/mcp.example.json`，给支持自定义动作的客户端导入 `client/openapi.example.yaml`，或者直接 `curl` 打 `POST /__agent/<动作>`。

## 能做什么、不能做什么

| 能做 | 不能做 |
|---|---|
| 白名单目录列目录、读写文件（文本与二进制）、写前自动备份 | 访问白名单之外的任何路径 |
| 执行非交互命令，拿到退出码、stdout、stderr | 鼠标键盘级 GUI 操作、看屏幕、点弹窗 |
| 查系统信息、查审计日志、反向代理保留原有网站 | 交互式命令、等待输入、安装向导 |
| 任意客户端接入（脚本 / 自定义动作 / MCP / 纯对话贴结果） | 流式输出、长连接、大文件直传 |
| 两条命令部署，重启后自动恢复 | 阻止平台强制关机、定时重置、宿主层断电 |
| 单令牌、单用户、可审计 | 多用户 RBAC、细粒度权限、配额隔离 |

完整清单、分层限制与风险登记见[能力、限制与风险](docs/06-capabilities.md)。

> **「一小时重启一次」能不能根治？** 不能。宿主层断电绕过 Windows 的关机流程，虚拟机内部拦不住。本方案解决的是「重启后不用人管、几分钟内自己回来」，详见[保活与平台定时重启](docs/03-keepalive.md)。

## 仓库结构

```
.
├── server/                          # 部署在远程服务器上
│   ├── gateway.js                   # 网关本体，零第三方依赖
│   ├── config.example.json          # 配置模板，复制成 config.json 后填写
│   ├── setup-server.ps1             # Windows 一键部署（自包含，内嵌网关代码）
│   ├── setup-server.sh              # Linux / macOS 一键部署（systemd）
│   ├── setup-server.template.ps1    # 一键脚本逻辑模板（维护者用）
│   ├── keepalive.ps1                # 可选会话保活：抑制空闲睡眠、否决普通关机
│   └── make-onefile.py              # 由模板重新生成自包含 setup-server.ps1
├── client/                          # 运行在本机
│   ├── setup.py                     # 本机一键配置 + 8 项验证
│   ├── bridge.py                    # 零依赖命令行客户端
│   ├── mcp-bridge.js                # MCP stdio 桥，7 个工具
│   ├── mcp.example.json             # MCP 配置模板
│   └── openapi.example.yaml         # OpenAPI 描述，供自定义动作 / 函数调用
├── docs/                            # 文档
└── ci/github-actions.yml            # CI 定义，启用方式见 CONTRIBUTING
```

## 文档

| 文档 | 内容 |
|---|---|
| [背景与架构](docs/01-background.md) | 核心概念、为什么不能直连、四条路线对比、架构图、准备清单 |
| [服务器端配置（手工版）](docs/02-server-setup.md) | 八个步骤的完整命令：目录、令牌、配置、自启、隧道、外部验收、变更安全做法 |
| [保活与平台定时重启](docs/03-keepalive.md) | 「一小时重启一次」的真相、实测恢复时间线、四层保活、验证方法 |
| [客户端配置（手工版）](docs/04-client-setup.md) | 五个步骤：令牌、地址、客户端选择、七个动作、接口契约 |
| [任意客户端接入](docs/05-client-integration.md) | 接入矩阵、三类客户端示例、通用提示词模板 |
| [能力、限制与风险](docs/06-capabilities.md) | 能做 / 有条件做 / 不能做、分层限制、风险登记表 |
| [运维手册](docs/07-operations.md) | 日常操作速查、安全加固清单、故障排查、完整验收清单 |
| [接口契约与常见疑问](docs/08-api-reference.md) | 七个动作的出入参、HTTP 状态码、文件说明、FAQ |

## 接口一览

统一入口：`POST <网关地址>/__agent/<动作>`，头 `Authorization: Bearer <令牌>`、`Content-Type: application/json`，体为 JSON 对象。

| 动作 | 作用 |
|---|---|
| `health` | 网关版本、进程、白名单分组、命令开关 |
| `sysinfo` | 系统版本、CPU 数、内存、运行时长 |
| `list` | 列白名单目录，最多 500 项 |
| `read` | 读文件，支持 `base64` 取原始字节，单次上限 2 MB |
| `write` | 写文件，支持 `base64` 上传二进制，写前自动备份 |
| `exec` | 执行命令，需显式开启，必带超时，危险命令被拒绝 |
| `log` | 审计日志尾部 |

详细参数与返回字段见[接口契约](docs/08-api-reference.md#接口契约速查)。

## 环境要求

| 位置 | 要求 |
|---|---|
| 服务器 | Windows Server 2016+ / Windows 10+，或带 systemd 的 Linux；Node.js 18+ |
| 本机 | Python 3.8+（命令行客户端与一键配置）；用 MCP 桥时另需 Node.js 18+ |
| 公网 | 任意隧道工具：ngrok / cloudflared / FRP，或你自己的反代 |

## 安全

- 令牌是 64 位十六进制随机串，只存放于服务端 `config.json`（`600` / 仅管理员与 SYSTEM）与本机 `0600` 文件或环境变量。
- 网关只绑回环地址；公网可达性完全交给隧道，隧道可再加一层访问控制。
- 路径白名单 + 拒绝规则双重限制；`config.json`、`*.key`、`*.pem`、`id_rsa`、`.ssh/` 默认禁读。
- 命令执行默认关闭；开启后仍受 `execDeny` / `execAllow`、超时、输出上限、并发上限约束。
- 令牌泄露等同控制权泄露：立即改服务端令牌 → 重启 → 同步所有客户端 → 确认旧令牌返回 401 → 查审计日志。

漏洞报告与安全模型见 [SECURITY.md](SECURITY.md)；上线前请逐项打勾[安全加固清单](docs/07-operations.md#安全加固清单)。

## 参与

见 [CONTRIBUTING.md](CONTRIBUTING.md)。改动 `server/gateway.js` 或 `server/keepalive.ps1` 后必须重新运行 `python3 server/make-onefile.py`，否则一键脚本里的内嵌副本会与源文件不一致。

CI 定义在 `ci/github-actions.yml`，包含语法检查、生成物一致性检查与端到端冒烟测试。启用方式：

```bash
mkdir -p .github/workflows && cp ci/github-actions.yml .github/workflows/ci.yml
```

提交这个文件需要 GitHub 令牌带 `workflow` scope。用 `gh` 时可先执行 `gh auth refresh -s workflow` 完成授权。

## 许可

[MIT](LICENSE)

## 免责

本软件按「现状」提供，不附带任何担保。远程控制通道天然具有高风险：请自行评估合规性与安全边界，只在自有或已授权机器上部署，并自行承担使用后果。

本项目为独立实现，与中国电信及 TeleAgent 产品方无隶属、合作或背书关系，未使用其客户端代码或未公开接口。文中提及的产品名称仅作环境说明。
