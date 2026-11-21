#!/bin/bash
# The merge drivers' interpreter. scripts/install-git-hooks.sh writes each merge.*.driver as
# `/bin/bash <clone>/cmux-git-hooks/merge_python.sh <clone>/cmux-merge-drivers/<driver>.py %O %A %B ...`, and this
# runs the driver under the Python hook_python.sh (beside it) picks on this host each time: the one the install
# recorded when it runs, else the first of its fixed candidates that does. A driver command that named one recorded
# path left every such merge a conflict once that interpreter was gone. The drivers need only the standard library.
# None that resolves into the work tree or the git dir of the merge is ever run.
set -euo pipefail

HOOK_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd -P)"
RECORDED_PYTHON=""
if [[ -r "$HOOK_DIR/python3-path" ]]; then
    IFS= read -r RECORDED_PYTHON < "$HOOK_DIR/python3-path" || true
fi
# shellcheck source=hook_python.sh
source "$HOOK_DIR/hook_python.sh"
# git runs a merge driver at the top of the work tree.
if ! hook_python_pick 0 "$RECORDED_PYTHON" "$(pwd -P)" "${HOOK_DIR%/*}"; then
    echo "cmux merge driver: no Python 3.9+ on this host runs ${1##*/}. Tried: $HOOK_PYTHON_TRIED. Next: install one" \
        "(macOS: brew install python; Debian or Ubuntu: sudo apt-get install -y python3), then rerun" \
        "scripts/install-git-hooks.sh." >&2
    exit 1
fi
exec "$HOOK_PYTHON" -I "$@"
