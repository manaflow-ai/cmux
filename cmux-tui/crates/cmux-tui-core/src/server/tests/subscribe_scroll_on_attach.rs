//! SWITCH FRAMES SF-5 (busy gate on a 2x display, 2026-11-02): with 24 hidden terminals printing, the Mac app's
//! event subscription got 1910 `scroll-changed` events in 5 s. The app reads a terminal's scroll position on that
//! terminal's attach stream; its store applies nothing for these, yet each one woke its event pump and asked for a
//! main-thread frame. A connection that says `subscribe-scroll-on-attach-v1` in `set-client-info` gets no
//! `scroll-changed` on `subscribe`; any other connection still gets them.

use super::*;

type Conn = (u64, MessageWriter, Arc<BoundedOutbound>, Arc<ConnectionSurfaceScheduler>);

fn connect(mux: &Arc<Mux>) -> Conn {
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    (client, writer, outbound, scheduler)
}

fn line(mux: &Arc<Mux>, (client, writer, outbound, scheduler): &Conn, request: Value) -> Value {
    assert!(handle_connection_message(mux, *client, &request.to_string(), writer, scheduler));
    pop_json(outbound)
}

/// The messages `conn` gets until the `marker` status arrives.
fn until_marker(conn: &Conn, marker: &str) -> Vec<String> {
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut seen = Vec::new();
    while !seen.iter().any(|message: &String| message.contains(marker)) {
        assert!(Instant::now() < deadline, "the marker never arrived: {seen:?}");
        match conn.2.try_pop() {
            Some(message) => seen.push(message),
            None => std::thread::sleep(Duration::from_millis(2)),
        }
    }
    seen
}

#[test]
fn a_connection_that_reads_scroll_on_attach_gets_no_scroll_changed_on_subscribe() {
    let mux = test_mux();
    let app = connect(&mux);
    let reply = line(
        &mux,
        &app,
        json!({"id": "info", "cmd": "set-client-info", "name": "cmux-next",
               "capabilities": [SUBSCRIBE_SCROLL_ON_ATTACH_CAPABILITY]}),
    );
    assert_eq!(reply["ok"], true, "{reply}");
    let other = connect(&mux);
    for conn in [&app, &other] {
        let reply =
            line(&mux, conn, json!({"id": "sub", "cmd": "subscribe", "tree_events": "deltas"}));
        assert_eq!(reply["ok"], true, "{reply}");
        let _ = drain_json(&conn.2);
    }

    // A hidden terminal prints: its scroll position moves once per frame.
    for offset in 1..=20 {
        mux.emit(MuxEvent::ScrollChanged { surface: 7, offset, at_bottom: true });
    }
    mux.emit(MuxEvent::Status("scroll-marker".into()));

    let app_seen = until_marker(&app, "scroll-marker");
    let scrolls: Vec<&String> = app_seen.iter().filter(|m| m.contains("scroll-changed")).collect();
    assert!(
        scrolls.is_empty(),
        "{} scroll-changed events reached a connection that reads scroll on attach: each wakes its event pump",
        scrolls.len()
    );
    // The subscriber mailbox keeps only the newest scroll of a surface (event_bus coalescing): at least one arrives.
    let other_seen = until_marker(&other, "scroll-marker");
    assert!(
        other_seen.iter().any(|m| m.contains("scroll-changed")),
        "a connection that did not ask lost its scroll-changed events: {other_seen:?}"
    );
}

#[test]
fn identify_lists_subscribe_scroll_on_attach() {
    let mux = test_mux();
    let identity = handle_command(
        &mux,
        mux.local_test_client(0),
        Command::Identify { machine_metadata: false, revisions: false },
        &test_writer(),
    )
    .unwrap();
    let capabilities = identity["capabilities"].as_array().cloned().unwrap_or_default();
    assert!(
        capabilities.iter().any(|c| c == SUBSCRIBE_SCROLL_ON_ATTACH_CAPABILITY),
        "identify does not list {SUBSCRIBE_SCROLL_ON_ATTACH_CAPABILITY}: {capabilities:?}"
    );
}
