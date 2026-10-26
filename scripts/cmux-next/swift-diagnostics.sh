#!/usr/bin/env bash
# Every Swift compiler diagnostic of a package build as diagnostics.jsonl
# {mode, target, file, line, group, message, fixits, ...}, from a build into a clean
# scratch folder or from persisted .dia files (swift_diagnostics.py). A build runs
# only as a fleet step:
#   cmux-ci run --class isolated --ref SHA --script scripts/cmux-next/swift-diagnostics.sh -- --summary
#   ... -- --package Packages/Shared/CmuxMessagesLab --summary --group StrictMemorySafety --fixits-out FILE
set -euo pipefail
exec python3 -I "$(dirname "${BASH_SOURCE[0]}")/swift_diagnostics.py" "$@"
