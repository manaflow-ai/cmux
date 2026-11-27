//! Mirrors the Swift tests of the session tree's chat history state (SidebarChatHistoryTests'
//! State section and its Loading row) on the rules alone.

use super::*;

/// `count` chats, newest first (`c0` newest).
fn chats(count: usize) -> Vec<Chat> {
    (0..count)
        .map(|i| Chat {
            id: format!("c{i}"),
            title: format!("chat {i}"),
            updated_at: 1_000_000.0 - i as f64 * 60.0,
            harness: Some(if i % 2 == 0 { "codex" } else { "claude-code" }.into()),
        })
        .collect()
}

fn set(ids: &[&str]) -> BTreeSet<String> {
    ids.iter().map(|id| id.to_string()).collect()
}

/// The history of `index` as acpmux's Earlier window answers it (`more`: more chats than the page
/// pass the window's exclusions).
fn history(index: &[Chat], live: &[&str], pinned: &[&str], limit: i64, folded: bool) -> History {
    let known: BTreeMap<String, Chat> =
        index.iter().map(|chat| (chat.id.clone(), chat.clone())).collect();
    let pinned: Vec<String> = pinned.iter().map(|id| id.to_string()).collect();
    let live = set(live);
    let passing = index.iter().filter(|c| !live.contains(&c.id) && !pinned.contains(&c.id)).count();
    make(index, &known, &live, &pinned, limit, folded, passing as i64 > limit, false)
}

fn ids(list: &[Chat]) -> Vec<&str> {
    list.iter().map(|chat| chat.id.as_str()).collect()
}

const M: Metrics = Metrics { section_header_height: 28.0, row_height: 30.0, row_spacing: 2.0 };

#[test]
fn earlier_lists_one_page_of_the_chats_no_workspace_shows_and_pins_in_pin_order() {
    let state = history(&chats(10), &["c0", "c2"], &["c5", "c1", "gone"], 3, false);
    assert_eq!(ids(&state.pinned), ["c5", "c1"], "a pinned chat the index lost is not shown");
    assert_eq!(ids(&state.earlier), ["c3", "c4", "c6"]);
    assert!(state.has_earlier && state.has_more);
}

#[test]
fn the_last_page_has_no_show_more_and_an_empty_index_no_earlier() {
    let last = history(&chats(4), &["c0"], &[], 3, false);
    assert_eq!(ids(&last.earlier), ["c1", "c2", "c3"]);
    assert!(!last.has_more);
    let none = history(&[], &[], &["c1"], 3, false);
    assert!(!none.has_earlier && none.pinned.is_empty());
    assert!(!history(&chats(2), &["c0", "c1"], &[], 3, false).has_earlier);
}

#[test]
fn folded_earlier_keeps_its_header_but_lists_no_rows() {
    let state = history(&chats(10), &[], &[], 3, true);
    assert!(state.has_earlier && state.earlier.is_empty() && !state.has_more);
    assert_eq!(state.earlier_height(&M), M.section_header_height);
}

#[test]
fn heights_are_a_header_and_one_row_per_chat_plus_show_more() {
    let row = M.row_height + M.row_spacing;
    let state = history(&chats(10), &[], &["c9"], 3, false);
    assert_eq!(state.pinned_height(&M), M.section_header_height + row);
    assert_eq!(state.earlier_height(&M), M.section_header_height + 4.0 * row);
    assert_eq!(History::default().pinned_height(&M), 0.0);
    assert_eq!(History::default().earlier_height(&M), 0.0);
}

#[test]
fn earlier_says_loading_until_acpmux_first_sends_its_rows() {
    let none = BTreeMap::new();
    let waiting = make(&[], &none, &BTreeSet::new(), &[], 20, false, false, true);
    assert!(waiting.has_earlier && waiting.shows_loading(), "a starting index is no empty history");
    assert_eq!(waiting.earlier_height(&M), M.section_header_height + M.row_height + M.row_spacing);
    let empty = make(&[], &none, &BTreeSet::new(), &[], 20, false, false, false);
    assert!(!empty.has_earlier && !empty.shows_loading());
    assert!(!history(&chats(2), &[], &[], 3, true).shows_loading());
    let folded = make(&[], &none, &BTreeSet::new(), &[], 20, true, false, true);
    assert!(!folded.shows_loading(), "folded Earlier keeps only its header");
}

#[test]
fn a_negative_or_zero_limit_lists_no_rows_but_keeps_the_header() {
    let state = history(&chats(3), &[], &[], -1, false);
    assert!(state.earlier.is_empty() && state.has_earlier);
}
