//! Entries the history module reads from other owners: closed items from
//! the session's closed-history store and locations from the app's
//! `history.trail` projection (the app owns the trail; this only reads it).
//! Both are pure mappings from the owners' JSON, ported from the Swift
//! `HistoryService.daemonClosedEntries` and `locationEntries`.

use cmux_history::{ClosedKind, HistoryEntry, HistoryKind};
use serde_json::Value;

/// Seconds between the Unix epoch and the Swift reference date 2001-01-01.
const SWIFT_REFERENCE_UNIX_S: f64 = 978_307_200.0;

/// One closed-history item (`closed.list` shape) as an entry
/// `closed:daemon:<closed id>`. An item that reopens as nothing (only tabs
/// `closed.list` marks `empty`: untouched New Tab pages, blank browsers) is
/// left out, and a row is named by its first other tab, never by the
/// `about:blank` placeholder a chat or New Tab page is kept on (Leo
/// 2026-10-11).
pub(super) fn closed_entry(item: &Value) -> Option<HistoryEntry> {
    let id = item.get("id")?.as_str()?;
    let at_ms = decimal(item.get("closed_at_ms")?)?;
    let tabs = closed_tabs(item);
    let empty = |tab: &&Value| tab.get("empty").and_then(Value::as_bool) == Some(true);
    let kept = !item.get("group").is_none_or(Value::is_null)
        || item.get("kind").and_then(Value::as_str) == Some("window");
    if !kept && tabs.iter().all(empty) {
        return None;
    }
    let tab = tabs.iter().find(|tab| !empty(tab)).or(tabs.first()).copied();
    let text = |value: Option<&Value>, key: &str| {
        value
            .and_then(|value| value.get(key))
            .and_then(Value::as_str)
            .filter(|text| !text.is_empty() && *text != "about:blank")
            .map(str::to_owned)
    };
    let tab_name = text(tab, "name");
    let url = text(tab, "url");
    let cwd = text(tab, "cwd");
    let closed_kind = match item.get("kind")?.as_str()? {
        "tab" if text(tab, "kind").as_deref() == Some("browser") => ClosedKind::BrowserTab,
        "tab" => ClosedKind::TerminalTab,
        "screen" => ClosedKind::Screen,
        // A closed window lists as a workspace (it reopens with the workspaces it kept).
        "workspace" | "window" => ClosedKind::Workspace,
        _ => return None,
    };
    let title = text(Some(item), "name")
        .or(tab_name)
        .or_else(|| url.clone())
        .or_else(|| cwd.clone())
        // No name, URL or directory: no title; the app shows its localized
        // default ("Terminal").
        .unwrap_or_default();
    let mut entry =
        HistoryEntry::new(format!("closed:daemon:{id}"), HistoryKind::Closed, at_ms, title);
    entry.detail = url.clone().or_else(|| cwd.clone());
    entry.closed_kind = Some(closed_kind);
    entry.url = url;
    entry.cwd = cwd;
    Some(entry)
}

/// Every tab the item would recreate: every member's, else the top level's
/// (a v1 item), as the Swift `ClosedItem.tabs`.
fn closed_tabs(item: &Value) -> Vec<&Value> {
    let tabs_of = |screens: Option<&Value>| {
        screens
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|screen| screen.get("tabs").and_then(Value::as_array))
            .flatten()
            .collect::<Vec<_>>()
    };
    match item.get("members").and_then(Value::as_array).filter(|members| !members.is_empty()) {
        Some(members) => members.iter().flat_map(|member| tabs_of(member.get("screens"))).collect(),
        None => tabs_of(item.get("screens")),
    }
}

/// The trail document's entries as `location:<machine>:<tab>:<index>`. The
/// daemon cannot know whether the app reaches another machine, so every
/// location reads available; the app greys offline ones itself.
pub(super) fn location_entries(trail: &Value) -> Vec<HistoryEntry> {
    let cursor = trail.get("cursor").and_then(Value::as_i64);
    let Some(entries) = trail.get("entries").and_then(Value::as_array) else {
        return Vec::new();
    };
    entries
        .iter()
        .enumerate()
        .filter_map(|(index, entry)| location_entry(entry, index, cursor))
        .collect()
}

fn location_entry(entry: &Value, index: usize, cursor: Option<i64>) -> Option<HistoryEntry> {
    let location = entry.get("location")?;
    if location.get("isIncognito").and_then(Value::as_bool) == Some(true) {
        return None;
    }
    let key = location.get("key")?;
    let machine = key.get("machine")?.as_str()?;
    let tab = key.get("tab")?.as_str()?;
    let text = |key: &str| location.get(key).and_then(Value::as_str).map(str::to_owned);
    let entered = entry.get("enteredAt")?.as_f64()?;
    let at_ms = ((entered + SWIFT_REFERENCE_UNIX_S) * 1000.0).round() as i64;
    let title = text("title").unwrap_or_default();
    let mut history = HistoryEntry::new(
        format!("location:{machine}:{tab}:{index}"),
        HistoryKind::Location,
        at_ms,
        title,
    );
    let workspace_title = text("workspaceTitle");
    history.detail.clone_from(&workspace_title);
    history.workspace = workspace_title.or_else(|| text("workspace"));
    history.machine = text("machineName");
    history.current = Some(i64::try_from(index).ok() == cursor);
    history.url = text("url");
    history.cwd = text("cwd");
    Some(history)
}

/// A decimal string or a JSON integer.
fn decimal(value: &Value) -> Option<i64> {
    match value {
        Value::String(text) => text.parse().ok(),
        other => other.as_i64(),
    }
}
