# 客户端配置（手工版）

## 五个步骤

> 用「速通」两步脚本时，本节 5 步已由 `client/setup.py` 自动完成，且会额外跑一遍 8 项验证。本节作为原理说明与手工排错手册保留。

### Step 1 — 把令牌放好 `[本机]`

```bash
mkdir -p ~/.config/remote-bridge && chmod 700 ~/.config/remote-bridge
printf '%s' '<令牌>' > ~/.config/remote-bridge/token
chmod 600 ~/.config/remote-bridge/token
```

Windows 可用「当前用户专用目录」并只给自己 ACL；或临时用环境变量：

```bash
export BRIDGE_TOKEN='<令牌>'        # macOS / Linux
$env:BRIDGE_TOKEN = '<令牌>'         # PowerShell
```

### Step 2 — 设置地址 `[本机]`

```bash
export BRIDGE_URL='https://<你的隧道域名>'
```

### Step 3 — 装客户端（任选其一，也可都不装） `[本机]`

| 想要什么 | 用哪个文件 | 依赖 |
|---|---|---|
| 命令行直接操作 | `client/bridge.py` | Python 3.8+，零第三方库 |
| 让支持 MCP 的 AI 客户端自动调用 | `client/mcp-bridge.js` | Node 18+ |
| 让支持自定义动作的 AI 客户端调用 | `client/openapi.example.yaml` | 客户端支持 OpenAPI 动作 |
| 什么都不装 | 直接 `curl` | 只有 curl |

### Step 4 — 跑通七个动作 `[本机]`

> 第 6 条 `exec` 需要先按 [变更时的安全做法](02-server-setup.md#变更时的安全做法) 把 `execEnabled` 打开；未开启时它会返回 `400 exec is disabled`，其余六条不受影响。

```bash
python3 client/bridge.py health
python3 client/bridge.py sysinfo
python3 client/bridge.py list /srv/data
python3 client/bridge.py write /srv/data/hello.txt --content 'hello from anywhere'
python3 client/bridge.py read  /srv/data/hello.txt
python3 client/bridge.py exec 'whoami' --shell sh
python3 client/bridge.py log --lines 10
```

Windows 服务器把 `sh` 换成 `powershell` 或 `cmd`，路径换成 `C:\srv\data`。

### Step 5 — 记下接口契约

所有能力都是同一个地址加不同路径：`POST https://<网关地址>/__agent/<动作>`，请求体是 JSON，响应是 JSON。速查表见[接口契约](08-api-reference.md#接口契约速查)。**记住这一句，就不需要任何专用客户端**。
