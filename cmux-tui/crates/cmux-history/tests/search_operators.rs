//! `history-search` reads the search operators (`is:`, `since:`, `before:`,
//! `-word`, `"phrase"`) the History page does.

use cmux_history::{SearchDoc, SearchIndex, SearchKind};

const HOUR_MS: i64 = 3_600_000;
const DAY_MS: i64 = 86_400_000;
const NOW: i64 = 1_800_000_000_000;
const DAY_START: i64 = 1_799_971_200_000;

fn doc(key: &str, kind: SearchKind, text: &str, at_ms: i64) -> SearchDoc {
    SearchDoc {
        key: key.to_owned(),
        source: "test".to_owned(),
        kind,
        target: key.to_owned(),
        position: None,
        title: format!("{key} title"),
        text: text.to_owned(),
        at_ms,
    }
}

fn index() -> SearchIndex {
    let mut index = SearchIndex::open_in_memory().expect("index");
    let docs = [
        doc("old-chat", SearchKind::Chat, "deploy the staging api", NOW - 30 * DAY_MS),
        doc("chat", SearchKind::Chat, "deploy the prod api", NOW - 2 * HOUR_MS),
        doc("command", SearchKind::Command, "cargo deploy --prod qa Straße", NOW - 2 * DAY_MS),
        doc("tab", SearchKind::Tab, "", NOW - DAY_MS),
    ];
    index.append("test", &docs, Some(1)).expect("append");
    index
}

fn keys(index: &SearchIndex, query: &str) -> Vec<String> {
    index
        .search_at(query, &[], 20, NOW, DAY_START)
        .expect("search")
        .into_iter()
        .map(|hit| hit.key)
        .collect()
}

#[test]
fn words_alone_search_as_before() {
    assert_eq!(keys(&index(), "deploy"), ["command", "chat", "old-chat"]);
}

#[test]
fn kind_and_time_operators_narrow_the_text_match() {
    let index = index();
    assert_eq!(keys(&index, "deploy is:chat"), ["chat", "old-chat"]);
    assert_eq!(keys(&index, "deploy since:7d"), ["command", "chat"]);
    assert_eq!(keys(&index, "deploy is:chats since:today"), ["chat"]);
    assert_eq!(keys(&index, "deploy before:7d"), ["old-chat"]);
    // The request's own kinds and `is:` must both pass.
    let hits = index
        .search_at("deploy is:chat", &[SearchKind::Command], 20, NOW, DAY_START)
        .expect("search");
    assert!(hits.is_empty());
}

#[test]
fn exclusions_and_phrases() {
    let index = index();
    assert_eq!(keys(&index, "deploy -staging"), ["command", "chat"]);
    assert_eq!(keys(&index, "\"the prod\""), ["chat"]);
    // A word too short for the trigram index is still left out, from the
    // text and from the title.
    assert_eq!(keys(&index, "deploy -qa"), ["chat", "old-chat"]);
    assert_eq!(keys(&index, "deploy -ld"), ["command", "chat"]);
    // Exclusions alone test the text too, not only names.
    assert_eq!(keys(&index, "-staging"), ["tab", "command", "chat"]);
}

#[test]
fn words_reach_the_index_as_typed() {
    // The trigram index folds case and diacritics only, so `ß` must not be
    // sent as `ss`.
    assert_eq!(keys(&index(), "Straße"), ["command"]);
}

#[test]
fn operators_alone_list_the_newest_docs_they_pass() {
    let index = index();
    assert_eq!(keys(&index, "since:3d"), ["tab", "command", "chat"]);
    assert_eq!(keys(&index, "is:command"), ["command"]);
    assert!(keys(&index, "   ").is_empty());
}
