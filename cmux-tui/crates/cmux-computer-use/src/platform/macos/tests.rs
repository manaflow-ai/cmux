//! Unit tests of the pure pieces, and an `#[ignore]` smoke of the real
//! desktop (run it on a Mac with a logged-in console session:
//! `cargo test -p cmux-computer-use -- --ignored macos_desktop_smoke --nocapture`).

use super::*;
use crate::desktop::{Button, MenuGuard, Point, Rect};
use crate::keys::{Key, KeyCombo, Modifier};

#[test]
fn modifier_flags() {
    assert_eq!(keymap::flags(&[]), 0);
    assert_eq!(
        keymap::flags(&[Modifier::Shift, Modifier::Meta]),
        keymap::FLAG_SHIFT | keymap::FLAG_COMMAND
    );
    assert_eq!(
        keymap::flags(&[Modifier::Control, Modifier::Alt, Modifier::Fn]),
        keymap::FLAG_CONTROL | keymap::FLAG_ALTERNATE | keymap::FLAG_FN
    );
}

#[test]
fn key_codes() {
    let code = |s: &str| keymap::key_code(&KeyCombo::parse(s).unwrap().key);
    assert_eq!(code("a"), Some((0, false)));
    assert_eq!(code("A"), Some((0, true)));
    assert_eq!(code("cmd+t"), Some((17, false)));
    assert_eq!(code("Return"), Some((36, false)));
    assert_eq!(code("Tab"), Some((48, false)));
    assert_eq!(code("Escape"), Some((53, false)));
    assert_eq!(code("Backspace"), Some((51, false)));
    assert_eq!(code("Delete"), Some((117, false)));
    assert_eq!(code("Left"), Some((123, false)));
    assert_eq!(code("Up"), Some((126, false)));
    assert_eq!(code("F1"), Some((122, false)));
    assert_eq!(code("F12"), Some((111, false)));
    assert_eq!(code("cmd+plus"), Some((24, true)));
    assert_eq!(code("?"), Some((44, true)));
    assert_eq!(code("1"), Some((18, false)));
    assert_eq!(keymap::key_code(&Key::F(24)), None);
    assert_eq!(keymap::key_code(&Key::Char('é')), None);
}

#[test]
fn every_ascii_printable_has_a_key() {
    for c in (0x20u8..0x7f).map(char::from) {
        assert!(keymap::char_key(c).is_some(), "{c:?} has no key");
    }
}

#[test]
fn only_plain_characters_carry_text() {
    assert_eq!(keymap::carries_text(&Key::Char('a'), 0), Some('a'));
    assert_eq!(keymap::carries_text(&Key::Char('A'), keymap::FLAG_SHIFT), Some('A'));
    assert_eq!(keymap::carries_text(&Key::Char('c'), keymap::FLAG_CONTROL), None);
    assert_eq!(keymap::carries_text(&Key::Char('t'), keymap::FLAG_COMMAND), None);
    assert_eq!(keymap::carries_text(&Key::Return, 0), None);
}

#[test]
fn role_names() {
    assert_eq!(roles::role_name("AXButton", None), "button");
    assert_eq!(roles::role_name("AXStaticText", None), "text");
    assert_eq!(roles::role_name("AXTextField", Some("AXSecureTextField")), "secure_text_field");
    assert_eq!(roles::role_name("AXTextField", Some("AXSomethingElse")), "text_field");
    assert_eq!(roles::role_name("AXButton", Some("AXCloseButton")), "close_button");
    assert_eq!(roles::role_name("AXPopUpButton", None), "popup_button");
    assert_eq!(roles::role_name("AXCheckBox", None), "checkbox");
    assert_eq!(roles::role_name("AXWebArea", None), "web_area");
    assert_eq!(roles::role_name("AXMenuBarItem", None), "menu_bar_item");
    assert_eq!(roles::role_name("", None), "unknown");
}

#[test]
fn action_names_round_trip() {
    assert_eq!(roles::action_name("AXPress"), "press");
    assert_eq!(roles::action_name("AXShowMenu"), "show_menu");
    assert_eq!(roles::action_name("AXIncrement"), "increment");
    assert_eq!(roles::action_name("AXShowDefaultUI"), "show_default_ui");
    assert_eq!(roles::action_name("Name:Reply\nTarget:0x0\nSelector:(null)"), "Reply");
    assert_eq!(roles::pascal_ax("show_menu"), "AXShowMenu");
    let available: Vec<String> = ["AXPress", "AXShowMenu", "Name:Archive\nTarget:0x1"]
        .iter()
        .map(|s| s.to_string())
        .collect();
    assert_eq!(
        roles::resolve_action("show_menu", &available).map(String::as_str),
        Some("AXShowMenu")
    );
    assert_eq!(roles::resolve_action("AXPress", &available).map(String::as_str), Some("AXPress"));
    assert!(roles::resolve_action("archive", &available).is_some());
    assert!(roles::resolve_action("increment", &available).is_none());
    assert_eq!(roles::attribute_action("expand"), Some(("AXExpanded", true)));
    assert!(roles::is_foreground_action("AXRaise"));
    assert!(roles::is_foreground_action("AXShowMenu"), "a menu takes the person's pointer");
    assert!(!roles::is_foreground_action("AXPress"));
}

#[test]
fn menu_opening_roles_are_refused_in_the_background() {
    for role in ["AXPopUpButton", "AXMenuButton", "AXComboBox", "AXMenuBarItem", "AXMenuExtra"] {
        assert!(roles::opens_menu(role, false, false), "{role}");
    }
    for role in ["AXButton", "AXCheckBox", "AXTextField", "AXMenuItem", "AXRadioButton"] {
        assert!(!roles::opens_menu(role, false, true), "{role}");
    }
    // Web content: an HTML <select> (a pop-up with its own menu) opens a
    // native menu; an ARIA menu button opens DOM content.
    assert!(roles::opens_menu("AXPopUpButton", true, true));
    assert!(!roles::opens_menu("AXPopUpButton", true, false));
    assert!(!roles::opens_menu("AXMenuButton", true, true));
    assert!(!roles::opens_menu("AXComboBox", true, false));
}

#[test]
fn menu_refusals_name_what_works_instead() {
    let popup = roles::menu_refusal("AXPopUpButton");
    assert!(popup.contains("popup_button") && popup.contains("set_value"), "{popup}");
    assert!(popup.contains("delivery foreground"), "{popup}");
    assert!(roles::menu_refusal("AXComboBox").contains("type_text"));
    assert!(roles::CONTEXT_MENU_REFUSAL.contains("perform_action"));
}

#[test]
fn keys_and_text_that_open_a_focused_popup() {
    for key in [Key::Space, Key::Return, Key::Up, Key::Down, Key::Char(' ')] {
        assert!(roles::key_opens_menu(&key), "{key:?}");
    }
    for key in [Key::Tab, Key::Escape, Key::Left, Key::Char('a')] {
        assert!(!roles::key_opens_menu(&key), "{key:?}");
    }
    assert!(roles::text_opens_menu("a b"));
    assert!(roles::text_opens_menu("x\n"));
    assert!(!roles::text_opens_menu("Tuesday"));
    assert!(roles::same_title(" Large ", "large"));
    assert!(!roles::same_title("Large", "Larger"));
}

#[test]
fn element_ids() {
    let id = roles::element_id(7, 42);
    assert_eq!(roles::parse_element_id(&id), Some((7, 42)));
    assert_eq!(roles::parse_element_id("x"), None);
    assert_eq!(roles::parse_element_id("1.y"), None);
}

#[test]
fn stale_and_unknown_element_ids() {
    let cache = ElementCache::default();
    assert!(matches!(cache.lookup("10", "1.0"), Err(DesktopError::StaleElement(_))));
    assert!(matches!(cache.lookup("10", "nope"), Err(DesktopError::TargetNotFound(_))));
}

#[test]
fn geometry() {
    let r = Rect { x: 100.0, y: 50.0, width: 200.0, height: 100.0 };
    assert_eq!(roles::center(&r), Point { x: 200.0, y: 100.0 });
    assert!(roles::contains(&r, Point { x: 100.0, y: 50.0 }));
    assert!(roles::contains(&r, Point { x: 300.2, y: 150.0 }));
    assert!(!roles::contains(&r, Point { x: 99.0, y: 60.0 }));
    assert!(!roles::contains(&r, Point { x: 150.0, y: 151.0 }));
    assert_eq!(roles::clamp_into(&r, Point { x: 300.4, y: 49.6 }), Point { x: 299.0, y: 50.0 });
    assert_eq!(roles::scale_of(2912, 1456.0), 2.0);
    assert_eq!(roles::scale_of(10, 0.0), 1.0);
}

#[test]
fn wheel_direction_and_rounding() {
    // dy > 0 scrolls down: a negative wheel in CG's convention.
    assert_eq!(roles::wheel_deltas(0.0, 3.0), (-3, 0));
    assert_eq!(roles::wheel_deltas(0.0, -2.0), (2, 0));
    assert_eq!(roles::wheel_deltas(1.0, 0.0), (0, -1));
    assert_eq!(roles::wheel_deltas(0.0, 0.2), (-1, 0));
    assert_eq!(roles::wheel_deltas(0.0, f64::NAN), (0, 0));
}

#[test]
fn drag_paths_end_at_the_target() {
    let from = Point { x: 0.0, y: 0.0 };
    let to = Point { x: 100.0, y: 0.0 };
    let path = roles::drag_path(from, to);
    assert_eq!(path.len(), 13);
    assert_eq!(*path.last().unwrap(), to);
    assert!(path.windows(2).all(|w| w[1].x > w[0].x));
    assert_eq!(roles::drag_path(from, from).len(), 4);
    assert_eq!(roles::drag_path(from, Point { x: 10_000.0, y: 0.0 }).len(), 60);
}

#[test]
fn button_event_types() {
    assert_eq!(input::button_events(Button::Left), (1, 2, 6));
    assert_eq!(input::button_events(Button::Right), (3, 4, 7));
    assert_eq!(input::button_events(Button::Middle), (25, 26, 27));
}

#[test]
fn bad_window_ids_are_not_found() {
    let d = MacDesktop::new(None);
    assert!(matches!(
        d.ui_tree("not-a-window", TreeOptions::default()),
        Err(DesktopError::TargetNotFound(_))
    ));
    assert!(matches!(d.set_value("4294967295", "1.0", "x"), Err(DesktopError::TargetNotFound(_))));
}

#[test]
fn info_names_macos() {
    let info = MacDesktop::new(None).info();
    assert_eq!(info.os, "macos");
    assert_eq!(info.display_server, "quartz");
    assert!(info.detail.starts_with("macOS"), "{}", info.detail);
}

/// The real desktop: apps, windows, a CoreGraphics screenshot and one tree.
/// Needs a console session; screenshots and trees need their grants, and
/// report which one is missing instead of failing.
#[test]
#[ignore = "needs a logged-in macOS console session"]
fn macos_desktop_smoke() {
    let d = MacDesktop::new(None);
    println!("info: {:?}", d.info());
    println!("permissions: {:?}", d.permissions());
    let apps = d.list_apps().expect("list_apps");
    println!(
        "{} apps, e.g. {:?}",
        apps.len(),
        apps.iter().take(5).map(|a| &a.id).collect::<Vec<_>>()
    );
    assert!(!apps.is_empty(), "a console session runs at least Finder or the Dock");
    let windows = d.list_windows().expect("list_windows");
    println!("{} windows", windows.len());
    for w in windows.iter().take(10) {
        println!("  {} {} {:?} {:?} on_screen={}", w.id, w.app_id, w.title, w.frame, w.on_screen);
    }
    match d.capture(&CaptureTarget::Display(None)) {
        Ok(f) => {
            println!("display: {}x{} @{}x origin {:?}", f.width, f.height, f.scale, f.origin);
            assert_eq!(f.rgba.len(), (f.width * f.height * 4) as usize);
        }
        Err(e) => println!("display capture: {e} ({})", e.code()),
    }
    if let Some(w) = windows.iter().find(|w| w.on_screen) {
        match d.capture(&CaptureTarget::Window(w.id.clone())) {
            Ok(f) => println!("window {}: {}x{} @{}x", w.id, f.width, f.height, f.scale),
            Err(e) => println!("window capture: {e} ({})", e.code()),
        }
        match d.ui_tree(&w.id, TreeOptions { max_nodes: 200, max_depth: 8, menus: true }) {
            Ok(t) => println!("tree of {}: root {} truncated={}", w.id, t.root.role, t.truncated),
            Err(e) => println!("ui_tree: {e} ({})", e.code()),
        }
    }
}

#[test]
fn shortcuts_match_menu_items_by_char_and_modifiers() {
    use crate::keys::KeyCombo;
    let m = |combo: &str, ch: Option<&str>, vk: Option<i64>, mods: i64| {
        keymap::menu_item_matches(&KeyCombo::parse(combo).unwrap(), ch, vk, mods)
    };
    // TextEdit's Make Plain Text is ⇧⌘T: AX reports "T" with the Shift bit.
    assert!(m("cmd+shift+t", Some("T"), None, keymap::MENU_SHIFT));
    // ⌘T (Show Fonts) is not ⇧⌘T, and the other way round.
    assert!(!m("cmd+shift+t", Some("T"), None, 0));
    assert!(!m("cmd+t", Some("T"), None, keymap::MENU_SHIFT));
    assert!(m("cmd+t", Some("T"), None, 0));
    // Option and Control must match exactly too.
    assert!(m("cmd+alt+s", Some("S"), None, keymap::MENU_OPTION));
    assert!(!m("cmd+s", Some("S"), None, keymap::MENU_OPTION));
    assert!(m("ctrl+cmd+f", Some("F"), None, keymap::MENU_CONTROL));
    // An item with no Command (MENU_NO_COMMAND) never matches a cmd chord.
    assert!(!m("cmd+f", Some("F"), None, keymap::MENU_NO_COMMAND));
    // Non-character equivalents compare the virtual key code.
    let (left, _) = keymap::key_code(&Key::Left).unwrap();
    assert!(m("cmd+left", None, Some(i64::from(left)), 0));
    assert!(!m("cmd+right", None, Some(i64::from(left)), 0));
    // Punctuation and digits match as typed.
    assert!(m("cmd+,", Some(","), None, 0));
    assert!(m("cmd+1", Some("1"), None, 0));
    // A missing or multi-character equivalent never matches a character key.
    assert!(!m("cmd+s", None, None, 0));
    assert!(!m("cmd+s", Some("SS"), None, 0));
}

#[test]
fn stepping_targets_take_numbers_and_percentages() {
    assert_eq!(roles::step_target("25%", 0.0, 1.0), Some(0.25));
    assert_eq!(roles::step_target("0.25", 0.0, 1.0), Some(0.25));
    assert_eq!(roles::step_target(" 40 % ", 0.0, 200.0), Some(80.0));
    assert_eq!(roles::step_target("150%", 0.0, 1.0), Some(1.0)); // clamped
    assert_eq!(roles::step_target("-3", 0.0, 10.0), Some(0.0));
    assert_eq!(roles::step_target("loud", 0.0, 1.0), None);
    assert!(roles::step_reached(0.26, 0.25, 0.0, 1.0));
    assert!(!roles::step_reached(0.31, 0.25, 0.0, 1.0));
}

/// A guard over the real policy decision (deny list and protected apps).
struct PolicyGuard(crate::policy::PolicyConfig);
impl MenuGuard for PolicyGuard {
    fn app_blocked(&self, id: &str, name: &str) -> bool {
        crate::policy::is_blocked(&self.0, &crate::policy::TargetApp { id: id.into(), name: name.into() }).is_some()
    }
    fn denies_any(&self) -> bool {
        !self.0.denied_apps.is_empty()
    }
}

/// Installed apps by display name, as a German Mac lists them: two apps share
/// "Ghostty" (an allowed copy and the denied one).
fn resolve(name: &str) -> Option<Vec<String>> {
    Some(match name.to_lowercase().as_str() {
        "terminal" => vec!["com.apple.Terminal".into()],
        "textedit" => vec!["com.apple.TextEdit".into()],
        "systemeinstellungen" | "system settings" => vec!["com.apple.systempreferences".into()],
        "schlüsselbundverwaltung" | "keychain access" => vec!["com.apple.keychainaccess".into()],
        "vorschau" | "preview" => vec!["com.apple.Preview".into()],
        "ghostty" => vec!["com.example.ghostty-viewer".into(), "com.mitchellh.ghostty".into()],
        "xcode" => vec!["com.apple.dt.Xcode".into()],
        _ => vec![],
    })
}

fn blocked_in(guard: &PolicyGuard, top: Option<usize>, depth: usize, siblings: &[&str], title: &str) -> bool {
    let siblings: Vec<String> = siblings.iter().map(|s| s.to_string()).collect();
    let ctx = roles::MenuItemContext { title, top_index: top, depth, siblings: &siblings };
    roles::menu_item_blocked(guard, &ctx, &resolve)
}

#[test]
fn a_denied_app_is_never_reachable_through_menus_in_any_language() {
    let guard = PolicyGuard(crate::policy::PolicyConfig::default()); // Terminal, Keychain, System Settings, Ghostty, ...
    // German Apple menu > Benutzte Objekte (Recent Items): by structure (Apple menu, a submenu), not by title.
    let recent = ["Programme", "Terminal", "TextEdit", "notizen.txt", "Menü löschen"];
    assert!(blocked_in(&guard, Some(0), 2, &recent, "Terminal"));
    assert!(!blocked_in(&guard, Some(0), 2, &recent, "TextEdit"));
    // A document or an unknown entry there could open in a denied app.
    assert!(blocked_in(&guard, Some(0), 2, &recent, "notizen.txt"));
    // German app menu > Dienste (Services): every entry, while any app is denied.
    assert!(blocked_in(&guard, Some(1), 2, &["Neues Terminal beim Ordner", "Notiz erstellen"], "Notiz erstellen"));
    // Öffnen mit (Open With), in a File menu: a list of apps, found by its items.
    let open_with = ["TextEdit (Standard)", "Terminal", "Vorschau", "Andere …"];
    assert!(blocked_in(&guard, Some(3), 2, &open_with, "Terminal"));
    assert!(!blocked_in(&guard, Some(3), 2, &open_with, "TextEdit (Standard)"));
    assert!(!blocked_in(&guard, Some(3), 2, &open_with, "Vorschau"));
    // Apple menu "Systemeinstellungen…" launches a denied app: blocked by the app it names.
    assert!(blocked_in(&guard, Some(0), 1, &["Über diesen Mac", "Systemeinstellungen…", "Sperren"], "Systemeinstellungen…"));
    assert!(blocked_in(&guard, Some(0), 1, &[], "System Settings…"));
    // macOS adds a note after the name: still the same app.
    assert!(blocked_in(&guard, Some(0), 1, &[], "System Settings…, 1 update"));
    assert!(blocked_in(&guard, Some(0), 1, &[], "Systemeinstellungen …, 1 Update"));
    assert_eq!(roles::menu_name_candidates("System Settings…, 1 update"), vec!["System Settings…, 1 update", "System Settings"]);
    // The rest of the Apple menu stays reachable (the person allows it).
    for t in ["Über diesen Mac", "Bildschirm sperren", "Ruhezustand", "Abmelden …", "Sofort beenden …"] {
        assert!(!blocked_in(&guard, Some(0), 1, &[], t), "{t}");
    }
    // Same-name apps: one denied copy blocks the name; a version suffix in a launch list is ambiguous.
    assert!(blocked_in(&guard, Some(3), 2, &["Ghostty", "Xcode (16.4)"], "Ghostty"));
    assert!(blocked_in(&guard, Some(3), 2, &["Ghostty", "Xcode (16.4)", "Xcode (17.0)"], "Xcode (16.4)"));
    // Ordinary menus are untouched, also when an item happens to be in a submenu.
    assert!(!blocked_in(&guard, Some(2), 1, &["Sichern", "Drucken …"], "Sichern"));
    assert!(!blocked_in(&guard, Some(4), 2, &["Fett", "Kursiv", "Unterstrichen"], "Fett"));
    // With an empty deny list only protected apps are blocked.
    let open = PolicyGuard(crate::policy::PolicyConfig { denied_apps: vec![], ..Default::default() });
    assert!(!blocked_in(&open, Some(0), 2, &recent, "Terminal"));
    assert!(!blocked_in(&open, Some(1), 2, &["Notiz erstellen"], "Notiz erstellen"));
    assert_eq!(roles::menu_app_name("Xcode (16.4)"), ("Xcode", true));
    assert_eq!(roles::menu_app_name("TextEdit (Standard)"), ("TextEdit", false));
    assert_eq!(roles::menu_app_name("Systemeinstellungen…"), ("Systemeinstellungen", false));
    assert_eq!(roles::menu_app_name("Andere ..."), ("Andere", false));
}

#[test]
fn shortcuts_run_the_first_enabled_item_as_appkit_does() {
    use roles::{ShortcutMatch as M, ShortcutPick as P};
    let m = |t: &str, enabled: bool, blocked: bool| M { title: t.into(), enabled, blocked };
    assert_eq!(roles::pick_shortcut(&[]), P::None);
    assert_eq!(roles::pick_shortcut(&[m("A", false, false), m("B", true, false)]), P::Press(1));
    assert_eq!(roles::pick_shortcut(&[m("A", false, false)]), P::Disabled("A".into()));
    // A blocked first enabled match refuses: a later item must not run in its place.
    assert_eq!(roles::pick_shortcut(&[m("Svc", true, true), m("B", true, false)]), P::Blocked("Svc".into()));
    // A blocked disabled item is passed over like any disabled one.
    assert_eq!(roles::pick_shortcut(&[m("Svc", false, true), m("B", true, false)]), P::Press(1));
    // A chord no menu item has is posted (a web app's cmd+shift+7), unless it
    // is a registered Services shortcut while some app is denied.
    assert!(roles::unmatched_chord_allowed(false, true));
    assert!(!roles::unmatched_chord_allowed(true, true));
    assert!(roles::unmatched_chord_allowed(true, false));
}

#[test]
fn keys_and_menu_commands_reach_only_the_key_window() {
    assert!(roles::keys_reach_target(true, 3, true, false));
    assert!(roles::keys_reach_target(false, 1, true, false));
    // A dialog or panel is the key window: Return must not reach it.
    assert!(!roles::keys_reach_target(false, 1, true, true));
    assert!(!roles::keys_reach_target(false, 2, true, false));
    assert!(!roles::keys_reach_target(false, 1, false, false));
    assert_eq!(roles::submenu_refusal("AXMenuItem", false), None);
    assert!(roles::submenu_refusal("AXMenuItem", true).is_some());
    assert_eq!(roles::submenu_refusal("AXMenuBarItem", true), None);
}

#[test]
fn stepping_stops_at_the_target_the_end_or_a_wrong_way_step() {
    use roles::Step;
    assert_eq!(roles::step_outcome(0.5, 0.4, 0.25, false), Step::Continue);
    assert_eq!(roles::step_outcome(0.3, 0.2, 0.25, false), Step::Passed { back: false });
    assert_eq!(roles::step_outcome(0.26, 0.16, 0.25, false), Step::Passed { back: true });
    assert_eq!(roles::step_outcome(0.0, 0.0, 0.25, true), Step::AtEnd);
    assert_eq!(roles::step_outcome(0.5, 0.6, 0.25, false), Step::Away);
    assert!(roles::step_confirmed(false, 0.26, 0.25, 0.0, 1.0));
    assert!(!roles::step_confirmed(true, 0.25, 0.25, 0.0, 1.0));
}

#[test]
fn the_menu_walk_is_breadth_first_within_budget_and_depth() {
    // A tree: 0 -> [1, 2], 1 -> [3, 4], 2 -> [5], 3 -> [6]; node 4 is left out.
    let kids = |n: u32| -> Vec<u32> {
        match n {
            0 => vec![1, 2],
            1 => vec![3, 4],
            2 => vec![5],
            3 => vec![6],
            _ => vec![],
        }
    };
    let (slots, truncated) = roles::breadth_first(0u32, 100, 10, |n, _| (*n != 4).then(|| kids(*n)));
    let order: Vec<u32> = slots.iter().map(|s| s.node).collect();
    assert_eq!(order, vec![0, 1, 2, 3, 5, 6]);
    assert!(!truncated);
    assert_eq!(slots[3].parent, Some(1)); // 3 under 1
    assert_eq!(slots[5].parent, Some(3)); // 6 under 3, three levels down
    // Budget: every top-level item before any deeper one, and the cut is reported.
    let (slots, truncated) = roles::breadth_first(0u32, 3, 10, |n, _| Some(kids(*n)));
    assert_eq!(slots.iter().map(|s| s.node).collect::<Vec<_>>(), vec![0, 1, 2]);
    assert!(truncated);
    // Depth: nothing below max_depth levels, reported.
    let (slots, truncated) = roles::breadth_first(0u32, 100, 2, |n, _| Some(kids(*n)));
    assert_eq!(slots.iter().map(|s| s.node).collect::<Vec<_>>(), vec![0, 1, 2]);
    assert!(truncated);
}

#[test]
fn services_shortcuts_are_read_from_the_pasteboard_server_dump() {
    let dump = r#"
        {
        NSBundleIdentifier = "com.apple.AppleSpell";
        NSKeyEquivalent =         {
        };
    },
        {
        NSKeyEquivalent =         {
            default = B;
        };
        NSMenuItem = { default = "Send File To Bluetooth Device"; };
    },
        {
        NSKeyEquivalent =         {
            English = "$^@C";
            default = "$^@C";
        };
    },
        {
        NSKeyEquivalent =         {
            default = "New cmux Workspace Here";
        };
    }
    "#;
    assert_eq!(roles::service_equivalents(dump), vec!["B".to_string(), "$^@C".to_string()]);
    // Localized values and function keys (written \Uf704 in the dump) count too;
    // a value that is not a dictionary is skipped, not latched onto a later one.
    let dump2 = r#"
        NSKeyEquivalent = "@x";
        NSMenuItem = { default = "Q"; };
        NSKeyEquivalent = { de = "@$E"; default = "@\Uf704"; };
    "#;
    assert_eq!(roles::service_equivalents(dump2), vec!["@$E".to_string(), "@\u{f704}".to_string()]);
    let (f1, _) = keymap::key_code(&Key::F(1)).unwrap();
    assert_eq!(keymap::service_shortcut("@\u{f704}"), Some((f1, keymap::FLAG_COMMAND)));
    assert!(roles::is_key_equivalent("$^@C"));
    assert!(!roles::is_key_equivalent("New Workspace"));
    let (b, _) = keymap::char_key('b').unwrap();
    let (c, _) = keymap::char_key('c').unwrap();
    // "B" is ⇧⌘B (a capital means Shift; Command is implied).
    assert_eq!(keymap::service_shortcut("B"), Some((b, keymap::FLAG_COMMAND | keymap::FLAG_SHIFT)));
    assert_eq!(
        keymap::service_shortcut("$^@C"),
        Some((c, keymap::FLAG_COMMAND | keymap::FLAG_SHIFT | keymap::FLAG_CONTROL))
    );
    assert_eq!(keymap::service_shortcut("@"), None);
    let services = vec![keymap::service_shortcut("B").unwrap()];
    assert!(keymap::is_service_shortcut(b, keymap::FLAG_COMMAND | keymap::FLAG_SHIFT, &services));
    assert!(!keymap::is_service_shortcut(b, keymap::FLAG_COMMAND, &services));
    let (seven, _) = keymap::char_key('7').unwrap();
    assert!(!keymap::is_service_shortcut(seven, keymap::FLAG_COMMAND | keymap::FLAG_SHIFT, &services));
}

#[test]
fn shifted_punctuation_matches_its_menu_item() {
    use crate::keys::KeyCombo;
    let m = |combo: &str, ch: &str, mods: i64| keymap::menu_item_matches(&KeyCombo::parse(combo).unwrap(), Some(ch), None, mods);
    // Zoom In as AX reports it: AXMenuItemCmdChar "+", AXMenuItemCmdModifiers 0
    // (Command only); the "+" itself means shift+=.
    assert!(m("cmd++", "+", 0));
    assert!(m("cmd+shift+=", "+", 0));
    assert!(!m("cmd+=", "+", 0));
    // Zoom Out "-" with modifiers 0, and a plain "=".
    assert!(m("cmd+-", "-", 0));
    assert!(m("cmd+=", "=", 0));
    assert!(!m("cmd+shift+=", "=", 0));
    // Letters: AX reports "T"; Shift is the MENU_SHIFT bit.
    assert!(m("cmd+t", "T", 0));
    assert!(!m("cmd+t", "T", keymap::MENU_SHIFT));
    assert!(m("cmd+shift+t", "T", keymap::MENU_SHIFT));
    // An upper-case chord letter is a Shift chord, as the menu's Shift bit says.
    assert!(m("cmd+T", "T", keymap::MENU_SHIFT));
    assert!(!m("cmd+T", "T", 0));
    // "?" (Help) is shift+/.
    assert!(m("cmd+?", "?", 0));
    assert!(m("cmd+shift+/", "?", 0));
}

#[test]
fn menu_items_fail_closed_while_the_app_name_index_builds() {
    let guard = PolicyGuard(crate::policy::PolicyConfig::default());
    let pending = |_: &str| -> Option<Vec<String>> { None };
    let ctx = roles::MenuItemContext { title: "TextEdit", top_index: Some(0), depth: 2, siblings: &[] };
    assert!(roles::menu_item_blocked(&guard, &ctx, &pending));
    let open = PolicyGuard(crate::policy::PolicyConfig { denied_apps: vec![], ..Default::default() });
    assert!(!roles::menu_item_blocked(&open, &ctx, &pending));
}

#[test]
fn the_services_check_knows_which_layouts_it_can_read() {
    assert!(roles::is_ansi_layout(Some("com.apple.keylayout.US")));
    assert!(roles::is_ansi_layout(Some("com.apple.keylayout.ABC")));
    assert!(roles::is_ansi_layout(None));
    assert!(!roles::is_ansi_layout(Some("com.apple.keylayout.German")));
    assert!(!roles::is_ansi_layout(Some("com.apple.keylayout.Dvorak")));
}

#[test]
fn the_services_dump_parser_reads_quoted_values_whole() {
    let dump = r#"NSKeyEquivalent = { default = "@;"; de = "$@}"; fr = "@\""; };
        NSKeyEquivalent = { default = "@K"; };"#;
    let got = roles::service_equivalents(dump);
    assert!(got.contains(&"@;".to_string()), "{got:?}");
    assert!(got.contains(&"$@}".to_string()), "{got:?}");
    assert!(got.contains(&"@K".to_string()), "{got:?}");
}
