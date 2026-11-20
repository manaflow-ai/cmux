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
    // A closed tab can be an agent chat (Swift `HistoryService.closedAgentSession`): the row
    // carries its session id and harness, so the search finds it by them and a client names
    // and brands it. A screen, workspace or window stays its container kind, even when the
    // first tab it would reopen is a chat.
    if item.get("kind").and_then(Value::as_str) == Some("tab")
        && let Some(agent) = tab.and_then(|tab| tab.get("agent_session"))
    {
        entry.session_id = text(Some(agent), "session");
        entry.provider = text(Some(agent), "harness");
    }
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

    /// A closed tab item (`closed.list` shape) that holds the one tab `tab`.
    fn closed_tab(id: &str, at_ms: i64, tab: Value) -> Value {
        serde_json::json!({"id": id, "kind": "tab", "closed_at_ms": at_ms,
            "screens": [{"tabs": [tab]}]})
    }

    /// Port of the Swift `ClosedAgentIdentityTests.daemonClosedSearchFiltersAfterEnrichmentAndBeforeLimit`:
    /// a closed chat is found by its agent session id and harness, even when newer unrelated
    /// closes outnumber the result limit. The app no longer enriches closed rows; the merged
    /// history carries the chat's identity itself.
    #[test]
    fn closed_chat_search_matches_session_and_harness_before_limit() {
        let chat = serde_json::json!({"kind": "conversation", "url": "about:blank",
            "agent_session": {"session": "same-session", "harness": "codex"}});
        let mut items = vec![closed_tab("closed_1", 1, chat)];
        for index in 2..=60 {
            let tab = serde_json::json!({"kind": "browser", "name": "Other",
                "url": format!("https://other.example/{index}")});
            items.push(closed_tab(&format!("closed_{index}"), index, tab));
        }
        let entries = closed_entries(&items);
        for (text, found) in [("same-session", true), ("codex", true), ("no-such-chat", false)] {
            let query = cmux_history::HistoryQuery {
                kinds: vec![HistoryKind::Closed],
                text: text.to_owned(),
                limit: Some(1),
                ..Default::default()
            };
            let matched = query.apply(&entries, 100, 0, |_| false);
            let ids: Vec<&str> = matched.iter().map(|entry| entry.id.as_str()).collect();
            assert_eq!(ids, if found { vec!["closed:daemon:closed_1"] } else { vec![] }, "{text}");
            if let Some(entry) = matched.first() {
                assert_eq!(entry.session_id.as_deref(), Some("same-session"));
                assert_eq!(entry.provider.as_deref(), Some("codex"));
                assert_eq!(entry.closed_kind, Some(ClosedKind::ConversationTab));
            }
        }
    }

    /// Port of the Swift `ClosedAgentIdentityTests.closedContainersRetainTheirOwnKind`: only a
    /// closed tab is a chat. A screen, workspace or window keeps its container kind and carries
    /// no agent identity, even when the first tab it would reopen is a chat.
    #[test]
    fn closed_containers_carry_no_agent_identity() {
        let chat = serde_json::json!({"kind": "conversation", "name": "Fix the flaky upload test",
            "url": "about:blank", "agent_session": {"session": "sess-closed", "harness": "codex"}});
        let tab = closed_entry(&closed_tab("closed_1", 1, chat.clone())).unwrap();
        assert_eq!(tab.session_id.as_deref(), Some("sess-closed"));
        assert_eq!(tab.provider.as_deref(), Some("codex"));
        for kind in ["screen", "workspace", "window"] {
            let mut item = closed_tab("closed_1", 1, chat.clone());
            item["kind"] = serde_json::json!(kind);
            let entry = closed_entry(&item).unwrap();
            assert_eq!((entry.session_id, entry.provider), (None, None), "{kind}");
        }
    }

    /// A plain browser tab and a chat with no session yet carry no session id; a chat's harness
    /// alone still names its brand.
    #[test]
    fn closed_tab_without_session_carries_no_session_id() {
        let browser =
            serde_json::json!({"kind": "browser", "name": "Docs", "url": "https://docs.example/"});
        let entry = closed_entry(&closed_tab("closed_1", 1, browser)).unwrap();
        assert_eq!((entry.session_id, entry.provider), (None, None));
        let pending = serde_json::json!({"kind": "conversation", "name": "Chat", "url": "about:blank",
            "agent_session": {"session": null, "harness": "claude"}});
        let entry = closed_entry(&closed_tab("closed_2", 1, pending)).unwrap();
        assert_eq!(entry.session_id, None);
        assert_eq!(entry.provider.as_deref(), Some("claude"));
    }
}
