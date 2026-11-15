# 接口契约、文件说明与常见疑问

## 接口契约速查

统一：`POST <网关地址>/__agent/<动作>`，头 `Authorization: Bearer <令牌>`、`Content-Type: application/json`，体为 JSON 对象。

| 动作 | 主要参数 | 返回要点 |
|---|---|---|
| `health` | 无 | `ok/version/node/platform/roots/execEnabled/shells` |
| `sysinfo` | 无 | `type/release/arch/cpus/totalMemMB/freeMemMB/uptimeSec` |
| `list` | `path` | `items[{name,dir,size}]`，最多 500 项 |
| `read` | `path`, `encoding`, `maxBytes` | `content`（`base64` 时为原始字节）、`size/truncated` |
| `write` | `path`, `content`, `encoding` | `bytes/backup`（写前自动备份路径） |
| `exec` | `command`, `shell`, `cwd`, `timeoutMs`, `env` | `ok/exitCode/timedOut/stdout/stderr/durationMs` |
| `log` | `lines` | `content`（审计日志尾部） |

| HTTP | 含义 |
|---|---|
| 200 | 成功（业务失败仍可能 200，看 `ok` 字段） |
| 400 | 参数错 / 策略拒绝 / 命令退出码非 0 |
| 401 | 令牌错 |
| 404 | 动作不存在（或没开反代时的普通路径） |
| 405 | 不是 POST |
| 429 | 限流 |
| 502 | 反代的上游不可达 |

## 配套文件

**速通只需要两个文件**：`server/setup-server.ps1`（Windows 云电脑）或 `server/setup-server.sh`（Linux） + `client/setup.py`（本机）。其余是手工版、可选接入与维护用。

| 文件 | 用在哪 | 作用 |
|---|---|---|
| `server/setup-server.ps1` | 服务器（Windows） | **一键脚本，自包含**：内嵌网关代码，自动完成目录 / 令牌 / 配置 / 自启 / 看门狗 / 自检 / 交接文件；`-Status` `-Check` `-Uninstall` |
| `server/setup-server.sh` | 服务器（Linux / macOS） | 同上，systemd 版；无 systemd 时加 `--no-service` |
| `server/keepalive.ps1` | 服务器（可选） | 会话级保活：抑制空闲睡眠、否决普通关机；由 `-KeepAlive` 安装，边界见 [保活与平台定时重启](03-keepalive.md) |
| `server/make-onefile.py` | 维护者 | 改了 `gateway.js` / `keepalive.ps1` 后，重新生成自包含 `setup-server.ps1` |
| `server/setup-server.template.ps1` | 维护者 | 一键脚本的逻辑模板，供上一条生成脚本使用 |
| `client/setup.py` | 本机 / AI Agent | **一键脚本**：写 0600 令牌、生成 MCP / OpenAPI / 提示词、合并客户端配置、跑 8 项验证 |
| `server/gateway.js` | 服务器 | 通用网关，零依赖，含鉴权 / 白名单 / 审计 / 反代 / 命令护栏 |
| `server/config.example.json` | 服务器 | 配置模板，复制成 `config.json` 后填写 |
| `client/bridge.py` | 本机 | 通用命令行客户端，零第三方依赖 |
| `client/mcp-bridge.js` | 本机 | MCP stdio 桥，给支持 MCP 的 AI 客户端 |
| `client/mcp.example.json` | 本机 | MCP 配置模板 |
| `client/openapi.example.yaml` | 本机 / AI 客户端 | 自定义动作 / 函数调用用的 OpenAPI 描述 |

## 常见疑问

**为什么不直接开远程桌面？** 封装式云电脑通常没有公网 IP、也不开放 RDP 端口；桌面链接是一次性、有连接数上限、空闲会关。GUI 自动化既不稳也不可审计。

**为什么非要隧道？** 网关只绑回环地址是最安全的选择；隧道负责把公网请求安全地送进回环口。云端 AI 客户端也访问不到 `127.0.0.1`。

**令牌丢了 / 泄露了怎么办？** 立刻改服务端 `config.json` 的 `token` → 重启网关 → 同步所有客户端 → 确认旧令牌返回 401 → 翻审计日志看有无异常调用。

**能不能不开启命令执行？** 可以。文件读写、系统信息、审计日志都不依赖 `execEnabled`，安全性高得多。只在确实需要远程跑命令时再开。

**大文件怎么办？** 先在服务器侧用命令压缩 / 切片到白名单目录，再分次 `read`；或直接走厂商提供的文件通道。

**能不能给多个人用？** 本网关是单令牌、无 RBAC。多人使用请自行加一层带各自凭据的代理，或改用官方多用户方案。

**一小时重启一次能不能根治？** 不能。宿主层强制断电 / 重置绕过 Windows，虚拟机内部拦不住。本方案的保活解决的是「重启后自动恢复」，实测断线窗口约 1～2 分钟，细节与验证方法见 [保活与平台定时重启](03-keepalive.md)。会话级 `-KeepAlive` 只挡普通关机与空闲睡眠，且会挡住系统更新重启，默认不安装。

**两步脚本跑失败了怎么办？** 第 1 步看 `setup.log` 与 `-Status`；第 2 步看 `RESULT` 里哪一项 FAIL。最常见三个原因：服务器没装 Node 18+（传 `-NodeExe`）、隧道地址没填（补 `--url`）、令牌或地址两端不一致（重新复制交接文件再跑一次第 2 步）。脚本是幂等的，参数不变重跑不会破坏已有配置；令牌只在加 `-RotateToken` / `--rotate-token` 时才换。
