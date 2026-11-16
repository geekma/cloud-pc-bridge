#!/usr/bin/env python3
"""
通用远程网关命令行客户端：零第三方依赖，Python 3.8+。

配置（二选一，不要把 token 写进脚本或配置文件）：
    export BRIDGE_URL="https://<你的隧道域名>"
    export BRIDGE_TOKEN="<64位随机串>"
或：
    export BRIDGE_URL="https://<你的隧道域名>"
    mkdir -p ~/.config/remote-bridge && chmod 700 ~/.config/remote-bridge
    printf '%s' '<64位随机串>' > ~/.config/remote-bridge/token && chmod 600 ~/.config/remote-bridge/token

用法：
    python3 bridge.py health
    python3 bridge.py sysinfo
    python3 bridge.py list /srv/data
    python3 bridge.py read /srv/data/a.txt --encoding base64 --save ./a.txt
    python3 bridge.py write /srv/data/a.txt --content "hello"
    python3 bridge.py write /srv/data/a.bin --file ./a.bin
    python3 bridge.py exec "Get-Date -Format o" --shell powershell
    python3 bridge.py exec "ls -la" --shell sh --timeout 30000
    python3 bridge.py log --lines 30
    python3 bridge.py raw health '{}'
"""
import argparse
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

TOKEN_FILE = Path.home() / '.config' / 'remote-bridge' / 'token'


def base_url():
    url = os.environ.get('BRIDGE_URL', '').strip().rstrip('/')
    if not url:
        sys.exit('缺少 BRIDGE_URL，例如 export BRIDGE_URL="https://<你的隧道域名>"')
    return url


def token():
    t = os.environ.get('BRIDGE_TOKEN', '').strip()
    if t:
        return t
    try:
        t = TOKEN_FILE.read_text(encoding='utf-8').strip()
        if t:
            return t
    except OSError:
        pass
    sys.exit('缺少 token：设置 BRIDGE_TOKEN，或写入 %s（权限 600）' % TOKEN_FILE)


def tunnel_hint(code, body):
    """把隧道服务商的错误页翻译成下一步动作。"""
    low = body.lower()
    if code == 404 and ('err_ngrok' in low or 'offline' in low or 'ngrok' in low
                        or 'tunnel' in low or 'cloudflare' in low):
        return ('隧道端点已离线或地址已失效：免费版隧道在机器关机或进程退出后下线，'
                '重启后通常换域名。先确认实例是否在运行，再取新地址并更新 BRIDGE_URL。')
    if code in (502, 503, 504):
        return '隧道在线但后端不响应：实例可能正在启动，或网关没起来。先确认桌面可交互，再看服务端计划任务。'
    if code == 401:
        return '令牌不被接受：核对 BRIDGE_TOKEN 与服务端 config.json 是否一致。'
    return '返回的不是 JSON，可能是隧道服务商的错误页或反向代理拦截页。'


def call(action, payload, attempts=3, timeout=60):
    url = base_url() + '/__agent/' + action
    data = json.dumps(payload or {}, ensure_ascii=False).encode('utf-8')
    headers = {
        'Authorization': 'Bearer ' + token(),
        'Content-Type': 'application/json',
        'User-Agent': 'generic-remote-bridge/1.0',
    }
    # 免费版 ngrok 会在浏览器访问时插入警告页；显式跳过。
    if 'ngrok' in url:
        headers['ngrok-skip-browser-warning'] = 'true'
    last = None
    for i in range(1, attempts + 1):
        req = urllib.request.Request(url, data=data, headers=headers, method='POST')
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.loads(r.read().decode('utf-8'))
        except urllib.error.HTTPError as e:
            body = e.read().decode('utf-8', 'replace')
            try:
                return json.loads(body)
            except ValueError:
                return {'ok': False, '_http': e.code, 'raw': body[:500],
                        'hint': tunnel_hint(e.code, body)}
        except Exception as e:                       # noqa: BLE001
            last = e
            if i < attempts:
                time.sleep(0.8 * i)
    return {'ok': False, 'error': 'RETRY_EXHAUSTED: %s' % last,
            'hint': '连不上：机器可能被平台休眠或关机，先确认实例状态；若实例在运行，检查隧道进程与网关计划任务。'}


def dump(obj):
    print(json.dumps(obj, ensure_ascii=False, indent=2))


def main():
    ap = argparse.ArgumentParser(description='通用远程网关客户端')
    ap.add_argument('command', help='health / sysinfo / list / read / write / exec / log / raw')
    ap.add_argument('arg', nargs='?', help='路径、命令正文或 action 名')
    ap.add_argument('payload', nargs='?', help='raw 模式的 JSON 字符串')
    ap.add_argument('--url', help='覆盖 BRIDGE_URL')
    ap.add_argument('--encoding', default='utf8', help='read/write 编码：utf8 | base64 | latin1 | hex')
    ap.add_argument('--max-bytes', type=int, default=262144)
    ap.add_argument('--content', help='write 的文本内容')
    ap.add_argument('--file', help='write 的本地源文件（按原始字节上传）')
    ap.add_argument('--save', help='read 结果保存到本地文件')
    ap.add_argument('--shell', default=None, help='exec 的 shell 名，见服务端 config.shells')
    ap.add_argument('--timeout', type=int, default=60000, help='exec 超时毫秒')
    ap.add_argument('--cwd', help='exec 工作目录（必须在白名单内）')
    ap.add_argument('--env', help='exec 附加环境变量，JSON 对象')
    ap.add_argument('--lines', type=int, default=50)
    a = ap.parse_args()

    if a.url:
        os.environ['BRIDGE_URL'] = a.url

    cmd = a.command.lower()
    if cmd == 'health':
        out = call('health', {})
    elif cmd == 'sysinfo':
        out = call('sysinfo', {})
    elif cmd == 'list':
        out = call('list', {'path': a.arg})
    elif cmd == 'read':
        out = call('read', {'path': a.arg, 'encoding': a.encoding, 'maxBytes': a.max_bytes})
        if a.save and out.get('ok'):
            raw = (base64.b64decode(out['content']) if a.encoding == 'base64'
                   else out['content'].encode('utf-8'))
            Path(a.save).write_bytes(raw)
            out['savedTo'] = a.save
    elif cmd == 'write':
        if a.file:
            content = base64.b64encode(Path(a.file).read_bytes()).decode('ascii')
            enc = 'base64'
        elif a.content is not None:
            content, enc = a.content, a.encoding
        else:
            sys.exit('write 需要 --content 或 --file')
        out = call('write', {'path': a.arg, 'content': content, 'encoding': enc})
    elif cmd == 'exec':
        payload = {'command': a.arg, 'timeoutMs': a.timeout}
        for key, val in (('shell', a.shell), ('cwd', a.cwd), ('env', a.env)):
            if val:
                payload[key] = json.loads(val) if key == 'env' else val
        out = call('exec', payload, attempts=1, timeout=min(max(a.timeout / 1000 + 30, 30), 630))
    elif cmd == 'log':
        out = call('log', {'lines': a.lines})
    elif cmd == 'raw':
        try:
            payload = json.loads(a.payload or '{}')
        except ValueError as e:
            sys.exit('payload 不是合法 JSON: %s' % e)
        out = call(a.arg, payload)
    else:
        sys.exit('未知命令：%s' % cmd)

    dump(out)
    if out.get('ok') is False:
        sys.exit(1)


if __name__ == '__main__':
    main()
