---
title:
  page: "Set Up NemoClaw on DGX Spark"
  nav: "DGX Spark Setup"
description: "Platform-specific setup for running NemoClaw on NVIDIA DGX Spark (Ubuntu 24.04, cgroup v2)."
keywords: ["nemoclaw dgx spark", "cgroup v2 docker", "dgx spark setup"]
topics: ["generative_ai", "ai_agents"]
tags: ["openclaw", "openshell", "dgx_spark", "nemoclaw"]
content:
  type: how_to
  difficulty: technical_beginner
  audience: ["developer", "engineer"]
status: published
---

<!--
  SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
  SPDX-License-Identifier: Apache-2.0
-->

# Set Up NemoClaw on DGX Spark

DGX Spark ships Ubuntu 24.04 with Docker 28.x but no Kubernetes.
OpenShell embeds k3s inside a Docker container, which hits two platform-specific issues on Spark: Docker group permissions and cgroup v2 incompatibility.

The `setup-spark` command handles both automatically.

## Quick Start

```console
$ git clone https://github.com/NVIDIA/NemoClaw.git
$ cd NemoClaw
$ sudo npm install -g .
$ nemoclaw setup-spark
```

That's it. `setup-spark` configures Docker for cgroup v2 host delegation and adds your user to the `docker` group, then you can run the normal onboard wizard:

```console
$ nemoclaw onboard
```

## What `setup-spark` Does

### 1. Fixes Docker permissions

**Symptom:** `Permission denied (os error 13)` when connecting to the Docker socket.

**Cause:** Your user is not in the `docker` group.

**What `setup-spark` does:** Runs `usermod -aG docker $USER`. You may need to log out and back in (or run `newgrp docker`) for it to take effect.

### 2. Fixes cgroup v2 incompatibility

**Symptom:** `Failed to start ContainerManager` or `openat2 /sys/fs/cgroup/kubepods/pids.max: no such file`.

**Cause:** Spark runs cgroup v2 (Ubuntu 24.04 default). k3s inside the OpenShell gateway tries to create cgroup v1 paths that don't exist.

**What `setup-spark` does:** Sets `"default-cgroupns-mode": "host"` in `/etc/docker/daemon.json` and restarts Docker. This allows k3s to use the host cgroup namespace.

## Prerequisites

These should already be present on your Spark:

| Dependency     | Notes                                                                                                              |
| -------------- | ------------------------------------------------------------------------------------------------------------------ |
| Docker 28.x    | Pre-installed                                                                                                      |
| Node.js 22     | If missing: `curl -fsSL https://deb.nodesource.com/setup_22.x \| sudo -E bash - && sudo apt-get install -y nodejs` |
| OpenShell CLI  | See [OpenShell releases](https://github.com/NVIDIA/OpenShell/releases) (use `aarch64` binary for Spark)            |
| NVIDIA API key | Free from [build.nvidia.com](https://build.nvidia.com) — prompted during onboarding                                |

## Manual Setup

If `setup-spark` does not work, apply the fixes manually:

### Fix Docker cgroup namespace

```console
$ stat -fc %T /sys/fs/cgroup/
cgroup2fs

$ sudo python3 -c "
import json, os
path = '/etc/docker/daemon.json'
d = json.load(open(path)) if os.path.exists(path) else {}
d['default-cgroupns-mode'] = 'host'
json.dump(d, open(path, 'w'), indent=2)
"

$ sudo systemctl restart docker
```

### Fix Docker permissions

```console
$ sudo usermod -aG docker $USER
$ newgrp docker
```

### Run the onboard wizard

```console
$ nemoclaw onboard
```

## Known Issues

| Issue                         | Status                    | Workaround                                                           |
| ----------------------------- | ------------------------- | -------------------------------------------------------------------- |
| cgroup v2 kills k3s in Docker | Fixed in `setup-spark`    | `daemon.json` cgroupns=host                                          |
| Docker permission denied      | Fixed in `setup-spark`    | `usermod -aG docker`                                                 |
| CoreDNS CrashLoop after setup | Fixed in `fix-coredns.sh` | Uses container gateway IP, not 127.0.0.11                            |
| Image pull failure            | OpenShell bug             | `openshell gateway destroy && openshell gateway start`, re-run setup |
| GPU passthrough               | Untested on Spark         | Should work with `--gpu` if NVIDIA Container Toolkit is configured   |

## Verifying Your Install

```console
$ openshell sandbox list
# Should show: nemoclaw  Ready

$ nemoclaw my-assistant connect
sandbox@my-assistant:~$ openclaw tui
```

## Architecture

```text
DGX Spark (Ubuntu 24.04, cgroup v2)
  └── Docker (28.x, cgroupns=host)
       └── OpenShell gateway container
            └── k3s (embedded)
                 └── nemoclaw sandbox pod
                      └── OpenClaw agent + NemoClaw plugin
```
