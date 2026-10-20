//! Behavior of the search-everything index through its public API.

use std::collections::BTreeSet;

use cmux_search::{
    Doc, EngineConfig, Kind, NameDoc, Query, Scope, ScreenFrames, SearchEngine, SyntheticCorpus,
};

const NOW: i64 = 1_800_000_000_000;
const MINUTE: i64 = 60_000;
const DAY: i64 = 86_400_000;

fn doc(kind: Kind, source: &str, text: &str, at_ms: i64) -> Doc {
    Doc {
        kind,
        source: source.to_owned(),
        target: source.to_owned(),
        position: Some(0),
        title: source.to_owned(),
        text: text.to_owned(),
        at_ms,
        key: None,
    }
}

fn name(kind: Kind, key: &str, title: &str, at_ms: i64) -> NameDoc {
    NameDoc {
        key: key.to_owned(),
        kind,
        target: key.to_owned(),
        title: title.to_owned(),
        subtitle: String::new(),
        at_ms,
    }
}

fn engine() -> SearchEngine {
    SearchEngine::new(EngineConfig::default())
}

fn search(engine: &SearchEngine, text: &str) -> Vec<cmux_search::Hit> {
    engine.search(&Query::new(text, NOW)).hits
}

#[test]
fn cmux_search_search_finds_text_ignoring_case_and_accents_and_marks_it() {
    let mut engine = engine();
    engine.append(doc(Kind::Chat, "acp:1", "Le Résumé crashed with SIGSEGV", NOW - MINUTE));
    let hits = search(&engine, "resume");
    assert_eq!(hits.len(), 1);
    let hit = &hits[0];
    assert_eq!(hit.kind, Kind::Chat);
    assert_eq!(hit.snippet, "Le Résumé crashed with SIGSEGV");
    assert_eq!(hit.highlights, vec![3.."Le Résumé".len()]);
    assert_eq!(search(&engine, "sigsegv").len(), 1);
    assert!(search(&engine, "segfault").is_empty());
}

#[test]
fn cmux_search_search_needs_every_word_in_one_doc() {
    let mut engine = engine();
    engine.append(doc(Kind::Scrollback, "term:1", "cargo build finished", NOW - MINUTE));
    engine.append(doc(Kind::Scrollback, "term:2", "cargo test passed", NOW - MINUTE));
    let hits = search(&engine, "cargo test");
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].target, "term:2");
}

#[test]
fn cmux_search_search_returns_the_newest_of_equal_matches_up_to_the_limit() {
    let mut engine = engine();
    for index in 0..100 {
        engine.append(doc(
            Kind::Scrollback,
            "term:1",
            &format!("build error {index}"),
            NOW - DAY + index * MINUTE,
        ));
    }
    let mut query = Query::new("error", NOW);
    query.limit = 10;
    let hits = engine.search(&query).hits;
    assert_eq!(hits.len(), 10);
    let expected: Vec<String> =
        (90..100).rev().map(|index| format!("build error {index}")).collect();
    let got: Vec<String> = hits.into_iter().map(|hit| hit.snippet).collect();
    assert_eq!(got, expected);
}

#[test]
fn cmux_search_kinds_and_scopes_filter_hits() {
    let mut engine = engine();
    engine.append(doc(Kind::Chat, "acp:1", "deploy staging now", NOW - MINUTE));
    engine.append(doc(Kind::Scrollback, "term:1", "deploy staging now", NOW - MINUTE));
    engine.append(doc(Kind::Chief, "chief:main", "deploy staging now", NOW - MINUTE));
    let mut query = Query::new("deploy staging", NOW);
    query.kinds = Scope::kinds_of(&Scope::AGENTS);
    let kinds: BTreeSet<&str> =
        engine.search(&query).hits.iter().map(|hit| hit.kind.as_str()).collect();
    assert_eq!(kinds, BTreeSet::from(["chat", "chief"]));
    query.kinds = Scope::kinds_of(&[Scope::Terminal]);
    let hits = engine.search(&query).hits;
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].kind, Kind::Scrollback);
}

#[test]
fn cmux_search_a_scrollback_hit_names_its_line_and_shows_only_that_line() {
    let mut engine = engine();
    let mut scrollback =
        doc(Kind::Scrollback, "term:7", "$ make\nok\nneedle in the haystack\nbye", NOW);
    scrollback.position = Some(100);
    engine.append(scrollback);
    let hits = search(&engine, "needle");
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].position, Some(100));
    assert_eq!(hits[0].line, 2);
    assert_eq!(hits[0].snippet, "needle in the haystack");
    assert_eq!(hits[0].highlights, vec![0..6]);
}

#[test]
fn cmux_search_removing_a_source_drops_its_hits_but_keeps_later_ones() {
    let mut engine = engine();
    engine.append(doc(Kind::Chat, "acp:9", "secret plan alpha", NOW - 2 * MINUTE));
    engine.append(doc(Kind::Chat, "acp:10", "secret plan beta", NOW - MINUTE));
    engine.remove_source("acp:9");
    let hits = search(&engine, "secret plan");
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].target, "acp:10");
    engine.append(doc(Kind::Chat, "acp:9", "secret plan gamma", NOW));
    assert_eq!(search(&engine, "secret plan").len(), 2);
}

#[test]
fn cmux_search_a_keyed_doc_replaces_the_earlier_one() {
    let mut engine = engine();
    let mut memory = doc(Kind::Chief, "chief:main", "user prefers alpha builds", NOW - DAY);
    memory.key = Some("memory:42".into());
    engine.append(memory.clone());
    memory.text = "user prefers beta builds".into();
    engine.append(memory);
    assert!(search(&engine, "alpha builds").is_empty());
    assert_eq!(search(&engine, "beta builds").len(), 1);
    engine.remove_key("memory:42");
    assert!(search(&engine, "beta builds").is_empty());
}

#[test]
fn cmux_search_search_spans_sealed_and_live_segments() {
    let config = EngineConfig { block_bytes: 256, segment_bytes: 4096, max_doc_bytes: 1 << 20 };
    let mut engine = SearchEngine::new(config);
    for index in 0..500 {
        engine.append(doc(
            Kind::Scrollback,
            "term:1",
            &format!("line {index} token{index:04}x"),
            NOW - 1000 + index,
        ));
    }
    let stats = engine.stats();
    assert!(stats.segments >= 3, "{stats:?}");
    assert_eq!(stats.docs, 500);
    assert_eq!(search(&engine, "token0003x").len(), 1);
    assert_eq!(search(&engine, "token0499x").len(), 1);
    let mut query = Query::new("line", NOW);
    query.limit = 1000;
    assert_eq!(engine.search(&query).hits.len(), 500);
}

#[test]
fn cmux_search_the_index_survives_save_and_load() {
    let dir = tempfile::tempdir().unwrap();
    let config = EngineConfig { block_bytes: 128, segment_bytes: 1024, max_doc_bytes: 1 << 20 };
    let mut engine = SearchEngine::new(config);
    for index in 0..200 {
        engine.append(doc(
            Kind::Chat,
            &format!("acp:{}", index % 5),
            &format!("message {index} about kiwi{index}"),
            NOW - 5000 + index,
        ));
    }
    let mut memory = doc(Kind::Chief, "chief:main", "remember the zebra", NOW);
    memory.key = Some("memory:1".into());
    engine.append(memory);
    engine.remove_source("acp:3");
    engine.upsert_name(name(Kind::Workspace, "ws_1", "cmux-next app", NOW));
    engine.record_open("acp:1", NOW);
    let before = search(&engine, "kiwi1");
    engine.save(dir.path()).unwrap();

    let mut loaded = SearchEngine::load(dir.path(), config).unwrap();
    assert_eq!(search(&loaded, "kiwi1"), before);
    assert_eq!(search(&loaded, "zebra").len(), 1);
    assert!(search(&loaded, "kiwi3 ").iter().all(|hit| hit.target != "acp:3"));
    assert_eq!(search(&loaded, "cmux-next")[0].target, "ws_1");
    loaded.remove_key("memory:1");
    assert!(search(&loaded, "zebra").is_empty());
}

#[test]
fn cmux_search_names_match_fuzzy_with_word_starts_and_basenames() {
    let mut engine = engine();
    engine.upsert_name(name(Kind::File, "f1", "Sources/App/ContentView.swift", NOW - DAY));
    engine.upsert_name(name(Kind::File, "f2", "Sources/Content/Overview/Archive.swift", NOW - DAY));
    engine.upsert_name(name(Kind::File, "f3", "docs/notes.md", NOW - DAY));
    engine.upsert_name(name(Kind::Workspace, "ws_perf", "Performance", NOW - DAY));
    engine.upsert_name(name(Kind::Workspace, "ws_app", "cmux-next app", NOW - DAY));
    assert_eq!(search(&engine, "contview")[0].target, "f1");
    assert_eq!(search(&engine, "cv")[0].target, "f1");
    assert_eq!(search(&engine, "perf")[0].target, "ws_perf");
    assert_eq!(search(&engine, "notes")[0].target, "f3");
    let hit = &search(&engine, "next")[0];
    assert_eq!(hit.target, "ws_app");
    assert_eq!(hit.highlights, vec![5..9]);
    engine.remove_name("ws_app");
    assert!(search(&engine, "next").is_empty());
}

#[test]
fn cmux_search_one_list_ranks_a_fresh_terminal_error_above_an_older_file_name() {
    let mut engine = engine();
    engine.upsert_name(name(
        Kind::File,
        "plans/db-migrations-DESIGN.md",
        "plans/db-migrations-DESIGN.md",
        NOW - DAY,
    ));
    engine.append(doc(
        Kind::Scrollback,
        "term:1",
        "error: migration 0042 failed",
        NOW - 2 * MINUTE,
    ));
    let hits = search(&engine, "migrat");
    assert_eq!(hits.len(), 2);
    assert_eq!(hits[0].target, "term:1");
    assert!(!hits[0].is_name);
    assert!(hits[1].is_name);
}

#[test]
fn cmux_search_a_better_match_beats_a_newer_one_and_opens_break_ties() {
    let mut engine = engine();
    engine.append(doc(Kind::Scrollback, "term:old", "ran cargo test twice", NOW - 3 * DAY));
    engine.append(doc(Kind::Scrollback, "term:new", "test the cargo cache", NOW - MINUTE));
    let hits = search(&engine, "cargo test");
    assert_eq!(hits[0].target, "term:old");
    assert!(hits[0].tier > hits[1].tier);

    let mut engine = SearchEngine::new(EngineConfig::default());
    engine.append(doc(Kind::Chat, "acp:a", "rollout plan", NOW - MINUTE));
    engine.append(doc(Kind::Chat, "acp:b", "rollout plan", NOW - MINUTE));
    engine.record_open("acp:a", NOW - MINUTE);
    engine.record_open("acp:a", NOW - MINUTE);
    assert_eq!(search(&engine, "rollout")[0].target, "acp:a");
}

#[test]
fn cmux_search_short_queries_search_names_only_and_quotes_keep_a_phrase() {
    let mut engine = engine();
    engine.append(doc(Kind::Scrollback, "term:1", "go go gadget", NOW));
    engine.append(doc(Kind::Scrollback, "term:2", "gadget go", NOW));
    engine.upsert_name(name(Kind::Tab, "tab_go", "go server", NOW));
    let hits = search(&engine, "go");
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].target, "tab_go");
    let hits = search(&engine, "\"go gadget\"");
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].target, "term:1");
    assert!(search(&engine, "   ").is_empty());
}

#[test]
fn cmux_search_screen_frames_index_a_new_screen_once() {
    let mut frames = ScreenFrames::new();
    let screen = "htop\ncpu 10%\nmem 2G\nproc a\nproc b\n";
    assert!(frames.offer("term:1", screen));
    assert!(!frames.offer("term:1", screen));
    assert!(!frames.offer("term:1", "htop\ncpu 11%\nmem 2G\nproc a\nproc b\n"));
    assert!(frames.offer("term:1", "vim\nfn main() {\n  run();\n}\n~\n"));
    assert!(frames.offer("term:2", screen));
    assert!(!frames.offer("term:3", "\n\n   \n"));
    frames.forget("term:1");
    assert!(frames.offer("term:1", screen));
}

/// The engine finds exactly the docs a plain substring scan finds.
#[test]
fn cmux_search_search_matches_a_plain_scan_over_a_synthetic_corpus() {
    let config =
        EngineConfig { block_bytes: 4096, segment_bytes: 256 * 1024, max_doc_bytes: 1 << 20 };
    let mut engine = SearchEngine::new(config);
    let docs: Vec<Doc> = SyntheticCorpus::with_bytes(7, 2 << 20).collect();
    for doc in &docs {
        engine.append(doc.clone());
    }
    let queries = [
        "mismatched types",
        "request id=",
        "FAILED",
        "scrollback",
        "deploy staging",
        "zzqx",
        "token reply",
    ];
    for text in queries {
        let words: Vec<String> = text.split_whitespace().map(str::to_lowercase).collect();
        let expected: BTreeSet<(String, i64)> = docs
            .iter()
            .filter(|doc| {
                let lower = doc.text.to_lowercase();
                words.iter().all(|word| lower.contains(word.as_str()))
            })
            .map(|doc| (doc.target.clone(), doc.at_ms))
            .collect();
        let mut query = Query::new(text, NOW);
        query.limit = 1_000_000;
        let got: BTreeSet<(String, i64)> = engine
            .search(&query)
            .hits
            .into_iter()
            .filter(|hit| !hit.is_name)
            .map(|hit| (hit.target, hit.at_ms))
            .collect();
        assert_eq!(got, expected, "query {text:?}");
    }
}
