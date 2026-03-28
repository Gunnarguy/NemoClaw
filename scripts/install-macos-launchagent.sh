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

cat >"$AGENT_PATH" <<EOF
#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$REPO_DIR"
LOG_DIR="\$HOME/.nemoclaw/logs"

mkdir -p "\$LOG_DIR"

exec "\$REPO_DIR/scripts/launch-macos.sh" --agent >>"\$LOG_DIR/launch-agent.log" 2>>"\$LOG_DIR/launch-agent.err.log"
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
