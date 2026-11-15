'use strict';
/* ------------------------------------------------------------------------- *
 * Generic remote-control gateway. Zero dependencies. Node 18+.
 *
 * Runs ON the remote server, listens on loopback ONLY. Public reachability is
 * provided separately by a tunnel (ngrok / cloudflared / FRP / reverse proxy).
 *
 *   /__agent/<action>  -> authenticated JSON control API
 *   everything else    -> optional reverse proxy to a local web server
 *
 * Config: config.json next to this file, or BRIDGE_CONFIG=/path/to/config.json
 * See config.example.json. No credentials are ever hard-coded here.
 * ------------------------------------------------------------------------- */

const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const { spawn } = require('child_process');

const CONFIG_PATH = process.env.BRIDGE_CONFIG || path.join(__dirname, 'config.json');
let CFG;
try {
  CFG = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
} catch (e) {
  console.error('[FATAL] cannot read config ' + CONFIG_PATH + ': ' + e.message);
  process.exit(1);
}

const TOKEN = String(CFG.token || '');
const PORT = Number(CFG.port || 8787);
const PROXY_PORT = Number(CFG.proxyPort || 0);
const HOME = path.resolve(CFG.home || __dirname);
const AUDIT = path.join(HOME, 'audit.log');
const BACKUP = path.join(HOME, 'backups');
const RATE = Number(CFG.rateLimitPerMinute || 180);
const MAX_BODY = Number(CFG.maxBodyBytes || 5 * 1024 * 1024);

const ROOTS = {};
for (const [k, v] of Object.entries(CFG.roots || {})) ROOTS[k] = path.resolve(v);
if (TOKEN.length < 32) { console.error('[FATAL] token too short (use 64 hex chars)'); process.exit(1); }
if (!Object.keys(ROOTS).length) { console.error('[FATAL] roots is empty'); process.exit(1); }

const rx = list => (Array.isArray(list) ? list : []).map(s => {
  try { return new RegExp(s, 'i'); } catch (e) { console.error('[WARN] bad regex skipped: ' + s); return null; }
}).filter(Boolean);
const DENY_WRITE = rx(CFG.denyWrite);
const DENY_READ = rx(CFG.denyRead && CFG.denyRead.length ? CFG.denyRead : [
  '[\\\\/]config\\.json$', '\\.(key|pem|pfx|p12)$', '[\\\\/]id_rsa', '[\\\\/]\\.ssh[\\\\/]'
]);
const EXEC_DENY = rx(CFG.execDeny && CFG.execDeny.length ? CFG.execDeny : [
  '\\bformat\\s+[a-z]:', '\\bdiskpart\\b', '\\bbcdedit\\b',
  '\\brm\\s+-rf\\s+/', '\\bmkfs\\b', '\\bdd\\s+if=',
  '\\b(Stop-Computer|Restart-Computer|shutdown\\.exe|reboot)\\b',
  '\\bnet\\s+user\\b[^\\r\\n]*/add', '\\bSet-ExecutionPolicy\\b'
]);
const EXEC_ALLOW = rx(CFG.execAllow);

let OEM_DECODER;
try { OEM_DECODER = new TextDecoder(String(CFG.oemEncoding || 'gbk')); }
catch (_) { OEM_DECODER = new TextDecoder('utf8'); }

/* ---------------------------------- utils --------------------------------- */
function send(res, code, obj) {
  if (res.headersSent) return;
  const body = Buffer.from(JSON.stringify(obj), 'utf8');
  res.writeHead(code, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': body.length,
    'cache-control': 'no-store'
  });
  res.end(body);
}

function audit(req, action, ok, detail, ms) {
  const line = JSON.stringify({
    ts: new Date().toISOString(), ip: req.socket.remoteAddress,
    action, ok: !!ok, detail: String(detail || '').slice(0, 300), ms
  }) + '\n';
  try { fs.appendFileSync(AUDIT, line, 'utf8'); } catch (_) { /* never fail a request */ }
}

function authorized(req) {
  const h = String(req.headers.authorization || '');
  const got = h.startsWith('Bearer ') ? h.slice(7) : '';
  const a = Buffer.from(got, 'utf8');
  const b = Buffer.from(TOKEN, 'utf8');
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', c => {
      size += c.length;
      if (size > MAX_BODY) { reject(new Error('request body too large')); req.destroy(); }
      else chunks.push(c);
    });
    req.on('end', () => {
      try { resolve(chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : {}); }
      catch (e) { reject(new Error('invalid JSON body')); }
    });
    req.on('error', reject);
  });
}

function safePath(p, forWrite) {
  if (typeof p !== 'string' || !p.trim()) throw new Error('path is required');
  const abs = path.resolve(p);
  let scope = null;
  for (const [k, root] of Object.entries(ROOTS)) {
    if (abs.toLowerCase() === root.toLowerCase() ||
        abs.toLowerCase().startsWith(root.toLowerCase() + path.sep)) { scope = k; break; }
  }
  if (!scope) throw new Error('path outside whitelist: ' + abs);
  const deny = forWrite ? DENY_WRITE : DENY_READ;
  for (const re of deny) if (re.test(abs)) throw new Error('path denied by policy: ' + re.source);
  return { abs, scope };
}

function backupFile(abs) {
  const stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14);
  const rel = path.relative(path.parse(abs).root, abs);
  const dest = path.join(BACKUP, stamp, rel);
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.copyFileSync(abs, dest);
  return dest;
}

function decodeBuf(buf, encoding) {
  return encoding === 'gbk' ? OEM_DECODER.decode(buf) : buf.toString('utf8');
}

/* ------------------------------ command runner ---------------------------- */
let execRunning = 0;
function runExec(b) {
  if (CFG.execEnabled !== true) throw new Error('exec is disabled: set execEnabled=true in config.json');
  const shell = String(b.shell || CFG.defaultShell || 'powershell');
  const profile = (CFG.shells || {})[shell];
  if (!profile || !profile.exe) throw new Error('unknown shell: ' + shell);
  const command = String(b.command || '');
  if (!command.trim()) throw new Error('command is required');
  const maxCommand = Number(CFG.execMaxCommand || 8000);
  if (command.length > maxCommand) throw new Error('command too long (max ' + maxCommand + ')');
  for (const re of EXEC_DENY) if (re.test(command)) throw new Error('command denied by policy: ' + re.source);
  if (EXEC_ALLOW.length && !EXEC_ALLOW.some(re => re.test(command))) {
    throw new Error('command not in execAllow list');
  }

  let cwd = b.cwd ? safePath(b.cwd, false).abs : HOME;
  if (!fs.existsSync(cwd) || !fs.statSync(cwd).isDirectory()) throw new Error('cwd is not a directory');
  const hardMax = Number(CFG.execHardMaxMs || 600000);
  const timeoutMs = Math.min(Math.max(Number(b.timeoutMs || CFG.execMaxMs || 60000), 1000), hardMax);
  const maxOut = Number(CFG.execMaxOut || 65536);
  const maxErr = Number(CFG.execMaxErr || 16384);
  const limit = Math.min(Math.max(Number(CFG.execMaxConcurrent || 3), 1), 8);
  const full = String(profile.prefix || '') + command;
  const args = (profile.args || ['-c', '{cmd}']).map(a => String(a).replace('{cmd}', full));
  const enc = String(profile.encoding || 'utf8');
  const env = Object.assign({}, process.env,
    (b.env && typeof b.env === 'object' && !Array.isArray(b.env)) ? b.env : {});

  return new Promise(resolve => {
    if (execRunning >= limit) return resolve({ ok: false, error: 'exec concurrency limit reached' });
    execRunning++;
    const started = Date.now();
    const outs = [], errs = [];
    let outN = 0, errN = 0, outCut = false, errCut = false, done = false, timedOut = false;
    let child;
    try {
      child = spawn(profile.exe, args, { cwd, env, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    } catch (e) {
      execRunning--;
      return resolve({ ok: false, error: 'spawn failed: ' + e.message });
    }
    const timer = setTimeout(() => { timedOut = true; try { child.kill(); } catch (_) {} }, timeoutMs);
    const take = (isErr, d, cap) => {
      if (!isErr) { if (outN + d.length <= cap) { outs.push(d); outN += d.length; } else outCut = true; }
      else { if (errN + d.length <= cap) { errs.push(d); errN += d.length; } else errCut = true; }
    };
    child.stdout.on('data', d => take(false, d, maxOut));
    child.stderr.on('data', d => take(true, d, maxErr));
    const finish = (code, spawnErr) => {
      if (done) return;
      done = true; clearTimeout(timer); execRunning--;
      resolve({
        ok: !timedOut && !spawnErr && code === 0,
        exitCode: timedOut ? null : code, timedOut, shell, cwd,
        durationMs: Date.now() - started,
        stdout: decodeBuf(Buffer.concat(outs), enc),
        stderr: decodeBuf(Buffer.concat(errs), enc) + (spawnErr || ''),
        truncatedOut: outCut, truncatedErr: errCut,
        detail: command.slice(0, 300)
      });
    };
    child.on('error', e => finish(null, e.message));
    child.on('close', code => finish(code, null));
  });
}

/* -------------------------------- handlers -------------------------------- */
const ENCODINGS = ['utf8', 'base64', 'latin1', 'hex'];
const handlers = {
  health: async () => ({
    ok: true, version: '1.0.0', pid: process.pid, node: process.version,
    platform: process.platform, port: PORT, proxy: PROXY_PORT ? '127.0.0.1:' + PROXY_PORT : null,
    roots: Object.keys(ROOTS), execEnabled: CFG.execEnabled === true,
    shells: Object.keys(CFG.shells || {}), time: new Date().toISOString()
  }),

  sysinfo: async () => ({
    ok: true, type: os.type(), release: os.release(), arch: os.arch(),
    cpus: os.cpus().length, totalMemMB: Math.round(os.totalmem() / 1048576),
    freeMemMB: Math.round(os.freemem() / 1048576),
    uptimeSec: Math.round(os.uptime()), loadAvg: os.loadavg()
  }),

  list: async b => {
    const { abs } = safePath(b.path, false);
    if (!fs.statSync(abs).isDirectory()) throw new Error('not a directory');
    const items = fs.readdirSync(abs, { withFileTypes: true }).slice(0, 500).map(e => ({
      name: e.name, dir: e.isDirectory(), size: e.isFile() ? fs.statSync(path.join(abs, e.name)).size : null
    }));
    return { ok: true, path: abs, count: items.length, items };
  },

  read: async b => {
    const { abs } = safePath(b.path, false);
    if (!fs.statSync(abs).isFile()) throw new Error('not a file');
    const enc = String(b.encoding || 'utf8').toLowerCase();
    if (!ENCODINGS.includes(enc)) throw new Error('unsupported encoding: ' + enc);
    const max = Math.min(Math.max(Number(b.maxBytes || 262144), 1), 2 * 1024 * 1024);
    const buf = fs.readFileSync(abs);
    return { ok: true, path: abs, size: buf.length, truncated: buf.length > max,
             encoding: enc, content: buf.slice(0, max).toString(enc) };
  },

  write: async b => {
    if (typeof b.content !== 'string') throw new Error('content must be a string');
    const enc = String(b.encoding || 'utf8').toLowerCase();
    if (!ENCODINGS.includes(enc)) throw new Error('unsupported encoding: ' + enc);
    const { abs } = safePath(b.path, true);
    const buf = Buffer.from(b.content, enc);
    let backup = null;
    if (fs.existsSync(abs)) backup = backupFile(abs);
    fs.mkdirSync(path.dirname(abs), { recursive: true });
    fs.writeFileSync(abs, buf);
    return { ok: true, path: abs, bytes: buf.length, encoding: enc, backup };
  },

  exec: async b => runExec(b),

  log: async b => {
    const n = Math.min(Math.max(Number(b.lines || 50), 1), 500);
    if (!fs.existsSync(AUDIT)) return { ok: true, source: 'audit', content: '' };
    const arr = fs.readFileSync(AUDIT, 'utf8').split(/\r?\n/);
    return { ok: true, source: 'audit', content: arr.slice(Math.max(0, arr.length - n - 1)).join('\n') };
  }
};

/* ------------------------------ reverse proxy ----------------------------- */
function proxy(req, res) {
  const headers = Object.assign({}, req.headers);
  if (CFG.proxyHost) headers.host = CFG.proxyHost;
  const up = http.request({ hostname: '127.0.0.1', port: PROXY_PORT, path: req.url,
                            method: req.method, headers }, r => {
    res.writeHead(r.statusCode, r.headers);
    r.pipe(res);
  });
  up.on('error', e => send(res, 502, { ok: false, error: 'upstream unreachable: ' + e.message }));
  req.pipe(up);
}

/* --------------------------------- server --------------------------------- */
let hits = 0, windowStart = Date.now();
const requestHandler = async (req, res) => {
  const started = Date.now();
  let pathname;
  try { pathname = new URL(req.url, 'http://localhost').pathname; }
  catch (_) { return send(res, 400, { ok: false, error: 'bad url' }); }
  if (!pathname.startsWith('/__agent/')) {
    return PROXY_PORT > 0 ? proxy(req, res) : send(res, 404, { ok: false, error: 'not found' });
  }
  const action = pathname.slice('/__agent/'.length);
  try {
    if (!authorized(req)) {
      audit(req, action, false, 'unauthorized', Date.now() - started);
      return send(res, 401, { ok: false, error: 'unauthorized' });
    }
    if (Date.now() - windowStart > 60000) { hits = 0; windowStart = Date.now(); }
    if (++hits > RATE) return send(res, 429, { ok: false, error: 'rate limited' });
    if (req.method !== 'POST') return send(res, 405, { ok: false, error: 'POST required' });
    const body = await readBody(req);
    if (!handlers[action]) return send(res, 404, { ok: false, error: 'unknown action' });
    const result = await handlers[action](body, req);
    audit(req, action, result.ok !== false,
          result.detail || result.path || result.source || '', Date.now() - started);
    return send(res, result.ok === false ? 400 : 200, result);
  } catch (e) {
    audit(req, action, false, e.message, Date.now() - started);
    return send(res, 400, { ok: false, error: e.message });
  }
};

const s4 = http.createServer(requestHandler);
s4.on('error', e => { console.error('[FATAL] IPv4 listen error: ' + e.message); process.exit(1); });
s4.listen(PORT, '127.0.0.1', () => console.log('[gateway] 127.0.0.1:' + PORT + ' ready'));
try {
  const s6 = http.createServer(requestHandler);
  s6.on('error', e => console.log('[gateway] IPv6 loopback unavailable, IPv4 only: ' + e.message));
  s6.listen(PORT, '::1');
} catch (_) { /* IPv6 optional */ }
process.on('uncaughtException', e => {
  try { fs.appendFileSync(path.join(HOME, 'crash.log'), new Date().toISOString() + ' ' + e.stack + '\n'); }
  catch (_) {}
  process.exit(1);
});
