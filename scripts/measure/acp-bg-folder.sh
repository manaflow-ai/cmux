#!/usr/bin/env bash
# The acpmux daemon's cost of background-task folders at Leo's scale (300 chats of 40 ended tasks and one
# coordinator of 5,646; cmux-tui/crates/acpmux/src/hub/bg_folder_bench.rs): CPU per idle look over every chat
# (`tick`), per `_acpmux/bg/list` of the coordinator (`list`), and per list after a new record (`list_after_start`).
# This checkout, then BASE_SHA's acpmux background-task files with this checkout's bench, on one runner:
#   cmux-ci test -- bash -c 'scripts/measure/acp-bg-folder.sh BASE_SHA'
# Prints `AFTER BG_FOLDER_BENCH ...` and `BEFORE BG_FOLDER_BENCH ...` lines. Env ACPMUX_BG_BENCH_{CHATS,TASKS,BIG,ROUNDS}
# pass through. No BASE_SHA: this checkout only.
set -euo pipefail
base="${1:-}"
cd "$(git rev-parse --show-toplevel)/cmux-tui"
bench() {
  local tag=$1 home
  home=$(mktemp -d)
  ACPMUX_HOME=$home cargo test --release -p acpmux --lib bg_folder_bench -- --ignored --nocapture 2>&1 \
    | grep BG_FOLDER_BENCH | sed "s/^/$tag /"
  rm -rf "$home"
}
bench AFTER
[ -n "$base" ] || exit 0
depth=()
[ "$(git rev-parse --is-shallow-repository)" = true ] && depth=(--depth=1)
git cat-file -e "$base^{commit}" 2>/dev/null || git fetch -q --no-recurse-submodules ${depth[@]+"${depth[@]}"} origin "$base"
src=crates/acpmux/src
saved=$(mktemp -d)
cp -R "$src" "$saved/"
trap 'rm -rf "$src" && cp -R "$saved/src" "$src" && rm -rf "$saved"' EXIT
for f in bg_run.rs hub/bg_tasks.rs hub/machine_info.rs hub/workflow_activity.rs hub/mod.rs; do
  git show "$base:cmux-tui/$src/$f" >"$src/$f"
done
rm -f "$src/hub/bg_folder.rs"
grep -q 'mod bg_folder_bench;' "$src/hub/mod.rs" \
  || sed -i.bak 's/^mod bg_notify;$/#[cfg(all(test, unix))]\nmod bg_folder_bench;\nmod bg_notify;/' "$src/hub/mod.rs"
rm -f "$src/hub/mod.rs.bak"
bench BEFORE
