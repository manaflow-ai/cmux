//! Pins each model op to the answer `PaletteModel` (CmuxNextPalette) gave in Swift.

use super::*;
use serde_json::json;

fn ask(request: Value) -> Value {
    call_value(&request).expect("model op answers")
}

fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|word| (*word).to_owned()).collect()
}

#[test]
fn highlights_mark_every_case_insensitive_occurrence() {
    assert_eq!(word_highlights("New Tab", &words(&["tab"])), vec![4, 5, 6]);
    assert_eq!(word_highlights("Tab tab", &words(&["TAB"])), vec![0, 1, 2, 4, 5, 6]);
    // Two words mark their union, sorted.
    assert_eq!(
        word_highlights("Close Other Tabs", &words(&["tab", "clo"])),
        vec![0, 1, 2, 12, 13, 14]
    );
}

#[test]
fn highlights_step_past_a_match() {
    // "aa" in "aaa": one match at 0, then the scan resumes at 2 (no overlap at 1).
    assert_eq!(word_highlights("aaa", &words(&["aa"])), vec![0, 1]);
    assert_eq!(word_highlights("aaaa", &words(&["aa"])), vec![0, 1, 2, 3]);
}

#[test]
fn highlights_skip_empty_and_long_words() {
    assert!(word_highlights("Tab", &words(&[""])).is_empty());
    assert!(word_highlights("Tab", &words(&["tabs"])).is_empty());
    assert!(word_highlights("Tab", &[]).is_empty());
    assert!(word_highlights("", &words(&["a"])).is_empty());
}

#[test]
fn highlights_are_empty_when_lowercasing_changes_the_length() {
    // "İ" lowercases to two scalars; offsets would point past the title.
    assert!(word_highlights("İstanbul", &words(&["stan"])).is_empty());
    // Scalars, not bytes or UTF-16 units.
    assert_eq!(word_highlights("café bar", &words(&["bar"])), vec![5, 6, 7]);
}

#[test]
fn query_sections_group_by_first_appearance_with_highlights() {
    let answer = ask(json!({
        "operation": "model.querySections",
        "sections": ["b", "a", "b"],
        "titles": ["Tab one", "Other", "Tab two"],
        "query": " tab ",
    }));
    assert_eq!(
        answer,
        json!([
            {"section": "b", "rows": [{"index": 0, "highlights": [0, 1, 2]}, {"index": 2, "highlights": [0, 1, 2]}]},
            {"section": "a", "rows": [{"index": 1, "highlights": []}]},
        ])
    );
    assert_eq!(ask(json!({"operation": "model.querySections", "sections": []})), json!([]));
}

#[test]
fn unranked_groups_visible_rows_by_section_order() {
    let answer = ask(json!({
        "operation": "model.unranked",
        "entries": [
            {"sectionIndex": 1},
            {"sectionIndex": 0},
            {"sectionIndex": 1, "visibleWhenQueryEmpty": false},
            {"sectionIndex": 1},
            {"sectionIndex": 7},
            {"sectionIndex": 0},
        ],
        "sectionOrders": [20, 10],
        "itemCount": 5,
    }));
    // Section 1 (order 10) before section 0 (order 20); hidden row 2, unknown section 7 and row 5
    // (past the items) drop.
    assert_eq!(
        answer,
        json!([{"sectionIndex": 1, "positions": [0, 3]}, {"sectionIndex": 0, "positions": [1]}])
    );
    // Equal orders keep index order.
    let tied = ask(json!({
        "operation": "model.unranked",
        "entries": [{"sectionIndex": 1}, {"sectionIndex": 0}],
        "sectionOrders": [5, 5],
        "itemCount": 2,
    }));
    assert_eq!(
        tied,
        json!([{"sectionIndex": 0, "positions": [1]}, {"sectionIndex": 1, "positions": [0]}])
    );
}

#[test]
fn resolve_rank_maps_ids_and_drops_gone_rows_and_empty_sections() {
    let answer = ask(json!({
        "operation": "model.resolveRank",
        "sections": [
            {"section": {"name": "Recent"}, "rows": [{"id": "c", "score": 9, "highlights": [1]}, {"id": "gone", "score": 8}]},
            {"section": {"name": "Old"}, "rows": [{"id": "gone2"}]},
            {"section": {"name": "Tabs"}, "rows": [{"id": "a", "score": 1}]},
        ],
        "ids": ["a", "b", "c"],
    }));
    assert_eq!(
        answer,
        json!([
            {"section": {"name": "Recent"}, "rows": [{"position": 2, "score": 9, "highlights": [1]}]},
            {"section": {"name": "Tabs"}, "rows": [{"position": 0, "score": 1, "highlights": []}]},
        ])
    );
}

#[test]
fn store_empty_rank_keeps_the_newest_four() {
    let order = ["a", "b", "c", "d"];
    assert_eq!(
        ask(json!({"operation": "model.storeEmptyRank", "order": order, "pageId": "e"})),
        json!({"order": ["b", "c", "d", "e"], "evicted": ["a"]})
    );
    // Storing a kept page moves it to newest, evicting nothing.
    assert_eq!(
        ask(json!({"operation": "model.storeEmptyRank", "order": order, "pageId": "b"})),
        json!({"order": ["a", "c", "d", "b"], "evicted": []})
    );
    assert_eq!(
        ask(
            json!({"operation": "model.storeEmptyRank", "order": ["a", "b"], "pageId": "c", "limit": 1})
        ),
        json!({"order": ["c"], "evicted": ["a", "b"]})
    );
}

fn placed(rows: &[(&str, &str)]) -> Vec<PlacedRow> {
    rows.iter()
        .map(|(id, section)| PlacedRow { id: (*id).to_owned(), section: (*section).to_owned() })
        .collect()
}

#[test]
fn selection_after_removing_stays_in_the_section() {
    let rows = placed(&[("a", "s1"), ("b", "s1"), ("c", "s1"), ("d", "s2")]);
    assert_eq!(selection_after_removing("b", &rows).as_deref(), Some("c"));
    // Last of its section: the previous one, never the next section.
    assert_eq!(selection_after_removing("c", &rows).as_deref(), Some("b"));
    // Alone in its section: none.
    assert_eq!(selection_after_removing("d", &rows), None);
    assert_eq!(selection_after_removing("zz", &rows), None);
    assert_eq!(
        ask(
            json!({"operation": "model.selectionAfterRemoving", "removed": "a", "rows": [{"id": "a", "section": "x"}, {"id": "b", "section": "x"}]})
        ),
        json!("b")
    );
}

#[test]
fn move_selection_clamps_or_wraps() {
    let mv = |count: i64, current: Option<i64>, delta: i64, wrap: bool| {
        ask(
            json!({"operation": "model.moveSelection", "count": count, "current": current, "delta": delta, "wrap": wrap}),
        )
    };
    assert_eq!(mv(0, None, 1, false), Value::Null);
    // Nothing selected: index -1, so Down lands on the first row.
    assert_eq!(mv(5, None, 1, false), json!(0));
    assert_eq!(mv(5, Some(-1), 1, false), json!(0));
    assert_eq!(mv(5, Some(4), 1, false), json!(4));
    assert_eq!(mv(5, Some(0), -1, false), json!(0));
    assert_eq!(mv(5, Some(4), 1, true), json!(0));
    assert_eq!(mv(5, Some(0), -1, true), json!(4));
    assert_eq!(mv(5, None, -1, true), json!(3));
    assert_eq!(mv(20, Some(3), PAGE_STEP, false), json!(11));
    assert_eq!(mv(5, Some(3), PAGE_STEP, false), json!(4));
}

#[test]
fn move_rail_clamps_without_wrap() {
    assert_eq!(move_rail(0, 0, 1), None);
    assert_eq!(move_rail(4, 0, 1), Some(1));
    assert_eq!(move_rail(4, 3, 1), Some(3));
    assert_eq!(move_rail(4, 0, -1), Some(0));
    assert_eq!(
        ask(json!({"operation": "model.moveRail", "count": 3, "index": 1, "delta": 5})),
        json!(2)
    );
}

#[test]
fn selectable_rows_follow_the_navigation_state() {
    let shown = words(&["a", "b", "c"]);
    assert_eq!(selectable_rows(&shown, None), vec![0, 1, 2]);
    assert_eq!(selectable_rows(&shown, Some(&words(&["c", "a", "b", "z"]))), vec![0, 1, 2]);
    // An older query's answer still shown: only the rows navigation holds.
    assert_eq!(selectable_rows(&shown, Some(&words(&["c"]))), vec![2]);
    assert_eq!(
        ask(json!({"operation": "model.selectableRows", "shown": ["a", "b"], "navigable": []})),
        json!([])
    );
}

fn menu(count: i64, selected: i64, filter: &str, key: &str, text: &str) -> Value {
    ask(json!({
        "operation": "model.actionsMenuKey",
        "count": count, "selectedIndex": selected, "filter": filter, "key": key, "text": text,
    }))
}

fn menu_answer(outcome: &str, selected: i64, filter: &str) -> Value {
    json!({"outcome": outcome, "selectedIndex": selected, "filter": filter})
}

#[test]
fn actions_menu_arrows_wrap_and_jumps_land_at_the_ends() {
    assert_eq!(menu(3, 2, "", "moveDown", ""), menu_answer("update", 0, ""));
    assert_eq!(menu(3, 0, "", "moveUp", ""), menu_answer("update", 2, ""));
    assert_eq!(menu(0, 0, "", "moveDown", ""), menu_answer("none", 0, ""));
    assert_eq!(menu(3, 2, "x", "moveToFirst", ""), menu_answer("update", 0, "x"));
    assert_eq!(menu(3, 1, "", "pageUp", ""), menu_answer("update", 0, ""));
    assert_eq!(menu(3, 0, "", "moveToLast", ""), menu_answer("update", 2, ""));
    assert_eq!(menu(3, 0, "", "pageDown", ""), menu_answer("update", 2, ""));
    assert_eq!(menu(0, 0, "", "moveToLast", ""), menu_answer("update", 0, ""));
}

#[test]
fn actions_menu_runs_closes_and_passes() {
    assert_eq!(menu(3, 1, "", "submit", ""), menu_answer("run", 1, ""));
    assert_eq!(menu(3, 1, "", "submitAlternate", ""), menu_answer("run", 1, ""));
    for key in ["toggleActions", "closeActions", "escape"] {
        assert_eq!(menu(3, 1, "", key, ""), menu_answer("close", 1, ""), "{key}");
    }
    for key in ["openActions", "enterRow", "leaveLevel"] {
        assert_eq!(menu(3, 1, "", key, ""), menu_answer("none", 1, ""), "{key}");
    }
    assert_eq!(menu(3, 1, "", "back", ""), menu_answer("pass", 1, ""));
    assert_eq!(menu(3, 1, "", "closeItem", ""), menu_answer("closeItem", 1, ""));
}

#[test]
fn actions_menu_filter_types_and_deletes() {
    assert_eq!(menu(3, 2, "co", "actionsFilterAppend", "p"), menu_answer("update", 0, "cop"));
    assert_eq!(
        menu(3, 2, "copé", "actionsFilterDeleteBackward", ""),
        menu_answer("update", 0, "cop")
    );
    // Backspace on an empty filter closes the menu.
    assert_eq!(menu(3, 2, "", "actionsFilterDeleteBackward", ""), menu_answer("close", 2, ""));
}

#[test]
fn prefix_hints_join_root_scopes_with_prefixes() {
    let answer = ask(json!({
        "operation": "model.prefixHints",
        "scopes": [
            {"id": "tabs", "prefix": "@", "title": "Tabs"},
            {"id": "files", "title": "Files"},
            {"id": "commands", "prefix": ">", "title": "Commands"},
            {"id": "scopes", "prefix": "?", "title": "Scopes"},
        ],
        "allScopesTitle": "All Scopes",
    }));
    assert_eq!(answer, json!("@ Tabs   > Commands   ? All Scopes"));
    assert_eq!(
        ask(
            json!({"operation": "model.prefixHints", "scopes": [{"id": "x", "title": "X"}], "allScopesTitle": "All"})
        ),
        Value::Null
    );
}

#[test]
fn query_selection_selects_the_initial_text_once_shown() {
    let pick = |request: Value| ask(request);
    assert_eq!(
        pick(
            json!({"operation": "model.querySelection", "textInput": true, "initial": "main", "query": "main"})
        ),
        json!({"selectsQuery": true, "selectedQueryLength": null})
    );
    assert_eq!(
        pick(
            json!({"operation": "model.querySelection", "textInput": true, "initial": "main", "query": "mai"})
        ),
        json!({"selectsQuery": false, "selectedQueryLength": null})
    );
    assert_eq!(
        pick(
            json!({"operation": "model.querySelection", "textInput": true, "initial": "", "query": ""})
        ),
        json!({"selectsQuery": false, "selectedQueryLength": null})
    );
    assert_eq!(
        pick(
            json!({"operation": "model.querySelection", "initial": "> ab", "query": "> ab", "initialQuerySelection": 2})
        ),
        json!({"selectsQuery": true, "selectedQueryLength": 2})
    );
    // A list page without a selection length selects nothing, even showing its initial query.
    assert_eq!(
        pick(json!({"operation": "model.querySelection", "initial": "> ab", "query": "> ab"})),
        json!({"selectsQuery": false, "selectedQueryLength": null})
    );
    assert_eq!(
        pick(
            json!({"operation": "model.querySelection", "initial": "> ab", "query": "> a", "initialQuerySelection": 2})
        ),
        json!({"selectsQuery": false, "selectedQueryLength": null})
    );
}

#[test]
fn an_unknown_op_is_an_error() {
    assert!(call_value(&json!({"operation": "model.nope"})).is_err());
    assert!(call_value(&json!({"operation": "model.moveRail"})).is_err());
}
