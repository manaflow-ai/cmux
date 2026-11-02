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
    AgentRosterView { sort, limit, counts: false }
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
fn needs_me_puts_blocked_then_working_then_idle_and_done_newest_first() {
    let result = shape(mixed(), &[], view(AgentSort::NeedsMe, None), NOW);
    assert_eq!(
        ids(&result),
        [
            "agent_blocked_new",
            "agent_blocked_old",
            "agent_working_new",
            "agent_working_old",
            // idle and done share a group: newest first, ties by id.
            "agent_done_new",
            "agent_idle_tie_a",
            "agent_idle_tie_b",
            "agent_idle_old",
            "agent_unknown",
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
    let result = shape(mixed(), &[], view(AgentSort::Recent, None), NOW);
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
    let result = shape(rows, &[], view(AgentSort::None, None), NOW);
    assert_eq!(ids(&result), expected);
}

#[test]
fn limit_trims_rows_after_ranking_but_counts_every_agent() {
    let result = shape(mixed(), &[], view(AgentSort::NeedsMe, Some(3)), NOW);
    assert_eq!(ids(&result), ["agent_blocked_new", "agent_blocked_old", "agent_working_new"]);
    assert_eq!(
        result["counts"],
        json!({"blocked": 2, "working": 2, "idle": 3, "done": 1, "unknown": 1, "total": 9})
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
    let result = shape(rows, &terminals, AgentRosterView::default(), NOW);
    let object = result.as_object().expect("the roster is an object");
    assert_eq!(object.keys().collect::<Vec<_>>(), ["agents", "counts"]);
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
        json!({"blocked": 1, "working": 1, "idle": 1, "done": 0, "unknown": 0, "total": 3})
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
    let rows = merge_sources(json!([terminal]), &sessions, &queued, None);
    let result = shape(rows, &[], AgentRosterView::default(), NOW);
    let agents = result["agents"].as_array().unwrap();
    assert_eq!(agents.len(), 2);
    assert_eq!(agents[0]["address"], "term_1");
    assert_eq!(agents[0]["kind"], "terminal");
    assert_eq!(agents[0]["queued_messages"], 2);
    assert_eq!(agents[1]["address"], "acp:acp-1");
    assert_eq!(agents[1]["kind"], "acp");
    assert_eq!(agents[1]["agent"], "claude");
    assert_eq!(agents[1]["state"], "blocked");
    assert_eq!(agents[1]["queued_messages"], 0);
    assert_eq!(result["counts"]["total"], 2);
}

#[test]
fn acpmux_state_filter_applies_before_roster_sorting() {
    let sessions = [
        json!({"sessionId": "idle", "status": "ready", "updatedAt": NOW}),
        json!({"sessionId": "working", "status": "running", "updatedAt": NOW}),
    ];
    let rows = merge_sources(json!([]), &sessions, &[], Some("idle"));
    let agents = rows.as_array().unwrap();
    assert_eq!(agents.len(), 1);
    assert_eq!(agents[0]["address"], "acp:idle");
    assert_eq!(agents[0]["state"], "idle");
}

#[test]
fn an_empty_title_or_folder_is_left_out() {
    let terminals = [json!({"id": "term_1", "title": "", "cwd": ""})];
    let rows = json!([agent("agent_a", "idle", NOW, "term_1")]);
    let result = shape(rows, &terminals, AgentRosterView::default(), NOW);
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
    let result = shape(rows, &[], AgentRosterView::default(), NOW);
    assert_eq!(
        result["counts"],
        json!({"blocked": 0, "working": 0, "idle": 1, "done": 0, "unknown": 2, "total": 3})
    );
    assert_eq!(result["agents"][0]["id"], "agent_idle");
}

#[test]
fn empty_roster_has_zero_counts() {
    let result = shape(json!([]), &[], AgentRosterView::default(), NOW);
    assert_eq!(
        result,
        json!({
            "agents": [],
            "counts": {"blocked": 0, "working": 0, "idle": 0, "done": 0, "unknown": 0, "total": 0},
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
    let result = shape(rows, &terminals, AgentRosterView::default(), NOW);
    let text = human(&result, Some("/home/me"));
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines[0], "1 blocked · 1 working · 0 idle · 0 done");
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
    let result = shape(mixed(), &[], view(AgentSort::NeedsMe, Some(2)), NOW);
    let text = human(&result, None);
    assert_eq!(
        text.lines().next().unwrap(),
        "2 blocked · 2 working · 3 idle · 1 done · 1 unknown (showing 2 of 9)"
    );
    assert_eq!(text.lines().count(), 4);
}

#[test]
fn human_output_for_no_agents_is_one_line() {
    let result = shape(json!([]), &[], AgentRosterView::default(), NOW);
    assert_eq!(human(&result, None), "No agents.\n");
}

#[test]
fn human_output_adds_a_session_column_across_sessions() {
    let mut row = agent("agent_a", "idle", NOW - 1_000, "term_1");
    row["session"] = json!("work");
    let result = shape(json!([row]), &[], AgentRosterView::default(), NOW);
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
    }
}

#[test]
fn json_stays_the_bare_ranked_array_unless_counts_is_asked_for() {
    let result = shape(mixed(), &[], AgentRosterView::default(), NOW);
    let plain = list_plan(AgentRosterView::default());
    let shown = machine_view(&plain, &result, OutputMode::Json);
    assert!(shown.is_array(), "--json is the bare agent array scripts read");
    assert_eq!(shown[0]["id"], "agent_blocked_new");
    assert_eq!(shown.as_array().unwrap().len(), 9);
    assert!(machine_view(&plain, &result, OutputMode::JsonLines).is_array());

    let counted = list_plan(AgentRosterView { counts: true, ..AgentRosterView::default() });
    let shown = machine_view(&counted, &result, OutputMode::Json);
    assert_eq!(shown.as_object().unwrap().keys().collect::<Vec<_>>(), ["agents", "counts"]);
    assert_eq!(shown["counts"]["total"], 9);
    // --jsonl is one agent per line either way.
    assert!(machine_view(&counted, &result, OutputMode::JsonLines).is_array());
}
