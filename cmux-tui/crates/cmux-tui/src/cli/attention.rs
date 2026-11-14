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
mod tests;
