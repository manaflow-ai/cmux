//! The New Tab page's Recently Closed rows: the newest closed tabs, screens
//! and workspaces from History, each with the kind its row draws, a title
//! that does not repeat its detail, and that detail.

use serde::{Deserialize, Serialize};

/// The most rows the page shows (`AgentPaneClosedItem.maximumPushed`).
pub const MAXIMUM_PUSHED: usize = 8;

/// A History closed item's kind (`CmuxNextHistory.ClosedItem.Kind`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ItemKind {
    TerminalTab,
    ConversationTab,
    BrowserTab,
    Screen,
    Workspace,
}

/// The kind a row draws (`AgentPaneClosedItem.Kind`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum RowKind {
    Terminal,
    Agent,
    Browser,
    Screen,
    Workspace,
}

/// The row kind of a closed item: a browser tab that showed an agent chat
/// reads as the chat.
pub fn kind(item: ItemKind, has_agent_session: bool) -> RowKind {
    match item {
        ItemKind::TerminalTab => RowKind::Terminal,
        ItemKind::ConversationTab => RowKind::Agent,
        ItemKind::BrowserTab if has_agent_session => RowKind::Agent,
        ItemKind::BrowserTab => RowKind::Browser,
        ItemKind::Screen => RowKind::Screen,
        ItemKind::Workspace => RowKind::Workspace,
    }
}

/// A URL's host and percent-encoded path (Foundation's `host()` and
/// `path()`); `None` for a URL with no authority or an empty host.
fn host_and_path(url: &str) -> Option<(&str, &str)> {
    let colon = url.find(':')?;
    let scheme = &url[..colon];
    if scheme.is_empty()
        || !scheme.bytes().all(|b| b.is_ascii_alphanumeric() || b"+-.".contains(&b))
    {
        return None;
    }
    let rest = url[colon + 1..].strip_prefix("//")?;
    let authority_end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let authority = &rest[..authority_end];
    let host_port = authority.rsplit_once('@').map_or(authority, |(_, host)| host);
    let host = if let Some(bracketed) = host_port.strip_prefix('[') {
        bracketed.split_once(']').map(|(host, _)| host)?
    } else {
        host_port.split_once(':').map_or(host_port, |(host, _)| host)
    };
    if host.is_empty() {
        return None;
    }
    let after = &rest[authority_end..];
    let path_end = after.find(['?', '#']).unwrap_or(after.len());
    Some((host, &after[..path_end]))
}

/// `NSString.lastPathComponent`: the part after the last `/`, trailing
/// slashes ignored; `/` stays `/`.
fn last_path_component(path: &str) -> &str {
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() {
        return if path.is_empty() { "" } else { "/" };
    }
    trimmed.rsplit('/').next().unwrap_or(trimmed)
}

/// `NSString.abbreviatingWithTildeInPath` for `home`: the home folder or a
/// path in it starts with `~`.
pub fn abbreviate_home(path: &str, home: Option<&str>) -> String {
    let Some(home) = home.map(|home| home.trim_end_matches('/')).filter(|home| !home.is_empty())
    else {
        return path.to_owned();
    };
    match path.strip_prefix(home) {
        Some("") | Some("/") => "~".to_owned(),
        Some(rest) if rest.starts_with('/') => format!("~{rest}"),
        _ => path.to_owned(),
    }
}

/// A title that is only the address or folder (a daemon record keeps no page
/// title) reads as host and path, or the folder's name, so the row does not
/// repeat its detail.
pub fn title(title: &str, url: Option<&str>, cwd: Option<&str>) -> String {
    if url == Some(title)
        && let Some((host, path)) = url.and_then(host_and_path)
    {
        return if path == "/" { host.to_owned() } else { format!("{host}{path}") };
    }
    if let Some(cwd) = cwd
        && cwd == title
    {
        return last_path_component(cwd).to_owned();
    }
    title.to_owned()
}

/// One History entry, as the app read it.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub id: String,
    /// Seconds since a fixed date; newest first.
    pub time: f64,
    pub title: String,
    #[serde(default)]
    pub detail: Option<String>,
    /// The closed item; `None` for an entry that is not a closed one.
    #[serde(default)]
    pub item: Option<Item>,
}

/// An entry's closed item.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    pub kind: ItemKind,
    #[serde(default)]
    pub agent_session: bool,
    #[serde(default)]
    pub url: Option<String>,
    #[serde(default)]
    pub cwd: Option<String>,
}

/// One row of the page's section.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Row {
    pub id: String,
    pub kind: RowKind,
    pub title: String,
    pub detail: Option<String>,
}

/// The newest `limit` closed entries as rows: newest first, entries that are
/// not closed items skipped, the detail the address, else the folder with
/// `~` for `home`, else the entry's own.
pub fn rows(entries: &[Entry], home: Option<&str>, limit: usize) -> Vec<Row> {
    let mut sorted: Vec<&Entry> = entries.iter().collect();
    sorted.sort_by(|a, b| b.time.total_cmp(&a.time));
    sorted
        .into_iter()
        .filter_map(|entry| {
            let item = entry.item.as_ref()?;
            let detail = item
                .url
                .clone()
                .or_else(|| item.cwd.as_deref().map(|cwd| abbreviate_home(cwd, home)))
                .or_else(|| entry.detail.clone());
            Some(Row {
                id: entry.id.clone(),
                kind: kind(item.kind, item.agent_session),
                title: title(&entry.title, item.url.as_deref(), item.cwd.as_deref()),
                detail,
            })
        })
        .take(limit)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // ClosedAgentIdentityTests: closed chats, in a conversation or a browser tab, are agents.
    #[test]
    fn kinds() {
        assert_eq!(kind(ItemKind::TerminalTab, false), RowKind::Terminal);
        assert_eq!(kind(ItemKind::TerminalTab, true), RowKind::Terminal);
        assert_eq!(kind(ItemKind::ConversationTab, false), RowKind::Agent);
        assert_eq!(kind(ItemKind::BrowserTab, true), RowKind::Agent);
        assert_eq!(kind(ItemKind::BrowserTab, false), RowKind::Browser);
        assert_eq!(kind(ItemKind::Screen, false), RowKind::Screen);
        assert_eq!(kind(ItemKind::Workspace, true), RowKind::Workspace);
    }

    #[test]
    fn an_address_title_reads_as_host_and_path() {
        let url = "https://github.com/manaflow-ai/cmux?tab=1#x";
        assert_eq!(title(url, Some(url), None), "github.com/manaflow-ai/cmux");
        let root = "https://example.com/";
        assert_eq!(title(root, Some(root), None), "example.com");
        let bare = "https://example.com";
        assert_eq!(title(bare, Some(bare), None), "example.com");
        let port = "http://user:pw@localhost:8080/app";
        assert_eq!(title(port, Some(port), None), "localhost/app");
        let v6 = "http://[::1]:3000/";
        assert_eq!(title(v6, Some(v6), None), "::1");
        let encoded = "https://a.com/a%20b";
        assert_eq!(title(encoded, Some(encoded), None), "a.com/a%20b");
    }

    #[test]
    fn an_address_without_a_host_stays() {
        for url in ["about:blank", "file:///tmp/x", "not a url", ""] {
            assert_eq!(title(url, Some(url), None), url, "{url}");
        }
    }

    #[test]
    fn a_page_title_stays() {
        assert_eq!(title("GitHub", Some("https://github.com"), None), "GitHub");
        assert_eq!(title("Terminal fallback", None, Some("/tmp")), "Terminal fallback");
        assert_eq!(title("x", None, None), "x");
    }

    #[test]
    fn a_folder_title_reads_as_its_name() {
        assert_eq!(title("/Users/me/src/cmux", None, Some("/Users/me/src/cmux")), "cmux");
        assert_eq!(title("/Users/me/src/", None, Some("/Users/me/src/")), "src");
        assert_eq!(title("/", None, Some("/")), "/");
        assert_eq!(title("relative", None, Some("relative")), "relative");
    }

    #[test]
    fn home_abbreviates() {
        let home = Some("/Users/me");
        assert_eq!(abbreviate_home("/Users/me", home), "~");
        assert_eq!(abbreviate_home("/Users/me/src", home), "~/src");
        assert_eq!(abbreviate_home("/Users/meow", home), "/Users/meow");
        assert_eq!(abbreviate_home("/tmp", home), "/tmp");
        assert_eq!(abbreviate_home("/Users/me/src", Some("/Users/me/")), "~/src");
        assert_eq!(abbreviate_home("/Users/me/src", None), "/Users/me/src");
    }

    #[test]
    fn rows_are_newest_closed_items_with_their_detail() {
        let entries: Vec<Entry> = serde_json::from_value(json!([
            {"id": "old", "time": 1.0, "title": "/Users/me/a", "item": {"kind": "terminalTab", "cwd": "/Users/me/a"}},
            {"id": "visit", "time": 9.0, "title": "Visit", "detail": "x"},
            {"id": "new", "time": 5.0, "title": "https://a.com/p", "item": {"kind": "browserTab", "url": "https://a.com/p"}},
            {"id": "chat", "time": 3.0, "title": "Chat", "detail": "codex", "item": {"kind": "browserTab", "agentSession": true}},
        ]))
        .unwrap();
        let rows = rows(&entries, Some("/Users/me"), MAXIMUM_PUSHED);
        assert_eq!(
            rows,
            vec![
                Row {
                    id: "new".into(),
                    kind: RowKind::Browser,
                    title: "a.com/p".into(),
                    detail: Some("https://a.com/p".into())
                },
                Row {
                    id: "chat".into(),
                    kind: RowKind::Agent,
                    title: "Chat".into(),
                    detail: Some("codex".into())
                },
                Row {
                    id: "old".into(),
                    kind: RowKind::Terminal,
                    title: "a".into(),
                    detail: Some("~/a".into())
                },
            ]
        );
    }

    #[test]
    fn rows_stop_at_the_limit() {
        let entries: Vec<Entry> = (0..12)
            .map(|i| Entry {
                id: format!("e{i}"),
                time: f64::from(i),
                title: "t".into(),
                detail: None,
                item: Some(Item {
                    kind: ItemKind::Screen,
                    agent_session: false,
                    url: None,
                    cwd: None,
                }),
            })
            .collect();
        let rows = rows(&entries, None, MAXIMUM_PUSHED);
        assert_eq!(rows.len(), MAXIMUM_PUSHED);
        assert_eq!(rows[0].id, "e11");
        assert_eq!(rows[0].detail, None);
    }
}
