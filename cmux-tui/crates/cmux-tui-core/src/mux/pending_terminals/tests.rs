use super::*;

/// Refusals make a host unadoptable only after enough of them in a row over
/// the minimum span; any other outcome starts the count again.
#[test]
fn refusal_streak_needs_count_and_span() {
    let start = Instant::now();
    let mut streak = RefusalStreak::default();
    assert!(!streak.record(true, start));
    assert!(!streak.record(true, start + Duration::from_secs(1)));
    // Three refusals, but within a burst shorter than the span.
    assert!(!streak.record(true, start + Duration::from_secs(2)));
    assert!(streak.record(true, start + NO_COMMON_PROTOCOL_MIN_SPAN));

    // A non-refusal resets the count and the start time.
    assert!(!streak.record(false, start + Duration::from_secs(20)));
    let later = start + Duration::from_secs(30);
    assert!(!streak.record(true, later));
    assert!(!streak.record(true, later + NO_COMMON_PROTOCOL_MIN_SPAN));
    assert!(streak.record(true, later + NO_COMMON_PROTOCOL_MIN_SPAN));
}

/// R-LIFECYCLE S1b (review of #34188, finding 2): only a terminal whose
/// runtime this owner holds can be a kept tab of an ended command, so the
/// count never reads the row of a terminal this owner holds no runtime for
/// (an earlier owner's exited rows stay: no row is ever deleted). The row
/// here is written after this owner started, with a receipt no build can
/// read: a read of it would make the count an error, and an unreadable
/// count keeps an app session's owner forever (server/owner_keepers.rs).
#[test]
fn the_kept_terminal_count_reads_no_row_this_owner_holds_no_runtime_for() {
    let mux = Mux::new_for_test("kept-count", SurfaceOptions::default());
    mux.workspace_registry
        .lock()
        .unwrap()
        .connection
        .get()
        .execute(
            "INSERT INTO terminal_hosts (terminal_id, workspace_key, incarnation, lifecycle,
                 launch_spec_json, exit_json, on_exit, created_revision, updated_revision)
             VALUES ('0123456789ab4def8123456789abcdef', 'w', NULL, 'exited', '{}',
                 'not a receipt', 'keep', 1, 1)",
            [],
        )
        .unwrap();
    assert_eq!(
        mux.kept_terminal_count().ok(),
        Some(0),
        "the count read an exited row this owner holds no runtime for"
    );
}
