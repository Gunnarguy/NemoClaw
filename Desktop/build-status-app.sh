#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="NemoClaw Status"
APP_DIR="$HOME/Applications/${APP_NAME}.app"
DESKTOP_APP_NAME="NemoClaw"
DESKTOP_APP_DIR="$HOME/Desktop/${DESKTOP_APP_NAME}.app"
BUILD_DIR="$REPO_DIR/Desktop/.build"
SCRIPT_PATH="$BUILD_DIR/${APP_NAME}.applescript"
DESKTOP_SCRIPT_PATH="$BUILD_DIR/${DESKTOP_APP_NAME}.applescript"
APP_LOG_DIR="$HOME/.nemoclaw/logs"
APP_LOG_PATH="$APP_LOG_DIR/status-app.log"
DESKTOP_APP_LOG_PATH="$APP_LOG_DIR/desktop-app.log"
LAUNCHER_PATH="$REPO_DIR/scripts/launch-macos.sh"
BIN_DIR="$HOME/.nemoclaw/bin"
MACBUD_PATH="$BIN_DIR/macbud"
OBSOLETE_CONTROL_PLIST="$HOME/Library/LaunchAgents/local.nemoclaw.control.plist"
OBSOLETE_CONTROL_SCRIPT="$BIN_DIR/macbud-control.py"
ACTION="${1:-install}"

mkdir -p "$BUILD_DIR" "$HOME/Applications" "$APP_LOG_DIR" "$BIN_DIR"

build_app() {
  cat > "$SCRIPT_PATH" <<EOF
on run
  my showControls()
end run

on reopen
  my showControls()
end reopen

on showControls()
  set launcherPath to "${LAUNCHER_PATH}"
  set statusLogPath to "${APP_LOG_PATH}"
  set promptText to "NemoClaw controls\n\nStart or reopen the dashboard, stop the UI stack, or restart it cleanly."
  set buttonChoice to button returned of (display dialog promptText buttons {"Cancel", "Stop", "Restart", "Start", "Open Dashboard"} default button "Open Dashboard" cancel button "Cancel" with title "NemoClaw Status")

  if buttonChoice is "Cancel" then
    return
  else if buttonChoice is "Stop" then
    my runAction("--app-stop", launcherPath, statusLogPath)
  else if buttonChoice is "Restart" then
    my runAction("--app-restart", launcherPath, statusLogPath)
  else if buttonChoice is "Start" then
    my runAction("--app-start", launcherPath, statusLogPath)
  else if buttonChoice is "Open Dashboard" then
    my runAction("--app-start", launcherPath, statusLogPath)
  end if
end showControls

on runAction(modeFlag, launcherPath, statusLogPath)
  set commandText to "/usr/bin/nohup /bin/bash " & quoted form of launcherPath & " " & quoted form of modeFlag & " >>" & quoted form of statusLogPath & " 2>&1 &"
  do shell script commandText
end runAction
EOF

  rm -rf "$APP_DIR"
  osacompile -o "$APP_DIR" "$SCRIPT_PATH"
}

build_desktop_app() {
  if [ -d "$DESKTOP_APP_DIR/Contents/MacOS" ]; then
    cat > "$DESKTOP_APP_DIR/Contents/MacOS/NemoClaw" <<EOF
#!/bin/bash
set -euo pipefail
mkdir -p "$APP_LOG_DIR"
exec /usr/bin/nohup /bin/bash "$LAUNCHER_PATH" --app-start >>"$DESKTOP_APP_LOG_PATH" 2>&1 &
EOF
    chmod +x "$DESKTOP_APP_DIR/Contents/MacOS/NemoClaw"
    return 0
  fi

  cat > "$DESKTOP_SCRIPT_PATH" <<EOF
on run
  do shell script "/usr/bin/nohup /bin/bash " & quoted form of "${LAUNCHER_PATH}" & " --app-start >>" & quoted form of "${DESKTOP_APP_LOG_PATH}" & " 2>&1 &"
end run
EOF

  rm -rf "$DESKTOP_APP_DIR"
  osacompile -o "$DESKTOP_APP_DIR" "$DESKTOP_SCRIPT_PATH"
}

install_macbud_helper() {
  cat > "$MACBUD_PATH" <<EOF
#!/usr/bin/env bash
set -euo pipefail

LAUNCHER_PATH="${LAUNCHER_PATH}"
STATUS_APP_PATH="${APP_DIR}"

case "\${1:-open}" in
  open|start|on)
    exec /bin/bash "${LAUNCHER_PATH}" --app-start
    ;;
  stop|off|kill)
    exec /bin/bash "${LAUNCHER_PATH}" --app-stop
    ;;
  restart)
    exec /bin/bash "${LAUNCHER_PATH}" --app-restart
    ;;
  controls|panel)
    exec open "${APP_DIR}"
    ;;
  status|"")
    if command -v nemoclaw >/dev/null 2>&1; then
      exec nemoclaw status
    fi
    exec node "${REPO_DIR}/bin/nemoclaw.js" status
    ;;
  *)
    echo "Usage: macbud [open|start|stop|restart|status|controls]" >&2
    exit 1
    ;;
esac
EOF

  chmod +x "$MACBUD_PATH"
}

cleanup_obsolete_shortcuts() {
  launchctl bootout "gui/$(id -u)" "$OBSOLETE_CONTROL_PLIST" >/dev/null 2>&1 || true
  rm -f "$OBSOLETE_CONTROL_PLIST" "$OBSOLETE_CONTROL_SCRIPT"
}

case "$ACTION" in
  install|build)
    cleanup_obsolete_shortcuts
    build_app
    build_desktop_app
    install_macbud_helper
    echo "Built ${APP_DIR}"
    echo "Prepared ${DESKTOP_APP_DIR}"
    echo "Installed ${MACBUD_PATH}"
    ;;
  uninstall)
    cleanup_obsolete_shortcuts
    rm -rf "$APP_DIR"
    rm -rf "$DESKTOP_APP_DIR"
    rm -f "$MACBUD_PATH"
    echo "Removed ${APP_DIR}"
    echo "Removed ${DESKTOP_APP_DIR}"
    echo "Removed ${MACBUD_PATH}"
    ;;
  *)
    echo "Usage: $0 [install|build|uninstall]" >&2
    exit 1
    ;;
esac
