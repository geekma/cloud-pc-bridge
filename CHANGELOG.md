# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 与 [语义化版本](https://semver.org/lang/zh-CN/)。

## [1.0.0] - 2026-11-15

首个公开版本。

### Added

- `server/gateway.js`：零依赖网关。鉴权（定长比较）、限流、路径白名单、读写备份、命令护栏、审计日志、可选反向代理。
- `server/config.example.json`：Windows 与 Linux 两套 shell 配置示例。
- `server/setup-server.ps1`：Windows 一键部署，自包含（内嵌网关与保活脚本），支持 `-Status` / `-Check` / `-Uninstall` / `-RotateToken` / `-KeepAlive`。
- `server/setup-server.sh`：Linux / macOS 一键部署，注册 systemd 服务与定时器，支持 `--no-service`。
- `server/setup-server.template.ps1` + `server/make-onefile.py`：一键脚本的模板与生成器，生成时回读校验内嵌字节一致性。
- `server/keepalive.ps1`：可选会话保活，抑制空闲睡眠、否决普通关机与注销，支持 `-Allow` / `-Deny` 维护放行。
- `client/setup.py`：本机一键配置。写 `0600` 令牌、生成 MCP / OpenAPI / 提示词、合并客户端配置（合并前备份）、跑 8 项验证。
- `client/bridge.py`：零依赖命令行客户端，覆盖 7 个动作，内置重试。
- `client/mcp-bridge.js`：MCP stdio 桥，暴露 7 个工具。
- `client/mcp.example.json`、`client/openapi.example.yaml`：客户端接入模板。
- 文档：背景与架构、服务器端配置、保活与平台定时重启、客户端配置、任意客户端接入、能力与限制、运维手册、接口契约。
- CI：语法检查、生成物一致性检查、端到端冒烟测试。

### Security

- 鉴权先于限流，未授权请求不消耗配额。
- 令牌使用密码学安全随机源生成；配置与私钥类文件默认禁读。
- 日志与状态输出中的 `Authorization` 脱敏。
- 命令执行默认关闭，需显式开启，受超时、输出上限与黑白名单约束。
