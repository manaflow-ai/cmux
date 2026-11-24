use super::*;
use serde_json::json;

fn reply(nav: Value) -> Reply {
    respond(&Request { nav })
}

#[test]
fn absent_or_empty_draws_no_block() {
    assert_eq!(reply(Value::Null), Reply::default());
    assert_eq!(reply(json!([])), Reply::default());
}

#[test]
fn ids_titles_and_symbols_parse() {
    let got = reply(json!([
        "palette.newAgentChat | New chat | square.and.pencil",
        "search.chats|Search",
        "automations.show",
        "appStore.show | | puzzlepiece",
    ]));
    assert!(got.problems.is_empty(), "{:?}", got.problems);
    let rows: Vec<_> = got
        .rows
        .iter()
        .map(|r| (r.action.as_str(), r.title.as_deref(), r.symbol.as_deref()))
        .collect();
    assert_eq!(
        rows,
        [
            ("palette.newAgentChat", Some("New chat"), Some("square.and.pencil")),
            ("search.chats", Some("Search"), None),
            ("automations.show", None, None),
            ("appStore.show", None, Some("puzzlepiece")),
        ]
    );
}

#[test]
fn a_legacy_id_becomes_its_canonical_one() {
    let (old, new) = cmux_action_catalog::tables::LEGACY_ALIASES
        .iter()
        .find(|(_, new)| {
            cmux_action_catalog::find(new).is_some_and(|a| !a.is_debug_only && !a.is_destructive)
        })
        .expect("a legacy alias to an everyday action");
    let got = reply(json!([old]));
    assert_eq!(got.rows.first().map(|r| r.action.as_str()), Some(*new));
}

#[test]
fn bad_entries_are_dropped_with_a_reason_and_the_rest_draw() {
    let destructive =
        cmux_action_catalog::actions().find(|a| a.is_destructive).expect("a destructive action").id;
    let got = reply(json!([
        "no.such.action",
        7,
        destructive,
        "home.show | Home | Bad Symbol",
        "home.show | a | b | c",
        "home.show",
        "home.show | Again",
        "",
    ]));
    assert_eq!(got.rows.len(), 1);
    assert_eq!(got.rows[0].action, "home.show");
    let paths: Vec<_> = got.problems.iter().map(|p| p.path.as_str()).collect();
    assert_eq!(
        paths,
        [
            "sidebar.nav[0]",
            "sidebar.nav[1]",
            "sidebar.nav[2]",
            "sidebar.nav[3]",
            "sidebar.nav[4]",
            "sidebar.nav[6]",
            "sidebar.nav[7]"
        ]
    );
    assert!(got.problems[2].why.contains("destructive"));
    assert!(got.problems[5].why.contains("duplicate"));
}

#[test]
fn not_a_list_and_too_many_rows_are_bounded() {
    assert_eq!(reply(json!("home.show")).problems[0].path, "sidebar.nav");
    let everyday: Vec<_> = cmux_action_catalog::actions()
        .filter(|a| !a.is_debug_only && !a.is_destructive)
        .take(MAX_ROWS + 3)
        .map(|a| a.id)
        .collect();
    let got = reply(json!(everyday));
    assert_eq!(got.rows.len(), MAX_ROWS);
    assert_eq!(got.problems.len(), 1);
    assert!(got.problems[0].why.contains("at most"));
}

#[test]
fn a_long_title_is_refused() {
    let got = reply(json!([format!("home.show | {}", "x".repeat(MAX_TITLE + 1))]));
    assert!(got.rows.is_empty());
    assert!(got.problems[0].why.contains("title"));
}
