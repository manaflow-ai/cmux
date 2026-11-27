#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Bound the kept Rust target directories (warm nightly-next builder)". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# The warm builder keeps the Rust target directories (above). Cargo
# never deletes old artifacts, so start them over above 30 GiB.
set -euo pipefail
dirs=(cmux-tui/target Native/OptChat/optchat-chief/target cmux-next-ios/rust/target)
kib=0
for d in "${dirs[@]}"; do
  [ -d "$d" ] && kib=$((kib + $(du -sk "$d" | awk '{print $1}')))
done
echo "kept Rust target directories: $((kib / 1024)) MiB"
if [ "$kib" -gt $((30 * 1024 * 1024)) ]; then
  echo "above 30 GiB: removing them; the next build compiles the helpers again"
  rm -rf "${dirs[@]}"
fi
