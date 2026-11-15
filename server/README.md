# server — 部署在远程服务器上

网关本体与部署脚本。所有文件都不需要联网下载，也不依赖第三方模块。

| 文件 | 用途 |
|---|---|
| `gateway.js` | 网关本体。Node 18+，零第三方依赖。含鉴权、限流、路径白名单、命令护栏、审计日志、反向代理 |
| `config.example.json` | 配置模板，复制成 `config.json` 后填写 |
| `setup-server.ps1` | **Windows 一键部署**，自包含（已内嵌网关与保活脚本），单文件即可完成全部配置 |
| `setup-server.sh` | **Linux / macOS 一键部署**，注册 systemd 服务与定时器；无 systemd 时用 `--no-service` |
| `setup-server.template.ps1` | 一键脚本的逻辑模板，供 `make-onefile.py` 生成上一项。**不要直接运行** |
| `keepalive.ps1` | 可选会话保活：抑制空闲睡眠、否决普通关机 / 注销 |
| `make-onefile.py` | 维护者工具：改了 `gateway.js` 或 `keepalive.ps1` 后重新生成 `setup-server.ps1` |

## 一键部署

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-server.ps1 -TunnelCommand 'ngrok http 8787' -EnableExec
```

```bash
sudo bash setup-server.sh --enable-exec --tunnel-command 'ngrok http 8787'
```

脚本是幂等的：参数不变重跑不会破坏已有配置，令牌只在显式要求轮换时才更换。

### Windows 参数

| 参数 | 默认值 | 说明 |
|---|---|---|
| `-BridgeDir` | `C:\srv\bridge` | 网关与配置目录 |
| `-DataDir` | `C:\srv\data` | 允许被访问的数据目录 |
| `-LogDir` | `C:\srv\logs` | 日志目录 |
| `-Port` | `8787` | 网关回环端口 |
| `-ProxyPort` | `0` | 反代目标端口，`0` 表示不启用反代 |
| `-NodeExe` | 自动探测 | Node 不在 PATH 时显式指定 `node.exe` 绝对路径 |
| `-TunnelCommand` | 空 | 隧道命令，例如 `ngrok http 8787` |
| `-TunnelUrl` | 空 | 已知公网地址；不传则尝试从隧道本地 API 读取 |
| `-TaskPrefix` | `RemoteBridge` | 计划任务名前缀，同时决定任务名 |
| `-Token` | 空 | 指定令牌（64 位十六进制）；留空则自动生成 |
| `-HandoffPath` | 空 | 交接文件输出路径，默认 `<BridgeDir>\bridge-handoff.json` |
| `-EnableExec` / `-DisableExec` | 关闭 | 是否允许远程执行命令 |
| `-KeepAlive` | 未安装 | 安装会话保活任务 |
| `-RotateToken` | 否 | 轮换令牌 |
| `-Status` | — | 打印任务状态、`health`、401 自检、隧道地址、最近日志 |
| `-Check` | — | 看门狗动作，由计划任务每分钟调用；也可手工执行 |
| `-Uninstall` | — | 只停用并注销本脚本创建的计划任务，不删数据目录 |

### Linux 参数

`--dir` `--data` `--logs` `--port` `--proxy-port` `--node` `--tunnel-command` `--tunnel-url` `--token` `--enable-exec` `--disable-exec` `--rotate-token` `--no-service` `--check` `--status` `--uninstall`，与上表一一对应。

## 手工部署

不用一键脚本时，按[服务器端配置（手工版）](../docs/02-server-setup.md)逐步执行：建目录、生成令牌、写配置、放网关并 `node --check`、前台试跑、注册自启、打通隧道、从外部验收。

## 配置要点

| 字段 | 说明 |
|---|---|
| `token` | 64 位十六进制随机串。只放在这里和客户端 `0600` 文件 |
| `port` / `proxyPort` | 网关端口；反代目标端口，`0` 为不启用 |
| `home` | 网关目录绝对路径，审计日志与备份写在它下面 |
| `roots` | 允许访问的目录，键名随意，值必须是**已存在的绝对路径** |
| `execEnabled` | 命令执行总开关，默认 `false` |
| `shells` | 按系统配置：Windows 用 `powershell` / `ps32` / `cmd`，Linux 用 `sh` |
| `execDeny` / `execAllow` | 命令黑名单 / 白名单正则；`execAllow` 为空表示不额外限制 |
| `denyRead` / `denyWrite` | 白名单内的额外拒绝规则，模板默认拒绝配置与私钥类文件 |

## 改了代码之后

```bash
python3 make-onefile.py
```

它会把 `gateway.js` 与 `keepalive.ps1` 以 base64 重新嵌入 `setup-server.ps1`，并回读校验字节是否完全一致。**忘记这一步会导致一键脚本里跑的还是旧版网关。** CI 会检查两者是否同步。

## 卸载

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-server.ps1 -Uninstall
```

```bash
sudo bash setup-server.sh --uninstall
```

只注销任务与服务，配置、日志和备份保留，需要时自行删除目录。
