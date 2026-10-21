#!/usr/bin/env bash
# Run the web lints on what differs from origin/feat-cmux-next (uncommitted edits
# included). `--fix` autofixes formatting and fixable lint rules first. The
# pre-push hook and the `web lint` CI job run the same checks.
# See scripts/web_lint_prepush.py --help.
set -euo pipefail
exec python3 -I "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/web_lint_prepush.py" "$@"
