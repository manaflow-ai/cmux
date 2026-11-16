use std::collections::HashSet;

use serde_json::{Value, json};

use super::super::super::OutputMode;
use super::super::super::command::{
    AgentRosterView, AgentSort, RequestPlan, ResponseView, WireOperation,
};
use super::*;

const NOW: u64 = 1_000_000;

fn agent(id: &str, state: &str, updated_at_ms: u64, terminal: &str) -> Value {
    json!({
        "id": id,
        "session_id": "session_1",
        "terminal_id": terminal,
        "state": state,
        "source": "hook",
        "updated_at_ms": updated_at_ms.to_string(),
        "source_session": null,
        "extra": {"agent": "claude"},
    })
}

fn ids(result: &Value) -> Vec<&str> {
    result["agents"].as_array().unwrap().iter().map(|row| row["id"].as_str().unwrap()).collect()
}

fn view(sort: AgentSort, limit: Option<usize>) -> AgentRosterView {
    AgentRosterView { sort, limit, counts: false, status: None }
}

fn mixed() -> Value {
    json!([
        agent("agent_idle_old", "idle", NOW - 50_000, "term_1"),
        agent("agent_working_old", "working", NOW - 40_000, "term_2"),
        agent("agent_blocked_old", "blocked", NOW - 30_000, "term_3"),
        agent("agent_done_new", "done", NOW - 1_000, "term_4"),
        agent("agent_unknown", "unknown", NOW - 500, "term_5"),
        agent("agent_working_new", "working", NOW - 2_000, "term_6"),
        agent("agent_blocked_new", "blocked", NOW - 3_000, "term_7"),
        agent("agent_idle_tie_b", "idle", NOW - 10_000, "term_8"),
        agent("agent_idle_tie_a", "idle", NOW - 10_000, "term_9"),
    ])
}

#[test]
fn needs_me_puts_blocked_then_working_then_idle_then_unknown_then_ended_newest_first() {
    let result = shape(mixed(), &[], &HashSet::new(), view(AgentSort::NeedsMe, None), NOW);
    assert_eq!(
        ids(&result),
        [
            "agent_blocked_new",
            "agent_blocked_old",
            "agent_working_new",
            "agent_working_old",
            // Newest first within a group, ties by id.
            "agent_idle_tie_a",
            "agent_idle_tie_b",
            "agent_idle_old",
            "agent_unknown",
            // The daemon's `done` is a session that ended.
            "agent_done_new",
        ]
    );
}

#[test]
fn needs_me_is_the_default_sort() {
    assert_eq!(AgentRosterView::default().sort, AgentSort::NeedsMe);
    assert_eq!(AgentRosterView::default().limit, None);
}

#[test]
fn recent_sort_ignores_state_and_breaks_ties_by_id() {
    let result = shape(mixed(), &[], &HashSet::new(), view(AgentSort::Recent, None), NOW);
    assert_eq!(
        ids(&result),
        [
            "agent_unknown",
            "agent_done_new",
            "agent_working_new",
            "agent_blocked_new",
            "agent_idle_tie_a",
            "agent_idle_tie_b",
            "agent_blocked_old",
            "agent_working_old",
            "agent_idle_old",
        ]
    );
}

#[test]
fn none_sort_keeps_the_daemon_order() {
    let rows = mixed();
    let expected: Vec<String> =
        rows.as_array().unwrap().iter().map(|row| row["id"].as_str().unwrap().to_owned()).collect();
    let result = shape(rows, &[], &HashSet::new(), view(AgentSort::None, None), NOW);
    assert_eq!(ids(&result), expected);
}

#[test]
fn limit_trims_rows_after_ranking_but_counts_every_agent() {
    let result = shape(mixed(), &[], &HashSet::new(), view(AgentSort::NeedsMe, Some(3)), NOW);
    assert_eq!(ids(&result), ["agent_blocked_new", "agent_blocked_old", "agent_working_new"]);
    assert_eq!(
        result["counts"],
        json!({"blocked": 2, "done": 0, "working": 2, "idle": 3, "unknown": 1, "ended": 1,
               "total": 9})
    );
}

#[test]
fn json_shape_has_agents_with_age_title_and_folder_and_counts() {
    let terminals = [
        json!({"id": "term_1", "title": "fix tests", "cwd": "/home/me/src/cmux"}),
        json!({"id": "term_2", "title": "no folder"}),
    ];
    let rows = json!([
        agent("agent_a", "blocked", NOW - 90_000, "term_1"),
        agent("agent_b", "working", NOW - 5_000, "term_2"),
        agent("agent_c", "idle", NOW + 5_000, "term_gone"),
    ]);
    let result = shape(rows, &terminals, &HashSet::new(), AgentRosterView::default(), NOW);
    let object = result.as_object().expect("the roster is an object");
    // `hidden_ended` (#39602): the ended agents of closed terminals the list leaves out.
    assert_eq!(object.keys().collect::<Vec<_>>(), ["agents", "counts", "hidden_ended"]);
    assert_eq!(result["hidden_ended"], 0);
    let agents = result["agents"].as_array().unwrap();
    // Every daemon field is kept as it was.
    assert_eq!(agents[0]["updated_at_ms"], (NOW - 90_000).to_string());
    assert_eq!(agents[0]["extra"]["agent"], "claude");
    assert_eq!(agents[0]["age_ms"], 90_000);
    assert_eq!(agents[0]["title"], "fix tests");
    assert_eq!(agents[0]["cwd"], "/home/me/src/cmux");
    assert_eq!(agents[1]["title"], "no folder");
    assert!(agents[1].get("cwd").is_none());
    // A terminal the list does not have adds nothing; a clock skewed
    // ahead of this one is age 0.
    assert!(agents[2].get("title").is_none());
    assert_eq!(agents[2]["age_ms"], 0);
    assert_eq!(
        result["counts"],
        json!({"blocked": 1, "done": 0, "working": 1, "idle": 1, "unknown": 0, "ended": 0,
               "total": 3})
    );
}

#[test]
fn bare_roster_joins_acpmux_sessions_with_message_addresses() {
    let terminal = agent("agent_terminal", "working", NOW - 1_000, "term_1");
    let sessions = [json!({
        "sessionId": "acp-1",
        "name": "review",
        "harness": "claude",
        "status": "waiting",
        "cwd": "/repo",
        "model": "sonnet",
        "agentSessionId": "native-1",
        "updatedAt": NOW - 2_000,
    })];
    let queued = [
        json!({"deliveries": [
            {"recipient": "term_1", "state": "queued"},
            {"recipient": "acp:acp-1", "state": "delivered"},
        ]}),
        json!({"deliveries": [{"recipient": "term_1", "state": "queued"}]}),
    ];
    let rows = merge_sources(json!([terminal]), &sessions, &queued, None, None);
    let result = shape(rows, &[], &HashSet::new(), AgentRosterView::default(), NOW);
    let agents = result["agents"].as_array().unwrap();
    assert_eq!(agents.len(), 2);
    let terminal = agents.iter().find(|row| row["address"] == "term_1").unwrap();
    assert_eq!(terminal["kind"], "terminal");
    assert_eq!(terminal["queued_messages"], 2);
    let acp = agents.iter().find(|row| row["address"] == "acp:acp-1").unwrap();
    assert_eq!(acp["kind"], "acp");
    assert_eq!(acp["agent"], "claude");
    assert_eq!(acp["state"], "blocked");
    assert_eq!(acp["status"], "blocked", "the shared word");
    assert_eq!(acp["acp_status"], "waiting", "acpmux's own word");
    assert_eq!(acp["queued_messages"], 0);
    assert_eq!(result["counts"]["total"], 2);
}

#[test]
fn acpmux_state_filter_applies_before_roster_sorting() {
    let sessions = [
        json!({"sessionId": "idle", "status": "ready", "updatedAt": NOW}),
        json!({"sessionId": "working", "status": "running", "updatedAt": NOW}),
    ];
    let rows = merge_sources(json!([]), &sessions, &[], Some("idle"), None);
    let agents = rows.as_array().unwrap();
    assert_eq!(agents.len(), 1);
    assert_eq!(agents[0]["address"], "acp:idle");
    assert_eq!(agents[0]["state"], "idle");
}

/// Inside one cmux session, `agent list` lists that session's agents: its
/// terminal agents and the chats created in its workspaces. A chat of
/// another session's workspace (the desktop app's), and a chat with no
/// workspace on record, stay out; `--all-sessions` lists every chat.
#[test]
fn a_bare_roster_lists_only_chats_of_this_sessions_workspaces() {
    let workspaces = [
        json!({"id": "ws_1", "extra": {"key": "0a1b2c3d-0000-4000-8000-000000000001"}}),
        json!({"id": "ws_2", "extra": {}}),
    ];
    let keys = workspace_keys(&workspaces);
    let chat = |id: &str, created_by: Value| json!({"sessionId": id, "status": "idle", "updatedAt": NOW, "createdBy": created_by});
    // The app hands workspaces their key's uppercase UUID form.
    let mine = json!({"kind": "person", "workspace": "0A1B2C3D-0000-4000-8000-000000000001"});
    let app = json!({"kind": "person", "workspace": "ffffffff-0000-4000-8000-000000000009"});
    let sessions = [
        chat("mine", mine),
        chat("app", app),
        chat("nowhere", json!({"kind": "script"})),
        chat("old", Value::Null),
    ];
    let terminal = agent("agent_terminal", "blocked", NOW, "term_1");
    let rows = merge_sources(json!([terminal]), &sessions, &[], None, Some(&keys));
    let addresses: Vec<&str> =
        rows.as_array().unwrap().iter().filter_map(|row| row["address"].as_str()).collect();
    assert_eq!(addresses, ["term_1", "acp:mine"]);

    let all = merge_sources(json!([]), &sessions, &[], None, None);
    assert_eq!(all.as_array().unwrap().len(), 4, "--all-sessions keeps every chat");
}

#[test]
fn a_session_without_readable_workspaces_lists_no_chat() {
    let sessions =
        [json!({"sessionId": "app", "status": "idle", "createdBy": {"workspace": "ws"}})];
    let rows = merge_sources(json!([]), &sessions, &[], None, Some(&workspace_keys(&[])));
    assert_eq!(rows, json!([]));
}

#[test]
fn an_empty_title_or_folder_is_left_out() {
    let terminals = [json!({"id": "term_1", "title": "", "cwd": ""})];
    let rows = json!([agent("agent_a", "idle", NOW, "term_1")]);
    let result = shape(rows, &terminals, &HashSet::new(), AgentRosterView::default(), NOW);
    assert!(result["agents"][0].get("title").is_none());
    assert!(result["agents"][0].get("cwd").is_none());
}

#[test]
fn a_state_the_cli_does_not_know_counts_and_ranks_as_unknown() {
    let rows = json!([
        agent("agent_new_state", "paused", NOW, "term_1"),
        {"session": "session_2", "result": {"error": "refused"}},
        agent("agent_idle", "idle", NOW - 1_000, "term_2"),
    ]);
    let result = shape(rows, &[], &HashSet::new(), AgentRosterView::default(), NOW);
    assert_eq!(
        result["counts"],
        json!({"blocked": 0, "done": 0, "working": 0, "idle": 1, "unknown": 2, "ended": 0,
               "total": 3})
    );
    assert_eq!(result["agents"][0]["id"], "agent_idle");
}

#[test]
fn empty_roster_has_zero_counts() {
    let result = shape(json!([]), &[], &HashSet::new(), AgentRosterView::default(), NOW);
    assert_eq!(
        result,
        json!({
            "agents": [],
            "counts": {"blocked": 0, "done": 0, "working": 0, "idle": 0, "unknown": 0, "ended": 0,
                       "total": 0},
            "hidden_ended": 0,
        })
    );
}

#[test]
fn human_output_leads_with_counts_then_ranked_rows() {
    let terminals = [json!({"id": "term_1", "title": "fix tests", "cwd": "/home/me/src/cmux"})];
    let rows = json!([
        agent("agent_w", "working", NOW - 5_000, "term_2"),
        agent("agent_b", "blocked", NOW - 120_000, "term_1"),
    ]);
    let result = shape(rows, &terminals, &HashSet::new(), AgentRosterView::default(), NOW);
    let text = human(&result, Some("/home/me"));
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines[0], "1 blocked · 0 done · 1 working · 0 idle");
    let header: Vec<&str> = lines[1].split_whitespace().collect();
    assert_eq!(header, ["STATE", "AGE", "AGENT", "TITLE", "FOLDER", "TERMINAL"]);
    let first: Vec<&str> = lines[2].split_whitespace().collect();
    assert_eq!(first, ["blocked", "2m", "claude", "fix", "tests", "~/src/cmux", "term_1"]);
    let second: Vec<&str> = lines[3].split_whitespace().collect();
    assert_eq!(second, ["working", "5s", "claude", "-", "-", "term_2"]);
    assert_eq!(lines.len(), 4);
}

#[test]
fn human_output_says_when_a_limit_hid_rows_and_names_unknown_agents() {
    let result = shape(mixed(), &[], &HashSet::new(), view(AgentSort::NeedsMe, Some(2)), NOW);
    let text = human(&result, None);
    assert_eq!(
        text.lines().next().unwrap(),
        "2 blocked · 0 done · 2 working · 3 idle · 1 unknown · 1 ended (showing 2 of 9)"
    );
    assert_eq!(text.lines().count(), 4);
}

#[test]
fn human_output_for_no_agents_is_one_line() {
    let result = shape(json!([]), &[], &HashSet::new(), AgentRosterView::default(), NOW);
    assert_eq!(human(&result, None), "No agents.\n");
}

#[test]
fn human_output_adds_a_session_column_across_sessions() {
    let mut row = agent("agent_a", "idle", NOW - 1_000, "term_1");
    row["session"] = json!("work");
    let result = shape(json!([row]), &[], &HashSet::new(), AgentRosterView::default(), NOW);
    let text = human(&result, None);
    let header: Vec<&str> = text.lines().nth(1).unwrap().split_whitespace().collect();
    assert_eq!(header[0], "SESSION");
    assert!(text.lines().nth(2).unwrap().starts_with("work "));
}

#[test]
fn ages_use_one_compact_unit() {
    assert_eq!(age_text(0), "0s");
    assert_eq!(age_text(59_999), "59s");
    assert_eq!(age_text(60_000), "1m");
    assert_eq!(age_text(3_599_999), "59m");
    assert_eq!(age_text(3_600_000), "1h");
    assert_eq!(age_text(86_399_999), "23h");
    assert_eq!(age_text(86_400_000 * 3), "3d");
}

fn list_plan(view: AgentRosterView) -> RequestPlan {
    RequestPlan {
        operation: WireOperation::Typed(ResourceOperation::AgentList),
        params: json!({}),
        idempotency_key: None,
        stream: false,
        resolve: Vec::new(),
        view: ResponseView::AgentRoster(view),
        filter: Default::default(),
    }
}

#[test]
fn json_stays_the_bare_ranked_array_unless_counts_is_asked_for() {
    let result = shape(mixed(), &[], &HashSet::new(), AgentRosterView::default(), NOW);
    let plain = list_plan(AgentRosterView::default());
    let shown = machine_view(&plain, &result, OutputMode::Json);
    assert!(shown.is_array(), "--json is the bare agent array scripts read");
    assert_eq!(shown[0]["id"], "agent_blocked_new");
    assert_eq!(shown.as_array().unwrap().len(), 9);
    assert!(machine_view(&plain, &result, OutputMode::JsonLines).is_array());

    let counted = list_plan(AgentRosterView { counts: true, ..AgentRosterView::default() });
    let shown = machine_view(&counted, &result, OutputMode::Json);
    assert_eq!(
        shown.as_object().unwrap().keys().collect::<Vec<_>>(),
        ["agents", "counts", "hidden_ended"]
    );
    assert_eq!(shown["counts"]["total"], 9);
    // --jsonl is one agent per line either way.
    assert!(machine_view(&counted, &result, OutputMode::JsonLines).is_array());
}

/// One vocabulary (bench round 3, T7): `agent list` rows carry the shared
/// `status` word that `terminal list --agents` shows, keep the daemon's
/// older `state`, and count by `status`. A daemon `done` is a session that
/// ended, not a finished turn, so it is no `done` agent.
#[test]
fn w4j_agent_list_rows_and_counts_use_the_shared_status_words() {
    let rows = json!([
        agent("agent_idle", "idle", NOW - 1_000, "term_1"),
        agent("agent_ended", "done", NOW - 2_000, "term_2"),
        agent("agent_blocked", "blocked", NOW - 3_000, "term_3"),
    ]);
    let result = shape(rows, &[], &HashSet::new(), AgentRosterView::default(), NOW);
    let row = |id: &str| {
        result["agents"].as_array().unwrap().iter().find(|row| row["id"] == id).unwrap().clone()
    };
    assert_eq!(row("agent_idle")["status"], "idle");
    assert_eq!(row("agent_blocked")["status"], "blocked");
    assert_eq!(row("agent_ended")["status"], "ended");
    assert_eq!(row("agent_ended")["state"], "ended", "state is an alias of status (W5-Q)");
    assert_eq!(
        result["counts"],
        json!({"blocked": 1, "done": 0, "working": 0, "idle": 1, "unknown": 0, "ended": 1,
               "total": 3})
    );
    let text = human(&result, None);
    assert_eq!(text.lines().next().unwrap(), "1 blocked · 0 done · 0 working · 1 idle · 1 ended");
    let states: Vec<&str> =
        text.lines().skip(2).filter_map(|line| line.split_whitespace().next()).collect();
    assert_eq!(states, ["blocked", "idle", "ended"]);
}

/// `done` is a finished turn nobody has viewed: an idle terminal agent whose
/// terminal has an unread notification, as in `terminal list --agents`. It
/// ranks right after blocked, and `--state done` keeps only those agents.
#[test]
fn w4j_an_unseen_idle_agent_is_done_and_ranks_after_blocked() {
    let rows = || {
        json!([
            agent("agent_working", "working", NOW - 1_000, "term_1"),
            agent("agent_finished", "idle", NOW - 9_000, "term_2"),
            agent("agent_seen", "idle", NOW - 2_000, "term_3"),
            agent("agent_blocked", "blocked", NOW - 5_000, "term_4"),
        ])
    };
    let notifications = [
        json!({"id": "notification_1", "terminal_id": "term_2", "unread": true}),
        json!({"id": "notification_2", "terminal_id": "term_3", "unread": false}),
        json!({"id": "notification_3", "unread": true}),
    ];
    let unseen = unseen_terminals(&notifications);
    assert_eq!(unseen, HashSet::from(["term_2"]));
    let result = shape(rows(), &[], &unseen, AgentRosterView::default(), NOW);
    assert_eq!(ids(&result), ["agent_blocked", "agent_finished", "agent_working", "agent_seen"]);
    assert_eq!(result["agents"][1]["status"], "done");
    assert_eq!(result["agents"][1]["state"], "done", "state is an alias of status (W5-Q)");
    assert_eq!(result["agents"][3]["status"], "idle");
    assert_eq!(result["counts"]["done"], 1);
    assert_eq!(result["counts"]["idle"], 1);

    let done = AgentRosterView { status: Some("done"), ..AgentRosterView::default() };
    let result = shape(rows(), &[], &unseen, done, NOW);
    assert_eq!(ids(&result), ["agent_finished"]);
    assert_eq!(result["counts"]["total"], 1);

    // `--state ended` asks the daemon for its `done` (a session that
    // ended) and keeps those rows: `status` ended.
    let ended_rows = json!([
        agent("agent_gone", "done", NOW - 3_000, "term_5"),
        agent("agent_seen", "idle", NOW - 2_000, "term_3"),
    ]);
    let ended = AgentRosterView { status: Some("ended"), ..AgentRosterView::default() };
    let result = shape(ended_rows, &[], &unseen, ended, NOW);
    assert_eq!(ids(&result), ["agent_gone"]);
    assert_eq!(result["agents"][0]["status"], "ended");
    assert_eq!(result["counts"]["ended"], 1);
}

/// W5-Q (bench r4 #7): `agent list` rows carry the agent's `name`, the name
/// `terminal list --agents` shows: the tab's name when it is an agent name.
#[test]
fn w5q_agent_list_rows_carry_the_agent_name() {
    let rows = json!([
        agent("agent_pong", "idle", NOW - 1_000, "term_1"),
        agent("agent_plain", "working", NOW - 2_000, "term_2"),
    ]);
    let terminals = [
        json!({"id": "term_1", "tab_id": "tab_1", "title": "claude"}),
        json!({"id": "term_2", "tab_id": "tab_2", "title": "codex"}),
    ];
    let tabs = [
        json!({"id": "tab_1", "name": "pong", "content_id": "term_1", "pane_id": "pane_1"}),
        json!({"id": "tab_2", "name": "My Tab", "content_id": "term_2", "pane_id": "pane_1"}),
    ];
    let mut result = shape(rows, &terminals, &HashSet::new(), AgentRosterView::default(), NOW);
    add_names(&mut result, &terminals, &tabs);
    let row = |id: &str| {
        result["agents"].as_array().unwrap().iter().find(|row| row["id"] == id).unwrap().clone()
    };
    assert_eq!(row("agent_pong")["name"], "pong");
    assert_eq!(row("agent_plain")["name"], Value::Null, "My Tab is no agent name");
    let text = human(&result, None);
    let header = text.lines().nth(1).unwrap_or_default();
    assert!(header.starts_with("NAME"), "{text}");
    assert!(text.lines().any(|line| line.starts_with("pong ")), "{text}");
}

/// W5-Q (bench round 4 orchestration #9): one state word. `state` is a
/// deprecated alias of `status` (`ended` for a session that ended), as in
/// `terminal list --agents`, so `state: idle` never sits beside
/// `status: done`.
#[test]
fn w5q_agent_list_state_is_the_one_status_word() {
    let rows = json!([
        agent("agent_finished", "idle", NOW - 1_000, "term_1"),
        agent("agent_seen", "idle", NOW - 2_000, "term_2"),
        agent("agent_ended", "done", NOW - 3_000, "term_3"),
        agent("agent_blocked", "blocked", NOW - 4_000, "term_4"),
    ]);
    let unseen = HashSet::from(["term_1"]);
    let result = shape(rows, &[], &unseen, AgentRosterView::default(), NOW);
    let row = |id: &str| {
        result["agents"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|row| row["id"] == id)
            .cloned()
            .unwrap_or_default()
    };
    for (id, word) in [
        ("agent_finished", "done"),
        ("agent_seen", "idle"),
        ("agent_ended", "ended"),
        ("agent_blocked", "blocked"),
    ] {
        assert_eq!(row(id)["state"], word, "{id}: {result}");
        assert_eq!(row(id)["status"], word, "{id}: {result}");
    }
}

/// W5-Q (bench round 4 orchestration #9): an ended agent whose terminal is
/// closed is not listed; `--state ended` still lists it. When the
/// terminals could not be read, nothing is left out.
#[test]
fn w5q_agent_list_leaves_out_ended_agents_of_closed_terminals() {
    let rows = || {
        json!([
            agent("agent_open_ended", "done", NOW - 1_000, "term_open"),
            agent("agent_closed_ended", "done", NOW - 2_000, "term_closed"),
            agent("agent_idle", "idle", NOW - 3_000, "term_idle"),
        ])
    };
    let terminals = [json!({"id": "term_open"}), json!({"id": "term_idle"})];
    let result = shape(rows(), &terminals, &HashSet::new(), AgentRosterView::default(), NOW);
    assert_eq!(ids(&result), ["agent_idle", "agent_open_ended"], "{result}");
    assert_eq!(result["counts"]["ended"], 1, "{result}");
    let ended = AgentRosterView { status: Some("ended"), ..AgentRosterView::default() };
    let result = shape(rows(), &terminals, &HashSet::new(), ended, NOW);
    assert_eq!(ids(&result), ["agent_open_ended", "agent_closed_ended"], "{result}");
    let unread = shape(rows(), &[], &HashSet::new(), AgentRosterView::default(), NOW);
    assert_eq!(unread["counts"]["total"], 3, "{unread}");
}

/// W5-Q follow-up (PR A review note 3): an ended session's row says
/// `status: "ended"`, the word `terminal list --agents` and the send
/// receipt say, not null.
#[test]
fn w5q_an_ended_row_of_agent_list_says_status_ended() {
    let rows = json!([
        agent("agent_ended", "done", NOW - 1_000, "term_1"),
        agent("agent_idle", "idle", NOW - 2_000, "term_2"),
    ]);
    let result = shape(rows, &[], &HashSet::new(), AgentRosterView::default(), NOW);
    let ended = result["agents"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|row| row["id"] == "agent_ended")
        .cloned()
        .unwrap_or_default();
    assert_eq!(ended["status"], "ended", "{result}");
    assert_eq!(ended["state"], "ended", "{result}");
    assert_eq!(result["counts"]["ended"], 1, "{result}");
}

/// W5-Q follow-up (PR A review note 8): the text output says how many
/// ended agents of closed terminals it left out, and `--json --counts`
/// has the number (`hidden_ended`). `--state ended` hides none.
#[test]
fn w5q_agent_list_says_how_many_ended_agents_it_left_out() {
    let rows = || {
        json!([
            agent("agent_closed_1", "done", NOW - 1_000, "term_closed_1"),
            agent("agent_closed_2", "done", NOW - 2_000, "term_closed_2"),
            agent("agent_idle", "idle", NOW - 3_000, "term_idle"),
        ])
    };
    let terminals = [json!({"id": "term_idle"})];
    let line = crate::localization::catalog().pane_cli.agent_list_hidden_ended;
    let result = shape(rows(), &terminals, &HashSet::new(), AgentRosterView::default(), NOW);
    assert_eq!(ids(&result), ["agent_idle"], "{result}");
    assert_eq!(result["hidden_ended"], 2, "{result}");
    let text = human(&result, None);
    assert!(text.contains(&line.replace("{count}", "2")), "{text}");

    let ended = AgentRosterView { status: Some("ended"), ..AgentRosterView::default() };
    let result = shape(rows(), &terminals, &HashSet::new(), ended, NOW);
    assert_eq!(result["hidden_ended"], 0, "{result}");
    assert!(!human(&result, None).contains(&line.replace("{count}", "0")), "{result}");

    // Only ended agents of closed terminals: no agent row, still the line.
    let closed = json!([agent("agent_closed_1", "done", NOW - 1_000, "term_closed_1")]);
    let result = shape(closed, &terminals, &HashSet::new(), AgentRosterView::default(), NOW);
    let text = human(&result, None);
    assert!(text.contains(&line.replace("{count}", "1")), "{text}");
}
