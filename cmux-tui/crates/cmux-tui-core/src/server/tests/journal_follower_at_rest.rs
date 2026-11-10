//! A live journal follower gets every `agent.state.changed` row.
//!
//! A hook report that changes no durable state writes no journal row
//! (`mux/agent_hooks_at_rest.rs`). A client that follows the journal for the
//! kind (chatmux-relay's forwarder subscribes to `agent.*` and posts each row
//! to its backend) reads the journal and nothing else, so while one follows,
//! each report is a row, as it is for an enabled journal hook. A bounded read
//! (`follow: false`, the app's history read) asks for what the journal holds
//! and keeps nothing.

use super::*;

const TERMINAL: &str = "00000000000040008000000000000b01";
const INCARNATION: &str = "10000000000040008000000000000b01";

fn hook(mux: &Arc<Mux>, terminal: &str, event: &str) {
    let ingress = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        event,
        Some(terminal),
        json!({
            "session_id":"follower-session",
            "cwd":"/work/project",
            "prompt":"go on",
            "tool_name":"Read",
        }),
    )
    .unwrap();
    let key = format!("follower-{}", crate::workspace_registry::new_uuid_v4());
    mux.append_journal_ingress(&ingress, "test", &key).unwrap();
}

/// `agent.state.changed` rows that three tool reports of the agent add.
fn rows_of_three_tool_reports(mux: &Arc<Mux>, terminal: &str) -> usize {
    let head = mux.session_journal_head().unwrap();
    for _ in 0..3 {
        hook(mux, terminal, "PreToolUse");
    }
    mux.session_journal_after(head, 1024)
        .unwrap()
        .records
        .iter()
        .filter(|record| record.kind == "agent.state.changed")
        .count()
}

/// The next outbound message `wanted` accepts; stream items are skipped.
fn pop_until(outbound: &BoundedOutbound, wanted: impl Fn(&Value) -> bool) -> Value {
    loop {
        let message = pop_json(outbound);
        if wanted(&message) {
            return message;
        }
    }
}

fn subscribe(stream: &str, follow: bool) -> String {
    resource_request(
        stream,
        "session.journal.subscribe",
        json!({
            "machine":"current",
            "session":"current",
            "stream_id":stream,
            "follow":follow,
            "filter":journal_subscription_filter(
                JournalSensitivity::Sensitive,
                json!({"kinds":["agent.*"]}),
            ),
        }),
        None,
    )
}

#[cfg(unix)]
#[test]
fn a_live_journal_follower_of_agent_rows_gets_a_row_for_each_report() {
    let mux = test_mux();
    let workspace = mux.create_empty_workspace(None, None, None).unwrap().key;
    mux.seed_running_terminal_for_test(TERMINAL, INCARNATION, &workspace).unwrap();
    let terminal =
        mux.workspace_registry.lock().unwrap().terminal_resource_id(TERMINAL).unwrap().unwrap();
    let terminal = terminal.as_str();
    hook(&mux, terminal, "SessionStart");
    hook(&mux, terminal, "UserPromptSubmit");
    assert_eq!(rows_of_three_tool_reports(&mux, terminal), 0, "setup: nobody follows, no row");

    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));

    // A bounded read ends at the head it found: it follows nothing.
    let bounded = "stream_00000000000000000000000000000b01";
    assert!(handle_connection_message(
        &mux,
        client,
        &subscribe(bounded, false),
        &writer,
        &scheduler
    ));
    assert_eq!(pop_until(&outbound, |message| message["id"] == bounded)["ok"], true);
    assert_eq!(rows_of_three_tool_reports(&mux, terminal), 0, "a bounded read keeps no row");

    let live = "stream_00000000000000000000000000000b02";
    assert!(handle_connection_message(&mux, client, &subscribe(live, true), &writer, &scheduler));
    assert_eq!(pop_until(&outbound, |message| message["id"] == live)["ok"], true);
    assert_eq!(
        rows_of_three_tool_reports(&mux, terminal),
        3,
        "a client follows the journal for agent.*: each report must be a row it can read"
    );
    let item = pop_until(&outbound, |message| message["type"] == "stream_item");
    assert_eq!(item["stream_id"], live);
    assert_eq!(item["item"]["kind"], "agent.state.changed");
    assert!(disconnect_client(&mux, client, false));
}
