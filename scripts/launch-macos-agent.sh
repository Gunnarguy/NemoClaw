#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$HOME/.nemoclaw/logs"

mkdir -p "$LOG_DIR"

exec "$REPO_DIR/scripts/launch-macos.sh" --agent >>"$LOG_DIR/launch-agent.log" 2>>"$LOG_DIR/launch-agent.err.log"
