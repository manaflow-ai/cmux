#!/usr/bin/env bash
# The connection-notices check, as cmux-next.yml's checks job runs it (one line there: the workflow file is
# near GitHub's size limit; its own tests run from their own line there). ROOT is the checkout; the ratchet compares with the base tip HEAD^1.
# Why: docs/ci/cmux-next-workflow-notes.md#note-464
set -euo pipefail
root="${1:?usage: check-connection-notices.sh ROOT}"
here="$(cd "$(dirname "$0")" && pwd)"
# First the report of views disabled or dimmed while the link connects (Leo, 2026-11-24: "the entire thing is somehow
# grayed out and I can't interact with anything at all"). It prints and never fails the check: a blocking rule needs
# Leo's own word.
python3 -I "$here/check-connection-notices.py" --root "$root" --input-block || echo "input-block report did not run (exit $?)"
# Then the check, which fails a new unbounded connection state.
python3 -I "$here/check-connection-notices.py" --root "$root" --base HEAD^1
