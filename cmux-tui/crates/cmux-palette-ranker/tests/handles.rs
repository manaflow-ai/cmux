//! A row's handles: the short ids a person types to find it (a Chief subagent's `a612`).
//!
//! Lawrence 2026-10-23 (msg 11943): Cmd-P for "a612" listed a212, a162 and a compare URL by
//! scattered letters and never the a612 workspace; "612" listed chat rows whose session ids hold
//! the digits. A query that is a row's handle, or the handle's digits, ranks that row first.

use cmux_palette_ranker::{RankRequest, RankedSection, rank_request};
use serde_json::{Value, json};

fn rank(entries: &Value, query: &str) -> Vec<usize> {
    let request: RankRequest = serde_json::from_value(json!({
        "operation": "rank",
        "entries": entries,
        "query": query,
        "now": 1_000_000.0,
    }))
    .expect("request");
    rank_request(&request)
        .into_iter()
        .flat_map(|section: RankedSection| section.rows.into_iter().map(|row| row.index))
        .collect()
}

fn entries() -> Value {
    json!([
        {"title": "a212 · Chief agents", "keywords": ["workspace", "Chief agents"], "handles": ["a212"]},
        {"title": "a162 · Cmd-T tabs self-close", "keywords": ["workspace"], "handles": ["a162"]},
        {"title": "a112 · cmux WireGuard mesh", "keywords": ["workspace"], "handles": ["a112"]},
        {"title": "github.com/manaflow-ai/cmux/compare/a612b0c...a612d00", "keywords": ["workspace"]},
        {"title": "about:blank", "keywords": ["tab", "acp:01a16c0a-6120-7f80-8aee-aeac17612612"], "rankBias": 40},
        {"title": "Markdown pane omnibar back", "subtitle": "cmux-next app", "keywords": ["workspace"], "handles": ["a612"]},
    ])
}

#[test]
fn the_handle_ranks_its_row_first() {
    for query in ["a612", "A612", " a612 ", "612"] {
        let order = rank(&entries(), query);
        assert_eq!(order.first(), Some(&5), "{query:?}: {order:?}");
    }
}

#[test]
fn another_handle_matches_only_its_own_row_first() {
    assert_eq!(rank(&entries(), "a212").first(), Some(&0));
    assert_eq!(rank(&entries(), "162").first(), Some(&1));
}

#[test]
fn a_part_of_a_handle_is_no_handle_match() {
    // "61" and "a61" start a612 but name no subagent: ordinary matching decides, and the row
    // that only has the handle is not lifted for it.
    for query in ["61", "a61", "6"] {
        let order = rank(&entries(), query);
        assert_ne!(order.first(), Some(&5), "{query:?}: {order:?}");
    }
}

#[test]
fn rows_without_handles_rank_as_before() {
    let plain = json!([{"title": "Mark all read"}, {"title": "Markdown pane omnibar back"}]);
    assert_eq!(rank(&plain, "omnibar"), vec![1]);
    assert_eq!(rank(&plain, "612"), Vec::<usize>::new());
}
