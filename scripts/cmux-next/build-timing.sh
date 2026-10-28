#!/usr/bin/env bash
# Incremental build timing for the generated wire targets (p05-ipc-194,
# plans/cmux-next/app-daemon-connection-DESIGN.md section 9.1).
#
# Times a warm CmuxNext `swift build` after a leaf edit (a private function
# body in DaemonRequest.swift) and after a one-field schema edit (one optional
# request field in cmux-tui/spec/sdk-schema.json), and records host, sha,
# seconds, the rebuilt targets and whether the wire generator ran. Run it before
# p05-ipc-027, after 027 and after 025 (shas in section 9.1). Fleet only:
#
#   cmux-ci run --class isolated --ref SHA \
#     --script 'scripts/cmux-next/build-timing.sh --leaf-edit --schema-edit'
#
# Usage:
#   scripts/cmux-next/build-timing.sh [--leaf-edit] [--schema-edit] [--rust]
#       [--repeat 3] [--target CmuxNextApp] [--leaf-file PATH]
#       [--schema-file PATH] [--schema-command NAME] [--scratch-path DIR]
#       [--max-leaf-seconds 30] [--label TEXT] [--out PATH]
#
# Writes artifacts/build-timing/<sha>.json and prints one design-table row per
# edit. Exits 1 when a leaf edit takes the budget or longer or reruns the
# generator, 2 on a usage error, 3 when a build fails. Every edited file is
# put back as it was, also on failure. With --rust it first runs
# `git submodule update --init --depth 1 ghostty-next` (cargo builds
# libghostty-vt from it and a fleet step's submodules are empty) and exits 2,
# before any build, when that fails.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
exec python3 "$repo_root/scripts/cmux-next/build_timing.py" --repo-root "$repo_root" "$@"
