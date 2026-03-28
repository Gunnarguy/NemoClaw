---
title:
  page: "NemoClaw Skills and Runtime Environments"
  nav: "Skills and Runtimes"
description: "How Copilot skills, OpenClaw chat, host tooling, and sandbox runtimes relate in NemoClaw."
keywords:
  [
    "nemoclaw skills",
    "copilot skills",
    "gemini cli missing",
    "sandbox runtime",
    "host vs sandbox",
  ]
topics: ["generative_ai", "ai_agents"]
tags: ["nemoclaw", "openclaw", "openshell", "copilot", "troubleshooting"]
content:
  type: reference
  difficulty: intermediate
  audience: ["developer", "engineer"]
status: published
---

<!--
  SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
  SPDX-License-Identifier: Apache-2.0
-->

# Skills and Runtime Environments

This page explains two concepts that are easy to conflate in NemoClaw.
First, it explains which skills belong to GitHub Copilot in VS Code versus OpenClaw in the browser.
Second, it explains why a CLI tool can exist on the host and still appear as missing from the sandboxed agent runtime.

## Two Different Chat Surfaces

NemoClaw involves two separate chat environments.

- VS Code Copilot chat is the coding and workflow surface you use with GitHub Copilot inside the editor.
- OpenClaw chat is the web UI running inside the OpenShell sandbox.

Copilot skills belong to the VS Code Copilot environment.
They do not automatically become runtime tools inside the OpenClaw browser chat.

## Copilot Skill Categories

The current environment exposes a mix of repo-local and extension-provided skills.

### Repo-local skills

These live in the repository and are specific to NemoClaw.

| Category | Skill         | Purpose                                                        |
| -------- | ------------- | -------------------------------------------------------------- |
| Docs     | `update-docs` | Scan recent code changes and draft or update user-facing docs. |

### Built-in or extension-provided skills

These come from Copilot or installed VS Code extensions.
They can change over time as the editor and extensions change.

| Category                 | Example skills                                                                                                                                | Purpose                                                                      |
| ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| GitHub review and triage | `summarize-github-issue-pr-notification`, `suggest-fix-issue`, `form-github-search-query`, `show-github-search-result`, `address-pr-comments` | Review issues and pull requests, summarize notifications, and suggest fixes. |
| Editor and search        | `get-search-view-results`                                                                                                                     | Read or summarize current search results in the editor.                      |
| Agent customization      | `agent-customization`                                                                                                                         | Create or debug instructions, prompts, custom agents, and skills.            |

## Runtime Boundaries

NemoClaw uses more than one execution environment.
Tooling visibility depends on which environment is actually running the command.

| Environment                    | What runs there                                               | Typical config location                                  |
| ------------------------------ | ------------------------------------------------------------- | -------------------------------------------------------- |
| Host shell                     | Your interactive terminal on macOS                            | Shell startup files and user PATH                        |
| macOS shortcut and LaunchAgent | Desktop app, helper commands, and background launch logic     | `~/.nemoclaw/`, `~/Library/LaunchAgents/`                |
| OpenShell host state           | Gateway, forwards, and CLI metadata                           | `~/.config/openshell/`                                   |
| Sandbox runtime                | OpenClaw and the NemoClaw plugin inside the sandbox container | Inside the sandbox, mainly `~/.openclaw/` and `/sandbox` |

The important rule is simple.
Host binaries are not automatically available inside the sandbox.

## Why a Host CLI Can Still Look Missing

If a tool is installed on the host, that only proves the host shell can find it.
It does not prove that the sandbox image includes that tool.

For example, a host check may succeed:

```console
$ command -v gemini
/Users/you/.nvm/versions/node/v22.x/bin/gemini
```

But the sandbox can still report that the same tool is missing if the sandbox image does not include it.

## Verified Gemini Example

In the current NemoClaw setup, the canonical macOS launcher path can resolve `gemini` on the host.
The running sandbox does not expose a `gemini` binary.

That means the current "Gemini missing" behavior is consistent with runtime isolation.
It does not mean the host install is broken.

## What Lives Where

Use these locations when debugging configuration.

- Host-side NemoClaw state lives under `~/.nemoclaw/`.
- OpenShell host metadata lives under `~/.config/openshell/`.
- The sandboxed OpenClaw runtime keeps its own configuration inside the sandbox, mainly under `~/.openclaw/`.
- Your repo-specific Python virtual environment, such as `.venv`, only affects commands that use that environment on the host. It does not define the sandbox image contents.

## When to Fix PATH and When to Fix the Image

Use a host PATH fix when a macOS shortcut, LaunchAgent, or terminal cannot find a host tool.

Use a sandbox image fix when the browser or agent runtime inside OpenClaw says a tool is missing, even though the host can resolve it.

If you need Gemini CLI inside the sandbox, install or provision it in the sandbox image or in whatever runtime the OpenClaw feature expects.
Installing it only on the host is not enough.
