//! Live terminal facts on `session.events` (`mux/terminal_live.rs`): a
//! subscriber gets a terminal's new OSC 9;4 progress and its new "last
//! output" time as a `delta` item, and the registry commits nothing for it.

use super::*;
use crate::server::ClientTransport;
use crate::server::tests::captured_writer;
use std::time::{Duration, Instant};

/// What the registry committed so far: the resource revision, the journal
/// head and the WAL commit count.
fn committed(mux: &Mux) -> (u64, u64, u64) {
    (
        mux.with_state(|state| state.resource_revision),
        mux.session_journal_head().unwrap(),
        mux.write_path_stats().wal_commits,
    )
}

fn next_item(outbound: &crate::server::BoundedOutbound, what: &str) -> Value {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Some(message) = outbound.try_pop() {
            let message: Value = serde_json::from_str(&message).expect("outbound JSON");
            assert_eq!(message["type"], "stream_item", "{what}: {message}");
            return message["item"].clone();
        }
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(2));
    }
}

/// Test-only settle: the stream worker handles what woke it and waits
/// again. Then the stream must have sent nothing.
fn settles_with_no_item(outbound: &crate::server::BoundedOutbound, what: &str) {
    std::thread::sleep(Duration::from_millis(300));
    let item = outbound.try_pop();
    assert!(item.is_none(), "{what}: the stream sent {item:?}");
}

fn events_request(stream: &str) -> crate::resource_router::ParsedResourceRequest {
    let message = json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":"live-terminal",
        "operation":"session.events",
        "params":{"machine":"current","session":"current","stream_id":stream},
    });
    crate::resource_router::parse_resource_request(&message.to_string()).unwrap()
}

/// The one terminal upsert of a delta item, after the checks every delta
/// item of this test meets.
fn terminal_upsert<'a>(item: &'a Value, terminal: &str, what: &str) -> &'a Value {
    assert_eq!(item["kind"], "delta", "{what}: {item}");
    let changes = item["changes"].as_array().unwrap_or_else(|| panic!("{what}: {item}"));
    assert_eq!(changes.len(), 1, "{what}: {item}");
    assert_eq!(changes[0]["kind"], "upsert", "{what}: {item}");
    assert_eq!(changes[0]["resource"], "terminal", "{what}: {item}");
    assert_eq!(changes[0]["id"], terminal, "{what}: {item}");
    &changes[0]["value"]
}

fn live_facts_reach_a_subscriber(mux: Arc<Mux>) {
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    surface.publish_pending_directory();
    surface.publish_pending_progress();
    let terminal = surface.terminal_public_id().expect("a public terminal").as_str().to_owned();
    assert!(
        mux.wait_for_terminal_publisher_for_test(Duration::from_secs(30)),
        "the terminal publisher did not drain"
    );

    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let request = events_request("stream_33333333333343338333333333333333");
    let (_, start) = prepare_session_event_stream(&mux, client, &writer, &request).unwrap();
    let stream_outbound = start.outbound.clone();
    let worker = {
        let mux = mux.clone();
        std::thread::spawn(move || run_session_event_stream(&mux, client, &writer, start))
    };
    let snapshot = next_item(&outbound, "the initial snapshot");
    assert_eq!(snapshot["kind"], "snapshot");

    // The terminal prints and reports a progress value: live facts.
    let before = committed(&mux);
    let first_ms = crate::workspace_registry::unix_epoch_ms().unwrap() + 60_000;
    surface.apply_stream_output_for_test(b"\x1b]9;4;1;42\x07line\r\n").unwrap();
    surface.note_output_at_for_test(first_ms);
    surface.publish_pending_state();
    let item = next_item(&outbound, "the live progress and last output");
    let value = terminal_upsert(&item, &terminal, "the live item");
    assert_eq!(value["extra"]["progress"]["value"], 42, "{item}");
    assert_eq!(value["extra"]["last_output"]["at_ms"], first_ms.to_string(), "{item}");
    let revision = before.0.to_string();
    assert_eq!(item["previous_revision"], revision, "a live item moves no revision: {item}");
    assert_eq!(item["revision"], revision, "a live item moves no revision: {item}");
    assert_eq!(item["cursor"]["revision"], revision, "{item}");
    assert_eq!(committed(&mux), before, "live facts committed to the registry");

    // An equal value sends no item.
    mux.publish_terminal_live(&surface);
    settles_with_no_item(&outbound, "a live change equal to the value last sent");
    assert_eq!(committed(&mux), before, "an equal live change committed to the registry");

    // A durable edge (the program starts to work) is one commit, and its
    // upsert carries the newest live facts.
    surface.report_program_status_for_test(ghostty_vt::ProgramStatusState::Working, first_ms);
    surface.publish_pending_state();
    let item = next_item(&outbound, "the committed program status edge");
    let value = terminal_upsert(&item, &terminal, "the committed item");
    let after_edge = committed(&mux);
    assert_eq!(after_edge.0, before.0 + 1, "a status edge is one revision");
    assert_eq!(after_edge.1, before.1 + 1, "a status edge is one journal row");
    assert_eq!(item["previous_revision"], revision, "{item}");
    assert_eq!(item["revision"], after_edge.0.to_string(), "{item}");
    assert_eq!(value["extra"]["progress"]["value"], 42, "{item}");
    assert_eq!(value["extra"]["last_output"]["at_ms"], first_ms.to_string(), "{item}");
    assert_eq!(value["extra"]["program_status"][0]["state"], "working", "{item}");
    // The stream checks the terminal again after its commit: the value is
    // the committed one, so it sends nothing.
    settles_with_no_item(&outbound, "after the committed upsert");

    // The same state again, a new progress and a later output: live, at the
    // committed revision, never older than the commit the client has.
    let second_ms = first_ms + 5_000;
    surface.apply_stream_output_for_test(b"\x1b]9;4;1;43\x07line\r\n").unwrap();
    surface.report_program_status_for_test(ghostty_vt::ProgramStatusState::Working, second_ms);
    surface.note_output_at_for_test(second_ms);
    surface.publish_pending_state();
    let item = next_item(&outbound, "the live item after the commit");
    let value = terminal_upsert(&item, &terminal, "the second live item");
    let revision = after_edge.0.to_string();
    assert_eq!(item["previous_revision"], revision, "{item}");
    assert_eq!(item["revision"], revision, "{item}");
    assert_eq!(value["extra"]["progress"]["value"], 43, "{item}");
    assert_eq!(value["extra"]["last_output"]["at_ms"], second_ms.to_string(), "{item}");
    assert_eq!(value["extra"]["program_status"][0]["state"], "working", "{item}");
    assert_eq!(
        value["extra"]["program_status"][0]["updated_at_ms"],
        second_ms.to_string(),
        "the repeated report is live too: {item}"
    );
    assert_eq!(committed(&mux), after_edge, "live facts committed to the registry");

    // The shown record reports a new progress number and keeps its state:
    // the tab shows the same state, so this is live too.
    let third_ms = second_ms + 1_000;
    surface.report_program_status_progress_for_test(
        ghostty_vt::ProgramStatusState::Working,
        Some(64),
        third_ms,
    );
    surface.publish_pending_state();
    let item = next_item(&outbound, "the live item of the shown record's progress");
    let value = terminal_upsert(&item, &terminal, "the shown progress item");
    assert_eq!(item["previous_revision"], revision, "{item}");
    assert_eq!(item["revision"], revision, "{item}");
    assert_eq!(value["extra"]["program_status"][0]["state"], "working", "{item}");
    assert_eq!(value["extra"]["program_status"][0]["progress"], 64, "{item}");
    assert_eq!(
        committed(&mux),
        after_edge,
        "the shown record's new progress number committed to the registry"
    );

    // A client that connects now reads the newest live facts in its snapshot.
    let (second_writer, second_outbound) = captured_writer();
    let second_client = mux.control_clients.register(ClientTransport::Unix, second_writer.clone());
    let request = events_request("stream_44444444444444448444444444444444");
    let (_, second) =
        prepare_session_event_stream(&mux, second_client, &second_writer, &request).unwrap();
    let second_stream_outbound = second.outbound.clone();
    let second_worker = {
        let (mux, writer) = (mux.clone(), second_writer);
        std::thread::spawn(move || run_session_event_stream(&mux, second_client, &writer, second))
    };
    let snapshot = next_item(&second_outbound, "the second client's snapshot");
    let read = snapshot["snapshot"]["terminals"]
        .as_array()
        .and_then(|terminals| terminals.iter().find(|value| value["id"] == terminal.as_str()))
        .unwrap_or_else(|| panic!("the snapshot has no terminal {terminal}: {snapshot}"));
    assert_eq!(read["extra"]["progress"]["value"], 43, "{read}");
    assert_eq!(read["extra"]["last_output"]["at_ms"], second_ms.to_string(), "{read}");
    assert_eq!(committed(&mux), after_edge, "a client read committed to the registry");

    settles_with_no_item(&outbound, "the first stream at the end");
    settles_with_no_item(&second_outbound, "the second stream after its snapshot");
    stream_outbound.close();
    second_stream_outbound.close();
    worker.join().unwrap();
    second_worker.join().unwrap();
    mux.shutdown();
}

/// An in-memory registry: the stream reads the terminal's durable rows
/// under the registry lock.
#[test]
fn a_subscriber_gets_live_terminal_facts_with_no_commit() {
    live_facts_reach_a_subscriber(Mux::new_for_test(
        "live-events",
        crate::SurfaceOptions::default(),
    ));
}

/// An on-disk registry: the stream reads the terminal's durable rows on its
/// own read-only connection.
#[cfg(unix)]
#[test]
fn a_subscriber_gets_live_terminal_facts_with_no_commit_on_disk() {
    let root = std::env::temp_dir()
        .join(format!("cmux-live-events-{}", crate::workspace_registry::new_uuid_v4()));
    let registry =
        crate::workspace_registry::WorkspaceRegistry::open(&root, "live-events").unwrap();
    // Test terminals (no child process), as `Mux::new_for_test` has.
    let mux = Mux::from_workspace_registry(
        "live-events".to_owned(),
        crate::SurfaceOptions::default(),
        registry,
        crate::mux::ProviderWorkspaceState::default(),
        true,
    )
    .unwrap();
    mux.stop_journal_maintenance();
    live_facts_reach_a_subscriber(mux);
    let _ = std::fs::remove_dir_all(&root);
}
