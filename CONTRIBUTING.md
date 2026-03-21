# Contributing to NVIDIA NemoClaw

Thank you for your interest in contributing to NVIDIA NemoClaw. This guide covers how to set up your development environment, run tests, and submit changes.

## Before You Open an Issue

Open an issue when you encounter one of the following situations.

- A real bug that you confirmed and could not fix.
- A feature proposal with a design — not a "please build this" request.
- Security vulnerabilities must follow [SECURITY.md](SECURITY.md) — **not** GitHub issues.

## Prerequisites

Install the following before you begin.

- Node.js 20+ and npm 10+
- Python 3.11+ (for blueprint and documentation builds)
- Docker (running)
- [uv](https://docs.astral.sh/uv/) (for Python dependency management)

## Getting Started

One command installs every dependency (root CLI, TypeScript plugin, and Python blueprint):

```bash
make setup    # installs root + plugin + blueprint deps
make doctor   # verify all prerequisites are healthy
make build    # compile the TypeScript plugin
make test     # run the full test suite
```

If `make doctor` reports a missing tool, install it before continuing.

## Main Tasks

Every developer action has a `make` target. Run `make help` for the full list.

| Task               | Purpose                                      |
| ------------------ | -------------------------------------------- |
| `make setup`       | Install all deps (root + plugin + blueprint) |
| `make doctor`      | Verify Node, npm, Python, uv, Docker, ruff   |
| `make build`       | Compile the TypeScript plugin (`tsc`)        |
| `make test`        | Run **all** test suites (root + plugin)      |
| `make test-root`   | Root unit tests only (`node --test`)         |
| `make test-plugin` | Plugin unit tests only (Vitest)              |
| `make check`       | Run all linters (TypeScript + Python)        |
| `make format`      | Auto-format TypeScript and Python source     |
| `make clean`       | Remove build artifacts                       |
| `make docs`        | Build documentation (Sphinx/MyST)            |
| `make docs-live`   | Serve docs locally with hot-reload           |

## Project Structure

The repository is organized as follows.

| Path                  | Purpose                                               |
| --------------------- | ----------------------------------------------------- |
| `nemoclaw/`           | TypeScript plugin (Commander CLI, OpenClaw extension) |
| `nemoclaw-blueprint/` | Python blueprint for sandbox orchestration            |
| `bin/`                | CLI entry point (`nemoclaw.js`)                       |
| `scripts/`            | Install helpers and automation scripts                |
| `test/`               | Root-level integration tests                          |
| `docs/`               | User-facing documentation (Sphinx/MyST)               |

## Documentation

If your change affects user-facing behavior (new commands, changed defaults, new features, bug fixes that contradict existing docs), update the relevant pages under `docs/` in the same PR.

If you use an AI coding agent (Cursor, Claude Code, Codex, etc.), the repo includes the `/update-docs` skill that drafts doc updates. Use them before writing from scratch and follow the style guide in [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md).

To build and preview docs locally:

```bash
make docs       # build the docs
make docs-live  # serve locally with auto-rebuild
```

See [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) for the full style guide and writing conventions.

## Pull Requests

We welcome contributions. Every PR requires maintainer review. To keep the review queue healthy, limit the number of open PRs you have at any time to fewer than 10.

> [!WARNING]
> Accounts that repeatedly exceed this limit or submit automated bulk PRs may have their PRs closed or their access restricted.

Follow these steps to submit a pull request.

1. Create a feature branch from `main`.
2. Make your changes with tests.
3. Run `make check && make test` to verify locally.
4. Run `make doctor` if you changed dependencies or build steps.
5. Open a PR.

### Commit Messages

This project uses [Conventional Commits](https://www.conventionalcommits.org/). All commit messages must follow the format:

```
<type>(<scope>): <description>

[optional body]

[optional footer(s)]
```

**Types:**

- `feat` - New feature
- `fix` - Bug fix
- `docs` - Documentation only
- `chore` - Maintenance tasks (dependencies, build config)
- `refactor` - Code change that neither fixes a bug nor adds a feature
- `test` - Adding or updating tests
- `ci` - CI/CD changes
- `perf` - Performance improvements

**Examples:**

```
feat(cli): add --profile flag to nemoclaw onboard
fix(blueprint): handle missing API key gracefully
docs: update quickstart for new install wizard
chore(deps): bump commander to 13.2
```
