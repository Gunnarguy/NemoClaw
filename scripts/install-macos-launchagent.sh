#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS_DIR="$HOME/Library/LaunchAgents"
BIN_DIR="$HOME/.nemoclaw/bin"
LOCAL_BIN="$HOME/.local/bin"
LOG_DIR="$HOME/.nemoclaw/logs"
PLIST_PATH="$AGENTS_DIR/local.nemoclaw.ui.plist"
AGENT_PATH="$BIN_DIR/nemoclaw-ui-agent.sh"

mkdir -p "$AGENTS_DIR" "$LOG_DIR" "$BIN_DIR"
chmod 700 "$HOME/.nemoclaw" "$LOG_DIR" "$BIN_DIR" 2>/dev/null || true
: >"$LOG_DIR/launchd.stdout.log"
: >"$LOG_DIR/launchd.stderr.log"

cat >"$AGENT_PATH" <<'EOF'
#!/usr/bin/env bash

set -uo pipefail

HOME_DIR="$HOME"
LOCAL_BIN="$HOME_DIR/.local/bin"
LOG_DIR="$HOME_DIR/.nemoclaw/logs"
REGISTRY_FILE="$HOME_DIR/.nemoclaw/sandboxes.json"
DASHBOARD_URL="http://127.0.0.1:18789"

mkdir -p "$LOG_DIR"
chmod 700 "$HOME_DIR/.nemoclaw" "$LOG_DIR" 2>/dev/null || true

PATH="$LOCAL_BIN:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
if [ -d "$HOME_DIR/.nvm/versions/node" ]; then
  latest_node="$(ls "$HOME_DIR/.nvm/versions/node" 2>/dev/null | sort -V | tail -1 2>/dev/null || true)"
  if [ -n "$latest_node" ]; then
    PATH="$HOME_DIR/.nvm/versions/node/$latest_node/bin:$PATH"
  fi
fi
export PATH

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_DIR/ui-agent.log"
}

rotate_log() {
  local file_path="$1"
  local keep_lines="$2"
  touch "$file_path"
  if [ "$(wc -l < "$file_path" 2>/dev/null || echo 0)" -gt "$keep_lines" ]; then
    tail -n "$keep_lines" "$file_path" > "$file_path.tmp" && mv "$file_path.tmp" "$file_path"
  fi
}

rotate_log "$LOG_DIR/ui-agent.log" 400
rotate_log "$LOG_DIR/ui-forward.log" 400

run_with_timeout() {
  local seconds="$1"
  shift
  python3 - "$seconds" "$@" <<'PY'
import os
import subprocess
import sys

timeout = float(sys.argv[1])
cmd = sys.argv[2:]

try:
    completed = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=timeout,
        env=os.environ.copy(),
    )
    sys.stdout.write(completed.stdout or "")
    sys.exit(completed.returncode)
except subprocess.TimeoutExpired as exc:
    sys.stdout.write(exc.stdout or "")
    sys.stderr.write(f"TIMEOUT {timeout}s: {' '.join(cmd)}\n")
    sys.exit(124)
PY
}

dashboard_ok() {
  python3 - "$DASHBOARD_URL" <<'PY'
import sys
import urllib.request

url = sys.argv[1]
try:
    with urllib.request.urlopen(url, timeout=2) as response:
        raise SystemExit(0 if response.status == 200 else 1)
except Exception:
    raise SystemExit(1)
PY
}

gateway_connected() {
  run_with_timeout 8 openshell status 2>/dev/null | perl -pe 's/\e\[[0-9;]*[A-Za-z]//g' | grep -q 'Status: Connected'
}

notify_user() {
  local title="$1" msg="$2" subtitle="${3:-}"
  python3 - "$title" "$msg" "$subtitle" <<'PY'
import subprocess, sys
def esc(v): return v.replace('\\', '\\\\').replace('"', '\\"')
title, msg = sys.argv[1], sys.argv[2]
subtitle = sys.argv[3] if len(sys.argv) > 3 else ""
script = f'display notification "{esc(msg)}" with title "{esc(title)}"'
if subtitle:
    script += f' subtitle "{esc(subtitle)}"'
subprocess.run(["osascript", "-e", script], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
PY
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

# Notification throttle: avoid spamming the same notification
LAST_NOTIFY_EVENT=""
LAST_NOTIFY_TIME=0
notify_throttled() {
  local event="$1" title="$2" msg="$3" subtitle="${4:-}"
  local now
  now="$(date +%s)"
  if [ "$event" = "$LAST_NOTIFY_EVENT" ] && [ $((now - LAST_NOTIFY_TIME)) -lt 120 ]; then
    return 0
  fi
  LAST_NOTIFY_EVENT="$event"
  LAST_NOTIFY_TIME="$now"
  notify_user "$title" "$msg" "$subtitle"
}

if [ ! -f "$HOME_DIR/.nemoclaw/credentials.json" ]; then
  log "No credentials file yet; skipping."
  exit 0
fi

get_sandbox_name() {
  python3 - <<'PY'
import json, os
path = os.path.expanduser('~/.nemoclaw/sandboxes.json')
try:
    data = json.load(open(path))
except Exception:
    print('', end='')
    raise SystemExit(0)
name = data.get('defaultSandbox')
if name and data.get('sandboxes', {}).get(name):
    print(name, end='')
else:
    names = list(data.get('sandboxes', {}).keys())
    print(names[0] if names else '', end='')
PY
}

log "NemoClaw UI supervisor started."

while true; do
  if [ ! -f "$REGISTRY_FILE" ]; then
    log "No sandbox registry yet; sleeping."
    sleep 30
    continue
  fi

  if ! need_cmd docker || ! docker info >/dev/null 2>&1; then
    log "Docker not ready; sleeping."
    sleep 15
    continue
  fi

  if ! need_cmd openshell; then
    log "openshell missing; sleeping."
    sleep 30
    continue
  fi

  sandbox_name="$(get_sandbox_name)"
  if [ -z "$sandbox_name" ]; then
    log "No sandbox registered; sleeping."
    sleep 30
    continue
  fi

  if ! gateway_connected; then
    log "Gateway not connected; attempting recovery."
    notify_throttled "gw_recovery" "NemoClaw" "Recovering gateway connection..." "Self-heal"
    run_with_timeout 8 openshell gateway select nemoclaw >/dev/null 2>&1 || true
    run_with_timeout 12 openshell gateway start --name nemoclaw >/dev/null 2>&1 || run_with_timeout 12 openshell gateway start >/dev/null 2>&1 || true
    for _ in $(seq 1 10); do
      if gateway_connected; then
        log "Gateway connected."
        notify_throttled "gw_recovered" "NemoClaw" "Gateway connection restored" "Self-heal"
        break
      fi
      sleep 1
    done
  fi

  if ! gateway_connected; then
    log "Gateway still not connected; retrying later."
    notify_throttled "gw_failed" "NemoClaw" "Gateway recovery failed — retrying in 15s" "Self-heal"
    sleep 15
    continue
  fi

  forward_state="$(run_with_timeout 8 openshell forward list 2>/dev/null | awk -v name="$sandbox_name" '$1 == name && $3 == 18789 { print $5 }' | tail -1 || true)"
  if [ "$forward_state" = "dead" ]; then
    log "Stopping dead forward for $sandbox_name."
    run_with_timeout 8 openshell forward stop 18789 "$sandbox_name" >/dev/null 2>&1 || true
  fi

  if dashboard_ok; then
    sleep 10
    continue
  fi

  if lsof -nP -iTCP:18789 -sTCP:LISTEN >/dev/null 2>&1; then
    log "Port 18789 is listening but dashboard probe failed; clearing stale listener."
    run_with_timeout 8 openshell forward stop 18789 "$sandbox_name" >/dev/null 2>&1 || true
    sleep 1
  fi

  log "Launching persistent dashboard forward for $sandbox_name."
  notify_throttled "fwd_start" "NemoClaw" "Starting dashboard forward..." "$sandbox_name"
  if openshell forward start 18789 "$sandbox_name" >>"$LOG_DIR/ui-forward.log" 2>&1; then
    log "Dashboard forward exited cleanly; relaunching if needed."
    notify_throttled "fwd_exited" "NemoClaw" "Dashboard forward exited — relaunching" "Self-heal"
  else
    rc=$?
    log "Dashboard forward exited with code $rc; retrying."
    notify_throttled "fwd_failed" "NemoClaw" "Dashboard forward failed (exit $rc) — retrying" "Self-heal"
  fi
  sleep 2

  # After relaunch, check if dashboard came back
  sleep 3
  if dashboard_ok; then
    notify_throttled "dashboard_ready" "NemoClaw" "Dashboard is back at 127.0.0.1:18789" "$sandbox_name"
  fi
done
EOF

chmod +x "$AGENT_PATH"

cat >"$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>local.nemoclaw.ui</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$AGENT_PATH</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME</string>
    <key>PATH</key>
    <string>$LOCAL_BIN:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>5</integer>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/launchd.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/launchd.stderr.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
launchctl enable "gui/$(id -u)/local.nemoclaw.ui" >/dev/null 2>&1 || true
launchctl kickstart -k "gui/$(id -u)/local.nemoclaw.ui" >/dev/null 2>&1 || true

echo "Installed LaunchAgent: $PLIST_PATH"
echo "Installed Agent Script: $AGENT_PATH"
echo "Logs: $LOG_DIR"
