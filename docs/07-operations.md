# 运维手册：速查、安全、排错、验收

## 日常操作速查

| 想做什么 | 命令 |
|---|---|
| 看网关是否在线 | `python3 client/bridge.py health` |
| 看 CPU / 内存 / 运行时间 | `python3 client/bridge.py sysinfo` |
| 列目录 | `python3 client/bridge.py list /srv/data` |
| 读文本文件 | `python3 client/bridge.py read /srv/data/a.txt` |
| 读中文 / 二进制文件 | `python3 client/bridge.py read /srv/data/a.txt --encoding base64 --save ./a.txt` |
| 写文本 | `python3 client/bridge.py write /srv/data/a.txt --content '内容'` |
| 上传任意文件（字节精确） | `python3 client/bridge.py write /srv/data/a.zip --file ./a.zip` |
| 执行 PowerShell | `python3 client/bridge.py exec 'Get-Service | Select-Object -First 5' --shell powershell` |
| 执行 cmd | `python3 client/bridge.py exec 'dir C:\srv\data /b' --shell cmd` |
| 执行 Linux shell | `python3 client/bridge.py exec 'df -h' --shell sh` |
| 看谁在什么时候动了什么 | `python3 client/bridge.py log --lines 50` |
| 直接打任意动作 | `python3 client/bridge.py raw health '{}'` |

**中文乱码怎么办**：这是最高频问题。Windows 中文系统的传统程序输出常是 GBK / CP936，而现代工具默认 UTF-8。规则是 —— **原文什么编码就按什么编码取字节**：读文件用 `encoding=base64` 拿原始字节，再按 `gb18030` / `utf-8` 解码；写回时按原编码编码成字节再 base64 上传。配置里 `cmd` 的 `encoding` 设成 `gbk`、`powershell` 设成 `utf8`，就是为这个。

**32 位还是 64 位**：老数据库驱动（Jet / Access）和部分旧 COM 组件只存在于 32 位 PowerShell；IIS 管理模块通常在 64 位。配置里同时留 `powershell` 和 `ps32` 两个名字，按需选。

## 安全加固清单

- [ ] 令牌是随机生成的 64 位串，不是单词、生日、 reuse 的密码
- [ ] 令牌只存在于服务端 `config.json` 与本机的 0600 文件 / 环境变量
- [ ] 服务端 `config.json` 权限收紧（Linux `600` / Windows 仅管理员与 SYSTEM）
- [ ] 网关只监听 `127.0.0.1` / `::1`，没有绑 `0.0.0.0`
- [ ] `roots` 只包含必要目录；`denyRead` / `denyWrite` 已按业务补齐
- [ ] `execEnabled` 只在确实需要时为 `true`，且配好 `execDeny`（生产建议加 `execAllow`）
- [ ] 网关进程以最小权限账户运行，不是域管 / root（除非确实必须）
- [ ] 隧道有固定域名或访问控制；免费随机域名不要长期用于生产
- [ ] 每次变更配置前先备份，改完 `node --check` 再重启服务
- [ ] 换网关版本前做过临时端口预启动验证，且失败自动回滚脚本已就位（见 [变更时的安全做法](02-server-setup.md#变更时的安全做法)）
- [ ] 审计日志定期归档；`backups/` 定期清理
- [ ] 有开机自启 + 失败重启 + 隧道自启，且验证过一次「重启后仍能连上」
- [ ] 令牌轮换流程演练过：改服务端 → 重启 → 同步所有客户端 → 旧令牌返回 401
- [ ] 两步脚本生成的 `bridge-handoff.json` 在服务器与本机两端用完即删（本机用 `--consume-handoff`）
- [ ] 两步脚本第 2 步输出 `RESULT: OK`，8 项验证没有 FAIL
- [ ] 已按 [保活与平台定时重启](03-keepalive.md) 验证过一次「重启后无需人工干预自动恢复」
- [ ] `-KeepAlive` 只在确实需要时装；计划维护前执行 `keepalive.ps1 -Allow`，维护后 `-Deny`

---

## 故障排查

| 现象 | 先查 | 怎么办 |
|---|---|---|
| `401 unauthorized` | 令牌是否一致、有无空格 / 换行、是否已轮换 | 重新写入令牌文件；确认 `Authorization: Bearer ` 前缀 |
| 连接超时 / 502 / 503 | 隧道是否在线、服务器是否关机、网关进程是否活着 | 看保活任务；重启隧道与服务；客户端自带 3 次重试 |
| `429 rate limited` | 一分钟超过 180 次 | 加退避，别用重试硬撞 |
| `404 unknown action` | 动作名拼写、服务端版本 | 对照[接口契约](08-api-reference.md#接口契约速查) |
| `400 exec is disabled` | `execEnabled` | 改 `true` 并重启网关 |
| `400 path outside whitelist` | 用了相对路径或别名、路径拼错 | 一律用 `roots` 里的**绝对路径** |
| `400 command denied` | 命中 `execDeny` / 不在 `execAllow` | 改命令或调整策略，不要直接关掉护栏 |
| 中文乱码 | 编码不一致 | `encoding=base64` 取字节，按 `gb18030` / `utf-8` 解码；cmd 输出配 `gbk` |
| 命令没输出 / 卡住 | 交互式命令、需要 stdin、自提权 | 换非交互写法、设更短超时、看 `stderr` |
| 写入后内容不对 | 忘了自动备份 / 编码 | 到 `home/backups/<时间戳>/` 找原件 |
| 网站打不开了 | `proxyPort` 指错、Host 被改 | 检查 `proxyPort` / `proxyHost`；必要时把 `proxyPort` 设 `0` 先恢复控制面 |
| 重启后失联 | 自启 / 保活没配 | 按 [Step 6](02-server-setup.md#step-6--变成后台服务--保活) 补 systemd 或计划任务 |
| 重启命令报「无法识别为 cmdlet」/ 版本没变 | Windows 计划任务重启命令写错 | 用 `schtasks /End /TN <任务名>` + `schtasks /Run /TN <任务名>`，或 `Stop-ScheduledTask` + `Start-ScheduledTask`；不要写 `Restart-ScheduledTask` |
| 换了版本后隧道再也连不上 | 新版启动即崩，且无回滚 | 按 [变更时的安全做法](02-server-setup.md#变更时的安全做法) 用备份还原 `gateway.js` / `config.json` 并重启；事后务必补上预启动验证 |
| 一键脚本报 `Node.js 18+ not found` | 服务器没装 Node，或不在 PATH | 装 Node 18+；或传 `-NodeExe "<node.exe 绝对路径>"` / `--node <路径>` |
| 第 2 步 `RESULT: FAILED` | 隧道没起来、地址写错、令牌不一致、服务端没开 `exec` | 先看第 1 步输出与 `setup.log`；用 `--url` 补地址；`exec` 未开启时该项显示 SKIP 不算失败 |
| 交接文件里 `url` 为空 | 没给隧道命令 / 地址，ngrok 本地 API 查不到 | 本机命令补 `--url https://<你的隧道域名>`；或重跑第 1 步加 `-TunnelCommand` / `-TunnelUrl` |
| 免费隧道域名每次重启都变 | 免费版随机域名 | 换固定域名；变化后更新本机 `BRIDGE_URL`（重跑第 2 步即可），令牌不用换 |
| 平台重启后一直连不上 | L1 / L2 自启没生效，或隧道进程没被拉起 | 按 [保活与平台定时重启](03-keepalive.md) 用 `-Status` / `-Check` 查任务状态与 `setup.log`；确认登录自启、隧道自启、看门狗三者都在 |

---

## 完整验收清单

**服务器侧**

1. `node --check gateway.js` 无输出
2. `config.json` 权限 600 / 仅管理员可读，令牌不在别处
3. 前台启动能看到 `ready`
4. 本机 `curl 127.0.0.1:<端口>/__agent/health` 返回 `ok:true`
5. 后台服务已设为开机自启 + 失败重启
6. 隧道进程也已设为开机自启
7. 隧道域名可访问，`health` 返回 `ok:true`
8. 不带令牌返回 401

**本机侧**

9. 令牌文件权限 600，`BRIDGE_URL` 已设
10. `bridge.py health` / `sysinfo` 成功
11. `list` → `write` → `read` 闭环成功，内容一致
12. 中文 / 二进制 base64 往返不乱码
13. 白名单外路径被拒绝
14. `exec`（如已开启）能拿到退出码与输出，危险命令被拒绝，超时能生效
15. `log` 里能看到刚才每一步的审计记录
16. 至少一个非命令行客户端（自定义动作或 MCP）成功调用过

**两步脚本追加验收**

17. 第 1 步输出 `local health: OK` 与 `no-token returns: 401 OK`，`bridge-handoff.json` 已生成
18. 第 2 步输出 `RESULT: OK`，8 项验证无 FAIL（`exec` 未开启时为 SKIP）
19. `~/.config/remote-bridge/token` 权限 0600，且 MCP / OpenAPI / 提示词 / env 文件里都不含令牌
20. 一次真实重启后 3 分钟内 `health` 自动恢复，全程未登录服务器（[保活与平台定时重启](03-keepalive.md)）
