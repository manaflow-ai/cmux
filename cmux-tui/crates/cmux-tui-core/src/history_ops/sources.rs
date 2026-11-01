//! Entry mappings: closed items from the session's closed-history store and
//! the location trail's entries (trail.rs). Pure mappings, ported from the
//! Swift `HistoryService.daemonClosedEntries` and `locationEntries`.

use cmux_history::{ClosedKind, HistoryEntry, HistoryKind};
use serde_json::Value;

use super::trail::TrailEntry;
use crate::state::closed_history_query::{closed_page, closed_tabs};

/// The closed items worth reopening as entries, newest first, a page closed again once, at
/// its newest close (Leo 2026-10-14: Recently Closed is high signal; `closed_page`).
pub(super) fn closed_entries(items: &[Value]) -> Vec<HistoryEntry> {
    let mut entries = items
        .iter()
        .filter_map(|item| Some((closed_entry(item)?, closed_page(item))))
        .collect::<Vec<_>>();
    entries.sort_by_key(|(entry, _)| std::cmp::Reverse(entry.at_ms));
    let mut seen = std::collections::HashSet::new();
    entries.retain(|(_, page)| page.is_none_or(|page| seen.insert(page)));
    entries.into_iter().map(|(entry, _)| entry).collect()
}

/// The closed groups the row `id` (`closed:daemon:<closed id>`) stands for: its own, and for a
/// page every other close of it, so removing the row leaves no older close to take its place.
pub(super) fn closed_ids_of(items: &[Value], id: &str) -> Vec<String> {
    let row = |item: &Value| {
        let closed = item.get("id").and_then(Value::as_str)?;
        Some(format!("{}{closed}", super::closed::PREFIX))
    };
    let page = items.iter().find(|item| row(item).as_deref() == Some(id)).and_then(closed_page);
    match page {
        Some(page) => {
            items.iter().filter(|item| closed_page(item) == Some(page)).filter_map(row).collect()
        }
        None => vec![id.to_owned()],
    }
}

/// One closed-history item (`closed.list` shape) as an entry
/// `closed:daemon:<closed id>`. An item that reopens as nothing (only tabs
/// `closed.list` marks `empty`: untouched New Tab pages, blank browsers) is
/// left out, and a row is named by its first other tab, never by the
/// `about:blank` placeholder a chat or New Tab page is kept on (Leo
/// 2026-10-11).
fn closed_entry(item: &Value) -> Option<HistoryEntry> {
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
        "tab" if text(tab, "kind").as_deref() == Some("conversation") => {
            ClosedKind::ConversationTab
        }
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

/// One trail entry as a location row (`location:<entry id>`). The daemon
/// cannot know whether the app reaches another machine, so every location
/// reads available; the app greys offline ones itself. `current`: the newest
/// entry (an app's Back/Forward cursor is its own view state).
pub(super) fn location_entry(id: &str, entry: &TrailEntry, current: bool) -> HistoryEntry {
    let text = |key: &str| entry.location.get(key).and_then(Value::as_str).map(str::to_owned);
    let mut history = HistoryEntry::new(
        id,
        HistoryKind::Location,
        entry.at_ms,
        text("title").unwrap_or_default(),
    );
    let workspace_title = text("workspace_title");
    history.detail.clone_from(&workspace_title);
    history.workspace = workspace_title.or_else(|| text("workspace"));
    history.machine = text("machine_name");
    history.current = Some(current);
    history.url = text("url");
    history.cwd = text("cwd");
    history
}

/// A decimal string or a JSON integer.
fn decimal(value: &Value) -> Option<i64> {
    match value {
        Value::String(text) => text.parse().ok(),
        other => other.as_i64(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn closed_chat_keeps_conversation_kind_in_merged_history() {
        for (kind, expected) in
            [("conversation", ClosedKind::ConversationTab), ("browser", ClosedKind::BrowserTab)]
        {
            let item = serde_json::json!({"id":"closed_chat","kind":"tab","closed_at_ms":1,
                "screens":[{"tabs":[{"kind":kind,"url":"about:blank","agent_session":{"session":"sess-closed","harness":"codex"}}]}]});
            let entry = closed_entry(&item).unwrap();
            assert_eq!(entry.closed_kind, Some(expected));
            assert_eq!(entry.id, "closed:daemon:closed_chat");
        }
    }
}
