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
            cmux_action_catalog::find(new)
                .is_some_and(|a| !a.is_debug_only && !a.is_destructive && !ends_or_removes(a.id))
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
        .filter(|a| !a.is_debug_only && !a.is_destructive && !ends_or_removes(a.id))
        .take(MAX_ROWS + 3)
        .map(|a| a.id)
        .collect();
    let got = reply(json!(everyday));
    assert_eq!(got.rows.len(), MAX_ROWS);
    // Each dropped entry gets its own diagnostic, not just the first past the limit.
    let paths: Vec<_> = got.problems.iter().map(|p| p.path.clone()).collect();
    assert_eq!(paths, ["sidebar.nav[12]", "sidebar.nav[13]", "sidebar.nav[14]"]);
    assert!(got.problems.iter().all(|p| p.why.contains("at most")));
}

#[test]
fn actions_that_quit_close_or_remove_are_refused_even_when_not_marked_destructive() {
    let got = reply(json!([
        "quit",
        "closeAllWindows",
        "workspace.closeAll",
        "palette.auth.signOut",
        "quitEndSessions",
        "home.show",
    ]));
    assert_eq!(got.rows.len(), 1, "{:?}", got.problems);
    assert_eq!(got.rows[0].action, "home.show");
    assert_eq!(got.problems.len(), 5);
    assert!(got.problems.iter().all(|p| p.why.contains("destructive")));
}

#[test]
fn the_word_test_reads_whole_words() {
    assert!(ends_or_removes("closeAllWindows"));
    assert!(ends_or_removes("palette.auth.signOut"));
    assert!(!ends_or_removes("reopenClosedWorkspace"));
    assert!(!ends_or_removes("palette.newAgentChat"));
    assert!(!ends_or_removes("appearance.customize"));
}

#[test]
fn a_long_title_is_refused() {
    let got = reply(json!([format!("home.show | {}", "x".repeat(MAX_TITLE + 1))]));
    assert!(got.rows.is_empty());
    assert!(got.problems[0].why.contains("title"));
}
