#!/usr/bin/env bash
# Remote bridge - Linux / macOS one-shot setup. Zero third-party packages.
#
# Run ON THE REMOTE MACHINE (needs Node.js 18+ and Python 3.8+):
#
#   bash server/setup-server.sh
#
# That single command creates directories, generates a token, writes
# config.json, installs gateway.js, registers systemd services (startup +
# restart + optional tunnel + 1-minute check timer), self-tests and writes
# bridge-handoff.json.
#
# Options:
#   --dir /srv/bridge --data /srv/data --logs /srv/logs
#   --port 8787 --proxy-port 0 --node /usr/bin/node
#   --tunnel-command 'ngrok http 8787' --tunnel-url 'https://<your-domain>'
#   --enable-exec | --disable-exec --rotate-token --token <64hex>
#   --no-service            skip systemd; run with nohup (also works on macOS)
#   --check                 internal watchdog action (every minute)
#   --status                show service state, health, tunnel, recent log
#   --uninstall             stop services, keep generated files
#
# systemd units are written to /etc/systemd/system; run with sudo when you are
# not root. With --no-service no root rights are needed.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BRIDGE_DIR="/srv/bridge"
DATA_DIR="/srv/data"
LOG_DIR="/srv/logs"
PORT="8787"
PROXY_PORT="0"
NODE_BIN=""
TUNNEL_COMMAND=""
TUNNEL_URL=""
TOKEN_ARG=""
ROTATE_TOKEN=0
ENABLE_EXEC=""
NO_SERVICE=0
TASK="install"

usage() { sed -n '2,28p' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) BRIDGE_DIR="$2"; shift 2;;
    --data) DATA_DIR="$2"; shift 2;;
    --logs) LOG_DIR="$2"; shift 2;;
    --port) PORT="$2"; shift 2;;
    --proxy-port) PROXY_PORT="$2"; shift 2;;
    --node) NODE_BIN="$2"; shift 2;;
    --tunnel-command) TUNNEL_COMMAND="$2"; shift 2;;
    --tunnel-url) TUNNEL_URL="$2"; shift 2;;
    --token) TOKEN_ARG="$2"; shift 2;;
    --enable-exec) ENABLE_EXEC="true"; shift;;
    --disable-exec) ENABLE_EXEC="false"; shift;;
    --rotate-token) ROTATE_TOKEN=1; shift;;
    --no-service) NO_SERVICE=1; shift;;
    --check) TASK="check"; shift;;
    --status) TASK="status"; shift;;
    --uninstall) TASK="uninstall"; shift;;
    -h|--help) usage; exit 0;;
    *) echo "unknown option: $1" >&2; usage; exit 2;;
  esac
done

CONFIG="$BRIDGE_DIR/config.json"
GATEWAY="$BRIDGE_DIR/gateway.js"
HANDOFF="$BRIDGE_DIR/bridge-handoff.json"
TUNNEL_CFG="$BRIDGE_DIR/tunnel.json"
TUNNEL_CMD_FILE="$BRIDGE_DIR/tunnel-command.sh"
SETUP_LOG="$BRIDGE_DIR/setup.log"
PID_FILE="$BRIDGE_DIR/gateway.pid"
TUNNEL_PID_FILE="$BRIDGE_DIR/tunnel.pid"
SERVICE="remote-bridge"
TUNNEL_SERVICE="remote-bridge-tunnel"
CHECK_SERVICE="remote-bridge-check"

log() {
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >> "$SETUP_LOG" 2>/dev/null || true
  if [ "$TASK" != "check" ]; then printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2"; fi
}

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing required command: $1" >&2; exit 1; }
}

find_node() {
  if [ -n "$NODE_BIN" ] && [ -x "$NODE_BIN" ]; then echo "$NODE_BIN"; return; fi
  if command -v node >/dev/null 2>&1; then command -v node; return; fi
  echo "Node.js 18+ not found. Install it first, or pass --node <path>." >&2
  exit 1
}

sudo_cmd() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else need sudo; sudo "$@"; fi
}

# ---------------------------------------------------------------- config JSON
PY_CONFIG=$(cat <<'PY'
import json, os, secrets, sys
p = sys.argv[1]
old = {}
if os.path.exists(p):
    try:
        old = json.load(open(p, encoding='utf-8'))
    except Exception:
        old = {}
tok = os.environ.get('BRIDGE_TOKEN_ARG', '').strip()
if not tok and os.environ.get('BRIDGE_ROTATE', '0') != '1':
    tok = str(old.get('token', ''))
if not tok or '<' in tok or os.environ.get('BRIDGE_ROTATE', '0') == '1':
    tok = secrets.token_hex(32)
if len(tok) < 32 or any(c.isspace() for c in tok):
    raise SystemExit('token must be >= 32 chars without whitespace')
exe = os.environ.get('BRIDGE_EXEC', '')
enabled = (exe == 'true') if exe else bool(old.get('execEnabled', False))
cfg = dict(old)
cfg.update({
    'token': tok,
    'port': int(os.environ['BRIDGE_PORT']),
    'proxyPort': int(os.environ['BRIDGE_PROXY']),
    'proxyHost': '',
    'home': os.environ['BRIDGE_HOME'],
    'roots': {'data': os.environ['BRIDGE_DATA'], 'logs': os.environ['BRIDGE_LOGS'],
              'bridge': os.environ['BRIDGE_HOME']},
    'execEnabled': enabled,
    'defaultShell': 'sh',
    'shells': {'sh': {'exe': '/bin/sh', 'args': ['-c', '{cmd}'], 'encoding': 'utf8'}},
})
cfg.setdefault('denyRead', ['[\\\\/]config\\.json$', '\\.(key|pem|pfx|p12)$',
                            '[\\\\/]id_rsa', '[\\\\/]\\.ssh[\\\\/]'])
cfg.setdefault('denyWrite', ['\\.(mdb|ldb|sqlite|bak)$'])
cfg.setdefault('rateLimitPerMinute', 180)
cfg.setdefault('maxBodyBytes', 5242880)
with open(p, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
)

write_config() {
  BRIDGE_TOKEN_ARG="$TOKEN_ARG" BRIDGE_ROTATE="$ROTATE_TOKEN" \
  BRIDGE_PORT="$PORT" BRIDGE_PROXY="$PROXY_PORT" BRIDGE_HOME="$BRIDGE_DIR" \
  BRIDGE_DATA="$DATA_DIR" BRIDGE_LOGS="$LOG_DIR" BRIDGE_EXEC="$ENABLE_EXEC" \
  python3 -c "$PY_CONFIG" "$CONFIG"
}

PY_HANDOFF=$(cat <<'PY'
import json, os, sys
with open(sys.argv[1], 'w', encoding='utf-8') as f:
    json.dump({
        'url': os.environ.get('BRIDGE_URL', ''),
        'token': os.environ['BRIDGE_TOKEN'],
        'port': int(os.environ['BRIDGE_PORT']),
        'dataDir': os.environ['BRIDGE_DATA'],
        'execEnabled': os.environ.get('BRIDGE_EXEC', 'false') == 'true',
        'created': __import__('datetime').datetime.now().astimezone().isoformat(),
        'note': 'SECRET: contains the bridge token. Copy to your own computer, run client/setup.py --from <this file>, then delete both copies.',
    }, f, ensure_ascii=False, indent=2)
PY
)

PY_CHECK=$(cat <<'PY'
import json, os, sys, urllib.request, urllib.error
cfg = json.load(open(sys.argv[1], encoding='utf-8'))
def probe(url, token):
    req = urllib.request.Request(url, data=b'{}', method='POST',
        headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json',
                 'ngrok-skip-browser-warning': 'true'})
    with urllib.request.urlopen(req, timeout=6) as r:
        return r.status == 200 and json.loads(r.read().decode('utf-8')).get('ok') is True
try:
    ok = probe('http://127.0.0.1:%d/__agent/health' % int(cfg['port']), cfg['token'])
except Exception:
    ok = False
if not ok:
    print('LOCAL_FAIL'); sys.exit(0)
tunnel = sys.argv[2]
if os.path.exists(tunnel):
    t = json.load(open(tunnel, encoding='utf-8'))
    if t.get('url'):
        try:
            if not probe(t['url'].rstrip('/') + '/__agent/health', cfg['token']):
                print('PUBLIC_FAIL'); sys.exit(0)
        except Exception:
            print('PUBLIC_FAIL'); sys.exit(0)
print('OK')
PY
)

get_token() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["token"])' "$CONFIG"; }

# ------------------------------------------------------------------ unit files
write_unit() {
  name="$1"; content="$2"; path="/etc/systemd/system/$name"
  printf '%s\n' "$content" | sudo_cmd tee "$path" >/dev/null
  sudo_cmd chmod 644 "$path"
}

install_units() {
  node="$(find_node)"
  write_unit "$SERVICE.service" "[Unit]
Description=Remote bridge gateway (loopback only)
After=network-online.target

[Service]
Type=simple
ExecStart=$node $GATEWAY
WorkingDirectory=$BRIDGE_DIR
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target"
  if [ -n "$TUNNEL_COMMAND" ]; then
    write_unit "$TUNNEL_SERVICE.service" "[Unit]
Description=Public tunnel for remote bridge
After=network-online.target

[Service]
Type=simple
ExecStart=/bin/sh $TUNNEL_CMD_FILE
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target"
  fi
  write_unit "$CHECK_SERVICE.service" "[Unit]
Description=Remote bridge health check

[Service]
Type=oneshot
ExecStart=/bin/bash $HERE/setup-server.sh --check --dir $BRIDGE_DIR --data $DATA_DIR --logs $LOG_DIR --port $PORT"
  write_unit "$CHECK_SERVICE.timer" "[Unit]
Description=Run remote bridge health check every minute

[Timer]
OnBootSec=60
OnUnitActiveSec=60
Unit=$CHECK_SERVICE.service

[Install]
WantedBy=timers.target"
  sudo_cmd systemctl daemon-reload
  sudo_cmd systemctl enable --now "$SERVICE.service" >/dev/null
  [ -n "$TUNNEL_COMMAND" ] && sudo_cmd systemctl enable --now "$TUNNEL_SERVICE.service" >/dev/null
  sudo_cmd systemctl enable --now "$CHECK_SERVICE.timer" >/dev/null
}

start_nohup() {
  node="$(find_node)"
  nohup "$node" "$GATEWAY" >> "$LOG_DIR/gateway.log" 2>&1 &
  echo $! > "$PID_FILE"
  if [ -n "$TUNNEL_COMMAND" ]; then
    nohup /bin/sh "$TUNNEL_CMD_FILE" >> "$LOG_DIR/tunnel.log" 2>&1 &
    echo $! > "$TUNNEL_PID_FILE"
  fi
}

restart_nohup() {
  [ -f "$PID_FILE" ] && kill "$(cat "$PID_FILE")" 2>/dev/null || true
  node="$(find_node)"
  nohup "$node" "$GATEWAY" >> "$LOG_DIR/gateway.log" 2>&1 &
  echo $! > "$PID_FILE"
}

# --------------------------------------------------------------------- actions
do_install() {
  need python3
  node="$(find_node)"
  mkdir -p "$BRIDGE_DIR" "$DATA_DIR" "$LOG_DIR"
  chmod 700 "$BRIDGE_DIR"
  if [ "$HERE/gateway.js" != "$GATEWAY" ]; then cp "$HERE/gateway.js" "$GATEWAY"; fi
  "$node" --check "$GATEWAY" || { echo "node --check failed" >&2; exit 1; }
  write_config
  chmod 600 "$CONFIG"
  log INFO "config written, port=$PORT, execEnabled=$(python3 -c 'import json,sys; print(str(json.load(open(sys.argv[1]))["execEnabled"]).lower())' "$CONFIG")"

  if [ -n "$TUNNEL_COMMAND" ]; then
    printf '#!/bin/sh\n%s\n' "$TUNNEL_COMMAND" > "$TUNNEL_CMD_FILE"
    chmod 700 "$TUNNEL_CMD_FILE"
    printf '{"command": %s, "url": %s}\n' \
      "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$TUNNEL_COMMAND")" \
      "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$TUNNEL_URL")" > "$TUNNEL_CFG"
    chmod 600 "$TUNNEL_CFG"
  fi

  if [ "$NO_SERVICE" -eq 1 ]; then
    start_nohup
    log INFO "started with nohup (no systemd)"
  else
    need systemctl
    install_units
    log INFO "systemd services enabled"
  fi

  healthy=0
  for _ in $(seq 1 25); do
    if [ "$(python3 -c "$PY_CHECK" "$CONFIG" "$TUNNEL_CFG")" != "LOCAL_FAIL" ]; then healthy=1; break; fi
    sleep 1
  done
  url="$TUNNEL_URL"
  if [ -z "$url" ] && command -v python3 >/dev/null 2>&1; then
    url="$(python3 -c 'import json,urllib.request
try:
 d=json.load(urllib.request.urlopen("http://127.0.0.1:4040/api/tunnels",timeout=2))
 print(next((t["public_url"] for t in d.get("tunnels",[]) if t.get("public_url","").startswith("https://")), ""))
except Exception: print("")' 2>/dev/null)"
  fi
  if [ -n "$TUNNEL_COMMAND" ] && [ -n "$url" ]; then
    printf '{"command": %s, "url": %s}\n' \
      "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$TUNNEL_COMMAND")" \
      "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$url")" > "$TUNNEL_CFG"
    chmod 600 "$TUNNEL_CFG"
  fi
  BRIDGE_URL="$url" BRIDGE_TOKEN="$(get_token)" BRIDGE_PORT="$PORT" BRIDGE_DATA="$DATA_DIR" \
    BRIDGE_EXEC="$(python3 -c 'import json,sys; print(str(json.load(open(sys.argv[1]))["execEnabled"]).lower())' "$CONFIG")" \
    python3 -c "$PY_HANDOFF" "$HANDOFF"
  chmod 600 "$HANDOFF"

  echo ""
  echo "==== remote bridge setup result ===="
  echo "local health     : $([ "$healthy" -eq 1 ] && echo OK || echo 'FAIL - see setup.log')"
  echo "gateway port     : $PORT"
  echo "public URL       : ${url:-<not detected; pass --url to client/setup.py>}"
  echo "handoff file     : $HANDOFF"
  echo ""
  echo "SECRET FILE: copy bridge-handoff.json to your own computer, then DELETE the copy on this server."
  echo "On your own computer run (one command):"
  echo "  python3 client/setup.py --from <path-to-bridge-handoff.json>$([ -z "$url" ] && echo ' --url https://<your-tunnel-domain>')"
  echo ""
  [ "$healthy" -eq 1 ] || { log ERROR "self-test failed"; exit 1; }
  log INFO "setup complete"
}

do_check() {
  need python3
  [ -f "$CONFIG" ] || { log ERROR "config.json missing"; exit 1; }
  state="$(python3 -c "$PY_CHECK" "$CONFIG" "$TUNNEL_CFG" 2>/dev/null || echo LOCAL_FAIL)"
  case "$state" in
    OK) ;;
    LOCAL_FAIL)
      log WARN "health failed -> restarting gateway"
      if [ "$NO_SERVICE" -eq 1 ] || [ ! -f "/etc/systemd/system/$SERVICE.service" ]; then restart_nohup
      else sudo_cmd systemctl restart "$SERVICE.service"; fi ;;
    PUBLIC_FAIL)
      log WARN "public URL unhealthy -> restarting tunnel"
      if [ "$NO_SERVICE" -eq 1 ] || [ ! -f "/etc/systemd/system/$TUNNEL_SERVICE.service" ]; then
        [ -f "$TUNNEL_PID_FILE" ] && kill "$(cat "$TUNNEL_PID_FILE")" 2>/dev/null || true
        nohup /bin/sh "$TUNNEL_CMD_FILE" >> "$LOG_DIR/tunnel.log" 2>&1 &
        echo $! > "$TUNNEL_PID_FILE"
      else
        sudo_cmd systemctl restart "$TUNNEL_SERVICE.service"
      fi ;;
  esac
}

do_status() {
  if [ -f "/etc/systemd/system/$SERVICE.service" ]; then
    for u in "$SERVICE.service" "$TUNNEL_SERVICE.service" "$CHECK_SERVICE.timer"; do
      [ -f "/etc/systemd/system/$u" ] && echo "$u: $(systemctl is-active "$u" 2>/dev/null)"
    done
  else
    echo "mode: nohup (pid file $PID_FILE)"
    [ -f "$PID_FILE" ] && echo "gateway pid: $(cat "$PID_FILE")"
  fi
  [ -f "$CONFIG" ] && echo "health: $(python3 -c "$PY_CHECK" "$CONFIG" "$TUNNEL_CFG")"
  [ -f "$TUNNEL_CFG" ] && echo "tunnel: $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("url") or "<none>")' "$TUNNEL_CFG")"
  [ -f "$SETUP_LOG" ] && tail -n 12 "$SETUP_LOG"
}

do_uninstall() {
  removed_units=0
  for u in "$SERVICE.service" "$TUNNEL_SERVICE.service" "$CHECK_SERVICE.service" "$CHECK_SERVICE.timer"; do
    if [ -f "/etc/systemd/system/$u" ]; then
      sudo_cmd systemctl disable --now "$u" >/dev/null 2>&1 || true
      sudo_cmd rm -f "/etc/systemd/system/$u"
      echo "removed unit: $u"
      removed_units=1
    fi
  done
  [ "$removed_units" -eq 1 ] && sudo_cmd systemctl daemon-reload 2>/dev/null || true
  [ -f "$PID_FILE" ] && kill "$(cat "$PID_FILE")" 2>/dev/null || true
  [ -f "$TUNNEL_PID_FILE" ] && kill "$(cat "$TUNNEL_PID_FILE")" 2>/dev/null || true
  echo "Generated files are KEPT on purpose (they contain your data and token):"
  for p in "$GATEWAY" "$CONFIG" "$HANDOFF" "$TUNNEL_CFG"; do [ -f "$p" ] && echo "  $p"; done
  echo "Delete them manually only when you are sure you no longer need this bridge."
}

case "$TASK" in
  install) do_install;;
  check) do_check;;
  status) do_status;;
  uninstall) do_uninstall;;
esac
