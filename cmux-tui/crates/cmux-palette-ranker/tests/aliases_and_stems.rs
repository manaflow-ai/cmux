//! A row's own aliases rank it like the user's `palette.aliases`, and a word matches its
//! inflections ("share" finds "Sharing").
//!
//! Cmd-Shift-P "share screen" listed Share Screen with Chief above Screen Sharing: the catalog's
//! phrases for Screen Sharing were only keywords, which reach the substring tier at best, while
//! the Chief row's title starts with the query.

use cmux_palette_ranker::{RankRequest, RankedSection, rank_request};
use serde_json::{Value, json};

fn rank_with(entries: &Value, query: &str, extra: Value) -> Vec<usize> {
    let mut request = json!({
        "operation": "rank",
        "entries": entries,
        "query": query,
        "now": 1_000_000.0,
    });
    if let (Some(request), Some(extra)) = (request.as_object_mut(), extra.as_object()) {
        request.extend(extra.clone());
    }
    let request: RankRequest = serde_json::from_value(request).expect("request");
    rank_request(&request)
        .into_iter()
        .flat_map(|section: RankedSection| section.rows.into_iter().map(|row| row.index))
        .collect()
}

fn rank(entries: &Value, query: &str) -> Vec<usize> {
    rank_with(entries, query, json!({}))
}

fn screen_rows() -> Value {
    json!([
        {"title": "Share Screen with Chief", "actionID": "chief.screenShare.start",
         "keywords": ["chief", "screen", "share", "sharing"]},
        {"title": "Stop Viewing Shared Screen", "actionID": "macScreen.stopViewing",
         "keywords": ["screen share", "vnc"]},
        {"title": "Screen Sharing", "actionID": "macScreen.open", "rankBias": 120,
         "keywords": ["screen share", "share screen", "vnc"],
         "aliases": ["screen share", "share screen", "Remote  Desktop", "vnc"]},
        {"title": "Open Desktop", "actionID": "cloudOpenDesktop", "keywords": ["remote", "vnc"]},
    ])
}

#[test]
fn a_rows_own_alias_ranks_it_first() {
    for query in ["share screen", "screen share", "vnc", "remote desktop", " Remote Desktop "] {
        let order = rank(&screen_rows(), query);
        assert_eq!(order.first(), Some(&2), "{query:?}: {order:?}");
    }
}

#[test]
fn an_own_alias_names_a_row_whose_text_does_not_match() {
    let rows = json!([
        {"title": "Alpha"},
        {"title": "Beta", "aliases": ["gamma ray"]},
    ]);
    assert_eq!(rank(&rows, "gamma ray"), vec![1]);
    // A part of an alias is no alias match.
    assert_eq!(rank(&rows, "gamma"), Vec::<usize>::new());
}

#[test]
fn an_own_alias_ranks_like_the_users_alias() {
    let rows = json!([
        {"title": "Theme Browser", "actionID": "browserTheme"},
        {"title": "Set Terminal Theme", "actionID": "terminal.setTheme", "aliases": ["skin"]},
        {"title": "Skin Care", "actionID": "skin"},
    ]);
    let own = rank(&rows, "skin");
    let user = rank_with(
        &json!([
            {"title": "Theme Browser", "actionID": "browserTheme"},
            {"title": "Set Terminal Theme", "actionID": "terminal.setTheme"},
            {"title": "Skin Care", "actionID": "skin"},
        ]),
        "skin",
        json!({"aliases": {"terminal.setTheme": ["skin"]}}),
    );
    assert_eq!(own, vec![1, 2]);
    assert_eq!(own, user);
}

#[test]
fn a_hidden_row_stays_hidden_for_its_own_alias() {
    let rows = json!([
        {"title": "Alpha", "frecencyKey": "action:alpha", "aliases": ["zulu"]},
        {"title": "Zulu Time"},
    ]);
    let order = rank_with(&rows, "zulu", json!({"frecency": {"hidden": ["action:alpha"]}}));
    assert_eq!(order, vec![1]);
}

#[test]
fn a_disabled_row_is_not_lifted_by_its_own_alias() {
    let rows = json!([
        {"title": "Alpha", "aliases": ["zulu"], "isEnabled": false},
        {"title": "Zulu Time"},
    ]);
    assert_eq!(rank(&rows, "zulu"), vec![1]);
}

#[test]
fn a_word_finds_its_inflections() {
    let rows = json!([
        {"title": "Open Settings"},
        {"title": "Screen Sharing"},
        {"title": "Splitting Panes"},
        {"title": "Closed Tabs"},
    ]);
    assert_eq!(rank(&rows, "screen share").first(), Some(&1));
    assert_eq!(rank(&rows, "share").first(), Some(&1));
    assert_eq!(rank(&rows, "shared screens").first(), Some(&1));
    assert_eq!(rank(&rows, "closes tab").first(), Some(&3));
    assert_eq!(rank(&rows, "closing tabs").first(), Some(&3));
    assert_eq!(rank(&rows, "setting").first(), Some(&0));
}

#[test]
fn a_stem_match_ranks_below_the_typed_words() {
    let rows = json!([
        {"title": "Screen Sharing", "rankBias": 120},
        {"title": "Share Screen with Chief"},
        {"title": "Shared Screen Viewer"},
    ]);
    // Typed words that start title words beat a stem match, bias or not.
    let order = rank(&rows, "share screen");
    assert_eq!(order.first(), Some(&1), "{order:?}");
    assert!(order.contains(&0), "{order:?}");
}

#[test]
fn short_or_unrelated_words_are_no_stem_match() {
    let rows = json!([{"title": "Sharing"}, {"title": "Use Tabs"}, {"title": "Set Color"}]);
    let strict = |query: &str| rank_with(&rows, query, json!({"typoPass": false}));
    // Under three letters there is no stem to share.
    assert_eq!(strict("sh x"), Vec::<usize>::new());
    // "shark" is not "share".
    assert_eq!(strict("shark"), Vec::<usize>::new());
    // "using" is not "use": a stem keeps three letters before its suffix.
    assert_eq!(strict("using tabs"), Vec::<usize>::new());
    // "settings" (and the typed start "sett") is not "Set": no doubled letters.
    assert_eq!(strict("settings"), Vec::<usize>::new());
    assert_eq!(strict("sett"), Vec::<usize>::new());
}
