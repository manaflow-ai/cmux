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

#[test]
fn screen_identity_replay_and_live_events_are_opt_in() {
    let mux = test_mux();
    let opted = connect(&mux);
    let reply = line(
        &mux,
        &opted,
        json!({"id": "info", "cmd": "set-client-info", "name": "cmux-next",
               "capabilities": [SCREEN_DEVICE_IDENTITY_CAPABILITY]}),
    );
    assert_eq!(reply["ok"], true, "{reply}");
    let legacy = connect(&mux);
    for conn in [&opted, &legacy] {
        assert!(handle_connection_message(
            &mux,
            conn.0,
            &json!({"id": "sub", "cmd": "subscribe"}).to_string(),
            &conn.1,
            &conn.3,
        ));
    }

    mux.emit(MuxEvent::ScreenDeviceChanged(Some("550e8400-e29b-41d4-a716-446655440000".into())));
    mux.emit(MuxEvent::Status("screen-identity-marker".into()));

    let opted_seen = until_marker(&opted, "screen-identity-marker");
    let opted_events: Vec<Value> = opted_seen
        .iter()
        .filter_map(|message| serde_json::from_str(message).ok())
        .filter(|message: &Value| message["event"] == "screen-device-changed")
        .collect();
    assert!(
        !opted_events.is_empty(),
        "an opted-in owner must receive the identity replay/live event: {opted_seen:?}"
    );
    assert!(
        opted_events.iter().all(|message| message["screen_device_id"].is_null()),
        "identity payloads must read the current cache, not a stale queued value: {opted_events:?}"
    );
    let legacy_seen = until_marker(&legacy, "screen-identity-marker");
    assert!(
        legacy_seen.iter().all(|message| !message.contains("screen-device-changed")),
        "a legacy owner must not receive the additive identity event: {legacy_seen:?}"
    );
}

#[test]
fn identify_lists_screen_identity_capability() {
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
        capabilities.iter().any(|c| c == SCREEN_DEVICE_IDENTITY_CAPABILITY),
        "identify does not list {SCREEN_DEVICE_IDENTITY_CAPABILITY}: {capabilities:?}"
    );
}
