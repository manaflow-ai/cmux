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

# The page's rows: webviews/bench/v2-gate.ts runs the rows whose names hold FILTER and appends the
# home's line for each. Store-only rows run under bun; a row that needs a DOM starts a browser and
# fails by name where none launches.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
run_page() {
  run bun "$repo_root/webviews/bench/v2-gate.ts" "$1"
}

# The gate lines are in v2-gates.d, one file per row of the design doc's PR table:
# `pr03d.gates` holds the lines whose tests write `v2.pr03d.*` rows, so a PR that adds
# a gate edits only its own row's file. A line is `GROUP FILTER` (a `#` starts a
# comment): GROUP is a word of the table below, FILTER the names of the gate tests the
# group's runner starts. Inside a group the lines run in file name order, then in
# line order. An unknown group or a line of another shape fails the script by name.
gates_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/v2-gates.d"
declare -A group_runner=(
  [book]=run_book
  [client]=run_client
  [core]=run_core
  [acpmux-lib]=run_acpmux_lib
  [tui-core-lib]=run_tui_core_lib
  [acpmux-v2-connection]=run_acpmux_test
  [page]=run_page
)
declare -A group_filters=()

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
      if [[ -z ${group_runner[$group]+set} ]]; then
        printf '%s:%d: %s is not a gate group\n' "$file" "$number" "$group" >&2
        return 1
      fi
      group_filters[$group]+="$filter "
    done <"$file"
  done
}
read_gates || exit 2

run_gates() {
  local group=$1 filter
  for filter in ${group_filters[$group]:-}; do
    "${group_runner[$group]}" "$filter"
  done
}

# acpmux-book (release)
book_gates() {
  run_gates book
}
run_group acpmux-book book_gates

# acpmux-client (release)
client_gates() {
  run_gates client
}
run_group acpmux-client client_gates

# acpmux-core (release)
core_gates() {
  run_gates core
}
run_group acpmux-core core_gates

# acpmux library gates (the gate profile avoids the release test build).
acpmux_lib_gates() {
  run_gates acpmux-lib
}
run_group acpmux-lib acpmux_lib_gates

# cmux-tui-core links libghostty-vt (ghostty-vt-sys): its build needs the ghostty-next
# submodule's source and zig, which neither the nightly's Rust setup nor a plain `cmux-ci test`
# checkout holds (`cmux-ci test --setup rust` does). Under CI the group gets both itself, the way
# fast-checks.yml's "Initialize Rust native dependencies" step does (decision 282); off CI, or where
# an input cannot be had, the group fails with a line naming it, never a build panic. Run from cmux-tui/.
tui_core_native_ready() {
  local root
  root=$(git rev-parse --show-toplevel) || return 1
  if [[ -z "${CMUX_GHOSTTY_SRC:-}" && ! -f "$root/ghostty-next/build.zig" ]]; then
    if [[ -z "${CI:-}" ]]; then
      echo "v2 gates: the ghostty-next submodule is empty; cmux-tui-core's gates need it (cmux-ci test --setup rust)" >&2
      return 1
    fi
    echo "v2 gates: the ghostty-next submodule is empty; initializing it for cmux-tui-core"
    (cd "$root" && bash scripts/ci/init-submodule.sh ghostty-next) || {
      echo "v2 gates: cannot initialize ghostty-next; cmux-tui-core's gates need it (cmux-ci test --setup rust)" >&2
      return 1
    }
  fi
  if ! command -v zig >/dev/null 2>&1 && [[ -z "${CMUX_ZIG:-}" ]]; then
    if [[ -z "${CI:-}" ]]; then
      echo "v2 gates: no zig on PATH; cmux-tui-core's gates need it (cmux-ci test --setup rust)" >&2
      return 1
    fi
    echo "v2 gates: no zig on PATH; installing the pinned zig for cmux-tui-core"
    # The installer exports CMUX_ZIG only to a GitHub job's later steps; this shell reads it back.
    local zig_env
    zig_env=$(mktemp)
    # ghostty-next names the Zig cmux-tui needs; the installer reads the classic tree's otherwise.
    (cd "$root" && GHOSTTY_ZIG_SOURCE=ghostty-next GITHUB_ENV="$zig_env" \
      GITHUB_PATH="$zig_env.path" ./scripts/install-zig-ci.sh > "$zig_env.log" 2>&1) || {
      tail -n 5 "$zig_env.log" >&2
      rm -f "$zig_env" "$zig_env.path" "$zig_env.log"
      echo "v2 gates: cannot install zig; cmux-tui-core's gates need it (cmux-ci test --setup rust)" >&2
      return 1
    }
    local zig_dir
    zig_dir=$(head -n 1 "$zig_env.path" 2>/dev/null || true)
    if [[ -n "$zig_dir" ]]; then
      export PATH="$zig_dir:$PATH"
    fi
    local cmux_zig
    cmux_zig=$(sed -n 's/^CMUX_ZIG=//p' "$zig_env" | tail -n 1)
    if [[ -n "$cmux_zig" ]]; then
      export CMUX_ZIG="$cmux_zig"
    fi
    rm -f "$zig_env" "$zig_env.path" "$zig_env.log"
  fi
  # bindgen loads libclang; fast-checks installs it with apt (sudo), which this script never does.
  if [[ -z "${LIBCLANG_PATH:-}" ]] && ! ldconfig -p 2>/dev/null | grep -q 'libclang'; then
    echo "v2 gates: no libclang for ghostty-vt-sys's bindgen; cmux-tui-core's gates need it (cmux-ci test --setup rust)" >&2
    return 1
  fi
}

# cmux-tui-core's list callers (row 7c), against an agent service in the test's process.
tui_core_lib_gates() {
  if ! tui_core_native_ready; then
    failed=1
    return
  fi
  run_gates tui-core-lib
}
run_group cmux-tui-core-lib tui_core_lib_gates

# acpmux integration gates use the same gate profile and one v2_connection
# test binary.
acpmux_connection_gates() {
  run_gates acpmux-v2-connection
}
run_group acpmux-v2-connection acpmux_connection_gates

# The page group needs the bun webviews/package.json pins (scripts/check-webviews-bun-version.sh).
# The workflow that runs this script sets it up first (cmux-next-quality-report.yml, the pinned
# setup-bun step); the script only checks it and, where it cannot be had, fails the group with a
# line naming it, never installing anything itself.
page_ready() {
  "$repo_root/scripts/check-webviews-bun-version.sh" --quiet && return 0
  "$repo_root/scripts/check-webviews-bun-version.sh" || true
  echo "v2 gates: no bun of the webviews pin on PATH; the page group's rows need it" >&2
  return 1
}

# The page's rows (webviews/bench/v2-gate.ts), after the cargo groups.
page_gates() {
  if ! page_ready; then
    failed=1
    return
  fi
  run_gates page
}
run_group page page_gates

exit "$failed"
