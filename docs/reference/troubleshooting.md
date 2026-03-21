---
title:
  page: "NemoClaw Troubleshooting Guide"
  nav: "Troubleshooting"
description: "Diagnose and resolve common NemoClaw installation, onboarding, and runtime issues."
keywords: ["nemoclaw troubleshooting", "nemoclaw debug sandbox issues"]
topics: ["generative_ai", "ai_agents"]
tags: ["openclaw", "openshell", "troubleshooting", "nemoclaw"]
content:
  type: reference
  difficulty: technical_beginner
  audience: ["developer", "engineer"]
status: published
---

<!--
  SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
  SPDX-License-Identifier: Apache-2.0
-->

<!-- markdownlint-disable MD014 -->

# Troubleshooting

Start here when something goes wrong.
Run the quick diagnostic first — most problems show up immediately.

## Quick Diagnostic

Run these four commands. The first one that fails points you to the right section below.

```console
$ node --version          # Need v20+  → see "Node.js version is too old"
$ npm --version           # Need v10+  → usually fixed by upgrading Node.js
$ docker info             # Must be running → see "Docker is not running"
$ nemoclaw --version      # CLI on PATH → see "nemoclaw not found after install"
```

If all four pass, skip to [Onboarding](#onboarding) or [Runtime](#runtime).

---

:::{admonition} Get Help
:class: tip

If your issue is not listed here, join the [NemoClaw Discord channel](https://discord.gg/XFpfPv9Uvx) to ask questions and get help from the community. You can also [file an issue on GitHub](https://github.com/NVIDIA/NemoClaw/issues/new).
:::

## Installation

### `nemoclaw` not found after install

**What you see:** `command not found: nemoclaw` after the installer finishes.

**Why:** nvm/fnm installed Node.js into a directory that your current shell doesn't know about yet.

**Fix:**

```console
$ source ~/.bashrc        # or ~/.zshrc for zsh
$ nemoclaw --version      # should work now
```

Still nothing? Check where npm puts global binaries and ensure that directory is on PATH:

```console
$ npm config get prefix   # e.g. /home/you/.nvm/versions/node/v22.x
$ ls "$(npm config get prefix)/bin/nemoclaw"
```

### Installer fails on unsupported platform

**What you see:** "unsupported OS" or "unsupported architecture" error.

**Why:** NemoClaw requires Linux (Ubuntu 22.04+), macOS (Apple Silicon), or Windows WSL2.

**Fix:** Verify your OS and arch. On WSL, make sure you're running the installer _inside_ WSL, not from PowerShell.

### Node.js version is too old

**What you see:** Installer exits with a Node.js version error, or `node --version` reports < 20.

**Fix (nvm):**

```console
$ nvm install 22 && nvm use 22
```

**Fix (system):** Install Node.js 22 from [nodejs.org](https://nodejs.org) or your package manager, then re-run the installer.

### Docker is not running

**What you see:** "Cannot connect to the Docker daemon" or similar.

**Fix (Linux):**

```console
$ sudo systemctl start docker
```

**Fix (macOS):** Open Docker Desktop (or start Colima: `colima start`) and wait for the engine to finish starting.

### npm install fails with permission errors

**What you see:** `EACCES` permission error from npm.

**Why:** npm is trying to write to a root-owned directory. **Do not use `sudo npm`.**

**Fix:**

```console
$ mkdir -p ~/.npm-global
$ npm config set prefix ~/.npm-global
$ export PATH=~/.npm-global/bin:$PATH   # add to ~/.bashrc or ~/.zshrc
```

### Port 18789 already in use

**What you see:** Onboarding or gateway startup fails because port 18789 is taken.

**Fix:**

```console
$ lsof -i :18789          # find the process
$ kill <PID>              # stop it, then retry
```

---

## Onboarding

### Cgroup v2 errors during onboard

**What you see:** `Failed to start ContainerManager` or cgroup-related errors. Common on Ubuntu 24.04, DGX Spark, and WSL2.

**Fix:**

```console
$ sudo nemoclaw setup-spark
$ nemoclaw onboard
```

See the [DGX Spark guide](../get-started/dgx-spark.md) for full details.

### Invalid sandbox name

**What you see:** "invalid sandbox name" error from the wizard.

**Why:** Names must be lowercase alphanumeric + hyphens, starting and ending with a letter or digit. Examples: `my-assistant`, `dev1`.

### Sandbox creation fails on DGX

**What you see:** DNS timeout or stale port-forward errors during sandbox creation.

**Fix:** Re-run `nemoclaw onboard`. The wizard automatically cleans up stale port-forwards and retries gateway readiness.

### Colima socket not detected (macOS)

**What you see:** "Docker socket not found" on macOS with Colima.

**Why:** Newer Colima versions use `~/.config/colima/default/docker.sock` instead of `~/.colima/default/docker.sock`. NemoClaw checks both paths.

**Fix:** Verify Colima is running: `colima status`. If it's stopped, run `colima start`.

---

## Runtime

### Sandbox shows as stopped

**Fix:** Run `nemoclaw onboard` to recreate the sandbox from the same blueprint and policy definitions.

### Status shows "not running" inside the sandbox

This is expected behavior.
When checking status inside an active sandbox, host-side sandbox state and inference configuration are not inspectable.
The status command detects the sandbox context and reports "active (inside sandbox)" instead.

**Fix:** Check host-side state from outside the sandbox:

```console
$ openshell sandbox list
```

### Inference requests time out

**Check:**

```console
$ nemoclaw <name> status
```

If the endpoint is correct, check for network policy rules blocking the connection and verify your NVIDIA API key is valid at [build.nvidia.com](https://build.nvidia.com).

### Agent cannot reach an external host

**Why:** OpenShell blocks outbound connections not listed in the network policy.

**Fix:** Open the TUI to see blocked requests and approve them:

```console
$ openshell term
```

To permanently allow an endpoint, see [Customize the Network Policy](../network-policy/customize-network-policy.md).

### Blueprint run failed

**Fix:** View the error output:

```console
$ nemoclaw <name> logs
```

Use `--follow` to stream logs in real time while debugging.
