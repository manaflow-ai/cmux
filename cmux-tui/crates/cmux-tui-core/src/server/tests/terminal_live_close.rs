//! A terminal's entry in the live log (`mux/terminal_live.rs`) and its
//! close.
//!
//! The entry says that the terminal has a live fact the `session.events`
//! streams did not send yet. It goes when the close is applied, not when the
//! close is planned: a close whose commit fails leaves the terminal open, and
//! its pending live fact must still reach the streams.

use super::*;

/// The terminal prints and reports a progress value: live facts only.
fn live_fact(surface: &crate::Surface, progress: u8, at_ms: u64) {
    surface
        .apply_stream_output_for_test(format!("\x1b]9;4;1;{progress}\x07line\r\n").as_bytes())
        .unwrap();
    surface.note_output_at_for_test(at_ms);
    surface.publish_pending_state();
}

/// Whether the live log has an entry for `terminal`.
fn has_live_mark(mux: &Mux, terminal: &TerminalPublicId) -> bool {
    mux.terminal_live_changes_after(0).1.iter().any(|(_, marked)| marked == terminal)
}

/// A session of one terminal (a test terminal: no child process) at rest.
fn one_terminal(mux: &Arc<Mux>) -> (Arc<crate::Surface>, TerminalPublicId) {
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    surface.publish_pending_directory();
    surface.publish_pending_progress();
    assert!(
        mux.wait_for_terminal_publisher_for_test(Duration::from_secs(30)),
        "the terminal publisher did not drain"
    );
    let terminal = surface.terminal_public_id().expect("a public terminal").clone();
    (surface, terminal)
}

/// `terminal.close` of `terminal` on a new connection; the response.
fn close_terminal(mux: &Arc<Mux>, terminal: &TerminalPublicId, key: &str) -> Value {
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let close = resource_request(
        key,
        "terminal.close",
        json!({"machine":"current", "session":"current", "terminal":terminal}),
        Some(key),
    );
    assert!(handle_connection_message(mux, client, &close, &writer, &scheduler));
    let response = pop_json(&outbound);
    disconnect_client(mux, client, false);
    response
}

#[test]
fn a_terminal_close_that_fails_keeps_the_pending_live_fact_of_its_terminal() {
    let mux = test_mux();
    let (surface, terminal) = one_terminal(&mux);
    let at_ms = crate::workspace_registry::unix_epoch_ms().unwrap() + 60_000;
    live_fact(&surface, 10, at_ms);
    assert!(has_live_mark(&mux, &terminal), "a live fact did not mark its terminal");

    // The close is planned and its commit fails: the terminal stays open.
    mux.set_terminal_close_failure_for_test(true).unwrap();
    let refused = close_terminal(&mux, &terminal, "live-close-refused");
    mux.set_terminal_close_failure_for_test(false).unwrap();
    assert_eq!(refused["ok"], false, "the close did not fail: {refused}");
    assert!(mux.terminal_resource_surface(&terminal).is_some(), "the terminal is gone");

    assert!(
        has_live_mark(&mux, &terminal),
        "a close that failed dropped the pending live fact of a terminal that stays open"
    );
    mux.shutdown();
}

/// The control of the test above: a close that is applied drops the entry.
#[test]
fn a_terminal_close_that_is_applied_drops_the_live_entry_of_its_terminal() {
    let mux = test_mux();
    let (surface, terminal) = one_terminal(&mux);
    let at_ms = crate::workspace_registry::unix_epoch_ms().unwrap() + 60_000;
    live_fact(&surface, 10, at_ms);
    assert!(has_live_mark(&mux, &terminal), "a live fact did not mark its terminal");

    let closed = close_terminal(&mux, &terminal, "live-close-applied");
    assert_eq!(closed["ok"], true, "{closed}");
    assert!(mux.terminal_resource_surface(&terminal).is_none(), "the terminal stays open");
    assert!(!has_live_mark(&mux, &terminal), "a closed terminal kept its live entry");
    mux.shutdown();
}
