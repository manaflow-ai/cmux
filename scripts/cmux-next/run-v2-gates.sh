#!/usr/bin/env bash
set -o pipefail
set -u

: "${V2_GATE_OUT:?V2_GATE_OUT must name the shared nightly measures file}"

# One list owns the nightly gate run. Cargo reuses the first test build for each
# crate while the filters below launch every gate that writes a registry row.
failed=0

run_group() {
  local name=$1
  shift
  local started=$SECONDS
  "$@"
  printf 'v2 gate group %s: %d seconds\n' "$name" "$((SECONDS - started))"
}

# A filter that fails after writing its rows: every line its run appended gets
# "gate_failed":true, and the v2 home reads those rows red with their numbers.
run() {
  local before=0
  [[ -f $V2_GATE_OUT ]] && before=$(wc -l <"$V2_GATE_OUT")
  if ! "$@"; then
    failed=1
    mark_failed "$before"
  fi
}

mark_failed() {
  local marked
  [[ -f $V2_GATE_OUT ]] && marked=$(mktemp) || return 0
  sed "$(($1 + 1)),\$ s/}[[:space:]]*\$/,\"gate_failed\":true}/" "$V2_GATE_OUT" >"$marked" \
    && cat "$marked" >"$V2_GATE_OUT"
  rm -f "$marked"
}

run_book() {
  run cargo test --release -p acpmux-book --lib "$1" -- --ignored --nocapture --test-threads=1
}

run_client() {
  run cargo test --release -p acpmux-client --lib "$1" -- --ignored --nocapture --test-threads=1
}

run_core() {
  run cargo test --release -p acpmux-core --lib "$1" -- --ignored --nocapture --test-threads=1
}

run_acpmux_lib() {
  run cargo test --profile gate -p acpmux --lib "$1" -- --ignored --nocapture --test-threads=1
}

run_tui_core_lib() {
  run cargo test --profile gate -p cmux-tui-core --lib "$1" -- --ignored --nocapture --test-threads=1
}

run_acpmux_test() {
  run cargo test --profile gate -p acpmux --test v2_connection "$1" -- --ignored --nocapture --test-threads=1
}

# The gate lines are in v2-gates.d, one file per row of the design doc's PR table:
# `pr03d.gates` holds the lines whose tests write `v2.pr03d.*` rows, so a PR that adds
# a gate edits only its own row's file. A line is `GROUP FILTER` (a `#` starts a
# comment): GROUP is a word of gate_runner below, FILTER the names of the gate tests the
# group's runner starts. Inside a group the lines run in file name order, then in
# line order. An unknown group or a line of another shape fails the script by name.
# The script keeps to bash 3.2, a Mac's stock bash: no associative arrays.
gates_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/v2-gates.d"
gate_groups="book client core acpmux-lib tui-core-lib acpmux-v2-connection"

# Each group word and the runner it starts. A group's timing line is named by its word.
gate_runner() {
  case $1 in
    book) echo run_book ;;
    client) echo run_client ;;
    core) echo run_core ;;
    acpmux-lib) echo run_acpmux_lib ;;
    tui-core-lib) echo run_tui_core_lib ;;
    acpmux-v2-connection) echo run_acpmux_test ;;
    *) return 1 ;;
  esac
}

gate_lines=()
read_gates() {
  local LC_ALL=C file line number group filter rest
  for file in "$gates_dir"/*.gates; do
    [[ -e $file ]] || continue
    number=0
    while IFS= read -r line || [[ -n $line ]]; do
      number=$((number + 1))
      read -r group filter rest <<<"${line%%#*}"
      [[ -n $group ]] || continue
      if [[ -z $filter || -n $rest || ! $filter =~ ^[A-Za-z0-9_]+$ ]]; then
        printf '%s:%d: a gate line is GROUP FILTER: %s\n' "$file" "$number" "$line" >&2
        return 1
      fi
      if ! gate_runner "$group" >/dev/null; then
        printf '%s:%d: %s is not a gate group\n' "$file" "$number" "$group" >&2
        return 1
      fi
      gate_lines+=("$group $filter")
    done <"$file"
  done
}
read_gates || exit 2

run_gates() {
  local runner line
  runner=$(gate_runner "$1")
  for line in ${gate_lines[@]+"${gate_lines[@]}"}; do
    if [[ ${line%% *} == "$1" ]]; then "$runner" "${line#* }"; fi
  done
}

# book, client and core run the release test build; acpmux-lib, tui-core-lib (row 7c's
# list callers, against an agent service in the test's process) and acpmux-v2-connection
# (one v2_connection test binary) use the gate profile, which avoids it.
for group in $gate_groups; do
  run_group "$group" run_gates "$group"
done

exit "$failed"
