//! A live journal follower keeps a terminal's live facts as journal rows.
//!
//! An agent plugin follows the journal with `terminal.*` and scans a terminal
//! when a row names it (spec/plugins.md, "Event-driven journal delivery").
//! Terminal output is no journal row, so for a terminal that prints the
//! `terminal.progress` row of a live fact (an OSC 9;4 report, a moved last
//! output time) is the plugin's only wake. With no such follower a live fact
//! is no row (`mux/terminal_live.rs`).

use super::*;

fn journal_head(mux: &Mux) -> u64 {
    mux.session_journal_head().unwrap()
}

/// The terminal prints and reports a progress value: live facts only.
fn live_fact(surface: &crate::Surface, progress: u8, at_ms: u64) {
    surface
        .apply_stream_output_for_test(format!("\x1b]9;4;1;{progress}\x07line\r\n").as_bytes())
        .unwrap();
    surface.note_output_at_for_test(at_ms);
    surface.publish_pending_state();
}

/// The next `terminal.progress` record the journal stream sent.
fn next_progress_row(outbound: &BoundedOutbound, timeout: Duration) -> Option<Value> {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        let Some(message) = outbound.try_pop() else {
            std::thread::sleep(Duration::from_millis(2));
            continue;
        };
        let message: Value = serde_json::from_str(&message).expect("outbound JSON");
        if message["type"] == "stream_item" && message["item"]["kind"] == "terminal.progress" {
            return Some(message["item"].clone());
        }
    }
    None
}

#[test]
fn a_terminal_journal_follower_gets_a_row_for_a_live_fact() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    surface.publish_pending_directory();
    surface.publish_pending_progress();
    let terminal = surface.terminal_public_id().expect("a public terminal").as_str().to_owned();
    assert!(
        mux.wait_for_terminal_publisher_for_test(Duration::from_secs(30)),
        "the terminal publisher did not drain"
    );

    // No follower: a live fact is no row.
    let at_ms = crate::workspace_registry::unix_epoch_ms().unwrap() + 60_000;
    let head = journal_head(&mux);
    live_fact(&surface, 10, at_ms);
    assert_eq!(journal_head(&mux), head, "a live fact was a journal row with no follower");

    // A plugin follows the journal from its tail, as the screen detection
    // plugin does.
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let open = resource_request(
        "progress-follower-open",
        "session.journal.subscribe",
        json!({
            "machine":"current",
            "session":"current",
            "stream_id":"stream_00000000000000000000000000000071",
            "filter":journal_subscription_filter(JournalSensitivity::Sensitive, json!({
                "kinds":["terminal.*"],
            })),
        }),
        None,
    );
    assert!(handle_connection_message(&mux, client, &open, &writer, &scheduler));
    assert_eq!(pop_json(&outbound)["ok"], true);

    live_fact(&surface, 11, at_ms + 5_000);
    let row = next_progress_row(&outbound, Duration::from_secs(5))
        .expect("a `terminal.*` journal follower got no row for a terminal's live fact");
    let names_the_terminal = row["subjects"].as_array().is_some_and(|subjects| {
        subjects
            .iter()
            .any(|subject| subject["kind"] == "terminal" && subject["id"] == terminal.as_str())
    });
    assert!(names_the_terminal, "the row does not name the terminal: {row}");
    assert_eq!(journal_head(&mux), head + 1, "one live fact is one row for the follower");

    // The follower leaves: a live fact is no row again. Its stream worker
    // ends on its own thread, so the facts repeat until one writes no row.
    assert!(disconnect_client(&mux, client, false));
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut step = 2_u64;
    loop {
        let head = journal_head(&mux);
        let progress = if step.is_multiple_of(2) { 20 } else { 21 };
        live_fact(&surface, progress, at_ms + 5_000 * step);
        if journal_head(&mux) == head {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "live facts are still journal rows after the last follower left"
        );
        step += 1;
        std::thread::sleep(Duration::from_millis(10));
    }
    mux.shutdown();
}
