# client — 运行在本机

三个可选客户端加一个配置脚本。全部不需要第三方 Python 包或 Node 包。

| 文件 | 用途 |
|---|---|
| `setup.py` | **一键配置**：写令牌、生成 MCP / OpenAPI / 提示词、合并客户端配置、跑 8 项验证 |
| `bridge.py` | 零依赖命令行客户端，覆盖全部七个动作 |
| `mcp-bridge.js` | MCP stdio 桥，向支持 MCP 的客户端暴露 7 个工具 |
| `mcp.example.json` | MCP 配置模板（不同客户端字段名略有差异，按其文档调整） |
| `openapi.example.yaml` | OpenAPI 描述，供支持自定义动作 / 函数调用的客户端导入 |

## 一键配置

```bash
python3 setup.py --from ./bridge-handoff.json --consume-handoff
```

### 参数

| 参数 | 说明 |
|---|---|
| `--from <路径>` | 读取服务器生成的 `bridge-handoff.json` |
| `--url <地址>` | 公网网关地址；交接文件里没有时用它补 |
| `--token <令牌>` | 直接给令牌，**会留在 shell 历史里**，优先用 `--from` |
| `--token-file <路径>` | 从文件读令牌 |
| `--data-dir <路径>` | 服务器白名单里的目录，用于 `write` / `read` 往返测试 |
| `--mcp-config <路径>` | 把 `remote-server` 合并进已有 MCP 配置（合并前自动备份） |
| `--openapi-out <路径>` | OpenAPI 描述输出位置 |
| `--consume-handoff` | 读完后删除本机这份交接文件 |
| `--skip-verify` | 只写文件，不调用网关 |
| `--no-mcp` | 不生成 MCP 配置 |
| `--status` | 显示已存配置（**不会打印令牌**）与 `health` |
| `--uninstall` | 删除本机生成的配置，不动客户端自己的配置文件 |
| `--json` | 输出机器可读的汇总 |

生成位置：令牌 `~/.config/remote-bridge/token`（`0600`）、地址与环境文件、MCP / OpenAPI / 提示词。**令牌只写进令牌文件**，不进 MCP 配置、不进 OpenAPI、不进提示词、不进 `env`。

## 命令行客户端

地址与令牌从 `BRIDGE_URL` / `BRIDGE_TOKEN` 环境变量或 `~/.config/remote-bridge/` 读取，也可以用 `--url` 临时覆盖。

```bash
python3 bridge.py health
python3 bridge.py sysinfo
python3 bridge.py list /srv/data
python3 bridge.py read /srv/data/a.txt
python3 bridge.py read /srv/data/a.txt --encoding base64 --save ./a.txt
python3 bridge.py write /srv/data/a.txt --content 'hello'
python3 bridge.py write /srv/data/a.zip --file ./a.zip
python3 bridge.py exec 'Get-Service | Select-Object -First 5' --shell powershell
python3 bridge.py exec 'dir C:\srv\data /b' --shell cmd
python3 bridge.py exec 'df -h' --shell sh
python3 bridge.py log --lines 50
python3 bridge.py raw health '{}'
```

### 参数

| 参数 | 说明 |
|---|---|
| `--url` | 覆盖 `BRIDGE_URL` |
| `--encoding` | `utf8`（默认）/ `base64` / `latin1` / `hex` |
| `--max-bytes` | `read` 单次最大字节数，默认 262144 |
| `--content` / `--file` | `write` 的文本内容 / 本地源文件（按原始字节上传） |
| `--save` | `read` 结果保存到本地文件 |
| `--shell` | `exec` 使用的 shell 名，必须存在于服务端 `config.shells` |
| `--timeout` | `exec` 超时毫秒，默认 60000 |
| `--cwd` | `exec` 工作目录，必须在白名单内 |
| `--env` | `exec` 附加环境变量，JSON 对象 |
| `--lines` | `log` 返回的尾部行数，默认 50 |

## MCP 桥

```json
{
  "mcpServers": {
    "remote-server": {
      "type": "stdio",
      "command": "node",
      "args": ["<mcp-bridge.js 的绝对路径>"],
      "env": { "BRIDGE_URL": "https://<你的隧道域名>" }
    }
  }
}
```

令牌**不要写进这份配置**：用环境变量 `BRIDGE_TOKEN`，或 `~/.config/remote-bridge/token`。配置好后客户端会看到 7 个工具：`bridge_health` / `bridge_sysinfo` / `bridge_list` / `bridge_read` / `bridge_write` / `bridge_exec` / `bridge_log`。多数客户端需要重启或「信任 / 启用」新 server 才生效。

## 编码提示

Windows 中文系统的传统程序输出常是 GBK / CP936，而现代工具默认 UTF-8。规则是**原文什么编码就按什么编码取字节**：读文件用 `encoding=base64` 拿原始字节，再按 `gb18030` / `utf-8` 解码；写回时按原编码编码成字节再 base64 上传。服务端配置里 `cmd` 的 `encoding` 设 `gbk`、`powershell` 设 `utf8`，就是为这个。

旧数据库驱动（Jet / Access）与部分旧 COM 组件只在 32 位 PowerShell 里存在，IIS 管理模块通常在 64 位。服务端因此同时提供 `powershell` 与 `ps32` 两个名字。
