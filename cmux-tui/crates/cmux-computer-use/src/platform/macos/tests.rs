//! Unit tests of the pure pieces, and an `#[ignore]` smoke of the real
//! desktop (run it on a Mac with a logged-in console session:
//! `cargo test -p cmux-computer-use -- --ignored macos_desktop_smoke --nocapture`).

use super::*;
use crate::desktop::{Button, Point, Rect};
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
    let (left, _) = keymap::key_code(&crate::keys::Key::Left).unwrap();
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
impl crate::desktop::MenuGuard for PolicyGuard {
    fn app_blocked(&self, id: &str, name: &str) -> bool {
        crate::policy::is_blocked(&self.0, &crate::policy::TargetApp { id: id.into(), name: name.into() }).is_some()
    }
    fn denies_any(&self) -> bool {
        !self.0.denied_apps.is_empty()
    }
}

#[test]
fn a_denied_app_is_never_reachable_through_recent_items_open_with_or_services() {
    let guard = PolicyGuard(crate::policy::PolicyConfig::default()); // denies Terminal, Keychain, ...
    let path = |p: &[&str]| p.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    let resolve = |name: &str| match name {
        "Terminal" => Some("com.apple.Terminal".to_string()),
        "TextEdit" => Some("com.apple.TextEdit".to_string()),
        "Keychain Access" => Some("com.apple.keychainaccess".to_string()),
        _ => None,
    };
    let blocked = |p: &[&str], title: &str| roles::menu_item_blocked(&guard, &path(p), title, &resolve);
    // Apple menu > Recent Items: a denied app is hidden and refused; an allowed one is not.
    assert!(blocked(&["Apple", "Recent Items"], "Terminal"));
    assert!(blocked(&["Apple", "Recent Items"], "Keychain Access"));
    assert!(!blocked(&["Apple", "Recent Items"], "TextEdit"));
    // A recent document (its app cannot be told) is refused while any app is denied.
    assert!(blocked(&["Apple", "Recent Items"], "notes.txt"));
    // Finder File > Open With: "Terminal" and "Terminal (default)" alike.
    assert!(blocked(&["File", "Open With"], "Terminal (default)"));
    assert!(!blocked(&["File", "Open With"], "TextEdit (default)"));
    // Services can hand the selection to any app: refused while any app is denied.
    assert!(blocked(&["TextEdit", "Services"], "New Terminal at Folder"));
    // Everything else in the Apple menu stays reachable (the person allows it).
    assert!(!blocked(&["Apple"], "About This Mac"));
    assert!(!blocked(&["File"], "Save"));
    // With an empty deny list nothing is refused (protected apps still are).
    let open = PolicyGuard(crate::policy::PolicyConfig { denied_apps: vec![], ..Default::default() });
    let blocked_open = |p: &[&str], title: &str| roles::menu_item_blocked(&open, &path(p), title, &resolve);
    assert!(!blocked_open(&["Apple", "Recent Items"], "Terminal"));
    assert!(!blocked_open(&["TextEdit", "Services"], "New Terminal at Folder"));
    assert_eq!(roles::entry_app_name("Xcode (16.4)"), "Xcode");
    assert_eq!(roles::entry_app_name("Preview"), "Preview");
}
