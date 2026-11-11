//! The answer the hook helper gets for a hook that changes no durable state
//! (`mux/agent_hooks_at_rest.rs`), through the real `session.journal.append`
//! handler: a receipt marked `replayed`, with the sequence and event id of the
//! journal row that holds the session's durable facts, and no new journal row.

use super::*;

/// The `session.journal.append` request of a Claude hook `event` of harness
/// session `w-receipt-session` on `terminal`, as the hook helper sends it.
fn hook_append(terminal: &TerminalPublicId, event: &str, key: &str) -> String {
    let event = crate::agent_hook_journal_ingress(
        "claude",
        event,
        Some(terminal.as_str()),
        json!({"session_id":"w-receipt-session", "cwd":"/work/project", "tool_name":"Read"}),
    )
    .expect("a Claude hook is a journal event");
    resource_request(
        key,
        "session.journal.append",
        json!({"machine":"current", "session":"current", "event":event}),
        Some(key),
    )
}

#[test]
fn a_hook_at_rest_gets_a_replayed_receipt_from_the_server_handler() {
    let mux = test_mux();
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let create = resource_request(
        "at-rest-receipt-create",
        "workspace.create",
        json!({"machine":"current", "session":"current", "initial_content":"terminal"}),
        Some("at-rest-receipt-create"),
    );
    assert!(handle_connection_message(&mux, client, &create, &writer, &scheduler));
    let created = pop_json(&outbound);
    let terminal = TerminalPublicId::parse(
        created.pointer("/result/value/terminal_id").and_then(Value::as_str).unwrap_or_default(),
    )
    .expect("workspace.create made a terminal");
    let send = |request: &str| {
        assert!(handle_connection_message(&mux, client, request, &writer, &scheduler));
        pop_json(&outbound)
    };

    let started = send(&hook_append(&terminal, "SessionStart", "at-rest-receipt-1"));
    assert_eq!(started.pointer("/result/replayed"), Some(&json!(false)), "{started}");
    let turn = send(&hook_append(&terminal, "UserPromptSubmit", "at-rest-receipt-2"));
    assert_eq!(turn.pointer("/result/replayed"), Some(&json!(false)), "{turn}");
    let head = mux.session_journal_head().unwrap();

    // A tool call in the turn changes no durable state.
    let at_rest = send(&hook_append(&terminal, "PreToolUse", "at-rest-receipt-3"));
    assert_eq!(at_rest.get("ok"), Some(&json!(true)), "{at_rest}");
    assert_eq!(at_rest.pointer("/result/replayed"), Some(&json!(true)), "{at_rest}");
    assert_eq!(
        at_rest.pointer("/result/value/sequence"),
        turn.pointer("/result/value/sequence"),
        "the receipt names the row that holds the session's facts: {at_rest}"
    );
    assert_eq!(
        at_rest.pointer("/result/value/event_id"),
        turn.pointer("/result/value/event_id"),
        "{at_rest}"
    );
    assert_eq!(at_rest.pointer("/result/revision"), turn.pointer("/result/revision"), "{at_rest}");
    assert_eq!(mux.session_journal_head().unwrap(), head, "no journal row for the tool call");

    // The helper's retry (the same key) gets the same answer.
    let retried = send(&hook_append(&terminal, "PreToolUse", "at-rest-receipt-3"));
    assert_eq!(retried.get("result"), at_rest.get("result"), "{retried}");
    assert_eq!(mux.session_journal_head().unwrap(), head);

    // The turn's end is a durable change: a new row, not a replay.
    let stopped = send(&hook_append(&terminal, "Stop", "at-rest-receipt-4"));
    assert_eq!(stopped.pointer("/result/replayed"), Some(&json!(false)), "{stopped}");
    assert!(mux.session_journal_head().unwrap() > head);
    assert!(disconnect_client(&mux, client, false));
}
