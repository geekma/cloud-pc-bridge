'use strict';
/* MCP stdio bridge for ANY MCP-capable client (WorkBuddy, Claude Desktop,
 * Cursor, Cline, ChatGPT desktop integrations, custom agents...).
 * Zero dependencies, Node 18+. Token is read from the environment or a 0600
 * file - never from the MCP config.
 *
 *   BRIDGE_URL=https://<tunnel-host> BRIDGE_TOKEN=<token> node mcp-bridge.js
 */
const fs = require('fs');
const os = require('os');
const path = require('path');

const TOKEN_FILE = process.env.BRIDGE_TOKEN_FILE ||
  path.join(os.homedir(), '.config', 'remote-bridge', 'token');

function baseUrl() {
  return (process.env.BRIDGE_URL || '').replace(/\/+$/, '');
}
function token() {
  const t = (process.env.BRIDGE_TOKEN || '').trim();
  if (t) return t;
  try { return fs.readFileSync(TOKEN_FILE, 'utf8').trim(); } catch (_) { return ''; }
}
const sleep = ms => new Promise(r => setTimeout(r, ms));

async function call(action, payload, opts = {}) {
  if (!baseUrl()) throw new Error('BRIDGE_URL is not set');
  if (!token()) throw new Error('BRIDGE_TOKEN is not set (or token file missing: ' + TOKEN_FILE + ')');
  const headers = {
    'Authorization': 'Bearer ' + token(),
    'Content-Type': 'application/json',
    'User-Agent': 'generic-remote-bridge-mcp/1.0',
  };
  if (baseUrl().includes('ngrok')) headers['ngrok-skip-browser-warning'] = 'true';
  const attempts = opts.attempts || 3;
  let last;
  for (let i = 1; i <= attempts; i++) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), opts.timeoutMs || 60000);
    try {
      const res = await fetch(baseUrl() + '/__agent/' + action, {
        method: 'POST', headers, body: JSON.stringify(payload || {}), signal: controller.signal,
      });
      clearTimeout(timer);
      const text = await res.text();
      let data;
      try { data = JSON.parse(text); } catch (_) { data = { ok: false, raw: text.slice(0, 2000) }; }
      if (![502, 503, 504].includes(res.status)) return { _http: res.status, ...data };
      last = new Error('HTTP ' + res.status);
    } catch (e) { last = e; }
    finally { clearTimeout(timer); }
    if (i < attempts) await sleep(800 * i);
  }
  throw new Error('RETRY_EXHAUSTED ' + action + ': ' + (last && last.message));
}

const TOOLS = [
  { name: 'bridge_health', description: '检查远程网关是否在线、版本、白名单根目录、命令执行是否开启',
    inputSchema: { type: 'object', properties: {} } },
  { name: 'bridge_sysinfo', description: '读取远程服务器系统信息：平台、CPU 数、内存、运行时间、负载',
    inputSchema: { type: 'object', properties: {} } },
  { name: 'bridge_list', description: '列出远程服务器上白名单目录内的文件（必须传绝对路径）',
    inputSchema: { type: 'object', properties: { path: { type: 'string' } }, required: ['path'] } },
  { name: 'bridge_read', description: '读取远程服务器白名单内文件；中文/二进制内容请用 encoding=base64 取原始字节',
    inputSchema: { type: 'object', properties: {
      path: { type: 'string' }, maxBytes: { type: 'number' },
      encoding: { type: 'string', enum: ['utf8', 'base64', 'latin1', 'hex'] } }, required: ['path'] } },
  { name: 'bridge_write', description: '写远程服务器白名单内文件（写前自动备份）；二进制或中文请用 encoding=base64',
    inputSchema: { type: 'object', properties: {
      path: { type: 'string' }, content: { type: 'string' },
      encoding: { type: 'string', enum: ['utf8', 'base64', 'latin1', 'hex'] } }, required: ['path', 'content'] } },
  { name: 'bridge_exec', description: '在远程服务器执行 shell 命令（需服务端 execEnabled=true）。shell 名称见 bridge_health 返回的 shells',
    inputSchema: { type: 'object', properties: {
      command: { type: 'string' }, shell: { type: 'string' },
      cwd: { type: 'string' }, timeoutMs: { type: 'number' },
      env: { type: 'object' } }, required: ['command'] } },
  { name: 'bridge_log', description: '读取网关审计日志（每次调用的时间、来源 IP、动作、是否成功、耗时）',
    inputSchema: { type: 'object', properties: { lines: { type: 'number' } } } },
];

const ACTIONS = {
  bridge_health: 'health', bridge_sysinfo: 'sysinfo', bridge_list: 'list',
  bridge_read: 'read', bridge_write: 'write', bridge_exec: 'exec', bridge_log: 'log',
};

function send(obj) { process.stdout.write(JSON.stringify(obj) + '\n'); }

async function handle(msg) {
  const { id, method, params } = msg || {};
  try {
    if (method === 'initialize') return send({ jsonrpc: '2.0', id,
      result: { protocolVersion: (params && params.protocolVersion) || '2024-11-05',
                capabilities: { tools: {} },
                serverInfo: { name: 'generic-remote-bridge', version: '1.0.0' } } });
    if (method === 'notifications/initialized' || method === 'initialized') return;
    if (method === 'ping') return send({ jsonrpc: '2.0', id, result: {} });
    if (method === 'tools/list') return send({ jsonrpc: '2.0', id, result: { tools: TOOLS } });
    if (method === 'resources/list') return send({ jsonrpc: '2.0', id, result: { resources: [] } });
    if (method === 'prompts/list') return send({ jsonrpc: '2.0', id, result: { prompts: [] } });
    if (method === 'tools/call') {
      const name = params && params.name;
      const args = (params && params.arguments) || {};
      const action = ACTIONS[name];
      if (!action) throw new Error('unknown tool: ' + name);
      const timeoutMs = action === 'exec'
        ? Math.min(Math.max(Number(args.timeoutMs || 60000) + 30000, 30000), 630000) : 60000;
      const out = await call(action, args, { timeoutMs });
      return send({ jsonrpc: '2.0', id,
        result: { content: [{ type: 'text', text: JSON.stringify(out) }],
                  isError: out.ok === false || out._http >= 400 } });
    }
    if (id !== undefined) return send({ jsonrpc: '2.0', id,
      error: { code: -32601, message: 'Method not found: ' + method } });
  } catch (e) {
    if (method === 'tools/call') return send({ jsonrpc: '2.0', id,
      result: { content: [{ type: 'text', text: e.message }], isError: true } });
    return send({ jsonrpc: '2.0', id, error: { code: -32000, message: e.message } });
  }
}

process.stderr.write('generic-remote-bridge MCP ready, upstream=' + (baseUrl() || '<unset>') + '\n');
let buf = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => {
  buf += chunk;
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i).trim();
    buf = buf.slice(i + 1);
    if (!line) continue;
    try { handle(JSON.parse(line)); }
    catch (e) { process.stderr.write('bad JSON-RPC line: ' + e.message + '\n'); }
  }
});
