# 任意客户端接入

## 接入原理

### 原理

网关不理解「你是哪个 AI 工具」，它只看三样东西：令牌对不对、动作名是否存在、参数是否合规。所以：

> **只要能发出「HTTPS POST + 一个 Bearer 头 + JSON 体」的东西，就是合法客户端。**

### 客户端接入矩阵

| 客户端类型 | 举例 | 接入方式 | 需要准备 |
|---|---|---|---|
| 命令行 / 脚本 | curl、Python、Node、PowerShell、CI 任务 | 直接 POST，或 `bridge.py` | 令牌 + 地址 |
| 自建 Agent / 后端服务 | 自己的程序、工作流引擎、定时任务 | 把 `call(action, payload)` 封一个函数 | 同上 |
| 支持自定义动作 / 函数调用的 AI 客户端 | ChatGPT 自定义 GPT（Actions）、各类支持工具调用的助手 | 导入 `openapi.example.yaml`，认证填 Bearer 令牌 | 公网可达地址 + 令牌 |
| 支持 MCP 的 AI 客户端 | WorkBuddy、Claude Desktop、Cursor、Cline 等 | `mcp.example.json` 配一个 stdio server | Node + 令牌 |
| 只能聊天、不能发请求的客户端 | 任意纯对话窗口 | 让模型**生成命令**，你在本机执行后把 JSON 结果贴回去 | 只贴结果，不贴令牌 |
| 浏览器网页直接调用 | 前端 JS | 通常会被 CORS 与自定义头拦住，需自建同源代理 | 不推荐 |

### A 类：脚本与命令行

最通用、最不容易被产品变化影响。`bridge.py` 之外，任何语言十几行就能封一个客户端：

```python
import json, os, urllib.request

def remote(action, payload=None):
    req = urllib.request.Request(
        os.environ['BRIDGE_URL'] + '/__agent/' + action,
        data=json.dumps(payload or {}).encode(),
        headers={'Authorization': 'Bearer ' + os.environ['BRIDGE_TOKEN'],
                 'Content-Type': 'application/json'},
        method='POST')
    return json.load(urllib.request.urlopen(req, timeout=60))

print(remote('sysinfo'))
```

### B 类：支持自定义动作的大模型客户端

1. 把 `client/openapi.example.yaml` 里的 `<你的隧道域名>` 换成真实地址，导入客户端的「自定义动作 / 工具」配置。模板描述了 7 个动作（`health` / `sysinfo` / `list` / `read` / `write` / `exec` / `log`），与网关 handlers 和 MCP 工具一一对应。
2. 认证选 **Bearer / API key**，密钥填服务端 `config.json` 里的同一个令牌。
3. 之后直接用自然语言下指令，例如：「列出服务器上 `/srv/data` 目录，读 `hello.txt`，再查一下内存和运行时长」。

**三点提醒**：

- 云端模型只能访问**公网可达**的地址；`127.0.0.1`、内网 IP 都不行，所以隧道是必需的。
- 把令牌交给第三方 AI 服务 = 授权该服务访问你的服务器。只在你信任的服务上做，并定期轮换令牌。
- 若客户端不支持自定义动作，就走 [客户端接入矩阵](05-client-integration.md#客户端接入矩阵) 最后一行：让模型生成命令，你执行后把结果贴回去。

### C 类：支持 MCP 的客户端

`client/mcp.example.json` 是通用模板（不同客户端字段名略有差异，按其文档调整）：

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

令牌**不要写进这份配置**：用系统环境变量 `BRIDGE_TOKEN`，或 `~/.config/remote-bridge/token`（0600）。配置好后客户端会看到 7 个工具：`bridge_health` / `bridge_sysinfo` / `bridge_list` / `bridge_read` / `bridge_write` / `bridge_exec` / `bridge_log`。多数客户端需要重启或「信任 / 启用」新 server 才生效。

### 通用提示词模板

```
你有一台远程服务器，接口是 POST https://<网关地址>/__agent/<动作>，
头：Authorization: Bearer <令牌>、Content-Type: application/json。
动作：health / sysinfo / list / read / write / exec / log。
规则：
1. 只用绝对路径，且路径必须在 roots 白名单内；
2. 读中文或二进制文件用 encoding=base64 拿原始字节再解码；
3. exec 必须设 timeoutMs，禁止交互式命令；
4. 写文件前先 read 一次确认，写操作要说明会触发自动备份；
5. 每次操作后简述退出码与关键输出，不要复述令牌。
先跑 health 和 sysinfo，然后告诉我服务器状态。
```

> 把 `<令牌>` 写进提示词会留在对话记录里。更稳妥：让客户端从环境变量读，提示词里只写「从环境变量读取令牌」。
