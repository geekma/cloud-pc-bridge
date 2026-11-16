# 保活与平台定时重启

## 现象与结论

**现象**：不少封装式云电脑由平台按空闲时长 / 会话状态回收实例。在一台实际机器上观察到约 1～1.5 小时一次的强制重置，间隔不固定；系统事件是 `Kernel-Power 41`（非正常断电），没有 `6006` / `1074` 这类正常关机记录。也就是说：不是 Windows 自己要重启，而是宿主机直接把虚拟机断电再拉起。

**能不能根治「一小时重启一次」**：**不能从虚拟机内部阻止**。宿主层的强制断电 / 重置绕过 Windows 的关机询问流程，任何脚本、`shutdown` 拦截、电源请求、模拟鼠标活动都拦不住。实测在一台机器上，会话级关机否决与电源请求全程处于 `ACTIVE` 状态，硬重启照样发生。**任何声称「装个脚本就永不重启」的方案都不可信。** 若平台提供控制台策略或「保持客户端连接」的会话保活规则，那属于平台侧设置，不属于本方案能控制的范围；本方案不承诺能改变平台策略。

**能解决的是什么**：解决「重启后失联、要人工重新连」的问题。目标是**无人值守自动恢复**，把断线窗口压到分钟级。一次实测时间线（已隐去机器信息）：

| 时刻 | 事件 |
|---|---|
| 17:32:27 | 宿主层硬重启（`Kernel-Power 41`） |
| 17:32:39 | 登录自启任务拉起网关进程（约 12 秒） |
| 17:33:45 | 看门狗发现隧道进程缺失，立即触发重建 |
| 17:34:04 | 隧道进程启动 |
| 17:34:11 | 公网 `health` 返回 200（距重启约 **104 秒**） |
| 17:39:55 | 公网探测超时一次 |
| 17:40:11 | 看门狗确认 URL 恢复（约 **16 秒** 自愈） |

同期状态文件记录累计 14 次自动重启、700+ 次心跳、连续失败数为 0，说明进程级与公网级自愈都在工作。

## 四层保活机制

一键脚本已全部装好，无需手工配置。

这四层有个共同前提：**实例正在运行**。实例被平台休眠或关机后，Windows 里没有任何进程在跑，四层全部停摆，公网只剩超时。那种情况不属于保活范围，处理方式见[冷启动与唤醒](09-cold-start.md)。

| 层 | 机制 | 解决什么 | Windows 实现 | Linux 实现 |
|---|---|---|---|---|
| L1 开机 / 进程 | 登录自启（需自动登录）+ 周期重复，`IgnoreNew` 避免重复实例 | 整机会被重置、进程被杀 | `<前缀>-Gateway` 计划任务：登录触发 + 每 5 分钟重复；无自动登录时改 SYSTEM + 开机触发 | systemd `Restart=always` + `enable` |
| L2 健康 / 隧道 | 每分钟打一次 `health`；公网 URL 不通则重启隧道，带 60 秒冷却 | 网关假死、隧道抖动、域名恢复慢 | `<前缀>-Watchdog` 任务运行 `setup-server.ps1 -Check` | `remote-bridge-check.timer` 运行 `setup-server.sh --check` |
| L3 会话（可选） | 抑制空闲睡眠、否决普通关机 / 注销 | 「空闲自动睡眠」「计划关机」这类**经过 Windows** 的请求 | `setup-server.ps1 -KeepAlive` 安装 `keepalive.ps1` | 一般不需要（systemd 已覆盖） |
| L4 客户端 | 请求失败自动重试 + 退避；提示词要求重启窗口内等待最多 3 分钟 | 恢复期内请求失败 | `bridge.py` / `mcp-bridge.js` 内置 3 次重试 | 同左 |

**L3 的边界**：`keepalive.ps1` 只能挡 `WM_QUERYENDSESSION` 流程内的普通关机，挡不住 `shutdown /f`、宿主断电、平台回收；它还会连带挡住 Windows Update 重启和手工关机。维护前执行 `powershell -Sta -File keepalive.ps1 -Allow`，维护后 `-Deny`。**默认不安装**，需要才加 `-KeepAlive`。

## 验证保活是否正常

```powershell
# [服务器] 看任务状态、health、401、隧道地址、最近日志
powershell -ExecutionPolicy Bypass -File .\setup-server.ps1 -Status -BridgeDir "C:\srv\bridge" -TaskPrefix "RemoteBridge"
# [服务器] 手动跑一次看门狗逻辑（正常时无输出，失败时写 setup.log）
powershell -ExecutionPolicy Bypass -File .\setup-server.ps1 -Check  -BridgeDir "C:\srv\bridge" -TaskPrefix "RemoteBridge"
# [服务器] 看平台重启证据：41 = 宿主层硬重启
Get-WinEvent -FilterHashtable @{LogName='System'; Id=41,6006,1074; StartTime=(Get-Date).AddHours(-8)} | Select-Object TimeCreated, Id
```

```bash
# [本机] 重启窗口内连续观察，恢复后应立刻变回 ok:true
python3 client/bridge.py health
python3 client/bridge.py log --lines 30
```

最硬的验收是：等平台自然重启一次（或在不影响业务时手工重启），在自动登录已开启的前提下不登录服务器、不敲任何命令，隔两三分钟从本机再打 `health`，应自动恢复；`log` 里能看到恢复后的新调用，网关进程 PID 会变化。手工重启前请确认[安全加固清单](07-operations.md#安全加固清单)已打勾。

## 降低重启频率的可选做法

以下做法都不属于根治，只能降低触发频率。保持厂商客户端连接或会话活跃（部分平台按空闲判定）、在平台控制台调整策略（若有该能力）、用固定域名的隧道以免免费域名每次重启变化、客户端一律配置自动重试。即便全部做到，也要按「随时会被重置」设计：长任务写检查点、结果落盘再读，不要依赖进程长期存活。

**一句话**：保活 ≠ 永不重启。本方案保的是「重启后不用人管，几分钟内自己回来」。
