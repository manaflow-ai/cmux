use super::*;

/// Three workspaces' worth of tabs: `tab_a` has an unread info
/// notification, `tab_b` an agent's request, `tab_c` a blocked agent,
/// `tab_d` an unread error, `tab_e` nothing. `tab_e` is focused.
fn snapshot() -> Value {
    json!({
        "workspaces": [
            {"id": "ws_1", "name": "work", "focused": true},
            {"id": "ws_2", "name": "deploy", "focused": false},
        ],
        "screens": [
            {"id": "screen_1", "workspace_id": "ws_1", "focused": true},
            {"id": "screen_2", "workspace_id": "ws_2", "focused": false},
        ],
        "panes": [
            {"id": "pane_1", "screen_id": "screen_1", "focused": true},
            {"id": "pane_2", "screen_id": "screen_2", "focused": false},
        ],
        "tabs": [
            {"id": "tab_a", "pane_id": "pane_1", "content_id": "term_a", "focused": false, "name": null, "extra": {}},
            {"id": "tab_b", "pane_id": "pane_2", "content_id": "term_b", "focused": false, "name": "release",
             "extra": {"attention": {"reason": "approve deploy", "at_ms": 300, "request_id": "r"}}},
            {"id": "tab_c", "pane_id": "pane_2", "content_id": "term_c", "focused": true, "name": null, "extra": {}},
            {"id": "tab_d", "pane_id": "pane_1", "content_id": "term_d", "focused": false, "name": null, "extra": {}},
            {"id": "tab_e", "pane_id": "pane_1", "content_id": "term_e", "focused": true, "name": null, "extra": {}},
        ],
        "terminals": [
            {"id": "term_a", "tab_id": "tab_a", "title": "build", "lifecycle": "running"},
            {"id": "term_b", "tab_id": "tab_b", "title": "claude", "lifecycle": "running"},
            {"id": "term_c", "tab_id": "tab_c", "title": "codex", "lifecycle": "running"},
            {"id": "term_d", "tab_id": "tab_d", "title": "tests", "lifecycle": "running"},
            {"id": "term_e", "tab_id": "tab_e", "title": "zsh", "lifecycle": "running"},
        ],
        "agents": [
            {"id": "agent_c", "terminal_id": "term_c", "state": "blocked", "updated_at_ms": "200"},
            {"id": "agent_e", "terminal_id": "term_e", "state": "working", "updated_at_ms": "1"},
        ],
        "notifications": [
            {"id": "n1", "terminal_id": "term_a", "unread": true, "level": "info", "created_at_ms": "100", "title": "bench done"},
            {"id": "n2", "terminal_id": "term_d", "unread": true, "level": "error", "created_at_ms": "400", "title": "tests failed"},
            {"id": "n3", "terminal_id": "term_e", "unread": false, "level": "error", "created_at_ms": "50", "title": "old"},
        ],
    })
}

fn tabs(queue: &[Value]) -> Vec<&str> {
    queue.iter().map(|entry| entry["tab"].as_str().unwrap()).collect()
}

#[test]
fn attention_cli_queue_orders_snapshot_tabs_like_the_tui() {
    let queue = snapshot_queue(&snapshot());
    assert_eq!(tabs(&queue), vec!["tab_c", "tab_b", "tab_d", "tab_a"]);
    assert_eq!(
        queue[1],
        json!({
            "tab": "tab_b",
            "terminal": "term_b",
            "workspace_id": "ws_2",
            "workspace": "deploy",
            "title": "release",
            "kind": "requested",
            "reason": "approve deploy",
            "level": "warning",
            "since_ms": 300,
        })
    );
    assert_eq!(queue[0]["kind"], "blocked");
    assert_eq!(queue[0]["since_ms"], 200);
    assert_eq!(queue[2]["level"], "error");
    assert_eq!(queue[3]["reason"], "bench done");
    assert_eq!(queue[3]["workspace"], "work");
}

/// `term_d` had an error that was read, then an info notification: every
/// row shows the terminal's unread marker, and the newest row decides.
#[test]
fn attention_cli_uses_the_newest_notification_of_a_terminal() {
    let mut snapshot = snapshot();
    snapshot["notifications"] = json!([
        {"id": "n4", "terminal_id": "term_d", "unread": true, "level": "info", "created_at_ms": "900", "title": "today"},
        {"id": "n2", "terminal_id": "term_d", "unread": true, "level": "error", "created_at_ms": "10", "title": "yesterday"},
        {"id": "n1", "terminal_id": "term_a", "unread": true, "level": "info", "created_at_ms": "100", "title": "bench done"},
    ]);
    let queue = snapshot_queue(&snapshot);
    assert_eq!(
        tabs(&queue),
        vec!["tab_c", "tab_b", "tab_a", "tab_d"],
        "tab_d is info, newest last"
    );
    assert_eq!(queue[3]["level"], "info");
    assert_eq!(queue[3]["reason"], "today");
    assert_eq!(queue[3]["since_ms"], 900);
}

#[test]
fn attention_cli_next_starts_at_the_top_from_a_tab_outside_the_queue_and_cycles() {
    let snapshot = snapshot();
    let queue = snapshot_queue(&snapshot);
    let current = focused_tab(&snapshot);
    assert_eq!(current.as_deref(), Some("tab_e"));
    assert_eq!(next_entry(&queue, current.as_deref()).unwrap()["tab"], "tab_c");
    assert_eq!(next_entry(&queue, Some("tab_c")).unwrap()["tab"], "tab_b");
    assert_eq!(next_entry(&queue, Some("tab_a")).unwrap()["tab"], "tab_c");
    assert!(next_entry(&[], Some("tab_a")).is_none());
}

#[test]
fn attention_cli_program_status_blocked_counts_and_read_notifications_do_not() {
    let mut snapshot = snapshot();
    snapshot["agents"] = json!([]);
    snapshot["tabs"][1]["extra"] = json!({});
    snapshot["notifications"] = json!([
        {"id": "n3", "terminal_id": "term_e", "unread": false, "level": "error", "created_at_ms": "50"},
    ]);
    snapshot["terminals"][3]["extra"] = json!({"program_status": [
        {"state": "working", "since_ms": "5"},
        {"state": "blocked", "since_ms": "70"},
    ]});
    let queue = snapshot_queue(&snapshot);
    assert_eq!(tabs(&queue), vec!["tab_d"]);
    assert_eq!(queue[0]["kind"], "blocked");
    assert_eq!(queue[0]["since_ms"], 70);
}

/// W5-Q (bench r4 #5): a blocked row says why: the program status
/// message (`approve Bash: ...`), for a block a program reported and for
/// one the agent roster shows.
#[test]
fn w5q_attention_blocked_rows_carry_the_status_message() {
    let mut program = snapshot();
    program["terminals"][2]["extra"] = json!({"program_status": [
        {"app": "claude-code", "state": "blocked", "kind": "permission",
         "title": "Claude Code", "msg": "approve Bash: touch /tmp/x", "since_ms": "150"},
    ]});
    let queue = snapshot_queue(&program);
    assert_eq!(queue[0]["tab"], "tab_c");
    assert_eq!(queue[0]["kind"], "blocked");
    assert_eq!(queue[0]["reason"], "approve Bash: touch /tmp/x", "{}", queue[0]);

    // The roster's block alone (no program status record) has no
    // message; the terminal's unread notification says why.
    let mut roster_only = snapshot();
    roster_only["notifications"] = json!([
        {"id": "n9", "terminal_id": "term_c", "unread": true, "level": "info",
         "created_at_ms": "210", "title": "Claude Code", "body": "Claude needs your permission to use Bash"},
    ]);
    let queue = snapshot_queue(&roster_only);
    assert_eq!(queue[0]["tab"], "tab_c");
    assert_eq!(queue[0]["reason"], "Claude needs your permission to use Bash", "{}", queue[0]);
}

/// W5-Q (bench r4 #5): `attention next` without `--after` answers the
/// most urgent entry, wherever the focus is; `--after` still cycles.
#[test]
fn w5q_attention_next_without_after_starts_at_the_most_urgent() {
    let mut snapshot = snapshot();
    // The person looks at tab_b (requested, second in the queue).
    snapshot["tabs"][4]["focused"] = json!(false);
    snapshot["panes"][0]["focused"] = json!(false);
    snapshot["panes"][1]["focused"] = json!(true);
    snapshot["screens"][0]["focused"] = json!(false);
    snapshot["screens"][1]["focused"] = json!(true);
    snapshot["workspaces"][0]["focused"] = json!(false);
    snapshot["workspaces"][1]["focused"] = json!(true);
    snapshot["tabs"][1]["focused"] = json!(true);
    snapshot["tabs"][2]["focused"] = json!(false);
    assert_eq!(focused_tab(&snapshot).as_deref(), Some("tab_b"));
    let queue = snapshot_queue(&snapshot);
    assert_eq!(tabs(&queue), vec!["tab_c", "tab_b", "tab_d", "tab_a"]);
    assert_eq!(next_target(&queue, None, None).unwrap()["tab"], "tab_c");
    assert_eq!(next_target(&queue, Some("tab_c"), None).unwrap()["tab"], "tab_b");
    assert_eq!(next_target(&queue, Some("tab_a"), None).unwrap()["tab"], "tab_c");
}

/// W5-Q review (PR A finding 9): `attention next --focus` without
/// `--after` starts after the focused tab, so pressing it again cycles;
/// it does not stay on a blocked tab that focus does not clear.
#[test]
fn w5q_attention_next_focus_starts_after_the_focused_tab() {
    let queue = snapshot_queue(&snapshot());
    assert_eq!(tabs(&queue), vec!["tab_c", "tab_b", "tab_d", "tab_a"]);
    assert_eq!(next_target(&queue, None, Some("tab_c")).unwrap()["tab"], "tab_b");
    assert_eq!(next_target(&queue, None, Some("tab_a")).unwrap()["tab"], "tab_c");
    // A focused tab that needs nothing: the most urgent entry.
    assert_eq!(next_target(&queue, None, Some("tab_e")).unwrap()["tab"], "tab_c");
    // `--after` wins over the focused tab.
    assert_eq!(next_target(&queue, Some("tab_b"), Some("tab_c")).unwrap()["tab"], "tab_d");
}

/// W5-Q review (PR A finding 10): a blocked row's reason is never the
/// program status record's title ("Claude Code" says nothing about why);
/// without a message the terminal's unread notification says why.
#[test]
fn w5q_attention_blocked_reason_is_never_the_record_title() {
    let mut program = snapshot();
    program["terminals"][2]["extra"] = json!({"program_status": [
        {"app": "claude-code", "state": "blocked", "kind": "permission",
         "title": "Claude Code", "since_ms": "150"},
    ]});
    program["notifications"] = json!([
        {"id": "n9", "terminal_id": "term_c", "unread": true, "level": "info",
         "created_at_ms": "210", "title": "Claude Code",
         "body": "Claude needs your permission to use Bash"},
    ]);
    let queue = snapshot_queue(&program);
    assert_eq!(queue[0]["tab"], "tab_c");
    assert_eq!(queue[0]["reason"], "Claude needs your permission to use Bash", "{}", queue[0]);
    program["notifications"] = json!([]);
    let queue = snapshot_queue(&program);
    assert_eq!(queue[0]["reason"], Value::Null, "{}", queue[0]);
}

/// W5-Q (bench r4 #5): a finished agent turn nobody viewed (`done`)
/// comes before a bell or another info notification, whatever their
/// ages: blocked, then done, then the rest.
#[test]
fn w5q_attention_puts_a_finished_turn_before_a_bell() {
    let mut snapshot = snapshot();
    snapshot["tabs"][1]["extra"] = json!({});
    snapshot["agents"] = json!([
        {"id": "agent_c", "terminal_id": "term_c", "state": "blocked", "updated_at_ms": "200"},
        {"id": "agent_e", "terminal_id": "term_e", "state": "idle", "updated_at_ms": "1"},
    ]);
    snapshot["notifications"] = json!([
        {"id": "n1", "terminal_id": "term_a", "unread": true, "level": "info", "created_at_ms": "100", "title": "Bell"},
        {"id": "n3", "terminal_id": "term_e", "unread": true, "level": "info", "created_at_ms": "500", "title": "Claude finished"},
    ]);
    let queue = snapshot_queue(&snapshot);
    assert_eq!(tabs(&queue), vec!["tab_c", "tab_e", "tab_a"]);
    assert_eq!(queue[1]["kind"], "done");
    assert_eq!(queue[2]["kind"], "unread");
    assert_eq!(next_target(&queue, None, None).unwrap()["kind"], "blocked");
}

#[test]
fn attention_cli_flags_take_after_and_focus_only_on_next() {
    let words = |list: &[&str]| list.iter().map(|word| (*word).to_owned()).collect::<Vec<_>>();
    assert_eq!(
        parse_flags("next", &words(&["--focus", "--after", "tab_x"])),
        Ok(Flags { after: Some("tab_x".into()), focus: true })
    );
    assert_eq!(
        parse_flags("next", &words(&["--after=tab_y"])),
        Ok(Flags { after: Some("tab_y".into()), focus: false })
    );
    assert!(parse_flags("list", &words(&["--focus"])).is_err());
    assert!(parse_flags("next", &words(&["--after"])).is_err());
}
