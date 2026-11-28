//! Search Tabs rows: which open and recently closed tabs the page lists, in what order and
//! sections, with what text and ranking boost. A port of the macOS palette's `TabSearchPlan`; the
//! host formats what is platform text (a closed tab's relative time, the abbreviated folder) and
//! passes it with each entry.
//!
//! Open tabs come first. `recent` and `compact` list them by last use with the current tab on
//! top (the page then selects the second row, so Return switches back to the previous tab);
//! `grouped` lists them by window and workspace in layout order. Recently closed tabs follow,
//! newest first: [`CLOSED_LISTED`] of them before the user types, up to [`CLOSED_SEARCHABLE`] for
//! a query.

use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};

pub const CLOSED_LISTED: usize = 10;
pub const CLOSED_LISTED_COMPACT: usize = 5;
pub const CLOSED_SEARCHABLE: usize = 50;
/// Ranking boost of the most recently used tab; each older tab gets [`RECENCY_STEP`] less, down to
/// zero.
pub const RECENCY_BOOST: i64 = 16;
pub const RECENCY_STEP: i64 = 2;
/// The order of the Recently Closed section, below every open section.
pub const CLOSED_ORDER: i64 = 1_000_000;

/// The page's layout (`palette.tabSearchStyle`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Style {
    #[default]
    Recent,
    Grouped,
    Compact,
}

/// What kind of tab an entry is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    Terminal,
    Browser,
    RemoteTerminal,
    #[default]
    Other,
}

/// One candidate: an open tab anywhere or a recently closed one, with the host's platform text.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Entry {
    pub id: String,
    pub kind: Kind,
    pub title: String,
    pub url: Option<String>,
    pub cwd: Option<String>,
    pub process: Option<String>,
    #[serde(rename = "workspaceID")]
    pub workspace_id: Option<String>,
    pub workspace_title: Option<String>,
    pub window_title: Option<String>,
    pub machine: Option<String>,
    /// Position in the layout: the grouped order and the tie-break everywhere.
    pub order: i64,
    pub is_closed: bool,
    pub is_current: bool,
    /// When the tab was last used (seconds, any epoch): last active for an open tab, the close
    /// time for a closed one; none when never.
    pub last_used: Option<f64>,
    /// The URL's host without `www.`, as the host reads it.
    pub host: Option<String>,
    /// The folder as a row shows it (`~/src/api`), and its last component (`api`).
    pub folder: Option<String>,
    pub folder_name: Option<String>,
    /// A closed tab's close time as the row shows it ("5 min. ago").
    pub closed_text: Option<String>,
}

/// The localized text the rows use.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Strings {
    pub current: String,
    pub untitled: String,
    pub open_section: String,
    pub closed_section: String,
    pub kind_terminal: String,
    pub kind_browser: String,
    pub kind_tab: String,
}

/// A titled group of rows; `order` keeps open tabs above closed ones for every query.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Section {
    pub id: String,
    pub title: String,
    pub order: i64,
}

/// One row: its entry (by index into the request's entries), section, text and ranking.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Row {
    pub entry: usize,
    pub section: Section,
    pub title: String,
    pub subtitle: Option<String>,
    pub accessory: Option<String>,
    /// Matched after the title: URL, full directory, process, workspace, machine and kind.
    pub keywords: Vec<String>,
    /// Ranking boost for a typed query: recent tabs win ties.
    pub rank_bias: i64,
    /// Listed before the user types (older closed tabs only match a query).
    pub is_visible_when_query_empty: bool,
}

fn most_recent_first(lhs: &Entry, rhs: &Entry) -> Ordering {
    if lhs.is_current != rhs.is_current {
        return if lhs.is_current { Ordering::Less } else { Ordering::Greater };
    }
    match (lhs.last_used, rhs.last_used) {
        (Some(l), Some(r)) if l != r => r.total_cmp(&l),
        (Some(_), None) => Ordering::Less,
        (None, Some(_)) => Ordering::Greater,
        _ => lhs.order.cmp(&rhs.order),
    }
}

fn newest_first(lhs: &Entry, rhs: &Entry) -> Ordering {
    let l = lhs.last_used.unwrap_or(f64::NEG_INFINITY);
    let r = rhs.last_used.unwrap_or(f64::NEG_INFINITY);
    if l != r { r.total_cmp(&l) } else { lhs.order.cmp(&rhs.order) }
}

/// The rows of `entries` for `style`.
pub fn rows(entries: &[Entry], style: Style, strings: &Strings) -> Vec<Row> {
    // Ids are unique per kind of row; a repeat (two machines reusing an id) keeps its first entry
    // rather than listing a row twice.
    let mut seen_open = HashSet::new();
    let mut seen_closed = HashSet::new();
    let open: Vec<usize> = (0..entries.len())
        .filter(|&i| !entries[i].is_closed && seen_open.insert(entries[i].id.as_str()))
        .collect();
    let mut closed: Vec<usize> = (0..entries.len())
        .filter(|&i| entries[i].is_closed && seen_closed.insert(entries[i].id.as_str()))
        .collect();
    closed.sort_by(|&a, &b| newest_first(&entries[a], &entries[b]));
    closed.truncate(CLOSED_SEARCHABLE);
    let mut by_recency = open.clone();
    by_recency.sort_by(|&a, &b| most_recent_first(&entries[a], &entries[b]));
    let mut rank_of: HashMap<&str, usize> = HashMap::new();
    for (rank, &index) in by_recency.iter().enumerate() {
        rank_of.entry(entries[index].id.as_str()).or_insert(rank);
    }
    let rank = |index: usize| rank_of.get(entries[index].id.as_str()).copied().unwrap_or(0);
    let open_section =
        Section { id: "tabSearch.open".into(), title: strings.open_section.clone(), order: 0 };
    let mut out = Vec::new();
    match style {
        Style::Recent | Style::Compact => {
            for &index in &by_recency {
                out.push(row(entries, index, open_section.clone(), style, rank(index), strings));
            }
        }
        Style::Grouped => {
            let mut layout = open;
            layout.sort_by_key(|&index| entries[index].order);
            let mut group_order: HashMap<String, i64> = HashMap::new();
            for index in layout {
                let key = group_key(&entries[index]);
                let next = group_order.len() as i64;
                let order = *group_order.entry(key.clone()).or_insert(next);
                let section = Section {
                    id: format!("tabSearch.group.{key}"),
                    title: group_title(&entries[index], strings),
                    order,
                };
                out.push(row(entries, index, section, style, rank(index), strings));
            }
        }
    }
    let closed_section = Section {
        id: "tabSearch.closed".into(),
        title: strings.closed_section.clone(),
        order: CLOSED_ORDER,
    };
    let listed = if style == Style::Compact { CLOSED_LISTED_COMPACT } else { CLOSED_LISTED };
    for (position, &index) in closed.iter().enumerate() {
        let mut closed_row = row(entries, index, closed_section.clone(), style, position, strings);
        closed_row.rank_bias = 0;
        closed_row.is_visible_when_query_empty = position < listed;
        out.push(closed_row);
    }
    out
}

/// The row the page selects before the user types (of the rows listed then): the second one when
/// the first is the current tab and another open tab follows.
pub fn empty_query_selection(entries: &[Entry], rows: &[Row]) -> usize {
    let open = rows.iter().filter(|row| !entries[row.entry].is_closed).count();
    let first_is_current = rows.first().is_some_and(|row| entries[row.entry].is_current);
    if open > 1 && first_is_current { 1 } else { 0 }
}

fn row(
    entries: &[Entry],
    index: usize,
    section: Section,
    style: Style,
    rank: usize,
    strings: &Strings,
) -> Row {
    let entry = &entries[index];
    let mut subtitle_parts: Vec<String> = Vec::new();
    if let Some(place) = place_text(entry, style == Style::Compact) {
        subtitle_parts.push(place);
    }
    if style == Style::Recent
        && let Some(workspace) = entry.workspace_title.as_ref().filter(|title| !title.is_empty())
    {
        subtitle_parts.push(workspace.clone());
    }
    if style != Style::Compact {
        if let Some(machine) = &entry.machine {
            subtitle_parts.push(machine.clone());
        }
        if style == Style::Recent
            && let Some(window) = &entry.window_title
        {
            subtitle_parts.push(window.clone());
        }
    }
    let accessory = if entry.is_closed {
        entry.closed_text.clone()
    } else if entry.is_current {
        Some(strings.current.clone())
    } else if style == Style::Compact {
        None
    } else {
        entry.process.clone()
    };
    let mut keywords: Vec<String> =
        [&entry.url, &entry.cwd, &entry.process, &entry.workspace_title, &entry.machine]
            .into_iter()
            .flatten()
            .cloned()
            .collect();
    keywords.push(
        match entry.kind {
            Kind::Terminal | Kind::RemoteTerminal => &strings.kind_terminal,
            Kind::Browser => &strings.kind_browser,
            Kind::Other => &strings.kind_tab,
        }
        .clone(),
    );
    Row {
        entry: index,
        section,
        title: if entry.title.is_empty() { strings.untitled.clone() } else { entry.title.clone() },
        subtitle: (!subtitle_parts.is_empty()).then(|| subtitle_parts.join(" · ")),
        accessory,
        keywords,
        rank_bias: (RECENCY_BOOST - RECENCY_STEP * rank as i64).max(0),
        is_visible_when_query_empty: true,
    }
}

/// The site of a page or the folder of a terminal: `github.com`, `~/src/api` (`api` when short).
fn place_text(entry: &Entry, short: bool) -> Option<String> {
    if let Some(host) = &entry.host {
        return Some(host.clone());
    }
    if let Some(url) = entry.url.as_ref().filter(|url| !url.is_empty()) {
        return Some(url.clone());
    }
    let cwd = entry.cwd.as_ref().filter(|cwd| !cwd.is_empty())?;
    if short {
        let name = entry.folder_name.as_deref().unwrap_or_default();
        return Some(if name.is_empty() { cwd.clone() } else { name.to_owned() });
    }
    Some(entry.folder.clone().unwrap_or_else(|| cwd.clone()))
}

fn group_key(entry: &Entry) -> String {
    format!(
        "{}|{}|{}",
        entry.window_title.as_deref().unwrap_or_default(),
        entry.machine.as_deref().unwrap_or_default(),
        entry.workspace_id.as_deref().unwrap_or_default()
    )
}

fn group_title(entry: &Entry, strings: &Strings) -> String {
    let workspace = entry
        .workspace_title
        .clone()
        .filter(|title| !title.is_empty())
        .unwrap_or_else(|| strings.untitled.clone());
    [entry.window_title.clone(), Some(workspace), entry.machine.clone()]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>()
        .join(" · ")
}

/// A `tabSearchRows` request: the entries, the layout and the text.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Request {
    pub entries: Vec<Entry>,
    pub style: Style,
    pub strings: Strings,
}

/// The answer: the rows, and the empty query's row among those listed before typing.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Answer {
    pub rows: Vec<Row>,
    pub empty_query_selection: usize,
}

pub fn answer(request: &Request) -> Answer {
    let rows = rows(&request.entries, request.style, &request.strings);
    let listed: Vec<Row> =
        rows.iter().filter(|row| row.is_visible_when_query_empty).cloned().collect();
    let empty_query_selection = empty_query_selection(&request.entries, &listed);
    Answer { rows, empty_query_selection }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings() -> Strings {
        Strings {
            current: "current".into(),
            untitled: "Untitled".into(),
            open_section: "Open".into(),
            closed_section: "Recently Closed".into(),
            kind_terminal: "terminal".into(),
            kind_browser: "browser".into(),
            kind_tab: "tab".into(),
        }
    }

    fn open(id: &str, order: i64, last: Option<f64>, current: bool) -> Entry {
        Entry {
            id: id.into(),
            kind: Kind::Terminal,
            title: id.to_uppercase(),
            order,
            last_used: last,
            is_current: current,
            ..Entry::default()
        }
    }

    fn closed(id: &str, order: i64, at: f64) -> Entry {
        Entry {
            id: id.into(),
            kind: Kind::Browser,
            title: id.into(),
            order,
            is_closed: true,
            last_used: Some(at),
            closed_text: Some(format!("{at}s ago")),
            ..Entry::default()
        }
    }

    fn ids(entries: &[Entry], rows: &[Row]) -> Vec<String> {
        rows.iter().map(|row| entries[row.entry].id.clone()).collect()
    }

    #[test]
    fn recent_lists_the_current_tab_then_by_last_use_then_closed_newest_first() {
        let entries = vec![
            open("a", 0, Some(10.0), false),
            open("b", 1, None, false),
            open("c", 2, Some(30.0), false),
            open("cur", 3, Some(1.0), true),
            open("a", 4, Some(99.0), false),
            closed("x", 0, 5.0),
            closed("y", 1, 50.0),
            open("d", 5, None, false),
        ];
        let rows = rows(&entries, Style::Recent, &strings());
        assert_eq!(ids(&entries, &rows), ["cur", "c", "a", "b", "d", "y", "x"]);
        let bias: Vec<_> = rows.iter().map(|row| row.rank_bias).collect();
        assert_eq!(bias, [16, 14, 12, 10, 8, 0, 0]);
        assert_eq!(rows[0].accessory.as_deref(), Some("current"));
        assert_eq!(rows[5].accessory.as_deref(), Some("50s ago"));
        assert_eq!(rows[5].section.order, CLOSED_ORDER);
        assert_eq!(rows[5].keywords, ["browser"]);
        let answer = answer(&Request { entries, style: Style::Recent, strings: strings() });
        assert_eq!(answer.empty_query_selection, 1);
    }

    #[test]
    fn closed_tabs_list_ten_then_only_match_and_stop_at_fifty() {
        let entries: Vec<Entry> = (0..60).map(|i| closed(&format!("c{i}"), i, i as f64)).collect();
        let recent = rows(&entries, Style::Recent, &strings());
        assert_eq!(recent.len(), CLOSED_SEARCHABLE);
        assert_eq!(
            recent.iter().filter(|row| row.is_visible_when_query_empty).count(),
            CLOSED_LISTED
        );
        assert_eq!(entries[recent[0].entry].id, "c59");
        let compact = rows(&entries, Style::Compact, &strings());
        assert_eq!(
            compact.iter().filter(|row| row.is_visible_when_query_empty).count(),
            CLOSED_LISTED_COMPACT
        );
        assert_eq!(empty_query_selection(&entries, &recent), 0);
    }

    #[test]
    fn grouped_sections_follow_layout_order() {
        let mut a = open("a", 2, None, false);
        a.window_title = Some("W1".into());
        a.workspace_id = Some("ws1".into());
        a.workspace_title = Some("".into());
        let mut b = open("b", 0, None, false);
        b.window_title = Some("W2".into());
        b.workspace_id = Some("ws2".into());
        b.workspace_title = Some("Api".into());
        b.machine = Some("box".into());
        let mut c = open("c", 1, None, false);
        c.window_title = Some("W1".into());
        c.workspace_id = Some("ws1".into());
        let entries = vec![a, b, c];
        let rows = rows(&entries, Style::Grouped, &strings());
        assert_eq!(ids(&entries, &rows), ["b", "c", "a"]);
        assert_eq!(rows[0].section.id, "tabSearch.group.W2|box|ws2");
        assert_eq!(rows[0].section.title, "W2 · Api · box");
        assert_eq!(rows[0].section.order, 0);
        assert_eq!(rows[1].section.title, "W1 · Untitled");
        assert_eq!((rows[1].section.order, rows[2].section.order), (1, 1));
    }

    #[test]
    fn subtitles_accessories_and_keywords_follow_the_style() {
        let mut entry = open("t", 0, None, false);
        entry.title = String::new();
        entry.cwd = Some("/Users/me/src/api".into());
        entry.folder = Some("~/src/api".into());
        entry.folder_name = Some("api".into());
        entry.process = Some("claude".into());
        entry.workspace_title = Some("Work".into());
        entry.machine = Some("".into());
        entry.window_title = Some("Main".into());
        let entries = vec![entry];
        let recent = &rows(&entries, Style::Recent, &strings())[0];
        assert_eq!(recent.title, "Untitled");
        assert_eq!(recent.subtitle.as_deref(), Some("~/src/api · Work ·  · Main"));
        assert_eq!(recent.accessory.as_deref(), Some("claude"));
        assert_eq!(recent.keywords, ["/Users/me/src/api", "claude", "Work", "", "terminal"]);
        let compact = &rows(&entries, Style::Compact, &strings())[0];
        assert_eq!(compact.subtitle.as_deref(), Some("api"));
        assert_eq!(compact.accessory, None);
        let grouped = &rows(&entries, Style::Grouped, &strings())[0];
        assert_eq!(grouped.subtitle.as_deref(), Some("~/src/api · "));
        let mut web = open("w", 0, None, false);
        web.kind = Kind::Browser;
        web.url = Some("https://www.github.com/x".into());
        web.host = Some("github.com".into());
        let entries = vec![web];
        assert_eq!(
            rows(&entries, Style::Compact, &strings())[0].subtitle.as_deref(),
            Some("github.com")
        );
    }
}
