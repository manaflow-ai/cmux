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

#[test]
fn denied_items_match_whole_words_in_the_title_or_path() {
    let p = MenuPolicy { mode: MenuMode::Open, denied_names: titles(&["Terminal", "cmux"]) };
    assert_eq!(p.denied_item("Terminal", &titles(&["Open With"])), Some("Terminal"));
    assert_eq!(p.denied_item("New Terminal at Folder", &titles(&["Services"])), Some("Terminal"));
    assert_eq!(p.denied_item("Open in cmux", &[]), Some("cmux"));
    // A path element names the app: everything below it is denied.
    assert_eq!(p.denied_item("Window 1", &titles(&["Terminal"])), Some("Terminal"));
    // Not a whole word.
    assert_eq!(p.denied_item("Terminals Guide", &[]), None);
    assert_eq!(p.denied_item("cmuxlike", &[]), None);
    assert_eq!(p.denied_item("TextEdit", &titles(&["Open With"])), None);
}

#[test]
fn denied_names_follow_the_deny_list_and_running_apps() {
    let mut config = PolicyConfig::default();
    let running = vec![App {
        id: "com.example.secret".into(),
        name: "Secret Vault".into(),
        pid: 5,
        frontmost: false,
        hidden: false,
    }];
    let names = denied_names(&config, &running);
    assert!(names.iter().any(|n| n == "Terminal"));
    assert!(names.iter().any(|n| n == "System Settings"));
    assert!(names.iter().any(|n| n == "1Password"));
    assert!(!names.iter().any(|n| n == "Secret Vault"));

    // The person removed Terminal and added an app by id and one by name.
    config.denied_apps.retain(|a| a != "com.apple.Terminal");
    config.denied_apps.push("com.example.secret".into());
    config.denied_apps.push("name:Diary".into());
    let names = denied_names(&config, &running);
    assert!(!names.iter().any(|n| n == "Terminal"));
    assert!(names.iter().any(|n| n == "Secret Vault"));
    assert!(names.iter().any(|n| n == "Diary"));

    // An empty deny list still protects the security UI.
    config.denied_apps.clear();
    let names = denied_names(&config, &[]);
    assert_eq!(names, vec!["SecurityAgent".to_string(), "cmux Remote".to_string()]);
}

fn el(role: &str, name: &str, children: Vec<Element>) -> Element {
    Element {
        id: name.into(),
        role: role.into(),
        name: name.into(),
        value: String::new(),
        frame: None,
        actions: vec![],
        focused: false,
        disabled: false,
        children,
    }
}

#[test]
fn hide_denied_removes_items_and_their_submenus() {
    let mut root = el(
        "window",
        "Finder",
        vec![el(
            "menu",
            "",
            vec![
                el("menu_item", "Open", vec![]),
                el(
                    "menu_item",
                    "Open With",
                    vec![el(
                        "menu",
                        "",
                        vec![
                            el("menu_item", "TextEdit", vec![]),
                            el("menu_item", "Terminal", vec![]),
                        ],
                    )],
                ),
                el(
                    "menu_item",
                    "Services",
                    vec![el("menu", "", vec![el("menu_item", "New Terminal at Folder", vec![])])],
                ),
                el("text", "Terminal", vec![]),
            ],
        )],
    );
    let policy = MenuPolicy { mode: MenuMode::Open, denied_names: titles(&["Terminal"]) };
    assert!(has_menu_items(&root));
    assert!(!has_menu_items(&el("window", "w", vec![el("button", "OK", vec![])])));
    assert_eq!(hide_denied(&mut root, &policy), 2);
    let menu = &root.children[0];
    let names: Vec<&str> = menu.children.iter().map(|c| c.name.as_str()).collect();
    // Plain text naming the app is not a menu item and stays.
    assert_eq!(names, vec!["Open", "Open With", "Services", "Terminal"]);
    assert_eq!(menu.children[1].children[0].children.len(), 1);
    assert!(menu.children[2].children[0].children.is_empty());
    // Nothing denied: nothing removed.
    let mut copy = root.clone();
    assert_eq!(hide_denied(&mut copy, &MenuPolicy::default()), 0);
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
