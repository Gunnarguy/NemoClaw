#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Shared installer helpers.  Both install.sh and scripts/install.sh source
# this file so that runtime validation, PATH refresh, shim creation, and
# version helpers stay in one place.
#
# Callers MUST define info(), warn(), error()/fail() BEFORE sourcing this file.

# ── Version constants ────────────────────────────────────────────────

MIN_NODE_MAJOR="${MIN_NODE_MAJOR:-20}"
MIN_NPM_MAJOR="${MIN_NPM_MAJOR:-10}"
RECOMMENDED_NODE_MAJOR="${RECOMMENDED_NODE_MAJOR:-22}"
RUNTIME_REQUIREMENT_MSG="NemoClaw requires Node.js >=${MIN_NODE_MAJOR} and npm >=${MIN_NPM_MAJOR} (recommended Node.js ${RECOMMENDED_NODE_MAJOR})."

# ── Utilities ────────────────────────────────────────────────────────

# Extract the major version number from a version string like "v22.14.0"
# or "10.9.2".  Strips a leading 'v' if present.
version_major() {
  printf '%s\n' "${1#v}" | cut -d. -f1
}

# Compare two dotted version strings (major.minor.patch).
# Returns 0 (true) if $1 >= $2.
version_gte() {
  local IFS=.
  # shellcheck disable=SC2206
  local -a a=($1) b=($2)
  for i in 0 1 2; do
    local ai=${a[$i]:-0} bi=${b[$i]:-0}
    if (( ai > bi )); then return 0; fi
    if (( ai < bi )); then return 1; fi
  done
  return 0
}

# ── nvm / PATH helpers ──────────────────────────────────────────────

# Load nvm into the current shell so that `node` and `npm` resolve to the
# nvm-installed version.
ensure_nvm_loaded() {
  if [ -z "${NVM_DIR:-}" ]; then
    export NVM_DIR="$HOME/.nvm"
  fi
  if [ -s "$NVM_DIR/nvm.sh" ]; then
    # shellcheck source=/dev/null
    \. "$NVM_DIR/nvm.sh"
  fi
}

# Add the npm global prefix bin and the user-local shim directory to PATH
# if they are not already present.
refresh_path() {
  ensure_nvm_loaded

  local npm_bin
  npm_bin="$(npm config get prefix 2>/dev/null)/bin" || true
  if [ -n "$npm_bin" ] && [ -d "$npm_bin" ]; then
    case ":$PATH:" in
      *":$npm_bin:"*) ;;
      *) export PATH="$npm_bin:$PATH" ;;
    esac
  fi

  local shim_dir="${NEMOCLAW_SHIM_DIR:-${HOME}/.local/bin}"
  if [ -d "$shim_dir" ]; then
    case ":$PATH:" in
      *":$shim_dir:"*) ;;
      *) export PATH="$shim_dir:$PATH" ;;
    esac
  fi
}

# Create a symlink at ~/.local/bin/nemoclaw → <npm prefix>/bin/nemoclaw
# so that nemoclaw is on PATH even when the npm prefix isn't.
# Returns 1 if the nemoclaw binary doesn't exist in the npm prefix.
ensure_nemoclaw_shim() {
  local shim_dir="${NEMOCLAW_SHIM_DIR:-${HOME}/.local/bin}"
  local npm_bin shim_path
  npm_bin="$(npm config get prefix 2>/dev/null)/bin" || true
  shim_path="${shim_dir}/nemoclaw"

  if [ -z "$npm_bin" ] || [ ! -x "$npm_bin/nemoclaw" ]; then
    return 1
  fi

  local orig_path="${ORIGINAL_PATH:-${PATH:-}}"
  case ":$orig_path:" in
    *":$npm_bin:"*|*":$shim_dir:"*) return 0 ;;
  esac

  mkdir -p "$shim_dir"
  ln -sfn "$npm_bin/nemoclaw" "$shim_path"
  refresh_path
  info "Created user-local shim at $shim_path"
  return 0
}

# ── Runtime validation ──────────────────────────────────────────────

# Verify that Node.js and npm meet the minimum version requirements.
# On failure, calls error() or fail() — whichever the caller defined.
ensure_supported_runtime() {
  local _err_fn="error"
  if type fail >/dev/null 2>&1; then _err_fn="fail"; fi

  command -v node >/dev/null 2>&1 || $_err_fn "${RUNTIME_REQUIREMENT_MSG} Node.js was not found on PATH."
  command -v npm  >/dev/null 2>&1 || $_err_fn "${RUNTIME_REQUIREMENT_MSG} npm was not found on PATH."

  local node_version npm_version node_major npm_major
  node_version="$(node --version 2>/dev/null || node -v 2>/dev/null || true)"
  npm_version="$(npm --version 2>/dev/null || true)"
  node_major="$(version_major "$node_version")"
  npm_major="$(version_major "$npm_version")"

  case "$node_major" in ''|*[!0-9]*) $_err_fn "Could not determine Node.js version from '${node_version}'. ${RUNTIME_REQUIREMENT_MSG}" ;; esac
  case "$npm_major"  in ''|*[!0-9]*) $_err_fn "Could not determine npm version from '${npm_version}'. ${RUNTIME_REQUIREMENT_MSG}" ;; esac

  if [ "$node_major" -lt "$MIN_NODE_MAJOR" ] || [ "$npm_major" -lt "$MIN_NPM_MAJOR" ]; then
    $_err_fn "Unsupported runtime detected: Node.js ${node_version:-unknown}, npm ${npm_version:-unknown}. ${RUNTIME_REQUIREMENT_MSG} Upgrade Node.js and rerun the installer."
  fi

  info "Runtime OK: Node.js ${node_version}, npm ${npm_version}"
}
