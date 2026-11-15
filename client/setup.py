#!/usr/bin/env python3
"""Local one-shot setup for ANY AI agent / client. Python 3.8+, zero dependencies.

Run ON YOUR OWN COMPUTER, once, after the server-side one-shot script finished:

    python3 client/setup.py --from <path-to-bridge-handoff.json>

Or give the values directly (token on the command line stays in shell history,
so the handoff file is preferred):

    python3 client/setup.py --url https://<your-domain> --token <64hex>

What it does in one shot:
  1. Stores the token in ~/.config/remote-bridge/token (0600) and the URL.
  2. Generates MCP config, OpenAPI spec and a ready-to-paste AI-agent prompt.
  3. Optionally merges the MCP server into an existing client config
     (--mcp-config <path>), backing up that file first.
  4. Verifies the whole chain: health, 401 without token, sysinfo, list,
     write/read round trip, audit log, and exec when enabled.
  5. Prints the exact commands / prompt to hand to any AI client.

The token is NEVER written to MCP config, OpenAPI spec, prompt, shell env files
or this script's output.
"""
import argparse
import json
import os
import re
import shutil
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
CONFIG_DIR = Path.home() / '.config' / 'remote-bridge'
TOKEN_FILE = CONFIG_DIR / 'token'
URL_FILE = CONFIG_DIR / 'url'
GENERATED = ('token', 'url', 'env.sh', 'env.ps1', 'mcp.json', 'openapi.yaml', 'agent-prompt.txt')


def parse_args():
    ap = argparse.ArgumentParser(description='One-shot local setup for remote bridge')
    ap.add_argument('--from', dest='handoff', help='bridge-handoff.json produced by the server script')
    ap.add_argument('--url', help='public gateway URL, e.g. https://<your-domain>')
    ap.add_argument('--token', help='bridge token (prefer --from; command line is recorded in shell history)')
    ap.add_argument('--token-file', help='read token from a file instead')
    ap.add_argument('--data-dir', help='server-side whitelisted data directory for the write/read test')
    ap.add_argument('--mcp-config', help='merge remote-server into this existing MCP config JSON (backed up first)')
    ap.add_argument('--openapi-out', help='where to write the generated OpenAPI spec (default: config dir)')
    ap.add_argument('--consume-handoff', action='store_true', help='delete the local handoff copy after reading it')
    ap.add_argument('--skip-verify', action='store_true', help='write files only, do not call the gateway')
    ap.add_argument('--no-mcp', action='store_true', help='do not generate MCP config files')
    ap.add_argument('--status', action='store_true', help='show stored config (never prints the token) and health')
    ap.add_argument('--uninstall', action='store_true', help='remove generated local files; keep client configs untouched')
    ap.add_argument('--json', action='store_true', help='machine-readable summary')
    return ap.parse_args()


def read_handoff(path):
    p = Path(path).expanduser()
    if not p.is_file():
        die('handoff file not found: %s' % p)
    try:
        data = json.loads(p.read_text(encoding='utf-8-sig'))
    except Exception as e:                                    # noqa: BLE001
        die('cannot parse handoff file: %s' % e)
    return data


def die(msg, code=2):
    print('ERROR: ' + msg, file=sys.stderr)
    sys.exit(code)


def call(url, token, action, payload=None, timeout=30, attempts=2):
    endpoint = url.rstrip('/') + '/__agent/' + action
    body = json.dumps(payload or {}, ensure_ascii=False).encode('utf-8')
    headers = {'Content-Type': 'application/json', 'User-Agent': 'remote-bridge-setup/1.0'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    if 'ngrok' in url:
        headers['ngrok-skip-browser-warning'] = 'true'
    last = None
    for i in range(1, attempts + 1):
        req = urllib.request.Request(endpoint, data=body, headers=headers, method='POST')
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return {'_http': r.status, **json.loads(r.read().decode('utf-8'))}
        except urllib.error.HTTPError as e:
            raw = e.read().decode('utf-8', 'replace')
            try:
                return {'_http': e.code, **json.loads(raw)}
            except ValueError:
                return {'_http': e.code, 'ok': False, 'raw': raw[:300]}
        except Exception as e:                                # noqa: BLE001
            last = e
            if i < attempts:
                time.sleep(0.8 * i)
    return {'_http': 0, 'ok': False, 'error': 'RETRY_EXHAUSTED: %s' % last}


def write_private(path, text):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(CONFIG_DIR, 0o700)
    except OSError:
        pass
    p = Path(path)
    p.write_text(text, encoding='utf-8')
    try:
        os.chmod(p, 0o600)
    except OSError:
        pass
    return p


def mcp_entry(url):
    return {
        'type': 'stdio',
        'command': 'node',
        'args': [str(HERE / 'mcp-bridge.js')],
        'env': {'BRIDGE_URL': url},
    }


def merge_mcp(path, url):
    p = Path(path).expanduser()
    if not p.is_file():
        return {'ok': False, 'reason': 'MCP config not found: %s' % p}
    try:
        cfg = json.loads(p.read_text(encoding='utf-8-sig'))
    except Exception as e:                                    # noqa: BLE001
        return {'ok': False, 'reason': 'cannot parse MCP config: %s' % e}
    if not isinstance(cfg, dict):
        return {'ok': False, 'reason': 'MCP config root is not a JSON object'}
    backup = str(p) + '.bak-' + time.strftime('%Y%m%d-%H%M%S')
    shutil.copy2(str(p), backup)
    servers = cfg.setdefault('mcpServers', {})
    if not isinstance(servers, dict):
        return {'ok': False, 'reason': 'mcpServers is not a JSON object'}
    servers['remote-server'] = mcp_entry(url)
    p.write_text(json.dumps(cfg, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    return {'ok': True, 'path': str(p), 'backup': backup}


def generate_openapi(url, out):
    src = HERE / 'openapi.example.yaml'
    if not src.is_file():
        return {'ok': False, 'reason': 'openapi.example.yaml missing'}
    text = src.read_text(encoding='utf-8')
    text = text.replace('https://<你的隧道域名>', url).replace('<你的隧道域名>', url.replace('https://', '').replace('http://', ''))
    p = Path(out) if out else CONFIG_DIR / 'openapi.yaml'
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text, encoding='utf-8')
    return {'ok': True, 'path': str(p)}


def generate_prompt(url, data_dir, exec_enabled):
    text = """你有一台远程服务器，统一接口是 POST {url}/__agent/<动作>。
认证头：Authorization: Bearer <令牌>。令牌在本机文件 ~/.config/remote-bridge/token（权限 0600），
读取后使用，不要打印、不要复述、不要写进任何文件或对话摘要。

动作：health / sysinfo / list / read / write / exec / log。
规则：
1. 路径一律用服务器绝对路径，且必须在 roots 白名单内；
2. 中文或二进制文件用 encoding=base64 取原始字节再按原编码解码；
3. exec 必须带 timeoutMs，禁止交互式命令；
4. 写文件前先 read 确认，写操作会触发服务端自动备份；
5. 每次操作后给出退出码与关键输出；
6. 连接失败自动重试 3 次，间隔 1/2/4 秒；平台定时重启时等待最多 3 分钟。

已知：数据目录 {data}；命令执行当前{state}。
先跑 health 和 sysinfo，然后报告服务器状态。
""".format(url=url, data=data_dir or '<未提供，先跑 health 看 roots>',
           state='开启' if exec_enabled else '关闭')
    write_private(CONFIG_DIR / 'agent-prompt.txt', text)
    return str(CONFIG_DIR / 'agent-prompt.txt')


def do_status(args):
    url = (URL_FILE.read_text(encoding='utf-8').strip() if URL_FILE.is_file() else '')
    token = (TOKEN_FILE.read_text(encoding='utf-8').strip() if TOKEN_FILE.is_file() else '')
    out = {
        'configDir': str(CONFIG_DIR),
        'url': url,
        'tokenStored': TOKEN_FILE.is_file(),
        'tokenMode': '0600 file',
        'files': sorted(p.name for p in CONFIG_DIR.iterdir()) if CONFIG_DIR.is_dir() else [],
    }
    if url and token and not args.skip_verify:
        out['health'] = call(url, token, 'health')
    print(json.dumps(out, ensure_ascii=False, indent=2))
    return 0 if (out.get('health') or {}).get('ok', False) or not url or args.skip_verify else 1


def do_uninstall(args):
    removed = []
    for name in GENERATED:
        p = CONFIG_DIR / name
        if p.is_file():
            p.unlink()
            removed.append(str(p))
    print(json.dumps({'removed': removed,
                      'note': 'Client MCP configs are untouched. Remove the remote-server entry manually if needed.'},
                     ensure_ascii=False, indent=2))
    return 0


def verify(url, token, data_dir, exec_enabled, shells):
    checks = []

    def add(name, ok, detail=''):
        checks.append({'name': name, 'ok': bool(ok), 'detail': str(detail)[:200]})

    h = call(url, token, 'health')
    add('health', h.get('ok') is True and h.get('_http') == 200,
        'version=%s node=%s execEnabled=%s' % (h.get('version'), h.get('node'), h.get('execEnabled')))
    if not h.get('ok'):
        return checks, h

    no_auth = call(url, None, 'health', attempts=1)
    add('401_without_token', no_auth.get('_http') == 401, 'http=%s' % no_auth.get('_http'))

    s = call(url, token, 'sysinfo')
    add('sysinfo', s.get('ok') is True,
        'platform=%s cpus=%s memMB=%s' % (s.get('type'), s.get('cpus'), s.get('totalMemMB')))

    real_exec = bool(h.get('execEnabled'))
    real_shells = h.get('shells') or shells or []
    if data_dir:
        lst = call(url, token, 'list', {'path': data_dir})
        add('list', lst.get('ok') is True, 'count=%s' % lst.get('count'))
        name = 'bridge-setup-check-%s.txt' % time.strftime('%Y%m%d-%H%M%S')
        sep = '\\' if '\\' in data_dir else '/'
        target = data_dir.rstrip('/\\') + sep + name
        content = 'remote-bridge setup check %s\n' % time.strftime('%Y-%m-%d %H:%M:%S')
        w = call(url, token, 'write', {'path': target, 'content': content})
        add('write', w.get('ok') is True, 'bytes=%s' % w.get('bytes'))
        r = call(url, token, 'read', {'path': target})
        add('read', r.get('ok') is True and r.get('content') == content, 'path=%s' % target)
    else:
        add('file_roundtrip', None, 'skipped: no dataDir in handoff, pass --data-dir')

    log = call(url, token, 'log', {'lines': 10})
    add('audit_log', log.get('ok') is True and bool(log.get('content')), 'lines returned')

    if real_exec:
        if 'powershell' in real_shells:
            command, shell = 'Get-Date -Format o', 'powershell'
        elif 'cmd' in real_shells:
            command, shell = 'echo ok', 'cmd'
        else:
            command, shell = 'echo ok', 'sh'
        e = call(url, token, 'exec', {'command': command, 'shell': shell, 'timeoutMs': 30000},
                 timeout=60, attempts=1)
        add('exec', e.get('ok') is True and e.get('exitCode') == 0,
            'shell=%s exit=%s out=%s' % (shell, e.get('exitCode'), str(e.get('stdout', ''))[:60]))
    else:
        add('exec', None, 'skipped: execEnabled=false on server')
    return checks, h


def main():
    args = parse_args()
    if args.status:
        return do_status(args)
    if args.uninstall:
        return do_uninstall(args)

    handoff = read_handoff(args.handoff) if args.handoff else {}
    url = (args.url or handoff.get('url') or '').strip().rstrip('/')
    if not url:
        die('missing gateway URL: pass --url, or use a handoff file with a url field')
    if not re.match(r'^https?://[^/\s]+', url):
        die('URL must start with http:// or https://')
    if url.startswith('http://') and not re.match(r'^http://(127\.0\.0\.1|localhost|\[::1\])', url):
        print('WARNING: plain HTTP over the public network is not encrypted. Use an HTTPS tunnel.', file=sys.stderr)

    token = (args.token or '').strip()
    if not token and args.token_file:
        token = Path(args.token_file).expanduser().read_text(encoding='utf-8').strip()
    if not token:
        token = str(handoff.get('token') or '').strip()
    if not token:
        die('missing token: use --from <handoff>, --token-file or --token')
    if len(token) < 32 or any(c.isspace() for c in token):
        die('token must be at least 32 characters with no whitespace')
    data_dir = args.data_dir or handoff.get('dataDir') or ''
    exec_enabled = bool(handoff.get('execEnabled'))
    shells = handoff.get('shells') or []

    # 1) credentials
    write_private(TOKEN_FILE, token + '\n')
    write_private(URL_FILE, url + '\n')
    write_private(CONFIG_DIR / 'env.sh',
                  '# Source this file: . ~/.config/remote-bridge/env.sh\n'
                  "export BRIDGE_URL='%s'\n"
                  '# BRIDGE_TOKEN is read from ~/.config/remote-bridge/token by the clients\n' % url)
    write_private(CONFIG_DIR / 'env.ps1',
                  '# Run: . (Join-Path $HOME ".config/remote-bridge/env.ps1")\n'
                  "$env:BRIDGE_URL = '%s'\n"
                  '# Token is read from the token file by the clients\n' % url)

    # 2) client configs
    mcp_path = None
    if not args.no_mcp:
        write_private(CONFIG_DIR / 'mcp.json',
                      json.dumps({'mcpServers': {'remote-server': mcp_entry(url)}},
                                 ensure_ascii=False, indent=2) + '\n')
        mcp_path = str(CONFIG_DIR / 'mcp.json')
    merged = None
    if args.mcp_config:
        merged = merge_mcp(args.mcp_config, url)
    openapi = generate_openapi(url, args.openapi_out)
    prompt = generate_prompt(url, data_dir, exec_enabled)

    summary = {
        'configDir': str(CONFIG_DIR),
        'url': url,
        'tokenStored': str(TOKEN_FILE),
        'tokenMode': '0600 file, never written to MCP/OpenAPI/prompt/env',
        'mcpConfig': mcp_path,
        'mcpMerged': merged,
        'openapi': openapi,
        'agentPrompt': prompt,
    }

    # 3) verification
    if not args.skip_verify:
        checks, health = verify(url, token, data_dir, exec_enabled, shells)
        summary['checks'] = checks
        summary['serverVersion'] = health.get('version')
        summary['execEnabled'] = health.get('execEnabled')
        failed = [c['name'] for c in checks if c['ok'] is False]
        summary['failed'] = failed
        summary['ok'] = not failed
    else:
        summary['ok'] = True
        summary['note'] = 'verification skipped'

    if args.consume_handoff and args.handoff:
        try:
            Path(args.handoff).expanduser().unlink()
            summary['handoffDeleted'] = True
        except OSError as e:                                  # noqa: BLE001
            summary['handoffDeleted'] = False
            summary['handoffDeleteError'] = str(e)

    if args.json:
        print(json.dumps(summary, ensure_ascii=False, indent=2))
    else:
        print('==== local AI agent setup ====')
        print('URL           : ' + url)
        print('token         : stored in ' + str(TOKEN_FILE) + ' (0600), never printed')
        print('MCP config    : ' + str(mcp_path or '<skipped>'))
        if merged:
            print('merged into   : ' + json.dumps(merged, ensure_ascii=False))
        print('OpenAPI       : ' + str(openapi.get('path') or openapi.get('reason')))
        print('agent prompt  : ' + prompt)
        if 'checks' in summary:
            print('---- verification ----')
            for c in summary['checks']:
                mark = 'OK  ' if c['ok'] is True else ('SKIP' if c['ok'] is None else 'FAIL')
                print('%s %-20s %s' % (mark, c['name'], c['detail']))
        print('---- next: give ONE line to any AI agent ----')
        print('请读取 ' + prompt + ' 并按其内容接入远程服务器；先跑 health 和 sysinfo。')
        print('命令行方式：python3 ' + str(HERE / 'bridge.py') + ' health')
        if not summary['ok']:
            print('RESULT: FAILED -> ' + ', '.join(summary['failed']))
        else:
            print('RESULT: OK')
    if args.handoff and not args.consume_handoff:
        print('REMINDER: the handoff file still contains the token. Delete the local copy: %s' % args.handoff,
              file=sys.stderr)
    return 0 if summary['ok'] else 1


if __name__ == '__main__':
    sys.exit(main())
