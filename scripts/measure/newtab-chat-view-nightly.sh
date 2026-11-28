#!/usr/bin/env bash
# Fleet entry for scripts/measure/newtab-chat-view-nightly.py (see its docstring); packs report.tgz.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
python3 scripts/measure/newtab-chat-view-nightly.py "$@"
rc=$?
tar -czf .build/newtab-chat-view-nightly.tgz -C .build newtab-chat-view-nightly && mv .build/newtab-chat-view-nightly.tgz .build/newtab-chat-view-nightly/report.tgz
exit $rc
