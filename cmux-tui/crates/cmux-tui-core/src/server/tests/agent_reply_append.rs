//! A hook's `live_reply` is a terminal's last reply only when its append is
//! new (W5-Q follow-up, PR C review: the reply was stamped before the append
//! knew its result).
//!
//! A detached hook retries its request with the same idempotency key, so the
//! daemon can read an older `Stop` after a newer one. That replay, or an
//! append that fails, must not put back an older reply or a new `at_ms`.

use super::*;

/// The `session.journal.append` request of a Claude `Stop` hook of harness
/// session `session` on `terminal`, with `live_reply: reply` beside the
/// event, as the hook sends it.
fn stop_hook_append(terminal: &TerminalPublicId, reply: &str, session: &str, key: &str) -> String {
    let event = crate::agent_hook_journal_ingress(
        "claude",
        "Stop",
        Some(terminal.as_str()),
        json!({"session_id":session}),
    )
    .expect("a Claude Stop hook is a journal event");
    resource_request(
        key,
        "session.journal.append",
        json!({
            "machine":"current",
            "session":"current",
            "event":event,
            "live_reply":reply,
        }),
        Some(key),
    )
}

#[test]
fn w5q_a_replayed_or_failed_hook_append_keeps_the_newer_reply() {
    let mux = test_mux();
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let create = resource_request(
        "w5q-reply-create",
        "workspace.create",
        json!({"machine":"current", "session":"current", "initial_content":"terminal"}),
        Some("w5q-reply-create"),
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

    let first = stop_hook_append(&terminal, "FIRST_REPLY", "w5q-reply-session", "w5q-reply-1");
    let appended = send(&first);
    assert_eq!(appended.pointer("/result/replayed"), Some(&json!(false)), "{appended}");
    let second = stop_hook_append(&terminal, "SECOND_REPLY", "w5q-reply-session", "w5q-reply-2");
    let appended = send(&second);
    assert_eq!(appended.pointer("/result/replayed"), Some(&json!(false)), "{appended}");
    let kept = mux.agent_last_reply_text(&terminal).expect("the second turn's reply is kept");
    assert_eq!(kept.text, "SECOND_REPLY");

    // The hook retried the first turn's request: the journal replays it.
    let replayed = send(&first);
    assert_eq!(replayed.pointer("/result/replayed"), Some(&json!(true)), "{replayed}");
    assert_eq!(
        mux.agent_last_reply_text(&terminal).as_ref(),
        Some(&kept),
        "a replayed append put back an older reply or a new time"
    );

    // The second turn's key with another event (another harness session):
    // the journal refuses it.
    let conflict = stop_hook_append(&terminal, "THIRD_REPLY", "w5q-other-session", "w5q-reply-2");
    let refused = send(&conflict);
    assert_ne!(refused.get("ok"), Some(&json!(true)), "{refused}");
    assert_eq!(
        mux.agent_last_reply_text(&terminal).as_ref(),
        Some(&kept),
        "a failed append kept its reply"
    );
    assert!(disconnect_client(&mux, client, false));
}
