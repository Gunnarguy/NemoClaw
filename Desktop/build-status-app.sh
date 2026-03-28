#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="NemoClaw Status"
APP_DIR="$HOME/Applications/${APP_NAME}.app"
DESKTOP_APP_NAME="NemoClaw"
DESKTOP_APP_DIR="$HOME/Desktop/${DESKTOP_APP_NAME}.app"
SOURCE_PATH="$REPO_DIR/Desktop/NemoClawShell.swift"
LAUNCHER_PATH="$REPO_DIR/scripts/launch-macos.sh"
BIN_DIR="$HOME/.nemoclaw/bin"
MACBUD_PATH="$BIN_DIR/macbud"
OBSOLETE_CONTROL_PLIST="$HOME/Library/LaunchAgents/local.nemoclaw.control.plist"
OBSOLETE_CONTROL_SCRIPT="$BIN_DIR/macbud-control.py"
STATUS_BUNDLE_ID="local.nemoclaw.status"
DESKTOP_BUNDLE_ID="local.nemoclaw.desktop"
EXECUTABLE_NAME="NemoClawShell"
DASHBOARD_URL="http://127.0.0.1:18789"
ACTION="${1:-install}"

mkdir -p "$HOME/Applications" "$BIN_DIR"

build_native_binary() {
  local build_dir="$1"

  command -v xcrun >/dev/null 2>&1 || {
    echo "xcrun is required to build the native macOS shell." >&2
    exit 1
  }

  xcrun swiftc \
    -parse-as-library \
    -target arm64-apple-macos13.0 \
    -framework AppKit \
    -framework SwiftUI \
    "$SOURCE_PATH" \
    -o "$build_dir/$EXECUTABLE_NAME"
}

write_info_plist() {
  local plist_path="$1"
  local app_display_name="$2"
  local bundle_identifier="$3"
  local app_mode="$4"

  cat > "$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>$app_display_name</string>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$bundle_identifier</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$app_display_name</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>NemoClaw needs access to the repository in your Documents folder to launch and manage the local UI stack.</string>
  <key>NSDesktopFolderUsageDescription</key>
  <string>NemoClaw stores the shell app on your Desktop and needs access to manage it.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NemoClawAppMode</key>
  <string>$app_mode</string>
  <key>NemoClawLauncherPath</key>
  <string>$LAUNCHER_PATH</string>
  <key>NemoClawDashboardURL</key>
  <string>$DASHBOARD_URL</string>
  <key>NemoClawDesktopAppPath</key>
  <string>$DESKTOP_APP_DIR</string>
  <key>NemoClawStatusAppPath</key>
  <string>$APP_DIR</string>
  <key>NemoClawDesktopBundleIdentifier</key>
  <string>$DESKTOP_BUNDLE_ID</string>
  <key>NemoClawStatusBundleIdentifier</key>
  <string>$STATUS_BUNDLE_ID</string>
</dict>
</plist>
EOF
}

install_app_bundle() {
  local target_app_dir="$1"
  local app_display_name="$2"
  local bundle_identifier="$3"
  local app_mode="$4"
  local build_dir="$5"

  rm -rf "$target_app_dir"
  mkdir -p "$target_app_dir/Contents/MacOS"

  cp "$build_dir/$EXECUTABLE_NAME" "$target_app_dir/Contents/MacOS/$EXECUTABLE_NAME"
  write_info_plist "$target_app_dir/Contents/Info.plist" "$app_display_name" "$bundle_identifier" "$app_mode"

  codesign --force --deep --sign - "$target_app_dir" >/dev/null
}

install_macbud_helper() {
  cat > "$MACBUD_PATH" <<EOF
#!/usr/bin/env bash
set -euo pipefail

LAUNCHER_PATH="${LAUNCHER_PATH}"
STATUS_APP_PATH="${APP_DIR}"
DESKTOP_APP_PATH="${DESKTOP_APP_DIR}"

case "\${1:-open}" in
  open|app|on)
    exec open "\${DESKTOP_APP_PATH}"
    ;;
  start)
    exec env NEMOCLAW_OPEN_BROWSER=0 /bin/bash "\${LAUNCHER_PATH}" --app-start
    ;;
  stop|off|kill)
    exec /bin/bash "\${LAUNCHER_PATH}" --app-stop
    ;;
  restart)
    exec env NEMOCLAW_OPEN_BROWSER=0 /bin/bash "\${LAUNCHER_PATH}" --app-restart
    ;;
  quit|close)
    handled=0
    if osascript -e 'tell application "${APP_NAME}" to quit' >/dev/null 2>&1; then
      handled=1
    fi
    if osascript -e 'tell application "${DESKTOP_APP_NAME}" to quit' >/dev/null 2>&1; then
      handled=1
    fi
    if [ "\$handled" -eq 0 ]; then
      exec /bin/bash "\${LAUNCHER_PATH}" --app-stop
    fi
    ;;
  browser|dashboard)
    exec open "${DASHBOARD_URL}"
    ;;
  controls|panel)
    exec open "\${STATUS_APP_PATH}"
    ;;
  status|"")
    if command -v nemoclaw >/dev/null 2>&1; then
      exec nemoclaw status
    fi
    exec node "${REPO_DIR}/bin/nemoclaw.js" status
    ;;
  *)
    echo "Usage: macbud [open|app|start|stop|restart|quit|status|controls|browser]" >&2
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
    build_dir="$(mktemp -d "${TMPDIR:-/tmp}/nemoclaw-shell-build.XXXXXX")"
    trap 'rm -rf "$build_dir"' EXIT

    cleanup_obsolete_shortcuts
    [ -f "$SOURCE_PATH" ] || {
      echo "Missing source file: $SOURCE_PATH" >&2
      exit 1
    }

    build_native_binary "$build_dir"
    install_app_bundle "$APP_DIR" "$APP_NAME" "$STATUS_BUNDLE_ID" "status" "$build_dir"
    install_app_bundle "$DESKTOP_APP_DIR" "$DESKTOP_APP_NAME" "$DESKTOP_BUNDLE_ID" "desktop" "$build_dir"
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
