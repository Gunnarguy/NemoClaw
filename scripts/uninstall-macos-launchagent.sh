#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

PLIST_PATH="$HOME/Library/LaunchAgents/local.nemoclaw.ui.plist"
AGENT_PATH="$HOME/.nemoclaw/bin/nemoclaw-ui-agent.sh"

if [ -f "$PLIST_PATH" ]; then
  launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
  rm -f "$PLIST_PATH"
  echo "Removed LaunchAgent: $PLIST_PATH"
else
  echo "LaunchAgent not installed."
fi

if [ -f "$AGENT_PATH" ]; then
  rm -f "$AGENT_PATH"
  echo "Removed agent script: $AGENT_PATH"
fi
