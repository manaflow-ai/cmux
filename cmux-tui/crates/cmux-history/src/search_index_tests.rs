use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};

use super::{Backfill, SearchDoc, SearchFeed, SearchIndex, SearchKind};
use crate::error::HistoryError;

const T0: i64 = 1_800_000_000_000;

/// A fresh directory under the system temp dir, removed on drop.
struct TempDir(PathBuf);

impl TempDir {
    fn new(label: &str) -> Self {
        static COUNTER: AtomicU32 = AtomicU32::new(0);
        let n = COUNTER.fetch_add(1, Ordering::Relaxed);
        let path =
            std::env::temp_dir().join(format!("cmux-search-{label}-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        Self(path)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn chat(session: &str, turn: i64, text: &str) -> SearchDoc {
    SearchDoc {
        key: format!("chat:{session}:{turn}"),
        source: format!("acpmux:{session}"),
        kind: SearchKind::Chat,
        target: session.to_owned(),
        position: Some(turn),
        title: format!("Chat {session}"),
        text: text.to_owned(),
        at_ms: T0 + turn,
    }
}

fn named(kind: SearchKind, id: &str, name: &str) -> SearchDoc {
    SearchDoc {
        key: format!("{}:{id}", kind.as_str()),
        source: kind.as_str().to_owned(),
        kind,
        target: id.to_owned(),
        position: None,
        title: name.to_owned(),
        text: name.to_owned(),
        at_ms: T0,
    }
}

fn keys(index: &SearchIndex, query: &str, kinds: &[SearchKind]) -> Vec<String> {
    index.search(query, kinds, 50).unwrap().into_iter().map(|hit| hit.key).collect()
}

#[test]
fn finds_text_inside_a_message_and_points_at_it() {
    let mut index = SearchIndex::open_in_memory().unwrap();
    index
        .append(
            "acpmux:s1",
            &[
                chat("s1", 0, "Why is CI red on main?"),
                chat("s1", 1, "The flaky middle-click test"),
            ],
            Some(2),
        )
        .unwrap();
    let hits = index.search("middle-click", &[], 10).unwrap();
    assert_eq!(hits.len(), 1);
    let hit = &hits[0];
    assert_eq!((hit.kind, hit.target.as_str(), hit.position), (SearchKind::Chat, "s1", Some(1)));
    assert_eq!(hit.title, "Chat s1");
    // The snippet marks the match.
    let marked: Vec<&str> =
        hit.highlights.iter().map(|range| &hit.snippet[range.clone()]).collect();
    assert_eq!(marked.concat().to_lowercase(), "middle-click");
}

#[test]
fn matching_folds_case_and_diacritics() {
    let mut index = SearchIndex::open_in_memory().unwrap();
    index.append("acpmux:s1", &[chat("s1", 0, "Lunch at the Café Zürich")], None).unwrap();
    assert_eq!(keys(&index, "CAFE zurich", &[]), ["chat:s1:0"]);
}

#[test]
fn every_word_must_match_and_newest_come_first() {
    let mut index = SearchIndex::open_in_memory().unwrap();
    index
        .append(
            "acpmux:s1",
            &[
                chat("s1", 0, "deploy the relay"),
                chat("s1", 1, "deploy the web app"),
                chat("s1", 2, "relay logs after the deploy"),
            ],
            None,
        )
        .unwrap();
    assert_eq!(keys(&index, "deploy relay", &[]), ["chat:s1:2", "chat:s1:0"]);
}

#[test]
fn kinds_filter_the_hits() {
    let mut index = SearchIndex::open_in_memory().unwrap();
    index.append("acpmux:s1", &[chat("s1", 0, "cargo test --workspace")], None).unwrap();
    let mut command = named(SearchKind::Command, "t1:7", "cargo test --workspace");
    command.target = "t1".to_owned();
    command.position = Some(7);
    command.source = "shell:t1".to_owned();
    index.append("shell:t1", &[command], None).unwrap();
    assert_eq!(keys(&index, "cargo test", &[SearchKind::Command]), ["command:t1:7"]);
    assert_eq!(keys(&index, "cargo test", &[SearchKind::Chat]), ["chat:s1:0"]);
    assert_eq!(keys(&index, "cargo test", &[]).len(), 2);
}

#[test]
fn a_renamed_workspace_is_found_by_its_new_name_only() {
    let mut index = SearchIndex::open_in_memory().unwrap();
    index.upsert(&named(SearchKind::Workspace, "w1", "Sidebar polish")).unwrap();
    index.upsert(&named(SearchKind::Workspace, "w1", "Search index")).unwrap();
    assert!(keys(&index, "polish", &[]).is_empty());
    assert_eq!(keys(&index, "index", &[]), ["workspace:w1"]);
}

#[test]
fn short_queries_match_tab_and_workspace_names() {
    let mut index = SearchIndex::open_in_memory().unwrap();
    index.upsert(&named(SearchKind::Tab, "tab1", "ui tests")).unwrap();
    index.append("acpmux:s1", &[chat("s1", 0, "the ui is slow")], None).unwrap();
    // Two letters: too short for the text index, so only names match.
    assert_eq!(keys(&index, "ui", &[]), ["tab:tab1"]);
    assert!(keys(&index, " ", &[]).is_empty());
}

#[test]
fn a_purged_source_leaves_the_index() {
    let mut index = SearchIndex::open_in_memory().unwrap();
    index.append("acpmux:s1", &[chat("s1", 0, "secret plan")], Some(1)).unwrap();
    index.remove_source("acpmux:s1").unwrap();
    assert!(keys(&index, "secret", &[]).is_empty());
    assert_eq!(index.cursor("acpmux:s1").unwrap(), None);
}

/// A feed of `count` messages per session, `budget` at a time.
struct Messages {
    sessions: Vec<String>,
    count: i64,
}

impl SearchFeed for Messages {
    fn sources(&self) -> Result<Vec<String>, HistoryError> {
        Ok(self.sessions.iter().map(|session| format!("acpmux:{session}")).collect())
    }

    fn read(
        &self,
        source: &str,
        after: Option<i64>,
        max: usize,
    ) -> Result<(Vec<SearchDoc>, i64), HistoryError> {
        let session = source.trim_start_matches("acpmux:");
        let start = after.unwrap_or(0);
        let end = (start + max as i64).min(self.count);
        let docs = (start..end)
            .map(|turn| chat(session, turn, &format!("message {turn} of {session}")))
            .collect();
        Ok((docs, end))
    }
}

#[test]
fn backfill_works_in_bounded_steps_and_resumes_after_a_restart() {
    let dir = TempDir::new("backfill");
    let path = dir.0.join("search.sqlite");
    let feed = Messages { sessions: vec!["a".to_owned(), "b".to_owned()], count: 7 };
    {
        let mut index = SearchIndex::open(&path).unwrap();
        let first = Backfill::step(&mut index, &feed, 5).unwrap();
        assert_eq!((first.indexed, first.done), (5, false));
        let second = Backfill::step(&mut index, &feed, 5).unwrap();
        assert_eq!((second.indexed, second.done), (5, false));
    }
    // A restart: the cursors carry on where the last step stopped.
    let mut index = SearchIndex::open(&path).unwrap();
    let mut total = 10;
    loop {
        let step = Backfill::step(&mut index, &feed, 5).unwrap();
        assert!(step.indexed <= 5);
        total += step.indexed;
        if step.done {
            break;
        }
    }
    assert_eq!(total, 14);
    assert_eq!(index.cursor("acpmux:a").unwrap(), Some(7));
    assert_eq!(keys(&index, "message", &[]).len(), 14, "nothing indexed twice");
    // New messages later: only those are read.
    let more = Messages { sessions: feed.sessions.clone(), count: 8 };
    assert_eq!(Backfill::step(&mut index, &more, 100).unwrap().indexed, 2);
}

/// The budget for a first page of results.
const FIRST_RESULTS: std::time::Duration = std::time::Duration::from_millis(50);

/// A big history: 100,000 chat messages, 20,000 commands and 1,000 names,
/// queried on a fresh connection.
#[test]
fn first_results_on_a_big_history_come_in_under_50ms() {
    const WORDS: &str = "the deploy relay sidebar flaky test branch merge build release \
        socket daemon terminal workspace café agent review commit palette search index render \
        window focus";
    let words: Vec<&str> = WORDS.split_whitespace().collect();
    let dir = TempDir::new("big");
    let path = dir.0.join("search.sqlite");
    let mut seed: u64 = 7;
    let mut word = || {
        seed = seed.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
        words[(seed >> 33) as usize % words.len()]
    };
    {
        let mut index = SearchIndex::open(&path).unwrap();
        for session in 0..1_000 {
            let docs: Vec<SearchDoc> = (0..100)
                .map(|turn| {
                    let text: Vec<&str> = (0..24).map(|_| word()).collect();
                    let mut doc = chat(&format!("s{session}"), turn, &text.join(" "));
                    if turn == 42 {
                        doc.text.push_str(&format!(" needle{session:04}"));
                    }
                    doc
                })
                .collect();
            index.append(&format!("acpmux:s{session}"), &docs, Some(100)).unwrap();
        }
        for terminal in 0..200 {
            let docs: Vec<SearchDoc> = (0..100)
                .map(|line| {
                    let mut doc = named(SearchKind::Command, &format!("t{terminal}:{line}"), "");
                    doc.text = format!("cargo test -p {} --{}", word(), word());
                    doc.source = format!("shell:t{terminal}");
                    doc
                })
                .collect();
            index.append(&format!("shell:t{terminal}"), &docs, Some(100)).unwrap();
        }
        for id in 0..1_000 {
            let kind = if id % 2 == 0 { SearchKind::Tab } else { SearchKind::Workspace };
            let name = format!("{} {}", word(), word());
            index.upsert(&named(kind, &format!("n{id}"), &name)).unwrap();
        }
    }
    let index = SearchIndex::open(&path).unwrap();
    let queries: [(&str, &[SearchKind]); 7] = [
        ("needle0500", &[]),
        ("deploy", &[]),
        ("the", &[]),
        ("flaky sidebar test", &[]),
        ("cafe", &[]),
        ("cargo relay", &[SearchKind::Command]),
        ("ui", &[]),
    ];
    let mut timings = Vec::new();
    for (query, kinds) in queries {
        let started = std::time::Instant::now();
        let hits = index.search(query, kinds, 50).unwrap();
        timings.push((query, started.elapsed(), hits.len()));
    }
    let slow: Vec<_> = timings.iter().filter(|(_, took, _)| *took >= FIRST_RESULTS).collect();
    assert!(slow.is_empty(), "over {FIRST_RESULTS:?}: {slow:?} (all: {timings:?})");
    assert_eq!(timings[0].2, 1, "the needle is found once");
}
