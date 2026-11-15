# 参与贡献

欢迎 issue 与 pull request。改动涉及远程控制与凭据，请优先保证「默认安全」，其次才是功能。

## 开发环境

- Node.js 18+（网关与 MCP 桥）
- Python 3.8+（命令行客户端与一键配置脚本）
- Windows 侧脚本用 PowerShell 5.1 验证；Linux 侧脚本用 `bash -n` 与 `shellcheck` 验证

仓库没有任何构建步骤，也没有第三方运行时依赖。请保持这一点：新增依赖前先在 issue 里讨论。

## 改动流程

```bash
git clone https://github.com/<owner>/cloud-pc-bridge.git
cd cloud-pc-bridge
git switch -c fix/short-description
```

改动 `server/gateway.js` 或 `server/keepalive.ps1` 后**必须**重新生成自包含脚本：

```bash
python3 server/make-onefile.py
```

生成器会回读校验内嵌字节是否与源文件完全一致。忘记这一步，一键脚本里跑的还是旧代码。

## 提交前自检

```bash
node --check server/gateway.js
node --check client/mcp-bridge.js
python3 -m py_compile client/bridge.py client/setup.py server/make-onefile.py
bash -n server/setup-server.sh
python3 server/make-onefile.py && git diff --exit-code -- server/setup-server.ps1
```

如果改了网关行为，请在本地起一个临时实例做端到端验证（临时端口 + 临时目录 + 临时令牌），至少覆盖：`health`、无令牌 401、`list`、`write`/`read` 往返、`log`、以及 `exec` 的开关、拒绝与超时。

## 提交信息

使用 Conventional Commits：

```
feat(gateway): add read-only mode for auditing
fix(setup): use named mutex for cross-process log writes
docs(keepalive): clarify auto-logon requirement
chore(ci): check onefile sync
```

## PR 检查项

- [ ] 没有引入第三方运行时依赖
- [ ] 新增或修改的能力有对应的文档段落
- [ ] 安全默认值没有被放宽（回环绑定、令牌校验顺序、白名单、命令默认关闭）
- [ ] `make-onefile.py` 已重新运行，`setup-server.ps1` 与源文件同步
- [ ] 没有提交真实令牌、域名、IP、主机名、账号或业务路径
- [ ] 示例与文档里的占位符仍使用 `<尖括号>`

## 文档风格

- 面向没搭过服务器的读者，先给命令再解释原理。
- 命令块标注执行位置：`[服务器]` / `[本机]`。
- 数值、限制、超时写具体值，不写「较快」「较大」。
- 承诺要可验证：给验收命令与期望输出，避免「一定成功」这类表述。
