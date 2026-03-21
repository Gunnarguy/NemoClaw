# ── NemoClaw Root Makefile ────────────────────────────────────────────
# Authoritative interface for bootstrap → build → check → test → docs.
# Run `make help` for a quick overview of available targets.
# ──────────────────────────────────────────────────────────────────────

.PHONY: help setup build test check lint format clean \
        lint-ts lint-py format-ts format-py \
        test-root test-plugin \
        doctor \
        docs docs-strict docs-live docs-clean

# ── Bootstrap ────────────────────────────────────────────────────────

setup: ## Install all dependencies (root + plugin + blueprint)
	npm install
	cd nemoclaw && npm install
	@if command -v uv >/dev/null 2>&1; then \
		uv sync --group docs; \
	else \
		echo "[WARN] uv not found — skipping Python/docs deps. Install: https://docs.astral.sh/uv/getting-started/installation/"; \
	fi
	@echo "✔ Setup complete. Run 'make doctor' to verify your environment."

# ── Build ────────────────────────────────────────────────────────────

build: ## Compile the TypeScript plugin
	cd nemoclaw && npm run build

# ── Check / Lint / Format ────────────────────────────────────────────

check: lint-ts lint-py ## Run all linters and type checks
	@echo "All checks passed."

lint: lint-ts lint-py

lint-ts:
	cd nemoclaw && npm run check

lint-py:
	cd nemoclaw-blueprint && $(MAKE) check

format: format-ts format-py

format-ts:
	cd nemoclaw && npm run lint:fix && npm run format

format-py:
	cd nemoclaw-blueprint && $(MAKE) format

# ── Test ─────────────────────────────────────────────────────────────

test: test-root test-plugin ## Run all test suites

test-root: ## Root unit tests (Node.js native runner)
	npm test

test-plugin: ## Plugin unit tests (Vitest)
	cd nemoclaw && npm test

# ── Doctor ───────────────────────────────────────────────────────────

doctor: ## Validate development prerequisites
	@echo "── NemoClaw Doctor ──"
	@printf "Node.js:     "; node --version 2>/dev/null || echo "MISSING — install Node.js >=20 (https://nodejs.org)"
	@printf "npm:         "; npm --version 2>/dev/null  || echo "MISSING — comes with Node.js"
	@printf "Python:      "; python3 --version 2>/dev/null || echo "MISSING — install Python >=3.11 (https://python.org)"
	@printf "uv:          "; uv --version 2>/dev/null || echo "MISSING — install uv (https://docs.astral.sh/uv/getting-started/installation/)"
	@printf "Docker:      "; docker --version 2>/dev/null || echo "MISSING — install Docker (https://docs.docker.com/get-docker/)"
	@printf "ruff:        "; ruff --version 2>/dev/null || echo "MISSING — install ruff (pip install ruff) or use 'uv tool install ruff'"
	@echo ""
	@echo "── Dependency state ──"
	@[ -d node_modules ] && echo "Root node_modules:    OK" || echo "Root node_modules:    MISSING — run 'make setup'"
	@[ -d nemoclaw/node_modules ] && echo "Plugin node_modules:  OK" || echo "Plugin node_modules:  MISSING — run 'make setup'"
	@[ -d nemoclaw/dist ] && echo "Plugin build:         OK" || echo "Plugin build:         NOT BUILT — run 'make build'"
	@echo ""

# ── Clean ────────────────────────────────────────────────────────────

clean: docs-clean ## Remove build artifacts
	cd nemoclaw && npm run clean
	rm -rf node_modules/.cache

# ── Documentation ────────────────────────────────────────────────────

docs: ## Build HTML docs
	uv run --group docs sphinx-build -b html docs docs/_build/html

docs-strict: ## Build docs with warnings-as-errors
	uv run --group docs sphinx-build -W -b html docs docs/_build/html

docs-live: ## Live-reload doc preview
	uv run --group docs sphinx-autobuild docs docs/_build/html --open-browser

docs-clean:
	rm -rf docs/_build

# ── Help ─────────────────────────────────────────────────────────────

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
