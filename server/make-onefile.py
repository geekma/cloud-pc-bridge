#!/usr/bin/env python3
"""Rebuild the self-contained Windows setup script.

  python3 server/make-onefile.py

Reads:
  server/setup-server.template.ps1   (logic, with two <<...>> placeholders)
  server/gateway.js                  (embedded verbatim)
  server/keepalive.ps1               (embedded verbatim)
Writes:
  server/setup-server.ps1            (UTF-8 with BOM, Windows PowerShell 5.1)

Run this again whenever gateway.js or keepalive.ps1 changes. The generated
script needs no other file on the remote machine.
"""
import base64
import hashlib
import json
import re
import textwrap
from pathlib import Path

HERE = Path(__file__).resolve().parent
BOM = b'\xef\xbb\xbf'


def payload(name: str) -> bytes:
    raw = (HERE / name).read_bytes()
    # PowerShell 5.1 needs a BOM for non-ASCII .ps1. Node.js .js must NOT get one.
    if name.endswith('.ps1') and not raw.startswith(BOM):
        raw = BOM + raw
    return raw


def embedded(name: str) -> str:
    text = base64.b64encode(payload(name)).decode('ascii')
    return '\n'.join(textwrap.wrap(text, 100))


def main() -> None:
    template = (HERE / 'setup-server.template.ps1').read_text(encoding='utf-8-sig')
    if template.count('<<GATEWAY_BASE64>>') != 1 or template.count('<<KEEPALIVE_BASE64>>') != 1:
        raise SystemExit('template placeholders missing or duplicated')
    out = template.replace('<<GATEWAY_BASE64>>', embedded('gateway.js'))
    out = out.replace('<<KEEPALIVE_BASE64>>', embedded('keepalive.ps1'))
    (HERE / 'setup-server.ps1').write_text(out, encoding='utf-8-sig')

    # Verify the generated file really carries byte-exact copies.
    built = (HERE / 'setup-server.ps1').read_text(encoding='utf-8-sig')
    blocks = re.findall(r"@'\n(.*?)\n'@", built, re.S)
    if len(blocks) != 2:
        raise SystemExit('expected exactly 2 embedded blocks, found %d' % len(blocks))
    result = {}
    for block, name in zip(blocks, ('gateway.js', 'keepalive.ps1')):
        decoded = base64.b64decode(re.sub(r'\s', '', block))
        ok = decoded == payload(name)
        result[name] = {'bytes': len(decoded), 'sha256': hashlib.sha256(decoded).hexdigest()[:16],
                        'byte_exact': ok}
        if not ok:
            raise SystemExit('embedded payload mismatch: ' + name)
    result['output'] = str(HERE / 'setup-server.ps1')
    result['output_bytes'] = (HERE / 'setup-server.ps1').stat().st_size
    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == '__main__':
    main()
