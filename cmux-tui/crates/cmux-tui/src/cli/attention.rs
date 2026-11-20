//! `cmux attention next|list`: the tabs that need the person, in the order
//! the TUI's `next-attention` key (`Ctrl-b a`) visits them
//! (`crate::attention`), read from one daemon `session.snapshot`.
//!
//! ```text
//! cmux attention next [--after <tab_…>] [--focus]
//! cmux attention list
//! ```
//!
//! `next` answers `{target, queue_length, focused}`: `target` is the first
//! (most urgent) entry, or with `--after` the entry after that tab, wrapping,
//! or null when nothing needs the person. `--focus` without `--after` starts
//! after the focused tab, so the same key cycles. A blocked entry's `reason`
//! is the agent's own message (its program status `msg`, else its unread
//! notification), never the record's title; an agent's finished turn nobody
//! viewed is `kind: done`. It moves focus only with `--focus`,
//! which sends `tab <tab> focus` (the app's window follows as for that
//! command). `list` answers `{queue}`. `request` and `clear` stay with the
//! resource grammar (`command/state.rs`).

use serde_json::{Value, json};

use super::command::CommandPlan;
use super::{GlobalArgs, Surface, wire};
use crate::attention::{
    AttentionCandidate, AttentionKind, AttentionLevel, attention_queue, next_attention,
};

/// `cmux attention next|list …` from the full argv. `None` for any other
/// command, `request` and `clear` included.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command) = super::parse_globals(args).ok()?;
    if super::has_help_option(&command) {
        return None;
    }
    let (scope, verb, rest) = match command.as_slice() {
        [scope, verb, rest @ ..] => (scope.as_str(), verb.as_str(), rest),
        _ => return None,
    };
    if scope != "attention" || !matches!(verb, "next" | "list") {
        return None;
    }
    Some(match parse_flags(verb, rest) {
        Ok(flags) => run(&global, verb, &flags),
        Err(message) => wire::print_local_error(
            &json!({"code": "usage.invalid", "message": message}),
            global.output,
            2,
        ),
    })
}

#[derive(Debug, Default, PartialEq, Eq)]
struct Flags {
    after: Option<String>,
    focus: bool,
}

fn parse_flags(verb: &str, words: &[String]) -> Result<Flags, String> {
    let mut flags = Flags::default();
    let mut words = words.iter();
    while let Some(word) = words.next() {
        match (verb, word.as_str()) {
            ("next", "--focus") => flags.focus = true,
            ("next", "--after") => {
                let tab = words.next().ok_or("--after takes a tab_… id")?;
                flags.after = Some(tab.clone());
            }
            (_, other) => match other.strip_prefix("--after=").filter(|_| verb == "next") {
                Some(tab) => flags.after = Some(tab.to_owned()),
                None => return Err(format!("attention {verb} does not take {other}")),
            },
        }
    }
    Ok(flags)
}

fn run(global: &GlobalArgs, verb: &str, flags: &Flags) -> i32 {
    let snapshot = match super::mcp::agent_resource(global, super::agents::snapshot_plan()) {
        Ok(snapshot) => snapshot,
        Err(error) => return wire::print_local_error(&error, global.output, 3),
    };
    let queue = snapshot_queue(&snapshot);
    if verb == "list" {
        return wire::print_local_success(&json!({"queue": queue}), global.output);
    }
    // `--focus` cycles: it starts after the tab the person looks at.
    let focused_now = flags.focus.then(|| focused_tab(&snapshot)).flatten();
    let target = next_target(&queue, flags.after.as_deref(), focused_now.as_deref()).cloned();
    let mut focused = false;
    if flags.focus
        && let Some(tab) = target.as_ref().and_then(|entry| text(entry, "tab"))
    {
        if let Err(error) = focus_tab(global, tab) {
            return wire::print_local_error(&error, global.output, 1);
        }
        focused = true;
    }
    let answer = json!({"target": target, "queue_length": queue.len(), "focused": focused});
    wire::print_local_success(&answer, global.output)
}

/// `tab <tab> focus` through the resource grammar, then the app's own tab
/// focus, as `cmux tab <tab> focus` runs it.
fn focus_tab(global: &GlobalArgs, tab: &str) -> Result<Value, Value> {
    let words = ["tab", tab, "focus"].map(str::to_owned);
    let mut plan = match super::command::parse(&words, Surface::CmuxTui) {
        Ok(CommandPlan::Protocol(plan)) => *plan,
        Ok(_) => return Err(json!({"code": "internal", "message": "tab focus is not a request"})),
        Err(error) => return Err(json!({"code": "usage.invalid", "message": error.0})),
    };
    plan.idempotency_key = Some(
        wire::random_idempotency_key()
            .map_err(|error| json!({"code": "internal", "message": error.0}))?,
    );
    let result = super::mcp::agent_resource(global, plan)?;
    super::app_focus::after_daemon(
        global,
        cmux_tui_core::resource::ResourceOperation::TabFocus,
        result,
    )
}

/// What `field` answers for a missing key.
static NULL: Value = Value::Null;

/// `value[key]` without an indexing panic site.
fn field<'a>(value: &'a Value, key: &str) -> &'a Value {
    value.get(key).unwrap_or(&NULL)
}

fn text<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    field(value, key).as_str()
}

fn records<'a>(value: &'a Value, key: &str) -> &'a [Value] {
    field(value, key).as_array().map(Vec::as_slice).unwrap_or_default()
}

/// A Unix ms value the snapshot writes as a number or a decimal string.
fn millis(value: &Value) -> Option<u64> {
    value.as_u64().or_else(|| value.as_str().and_then(|text| text.parse().ok()))
}

fn by_id<'a>(records: &'a [Value], id: &Value) -> Option<&'a Value> {
    if id.is_null() {
        return None;
    }
    records.iter().find(|record| field(record, "id") == id)
}

/// The tab the person looks at: the focused tab of the focused pane of the
/// focused screen of the focused workspace. `next --focus` starts after it.
fn focused_tab(snapshot: &Value) -> Option<String> {
    let focused = |kind: &str| -> Vec<&Value> {
        records(snapshot, kind).iter().filter(|record| field(record, "focused") == true).collect()
    };
    let workspace = field(*focused("workspaces").first()?, "id");
    let screen = focused("screens").into_iter().find(|s| field(s, "workspace_id") == workspace)?;
    let pane =
        focused("panes").into_iter().find(|p| field(p, "screen_id") == field(screen, "id"))?;
    let tab = focused("tabs").into_iter().find(|t| field(t, "pane_id") == field(pane, "id"))?;
    text(tab, "id").map(str::to_owned)
}

/// The snapshot's queue, one JSON entry per tab:
/// `{tab, terminal, workspace_id, workspace, title, kind, reason, level, since_ms}`.
fn snapshot_queue(snapshot: &Value) -> Vec<Value> {
    let tabs = records(snapshot, "tabs");
    let terminals = records(snapshot, "terminals");
    // The tab a terminal shows in, for agent and notification rows.
    let tab_of_terminal = |terminal: &Value| -> Option<String> {
        text(by_id(terminals, terminal)?, "tab_id").map(str::to_owned)
    };
    let position_of = |tab: &str| tabs.iter().position(|record| text(record, "id") == Some(tab));
    let mut candidates = Vec::new();
    let mut details: std::collections::HashMap<(String, AttentionKind), (Option<String>, u64)> =
        std::collections::HashMap::new();
    let mut push = |tab: String, kind, level, age: u64, reason: Option<String>| {
        let Some(position) = position_of(&tab) else { return };
        details.entry((tab.clone(), kind)).or_insert((reason, age));
        candidates.push(AttentionCandidate { key: tab, kind, level, age, position });
    };
    for tab in tabs {
        let Some(id) = text(tab, "id") else { continue };
        let mark = field(field(tab, "extra"), "attention");
        if mark.is_object() {
            let reason = text(mark, "reason").map(str::to_owned);
            let since = millis(field(mark, "at_ms")).unwrap_or(u64::MAX);
            push(id.to_owned(), AttentionKind::Requested, AttentionLevel::Warning, since, reason);
        }
    }
    let notifications = records(snapshot, "notifications");
    for terminal in terminals {
        let blocked = records(field(terminal, "extra"), "program_status")
            .iter()
            .filter(|record| text(record, "state") == Some("blocked"))
            .filter_map(|record| millis(field(record, "since_ms")))
            .min();
        let (Some(since), Some(tab)) = (blocked, text(terminal, "tab_id")) else { continue };
        let reason = blocked_reason(terminal, notifications);
        push(tab.to_owned(), AttentionKind::Blocked, AttentionLevel::Warning, since, reason);
    }
    for agent in records(snapshot, "agents") {
        if text(agent, "state") != Some("blocked") {
            continue;
        }
        let terminal_id = field(agent, "terminal_id");
        let Some(tab) = tab_of_terminal(terminal_id) else { continue };
        let since = millis(field(agent, "updated_at_ms")).unwrap_or(u64::MAX);
        let reason = by_id(terminals, terminal_id)
            .and_then(|terminal| blocked_reason(terminal, notifications));
        push(tab, AttentionKind::Blocked, AttentionLevel::Warning, since, reason);
    }
    // A terminal whose agent finished a turn nobody viewed: the roster's
    // `done`, the word `terminal list --agents` shows.
    let finished: std::collections::HashSet<String> =
        super::terminal_talk::roster::agent_rows(snapshot)
            .into_iter()
            .filter(|row| row.status == Some(cmux_tui_core::AgentStatus::Done))
            .map(|row| row.terminal)
            .collect();
    // Every row of a terminal carries that terminal's current unread marker,
    // so only its newest row says why the tab is unread.
    let mut newest: std::collections::BTreeMap<&str, &Value> = std::collections::BTreeMap::new();
    for notification in notifications {
        let Some(terminal) = text(notification, "terminal_id") else { continue };
        let created = millis(field(notification, "created_at_ms")).unwrap_or(0);
        let kept = newest.get(terminal).map(|row| millis(field(row, "created_at_ms")).unwrap_or(0));
        if kept.is_none_or(|kept| created > kept) {
            newest.insert(terminal, notification);
        }
    }
    for notification in newest.into_values() {
        if field(notification, "unread") != true {
            continue;
        }
        let terminal_id = field(notification, "terminal_id");
        let Some(tab) = tab_of_terminal(terminal_id) else { continue };
        let level = AttentionLevel::parse(text(notification, "level").unwrap_or_default());
        let since = millis(field(notification, "created_at_ms")).unwrap_or(u64::MAX);
        let title = text(notification, "title").filter(|title| !title.is_empty());
        let kind = if terminal_id.as_str().is_some_and(|id| finished.contains(id)) {
            AttentionKind::Done
        } else {
            AttentionKind::Unread
        };
        push(tab, kind, level, since, title.map(str::to_owned));
    }
    attention_queue(candidates)
        .into_iter()
        .map(|entry| {
            let tab = position_of(&entry.key).and_then(|index| tabs.get(index));
            let (reason, since) =
                details.get(&(entry.key.clone(), entry.kind)).cloned().unwrap_or((None, entry.age));
            entry_json(snapshot, &entry, tab.unwrap_or(&NULL), reason, since)
        })
        .collect()
}

/// `value` trimmed, when any text is left.
fn shown(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|text| !text.is_empty())
}

/// Why a blocked terminal waits on the person: its blocked program status
/// message (Claude Code's `approve Bash: …`), else its newest unread
/// notification's body or title (a hook's "needs your permission"). The
/// record's title ("Claude Code") says nothing about why: never used.
fn blocked_reason(terminal: &Value, notifications: &[Value]) -> Option<String> {
    let reported = records(field(terminal, "extra"), "program_status")
        .iter()
        .filter(|record| text(record, "state") == Some("blocked"))
        .find_map(|record| shown(text(record, "msg")));
    if let Some(reason) = reported {
        return Some(reason.to_owned());
    }
    let terminal_id = field(terminal, "id");
    notifications
        .iter()
        .filter(|notification| {
            field(notification, "unread") == true
                && !terminal_id.is_null()
                && field(notification, "terminal_id") == terminal_id
        })
        .max_by_key(|notification| millis(field(notification, "created_at_ms")).unwrap_or(0))
        .and_then(|notification| {
            shown(text(notification, "body")).or_else(|| shown(text(notification, "title")))
        })
        .map(str::to_owned)
}

fn entry_json(
    snapshot: &Value,
    entry: &AttentionCandidate<String>,
    tab: &Value,
    reason: Option<String>,
    since: u64,
) -> Value {
    let terminal = by_id(records(snapshot, "terminals"), field(tab, "content_id"));
    let pane = by_id(records(snapshot, "panes"), field(tab, "pane_id"));
    let screen =
        pane.and_then(|pane| by_id(records(snapshot, "screens"), field(pane, "screen_id")));
    let workspace = screen
        .and_then(|screen| by_id(records(snapshot, "workspaces"), field(screen, "workspace_id")));
    let title = text(tab, "name")
        .filter(|name| !name.is_empty())
        .or_else(|| terminal.and_then(|terminal| text(terminal, "title")))
        .unwrap_or_default();
    let level = match entry.level {
        AttentionLevel::Info => "info",
        AttentionLevel::Warning => "warning",
        AttentionLevel::Error => "error",
    };
    json!({
        "tab": entry.key,
        "terminal": terminal.map(|terminal| field(terminal, "id")),
        "workspace_id": workspace.map(|workspace| field(workspace, "id")),
        "workspace": workspace.map(|workspace| field(workspace, "name")),
        "title": title,
        "kind": entry.kind.as_str(),
        "reason": reason,
        "level": level,
        "since_ms": (since != u64::MAX).then_some(since),
    })
}

/// The entry `attention next` answers: the one after `after` (wrapping),
/// else after `focused` (`--focus`: the key cycles), else the first, the
/// most urgent. Without `--focus` the focused tab does not move the start:
/// an agent asks what needs the person most, wherever the person looks.
fn next_target<'a>(
    queue: &'a [Value],
    after: Option<&str>,
    focused: Option<&str>,
) -> Option<&'a Value> {
    next_entry(queue, after.or(focused))
}

/// The entry after `current` in `queue` (wrapping), else the first.
fn next_entry<'a>(queue: &'a [Value], current: Option<&str>) -> Option<&'a Value> {
    let keys: Vec<AttentionCandidate<&str>> = queue
        .iter()
        .enumerate()
        .map(|(position, entry)| AttentionCandidate {
            key: text(entry, "tab").unwrap_or_default(),
            kind: AttentionKind::Unread,
            level: AttentionLevel::Info,
            age: 0,
            position,
        })
        .collect();
    let target = next_attention(&keys, current.as_ref())?;
    queue.get(target.position)
}

#[cfg(test)]
mod tests {
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
}
