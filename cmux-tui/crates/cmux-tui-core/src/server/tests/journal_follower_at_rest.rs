//! A live journal follower gets every `agent.state.changed` row.
//!
//! A hook report that changes no durable state writes no journal row
//! (`mux/agent_hooks_at_rest.rs`). A client that follows the journal for the
//! kind (chatmux-relay's forwarder subscribes to `agent.*` and posts each row
//! to its backend) reads the journal and nothing else, so while one follows,
//! each report is a row, as it is for an enabled journal hook. A bounded read
//! (`follow: false`, the app's history read) asks for what the journal holds
//! and keeps nothing.

#![cfg(unix)]

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
    subscribe_with(
        stream,
        follow,
        journal_subscription_filter(JournalSensitivity::Sensitive, json!({"kinds":["agent.*"]})),
    )
}

fn subscribe_with(stream: &str, follow: bool, filter: Value) -> String {
    resource_request(
        stream,
        "session.journal.subscribe",
        json!({
            "machine":"current",
            "session":"current",
            "stream_id":stream,
            "follow":follow,
            "filter":filter,
        }),
        None,
    )
}

/// A session with one agent in a turn: its tool reports change no durable
/// state. Returns the agent's terminal.
fn session_with_an_agent_at_rest() -> (Arc<Mux>, String) {
    let mux = test_mux();
    let workspace = mux.create_empty_workspace(None, None, None).unwrap().key;
    mux.seed_running_terminal_for_test(TERMINAL, INCARNATION, &workspace).unwrap();
    let terminal =
        mux.workspace_registry.lock().unwrap().terminal_resource_id(TERMINAL).unwrap().unwrap();
    let terminal = terminal.as_str().to_string();
    hook(&mux, &terminal, "SessionStart");
    hook(&mux, &terminal, "UserPromptSubmit");
    assert_eq!(rows_of_three_tool_reports(&mux, &terminal), 0, "setup: nobody follows, no row");
    (mux, terminal)
}

/// The `journal_followers` section of `server-stats`.
fn follower_stats(mux: &Arc<Mux>) -> Value {
    let client = mux.control_clients.register(ClientTransport::Unix, test_writer());
    let include = Some(vec!["journal_followers".to_string()]);
    let stats =
        handle_command(mux, client, Command::ServerStats { include }, &test_writer()).unwrap();
    stats["journal_followers"].clone()
}

/// Opens a live journal stream with `filter` on a new local client.
fn follow_live(mux: &Arc<Mux>, stream: &str, filter: Value) {
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let request = subscribe_with(stream, true, filter);
    assert!(handle_connection_message(mux, client, &request, &writer, &scheduler));
    assert_eq!(pop_until(&outbound, |message| message["id"] == stream)["ok"], true);
}

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

    // The follower leaves. It can come back with its cursor, so the rows
    // stay for the grace; after it, a report writes nothing again.
    let cancel = resource_request(
        "follower-cancel",
        "stream.cancel",
        json!({"machine":"current","session":"current","stream":live}),
        None,
    );
    assert!(handle_connection_message(&mux, client, &cancel, &writer, &scheduler));
    assert_eq!(pop_until(&outbound, |message| message["id"] == "follower-cancel")["ok"], true);
    assert!(disconnect_client(&mux, client, false));
    let deadline = Instant::now() + Duration::from_secs(5);
    while mux.journal_row_followers_for_test() > 0 {
        assert!(Instant::now() < deadline, "the journal stream did not end with its client");
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(rows_of_three_tool_reports(&mux, terminal), 3, "inside the grace: still rows");
    mux.pass_journal_follower_grace_for_test();
    assert_eq!(rows_of_three_tool_reports(&mux, terminal), 0, "after the grace: no row");
}

/// The kind filter is asked: a follower of other kinds is never sent an
/// agent row, so it keeps none.
#[test]
fn a_live_journal_follower_of_other_kinds_keeps_no_agent_row() {
    let (mux, terminal) = session_with_an_agent_at_rest();
    follow_live(
        &mux,
        "stream_00000000000000000000000000000b11",
        journal_subscription_filter(JournalSensitivity::Sensitive, json!({"kinds":["terminal.*"]})),
    );
    assert_eq!(
        rows_of_three_tool_reports(&mux, &terminal),
        0,
        "a follower of terminal.* is never sent agent.state.changed"
    );
}

/// A hook row is `sensitive`. A stream is sent it only with
/// `max_sensitivity: sensitive`; the default limit is `metadata`. A follower
/// that can never be sent the rows must not turn the saving off.
#[test]
fn a_live_journal_follower_below_the_row_sensitivity_keeps_no_agent_row() {
    let (mux, terminal) = session_with_an_agent_at_rest();
    follow_live(&mux, "stream_00000000000000000000000000000b21", json!({"kinds":["agent.*"]}));
    assert_eq!(
        rows_of_three_tool_reports(&mux, &terminal),
        0,
        "agent.* at the default metadata limit is never sent a sensitive row"
    );
    follow_live(&mux, "stream_00000000000000000000000000000b22", json!({}));
    assert_eq!(
        rows_of_three_tool_reports(&mux, &terminal),
        0,
        "no kind filter at the default metadata limit is never sent a sensitive row"
    );
    follow_live(
        &mux,
        "stream_00000000000000000000000000000b23",
        journal_subscription_filter(JournalSensitivity::Sensitive, json!({})),
    );
    assert_eq!(
        rows_of_three_tool_reports(&mux, &terminal),
        3,
        "control: the sensitive limit is sent each row"
    );
}

/// A follower of the last daemon run (chatmux-relay's forwarder) comes back
/// with its saved cursor after a restart and must find the rows of the gap:
/// the grace runs from the moment the daemon serves, with no follower yet.
#[test]
fn the_follower_grace_runs_from_the_daemon_start() {
    let (mux, terminal) = session_with_an_agent_at_rest();
    mux.mark_server_lifecycle_ready();
    assert_eq!(
        rows_of_three_tool_reports(&mux, &terminal),
        3,
        "a daemon that just started keeps each report for a follower that comes back"
    );
    mux.pass_journal_follower_grace_for_test();
    assert_eq!(rows_of_three_tool_reports(&mux, &terminal), 0, "after the grace: no row");
}

/// `server-stats` with `include: ["journal_followers"]` names each live
/// follower, its filter and whether it keeps the rows; without the name the
/// section is absent.
#[test]
fn server_stats_lists_the_journal_followers_and_what_keeps_the_rows() {
    let (mux, _terminal) = session_with_an_agent_at_rest();
    let client = mux.control_clients.register(ClientTransport::Unix, test_writer());
    let plain =
        handle_command(&mux, client, Command::ServerStats { include: None }, &test_writer())
            .unwrap();
    assert!(plain.get("journal_followers").is_none(), "{plain}");

    let none = follower_stats(&mux);
    assert_eq!(none["followers"], json!([]), "{none}");
    assert_eq!(none["hook_rows_kept"], false, "{none}");
    assert_eq!(none["report_rows_kept"], false, "{none}");
    assert_eq!(none["keep_all_ms"], 0, "{none}");
    assert_eq!(none["grace_ms"], 120_000, "{none}");

    let quiet = "stream_00000000000000000000000000000b31";
    follow_live(&mux, quiet, json!({"kinds":["agent.*", "terminal.exited"]}));
    let keeper = "stream_00000000000000000000000000000b32";
    follow_live(
        &mux,
        keeper,
        journal_subscription_filter(JournalSensitivity::Sensitive, json!({"kinds":["agent.*"]})),
    );
    let stats = follower_stats(&mux);
    let followers = stats["followers"].as_array().unwrap();
    assert_eq!(followers.len(), 2, "{stats}");
    let of = |stream: &str| {
        followers
            .iter()
            .find(|follower| follower["stream_id"] == stream)
            .unwrap_or_else(|| panic!("{stream} is not listed: {stats}"))
    };
    assert_eq!(of(quiet)["kinds"], json!(["agent.*", "terminal.exited"]), "{stats}");
    assert_eq!(of(quiet)["max_sensitivity"], "metadata", "{stats}");
    assert_eq!(of(quiet)["keeps_hook_rows"], false, "{stats}");
    assert_eq!(of(quiet)["keeps_report_rows"], false, "{stats}");
    assert_eq!(of(quiet)["remote"], false, "{stats}");
    assert!(of(quiet)["left_ms"].is_null(), "{stats}");
    assert_eq!(of(keeper)["kinds"], json!(["agent.*"]), "{stats}");
    assert_eq!(of(keeper)["max_sensitivity"], "sensitive", "{stats}");
    assert_eq!(of(keeper)["keeps_hook_rows"], true, "{stats}");
    assert_eq!(of(keeper)["keeps_report_rows"], true, "{stats}");
    assert_eq!(stats["hook_rows_kept"], true, "{stats}");
    assert_eq!(stats["report_rows_kept"], true, "{stats}");
    assert_eq!(stats["journal_hook_keeps_rows"], false, "{stats}");

    mux.mark_server_lifecycle_ready();
    let started = follower_stats(&mux);
    let keep_all = started["keep_all_ms"].as_u64().unwrap_or(0);
    assert!(keep_all > 0 && keep_all <= 120_000, "{started}");
}
