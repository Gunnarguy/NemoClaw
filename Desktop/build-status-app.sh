#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Build and optionally install the NemoClaw Status menu bar app.
# Usage:
#   ./build-status-app.sh          # build only
#   ./build-status-app.sh install  # build + install to ~/Applications
#   ./build-status-app.sh run      # build + run immediately

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/NemoClawStatus"
BUILD_DIR="$SCRIPT_DIR/build"
APP_NAME="NemoClaw Status.app"
APP_PATH="$BUILD_DIR/$APP_NAME"

SWIFT_SRC="$SRC_DIR/NemoClawStatus.swift"
INFO_PLIST="$SRC_DIR/Info.plist"
ICON_SRC="$SCRIPT_DIR/icons/NemoClaw.icns"

GREEN='\033[0;32m'
NC='\033[0m'

info() { printf "${GREEN}[build]${NC} %s\n" "$*"; }

if [ ! -f "$SWIFT_SRC" ]; then
  echo "Error: $SWIFT_SRC not found." >&2
  exit 1
fi

# --- Build ---
info "Compiling NemoClawStatus..."
mkdir -p "$BUILD_DIR"
swiftc \
  -O \
  -target arm64-apple-macos13 \
  -framework Cocoa \
  -framework Foundation \
  -o "$BUILD_DIR/NemoClawStatus" \
  "$SWIFT_SRC"

# --- Assemble .app bundle ---
info "Assembling $APP_NAME..."
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"
cp "$BUILD_DIR/NemoClawStatus" "$APP_PATH/Contents/MacOS/"
cp "$INFO_PLIST" "$APP_PATH/Contents/"

if [ -f "$ICON_SRC" ]; then
  cp "$ICON_SRC" "$APP_PATH/Contents/Resources/NemoClaw.icns"
fi

info "Built: $APP_PATH"

# --- Install / Run ---
ACTION="${1:-}"

if [ "$ACTION" = "install" ]; then
  INSTALL_DIR="$HOME/Applications"
  mkdir -p "$INSTALL_DIR"
  rm -rf "$INSTALL_DIR/$APP_NAME"
  cp -R "$APP_PATH" "$INSTALL_DIR/$APP_NAME"
  info "Installed to $INSTALL_DIR/$APP_NAME"

  # Optionally add a LaunchAgent to start at login
  PLIST_PATH="$HOME/Library/LaunchAgents/local.nemoclaw.status.plist"
  cat >"$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>local.nemoclaw.status</string>
  <key>ProgramArguments</key>
  <array>
    <string>$INSTALL_DIR/$APP_NAME/Contents/MacOS/NemoClawStatus</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
  # kickstart ensures exactly one instance is launched by launchd
  launchctl kickstart -k "gui/$(id -u)/local.nemoclaw.status" 2>/dev/null || true
  info "LaunchAgent installed — starts at login."
fi

if [ "$ACTION" = "run" ]; then
  # Only use 'open' for ad-hoc runs without a LaunchAgent
  info "Launching NemoClaw Status..."
  open "$APP_PATH"
fi

info "Done."
