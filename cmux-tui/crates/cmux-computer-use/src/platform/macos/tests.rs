//! Unit tests of the pure pieces, and an `#[ignore]` smoke of the real
//! desktop (run it on a Mac with a logged-in console session:
//! `cargo test -p cmux-computer-use -- --ignored macos_desktop_smoke --nocapture`).

use super::*;
use crate::desktop::{Button, MenuGuard, Point, Rect};
use crate::keys::{Key, KeyCombo, Modifier};

/// A pid-routed scroll names its window and carries the point inside it:
/// global (72, 174) in a window at (60, 80) is (12, 94) there. Before the
/// fix only fields 91/92 were set and AppKit dropped every scroll posted to a
/// background window.
#[test]
fn pid_mouse_events_name_the_window_and_its_local_point() {
    let stamp =
        roles::pid_mouse_stamp(290, Point { x: 72.0, y: 174.0 }, Some(Point { x: 60.0, y: 80.0 }));
    assert_eq!(stamp.window_number, 290);
    assert_eq!(stamp.local, Some(Point { x: 12.0, y: 94.0 }));
    // A window whose origin cannot be read still gets its number.
    let unknown = roles::pid_mouse_stamp(7, Point { x: 1.0, y: 2.0 }, None);
    assert_eq!(unknown, roles::PidMouseStamp { window_number: 7, local: None });
}

/// Bugs 1 and 4: a plain background click presses a control through AX,
/// selects the row of a list item with no press (Finder's file name, a text
/// field with only AXConfirm/AXOpen), and posts events for everything else.
#[test]
fn background_click_on_a_hit_element() {
    use roles::{HitClick, hit_click};
    assert_eq!(hit_click("AXButton", true, false, false), HitClick::Press);
    assert_eq!(hit_click("AXCheckBox", true, true, false), HitClick::Press);
    assert_eq!(hit_click("AXLink", true, false, false), HitClick::Press);
    // Finder list view: the name field in a row, no AXPress.
    assert_eq!(hit_click("AXTextField", false, true, false), HitClick::Select);
    assert_eq!(hit_click("AXStaticText", false, true, false), HitClick::Select);
    // A text area takes the caret from events; a button without AXPress too.
    assert_eq!(hit_click("AXTextArea", false, false, false), HitClick::Events);
    assert_eq!(hit_click("AXButton", false, false, false), HitClick::Events);
    // A web area or group that happens to advertise a press is not a control.
    assert_eq!(hit_click("AXWebArea", true, false, false), HitClick::Events);
    assert_eq!(hit_click("AXGroup", true, false, false), HitClick::Events);
    assert!(roles::is_label_role("AXStaticText") && !roles::is_label_role("AXButton"));
}

/// Bugs 2 and 3: a background chord whose matches are all disabled (the app
/// has no key window) gets its menus validated first; a blocked or enabled
/// match, or none, does not.
#[test]
fn a_background_chord_with_only_disabled_matches_needs_validation() {
    let m = |enabled, blocked| roles::ShortcutMatch {
        title: "Select All".into(),
        enabled,
        blocked,
        checked: true,
        unknown: false,
        unplaced: false,
    };
    assert!(roles::needs_menu_validation(&[m(false, false)]));
    assert!(roles::needs_menu_validation(&[m(false, false), m(false, false)]));
    assert!(!roles::needs_menu_validation(&[]));
    assert!(!roles::needs_menu_validation(&[m(true, false)]));
    assert!(!roles::needs_menu_validation(&[m(false, false), m(true, false)]));
    assert!(!roles::needs_menu_validation(&[m(false, true)]));
}

/// The window server records posted to the target's process: the window id
/// little-endian at 0x3C, the focus direction at 0x8A, the make-key flag and
/// mask for the make-key pair.
#[test]
fn activation_records_carry_the_window_and_direction() {
    let focus = activation::record(0x0D, 0x0102_0304, activation::FOCUS_IN);
    assert_eq!((focus[0x04], focus[0x08]), (0xF8, 0x0D));
    assert_eq!(&focus[0x3C..0x40], &[0x04, 0x03, 0x02, 0x01]);
    assert_eq!(focus[0x8A], 0x01);
    assert_eq!(focus[0x3A], 0);
    let out = activation::record(0x0D, 7, activation::FOCUS_OUT);
    assert_eq!(out[0x8A], 0x02);
    let make = activation::record(0x01, 7, 0);
    assert_eq!((make[0x08], make[0x3A], make[0x8A]), (0x01, 0x10, 0));
    assert!(make[0x20..0x30].iter().all(|b| *b == 0xFF));
}

/// Review 9: a hit element that is a menu item the deny list blocks is
/// refused before anything is pressed, whatever it offers.
#[test]
fn a_blocked_hit_element_is_refused_not_pressed() {
    use roles::{HitClick, hit_click};
    assert_eq!(hit_click("AXMenuItem", true, false, true), HitClick::Refuse);
    assert_eq!(hit_click("AXMenuItem", true, false, false), HitClick::Press);
    assert_eq!(hit_click("AXTextField", false, true, true), HitClick::Refuse);
}

/// Review 9: the hit-test is used only for an on-screen window and an
/// element inside the target window (a sibling window's element at an
/// overlapping point is not acted on).
#[test]
fn the_hit_test_keeps_only_the_target_window() {
    assert!(roles::hit_usable(true, true));
    assert!(!roles::hit_usable(true, false));
    assert!(!roles::hit_usable(false, true));
}

/// Review 3: a hit-test press falls back to events only when the element
/// did not take it; a timeout or cannot-complete may have run it.
#[test]
fn a_press_that_may_have_run_is_not_clicked_again() {
    assert!(roles::press_error_falls_back(-25206)); // action unsupported
    assert!(roles::press_error_falls_back(-25205)); // attribute unsupported
    assert!(roles::press_error_falls_back(-25201)); // illegal argument
    assert!(!roles::press_error_falls_back(-25204)); // cannot complete (timeout)
    assert!(!roles::press_error_falls_back(-25200)); // failure
}



/// Review 1: the key-in-app scope runs only on a verified macOS major
/// (26) and never with CMUX_CU_BG_ACTIVATE=0; macOS 27 was not verified.
#[test]
fn the_key_in_app_scope_is_gated() {
    assert!(activation::gate("26.6.2", None));
    assert!(activation::gate("26.0", Some("1")));
    assert!(!activation::gate("26.6.2", Some("0")));
    assert!(!activation::gate("27.0.1", None));
    assert!(!activation::gate("15.7", None));
    assert!(!activation::gate("", None));
}


/// Review 2 (B, 3): inside a scope an item is pressed only while the scope
/// is live and focus is on the target window, and never a Services item.
#[test]
fn a_primed_press_needs_a_live_scope_on_the_target_and_no_service() {
    assert_eq!(roles::primed_press(true, true, false), Ok(()));
    assert!(roles::primed_press(false, true, false).is_err());
    assert!(roles::primed_press(true, false, false).is_err());
    assert!(roles::primed_press(true, true, true).unwrap_err().contains("Services"));
}

/// Review 2 (4): the person's front app is never entered; a scope on the
/// same window joins; one on another window of the app refuses.
#[test]
fn key_in_app_entry_decisions() {
    use activation::{Entry, entry};
    assert_eq!(entry(None, 7, true), Entry::Refuse);
    assert_eq!(entry(Some((7, 1)), 7, true), Entry::Refuse);
    assert_eq!(entry(None, 7, false), Entry::Post);
    assert_eq!(entry(Some((7, 2)), 7, false), Entry::Join);
    assert_eq!(entry(Some((9, 1)), 7, false), Entry::Refuse);
    assert_eq!(entry(Some((9, 0)), 7, false), Entry::Post);
}

/// A fake system for the scope's lifecycle.
#[derive(Default)]
struct FakeOs {
    front: std::cell::Cell<Option<i32>>,
    /// Front pid after this many posts (the person switches mid-scope).
    front_after_posts: std::cell::Cell<Option<(usize, i32)>>,
    posts: std::cell::RefCell<Vec<(u8, u32, u8)>>,
    windows: std::cell::RefCell<Vec<(u32, i32)>>,
    fail_posts: std::cell::Cell<bool>,
    epoch: std::cell::Cell<u64>,
}

impl activation::ScopeOs for FakeOs {
    fn front_pid(&self) -> Option<i32> {
        if let Some((n, pid)) = self.front_after_posts.get()
            && self.posts.borrow().len() >= n
        {
            return Some(pid);
        }
        self.front.get()
    }
    fn psn_of(&self, window: u32) -> Option<activation::Psn> {
        self.windows.borrow().iter().find(|w| w.0 == window).map(|w| [w.1 as u32, 0])
    }
    fn post(&self, _psn: &activation::Psn, r: &[u8; 0xF8]) -> bool {
        if self.fail_posts.get() {
            return false;
        }
        let w = u32::from_le_bytes([r[0x3C], r[0x3D], r[0x3E], r[0x3F]]);
        self.posts.borrow_mut().push((r[0x08], w, r[0x8A]));
        true
    }
    fn window_exists(&self, window: u32, pid: i32) -> bool {
        self.windows.borrow().iter().any(|w| *w == (window, pid))
    }
    fn any_window(&self, pid: i32) -> Option<u32> {
        self.windows.borrow().iter().find(|w| w.1 == pid).map(|w| w.0)
    }
    fn stop_epoch(&self) -> u64 {
        self.epoch.get()
    }
}

fn fake(windows: &[(u32, i32)]) -> FakeOs {
    let os = FakeOs::default();
    os.front.set(Some(1)); // the person's app
    *os.windows.borrow_mut() = windows.to_vec();
    os
}

const IN: (u8, u8) = (activation::RECORD_FOCUS, activation::FOCUS_IN);

/// Entering posts focus-in and the make-key pair for the window; the end
/// posts one focus-out for it.
#[test]
fn a_scope_enters_and_hands_back_once() {
    let os = fake(&[(10, 5)]);
    let reg = activation::Registry::new();
    let key = activation::KeyInApp::enter_with(&os, &reg, 10, 5).expect("entered");
    assert!(key.live());
    assert_eq!(key.end(), activation::Ended::Fine);
    let posts = os.posts.borrow().clone();
    assert_eq!(posts.len(), 4, "{posts:?}");
    assert_eq!((posts[0].0, posts[0].2), IN);
    assert_eq!(posts[3], (activation::RECORD_FOCUS, 10, activation::FOCUS_OUT));
}

/// Early returns: the person's front app, an unknown window, a failed post
/// (then what was posted is handed back).
#[test]
fn a_scope_refuses_the_front_app_and_unknown_windows() {
    let os = fake(&[(10, 5)]);
    let reg = activation::Registry::new();
    os.front.set(Some(5));
    assert!(activation::KeyInApp::enter_with(&os, &reg, 10, 5).is_none());
    assert!(os.posts.borrow().is_empty());
    os.front.set(Some(1));
    assert!(activation::KeyInApp::enter_with(&os, &reg, 99, 5).is_none());
    os.fail_posts.set(true);
    assert!(activation::KeyInApp::enter_with(&os, &reg, 10, 5).is_none());
    os.fail_posts.set(false);
    // Nothing left open: a new scope enters.
    assert!(activation::KeyInApp::enter_with(&os, &reg, 10, 5).is_some());
}

/// Two sessions on one app: the same window joins (no second records, one
/// hand-back after the last); another window is refused.
#[test]
fn a_join_shares_the_window_and_another_window_is_refused() {
    let os = fake(&[(10, 5), (11, 5)]);
    let reg = activation::Registry::new();
    let a = activation::KeyInApp::enter_with(&os, &reg, 10, 5).expect("first");
    assert!(activation::KeyInApp::enter_with(&os, &reg, 11, 5).is_none(), "other window");
    let b = activation::KeyInApp::enter_with(&os, &reg, 10, 5).expect("join");
    assert_eq!(os.posts.borrow().len(), 3);
    drop(a);
    assert_eq!(os.posts.borrow().len(), 3, "still open: no hand-back");
    drop(b);
    assert_eq!(os.posts.borrow().len(), 4);
}

/// The person switching to the target app mid-entry aborts it, and no
/// focus-out goes to the app they are now using; a live scope stops being
/// live when they switch, or on a Stop.
#[test]
fn the_person_switching_to_the_target_aborts_the_scope() {
    let os = fake(&[(10, 5)]);
    let reg = activation::Registry::new();
    os.front_after_posts.set(Some((1, 5)));
    assert!(activation::KeyInApp::enter_with(&os, &reg, 10, 5).is_none());
    let posts = os.posts.borrow().clone();
    assert_eq!(posts.len(), 1, "stopped after the first record: {posts:?}");
    assert!(posts.iter().all(|p| p.2 != activation::FOCUS_OUT));
    os.front_after_posts.set(None);
    os.posts.borrow_mut().clear();
    let key = activation::KeyInApp::enter_with(&os, &reg, 10, 5).expect("entered");
    os.front.set(Some(5));
    assert!(!key.live());
    assert!(!key.wait_until(std::time::Duration::from_secs(1), &|| true));
    assert_eq!(key.end(), activation::Ended::Fine);
    assert!(os.posts.borrow().iter().all(|p| p.2 != activation::FOCUS_OUT));
    os.front.set(Some(1));
    let key = activation::KeyInApp::enter_with(&os, &reg, 10, 5).expect("entered");
    os.epoch.set(1); // the person pressed Stop
    assert!(!key.live());
}

/// The window closed during the scope (a primed File > Close): the hand-back
/// names another window of the app, from the full list (off screen
/// included); with none left it reports the failure.
#[test]
fn the_hand_back_names_a_window_that_still_exists() {
    let os = fake(&[(10, 5), (12, 5)]);
    let reg = activation::Registry::new();
    let key = activation::KeyInApp::enter_with(&os, &reg, 10, 5).expect("entered");
    os.windows.borrow_mut().retain(|w| w.0 != 10);
    assert_eq!(key.end(), activation::Ended::Fine);
    assert_eq!(os.posts.borrow().last(), Some(&(activation::RECORD_FOCUS, 12, activation::FOCUS_OUT)));
    let key = activation::KeyInApp::enter_with(&os, &reg, 12, 5).expect("entered");
    os.windows.borrow_mut().clear();
    assert_eq!(key.end(), activation::Ended::HandBackFailed);
    // Notes are appended, never replaced.
    let mut note = "pressed".to_string();
    activation::append_note(&mut note, activation::HAND_BACK_FAILED);
    activation::append_note(&mut note, activation::HAND_BACK_FAILED);
    assert!(note.starts_with("pressed; ") && note.matches("hand-back").count() == 1);
}

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
    // A context menu is computerUse.menus's call, not always refused.
    assert!(!roles::is_foreground_action("AXShowMenu"));
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
fn menu_bar_roles_and_the_open_action() {
    assert!(roles::is_menu_bar("AXMenuBarItem") && roles::is_menu_bar("AXMenuExtra"));
    assert!(!roles::is_menu_bar("AXPopUpButton") && !roles::is_menu_bar("AXMenuItem"));
    let acts = |a: &[&str]| a.iter().map(|s| (*s).to_string()).collect::<Vec<_>>();
    assert_eq!(roles::open_action(&acts(&["AXShowMenu", "AXPress"])), Some("AXPress"));
    assert_eq!(roles::open_action(&acts(&["AXShowMenu"])), Some("AXShowMenu"));
    assert_eq!(roles::open_action(&acts(&["AXConfirm"])), None);
}

#[test]
fn menu_refusals_name_the_setting() {
    assert!(roles::menu_refusal("AXPopUpButton").contains("computerUse.menus"));
    assert!(roles::CONTEXT_MENU_REFUSAL.contains("computerUse.menus"));
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
        keymap::menu_item_matches(
            &KeyCombo::parse(combo).unwrap(),
            &keymap::menu_item_key(ch, vk, None),
            mods,
        )
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
        crate::policy::is_blocked(
            &self.0,
            &crate::policy::TargetApp { id: id.into(), name: name.into() },
        )
        .is_some()
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

fn blocked_in(
    guard: &PolicyGuard,
    top: Option<usize>,
    depth: usize,
    siblings: &[&str],
    title: &str,
) -> bool {
    let siblings: Vec<String> = siblings.iter().map(|s| s.to_string()).collect();
    let ctx =
        roles::MenuItemContext { title, top_index: top, depth, siblings: &siblings, launch: None };
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
    assert!(blocked_in(
        &guard,
        Some(1),
        2,
        &["Neues Terminal beim Ordner", "Notiz erstellen"],
        "Notiz erstellen"
    ));
    // Öffnen mit (Open With), in a File menu: a list of apps, found by its items.
    let open_with = ["TextEdit (Standard)", "Terminal", "Vorschau", "Andere …"];
    assert!(blocked_in(&guard, Some(3), 2, &open_with, "Terminal"));
    assert!(!blocked_in(&guard, Some(3), 2, &open_with, "TextEdit (Standard)"));
    assert!(!blocked_in(&guard, Some(3), 2, &open_with, "Vorschau"));
    // Apple menu "Systemeinstellungen…" launches a denied app: blocked by the app it names.
    assert!(blocked_in(
        &guard,
        Some(0),
        1,
        &["Über diesen Mac", "Systemeinstellungen…", "Sperren"],
        "Systemeinstellungen…"
    ));
    assert!(blocked_in(&guard, Some(0), 1, &[], "System Settings…"));
    // macOS adds a note after the name: still the same app.
    assert!(blocked_in(&guard, Some(0), 1, &[], "System Settings…, 1 update"));
    assert!(blocked_in(&guard, Some(0), 1, &[], "Systemeinstellungen …, 1 Update"));
    assert_eq!(
        roles::menu_name_candidates("System Settings…, 1 update"),
        vec!["System Settings…, 1 update", "System Settings"]
    );
    // The rest of the Apple menu stays reachable (the person allows it).
    for t in
        ["Über diesen Mac", "Bildschirm sperren", "Ruhezustand", "Abmelden …", "Sofort beenden …"]
    {
        assert!(!blocked_in(&guard, Some(0), 1, &[], t), "{t}");
    }
    // Same-name apps: one denied copy blocks the name; a version suffix in a launch list is ambiguous.
    assert!(blocked_in(&guard, Some(3), 2, &["Ghostty", "Xcode (16.4)"], "Ghostty"));
    assert!(blocked_in(
        &guard,
        Some(3),
        2,
        &["Ghostty", "Xcode (16.4)", "Xcode (17.0)"],
        "Xcode (16.4)"
    ));
    // Ordinary menus are untouched, also when an item happens to be in a submenu.
    assert!(!blocked_in(&guard, Some(2), 1, &["Sichern", "Drucken …"], "Sichern"));
    assert!(!blocked_in(&guard, Some(4), 2, &["Fett", "Kursiv", "Unterstrichen"], "Fett"));
    // With an empty deny list only protected apps are blocked.
    let open =
        PolicyGuard(crate::policy::PolicyConfig { denied_apps: vec![], ..Default::default() });
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
    let m = |t: &str, enabled: bool, blocked: bool| M {
        title: t.into(),
        enabled,
        blocked,
        checked: true,
        unknown: false,
        unplaced: false,
    };
    assert_eq!(roles::pick_shortcut(&[]), P::None);
    assert_eq!(roles::pick_shortcut(&[m("A", false, false), m("B", true, false)]), P::Press(1));
    assert_eq!(roles::pick_shortcut(&[m("A", false, false)]), P::Disabled("A".into()));
    // A blocked first enabled match refuses: a later item must not run in its place.
    assert_eq!(
        roles::pick_shortcut(&[m("Svc", true, true), m("B", true, false)]),
        P::Blocked("Svc".into())
    );
    // A blocked disabled item is passed over like any disabled one.
    assert_eq!(roles::pick_shortcut(&[m("Svc", false, true), m("B", true, false)]), P::Press(1));
    // Unmatched chords: see chords_are_held_to_the_deny_list_in_both_deliveries.
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
    let (slots, truncated) =
        roles::breadth_first(0u32, 100, 10, |n, _| (*n != 4).then(|| kids(*n)));
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
    assert_eq!(keymap::service_shortcut("@\u{f704}", true), Some((f1, keymap::FLAG_COMMAND)));
    assert!(roles::is_key_equivalent("$^@C"));
    assert!(!roles::is_key_equivalent("New Workspace"));
    let (b, _) = keymap::char_key('b').unwrap();
    let (c, _) = keymap::char_key('c').unwrap();
    // "B" is ⇧⌘B (a capital means Shift; Command is implied).
    assert_eq!(
        keymap::service_shortcut("B", true),
        Some((b, keymap::FLAG_COMMAND | keymap::FLAG_SHIFT))
    );
    assert_eq!(
        keymap::service_shortcut("$^@C", true),
        Some((c, keymap::FLAG_COMMAND | keymap::FLAG_SHIFT | keymap::FLAG_CONTROL))
    );
    // A lone "@" is a key now (see marker_only_and_escaped_services_keys_parse).
    let services = vec![keymap::service_shortcut("B", true).unwrap()];
    assert!(keymap::is_service_shortcut(b, keymap::FLAG_COMMAND | keymap::FLAG_SHIFT, &services));
    assert!(!keymap::is_service_shortcut(b, keymap::FLAG_COMMAND, &services));
    let (seven, _) = keymap::char_key('7').unwrap();
    assert!(!keymap::is_service_shortcut(
        seven,
        keymap::FLAG_COMMAND | keymap::FLAG_SHIFT,
        &services
    ));
}

#[test]
fn shifted_punctuation_matches_its_menu_item() {
    use crate::keys::KeyCombo;
    let m = |combo: &str, ch: &str, mods: i64| {
        keymap::menu_item_matches(
            &KeyCombo::parse(combo).unwrap(),
            &keymap::menu_item_key(Some(ch), None, None),
            mods,
        )
    };
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
    // An upper-case chord letter is a Shift chord, as the keys it posts are
    // (key_codes) and as xdotool resolves "super+T": both paths agree.
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
    let ctx = roles::MenuItemContext {
        title: "TextEdit",
        top_index: Some(0),
        depth: 2,
        siblings: &[],
        launch: None,
    };
    assert!(roles::menu_item_blocked(&guard, &ctx, &pending));
    // With nothing denied too: the protected apps always apply.
    let open =
        PolicyGuard(crate::policy::PolicyConfig { denied_apps: vec![], ..Default::default() });
    assert!(roles::menu_item_blocked(&open, &ctx, &pending));
}

#[test]
fn the_services_check_knows_which_keys_each_layout_places() {
    use roles::Layout as L;
    for id in
        ["com.apple.keylayout.US", "com.apple.keylayout.ABC", "com.apple.keylayout.Australian"]
    {
        assert_eq!(roles::layout_of(Some(id), true), L::Ansi);
    }
    assert_eq!(roles::layout_of(Some("com.apple.keylayout.British"), true), L::LettersDigits);
    assert_eq!(roles::layout_of(Some("com.apple.keylayout.British-PC"), true), L::LettersDigits);
    assert_eq!(roles::layout_of(Some("com.apple.keylayout.German"), true), L::Other);
    assert_eq!(roles::layout_of(Some("com.apple.keylayout.Dvorak"), true), L::Other);
    // Nothing recorded: U.S. only on a default install; otherwise fail closed.
    assert_eq!(roles::layout_of(None, false), L::Ansi);
    assert_eq!(roles::layout_of(None, true), L::Other);
    // Keys with the same code on every layout are placed on any layout,
    // German and Dvorak included: alt+left, cmd+left, F5, ctrl+return.
    for key in [
        Key::Left,
        Key::Right,
        Key::Up,
        Key::Down,
        Key::F(5),
        Key::Return,
        Key::Tab,
        Key::Space,
        Key::Escape,
        Key::Delete,
        Key::Backspace,
        Key::Home,
        Key::End,
        Key::PageUp,
        Key::PageDown,
    ] {
        for shift in [false, true] {
            assert!(roles::layout_places(&key, shift, L::Other), "{key:?}");
        }
    }
    // Letters: ANSI and British; not German (Y and Z swap) or Dvorak.
    let e = Key::Char('e');
    assert!(
        roles::layout_places(&e, false, L::Ansi)
            && roles::layout_places(&e, true, L::LettersDigits)
    );
    assert!(!roles::layout_places(&e, false, L::Other));
    // Digits: unshifted on British; shifted (Shift-3 is £ there) only on ANSI.
    let three = Key::Char('3');
    assert!(roles::layout_places(&three, false, L::LettersDigits));
    assert!(!roles::layout_places(&three, true, L::LettersDigits));
    assert!(roles::layout_places(&three, true, L::Ansi));
    // Punctuation: only on ANSI.
    let hash = Key::Char('\\');
    assert!(roles::layout_places(&hash, false, L::Ansi));
    assert!(!roles::layout_places(&hash, false, L::LettersDigits));
}

#[test]
fn the_services_dump_parser_reads_quoted_values_whole() {
    let dump = r#"NSKeyEquivalent = { default = "@;"; de = "$@}"; fr = "@\""; };
        NSKeyEquivalent = { default = "@K"; };"#;
    let got = roles::service_equivalents(dump);
    assert!(got.contains(&"@;".to_string()), "{got:?}");
    assert!(got.contains(&"$@}".to_string()), "{got:?}");
    assert!(got.contains(&"@K".to_string()), "{got:?}");
    // Escaped quote and backslash decode to one character each.
    assert!(got.contains(&"@\"".to_string()), "{got:?}");
    let got = roles::service_equivalents(r#"NSKeyEquivalent = { default = "@\\"; de = "$@X" };"#);
    assert!(got.contains(&"@\\".to_string()), "{got:?}");
    // The last entry has no ";" before "}".
    assert!(got.contains(&"$@X".to_string()), "{got:?}");
    let got = roles::service_equivalents(r#"NSKeyEquivalent = { default = "@\101"; };"#);
    assert_eq!(got, vec!["@A".to_string()]);
}

#[test]
fn chords_are_held_to_the_deny_list_in_both_deliveries() {
    use roles::{ChordAction as A, ChordFacts, ServiceCheck as S, ShortcutMatch as M};
    let m = |t: &str, enabled: bool, blocked: bool| M {
        title: t.into(),
        enabled,
        blocked,
        checked: true,
        unknown: false,
        unplaced: false,
    };
    fn base(matches: &[M]) -> ChordFacts<'_> {
        ChordFacts {
            matches,
            complete: true,
            background: true,
            denies_any: true,
            layout_known: true,
            is_service: S::NoMatch,
        }
    }
    let undo = [m("Undo", true, false)];
    let off = [m("Undo", false, false)];
    // Foreground: posted whenever posting is safe, so the key view (a web
    // page's cmd+F, cmd+K) sees it first, as with the person's key.
    let fg = |m| ChordFacts { background: false, ..base(m) };
    assert_eq!(roles::decide_chord(&fg(&undo)), A::Post);
    assert_eq!(
        roles::decide_chord(&ChordFacts {
            denies_any: false,
            complete: false,
            layout_known: false,
            is_service: S::Unread,
            ..fg(&undo)
        }),
        A::Post
    );
    // ...and the app's item is pressed when posting is not safe: a Service
    // has the chord (VS Code's shift+cmd+F, Spotlight's Service), the walk is
    // incomplete, the layout cannot place it, or another match is blocked.
    let later_blocked = [m("Undo", true, false), m("Open in Simulator", true, true)];
    for f in [
        ChordFacts { is_service: S::Match, ..fg(&undo) },
        ChordFacts { is_service: S::Unread, ..fg(&undo) },
        ChordFacts { complete: false, ..fg(&undo) },
        ChordFacts { layout_known: false, ..fg(&undo) },
        ChordFacts { denies_any: false, ..fg(&later_blocked) },
        fg(&later_blocked),
    ] {
        assert_eq!(roles::decide_chord(&f), A::PressItem(0), "{f:?}");
    }
    // Foreground with no enabled match: the background rules (refused when
    // a Service has it).
    assert_eq!(
        roles::decide_chord(&ChordFacts { is_service: S::Match, ..fg(&[]) }),
        A::Refuse(roles::REFUSE_SERVICE)
    );
    assert!(
        roles::needs_key_checks(&undo, true, false) && !roles::needs_key_checks(&undo, true, true)
    );
    assert!(
        !roles::needs_key_checks(&later_blocked, true, false)
            && !roles::needs_key_checks(&undo, false, false)
    );
    // Background: the first enabled, unblocked match is pressed through AX,
    // deny list or not, whatever the walk, layout and Services say (no key
    // is posted, so nothing else can take the chord).
    for denies_any in [false, true] {
        let f = ChordFacts {
            denies_any,
            complete: false,
            layout_known: false,
            is_service: S::Match,
            ..base(&undo)
        };
        assert_eq!(roles::decide_chord(&f), A::PressItem(0));
    }
    // Disabled matches before it do not run, blocked or not.
    let earlier_off = [m("Launch Simulator", false, true), m("Undo", true, false)];
    assert_eq!(roles::decide_chord(&base(&earlier_off)), A::PressItem(1));
    // The first enabled match is blocked: refused, with nothing denied too
    // (a protected app's item).
    let blocked = [m("Open in Simulator", true, true)];
    for denies_any in [false, true] {
        assert_eq!(
            roles::decide_chord(&ChordFacts { denies_any, ..base(&blocked) }),
            A::Refuse(roles::REFUSE_BLOCKED)
        );
    }
    // Only disabled matches, one blocked: a posted key is revalidated at key
    // time, so it is refused.
    let off_blocked = [m("Undo", false, false), m("Open in Simulator", false, true)];
    for denies_any in [false, true] {
        assert_eq!(
            roles::decide_chord(&ChordFacts { denies_any, ..base(&off_blocked) }),
            A::Refuse(roles::REFUSE_BLOCKED)
        );
    }
    // Only disabled matches, none blocked (cmd+c with nothing selected), or
    // none at all (cmd+shift+t where no item has it): posted like the
    // person's key once the checks pass; a posted chord keeps its Shift.
    for matches in [&off[..], &[]] {
        assert_eq!(roles::decide_chord(&base(matches)), A::Post);
        // Nothing denied: posted as typed, whatever the walk, layout or Services say.
        let f = ChordFacts {
            denies_any: false,
            complete: false,
            layout_known: false,
            is_service: S::Unread,
            ..base(matches)
        };
        assert_eq!(roles::decide_chord(&f), A::Post);
        // Something denied: the walk, the layout and Services, in that order.
        assert!(
            roles::needs_key_checks(matches, true, true)
                && !roles::needs_key_checks(matches, false, true)
        );
        assert_eq!(
            roles::decide_chord(&ChordFacts { complete: false, ..base(matches) }),
            A::Refuse(roles::REFUSE_TOO_DEEP)
        );
        assert_eq!(
            roles::decide_chord(&ChordFacts { layout_known: false, ..base(matches) }),
            A::Refuse(roles::REFUSE_LAYOUT)
        );
        assert_eq!(
            roles::decide_chord(&ChordFacts { is_service: S::Match, ..base(matches) }),
            A::Refuse(roles::REFUSE_SERVICE)
        );
        assert_eq!(
            roles::decide_chord(&ChordFacts { is_service: S::Unread, ..base(matches) }),
            A::Refuse(roles::REFUSE_SERVICES_UNREAD)
        );
    }
    assert!(!roles::needs_key_checks(&undo, true, true));
}

#[test]
fn marker_only_and_escaped_services_keys_parse() {
    assert!(roles::is_key_equivalent("@$"));
    assert!(roles::is_key_equivalent("@"));
    let (four, _) = keymap::char_key('4').unwrap();
    assert_eq!(
        keymap::service_shortcut("@$", true),
        Some((four, keymap::FLAG_COMMAND | keymap::FLAG_SHIFT))
    );
    // \U0041 decodes to "A"; quoted content is verbatim, so "@\r", "\t",
    // " " and a lone "@" are keys and kept.
    let got = roles::service_equivalents(
        r#"NSKeyEquivalent = { default = "@\U0041"; a = "@\r"; b = "\t"; c = " "; d = "@"; e = "@$\r"; };"#,
    );
    for want in ["@A", "@\r", "\t", " ", "@", "@$\r"] {
        assert!(got.contains(&want.to_string()), "{want:?} in {got:?}");
    }
    assert_eq!(
        keymap::service_shortcut("@$\r", true),
        Some((keymap::KEY_RETURN, keymap::FLAG_COMMAND | keymap::FLAG_SHIFT))
    );
    assert_eq!(keymap::service_shortcut(" ", true), Some((49, keymap::FLAG_COMMAND)));
    // A lone "@" (a service's own key) is the "@" key, Command implied.
    let (two, _) = keymap::char_key('2').unwrap();
    assert_eq!(
        keymap::service_shortcut("@", true),
        Some((two, keymap::FLAG_COMMAND | keymap::FLAG_SHIFT))
    );
    // \\U is decoded once: "\\\\U0041" is a backslash then "U0041".
    let got = roles::service_equivalents(r#"NSKeyEquivalent = { default = "\\U0041"; };"#);
    assert!(got.is_empty(), "{got:?}");
}

#[test]
fn services_keys_on_non_character_keys_are_placed() {
    let code = |k: Key| keymap::key_code(&k).unwrap().0;
    let cmd = keymap::FLAG_COMMAND;
    let alt = keymap::FLAG_ALTERNATE;
    assert_eq!(keymap::service_shortcut("~\u{7f}", true), Some((code(Key::Backspace), cmd | alt)));
    assert_eq!(keymap::service_shortcut("\u{1b}", true), Some((code(Key::Escape), cmd)));
    assert_eq!(keymap::service_shortcut("\u{f702}", true), Some((code(Key::Left), cmd)));
    assert_eq!(keymap::service_shortcut("\u{f72d}", true), Some((code(Key::PageDown), cmd)));
    assert_eq!(keymap::service_shortcut("\u{f728}", true), Some((code(Key::Delete), cmd)));
    assert_eq!(keymap::service_shortcut("\u{f717}", true), Some((code(Key::F(20)), cmd)));
    // F21..F24 (no Mac key) are placed where no chord lands, not dropped.
    assert_eq!(keymap::service_shortcut("\u{f71b}", true), Some((keymap::NO_KEY, cmd)));
    // Help is placed on its own key (no chord cmux sends uses it); a key no
    // posted chord can produce (a non-ANSI letter, Insert) is placed at
    // NO_KEY, not dropped and not a failed read.
    assert_eq!(keymap::service_shortcut("\u{f746}", true), Some((114, cmd)));
    assert_eq!(keymap::service_shortcut("\u{f727}", true), Some((keymap::NO_KEY, cmd)));
    assert_eq!(keymap::service_shortcut("@\u{f6}", false), Some((keymap::NO_KEY, cmd)));
    // The person's assignments carry Command only where they say "@".
    let (t, _) = keymap::char_key('t').unwrap();
    assert_eq!(keymap::service_shortcut("^~t", false), Some((t, keymap::FLAG_CONTROL | alt)));
    assert_eq!(keymap::service_shortcut("@t", false), Some((t, cmd)));
}

#[test]
fn person_services_shortcuts_are_placed() {
    let (t, _) = keymap::char_key('t').unwrap();
    assert_eq!(
        keymap::service_shortcut("@^t", false),
        Some((t, keymap::FLAG_COMMAND | keymap::FLAG_CONTROL))
    );
    assert_eq!(
        keymap::service_shortcut("^~\r", false),
        Some((keymap::KEY_RETURN, keymap::FLAG_CONTROL | keymap::FLAG_ALTERNATE))
    );
}

#[test]
fn a_missing_core_foundation_value_is_none_not_a_crash() {
    // A Copy/Create call that finds nothing returns NULL; taking it must not
    // release NULL (CFRelease(NULL) traps and took down the worker).
    assert!(sys::Cf::created(std::ptr::null()).is_none());
    assert!(sys::Cf::preference("cmuxNoSuchKey", "com.apple.HIToolbox").is_none());
    assert!(sys::Cf::preference("NSServicesStatus", "cmux.no.such.domain").is_none());
}

#[test]
fn menu_items_on_non_character_keys_are_matched() {
    use crate::keys::KeyCombo;
    let m = |combo: &str, ch: Option<&str>, vk: Option<i64>, glyph: Option<i64>| {
        keymap::menu_item_matches(
            &KeyCombo::parse(combo).unwrap(),
            &keymap::menu_item_key(ch, vk, glyph),
            0,
        )
    };
    // Finder's Move to Trash as AX reports it on macOS 26.6: the character is
    // a backspace control character, with the key code and the glyph.
    assert!(m("cmd+backspace", Some("\u{8}"), Some(51), Some(23)));
    // Only the glyph, or only the control character.
    assert!(m("cmd+backspace", None, None, Some(0x17)));
    assert!(m("cmd+backspace", Some("\u{8}"), None, None));
    assert!(m("cmd+left", None, None, Some(0x64)));
    assert!(m("cmd+return", None, None, Some(0x0B)));
    assert!(m("cmd+f5", None, None, Some(0x73)));
    // Not another key, and never a printable character's item.
    assert!(!m("cmd+delete", Some("\u{8}"), Some(51), Some(23)));
    assert!(!m("cmd+h", Some("\u{8}"), Some(51), Some(23)));
    assert!(m("cmd+h", Some("H"), None, None));
}

#[test]
fn every_way_ax_reports_a_non_character_key_is_matched_or_fails_closed() {
    use crate::keys::KeyCombo;
    let key = |ch: Option<&str>, vk: Option<i64>, glyph: Option<i64>| {
        keymap::menu_item_key(ch, vk, glyph)
    };
    let m = |combo: &str, k: &keymap::MenuItemKey| {
        keymap::menu_item_matches(&KeyCombo::parse(combo).unwrap(), k, 0)
    };
    // Space comes as " ".
    assert!(m("cmd+space", &key(Some(" "), None, None)));
    // Option instead of Command is another chord.
    assert!(!m("alt+space", &key(Some(" "), None, None)));
    // Function-key characters (U+F700-F8FF) are keys, not printable: cmd+up
    // (Finder's Enclosing Folder), F5, Home, Forward Delete.
    assert!(m("cmd+up", &key(Some("\u{f700}"), None, None)));
    assert!(m("cmd+f5", &key(Some("\u{f708}"), None, None)));
    assert!(m("cmd+home", &key(Some("\u{f729}"), None, None)));
    assert!(m("cmd+delete", &key(Some("\u{f728}"), None, None)));
    assert!(!m("cmd+down", &key(Some("\u{f700}"), None, None)));
    // Keypad Enter is 76 by character and by glyph alike.
    assert_eq!(key(Some("\u{3}"), None, None).codes, vec![76]);
    assert_eq!(key(None, None, Some(0x04)).codes, vec![76]);
    // F16-F19 glyphs.
    assert!(m("cmd+f16", &key(None, None, Some(0x8F))));
    assert!(m("cmd+f19", &key(None, None, Some(0x92))));
    // Sources that disagree: either one matches (the check fails closed).
    let both = key(Some("\u{8}"), Some(117), None);
    assert!(m("cmd+backspace", &both) && m("cmd+delete", &both));
    // A key equivalent no table places is reported, not dropped: an unknown
    // glyph, a control character with no key (backtab), two characters.
    assert!(key(None, None, Some(0x05)).unplaceable);
    // Backtab is shift+Tab: placed on Tab, with its Shift.
    let backtab = key(Some("\u{19}"), None, None);
    assert!(!backtab.unplaceable && backtab.codes == vec![48] && backtab.implied_shift);
    assert!(m("cmd+shift+tab", &backtab) && !m("cmd+tab", &backtab));
    assert_eq!(
        keymap::service_shortcut("@\u{19}", false),
        Some((48, keymap::FLAG_COMMAND | keymap::FLAG_SHIFT))
    );
    // Option, Control and Command rule an item out whatever its key.
    let combo = |c: &str| KeyCombo::parse(c).unwrap();
    assert!(keymap::menu_mods_match(&combo("cmd+x"), 0));
    assert!(!keymap::menu_mods_match(&combo("cmd+x"), keymap::MENU_OPTION));
    assert!(!keymap::menu_mods_match(&combo("ctrl+x"), 0));
    assert!(keymap::menu_mods_match(
        &combo("ctrl+x"),
        keymap::MENU_CONTROL | keymap::MENU_NO_COMMAND
    ));
    assert!(key(Some("\u{1}"), None, None).unplaceable);
    assert!(key(Some("ab"), None, None).unplaceable);
    // No key equivalent at all, and glyph 0 ("no glyph").
    assert!(key(None, None, None).is_empty() && key(Some(""), None, Some(0)).is_empty());
    // A letter keeps matching by its character; its virtual key is not used.
    let copy = key(Some("C"), Some(8), None);
    assert!(m("cmd+c", &copy) && copy.codes.is_empty() && !copy.unplaceable);
}

#[test]
fn an_unchecked_match_is_never_pressed() {
    use roles::{ChordAction as A, ChordFacts, ServiceCheck as S, ShortcutMatch as M};
    // Its title could not be read, so it was not held to the protected apps;
    // with nothing denied (where it is not marked blocked) the key is posted.
    let unchecked = [M {
        title: String::new(),
        enabled: true,
        blocked: false,
        checked: false,
        unknown: false,
        unplaced: false,
    }];
    for background in [false, true] {
        let f = ChordFacts {
            matches: &unchecked,
            complete: false,
            background,
            denies_any: false,
            layout_known: true,
            is_service: S::NoMatch,
        };
        assert_eq!(roles::decide_chord(&f), A::Post);
    }
}

#[test]
fn only_escape_and_bare_arrows_reach_an_open_menu() {
    use roles::{OpenMenuKey, key_with_open_menu};
    let k = |s: &str| key_with_open_menu(&KeyCombo::parse(s).unwrap());
    assert_eq!(k("Escape"), OpenMenuKey::Close);
    assert_eq!(k("Down"), OpenMenuKey::Post);
    assert_eq!(k("Left"), OpenMenuKey::Post);
    for refused in ["Return", "space", "n", "shift+Down", "cmd+Down", "Tab", "shift+Escape"] {
        assert_eq!(k(refused), OpenMenuKey::Refuse, "{refused}");
    }
}

#[test]
fn a_walk_knows_where_it_is_in_menus_without_reading_more() {
    use ax::MenuPlace;
    // A window's pop-up button: not in a menu.
    assert_eq!(MenuPlace::below(None, Some("AXPopUpButton"), Some("")), None);
    // Its menu: the items are at depth 1, under no item.
    let menu = MenuPlace::below(None, Some("AXMenu"), None).unwrap();
    assert_eq!(menu, MenuPlace { in_menu: true, depth: 1, path: Some(vec![]) });
    // An item's submenu: depth 2, under that item.
    let item = MenuPlace::below(Some(&menu), Some("AXMenuItem"), Some("Services")).unwrap();
    assert!(!item.in_menu);
    let sub = MenuPlace::below(Some(&item), Some("AXMenu"), None).unwrap();
    assert_eq!(sub, MenuPlace { in_menu: true, depth: 2, path: Some(vec!["Services".into()]) });
    // A title that could not be read leaves the path unknown (fail closed).
    let unknown = MenuPlace::below(Some(&menu), Some("AXMenuItem"), None).unwrap();
    assert_eq!(MenuPlace::below(Some(&unknown), Some("AXMenu"), None).unwrap().path, None);
    // A role that could not be read is walked as a menu (its items checked).
    assert!(MenuPlace::below(None, None, None).unwrap().in_menu);
}

#[test]
fn appkit_launch_submenus_are_read_in_every_language() {
    let titles = workspace::launch_submenu_titles();
    for english in ["services", "open with", "share", "recent items", "quick actions"] {
        assert!(titles.iter().any(|t| t == english), "{english}: {titles:?}");
    }
    // Other languages come from the same tables (German: Dienste, Öffnen mit).
    assert!(titles.iter().any(|t| t == "dienste"), "{titles:?}");
    assert!(titles.iter().any(|t| t == "öffnen mit"), "{titles:?}");
}

#[test]
fn an_item_under_a_launch_submenu_or_an_unreadable_parent_is_in_a_launch_list() {
    let launch = vec!["services".to_string(), "quick actions".to_string()];
    let path = |p: &[&str]| p.iter().map(|s| (*s).to_string()).collect::<Vec<_>>();
    assert!(roles::in_opened_launch_list(Some(&path(&["Services"])), &launch));
    assert!(roles::in_opened_launch_list(Some(&path(&["Quick Actions\u{2026}"])), &launch));
    assert!(roles::in_opened_launch_list(Some(&path(&["Tags", "Services"])), &launch));
    assert!(!roles::in_opened_launch_list(Some(&path(&["Sort By"])), &launch));
    assert!(!roles::in_opened_launch_list(Some(&[]), &launch));
    assert!(roles::in_opened_launch_list(None, &launch));
    assert_eq!(
        roles::submenu_title_key(" Dienste-Einstellungen\u{a0}\u{2026} "),
        "dienste-einstellungen"
    );
}

#[test]
fn the_keyboard_handoff_arms_only_on_tested_macos_majors() {
    assert!(key_focus::tested_os("26.7"));
    assert!(key_focus::tested_os("12.0"));
    assert!(!key_focus::tested_os("27.0"));
    assert!(!key_focus::tested_os("11.7"));
    assert!(!key_focus::tested_os(""));
}

#[test]
fn a_pop_up_s_items_need_no_sibling_titles() {
    // A pop-up's items (depth 1) are checked from what the walk read: the
    // menu's titles are read (once per menu) only for a launch list at
    // depth 2 and more while something is denied, never per item.
    let d = MacDesktop::new(None);
    assert!(!d.opened_needs_siblings(1));
    assert!(!d.opened_needs_siblings(2), "nothing is denied without a guard");
    let config = crate::policy::PolicyConfig {
        denied_apps: vec!["com.apple.Terminal".into()],
        ..Default::default()
    };
    d.set_menu_guard(Arc::new(PolicyGuard(config)));
    assert!(!d.opened_needs_siblings(1));
    assert!(d.opened_needs_siblings(2));
    // While the app names load, items fail closed; wait for the index.
    let start = std::time::Instant::now();
    while !workspace::app_names_ready() && start.elapsed() < std::time::Duration::from_secs(60) {
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    assert!(workspace::app_names_ready());
    // 500 font names at depth 1: each is decided with no sibling list.
    let names: Vec<String> = (0..500).map(|i| format!("Font Family {i}")).collect();
    let source = workspace::NameSource::now();
    let hidden = names
        .iter()
        .filter(|n| {
            d.opened_item_known(
                &ax::OpenedItem {
                    title: n,
                    title_failed: false,
                    depth: 1,
                    path: Some(&[]),
                    launch: false,
                },
                &source,
            )
        })
        .count();
    assert_eq!(hidden, 0);
    // An unreadable title fails closed, whatever the deny list.
    assert!(d.opened_item_known(
        &ax::OpenedItem { title: "", title_failed: true, depth: 1, path: Some(&[]), launch: false },
        &source,
    ));
}

#[test]
fn a_helper_s_menu_is_taken_only_when_the_deny_list_allows_its_owner() {
    // This test process is not a regular app: a helper, as far as menus go.
    let me = std::process::id() as i32;
    let app = workspace::app_for_pid(me);
    let mine = app.as_ref().map(|a| a.id()).unwrap_or_default();
    // The target's own menu is always the call's.
    assert!(menus::may_be_targets_menu(me, me, None));
    let allow = PolicyGuard(crate::policy::PolicyConfig {
        denied_apps: vec!["com.example.other".into()],
        ..Default::default()
    });
    let deny = PolicyGuard(crate::policy::PolicyConfig {
        denied_apps: vec![mine.clone()],
        ..Default::default()
    });
    if app.is_some_and(|a| !a.is_regular()) {
        assert!(menus::may_be_targets_menu(me, 1, Some(&allow)));
        assert!(!menus::may_be_targets_menu(me, 1, Some(&deny)), "{mine}");
    } else {
        // Not listed as a running app: a helper only while nothing is denied.
        assert!(menus::may_be_targets_menu(me, 1, None));
        assert!(!menus::may_be_targets_menu(me, 1, Some(&allow)));
    }
}

#[test]
fn an_app_is_launched_by_its_name_as_well_as_its_bundle_id() {
    // Iteration 4, multi_apps/ab666698: the agent asked for "Notes" and was
    // told no installed app has that bundle id.
    assert_eq!(
        workspace::launch_targets("com.apple.TextEdit"),
        vec!["com.apple.TextEdit".to_string()]
    );
    assert_eq!(workspace::launch_targets("TextEdit"), vec!["com.apple.TextEdit".to_string()]);
    assert_eq!(workspace::launch_targets("TextEdit.app"), vec!["com.apple.TextEdit".to_string()]);
    assert!(workspace::launch_targets("cmux-no-such-app").is_empty());
    assert!(workspace::launch_targets("  ").is_empty());
}

#[test]
fn a_helper_s_menu_window_counts_only_over_the_target_s_window() {
    let win = Rect { x: 100.0, y: 100.0, width: 400.0, height: 300.0 };
    let over = Rect { x: 450.0, y: 200.0, width: 200.0, height: 300.0 };
    let elsewhere = Rect { x: 1200.0, y: 0.0, width: 200.0, height: 300.0 };
    assert!(menus::overlaps(&over, &win));
    assert!(!menus::overlaps(&elsewhere, &win));
    // Touching edges share no area.
    let touching = Rect { x: 500.0, y: 100.0, width: 50.0, height: 50.0 };
    assert!(!menus::overlaps(&touching, &win));
}

#[test]
fn the_target_s_keyboard_goes_back_when_its_menu_shows_or_when_the_call_ends() {
    use key_focus::{ReleasePlan, release_plan};
    // The menu shows: give it back now.
    assert_eq!(release_plan(true, true, true), ReleasePlan::Now);
    assert_eq!(release_plan(true, false, true), ReleasePlan::Now);
    // The target's notice was dropped but no menu showed (yet): not on a
    // timer, when the call disarms.
    assert_eq!(release_plan(false, true, true), ReleasePlan::AtDisarm);
    // A helper with no menu, or the person moved on: nothing to give back.
    assert_eq!(release_plan(false, false, true), ReleasePlan::Miss);
    assert_eq!(release_plan(true, true, false), ReleasePlan::Miss);
}

#[test]
fn a_submenu_counts_as_open_once_a_window_shows_or_its_items_change() {
    let s = |v: &[&str]| v.iter().map(|t| (*t).to_string()).collect::<Vec<_>>();
    // A placeholder that fills on open.
    assert!(menus::submenu_opened(&[1], &[1], &s(&["Item"]), &s(&["TextEdit", "Terminal"])));
    // A stale list that stays, but a new menu window showed.
    assert!(menus::submenu_opened(&[1], &[1, 2], &s(&["Xcode"]), &s(&["Xcode"])));
    // Nothing changed yet.
    assert!(!menus::submenu_opened(&[1], &[1], &s(&["Xcode"]), &s(&["Xcode"])));
    // Still empty, even with a window.
    assert!(!menus::submenu_opened(&[1], &[1, 2], &s(&[]), &s(&["", ""])));
}

#[test]
fn a_release_thread_acts_only_for_its_own_live_call() {
    use key_focus::{CallState, call_state};
    assert_eq!(call_state(7, true, 7), CallState::Live);
    // Its call ended (the menu was listed and closed, or never showed):
    // nothing is released by id any more.
    assert_eq!(call_state(7, false, 7), CallState::Ended);
    // A later call armed: an earlier call's thread or theft is ignored.
    assert_eq!(call_state(8, true, 7), CallState::Stale);
    assert_eq!(call_state(8, false, 7), CallState::Stale);
}

#[test]
fn a_target_theft_whose_menu_was_never_seen_goes_back_when_the_call_ends() {
    use key_focus::gives_back_at_disarm;
    // The call never saw its menu (it showed late, or a panel off the menu
    // layer took key focus) and the person's app is still in front.
    assert!(gives_back_at_disarm(false, true, true));
    // A menu that was seen and closed ended its theft itself.
    assert!(!gives_back_at_disarm(true, true, true));
    // Not a helper's, and not once the person moved on.
    assert!(!gives_back_at_disarm(false, false, true));
    assert!(!gives_back_at_disarm(false, true, false));
}

#[test]
fn a_theft_has_one_taker() {
    use key_focus::{Theft, take_theft};
    let t = Theft { thief: 42, front: 7, generation: 3, is_target: true };
    let mut slot = Some(t);
    // Another thief's, or another call's: not taken.
    assert_eq!(take_theft(&mut slot, 43, 3), None);
    assert_eq!(take_theft(&mut slot, 42, 2), None);
    // The release thread takes it; disarm then finds nothing to release.
    assert_eq!(take_theft(&mut slot, 42, 3), Some(t));
    assert_eq!(take_theft(&mut slot, 42, 3), None);
    assert_eq!(slot, None);
}

#[test]
fn a_new_menu_window_counts_only_over_the_target() {
    use key_focus::counts_as_call_menu;
    let target = Rect { x: 100.0, y: 100.0, width: 400.0, height: 300.0 };
    let over = Rect { x: 300.0, y: 200.0, width: 200.0, height: 300.0 };
    let menubar = Rect { x: 1200.0, y: 0.0, width: 300.0, height: 400.0 };
    // The thief's own menu window counts wherever it is.
    assert!(counts_as_call_menu((42, 101, 9, menubar), 42, &[], Some(target)));
    // A new window of another owner: only over the target's window.
    assert!(counts_as_call_menu((77, 101, 9, over), 42, &[], Some(target)));
    // The person's Control Center or Wi-Fi menu elsewhere never counts.
    assert!(!counts_as_call_menu((77, 101, 9, menubar), 42, &[], Some(target)));
    // One that was there when the call armed, or off the menu layer: no.
    assert!(!counts_as_call_menu((77, 101, 9, over), 42, &[9], Some(target)));
    assert!(!counts_as_call_menu((42, 0, 9, over), 42, &[], Some(target)));
}

#[test]
fn a_release_by_id_is_skipped_once_another_app_took_the_keyboard() {
    use key_focus::release_blocked;
    assert_eq!(release_blocked(false, true), None);
    assert!(release_blocked(true, true).is_some_and(|w| w.contains("another app")));
    assert!(release_blocked(false, false).is_some_and(|w| w.contains("tap")));
}

#[test]
fn the_keyboard_handoff_is_off_unless_its_variable_is_1() {
    assert!(!key_focus::handoff_enabled_by(None));
    assert!(!key_focus::handoff_enabled_by(Some("")));
    assert!(!key_focus::handoff_enabled_by(Some("0")));
    assert!(!key_focus::handoff_enabled_by(Some("true")));
    assert!(key_focus::handoff_enabled_by(Some("1")));
    // This test process does not set it: arm is a no-op (no tap, no thread).
    if std::env::var(key_focus::HANDOFF_ENV).ok().as_deref() != Some("1") {
        let frame = Rect { x: 0.0, y: 0.0, width: 10.0, height: 10.0 };
        assert!(!key_focus::arm(1, 2, frame, None));
        assert_eq!(key_focus::counts(), (0, 0));
    }
}

#[test]
fn a_menu_holding_the_keyboard_is_left_open_only_when_nothing_can_hide_under_it() {
    use menus::{HeldMenu, held_menu_decision as d};
    // (held, kept, any_hidden, any_submenu, names_ready)
    // Not holding the keyboard (the handoff gave it back): left open.
    assert_eq!(d(false, false, true, true, false), HeldMenu::LeaveOpen);
    // Holding it, nothing hidden, no submenu, names ready: left open.
    assert_eq!(d(true, false, false, false, true), HeldMenu::LeaveOpen);
    // Any submenu, or a hidden (denied or protected) item: listed.
    assert_eq!(d(true, false, false, true, true), HeldMenu::List);
    assert_eq!(d(true, false, true, false, true), HeldMenu::List);
    // A handoff that did not give the keyboard back: always listed.
    assert_eq!(d(true, true, false, false, true), HeldMenu::List);
    // Names still loading: closed, and the call says so, whatever the deny
    // list (the protected apps always apply).
    assert_eq!(d(true, false, false, false, false), HeldMenu::Loading);
    assert_eq!(d(true, true, false, false, false), HeldMenu::Loading);
    // A listed menu's report says so.
    assert_eq!(crate::menus::MenuReport::listed(vec![], 0).state, "listed");
}

#[test]
fn an_unreadable_title_is_hidden_and_counted_never_a_separator() {
    use menus::{Row, listed_row};
    assert_eq!(listed_row("", true, false), Row::Hidden);
    assert_eq!(listed_row("", true, true), Row::Hidden);
    assert_eq!(listed_row("Copy", false, true), Row::Hidden);
    assert_eq!(listed_row("  ", false, false), Row::Separator);
    assert_eq!(listed_row("Copy", false, false), Row::Visible);
}

#[test]
fn picks_wait_and_say_so_while_the_app_names_load() {
    let loading = crate::menus::APP_NAMES_LOADING;
    // pick_in and the closed pop-up pick share this gate.
    assert_eq!(menus::pick_gate(false), Err(loading));
    assert_eq!(menus::pick_gate(true), Ok(()));
    // The gate comes before the pick: even a visible exact match is not
    // chosen while the names load.
    let titles = vec!["Copy".to_string(), "Open in cmux Remote".to_string()];
    let hidden = [false, false];
    assert_eq!(menus::gated_pick(false, &titles, &hidden, "Copy"), Err(loading));
    assert_eq!(menus::gated_pick(true, &titles, &hidden, "Copy"), Ok(crate::menus::Pick::Item(0)));
    // A menu left open while they load says so.
    assert_eq!(menus::loading_note(false), Some(loading));
    assert_eq!(menus::loading_note(true), None);
}

#[test]
fn a_shortcut_blocked_only_while_names_load_says_they_are_loading() {
    let loading = crate::menus::APP_NAMES_LOADING;
    // The blocking item's name could not be resolved yet: "loading".
    assert_eq!(roles::loading_instead(roles::REFUSE_BLOCKED, true), Some(loading));
    // A real block keeps the deny-list refusal, loading or not.
    assert_eq!(roles::loading_instead(roles::REFUSE_BLOCKED, false), None);
    // Any other refusal is unchanged.
    assert_eq!(roles::loading_instead(roles::REFUSE_LAYOUT, true), None);
}

#[test]
fn a_menu_item_check_tells_a_real_block_from_a_name_not_resolved_yet() {
    use roles::{ItemCheck, MenuItemContext, menu_item_check};
    let guard = PolicyGuard(crate::policy::PolicyConfig::default());
    let ctx =
        |t| MenuItemContext { title: t, top_index: None, depth: 1, siblings: &[], launch: None };
    let loading = |_: &str| -> Option<Vec<String>> { None };
    assert_eq!(menu_item_check(&guard, &ctx("Copy"), &loading), ItemCheck::Unknown);
    let known = |n: &str| -> Option<Vec<String>> {
        Some(if n == "Terminal" { vec!["com.apple.Terminal".into()] } else { vec![] })
    };
    assert_eq!(menu_item_check(&guard, &ctx("Copy"), &known), ItemCheck::Allowed);
    assert_eq!(menu_item_check(&guard, &ctx("Terminal"), &known), ItemCheck::Blocked);
}

#[test]
fn before_the_index_is_built_a_blocked_app_is_known_by_its_localized_name() {
    // LaunchServices matches file names only: the German display name of
    // System Settings would be "not an app" there.
    let mut blocked = workspace::NameMap::new();
    blocked.insert("systemeinstellungen".into(), vec!["com.apple.systempreferences".into()]);
    let file_names_only = Vec::new;
    assert_eq!(
        workspace::cold_resolve("systemeinstellungen", Some(&blocked), file_names_only),
        Some(vec!["com.apple.systempreferences".to_string()])
    );
    // Other names go to LaunchServices.
    assert_eq!(
        workspace::cold_resolve("textedit", Some(&blocked), || vec!["com.apple.TextEdit".into()]),
        Some(vec!["com.apple.TextEdit".to_string()])
    );
    // No blocked names (no guard, LaunchServices unavailable): unresolved.
    assert_eq!(workspace::cold_resolve("textedit", None, Vec::new), None);
    // And the Apple menu item is held to the deny list with that resolver.
    let guard = PolicyGuard(crate::policy::PolicyConfig::default());
    let ctx = roles::MenuItemContext {
        title: "Systemeinstellungen\u{2026}",
        top_index: Some(0),
        depth: 1,
        siblings: &[],
        launch: None,
    };
    let resolve =
        |n: &str| workspace::cold_resolve(&n.trim().to_lowercase(), Some(&blocked), Vec::new);
    assert!(roles::menu_item_blocked(&guard, &ctx, &resolve));
}

#[test]
fn a_running_app_a_prefix_entry_covers_is_known_by_its_name_before_the_index() {
    let mut map = workspace::NameMap::new();
    let running = vec![
        ("com.agilebits.onepassword7".to_string(), "1Password 7".to_string()),
        ("com.apple.TextEdit".to_string(), "TextEdit".to_string()),
    ];
    workspace::add_prefixed_running(&mut map, &["com.agilebits.".to_string()], &running);
    assert_eq!(map.get("1password 7"), Some(&vec!["com.agilebits.onepassword7".to_string()]));
    assert_eq!(map.get("textedit"), None);
    // Bundle ids compare in any case, as the deny list's matcher does.
    let mut map = workspace::NameMap::new();
    let running = vec![("com.apple.ActivityMonitor".to_string(), "Aktivitätsanzeige".to_string())];
    workspace::add_prefixed_running(&mut map, &["com.apple.activitymonitor".to_string()], &running);
    assert_eq!(map.get("aktivitätsanzeige"), Some(&vec!["com.apple.ActivityMonitor".to_string()]));
}

#[test]
fn a_refusal_names_why_an_item_is_blocked() {
    use crate::menus::{APP_NAMES_LOADING, BlockReason, UNREADABLE_ITEM_REFUSAL, block_message};
    assert!(block_message(BlockReason::Denied, Some("Open in X")).contains("deny list"));
    assert_eq!(block_message(BlockReason::Loading, Some("Open in X")), APP_NAMES_LOADING);
    assert_eq!(block_message(BlockReason::Unreadable, None), UNREADABLE_ITEM_REFUSAL);
}

#[test]
fn an_open_with_item_naming_an_allowed_app_is_allowed_once_the_index_is_built() {
    use crate::menus::BlockReason;
    // The default deny list is not empty (Terminal is on it).
    let guard = PolicyGuard(crate::policy::PolicyConfig::default());
    let open_with = vec!["Open With".to_string()];
    let index = |n: &str| -> Option<Vec<String>> {
        Some(match n.to_lowercase().as_str() {
            "textedit" => vec!["com.apple.TextEdit".into()],
            "terminal" => vec!["com.apple.Terminal".into()],
            _ => vec![],
        })
    };
    let cold = |_: &str| -> Option<Vec<String>> { Some(Vec::new()) };
    let reason = |t: &str| opened_reason(&guard, t, Some(&open_with), false, &cold, &index);
    assert_eq!(reason("TextEdit"), None);
    assert_eq!(reason("Terminal"), Some(BlockReason::Denied));
    // An Open With item the index does not know: blocked (launch list).
    assert_eq!(reason("Some Document"), Some(BlockReason::Denied));
    // The menu-bar rule could not resolve a name yet: Loading.
    assert_eq!(
        opened_reason(&guard, "TextEdit", Some(&open_with), true, &cold, &index),
        Some(BlockReason::Loading)
    );
    // While the index loads, an index-only block says Loading.
    let loading = |_: &str| -> Option<Vec<String>> { None };
    assert_eq!(
        opened_reason(&guard, "TextEdit", Some(&open_with), false, &cold, &loading),
        Some(BlockReason::Loading)
    );
}

#[test]
fn the_name_free_rules_do_not_block_a_launch_list_item() {
    let guard = PolicyGuard(crate::policy::PolicyConfig::default());
    let open_with = vec!["Open With".to_string()];
    // A launch list needs names: the name-free pass leaves it alone.
    assert!(!opened_rules_name_free(&guard, "TextEdit", Some(&open_with)));
    // An item above it that cannot be read while something is denied: the
    // listing hides it and the press refuses it, as Unreadable.
    let index = |_: &str| -> Option<Vec<String>> { Some(vec!["com.apple.TextEdit".into()]) };
    let cold = |_: &str| -> Option<Vec<String>> { Some(Vec::new()) };
    assert!(opened_rules(&guard, "TextEdit", None, &index));
    assert_eq!(
        opened_reason(&guard, "TextEdit", None, false, &cold, &index),
        Some(crate::menus::BlockReason::Unreadable)
    );
    // A `name:` deny entry is matched by the name alone.
    let by_name = PolicyGuard(crate::policy::PolicyConfig {
        denied_apps: vec!["name:Diary".into()],
        ..Default::default()
    });
    assert!(opened_rules_name_free(&by_name, "Write in Diary", Some(&[])));
}

#[test]
fn a_word_run_naming_a_blocked_app_known_before_the_index_is_denied_not_loading() {
    use crate::menus::BlockReason;
    let guard = PolicyGuard(crate::policy::PolicyConfig {
        denied_apps: vec!["com.agilebits.*".into()],
        ..Default::default()
    });
    let cold = |n: &str| -> Option<Vec<String>> {
        Some(if n.eq_ignore_ascii_case("1Password") {
            vec!["com.agilebits.onepassword7".into()]
        } else {
            vec![]
        })
    };
    let loading = |_: &str| -> Option<Vec<String>> { None };
    assert_eq!(
        opened_reason(&guard, "Open in 1Password", Some(&[]), false, &cold, &loading),
        Some(BlockReason::Denied)
    );
}

#[test]
fn the_press_and_the_listing_agree_on_every_item() {
    // The listing (listing_blocked) and the press (press_reason after the
    // menu-bar rule's check) use one name source: the index plus the cold
    // map, which here knows names the index does not ("Foo", a denied app
    // outside the app folders, and a prefix app), and while the index loads
    // knows only those. For every guard, title, path and source they agree.
    let guards = [
        PolicyGuard(crate::policy::PolicyConfig::default()),
        PolicyGuard(crate::policy::PolicyConfig { denied_apps: vec![], ..Default::default() }),
        PolicyGuard(crate::policy::PolicyConfig {
            denied_apps: vec![
                "com.agilebits.*".into(),
                "name:Diary".into(),
                "com.example.foo".into(),
            ],
            ..Default::default()
        }),
    ];
    let map = |pairs: &[(&str, &str)]| {
        let mut m = workspace::NameMap::new();
        for (name, id) in pairs {
            m.entry(name.to_string()).or_default().push(id.to_string());
        }
        m
    };
    let index = map(&[
        ("textedit", "com.apple.TextEdit"),
        ("terminal", "com.apple.Terminal"),
        ("securityagent", "com.apple.securityagent"),
    ]);
    let cold = map(&[
        ("terminal", "com.apple.Terminal"),
        ("foo", "com.example.foo"),
        ("1password", "com.agilebits.onepassword7"),
    ]);
    let sources = [
        workspace::NameSource::of(Some(index.clone()), Some(cold.clone())),
        // The index is still loading: only the cold map answers.
        workspace::NameSource::of(None, Some(cold)),
        workspace::NameSource::of(Some(index), None),
    ];
    let titles = [
        "TextEdit",
        "Terminal",
        "New Terminal at Folder",
        "Open in 1Password",
        "Open in Foo",
        "Foo",
        "Write in Diary",
        "SecurityAgent",
        "Make Sticky",
        "Copy",
        "",
    ];
    let open_with = vec!["Open With".to_string()];
    let services = vec!["Services".to_string()];
    let terminal = vec!["Terminal".to_string()];
    let sort = vec!["Sort By".to_string()];
    let paths: [Option<&[String]>; 6] =
        [None, Some(&[]), Some(&open_with), Some(&services), Some(&terminal), Some(&sort)];
    for guard in &guards {
        for names in &sources {
            let resolve = |n: &str| names.resolve(n);
            let cold_answer = |n: &str| names.cold_answer(n);
            for title in titles {
                for path in paths {
                    for launch in [None, Some(false), Some(true)] {
                        for depth in [1, 2] {
                            let ctx = roles::MenuItemContext {
                                title,
                                top_index: None,
                                depth,
                                siblings: &[],
                                launch,
                            };
                            let listing = listing_blocked(guard, &ctx, path, &resolve);
                            // The press's own check, as it runs (Unknown
                            // included: menu_unknown).
                            let check = roles::menu_item_check(guard, &ctx, &resolve);
                            let press =
                                press_reason(guard, check, title, path, &cold_answer, &resolve);
                            assert_eq!(
                                press.is_some(),
                                listing,
                                "{title:?} under {path:?}, launch {launch:?}, depth {depth}"
                            );
                        }
                    }
                }
            }
        }
    }
}

#[test]
fn one_name_source_joins_the_index_and_the_names_known_before_it() {
    let mut index = workspace::NameMap::new();
    index.insert("textedit".into(), vec!["com.apple.TextEdit".into()]);
    let mut cold = workspace::NameMap::new();
    cold.insert("foo".into(), vec!["com.example.foo".into()]);
    let both = workspace::NameSource::of(Some(index.clone()), Some(cold.clone()));
    assert_eq!(both.resolve("Foo"), Some(vec!["com.example.foo".to_string()]));
    assert_eq!(both.resolve("TextEdit"), Some(vec!["com.apple.TextEdit".to_string()]));
    assert_eq!(both.resolve("Other"), Some(vec![]));
    // Before the index: the cold map answers; anything else is unknown.
    let cold_only = workspace::NameSource::of(None, Some(cold));
    assert_eq!(cold_only.resolve("foo"), Some(vec!["com.example.foo".to_string()]));
    assert_eq!(cold_only.resolve("TextEdit"), None);
}

#[test]
fn unknown_siblings_fail_closed_only_while_something_is_denied() {
    let resolve = |_: &str| -> Option<Vec<String>> { Some(vec![]) };
    assert!(roles::launch_by_items(None, true, &resolve));
    assert!(!roles::launch_by_items(None, false, &resolve));
}

#[test]
fn entries_split_into_exact_ids_and_prefixes() {
    let (ids, prefixes) = workspace::split_entries(vec![
        "com.apple.Terminal".into(),
        "com.AgileBits.*".into(),
        "*".into(),
    ]);
    assert_eq!(ids, vec!["com.apple.Terminal".to_string()]);
    // Lower-cased; a lone `*` is the empty prefix: every app.
    assert_eq!(prefixes, vec!["com.agilebits.".to_string(), String::new()]);
    let mut map = workspace::NameMap::new();
    workspace::add_prefixed_running(
        &mut map,
        &[String::new()],
        &[("com.apple.TextEdit".into(), "TextEdit".into())],
    );
    assert!(map.contains_key("textedit"));
    // A deny-list edit rebuilds the cached names; the same set reuses them.
    let a = vec!["com.apple.Terminal".to_string()];
    let b = vec!["com.apple.Terminal".to_string(), "com.example.x".to_string()];
    assert!(workspace::reuse_cached(&a, &a));
    assert!(!workspace::reuse_cached(&a, &b));
}

#[test]
fn the_protected_prefixes_are_sent_as_prefix_entries() {
    let prefixes = crate::policy::protected_prefixes();
    assert!(prefixes.contains(&"com.cmuxterm.remote."));
    assert!(prefixes.iter().all(|p| p.ends_with('.')));
}
