//! The New Tab page's Recently Closed section (`NewTabClosed`, cx-d0d.60): the newest closed
//! rows of History as the page draws them, without favicons (the app adds those). A row
//! reopens through History's own path; a row gone since the page drew refuses.

use crate::reading::{HistoryAgentSession, HistoryKind};
use serde::{Deserialize, Serialize};

/// The most rows one push carries (`AgentPaneClosedItem.maximumPushed`).
pub const MAXIMUM_PUSHED: usize = 8;

/// A row's kind on the page (`AgentPaneClosedItem.Kind`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PageKind {
    Terminal,
    Browser,
    Agent,
    Screen,
    Workspace,
}

/// The closed payload of a History row, as far as the page reads it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceItem {
    pub kind: HistoryKind,
    #[serde(default)]
    pub url: Option<String>,
    #[serde(default)]
    pub cwd: Option<String>,
    #[serde(default)]
    pub agent_session: Option<HistoryAgentSession>,
}

/// One History row (`HistoryEntry`) as the page reads it; a row that is not a closed one has
/// no `closed` and is skipped.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Source {
    pub id: String,
    #[serde(default)]
    pub time_ms: u64,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub detail: Option<String>,
    #[serde(default = "available")]
    pub is_available: bool,
    #[serde(default)]
    pub closed: Option<SourceItem>,
}

fn available() -> bool {
    true
}

/// One row of the section (`AgentPaneClosedItem`, its `json` shape without the icon).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PageItem {
    /// The History entry id.
    pub id: String,
    pub kind: PageKind,
    pub title: String,
    /// The address or folder under the title.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    /// Close time, ms since 1970.
    pub closed_at: u64,
    /// False while its machine is not connected: dimmed, not clickable.
    pub available: bool,
}

/// The page kind of a closed row (`kind(for:)`): a browser tab of an agent chat is an agent.
pub fn kind(item: &SourceItem) -> PageKind {
    match item.kind {
        HistoryKind::TerminalTab => PageKind::Terminal,
        HistoryKind::ConversationTab => PageKind::Agent,
        HistoryKind::BrowserTab if item.agent_session.is_some() => PageKind::Agent,
        HistoryKind::BrowserTab => PageKind::Browser,
        HistoryKind::Screen => PageKind::Screen,
        HistoryKind::Workspace => PageKind::Workspace,
    }
}

/// The section's rows (`items`): newest first, only closed rows, at most [`MAXIMUM_PUSHED`].
/// A row's detail is its address, else its folder with the home folder as `~`, else the
/// History row's detail. `home` is the user's home folder.
pub fn items(sources: &[Source], home: &str) -> Vec<PageItem> {
    let mut sorted: Vec<&Source> = sources.iter().collect();
    sorted.sort_by_key(|source| std::cmp::Reverse(source.time_ms));
    sorted
        .into_iter()
        .filter_map(|source| {
            let item = source.closed.as_ref()?;
            let detail = item
                .url
                .clone()
                .or_else(|| item.cwd.as_deref().map(|cwd| abbreviate_tilde(cwd, home)))
                .or_else(|| source.detail.clone());
            Some(PageItem {
                id: source.id.clone(),
                kind: kind(item),
                title: title(&source.title, item.url.as_deref(), item.cwd.as_deref()),
                detail,
                closed_at: source.time_ms,
                available: source.is_available,
            })
        })
        .take(MAXIMUM_PUSHED)
        .collect()
}

/// A title that is only the address or folder (a daemon record keeps no page title) reads as
/// host and path, or the folder's name, so the row does not repeat its detail (`title`).
pub fn title(title: &str, url: Option<&str>, cwd: Option<&str>) -> String {
    if let Some(url) = url
        && title == url
        && let Some((host, path)) = host_and_path(url)
    {
        return if path == "/" { host } else { host + &path };
    }
    if let Some(cwd) = cwd
        && title == cwd
    {
        return last_path_component(cwd);
    }
    title.to_owned()
}

/// A URL's host and path as Foundation reads them (`URL.host()`, `URL.path()`, both
/// percent-decoded): None without an authority (`about:blank`, `mailto:`) or without a host.
/// The host drops any user info, port and IPv6 brackets; the path runs to the query or
/// fragment and may be empty.
pub fn host_and_path(url: &str) -> Option<(String, String)> {
    let (scheme, after_colon) = url.split_once(':')?;
    let scheme_ok = scheme.chars().next().is_some_and(|c| c.is_ascii_alphabetic())
        && scheme.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'));
    if !scheme_ok {
        return None;
    }
    let rest = after_colon.strip_prefix("//")?;
    let end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let (authority, after) = rest.split_at_checked(end)?;
    let host_port = authority.rsplit_once('@').map_or(authority, |(_, host)| host);
    let host = if let Some(bracketed) = host_port.strip_prefix('[') {
        bracketed.split_once(']').map(|(host, _)| host)?
    } else {
        host_port.split_once(':').map_or(host_port, |(host, _)| host)
    };
    if host.is_empty() {
        return None;
    }
    let path = after.split(['?', '#']).next().unwrap_or_default();
    Some((percent_decode(host), percent_decode(path)))
}

/// `%XX` decoded; text that does not decode to UTF-8 stays as it was.
pub fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while let Some(&byte) = bytes.get(index) {
        if byte == b'%'
            && let (Some(high), Some(low)) = (
                bytes.get(index + 1).and_then(|b| (*b as char).to_digit(16)),
                bytes.get(index + 2).and_then(|b| (*b as char).to_digit(16)),
            )
        {
            out.push((high * 16 + low) as u8);
            index += 3;
            continue;
        }
        out.push(byte);
        index += 1;
    }
    String::from_utf8(out).unwrap_or_else(|_| text.to_owned())
}

/// `NSString.lastPathComponent`: the last piece after trailing slashes go; `/` for only
/// slashes, empty for empty.
pub fn last_path_component(path: &str) -> String {
    if path.is_empty() {
        return String::new();
    }
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() {
        return "/".to_owned();
    }
    trimmed.rsplit('/').next().unwrap_or(trimmed).to_owned()
}

/// `NSString.abbreviatingWithTildeInPath` for home folder `home`: the home folder itself reads
/// `~`, a path inside it `~/rest`; any other path, or an empty home, is unchanged.
pub fn abbreviate_tilde(path: &str, home: &str) -> String {
    let home = home.trim_end_matches('/');
    if home.is_empty() {
        return path.to_owned();
    }
    match path.strip_prefix(home) {
        Some("") => "~".to_owned(),
        Some(rest) if rest.starts_with('/') => format!("~{rest}"),
        _ => path.to_owned(),
    }
}
