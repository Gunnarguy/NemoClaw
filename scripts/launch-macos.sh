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

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[1;34m'
NC='\033[0m'

info() { printf "${BLUE}[nemoclaw]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[nemoclaw]${NC} %s\n" "$*"; }
fail() { printf "${RED}[nemoclaw]${NC} %s\n" "$*"; exit 1; }

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
    latest_node="$(ls "$HOME/.nvm/versions/node" 2>/dev/null | sort -V | tail -1 2>/dev/null || true)"
    if [ -n "$latest_node" ]; then
      export PATH="$HOME/.nvm/versions/node/$latest_node/bin:$PATH"
    fi
  fi
  if [ -s "$HOME/.nvm/nvm.sh" ]; then
    # shellcheck disable=SC1090
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

run_onboard() {
  info "No sandbox found. Starting first-run onboarding..."
  log_launcher "No sandbox found; starting onboarding."
  nemoclaw_cmd onboard
}

start_dashboard() {
  local sandbox_name="$1"
  local command_label
  local should_open_browser="1"
  [ -n "$sandbox_name" ] || fail "No sandbox name available."

  command_label="$(nemoclaw_cmd_label)"
  if [ "$MODE" = "--agent" ]; then
    should_open_browser="0"
  fi

  ensure_gateway
  ensure_dashboard_forward "$sandbox_name"

  if [ "$should_open_browser" = "1" ]; then
    info "Opening NemoClaw dashboard in your browser..."
    log_launcher "Opening dashboard for sandbox '$sandbox_name'."
    open "$DESKTOP_URL"
  else
    info "Dashboard ready at $DESKTOP_URL"
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
  echo "  Dashboard: $DESKTOP_URL"
  echo "  Sandbox:   $sandbox_name"
  echo ""
  echo "  Useful commands:"
  echo "    $command_label status"
  echo "    $command_label $sandbox_name connect"
  echo "    openshell term"
  echo ""
}

main() {
  ensure_log_dir
  if [ "$MODE" != "--agent" ]; then
    clear || true
    echo ""
    echo "  NemoClaw macOS Launcher"
    echo ""
  fi

  ensure_node
  wait_for_docker
  ensure_deps
  ensure_global_nemoclaw
  ensure_openshell
  if [ "$MODE" = "--agent" ] && [ ! -f "$HOME/.nemoclaw/credentials.json" ]; then
    info "No credentials file yet. Agent exiting quietly."
    exit 0
  fi
  ensure_credentials
  if [ "$MODE" != "--agent" ]; then
    ensure_launchagent
    ensure_status_bar
  fi

  local sandbox_name
  sandbox_name="$(get_default_sandbox "$REPO_DIR/bin/lib/registry.js")"

  if [ "$MODE" = "--agent" ] && [ -z "$sandbox_name" ]; then
    info "No sandbox registered yet. Agent exiting quietly."
    exit 0
  fi

  if [ -z "$sandbox_name" ] && [ "$MODE" != "--recover-ui" ]; then
    run_onboard
    sandbox_name="$(get_default_sandbox "$REPO_DIR/bin/lib/registry.js")"
  fi

  if [ "$MODE" = "--recover-ui" ] && [ -n "$sandbox_name" ]; then
    info "Recovering UI for sandbox '$sandbox_name'..."
    log_launcher "Recovering UI for sandbox '$sandbox_name'."
    openshell forward stop 18789 "$sandbox_name" >/dev/null 2>&1 || true
  fi

  [ -n "$sandbox_name" ] || fail "No sandbox was registered after onboarding."
  start_dashboard "$sandbox_name"

  if [ "$MODE" != "--agent" ]; then
    echo "Press Enter to close this window."
    read -r _
  fi
}

main "$@"
