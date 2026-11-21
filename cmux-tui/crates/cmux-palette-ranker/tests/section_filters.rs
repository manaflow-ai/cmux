//! Search filters: `in:tabs`, `-in:history`, `kind:settings` keep or drop whole sections.
//!
//! Leo (2026-11-18): "do we have any kind of filtering mechanism for the searching? Presumably,
//! some people don't necessarily want to be ... looking through the entirety of the universe".

use cmux_palette_ranker::{RankRequest, RankedSection, Ranker, rank_request};
use serde_json::{Value, json};

fn names() -> Value {
    json!([
        ["Workspaces", "workspaces"],
        ["Tabs", "navigation"],
        ["History", "search.history"],
        ["Settings", "settings"]
    ])
}

fn entries() -> Value {
    json!([
        {"title": "deploy dashboard", "sectionIndex": 0, "frecencyKey": "w1"},
        {"title": "deploy logs", "sectionIndex": 1, "frecencyKey": "t1", "isVisibleWhenQueryEmpty": false},
        {"title": "staging deploy", "sectionIndex": 1, "frecencyKey": "t2", "isVisibleWhenQueryEmpty": false},
        {"title": "deploy runbook", "sectionIndex": 2, "isVisibleWhenQueryEmpty": false},
        {"title": "Deploy on save", "sectionIndex": 3, "isVisibleWhenQueryEmpty": false},
    ])
}

fn request(query: &str, with_names: bool) -> RankRequest {
    let mut value = json!({
        "operation": "rank",
        "entries": entries(),
        "query": query,
        "sectionOrders": [0, 1, 2, 3],
        "now": 1_000_000.0,
        "frecency": {"entries": {"t2": {"score": 5.0, "lastUsed": 999_000.0}}},
    });
    if with_names {
        value["sectionNames"] = names();
    }
    serde_json::from_value(value).expect("request")
}

fn rows(sections: Vec<RankedSection>) -> Vec<usize> {
    sections.into_iter().flat_map(|section| section.rows.into_iter().map(|row| row.index)).collect()
}

fn sorted(mut indexes: Vec<usize>) -> Vec<usize> {
    indexes.sort_unstable();
    indexes
}

#[test]
fn in_keeps_only_the_named_kind() {
    assert_eq!(sorted(rows(rank_request(&request("in:tabs deploy", true)))), vec![1, 2]);
    assert_eq!(sorted(rows(rank_request(&request("deploy kind:settings", true)))), vec![4]);
}

#[test]
fn a_minus_drops_a_kind() {
    assert_eq!(
        sorted(rows(rank_request(&request("-in:history,settings deploy", true)))),
        vec![0, 1, 2]
    );
}

#[test]
fn a_filter_alone_lists_its_kind_most_used_first() {
    // The tabs hide on the empty query, but `in:tabs` names them: every tab, t2 (used) first.
    assert_eq!(rows(rank_request(&request("in:tabs", true))), vec![2, 1]);
}

#[test]
fn without_section_names_the_query_is_plain_text() {
    // A page that sends no names (every page but Search Everything) ranks as before.
    let plain = rank_request(&request("in:tabs deploy", false));
    let mut unfiltered = request("in:tabs deploy", true);
    unfiltered.section_names = Some(Vec::new());
    assert_eq!(plain, rank_request(&unfiltered));
    let all = sorted(rows(rank_request(&request("deploy", true))));
    assert_eq!(all, vec![0, 1, 2, 3, 4]);
}

#[test]
fn a_name_of_no_section_stays_text() {
    // "in:nowhere" names nothing, so it is part of the words and nothing matches it.
    assert!(rows(rank_request(&request("in:nowhere deploy", true))).is_empty());
}

#[test]
fn the_installed_ranker_filters_the_same_way() {
    let mut ranker = Ranker::new();
    ranker.install(7, serde_json::from_value(entries()).expect("entries"));
    for query in ["in:tabs deploy", "in:tabs deploy l", "in:tabs dep", "-in:tabs deploy"] {
        let mut installed = request(query, true);
        installed.entries = None;
        installed.version = Some(7);
        let answer = sorted(rows(ranker.rank(&installed).expect("installed")));
        assert_eq!(answer, sorted(rows(rank_request(&request(query, true)))), "{query}");
    }
}

#[test]
fn the_c_abi_answers_the_filter_operation() {
    use cmux_palette_ranker::ffi::{
        OK, cmux_palette_ranker_free, cmux_palette_ranker_new, cmux_palette_ranker_rank,
    };
    let request = serde_json::to_vec(&json!({
        "operation": "filter",
        "query": "-in:history deploy in:tab",
        "sectionNames": names(),
    }))
    .expect("request");
    let ranker = cmux_palette_ranker_new();
    let mut response: *const u8 = std::ptr::null();
    let mut response_len = 0usize;
    // SAFETY: a live handle, a readable request and writable out pointers.
    let code = unsafe {
        cmux_palette_ranker_rank(
            ranker,
            request.as_ptr(),
            request.len(),
            &mut response,
            &mut response_len,
        )
    };
    // SAFETY: on OK the response holds `response_len` bytes until the next call on the handle.
    let body: Value =
        serde_json::from_slice(unsafe { std::slice::from_raw_parts(response, response_len) })
            .expect("filter JSON");
    // SAFETY: the handle from cmux_palette_ranker_new, freed once.
    unsafe { cmux_palette_ranker_free(ranker) };
    assert_eq!(code, OK);
    assert_eq!(body, json!({"rest": "deploy", "include": [1], "exclude": [2], "applied": true}));
}
