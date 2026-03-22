---
title:
  page: "NemoClaw Hub for macOS — Menu Bar Dashboard and Remote Control"
  nav: "macOS Hub App"
description: "Build and install the NemoClaw Hub, a macOS menu bar app for monitoring sandboxes, managing policies, and controlling the Telegram bridge."
keywords: ["nemoclaw macos hub", "nemoclaw menu bar app", "nemoclaw dashboard macos"]
topics: ["generative_ai", "ai_agents"]
tags: ["openclaw", "openshell", "macos", "monitoring", "nemoclaw"]
content:
  type: how_to
  difficulty: intermediate
  audience: ["developer", "engineer"]
status: published
---

<!--
  SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
  SPDX-License-Identifier: Apache-2.0
-->

# macOS Hub App

```{include} ../_includes/alpha-statement.md
```

The NemoClaw Hub is a native macOS menu bar app that provides a single window for monitoring sandboxes, configuring inference, toggling network policies, and controlling the Telegram bridge.

The Hub lives in your menu bar and opens a full dashboard when you click its icon.

## Prerequisites

- macOS 13 (Ventura) or later on Apple Silicon.
- Xcode Command Line Tools installed (`xcode-select --install`).
- A cloned copy of the NemoClaw repository.

## Build the Hub

From the root of the NemoClaw repository, run the build script:

```console
$ bash Desktop/build-status-app.sh
```

The script compiles the Swift source, assembles a `.app` bundle, and places it at `Desktop/build/NemoClaw Status.app`.

## Run the Hub

Launch the Hub without installing it:

```console
$ bash Desktop/build-status-app.sh run
```

A shipping-box icon appears in your menu bar.
Click it and select **Open NemoClaw Hub** to open the dashboard window.

## Install as a Login Item

To install the Hub to `~/Applications` and register a LaunchAgent so it starts automatically at login:

```console
$ bash Desktop/build-status-app.sh install
```

The LaunchAgent is written to `~/Library/LaunchAgents/local.nemoclaw.status.plist`.
The Hub will start automatically on your next login.

To stop the LaunchAgent manually:

```console
$ launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/local.nemoclaw.status.plist
```

To restart it:

```console
$ launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.nemoclaw.status.plist
```

## Dashboard Sections

The Hub window has a sidebar with nine sections.

### Overview

Shows the dashboard status, sandbox count, GPU information, upstream sync state, running services, and credentials summary.
Use the sandbox dropdown to switch the active sandbox context.

### Sandboxes

Lists existing sandboxes with their model, provider, GPU status, and applied policies.
Each sandbox card has **Connect**, **Status**, and **Delete** buttons.

The **Create New Sandbox** form at the top provides an in-app onboard wizard.
Fill in a name, select a model and provider, toggle GPU support, and choose policy presets.
Click **Run Onboard Wizard** to open an interactive Terminal session, or **Quick Create** to launch a non-interactive onboard with environment variables pre-set.

### Inference

Displays GPU detection results and local backend status (Ollama, vLLM).
Use the provider and model dropdowns to change inference configuration, then click **Apply to Active Sandbox**.

### Policies

Toggle network policy presets on or off with switches.
Nine presets are available: Docker, Discord, Hugging Face, Jira, npm, Outlook, PyPI, Slack, and Telegram.
Each switch shows the allowed endpoints for that preset.

Click **Apply All Policies to Sandbox** to write the selected presets.
Click **Auto-Detect Suggested Presets** to enable presets based on which credential tokens are configured.

### Bridges

Shows the status of the Telegram bridge, Discord bridge, Slack bridge, and Cloudflare tunnel.
Start or stop the Telegram bridge directly from this panel.

### Telegram Remote

A dedicated panel for the Telegram bridge with a commands reference table, chat ID restriction field, and a test-message button.
A live log view at the bottom streams the bridge output with a three-second refresh interval.

### Upstream Sync

Shows how many commits the local fork is behind the NVIDIA upstream.
Click **Fetch Now** to check, or **Trigger GitHub Action** to dispatch the auto-sync workflow.
Recent upstream commits are listed below.

### Credentials

Displays each credential (NVIDIA API Key, GitHub Token, Telegram Bot Token, Discord Bot Token, Slack Bot Token) with its status.
Click **Set** to enter a value through a secure input dialog.
Credentials are stored in `~/.nemoclaw/credentials.json` with file permissions set to `600`.

### Logs

Streams sandbox, Telegram bridge, or Cloudflare tunnel logs in real time.
Use the source dropdown to switch between log sources.
Logs auto-refresh every three seconds with automatic scroll-to-bottom.

## Notifications

The Hub requests permission to send macOS notifications for three events:

- The NemoClaw dashboard goes offline or comes back online.
- New commits appear on the NVIDIA upstream that have not been merged.
- A messaging bridge process stops unexpectedly.

Notifications use the standard macOS notification center and can be managed in **System Settings > Notifications**.

## Uninstall

To remove the LaunchAgent and installed app:

```console
$ launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/local.nemoclaw.status.plist
$ rm ~/Library/LaunchAgents/local.nemoclaw.status.plist
$ rm -rf ~/Applications/NemoClaw\ Status.app
```

## Related Topics

- [Monitor sandbox activity](monitor-sandbox-activity.md) through the OpenShell TUI.
- [Set up the Telegram bridge](../deployment/set-up-telegram-bridge.md) for remote agent chat.
- [Customize the network policy](../network-policy/customize-network-policy.md) to manage egress rules.
