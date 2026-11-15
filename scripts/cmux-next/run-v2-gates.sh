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

run() {
  if ! "$@"; then
    failed=1
  fi
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

# acpmux-book (release)
book_gates() {
  run_book god_vs_small
  run_book kin_table_change_gate
  run_book sibling_insert_gate
  run_book family_page_gate
  run_book family_page_after_gate
  run_book folder_page_gate
  run_book random_replay_gate
  run_book cold_continuation_gate
  run_book pr05f_apply_newest
  run_book pr05f_apply_move
  run_book pr05f_first_window
  run_book pr05f_deep_page
  run_book pr05f_equal_entry
  run_book v2_pr03c_
  run_book v2_pr03d_
}
run_group acpmux-book book_gates

# acpmux-client (release)
client_gates() {
  run_client v2_pr06_client_chat
  run_client v2_pr04b_mirror_v1_rows_gate
}
run_group acpmux-client client_gates

# acpmux-core (release)
core_gates() {
  run_core replay_frame_gate
  run_core replay_append_gate
  run_core replay_open_hold_gate
  run_core single_encode_gate
  run_core list_window_gate_measures_running_subscriptions_at_both_sizes
  run_core pr05b_compaction_keeps_writing_through_one_million_changes
  run_core pr05b_startup_pages_and_hot_index_gate
  run_core pr05b_memory_attribution
  run_core pr05d_origin_state_ops
  run_core pr05d_removed_origin_batch
  run_core pr05d_submit_time
  run_core pr08_mirror_apply
  run_core pr08_mirror_local_row
  run_core v2_pr03c_
  run_core v2_pr04_chat_stopped_reader
}
run_group acpmux-core core_gates

# acpmux library gates (the gate profile avoids the release test build).
acpmux_lib_gates() {
  run_acpmux_lib tee_change_gate
  run_acpmux_lib stream_chunk_gate
  run_acpmux_lib walk_rss_gate
  run_acpmux_lib live_view_gate
  run_acpmux_lib keyed_page_gate
  run_acpmux_lib sidebar_mirror_connect_gate
  run_acpmux_lib hub_row_submit_gate
  run_acpmux_lib v2_pr08_reconnect_30
  run_acpmux_lib v2_pr08_fanout_30
  run_acpmux_lib v2_pr03b_tee_append_added
  run_acpmux_lib v2_pr03b_append_on_off
  run_acpmux_lib v2_pr03b_catchup_ack
  run_acpmux_lib hold_attach_gate
  # Row 7b: rows by key, and the CLI and MCP list callers.
  run_acpmux_lib v2_pr07b_info_rows
  run_acpmux_lib v2_pr07b_callers
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
  run_tui_core_lib v2_pr07c_update_plan
}
run_group cmux-tui-core-lib tui_core_lib_gates

# acpmux integration gates use the same gate profile and one v2_connection
# test binary.
acpmux_connection_gates() {
  run_acpmux_test v2_pr04_stopped_readers
  run_acpmux_test v2_pr04_offer_256_subscriptions
  run_acpmux_test v2_pr04_list_resume_end
}
run_group acpmux-v2-connection acpmux_connection_gates

exit "$failed"
