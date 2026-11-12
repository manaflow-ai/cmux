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
    // Nothing denied: nothing blocked, and an unknown name is fine.
    let g = Guard { denies: false };
    assert!(!title_names_blocked_app(&g, "New Terminal at Folder", &resolve));
    assert!(!title_names_blocked_app(&g, "Open Settings", &resolve));
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
