#!/usr/bin/env bash
# Installs the comparison's third-party tools into this directory only:
# js-tiktoken and Stagehand (npm), browser-use (uv venv in .venv).
set -euo pipefail
cd "$(dirname "$0")"
command npm install --no-audit --no-fund
uv venv -q -p 3.12 .venv
VIRTUAL_ENV="$PWD/.venv" uv pip install -q "browser-use==0.13.10"
