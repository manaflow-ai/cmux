#!/usr/bin/env bash
# Installs the competitors bench.py compares cmux with, each in its own empty directory under DEPS
# (default /tmp/cu-bench), at pinned versions. No API keys; nothing is installed globally.
#   tests/automation-bench/perf/setup.sh [DEPS]
# browser-use needs Python >= 3.11: uv makes the venv (uv from PATH, else uv installed into a private
# venv with pip); its managed Python is used when the system one is older.
set -euo pipefail
deps="${1:-/tmp/cu-bench}"
BROWSER_USE_VERSION="${BROWSER_USE_VERSION:-0.13.11}"
PLAYWRIGHT_MCP_VERSION="${PLAYWRIGHT_MCP_VERSION:-0.0.83}"
STAGEHAND_VERSION="${STAGEHAND_VERSION:-4.2.1}"
mkdir -p "$deps/browser-use" "$deps/playwright-mcp" "$deps/stagehand"
npm_bin="$(command -v npm)"
uv_bin="$(command -v uv || true)"
if [[ -z "$uv_bin" ]]; then
  python3 -m venv "$deps/uv-venv"
  "$deps/uv-venv/bin/pip" install -q uv
  uv_bin="$deps/uv-venv/bin/uv"
fi
if [[ ! -x "$deps/browser-use/.venv/bin/python" ]]; then
  (cd "$deps/browser-use" && "$uv_bin" venv -q --python 3.12 .venv)
fi
VIRTUAL_ENV="$deps/browser-use/.venv" "$uv_bin" pip install -q "browser-use==$BROWSER_USE_VERSION"
# --ignore-scripts: neither package needs an install script (Chrome comes from the caller).
(cd "$deps/playwright-mcp" && [[ -f package.json ]] || (cd "$deps/playwright-mcp" && "$npm_bin" init -y >/dev/null))
(cd "$deps/playwright-mcp" && "$npm_bin" install -q --ignore-scripts --no-fund --no-audit "@playwright/mcp@$PLAYWRIGHT_MCP_VERSION" >/dev/null)
(cd "$deps/stagehand" && [[ -f package.json ]] || (cd "$deps/stagehand" && "$npm_bin" init -y >/dev/null))
(cd "$deps/stagehand" && "$npm_bin" install -q --ignore-scripts --no-fund --no-audit "@browserbasehq/stagehand@$STAGEHAND_VERSION" >/dev/null)
echo "BENCH-DEPS browser-use=$("$deps/browser-use/.venv/bin/python" -I -c 'import importlib.metadata as m; print(m.version("browser-use"))') playwright-mcp=$(node -p "require('$deps/playwright-mcp/node_modules/@playwright/mcp/package.json').version") stagehand=$(node -p "require('$deps/stagehand/node_modules/@browserbasehq/stagehand/package.json').version")"
