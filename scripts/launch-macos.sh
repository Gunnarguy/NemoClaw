#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DESKTOP_URL="http://127.0.0.1:18789"
LOCAL_BIN="$HOME/.local/bin"
MODE="${1:-start}"
LOG_DIR="$HOME/.nemoclaw/logs"
LAUNCHER_LOG="$LOG_DIR/launcher.log"

YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[1;34m'
NC='\033[0m'

info() { printf "${BLUE}[nemoclaw]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[nemoclaw]${NC} %s\n" "$*"; }
fail() { printf "${RED}[nemoclaw]${NC} %s\n" "$*"; exit 1; }

is_agent_mode() {
  [ "$MODE" = "--agent" ]
}

is_recover_mode() {
  [ "$MODE" = "--recover-ui" ]
}

is_stop_mode() {
  [ "$MODE" = "stop" ] || [ "$MODE" = "--app-stop" ]
}

is_restart_mode() {
  [ "$MODE" = "restart" ] || [ "$MODE" = "--app-restart" ]
}

is_app_mode() {
  [ "$MODE" = "--app-start" ] || is_stop_mode || is_restart_mode
}

should_pause_on_exit() {
  ! is_agent_mode && ! is_app_mode && ! is_recover_mode
}

validate_mode() {
  case "$MODE" in
    start|stop|restart|--agent|--recover-ui|--app-start|--app-stop|--app-restart)
      ;;
    *)
      fail "Unsupported launcher mode: $MODE"
      ;;
  esac
}

installed_nemoclaw_available() {
  command -v nemoclaw >/dev/null 2>&1
}

rotate_log_file() {
  local file_path="$1"
  local keep_lines="$2"

  mkdir -p "$(dirname "$file_path")"
  touch "$file_path"
  if [ "$(wc -l < "$file_path" 2>/dev/null || echo 0)" -gt "$keep_lines" ]; then
    tail -n "$keep_lines" "$file_path" > "$file_path.tmp" && mv "$file_path.tmp" "$file_path"
  fi
}

ensure_log_dir() {
  mkdir -p "$LOG_DIR"
  chmod 700 "$HOME/.nemoclaw" "$LOG_DIR" 2>/dev/null || true
  rotate_log_file "$LAUNCHER_LOG" 300
}

log_launcher() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LAUNCHER_LOG"
}

notify_user() {
  python3 - "$1" "$2" "${3:-}" <<'PY'
import subprocess
import sys

def esc(value: str) -> str:
    return value.replace('\\', '\\\\').replace('"', '\\"')

title = sys.argv[1]
message = sys.argv[2]
subtitle = sys.argv[3] if len(sys.argv) > 3 else ""
script = f'display notification "{esc(message)}" with title "{esc(title)}"'
if subtitle:
    script += f' subtitle "{esc(subtitle)}"'
subprocess.run(["osascript", "-e", script], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
PY
}

dashboard_ok() {
  python3 - "$DESKTOP_URL" <<'PY'
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

get_dashboard_token() {
  local sandbox_name="$1"
  python3 - "$sandbox_name" <<'PY'
import re
import subprocess
import sys

sandbox_name = sys.argv[1]
payload = """python3 - <<'PYTOKEN'
import json
import os

path = os.path.expanduser('~/.openclaw/openclaw.json')
try:
    cfg = json.load(open(path))
except Exception:
    print('')
else:
    print(cfg.get('gateway', {}).get('auth', {}).get('token', ''))
PYTOKEN
exit
"""

completed = subprocess.run(
    ["openshell", "sandbox", "connect", sandbox_name],
    input=payload,
    capture_output=True,
    text=True,
    check=False,
)

for line in reversed(completed.stdout.splitlines()):
    token = line.strip()
    if re.fullmatch(r"[A-Fa-f0-9]{32,}", token):
        sys.stdout.write(token)
        break
PY
}

get_dashboard_url() {
  local sandbox_name="$1"
  local token=""

  token="$(get_dashboard_token "$sandbox_name")"
  if [ -n "$token" ]; then
    printf '%s/#token=%s' "${DESKTOP_URL%/}" "$token"
    return 0
  fi

  printf '%s' "$DESKTOP_URL"
}

nemoclaw_cmd() {
  if installed_nemoclaw_available; then
    nemoclaw "$@"
  else
    cd "$REPO_DIR"
    node bin/nemoclaw.js "$@"
  fi
}

nemoclaw_cmd_label() {
  if installed_nemoclaw_available; then
    printf '%s' 'nemoclaw'
  else
    printf '%s' 'node bin/nemoclaw.js'
  fi
}

ensure_path() {
  export PATH="$LOCAL_BIN:$PATH"
  if [ -d "$HOME/.nvm/versions/node" ]; then
    local latest_node
    latest_node="$(find "$HOME/.nvm/versions/node" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort -V | tail -1 2>/dev/null || true)"
    if [ -n "$latest_node" ]; then
      export PATH="$HOME/.nvm/versions/node/$latest_node/bin:$PATH"
    fi
  fi
  if [ -s "$HOME/.nvm/nvm.sh" ]; then
    # shellcheck source=/dev/null
    . "$HOME/.nvm/nvm.sh"
    nvm use default >/dev/null 2>&1 || true
  fi
}

wait_for_docker() {
  if docker info >/dev/null 2>&1; then
    info "Docker is running."
    log_launcher "Docker already running."
    return 0
  fi

  info "Starting Docker Desktop..."
  log_launcher "Starting Docker Desktop."
  open -a Docker || true

  for _ in $(seq 1 90); do
    if docker info >/dev/null 2>&1; then
      info "Docker is ready."
      log_launcher "Docker became ready."
      return 0
    fi
    sleep 2
  done

  fail "Docker did not become ready. Start Docker Desktop manually, then retry."
}

ensure_node() {
  ensure_path
  command -v node >/dev/null 2>&1 || fail "Node.js not found. Install Node.js 20+ first."
  command -v npm >/dev/null 2>&1 || fail "npm not found. Install Node.js 20+ first."
}

ensure_deps() {
  cd "$REPO_DIR"
  if [ ! -d "$REPO_DIR/node_modules/openclaw" ]; then
    info "Installing root dependencies..."
    log_launcher "Installing root dependencies."
    npm install
  fi
}

ensure_global_nemoclaw() {
  ensure_path
  if command -v nemoclaw >/dev/null 2>&1; then
    return 0
  fi

  info "Installing global nemoclaw command..."
  log_launcher "Installing global nemoclaw command."
  cd "$REPO_DIR"
  npm link >/dev/null 2>&1 || fail "Failed to install global nemoclaw command."
  ensure_path
  command -v nemoclaw >/dev/null 2>&1 || fail "Global nemoclaw command is still unavailable after npm link."
}

ensure_openshell() {
  ensure_path
  if command -v openshell >/dev/null 2>&1; then
    info "OpenShell found: $(command -v openshell)"
    return 0
  fi

  info "Installing OpenShell locally..."
  log_launcher "Installing OpenShell locally."
  NEMOCLAW_NON_INTERACTIVE=1 bash "$REPO_DIR/scripts/install-openshell.sh"
  ensure_path
  command -v openshell >/dev/null 2>&1 || fail "OpenShell install failed."
}

ensure_credentials() {
  [ -f "$HOME/.nemoclaw/credentials.json" ] || fail "Missing ~/.nemoclaw/credentials.json. Your API keys need to be saved first."
}

ensure_launchagent() {
  local plist_path="$HOME/Library/LaunchAgents/local.nemoclaw.ui.plist"
  local agent_path="$HOME/.nemoclaw/bin/nemoclaw-ui-agent.sh"

  if [ -f "$plist_path" ] && [ -x "$agent_path" ]; then
    return 0
  fi

  info "Installing macOS self-heal LaunchAgent..."
  log_launcher "Installing macOS LaunchAgent."
  bash "$REPO_DIR/scripts/install-macos-launchagent.sh" >/dev/null
}

ensure_status_bar() {
  local status_app="$HOME/Applications/NemoClaw Status.app"

  if [ -d "$status_app" ]; then
    return 0
  fi

  local build_script="$REPO_DIR/Desktop/build-status-app.sh"
  if [ ! -f "$build_script" ]; then
    return 0
  fi

  info "Building and installing NemoClaw Status menu bar app..."
  log_launcher "Installing NemoClaw Status menu bar app."
  bash "$build_script" install >/dev/null 2>&1 || warn "Status bar app build failed (non-fatal)."
}

stop_dashboard_stack() {
  local sandbox_name="${1:-}"

  info "Stopping NemoClaw UI services..."
  log_launcher "Stopping NemoClaw UI services for sandbox '${sandbox_name:-unknown}'."

  bash "$REPO_DIR/scripts/start-services.sh" --stop >/dev/null 2>&1 || true

  if [ -n "$sandbox_name" ]; then
    openshell forward stop 18789 "$sandbox_name" >/dev/null 2>&1 || true
  fi
  openshell forward stop 18789 >/dev/null 2>&1 || true
  openshell gateway stop -g nemoclaw >/dev/null 2>&1 || true

  notify_user "NemoClaw" "UI stopped" "${sandbox_name:-No sandbox}"
}

gateway_connected() {
  openshell status 2>/dev/null | perl -pe 's/\e\[[0-9;]*[A-Za-z]//g' | grep -q 'Status: Connected'
}

ensure_gateway() {
  if gateway_connected; then
    info "OpenShell gateway is connected."
    return 0
  fi

  warn "Gateway is not connected. Re-establishing it..."
  openshell gateway select nemoclaw >/dev/null 2>&1 || true
  openshell gateway start --name nemoclaw >/dev/null 2>&1 || openshell gateway start >/dev/null 2>&1 || true

  for _ in $(seq 1 20); do
    if gateway_connected; then
      info "OpenShell gateway is healthy."
      return 0
    fi
    sleep 2
  done

  fail "Gateway did not become healthy. Try: openshell gateway info"
}

ensure_dashboard_forward() {
  local sandbox_name="$1"
  local forward_state=""

  forward_state="$(openshell forward list 2>/dev/null | awk -v name="$sandbox_name" '$1 == name && $3 == 18789 { print $5 }' | tail -1 || true)"

  if [ "$forward_state" = "dead" ]; then
    warn "Found dead dashboard forward. Cleaning it up..."
    openshell forward stop 18789 "$sandbox_name" >/dev/null 2>&1 || true
  fi

  if lsof -nP -iTCP:18789 -sTCP:LISTEN >/dev/null 2>&1 && ! dashboard_ok; then
    warn "Dashboard port 18789 is stale. Clearing existing listener..."
    openshell forward stop 18789 "$sandbox_name" >/dev/null 2>&1 || true
    openshell forward stop 18789 >/dev/null 2>&1 || true
    sleep 1
  fi

  if ! lsof -nP -iTCP:18789 -sTCP:LISTEN >/dev/null 2>&1; then
    info "Starting dashboard port forward for '$sandbox_name'..."
    openshell forward start --background 18789 "$sandbox_name"
  else
    info "Dashboard port 18789 is already listening."
  fi

  info "Waiting for dashboard to become reachable..."
  for _ in $(seq 1 30); do
    if dashboard_ok; then
      return 0
    fi
    sleep 1
  done

  fail "Dashboard did not come up on $DESKTOP_URL. Try: openshell forward start --background 18789 $sandbox_name"
}

get_default_sandbox() {
  node - "$1" <<'EOF'
const registry = require(process.argv[2]);
const current = registry.getDefault();
if (current) process.stdout.write(current);
EOF
}

remove_registered_sandbox() {
  local registry_path="$1"
  local sandbox_name="$2"

  node - "$registry_path" "$sandbox_name" <<'EOF'
const registry = require(process.argv[2]);
registry.removeSandbox(process.argv[3]);
EOF
}

sandbox_ready() {
  local sandbox_name="$1"
  openshell sandbox list 2>/dev/null | perl -pe 's/\e\[[0-9;]*[A-Za-z]//g' | awk -v name="$sandbox_name" 'NR > 1 && $1 == name && $NF == "Ready" { found=1 } END { exit found ? 0 : 1 }'
}

recreate_missing_sandbox() {
  local sandbox_name="$1"
  local api_key=""

  api_key="$(cd "$REPO_DIR" && node - <<'EOF'
const { getCredential } = require('./bin/lib/credentials');
process.stdout.write(getCredential('NVIDIA_API_KEY') || '');
EOF
)"

  [ -n "$api_key" ] || fail "Sandbox is missing and no saved NVIDIA_API_KEY is available to recreate it automatically."

  warn "Registered sandbox '$sandbox_name' is missing. Recreating it from saved configuration..."
  log_launcher "Recreating missing sandbox '$sandbox_name'."
  remove_registered_sandbox "$REPO_DIR/bin/lib/registry.js" "$sandbox_name"
  (
    cd "$REPO_DIR"
    NVIDIA_API_KEY="$api_key" \
    NEMOCLAW_SANDBOX_NAME="$sandbox_name" \
    node bin/nemoclaw.js onboard --non-interactive
  )
}

run_onboard() {
  info "No sandbox found. Starting first-run onboarding..."
  log_launcher "No sandbox found; starting onboarding."
  nemoclaw_cmd onboard
}

start_dashboard() {
  local sandbox_name="$1"
  local command_label
  local dashboard_url
  local should_open_browser="1"
  [ -n "$sandbox_name" ] || fail "No sandbox name available."

  command_label="$(nemoclaw_cmd_label)"
  if is_agent_mode; then
    should_open_browser="0"
  fi

  ensure_gateway
  ensure_dashboard_forward "$sandbox_name"
  dashboard_url="$(get_dashboard_url "$sandbox_name")"

  if [ "$should_open_browser" = "1" ]; then
    info "Opening NemoClaw dashboard in your browser..."
    log_launcher "Opening dashboard for sandbox '$sandbox_name'."
    open "$dashboard_url"
  else
    info "Dashboard ready at $dashboard_url"
    log_launcher "Dashboard ready for sandbox '$sandbox_name'."
  fi

  if [ "${NEMOCLAW_START_AUX_SERVICES:-0}" = "1" ]; then
    info "Starting auxiliary services..."
    NEMOCLAW_ENABLE_PUBLIC_TUNNEL="${NEMOCLAW_ENABLE_PUBLIC_TUNNEL:-0}" nemoclaw_cmd start || true
  else
    info "Skipping auxiliary services (local-only mode)."
  fi

  notify_user "NemoClaw Ready" "Dashboard is ready at 127.0.0.1:18789" "$sandbox_name"

  echo ""
  echo "  Dashboard: $dashboard_url"
  echo "  Sandbox:   $sandbox_name"
  echo ""
  echo "  Useful commands:"
  echo "    $command_label status"
  echo "    $command_label $sandbox_name connect"
  echo "    openshell term"
  echo ""
}

main() {
  validate_mode
  ensure_log_dir
  if ! is_agent_mode; then
    clear || true
    echo ""
    echo "  NemoClaw macOS Launcher"
    echo ""
  fi

  ensure_node
  ensure_openshell

  if ! is_stop_mode; then
    wait_for_docker
    ensure_deps
    ensure_global_nemoclaw
  fi

  if is_agent_mode && [ ! -f "$HOME/.nemoclaw/credentials.json" ]; then
    info "No credentials file yet. Agent exiting quietly."
    exit 0
  fi

  if ! is_stop_mode; then
    ensure_credentials
  fi

  if ! is_agent_mode && ! is_stop_mode; then
    ensure_launchagent
    ensure_status_bar
  fi

  local sandbox_name
  sandbox_name="$(get_default_sandbox "$REPO_DIR/bin/lib/registry.js")"

  if is_agent_mode && [ -z "$sandbox_name" ]; then
    info "No sandbox registered yet. Agent exiting quietly."
    exit 0
  fi

  if is_stop_mode; then
    stop_dashboard_stack "$sandbox_name"
    exit 0
  fi

  if [ -z "$sandbox_name" ] && ! is_recover_mode; then
    run_onboard
    sandbox_name="$(get_default_sandbox "$REPO_DIR/bin/lib/registry.js")"
  fi

  if [ -n "$sandbox_name" ] && ! sandbox_ready "$sandbox_name"; then
    recreate_missing_sandbox "$sandbox_name"
  fi

  if is_recover_mode && [ -n "$sandbox_name" ]; then
    info "Recovering UI for sandbox '$sandbox_name'..."
    log_launcher "Recovering UI for sandbox '$sandbox_name'."
    openshell forward stop 18789 "$sandbox_name" >/dev/null 2>&1 || true
  fi

  [ -n "$sandbox_name" ] || fail "No sandbox was registered after onboarding."

  if is_restart_mode; then
    info "Restarting NemoClaw UI for '$sandbox_name'..."
    log_launcher "Restarting NemoClaw UI for sandbox '$sandbox_name'."
    stop_dashboard_stack "$sandbox_name"
  fi

  start_dashboard "$sandbox_name"

  if should_pause_on_exit; then
    echo "Press Enter to close this window."
    read -r _
  fi
}

main "$@"
