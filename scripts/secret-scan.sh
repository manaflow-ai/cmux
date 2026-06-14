#!/usr/bin/env bash
#
# Run the cmux secret scan locally (the same scan CI runs).
#
# Scans the working tree with gitleaks using the repo's narrow allowlist
# (.gitleaks.toml). Intentional Sentry-scrubber redaction fixtures and other
# known-public values are suppressed there, so any finding this prints is worth
# investigating. See docs/secret-scanning.md and
# https://github.com/manaflow-ai/cmux/issues/5978.
#
# Usage:
#   ./scripts/secret-scan.sh
#
# Exit codes: 0 = no leaks, 1 = leak(s) found, 2 = gitleaks not installed.
#
# Install gitleaks locally with:  brew install gitleaks
# Override the binary (used by CI) with: CMUX_GITLEAKS_BIN=/path/to/gitleaks

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

GITLEAKS_BIN="${CMUX_GITLEAKS_BIN:-gitleaks}"

if ! command -v "$GITLEAKS_BIN" >/dev/null 2>&1; then
  echo "error: '$GITLEAKS_BIN' not found." >&2
  echo "Install it with: brew install gitleaks" >&2
  echo "(or set CMUX_GITLEAKS_BIN to a gitleaks binary)" >&2
  exit 2
fi

cd "$PROJECT_DIR"

echo "==> Scanning working tree with $("$GITLEAKS_BIN" version 2>/dev/null || echo gitleaks) ..."

# `dir` scans the on-disk files (honouring .gitignore) rather than full git
# history, so it reflects what is currently checked in. --redact keeps any
# matched secret out of the scanner's own output.
#
# `|| status=$?` captures gitleaks' exit code without tripping `set -e` when it
# reports leaks (exit 1), so the summary below still runs.
status=0
"$GITLEAKS_BIN" dir "$PROJECT_DIR" \
  --config "$PROJECT_DIR/.gitleaks.toml" \
  --redact \
  --verbose \
  --no-banner || status=$?

if [ "$status" -eq 0 ]; then
  echo "==> No leaks found."
fi

exit "$status"
