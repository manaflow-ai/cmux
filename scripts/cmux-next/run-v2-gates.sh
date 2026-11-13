#!/usr/bin/env bash
set -o pipefail
set -u

# One list owns the nightly gate run. Cargo reuses the first test build for each
# crate while the filters below launch every gate that writes a registry row.
failed=0

run() {
  if ! "$@"; then
    failed=1
  fi
}

run_book() {
  run cargo test --release -p acpmux-book --lib "$1" -- --ignored --nocapture
}

run_core() {
  run cargo test --release -p acpmux-core --lib "$1" -- --ignored --nocapture
}

run_acpmux_lib() {
  run cargo test --profile gate -p acpmux --lib "$1" -- --ignored --nocapture
}

run_acpmux_test() {
  run cargo test --profile gate -p acpmux --test v2_connection "$1" -- --ignored --nocapture
}

# acpmux-book (release)
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

# acpmux-client has no v2 gate rows on this base; compile its ignored-test
# target once so the crate remains part of the release gate build set.
run cargo test --release -p acpmux-client --lib -- --ignored --nocapture

# acpmux-core (release)
run_core replay_frame_gate
run_core replay_append_gate
run_core single_encode_gate
run_core list_window_gate_measures_running_subscriptions_at_both_sizes
run_core pr05b_compaction_keeps_writing_through_one_million_changes
run_core pr05b_startup_pages_and_hot_index_gate
run_core pr05b_memory_attribution
run_core pr05d_origin_state_ops
run_core pr05d_removed_origin_batch
run_core pr05d_submit_time

# acpmux library gates (the gate profile avoids the release test build).
run_acpmux_lib tee_change_gate
run_acpmux_lib stream_chunk_gate
run_acpmux_lib walk_rss_gate
run_acpmux_lib live_view_gate
run_acpmux_lib keyed_page_gate

# acpmux integration gates use the same gate profile and one v2_connection
# test binary.
run_acpmux_test v2_pr04_stopped_readers
run_acpmux_test v2_pr04_offer_256_subscriptions
run_acpmux_test v2_pr04_list_resume_end

exit "$failed"
