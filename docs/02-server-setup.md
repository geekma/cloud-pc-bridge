# 服务器端配置（手工版）

## 八个步骤

> 用「速通」两步脚本时，本节 8 步已由 `server/setup-server.ps1`（Windows）或 `server/setup-server.sh`（Linux）自动完成。本节作为原理说明、自定义调整与排错手册保留。

### Step 1 — 建目录 `[服务器]`

Windows（PowerShell）：

```powershell
New-Item -ItemType Directory -Force -Path 'C:\srv\bridge','C:\srv\data','C:\srv\logs' | Out-Null
```

Linux / macOS：

```bash
sudo mkdir -p /srv/bridge /srv/data /srv/logs && sudo chown -R "$USER" /srv/bridge /srv/data /srv/logs
```

目录用途：`bridge` 放网关与配置、`data` 是允许被访问的数据目录、`logs` 放日志。路径随便改，但后面所有配置要一致。

### Step 2 — 生成令牌 `[服务器]`

```powershell
# Windows PowerShell（用密码学安全随机数，不要用 Get-Random 拼令牌）
$b = New-Object byte[] 32
[System.Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($b)
-join ($b | ForEach-Object { $_.ToString('x2') })
```

```bash
# Linux / macOS（推荐）
openssl rand -hex 32
```

得到一串 64 位十六进制字符，记作 `<令牌>`。**只在服务器上写进配置、在本机写进 0600 文件**，不要贴进聊天、文档、代码仓库或 MCP 配置。

### Step 3 — 写配置 `[服务器]`

把 `server/config.example.json` 复制成 `server/config.json`（和 `gateway.js` 放同一目录），至少改这几项：

| 字段 | 填什么 |
|---|---|
| `token` | Step 2 生成的 `<令牌>` |
| `port` | 网关端口，示例 `8787`，可改 |
| `proxyPort` | 服务器上已有网站的本地端口；不需要反代就填 `0` |
| `home` | Step 1 的 `bridge` 目录绝对路径 |
| `roots` | 允许访问的目录，键名随便取，值必须是**绝对路径** |
| `execEnabled` | 先保持 `false`；等 [本机配置](04-client-setup.md) 验收通过再考虑打开 |
| `shells` | 按系统选：Windows 用 `powershell` / `ps32` / `cmd`；Linux 用 `sh` |

> `roots` 里每个目录都必须**真实存在**，键名就是给客户端看的分组名，随便取。模板里默认三个键与 Step 1 建的目录一致；要加目录就先建好再写进来。

最小可用配置（**Linux 版**，最易上手）：

```json
{
  "token": "<令牌>",
  "port": 8787,
  "proxyPort": 0,
  "home": "/srv/bridge",
  "roots": { "data": "/srv/data", "logs": "/srv/logs", "bridge": "/srv/bridge" },
  "execEnabled": false,
  "defaultShell": "sh",
  "shells": { "sh": { "exe": "/bin/sh", "args": ["-c", "{cmd}"], "encoding": "utf8" } }
}
```

**Windows 版**只需把路径换成 `C:\\srv\\...`（JSON 里反斜杠要写两个），`shells` 换成示例文件里的 `powershell` / `ps32` / `cmd` 三段。

> `execAllow` 留空数组表示「不额外限制」；填了正则就变成**只允许**匹配的命令，生产环境建议填。

### Step 4 — 放网关并做语法检查 `[服务器]`

把 `server/gateway.js` 放到 `bridge` 目录：

```bash
node --check /srv/bridge/gateway.js     # 无输出 = 语法 OK
```

配置文件权限收紧：

```bash
chmod 600 /srv/bridge/config.json       # Linux
```

```powershell
# Windows：用内置 SID（不受系统语言影响）只授权内置管理员组与 SYSTEM
# *S-1-5-32-544 = 内置管理员组，*S-1-5-18 = SYSTEM
icacls C:\srv\bridge\config.json /inheritance:r /grant:r "*S-1-5-32-544:F" "*S-1-5-18:F"
```

### Step 5 — 前台试跑 + 服务器本机自测 `[服务器]`

```bash
node /srv/bridge/gateway.js
# 看到 "[gateway] 127.0.0.1:8787 ready" 就对了
```

另开一个终端，**在服务器本机**测（此时还没隧道）：

```bash
curl -s -X POST http://127.0.0.1:8787/__agent/health \
  -H 'Authorization: Bearer <令牌>' -H 'Content-Type: application/json' -d '{}'
```

期望返回含 `"ok":true` 的 JSON。命令执行先别测：`execEnabled` 默认是关的，开启与变更流程见下面「变更时的安全做法」小节。确认无误后 `Ctrl+C` 停掉前台进程，进入 Step 6。

### Step 6 — 变成后台服务 + 保活 `[服务器]`

**Linux（systemd）**：新建 `/etc/systemd/system/remote-bridge.service`

```ini
[Unit]
Description=Remote control gateway
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/node /srv/bridge/gateway.js
WorkingDirectory=/srv/bridge
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now remote-bridge
systemctl status remote-bridge
```

**Windows（计划任务）**：用「任务计划程序」新建任务（名字自定，下文记作 `<任务名>`），触发器选「计算机启动时」，操作为 `node.exe` 加参数 `C:\srv\bridge\gateway.js`，勾选「不管用户是否登录都要运行」+「以最高权限运行」；在「设置」里勾「任务失败时重新启动」（间隔 1 分钟，最多 9999 次）。

以后改了配置要重启网关，用下面两条（`schtasks.exe` 在所有 Windows 版本都有）：

```powershell
schtasks /End /TN '<任务名>'
schtasks /Run /TN '<任务名>'
```

也可以用 `Stop-ScheduledTask -TaskName '<任务名>'` + `Start-ScheduledTask -TaskName '<任务名>'`。**注意：PowerShell 没有 `Restart-ScheduledTask` 这个 cmdlet**，写进脚本会直接报「无法识别为 cmdlet」，导致服务没重启、配置也没生效。

> 很多封装式云电脑会被平台定时强制关机 / 重启。**保活任务不是可选项**：开机自启 + 失败重启 + 隧道自启，三者都要有，否则过一会儿就失联。

### Step 7 — 打通公网隧道 `[服务器]`

二选一（示例值，按需替换）：

```bash
# 方案 A：ngrok（免费版域名每次启动会变）
ngrok http 8787

# 方案 B：Cloudflare Tunnel（可绑定固定域名，更适合长期使用）
cloudflared tunnel --url http://127.0.0.1:8787
```

拿到 `https://<你的隧道域名>`，记作 `<网关地址>`。隧道进程同样要注册成开机自启的服务。

> 免费版 ngrok 对浏览器访问会插一个警告页，所以客户端请求要带 `ngrok-skip-browser-warning: true` 头（配套客户端已自动处理）。生产建议固定域名 + 访问认证。

### Step 8 — 从外部验收 `[本机]`

```bash
curl -s -X POST https://<你的隧道域名>/__agent/health \
  -H 'Authorization: Bearer <令牌>' \
  -H 'Content-Type: application/json' \
  -H 'ngrok-skip-browser-warning: true' -d '{}'
```

看到 `"ok":true` 即全链路打通。不带令牌应返回 `401 unauthorized` —— 这条也要验，说明鉴权生效。

> **命令执行开关**：默认 `execEnabled:false`，此时 `/__agent/exec` 会返回「exec is disabled」。确认文件读写都正常、且你确实需要远程执行命令后，改成 `true` 并重启网关服务。开启前请读 [安全加固清单](07-operations.md#安全加固清单) 与下面的 [变更时的安全做法](02-server-setup.md#变更时的安全做法)。

### 变更时的安全做法 `[服务器]`

这三类变更都要**重启进程**才生效，重启会短暂断隧道，别在业务高峰做。推荐顺序：

1. **先预启动验证**：复制一份新版 `gateway.js`，只把配置路径和端口改成临时值（例如 `18787`），用服务器本机 Node 启动；POST `health` 确认版本与 `execEnabled`，再打一条无害命令验证 `exec`；然后停掉临时进程、删掉临时配置。**全程不碰正在跑的服务**。
2. **备份 + 语法检查**：备份当前 `gateway.js` 与 `config.json`；`node --check <新版>.js` 无输出才算通过。
3. **切换文件与配置**：覆盖 `gateway.js`、写入新 `config.json`。
4. **让重启脱离当前请求**：若重启命令是从网关自己的远程执行通道发起的，务必用 `Start-Process` 拉一个独立脚本并延时十几秒再重启 —— 否则那个 HTTP 请求会被自己掐断，后面的自检与回滚都跑不完。
5. **重启 + 自检 + 自动回滚**：按 [Step 6](02-server-setup.md#step-6--变成后台服务--保活) 的正确命令重启；脚本在服务器本机循环 POST `health`，确认 `version` / `execEnabled` 符合预期；**超时未确认就自动还原备份文件并重启**。
6. **外部复验**：从本机再打一次 `health`、一条只读命令、一次不带令牌的请求（应 401），并确认原有网站仍可访问。

> 第 1、5 步不是形式主义。两类常见失败：重启命令写错（Windows **没有** `Restart-ScheduledTask`），会留下「文件已换、进程没换」的半吊子状态；新版启动即崩，会让隧道彻底失联且**无法远程修复**。预启动验证 + 自动回滚，是无需登录服务器就能保住通道的唯一保险。
