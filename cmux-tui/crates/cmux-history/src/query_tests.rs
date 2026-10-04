use super::{HistoryQuery, HistoryRange, apply, is_displayable, search_text};
use crate::entry::{HistoryEntry, HistoryKind};

const NOW: i64 = 1_800_000_000_000;

fn page(id: &str, title: &str, url: &str, ago_s: i64) -> HistoryEntry {
    let mut entry =
        HistoryEntry::new(format!("page:{id}"), HistoryKind::Page, NOW - ago_s * 1000, title);
    entry.detail = Some(url.to_owned());
    entry.url = Some(url.to_owned());
    entry.profile = Some("default".to_owned());
    entry
}

fn agent(id: &str, provider: &str, cwd: &str, ago_s: i64) -> HistoryEntry {
    let mut entry =
        HistoryEntry::new(format!("agent:{id}"), HistoryKind::Agent, NOW - ago_s * 1000, provider);
    entry.detail = Some(cwd.to_owned());
    entry.cwd = Some(cwd.to_owned());
    entry.provider = Some(provider.to_owned());
    entry.session_id = Some(id.to_owned());
    entry.workspace = Some("api".to_owned());
    entry
}

fn sample() -> Vec<HistoryEntry> {
    vec![
        page("1", "Swift Forums", "https://forums.swift.org/t/1", 60),
        page("2", "Résumé tips", "https://example.com/resume", 7200),
        agent("s-1", "claude", "/Users/me/api", 30),
        page("3", "Old page", "https://old.example.com", 40 * 86_400),
    ]
}

fn ids(query: &HistoryQuery, entries: &[HistoryEntry]) -> Vec<String> {
    apply(query, entries, NOW, NOW - 3_600_000, |_| false)
        .into_iter()
        .map(|entry| entry.id)
        .collect()
}

fn text(text: &str) -> HistoryQuery {
    HistoryQuery { text: text.to_owned(), ..HistoryQuery::default() }
}

#[test]
fn empty_query_is_everything_newest_first() {
    assert_eq!(
        ids(&HistoryQuery::default(), &sample()),
        ["agent:s-1", "page:1", "page:2", "page:3"]
    );
}

#[test]
fn tokens_match_in_any_order_across_fields() {
    assert_eq!(ids(&text("forums SWIFT"), &sample()), ["page:1"]);
    assert_eq!(ids(&text("api claude"), &sample()), ["agent:s-1"]);
}

#[test]
fn diacritics_fold() {
    assert_eq!(ids(&text("resume"), &sample()), ["page:2"]);
    assert_eq!(ids(&text("RÉSUMÉ"), &sample()), ["page:2"]);
}

#[test]
fn kinds_range_and_limit_filter() {
    let pages_hour = HistoryQuery {
        kinds: vec![HistoryKind::Page],
        range: HistoryRange::Hour,
        ..HistoryQuery::default()
    };
    assert_eq!(ids(&pages_hour, &sample()), ["page:1"]);
    let pages_two =
        HistoryQuery { kinds: vec![HistoryKind::Page], limit: Some(2), ..HistoryQuery::default() };
    assert_eq!(ids(&pages_two, &sample()), ["page:1", "page:2"]);
    let month = HistoryQuery { range: HistoryRange::Month, ..HistoryQuery::default() };
    assert_eq!(ids(&month, &sample()).len(), 3);
}

#[test]
fn implementation_pages_and_placeholder_locations_are_hidden() {
    let mut location = HistoryEntry::new("location:history", HistoryKind::Location, NOW, "History");
    location.url = Some("cmux://history".to_owned());
    let mut home = HistoryEntry::new("location:home", HistoryKind::Location, NOW, "~");
    home.cwd = Some("/Users/me".to_owned());
    let noise = vec![
        page("history", "History", "cmux://history", 1),
        page("blank", "about:blank", "about:blank", 2),
        location,
        home,
    ];
    assert!(ids(&HistoryQuery::default(), &noise).is_empty());
}

#[test]
fn directory_file_urls_are_hidden_through_the_predicate() {
    let dir = page("dir", "tmp", "file:///tmp/project/", 1);
    let file = page("file", "notes", "file:///tmp/project/notes.txt", 1);
    let is_dir = |path: &str| path.trim_end_matches('/') == "/tmp/project";
    assert!(!is_displayable(&dir, is_dir));
    assert!(is_displayable(&file, is_dir));
    let mut location = HistoryEntry::new("location:dir", HistoryKind::Location, NOW, "project");
    location.url = Some("file:///tmp/project".to_owned());
    assert!(!is_displayable(&location, is_dir));
}

#[test]
fn about_blank_location_matches_case_insensitively() {
    let mut location = HistoryEntry::new("location:blank", HistoryKind::Location, NOW, "New Tab");
    location.url = Some("ABOUT:BLANK".to_owned());
    assert!(!is_displayable(&location, |_| false));
}

#[test]
fn today_starts_at_the_supplied_local_midnight() {
    let midnight = NOW - 5 * 3_600_000;
    assert_eq!(HistoryRange::Today.bounds(NOW, midnight), Some((midnight, NOW + 1000)));
    assert_eq!(HistoryRange::Hour.start(NOW, midnight), Some(NOW - 3_600_000));
    assert_eq!(HistoryRange::Week.start(NOW, midnight), Some(NOW - 7 * 86_400_000));
    assert_eq!(HistoryRange::Month.start(NOW, midnight), Some(NOW - 28 * 86_400_000));
    assert_eq!(HistoryRange::All.bounds(NOW, midnight), None);
}

#[test]
fn equal_times_order_by_id_descending() {
    let entries = vec![page("a", "A", "https://a/", 5), page("b", "B", "https://b/", 5)];
    assert_eq!(ids(&HistoryQuery::default(), &entries), ["page:b", "page:a"]);
}

#[test]
fn search_text_follows_the_swift_field_order() {
    let mut command = HistoryEntry::new("command:x", HistoryKind::Command, NOW, "make");
    command.detail = Some("/repo".to_owned());
    command.machine = Some("box".to_owned());
    command.command = Some("make".to_owned());
    command.cwd = Some("/repo".to_owned());
    assert_eq!(search_text(&command), "make /repo box make /repo");
    assert_eq!(search_text(&agent("s", "codex", "/w", 0)), "codex /w codex s /w");
}
