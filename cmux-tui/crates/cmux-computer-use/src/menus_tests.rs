use super::*;

fn titles(t: &[&str]) -> Vec<String> {
    t.iter().map(|s| (*s).to_string()).collect()
}

#[test]
fn mode_parses_and_defaults_to_open() {
    assert_eq!(MenuMode::default(), MenuMode::Open);
    assert_eq!(MenuMode::parse("open"), Some(MenuMode::Open));
    assert_eq!(MenuMode::parse("refuse"), Some(MenuMode::Refuse));
    assert_eq!(MenuMode::parse("Open"), None);
    assert_eq!(MenuMode::Refuse.as_str(), "refuse");
    assert_eq!(serde_json::to_value(MenuMode::Refuse).unwrap(), "refuse");
}

#[test]
fn match_prefers_exact_then_case_then_unique_prefix() {
    let items = titles(&["When Unlocked", "Always", "never", "Never Again"]);
    assert_eq!(match_item(&items, "Always"), ItemMatch::Found(1));
    // Exact wins over a case-insensitive twin.
    assert_eq!(match_item(&items, "never"), ItemMatch::Found(2));
    assert_eq!(match_item(&items, "ALWAYS"), ItemMatch::Found(1));
    assert_eq!(match_item(&items, " when "), ItemMatch::Found(0));
    assert_eq!(match_item(&items, "Nev"), ItemMatch::Ambiguous(vec![2, 3]));
    assert_eq!(match_item(&items, "Sometimes"), ItemMatch::NotFound);
    assert_eq!(match_item(&items, "  "), ItemMatch::NotFound);
}

#[test]
fn match_reads_three_dots_as_an_ellipsis() {
    let items = titles(&["Other\u{2026}", "Open"]);
    assert_eq!(match_item(&items, "Other..."), ItemMatch::Found(0));
}

#[test]
fn not_found_lists_the_items() {
    let items = titles(&["A", "", "B"]);
    let msg = not_found("C", &ItemMatch::NotFound, &items);
    assert!(msg.contains("its items: A, B"), "{msg}");
    let msg = not_found("x", &ItemMatch::Ambiguous(vec![0, 2]), &items);
    assert!(msg.contains("A, B") && msg.contains("full title"), "{msg}");
}

/// Denies Terminal (by id) and anything named "Diary"; "Settings" resolves
/// to nothing yet (the index is being built).
struct Guard {
    denies: bool,
}

impl MenuGuard for Guard {
    fn app_blocked(&self, id: &str, name: &str) -> bool {
        self.denies && (id == "com.apple.Terminal" || name.eq_ignore_ascii_case("Diary"))
    }
    fn denies_any(&self) -> bool {
        self.denies
    }
}

fn resolve(name: &str) -> Option<Vec<String>> {
    match name {
        "Terminal" => Some(vec!["com.apple.Terminal".into()]),
        "TextEdit" => Some(vec!["com.apple.TextEdit".into()]),
        "Settings" => None,
        _ => Some(vec![]),
    }
}

#[test]
fn a_title_naming_a_blocked_app_in_whole_words_is_blocked() {
    let g = Guard { denies: true };
    let blocked = |t: &str| title_names_blocked_app(&g, t, &resolve);
    assert!(blocked("Terminal"));
    assert!(blocked("New Terminal at Folder"));
    assert!(blocked("Open in Terminal\u{2026}"));
    assert!(blocked("Write in diary"));
    // Not a whole word, or another app.
    assert!(!blocked("Terminals Guide"));
    assert!(!blocked("TextEdit"));
    assert!(!blocked("Always"));
    // A name the index cannot answer yet fails closed while anything is denied.
    assert!(blocked("Open Settings"));
    // Nothing denied: nothing blocked by the deny list; a name the index
    // cannot answer yet still fails closed (the protected apps apply).
    let g = Guard { denies: false };
    assert!(!title_names_blocked_app(&g, "New Terminal at Folder", &resolve));
    assert!(title_names_blocked_app(&g, "Open Settings", &resolve));
}

#[test]
fn reports_serialize_without_empty_fields() {
    let r = MenuReport::picked("Always", Some(42));
    let v = serde_json::to_value(&r).unwrap();
    assert_eq!(v, serde_json::json!({"state": "picked", "picked": "Always", "open_ms": 42}));
    let r = MenuReport::open(vec![MenuItemInfo { title: "A".into(), ..Default::default() }], 1);
    let v = serde_json::to_value(&r).unwrap();
    assert_eq!(v["items"], serde_json::json!([{"title": "A"}]));
    assert_eq!(v["hidden"], 1);
    assert!(v["next"].as_str().unwrap().contains("press an item"));
}

#[test]
fn a_pick_matches_visible_items_first_and_never_a_hidden_one() {
    let items = titles(&["New Terminal at Folder", "New Folder", "Never"]);
    let hidden = [true, false, false];
    // "New" is a unique prefix among the visible items, though a hidden one shares it.
    assert_eq!(pick(&items, &hidden, "New"), Pick::Item(1));
    assert_eq!(pick(&items, &hidden, "never"), Pick::Item(2));
    // Only the hidden item matches: refused, and it is not listed.
    assert_eq!(pick(&items, &hidden, "New Terminal"), Pick::Hidden);
    assert_eq!(pick(&items, &hidden, "Open"), Pick::Missing(ItemMatch::NotFound));
    let msg = denied_item_refusal(Some("New Terminal"));
    assert!(msg.contains("\"New Terminal\"") && !msg.contains("at Folder"), "{msg}");
    assert!(!denied_item_refusal(None).contains("Terminal"));
}

#[test]
fn a_long_menu_lists_its_first_items_and_counts_the_rest() {
    let mut r = MenuReport::open(vec![MenuItemInfo { title: "A".into(), ..Default::default() }], 0);
    r.more = 1800;
    let v = serde_json::to_value(&r).unwrap();
    assert_eq!(v["more"], 1800);
}

#[test]
fn a_mode_is_read_in_any_case_and_an_unknown_one_refuses() {
    let read = |v: serde_json::Value| serde_json::from_value::<MenuMode>(v).unwrap();
    assert_eq!(read(serde_json::json!("open")), MenuMode::Open);
    assert_eq!(read(serde_json::json!("Refuse")), MenuMode::Refuse);
    assert_eq!(read(serde_json::json!("OPEN")), MenuMode::Open);
    assert_eq!(read(serde_json::json!("sometimes")), MenuMode::Refuse);
    assert_eq!(read(serde_json::json!(null)), MenuMode::Refuse);
    assert_eq!(read(serde_json::json!(false)), MenuMode::Refuse);
    assert_eq!(read(serde_json::json!(1)), MenuMode::Refuse);
}

#[test]
fn a_menu_path_names_each_level() {
    assert_eq!(menu_path("Sort By > Name"), vec!["Sort By".to_string(), "Name".to_string()]);
    assert_eq!(
        menu_path("View \u{25B8} as Icons"),
        vec!["View".to_string(), "as Icons".to_string()]
    );
    assert_eq!(menu_path("Always"), vec!["Always".to_string()]);
    assert_eq!(menu_path(""), vec![String::new()]);
}

#[test]
fn an_exact_hidden_title_is_refused_before_a_visible_prefix() {
    let items = titles(&["Terminals Guide", "Terminal"]);
    let hidden = [false, true];
    assert_eq!(pick(&items, &hidden, "Terminal"), Pick::Hidden);
    assert_eq!(pick(&items, &hidden, "terminal"), Pick::Hidden);
    assert_eq!(pick(&items, &hidden, "Terminals"), Pick::Item(0));
    // Ambiguous among the visible items: listed, not guessed.
    let items = titles(&["Hidden Nev", "Never", "Never Again"]);
    let hidden = [true, false, false];
    // Indices among the visible items, as a caller lists them.
    assert_eq!(pick(&items, &hidden, "Nev"), Pick::Missing(ItemMatch::Ambiguous(vec![0, 1])));
}
