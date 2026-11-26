//! hq#19373, ask c-ea62b204f6: on a reconnect to the same daemon the Mac app kept every sidebar row but
//! dropped every tab's agent presence until that agent's next hook event. A connection that says
//! `agent-presence-replay-v1` in `set-client-info` gets each terminal's presence first on `subscribe`
//! (a stopped agent's with nulls), so the app can keep what it shows; any other connection gets none.

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

fn until_marker(conn: &Conn, marker: &str) -> Vec<Value> {
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut seen: Vec<String> = Vec::new();
    while !seen.iter().any(|message| message.contains(marker)) {
        assert!(
            Instant::now() < deadline,
            "the marker never arrived t={} client={}: {seen:?}",
            crate::server::dbg2_ms(),
            conn.0
        );
        match conn.2.try_pop() {
            Some(message) => seen.push(message),
            None => std::thread::sleep(Duration::from_millis(2)),
        }
    }
    seen.iter().filter_map(|message| serde_json::from_str(message).ok()).collect()
}

fn hook(mux: &Arc<Mux>, terminal: &TerminalPublicId, event: &str, key: &str) {
    let ingress = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        event,
        Some(&terminal.to_string()),
        json!({"session_id": format!("session-{terminal}"), "prompt": "go"}),
    )
    .unwrap();
    mux.append_journal_ingress(&ingress, "test", key).unwrap();
}

#[test]
fn an_opted_in_subscriber_gets_every_terminals_presence_first() {
    let mux = test_mux();
    let acting = mux.new_workspace(None, None).unwrap();
    let stopped = mux.new_workspace(None, None).unwrap();
    hook(&mux, acting.terminal_public_id().unwrap(), "UserPromptSubmit", "a-1");
    hook(&mux, stopped.terminal_public_id().unwrap(), "UserPromptSubmit", "s-1");
    hook(&mux, stopped.terminal_public_id().unwrap(), "Stop", "s-2");

    let app = connect(&mux);
    let reply = line(
        &mux,
        &app,
        json!({"id": "info", "cmd": "set-client-info", "name": "cmux-next",
               "capabilities": [AGENT_PRESENCE_REPLAY_CAPABILITY]}),
    );
    assert_eq!(reply["ok"], true, "{reply}");
    let legacy = connect(&mux);
    for conn in [&app, &legacy] {
        assert!(handle_connection_message(
            &mux,
            conn.0,
            &json!({"id": "sub", "cmd": "subscribe"}).to_string(),
            &conn.1,
            &conn.3,
        ));
    }
    eprintln!("DBG2 t={} emit marker", crate::server::dbg2_ms());
    mux.emit(MuxEvent::Status("presence-marker".into()));

    let presence = |seen: &[Value], surface: SurfaceId| -> Vec<Value> {
        seen.iter()
            .filter(|m| m["event"] == "agent-presence-changed" && m["surface"] == surface)
            .cloned()
            .collect()
    };
    let app_seen = until_marker(&app, "presence-marker");
    let acting_seen = presence(&app_seen, acting.id);
    assert_eq!(acting_seen.len(), 1, "{app_seen:?}");
    assert_eq!(acting_seen[0]["activity"], "thinking", "{acting_seen:?}");
    assert_eq!(acting_seen[0]["agent"], "claude", "{acting_seen:?}");
    let stopped_seen = presence(&app_seen, stopped.id);
    assert_eq!(stopped_seen.len(), 1, "a stopped agent must be cleared on replay: {app_seen:?}");
    assert!(stopped_seen[0]["activity"].is_null(), "{stopped_seen:?}");

    let legacy_seen = until_marker(&legacy, "presence-marker");
    assert!(
        legacy_seen.iter().all(|m| m["event"] != "agent-presence-changed"),
        "a connection that did not ask got a presence replay: {legacy_seen:?}"
    );
}

#[test]
fn identify_lists_agent_presence_replay() {
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
        capabilities.iter().any(|c| c == AGENT_PRESENCE_REPLAY_CAPABILITY),
        "identify does not list {AGENT_PRESENCE_REPLAY_CAPABILITY}: {capabilities:?}"
    );
}
