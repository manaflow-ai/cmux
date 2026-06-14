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

# Keep this in sync with .github/workflows/secret-scan.yml (GITLEAKS_VERSION).
# gitleaks' default rule set (loaded via `[extend] useDefault = true`) and
# allowlist semantics evolve across releases, so a local run on a different
# version can diverge from CI. We only warn (not fail) so local scans stay easy.
EXPECTED_GITLEAKS_VERSION="8.30.1"

if ! command -v "$GITLEAKS_BIN" >/dev/null 2>&1; then
  echo "error: '$GITLEAKS_BIN' not found." >&2
  echo "Install it with: brew install gitleaks" >&2
  echo "(or set CMUX_GITLEAKS_BIN to a gitleaks binary)" >&2
  exit 2
fi

cd "$PROJECT_DIR"

gitleaks_version="$("$GITLEAKS_BIN" version 2>/dev/null | tr -d '[:space:]')"
gitleaks_version="${gitleaks_version#v}"  # normalize a possible "v8.30.1" prefix
echo "==> Scanning working tree with gitleaks ${gitleaks_version:-(unknown version)} ..."
if [ -n "$gitleaks_version" ] && [ "$gitleaks_version" != "$EXPECTED_GITLEAKS_VERSION" ]; then
  echo "warning: local gitleaks $gitleaks_version differs from the version CI pins" \
       "($EXPECTED_GITLEAKS_VERSION); results may differ from CI." >&2
  echo "         See docs/secret-scanning.md." >&2
fi

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
