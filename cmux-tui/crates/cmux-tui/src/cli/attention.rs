//! `cmux attention next|list`: the tabs that need the person, in the order
//! the TUI's `next-attention` key (`Ctrl-b a`) visits them
//! (`crate::attention`), read from one daemon `session.snapshot`.
//!
//! ```text
//! cmux attention next [--after <tab_…>] [--focus]
//! cmux attention list
//! ```
//!
//! `next` answers `{target, queue_length, focused}`: `target` is the entry
//! after the focused tab (or after `--after`), wrapping, else the first, or
//! null when nothing needs the person. It moves focus only with `--focus`,
//! which sends `tab <tab> focus`. `list` answers `{queue}`.

use serde_json::{Value, json};

use super::command::CommandPlan;
use super::{GlobalArgs, wire};
use crate::attention::{
    AttentionCandidate, AttentionKind, AttentionLevel, attention_queue, next_attention,
};

/// A parsed `attention` command (`command.rs` `parse_attention`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum AttentionPlan {
    Next { after: Option<String>, focus: bool },
    List,
}

pub(super) fn run(global: GlobalArgs, plan: AttentionPlan) -> i32 {
    let snapshot = match request(&global, &["session", "current", "snapshot"]) {
        Ok(snapshot) => snapshot,
        Err(error) => return wire::print_local_error(&error, global.output, exit_code(&error)),
    };
    let queue = snapshot_queue(&snapshot);
    let (after, focus) = match plan {
        AttentionPlan::List => {
            return wire::print_local_success(&json!({"queue": queue}), global.output);
        }
        AttentionPlan::Next { after, focus } => (after, focus),
    };
    let current = after.or_else(|| focused_tab(&snapshot));
    let target = next_entry(&queue, current.as_deref()).cloned();
    let mut focused = false;
    if focus && let Some(tab) = target.as_ref().and_then(|entry| text(entry, "tab")) {
        if let Err(error) = request(&global, &["tab", tab, "focus"]) {
            return wire::print_local_error(&error, global.output, exit_code(&error));
        }
        focused = true;
    }
    let answer = json!({"target": target, "queue_length": queue.len(), "focused": focused});
    wire::print_local_success(&answer, global.output)
}

/// The CLI exit code for a failed request: 2 for a usage error, 3 when the
/// session could not be reached, 1 for an error the server answered.
fn exit_code(error: &Value) -> i32 {
    let code = text(error, "code").unwrap_or_default();
    if code.starts_with("usage.") {
        2
    } else if code.starts_with("transport.") {
        3
    } else {
        1
    }
}

/// One request through the public grammar, as `cmux <words>` sends it.
fn request(global: &GlobalArgs, words: &[&str]) -> Result<Value, Value> {
    let words = words.iter().map(|word| (*word).to_owned()).collect::<Vec<_>>();
    match super::command::parse(&words) {
        Ok(CommandPlan::Protocol(plan)) => wire::fetch(global, plan),
        Ok(_) => Err(json!({"code": "internal", "message": "not a protocol request"})),
        Err(error) => Err(json!({"code": "usage.invalid", "message": error.0})),
    }
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
/// focused screen of the focused workspace.
fn focused_tab(snapshot: &Value) -> Option<String> {
    let focused = |kind: &str| -> Vec<&Value> {
        records(snapshot, kind).iter().filter(|record| field(record, "focused") == true).collect()
    };
    let workspace = field(focused("workspaces").first()?, "id");
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
    for agent in records(snapshot, "agents") {
        if text(agent, "state") != Some("blocked") {
            continue;
        }
        let Some(tab) = tab_of_terminal(field(agent, "terminal_id")) else { continue };
        let since = millis(field(agent, "updated_at_ms")).unwrap_or(u64::MAX);
        push(tab, AttentionKind::Blocked, AttentionLevel::Warning, since, None);
    }
    // Every row of a terminal carries that terminal's current unread marker,
    // so only its newest row says why the tab is unread.
    let mut newest: std::collections::BTreeMap<&str, &Value> = std::collections::BTreeMap::new();
    for notification in records(snapshot, "notifications") {
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
        let Some(tab) = tab_of_terminal(field(notification, "terminal_id")) else { continue };
        let level = AttentionLevel::parse(text(notification, "level").unwrap_or_default());
        let since = millis(field(notification, "created_at_ms")).unwrap_or(u64::MAX);
        let title = text(notification, "title").filter(|title| !title.is_empty());
        push(tab, AttentionKind::Unread, level, since, title.map(str::to_owned));
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
    json!({
        "tab": entry.key,
        "terminal": terminal.map(|terminal| field(terminal, "id")),
        "workspace_id": workspace.map(|workspace| field(workspace, "id")),
        "workspace": workspace.map(|workspace| field(workspace, "name")),
        "title": title,
        "kind": entry.kind.as_str(),
        "reason": reason,
        "level": entry.level.as_str(),
        "since_ms": (since != u64::MAX).then_some(since),
    })
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

    /// Two workspaces' worth of tabs: `tab_a` has an unread info
    /// notification, `tab_c` a blocked agent, `tab_d` an unread error,
    /// `tab_e` nothing. `tab_e` is focused.
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
                {"id": "tab_c", "pane_id": "pane_2", "content_id": "term_c", "focused": true, "name": "release", "extra": {}},
                {"id": "tab_d", "pane_id": "pane_1", "content_id": "term_d", "focused": false, "name": null, "extra": {}},
                {"id": "tab_e", "pane_id": "pane_1", "content_id": "term_e", "focused": true, "name": null, "extra": {}},
            ],
            "terminals": [
                {"id": "term_a", "tab_id": "tab_a", "title": "build"},
                {"id": "term_c", "tab_id": "tab_c", "title": "codex"},
                {"id": "term_d", "tab_id": "tab_d", "title": "tests"},
                {"id": "term_e", "tab_id": "tab_e", "title": "zsh"},
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
        assert_eq!(tabs(&queue), vec!["tab_c", "tab_d", "tab_a"]);
        assert_eq!(
            queue[0],
            json!({
                "tab": "tab_c",
                "terminal": "term_c",
                "workspace_id": "ws_2",
                "workspace": "deploy",
                "title": "release",
                "kind": "blocked",
                "reason": null,
                "level": "warning",
                "since_ms": 200,
            })
        );
        assert_eq!(queue[1]["level"], "error");
        assert_eq!(queue[1]["reason"], "tests failed");
        assert_eq!(queue[2]["reason"], "bench done");
        assert_eq!(queue[2]["workspace"], "work");
        assert_eq!(queue[2]["title"], "build");
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
        assert_eq!(tabs(&queue), vec!["tab_c", "tab_a", "tab_d"], "tab_d is info, newest last");
        assert_eq!(queue[2]["level"], "info");
        assert_eq!(queue[2]["reason"], "today");
        assert_eq!(queue[2]["since_ms"], 900);
    }

    #[test]
    fn attention_cli_next_starts_at_the_top_from_a_tab_outside_the_queue_and_cycles() {
        let snapshot = snapshot();
        let queue = snapshot_queue(&snapshot);
        let current = focused_tab(&snapshot);
        assert_eq!(current.as_deref(), Some("tab_e"));
        assert_eq!(next_entry(&queue, current.as_deref()).unwrap()["tab"], "tab_c");
        assert_eq!(next_entry(&queue, Some("tab_c")).unwrap()["tab"], "tab_d");
        assert_eq!(next_entry(&queue, Some("tab_a")).unwrap()["tab"], "tab_c");
        assert!(next_entry(&[], Some("tab_a")).is_none());
    }

    #[test]
    fn attention_cli_read_notifications_and_working_agents_do_not_count() {
        let mut snapshot = snapshot();
        snapshot["agents"] = json!([
            {"id": "agent_e", "terminal_id": "term_e", "state": "working", "updated_at_ms": "1"},
        ]);
        snapshot["notifications"] = json!([
            {"id": "n3", "terminal_id": "term_e", "unread": false, "level": "error", "created_at_ms": "50"},
        ]);
        assert!(snapshot_queue(&snapshot).is_empty());
    }

    #[test]
    fn attention_cli_parses_next_and_list_with_their_flags_only() {
        let parse = |words: &[&str]| {
            let words = words.iter().map(|word| (*word).to_owned()).collect::<Vec<_>>();
            match super::super::command::parse(&words) {
                Ok(CommandPlan::Attention(plan)) => Ok(plan),
                Ok(_) => panic!("{words:?} is not an attention plan"),
                Err(error) => Err(error.0),
            }
        };
        assert_eq!(
            parse(&["attention", "next", "--focus", "--after", "tab_x"]),
            Ok(AttentionPlan::Next { after: Some("tab_x".into()), focus: true })
        );
        assert_eq!(
            parse(&["attention", "next", "--after=tab_y"]),
            Ok(AttentionPlan::Next { after: Some("tab_y".into()), focus: false })
        );
        assert_eq!(parse(&["attention", "list"]), Ok(AttentionPlan::List));
        assert!(parse(&["attention", "list", "--focus"]).is_err());
        assert!(parse(&["attention", "next", "--after"]).is_err());
        assert!(parse(&["attention", "next", "--after", ""]).is_err(), "an empty tab id");
        assert!(parse(&["attention", "next", "--after", "tab_"]).is_err());
        assert!(parse(&["attention", "next", "--after", "term_x"]).is_err(), "not a tab id");
        assert!(parse(&["attention", "request"]).is_err());
    }

    #[test]
    fn attention_cli_exit_codes_follow_the_error_kind() {
        assert_eq!(exit_code(&json!({"code": "usage.invalid"})), 2);
        assert_eq!(exit_code(&json!({"code": "transport.unavailable"})), 3);
        assert_eq!(exit_code(&json!({"code": "not_found", "message": "no such tab"})), 1);
        assert_eq!(exit_code(&json!({})), 1);
    }
}
