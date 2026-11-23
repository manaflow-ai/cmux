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

/// Review 3 (8, 9): the scope runs only on the verified minors (26.6+,
/// 27.0.1+; earlier versions and other majors run with it off), and any off
/// switch that says 0 turns it off, whichever source says it.
#[test]
fn the_key_in_app_scope_is_gated() {
    use activation::gate;
    assert!(gate("26.6.2", &[]));
    assert!(gate("26.7", &[]));
    assert!(gate("27.2", &[]));
    assert!(gate("27.3.1", &[]));
    assert!(!gate("26.5.1", &[]), "before the verified 26 minor");
    // 27.0.1 verified live (the person's macOS): on from 27.0.1, not 27.0.
    assert!(gate("27.0.1", &[]));
    assert!(gate("27.0.2", &[]));
    assert!(!gate("27.0", &[]), "27.0 itself was not verified");
    assert!(!gate("28.0", &[]));
    assert!(!gate("15.7", &[]));
    assert!(!gate("", &[]));
    assert!(!gate("27.2", &["0"]));
    assert!(!gate("27.2", &["1", "0"]), "the worker says 1, launchd says 0: off");
    assert!(!gate("27.2", &["0", "1"]));
    assert!(gate("27.2", &["1"]));
}

/// Review 3 (2, 3, 5): a disabled background menu item is never made
/// available when it sits in a launch list (Services, Open With, ... in
/// AppKit's languages; or its place cannot be read), is an open or reveal
/// command by title, or has AppKit's Open key equivalent (any language).
#[test]
fn launch_and_open_items_are_never_primed() {
    let launch = vec!["services".to_string(), "open with".to_string(), "dienste".to_string()];
    let open = vec!["open".to_string(), "open recent".to_string(), "show in finder".to_string()];
    let up = |t: &[&str]| t.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    let block = |title: &str, anc: Option<&[String]>, key: bool| {
        roles::prime_block(Some(title), anc, Some(key), &launch, &open)
    };
    assert!(block("Select All", Some(&up(&["Edit"])), false).is_none());
    assert!(block("Zoom In", Some(&up(&["View"])), false).is_none());
    // Services in English and German; Open With's submenu.
    assert!(block("Make New Sticky Note", Some(&up(&["Services", "TextEdit"])), false).is_some());
    assert!(block("Neue Notiz", Some(&up(&["Dienste", "TextEdit"])), false).is_some());
    assert!(block("Terminal", Some(&up(&["Open With", "File"])), false).is_some());
    // Unreadable place: fail closed.
    assert!(block("Select All", None, false).is_some());
    // Open commands by title (ellipsis and case ignored) and by key.
    assert!(block("Open\u{2026}", Some(&up(&["File"])), false).is_some());
    assert!(block("Open in New Tab", Some(&up(&["File"])), false).is_some());
    assert!(block("Show in Finder", Some(&up(&["File"])), false).is_some());
    assert!(block("Öffnen", Some(&up(&["Ablage"])), true).is_some(), "Command-O in any language");
    assert!(block("Opener", Some(&up(&["View"])), false).is_none(), "not a word prefix");
    // Review 4 (4): a document under Open Recent (an open command's submenu).
    assert!(block("report.txt", Some(&up(&["Open Recent", "File"])), false).is_some());
    // Review 4 (3): an unreadable title or key equivalent blocks.
    let edit = up(&["Edit"]);
    assert!(roles::prime_block(None, Some(&edit), Some(false), &launch, &open).is_some());
    assert!(roles::prime_block(Some("Select All"), Some(&edit), None, &launch, &open).is_some());
}

/// Review 3 (2, 3): AppKit's Open (Command-O) and Finder's Open
/// (Command-Down) are recognized by key; with Shift, Option or Control, or
/// another key, they are not.
#[test]
fn the_open_key_equivalent() {
    use keymap::{MENU_OPTION, MENU_SHIFT, menu_item_key};
    let o = menu_item_key(Some("O"), None, None);
    assert!(roles::is_open_key_equivalent(&o, 0));
    assert!(!roles::is_open_key_equivalent(&o, MENU_SHIFT));
    assert!(!roles::is_open_key_equivalent(&o, MENU_OPTION));
    let down = menu_item_key(None, Some(125), None);
    assert!(roles::is_open_key_equivalent(&down, 0));
    let a = menu_item_key(Some("A"), None, None);
    assert!(!roles::is_open_key_equivalent(&a, 0));
}

/// Review 2 (B, 3): inside a scope an item is pressed only while the scope
/// is live and focus is on the target window, and never a Services item.
#[test]
fn a_primed_press_needs_a_live_scope_on_the_target_and_no_service() {
    assert_eq!(roles::primed_press(true, true, false), Ok(()));
    assert!(roles::primed_press(false, true, false).is_err());
    assert!(roles::primed_press(true, false, false).is_err());
    assert!(roles::primed_press(true, true, true).unwrap_err().contains("never run"));
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
    /// When set, every post records whether the registry still had the pid
    /// open at that moment (the hand-back's ordering).
    watch: std::cell::Cell<Option<(&'static activation::Registry, i32)>>,
    open_at_post: std::cell::RefCell<Vec<bool>>,
    /// The injected clock: time passed since the fake started.
    elapsed: std::cell::Cell<std::time::Duration>,
    /// The front app cannot be read.
    front_unknown: std::cell::Cell<bool>,
}

/// The fake clock's origin.
fn fake_epoch() -> std::time::Instant {
    static T0: std::sync::OnceLock<std::time::Instant> = std::sync::OnceLock::new();
    *T0.get_or_init(std::time::Instant::now)
}

impl activation::ScopeOs for FakeOs {
    fn now(&self) -> std::time::Instant {
        fake_epoch() + self.elapsed.get()
    }
    fn front_pid(&self) -> Option<i32> {
        if self.front_unknown.get() {
            return None;
        }
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
        if let Some((reg, pid)) = self.watch.get() {
            self.open_at_post.borrow_mut().push(reg.is_open(pid));
        }
        true
    }
    fn window_exists(&self, window: u32, pid: i32) -> bool {
        self.windows.borrow().contains(&(window, pid))
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
    // Review 4 (5), 8 (6): ended under the app's lock with nothing posted
    // (its first record failed): no scope is left open and the app is not
    // held; a new scope may enter.
    assert!(!reg.is_open(5));
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
    assert_eq!(
        os.posts.borrow().last(),
        Some(&(activation::RECORD_FOCUS, 12, activation::FOCUS_OUT))
    );
    let key = activation::KeyInApp::enter_with(&os, &reg, 12, 5).expect("entered");
    os.windows.borrow_mut().clear();
    assert_eq!(key.end(), activation::Ended::HandBackFailed);
    // Notes are appended, never replaced.
    let mut note = "pressed".to_string();
    activation::append_note(&mut note, activation::HAND_BACK_FAILED);
    activation::append_note(&mut note, activation::HAND_BACK_FAILED);
    assert!(note.starts_with("pressed; ") && note.matches("hand-back").count() == 1);
}

/// Review 4 (1), 5 (1), 6 (1, 5): input is posted to an app only while no
/// scope is open on it, its own or another session's, and the post runs
/// under that app's lock, which entering a scope takes (no scope can open
/// mid-post); another app's lock is separate; a joiner keeps the app primed
/// after the first scope ended.
#[test]
fn input_is_posted_only_while_no_scope_is_open_and_under_the_app_lock() {
    let os = fake(&[(10, 5)]);
    let reg = activation::Registry::new();
    let short = std::time::Duration::from_millis(60);
    let held =
        reg.post_unprimed(5, 10, short, |p| (reg.pid_locked(5), reg.pid_locked(7), p.route()));
    assert_eq!(held, Some((true, false, input::Route::Pid { pid: 5, window: 10 })));
    let own = activation::KeyInApp::enter_with(&os, &reg, 10, 5).expect("own");
    let other = activation::KeyInApp::enter_with(&os, &reg, 10, 5).expect("another session joins");
    let ran = std::cell::Cell::new(false);
    assert_eq!(reg.post_unprimed(5, 10, short, |_| ran.set(true)), None, "own scope open");
    assert!(!ran.get(), "nothing posted while primed");
    assert_eq!(own.end(), activation::Ended::Fine);
    assert!(reg.is_open(5), "the joiner keeps the app primed");
    assert_eq!(reg.post_unprimed(5, 10, short, |_| ran.set(true)), None, "still primed");
    assert!(!ran.get());
    assert_eq!(reg.post_unprimed(7, 1, short, |_| 1), Some(1), "another app is not held");
    drop(other);
    assert_eq!(reg.post_unprimed(5, 10, short, |_| 2), Some(2), "last scope out: input may go");
}

/// Review 6 (3): after a failed hand-back the app may still take itself for
/// the active app, so input to it stays refused for a moment.
#[test]
fn a_failed_hand_back_keeps_input_refused_for_a_moment() {
    let os = fake(&[(10, 5)]);
    let reg = activation::Registry::new();
    let key = activation::KeyInApp::enter_with(&os, &reg, 10, 5).expect("entered");
    os.windows.borrow_mut().clear();
    assert_eq!(key.end(), activation::Ended::HandBackFailed);
    assert!(reg.is_open(5));
    let short = std::time::Duration::from_millis(60);
    assert_eq!(reg.post_unprimed(5, 10, short, |_| ()), None);
}

/// Review 6 (4): entry fails closed when the front app cannot be read.
#[test]
fn entry_fails_closed_when_the_front_app_is_unreadable() {
    let os = fake(&[(10, 5)]);
    let reg = activation::Registry::new();
    os.front_unknown.set(true);
    assert!(activation::KeyInApp::enter_with(&os, &reg, 10, 5).is_none());
    assert!(os.posts.borrow().is_empty());
}

/// Review 6 (8): a joiner shares the first scope's deadline (injected
/// clock): joins never extend priming past one bound from the first entry.
#[test]
fn a_joiner_does_not_extend_the_bound() {
    let os = fake(&[(10, 5)]);
    let reg = activation::Registry::new();
    let first = activation::KeyInApp::enter_with(&os, &reg, 10, 5).expect("first");
    os.elapsed.set(activation::SCOPE_BOUND - std::time::Duration::from_millis(1));
    let joiner = activation::KeyInApp::enter_with(&os, &reg, 10, 5).expect("joins");
    assert!(first.live() && joiner.live());
    os.elapsed.set(activation::SCOPE_BOUND);
    assert!(!first.live() && !joiner.live(), "both end one bound after the first entry");
}

/// The parameter lists of every `pub...fn` in `src` (pub, pub(super),
/// pub(crate), pub unsafe, extern), each read to its closing parenthesis, so
/// a signature rustfmt splits across lines is read whole.
fn pub_fn_params(src: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = src;
    while let Some(i) = rest.find("fn ") {
        let before = &rest[..i];
        let line_start = before.rfind('\n').map_or(0, |n| n + 1);
        let head = before[line_start..].trim();
        let after = &rest[i..];
        if head.starts_with("pub")
            && let Some(open) = after.find('(')
        {
            let mut depth = 0usize;
            let mut end = None;
            for (j, c) in after[open..].char_indices() {
                match c {
                    '(' => depth += 1,
                    ')' => {
                        depth -= 1;
                        if depth == 0 {
                            end = Some(open + j);
                            break;
                        }
                    }
                    _ => {}
                }
            }
            if let Some(end) = end {
                out.push(after[open..=end].to_string());
            }
        }
        rest = &after[3..];
    }
    out
}

/// Every .rs file under `dir`, subdirectories included.
fn rust_sources(dir: &std::path::Path, out: &mut Vec<std::path::PathBuf>) {
    for entry in std::fs::read_dir(dir).expect("source directory") {
        let path = entry.expect("entry").path();
        if path.is_dir() {
            rust_sources(&path, out);
        } else if path.extension().and_then(|e| e.to_str()) == Some("rs") {
            out.push(path);
        }
    }
}

/// Reviews 6 (1), 7, 8: input reaches an app's process only through
/// `activation::post_unprimed`. The posters are declared only in a private
/// module of input.rs, so nothing else can name them; this test is the
/// backstop. Every source file under this directory (subdirectories too) is
/// read at test time: only input.rs names the CoreGraphics and SkyLight
/// event posters (to a process, a PSN, the HID tap), only activation.rs
/// names SLPSPostEventRecordTo, sys.rs names none; no public input.rs
/// function takes a bare Route (signatures read whole, any pub form); only
/// activation.rs builds a Posting.
#[test]
fn only_post_unprimed_can_post_to_a_process() {
    let dir = std::path::Path::new(concat!(env!("CARGO_MANIFEST_DIR"), "/src/platform/macos"));
    let posters = [
        concat!("CGEvent", "PostToPid"),
        concat!("CGEvent", "PostToPSN"),
        concat!("SLEvent", "PostToPid"),
        concat!("SLEvent", "PostToPSN"),
        concat!("CGSPost", "Event"),
        concat!("CGEvent", "Post("),
    ];
    let record_poster = concat!("SLPSPost", "EventRecordTo");
    let build = concat!("Posting", " { route");
    let mut files = Vec::new();
    rust_sources(dir, &mut files);
    let mut seen = 0;
    for path in files {
        let name = path.file_name().unwrap().to_string_lossy().to_string();
        if name == "tests.rs" {
            continue;
        }
        seen += 1;
        let src = std::fs::read_to_string(&path).expect("read source");
        if name != "input.rs" {
            for p in posters {
                assert!(!src.contains(p), "{name} names {p}: post through input with a Posting");
            }
        }
        if name != "activation.rs" {
            assert!(!src.contains(record_poster), "{name} names {record_poster}");
            assert!(!src.contains(build), "{name} builds a Posting");
        }
        if name == "input.rs" {
            for params in pub_fn_params(&src) {
                assert!(
                    !params.contains(": Route") && !params.contains(":Route"),
                    "input.rs exposes a bare-Route poster: {params}"
                );
            }
        }
    }
    assert!(seen >= 10, "the macOS sources were found ({seen})");
}

/// The guard's signature reader sees split signatures and every pub form.
#[test]
fn the_guard_reads_whole_signatures() {
    let src = "pub(super) fn a(\n    route: Route,\n    x: u8,\n) {}\npub unsafe fn b(r: Route) {}\nfn c(route: Route) {}\npub(crate) fn d(p: &Posting) {}";
    let params = pub_fn_params(src);
    assert_eq!(params.len(), 3, "{params:?}");
    assert!(params[0].contains("route: Route"));
    assert!(params[1].contains("r: Route"));
    assert!(params[2].contains("&Posting"));
}

/// Review 8 (4): an action clears the hand-back flag before it runs and
/// adds a failure during it to its result or refusal, once.
#[test]
fn an_action_reports_its_own_failed_hand_back_once() {
    let fail = || {
        let os = fake(&[(10, 5)]);
        let reg = activation::Registry::new();
        let key = activation::KeyInApp::enter_with(&os, &reg, 10, 5).expect("entered");
        os.windows.borrow_mut().clear();
        drop(key);
    };
    // A stale flag from before the call is cleared.
    fail();
    let ok = actions::reporting_hand_back(|| Ok(ActionOutcome::delivered("x")));
    assert!(ok.unwrap().note.is_empty());
    // A failure during the call: on Ok and on Err, once.
    let ok = actions::reporting_hand_back(|| {
        fail();
        let mut out = ActionOutcome::delivered("x");
        activation::append_note(&mut out.note, activation::HAND_BACK_FAILED);
        Ok(out)
    })
    .unwrap();
    assert_eq!(ok.note.matches(activation::HAND_BACK_FAILED).count(), 1);
    let err = actions::reporting_hand_back(|| {
        fail();
        Err(DesktopError::TargetNotFound("gone".into()))
    })
    .unwrap_err();
    assert!(format!("{err:?}").contains(activation::HAND_BACK_FAILED));
    // Review of b4236e6 (12): the note follows the whole message; it is not
    // put into the element id ("element 1.2 (note) is stale").
    let err = actions::reporting_hand_back(|| {
        fail();
        Err(DesktopError::StaleElement("1.2".into()))
    })
    .unwrap_err()
    .to_string();
    assert!(err.starts_with("element 1.2 is stale; call get_ui_tree again ("), "{err}");
    assert!(err.ends_with(&format!("({})", activation::HAND_BACK_FAILED)), "{err}");
}

/// Review 8 (6): a scope whose first record failed posted nothing: no
/// hand-back failure is reported and the app is not held.
#[test]
fn a_failure_before_any_post_holds_nothing() {
    let os = fake(&[(10, 5)]);
    let reg = activation::Registry::new();
    os.fail_posts.set(true);
    activation::take_hand_back_failed();
    assert!(activation::KeyInApp::enter_with(&os, &reg, 10, 5).is_none());
    assert!(!activation::take_hand_back_failed());
    assert!(!reg.is_open(5));
}

/// Review 7, 8 (4, 5): a menu item's place is read up to the menu bar; a
/// walk that does not reach it is no place (blocked, with its own reason).
#[test]
fn a_menu_items_place_must_reach_the_menu_bar() {
    use roles::{MenuNode, menu_place};
    let node = |role: Option<&str>, title: Result<Option<&str>, ()>| MenuNode {
        role: role.map(str::to_string),
        title: title.map(|t| t.map(str::to_string)),
    };
    let yes = || true;
    let walk = vec![
        node(Some("AXMenu"), Ok(None)),
        node(Some("AXMenuItem"), Ok(Some("Font"))),
        node(Some("AXMenu"), Ok(None)),
        node(Some("AXMenuBarItem"), Ok(Some("Format"))),
        node(Some("AXMenuBar"), Ok(None)),
    ];
    assert_eq!(menu_place(walk.into_iter(), &yes), Some(vec!["Font".into(), "Format".into()]));
    // Ends at the application: no place.
    let walk = vec![node(Some("AXMenu"), Ok(None)), node(Some("AXApplication"), Ok(None))];
    assert_eq!(menu_place(walk.into_iter(), &yes), None);
    // Unreadable role or title: no place.
    assert_eq!(menu_place(vec![node(None, Ok(None))].into_iter(), &yes), None);
    let walk = vec![node(Some("AXMenuItem"), Err(())), node(Some("AXMenuBar"), Ok(None))];
    assert_eq!(menu_place(walk.into_iter(), &yes), None);
    // Deeper than the walk: no place.
    let deep = (0..roles::MENU_PLACE_DEPTH + 1).map(|_| node(Some("AXMenu"), Ok(None)));
    assert_eq!(menu_place(deep, &yes), None);
    // The scope ended: no place.
    let walk = vec![node(Some("AXMenuBar"), Ok(None))];
    assert_eq!(menu_place(walk.into_iter(), &|| false), None);
    // No place is refused with its own reason.
    let why = roles::prime_block(Some("Select All"), None, Some(false), &[], &[]).unwrap();
    assert!(why.contains("place in the menus could not be read"), "{why}");
}

/// Review 5 (1B): the last scope's entry stays in the registry until its
/// focus-out was posted, so no input reaches the app before it is handed
/// back.
#[test]
fn the_app_counts_as_primed_until_the_focus_out_is_posted() {
    let reg: &'static activation::Registry = Box::leak(Box::new(activation::Registry::new()));
    let os = fake(&[(10, 5)]);
    os.watch.set(Some((reg, 5)));
    let key = activation::KeyInApp::enter_with(&os, reg, 10, 5).expect("entered");
    assert_eq!(key.end(), activation::Ended::Fine);
    let posts = os.posts.borrow().clone();
    assert_eq!(posts.last(), Some(&(activation::RECORD_FOCUS, 10, activation::FOCUS_OUT)));
    assert_eq!(os.open_at_post.borrow().last(), Some(&true), "open at the focus-out");
    assert!(!reg.is_open(5), "removed after it");
}

/// Review 5 (1), 6 (6): long text is posted in chunks (the lock is held per
/// chunk), never inside a user-perceived character; a stop part way says how
/// much was typed.
#[test]
fn text_is_posted_in_chunks() {
    assert_eq!(roles::text_chunks("abcdefgh", 3), vec!["abc", "def", "gh"]);
    assert!(roles::text_chunks("", 3).is_empty());
    // e + combining acute stays together.
    assert_eq!(roles::text_chunks("abe\u{301}c", 3), vec!["abe\u{301}", "c"]);
    // A ZWJ family emoji is one chunk piece.
    let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
    let chunks = roles::text_chunks(&format!("a{family}b"), 2);
    assert!(chunks.iter().any(|c| c.contains(family)), "{chunks:?}");
    // A flag (two regional indicators) is not split.
    let flag = "\u{1F1EF}\u{1F1F5}";
    let chunks = roles::text_chunks(&format!("a{flag}"), 2);
    assert!(chunks.iter().any(|c| c.contains(flag)), "{chunks:?}");
    // A skin tone modifier stays with its emoji.
    let wave = "\u{1F44B}\u{1F3FD}";
    assert!(roles::text_chunks(&format!("x{wave}"), 1).iter().any(|c| c.contains(wave)));
    assert_eq!(roles::partial_typing_refusal(0, 9, "busy"), "busy");
    assert!(roles::partial_typing_refusal(4, 9, "busy").contains("first 4 of 9"));
}

/// Review 5 (2): inside a scope only the item's title is read again; a
/// changed or unreadable title is not pressed.
#[test]
fn a_menu_item_retitled_during_validation_is_not_pressed() {
    assert_eq!(roles::same_item(Some("Undo Typing"), Some("Undo Typing")), Ok(()));
    assert!(roles::same_item(Some("Undo Typing"), Some("Redo Typing")).is_err());
    assert!(roles::same_item(Some("Save"), None).is_err());
}

/// Review 7: the scope fails closed when the front app cannot be read:
/// not live, and its hand-back posts nothing and holds the app's input.
#[test]
fn an_unreadable_front_app_fails_closed_in_live_and_hand_back() {
    let os = fake(&[(10, 5)]);
    let reg = activation::Registry::new();
    let key = activation::KeyInApp::enter_with(&os, &reg, 10, 5).expect("entered");
    assert!(key.live());
    os.front_unknown.set(true);
    assert!(!key.live());
    let before = os.posts.borrow().len();
    activation::take_hand_back_failed();
    assert_eq!(key.end(), activation::Ended::HandBackFailed);
    assert_eq!(os.posts.borrow().len(), before, "no focus-out posted");
    assert!(reg.is_open(5), "input held");
    assert!(activation::take_hand_back_failed(), "the call learns of it");
}

/// Review 7: a failed hand-back is reported whatever path ended the scope:
/// a drop on an early return sets the same flag the action reads.
#[test]
fn a_dropped_scope_reports_its_failed_hand_back() {
    let os = fake(&[(10, 5)]);
    let reg = activation::Registry::new();
    activation::take_hand_back_failed();
    {
        let _key = activation::KeyInApp::enter_with(&os, &reg, 10, 5).expect("entered");
        os.windows.borrow_mut().clear();
    } // dropped, not ended
    assert!(activation::take_hand_back_failed());
    assert!(!activation::take_hand_back_failed(), "read once");
}

/// Review 7: input yields to a scope entry waiting for the same app, so a
/// long typing loop cannot keep it out between chunks.
#[test]
fn input_yields_to_a_waiting_scope_entry() {
    let reg = Arc::new(activation::Registry::new());
    let (tx, rx) = std::sync::mpsc::channel();
    let r2 = reg.clone();
    // Hold the app's lock as a chunk would, while an entry starts waiting.
    let lock = reg.lock_pid(5);
    let waiter = std::thread::spawn(move || {
        let _entry = r2.lock_pid_for_entry(5);
        tx.send("entry").unwrap();
        std::thread::sleep(std::time::Duration::from_millis(80));
    });
    while !reg.entry_waiting_for_test(5) {
        std::thread::yield_now();
    }
    drop(lock);
    // The next chunk waits for the entry instead of taking the lock first.
    let r = reg.post_unprimed(5, 1, std::time::Duration::from_secs(2), |_| "chunk");
    assert_eq!(rx.try_recv(), Ok("entry"), "the entry went first");
    assert_eq!(r, Some("chunk"));
    waiter.join().unwrap();
}

/// An NSTabView's tabs are AXRadioButtons with the AXTabButton subrole and
/// their own AXTitle (read live in the truth fixture: "General",
/// "Advanced"): the tree calls them `tab_button` and keeps the title as the
/// name, in the JSON tree and the outline alike.
#[test]
fn tabs_are_tab_buttons_named_by_their_title() {
    assert_eq!(roles::role_name("AXRadioButton", Some("AXTabButton")), "tab_button");
    assert_eq!(roles::role_name("AXRadioButton", None), "radio");
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
fn keys_reach_an_inline_editor_over_the_target_only() {
    let target = Rect { x: 544.0, y: 94.0, width: 920.0, height: 436.0 };
    // Finder's rename field, measured: no focused window, the Finder window
    // as main window, a text field in no window, inside the target.
    let field = roles::OverlayEditor {
        role: "AXTextField".into(),
        in_other_window: false,
        frame: Some(Rect { x: 759.0, y: 228.0, width: 54.0, height: 21.0 }),
    };
    assert!(roles::keys_reach_overlay_editor(false, true, Some(&field), &target));
    // A focused window (a sheet, an alert, another document) keeps the
    // key-window rule.
    assert!(!roles::keys_reach_overlay_editor(true, true, Some(&field), &target));
    // The editor is over another window of the app.
    assert!(!roles::keys_reach_overlay_editor(false, false, Some(&field), &target));
    let elsewhere = roles::OverlayEditor {
        frame: Some(Rect { x: 10.0, y: 40.0, width: 54.0, height: 21.0 }),
        ..field.clone()
    };
    assert!(!roles::keys_reach_overlay_editor(false, true, Some(&elsewhere), &target));
    // In another window, not a text input, or no frame: refused.
    let other = roles::OverlayEditor { in_other_window: true, ..field.clone() };
    assert!(!roles::keys_reach_overlay_editor(false, true, Some(&other), &target));
    let button = roles::OverlayEditor { role: "AXButton".into(), ..field.clone() };
    assert!(!roles::keys_reach_overlay_editor(false, true, Some(&button), &target));
    let unread = roles::OverlayEditor { frame: None, ..field.clone() };
    assert!(!roles::keys_reach_overlay_editor(false, true, Some(&unread), &target));
    assert!(!roles::keys_reach_overlay_editor(false, true, None, &target));
    // A window as big as the target is not an editor inside it.
    assert!(!roles::rect_within(&target, &target));
}

#[test]
fn an_inline_editor_window_id_names_the_window_keys_go_to() {
    let hint = roles::overlay_editor_window_hint(3910, "AXTextField", Some(3902));
    assert!(hint.contains("window 3910 is an inline editor (a text field"), "{hint}");
    assert!(hint.contains("window_id 3902"), "{hint}");
    let hint = roles::overlay_editor_window_hint(3910, "AXTextField", None);
    assert!(hint.contains("the window it lies over"), "{hint}");
}

#[test]
fn set_value_focuses_a_native_field_that_commits_when_editing_ends() {
    // Finder's Get Info name field: not focused, AXConfirm offered.
    assert!(roles::focus_before_value_write("AXTextField", false, false, Some(false), true));
    // Already being edited, web content, the person's app, no confirm, an
    // unreadable focus or a text area: left as it is.
    assert!(!roles::focus_before_value_write("AXTextField", false, false, Some(true), true));
    assert!(!roles::focus_before_value_write("AXTextField", true, false, Some(false), true));
    assert!(!roles::focus_before_value_write("AXTextField", false, true, Some(false), true));
    assert!(!roles::focus_before_value_write("AXTextField", false, false, Some(false), false));
    assert!(!roles::focus_before_value_write("AXTextField", false, false, None, true));
    assert!(!roles::focus_before_value_write("AXTextArea", false, false, Some(false), true));
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

/// Command-A alone is Select All, read back as the whole text selected;
/// with another modifier it is some other command.
#[test]
fn only_command_a_alone_is_select_all() {
    let combo = |s: &str| KeyCombo::parse(s).unwrap();
    assert!(roles::is_select_all(&combo("cmd+a")));
    assert!(!roles::is_select_all(&combo("cmd+shift+a")));
    assert!(!roles::is_select_all(&combo("ctrl+a")));
    assert!(!roles::is_select_all(&combo("a")));
}

/// A drag on a slider sets the value under its end: the fraction along the
/// track (bottom to top when the slider stands), within the range.
#[test]
fn a_slider_drag_sets_the_value_under_its_end() {
    let wide = Rect { x: 100.0, y: 50.0, width: 200.0, height: 20.0 };
    let at = |x, y| Point { x, y };
    assert_eq!(actions::slider_value_at(&wide, 0.0, 100.0, at(220.0, 60.0)), 60.0);
    assert_eq!(actions::slider_value_at(&wide, 0.0, 100.0, at(400.0, 60.0)), 100.0);
    assert_eq!(actions::slider_value_at(&wide, 10.0, 20.0, at(50.0, 60.0)), 10.0);
    let tall = Rect { x: 0.0, y: 0.0, width: 20.0, height: 100.0 };
    assert_eq!(actions::slider_value_at(&tall, 0.0, 1.0, at(10.0, 25.0)), 0.75);
}

/// Review of b4236e6 (1, 2): a click in text places the caret through
/// accessibility only outside rows (an editable cell's row is selected
/// instead) and outside the person's app (their caret would move); never
/// for a denied element.
#[test]
fn a_caret_is_placed_only_outside_rows_and_the_persons_app() {
    assert!(roles::caret_click_allowed(false, false, false));
    assert!(!roles::caret_click_allowed(false, true, false), "row");
    assert!(!roles::caret_click_allowed(false, false, true), "the person's app");
    assert!(!roles::caret_click_allowed(true, false, false), "denied");
}

/// Review of b4236e6 (4): only a value control pressed, incremented or
/// decremented must show it in its value; a confirm, cancel, show-menu,
/// custom action or a plain button can act invisibly.
#[test]
fn only_a_value_control_press_must_show_in_its_value() {
    for role in ["AXCheckBox", "AXRadioButton", "AXDisclosureTriangle", "AXIncrementor", "AXSlider"]
    {
        assert!(roles::press_shows_value(role, None, "AXPress"), "{role}");
    }
    assert!(roles::press_shows_value("AXIncrementor", None, "AXIncrement"));
    assert!(roles::press_shows_value("AXCheckBox", Some("AXSwitch"), "AXPress"));
    assert!(roles::press_shows_value("AXButton", Some("AXSwitch"), "AXPress"));
    for action in ["AXConfirm", "AXCancel", "AXShowMenu", "AXRaise", "Custom"] {
        assert!(!roles::press_shows_value("AXCheckBox", None, action), "{action}");
    }
    for role in ["AXButton", "AXTextField", "AXPopUpButton", "AXMenuItem"] {
        assert!(!roles::press_shows_value(role, None, "AXPress"), "{role}");
    }
}

/// Review of b4236e6 (6): a slider's read value is near the wanted one
/// within 2% of its range, whatever its range; a square slider is circular
/// and left to the events.
#[test]
fn a_slider_tolerance_follows_its_range_and_circular_ones_are_left_alone() {
    assert_eq!(roles::slider_tolerance(0.0, 100.0), 2.0);
    assert_eq!(roles::slider_tolerance(0.0, 1.0), 0.02);
    assert!(roles::slider_tolerance(5.0, 5.0) > 0.0);
    assert!(roles::looks_circular(&Rect { x: 0.0, y: 0.0, width: 32.0, height: 32.0 }));
    assert!(!roles::looks_circular(&Rect { x: 0.0, y: 0.0, width: 200.0, height: 20.0 }));
    assert!(!roles::looks_circular(&Rect { x: 0.0, y: 0.0, width: 20.0, height: 120.0 }));
}

/// Review of e75f474 (3, 4, 10): the gate every AX pointer write (caret
/// click, text drag, scroll, slider) goes through. In the person's front app
/// nothing is written and the events run; while another session's scope is
/// open on the app the write is refused; the front app is read again under
/// the lock, so an app that comes front while waiting is not written to.
#[test]
fn ax_pointer_writes_refuse_the_front_app_and_an_open_scope() {
    use std::cell::Cell;
    use std::time::Duration;
    let reg = activation::Registry::new();
    let wrote = Cell::new(0);
    let write = || wrote.set(wrote.get() + 1);
    // Not the front app, no scope: written.
    let done = actions::gated_in(&reg, 5, Duration::from_millis(50), || false, write).unwrap();
    assert_eq!(done, actions::AxWrite::Done(()));
    assert_eq!(wrote.get(), 1);
    // The person's front app: nothing written.
    let front = actions::gated_in(&reg, 5, Duration::from_millis(50), || true, write).unwrap();
    assert_eq!(front, actions::AxWrite::PersonsApp);
    // It comes front between the first check and the lock: nothing written.
    let reads = Cell::new(0);
    let late = actions::gated_in(
        &reg,
        5,
        Duration::from_millis(50),
        || {
            reads.set(reads.get() + 1);
            reads.get() > 1
        },
        write,
    )
    .unwrap();
    assert_eq!(late, actions::AxWrite::PersonsApp);
    assert_eq!(wrote.get(), 1);
    // Another session's key-in-app scope open on the app: refused.
    let os = fake(&[(10, 5)]);
    let key = activation::KeyInApp::enter_with(&os, &reg, 10, 5).expect("entered");
    let refused = actions::gated_in(&reg, 5, Duration::from_millis(50), || false, write);
    assert!(
        matches!(&refused, Err(DesktopError::Unsupported(m)) if m == activation::PRIMED_KEYS_REFUSAL),
        "{refused:?}"
    );
    assert_eq!(wrote.get(), 1);
    drop(key);
}

/// Review of e75f474 (6): a radio button already on, pressed, is done
/// already (uncertain), not "no effect".
#[test]
fn a_pressed_radio_button_already_on_is_already_done() {
    assert!(roles::press_already_done("AXRadioButton", "AXPress", "1"));
    assert!(!roles::press_already_done("AXRadioButton", "AXPress", "0"));
    assert!(!roles::press_already_done("AXCheckBox", "AXPress", "1"), "a checkbox toggles");
}

/// Follow-up of e75f474: watches detached from a stalled app are capped per
/// app; past the cap none starts (so no action there is no_effect).
#[test]
fn detached_watches_are_capped_per_app() {
    assert!(watch::may_start(0));
    assert!(watch::may_start(3));
    assert!(!watch::may_start(4));
}

/// Both priming defaults are one constant away: with the default off, only
/// an explicit `1` (and a verified macOS) turns the scope on; `0` always
/// turns it off.
#[test]
fn the_scope_default_is_one_constant_and_the_switch_overrides_it() {
    assert!(activation::gate_with(true, "27.0.1", &[]));
    assert!(!activation::gate_with(true, "27.0.1", &["0"]));
    assert!(!activation::gate_with(false, "27.0.1", &[]));
    assert!(activation::gate_with(false, "27.0.1", &["1"]));
    assert!(!activation::gate_with(false, "27.0.1", &["1", "0"]));
    assert!(!activation::gate_with(false, "26.5", &["1"]), "unverified macOS stays off");
}

/// A button's digit: its title (or description) is exactly one digit.
#[test]
fn a_digit_button_is_one_digit() {
    assert_eq!(roles::single_digit("8"), Some('8'));
    assert_eq!(roles::single_digit(" 0 "), Some('0'));
    assert_eq!(roles::single_digit("10"), None);
    assert_eq!(roles::single_digit("+"), None);
    assert_eq!(roles::single_digit(""), None);
}

/// The app-scoped priming list: under `NotDenied`, browsers (the cmux app
/// included: it hosts the cmux browser) and messaging and mail apps, their
/// beta and canary builds, and apps with no readable bundle id are never
/// primed; under `Any` every app is.
#[test]
fn the_priming_deny_list_covers_browsers_and_messaging() {
    use activation::{PrimeApps, may_prime};
    for id in [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.chrome.for.testing",
        "company.thebrowser.Browser",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "com.microsoft.edgemac.Beta",
        "com.brave.Browser.nightly",
        "com.cmuxterm.app",
        "com.cmuxterm.app.debug.cu.preview",
        "com.apple.MobileSMS",
        "com.apple.mail",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "net.whatsapp.WhatsApp",
        "ru.keepcoder.Telegram",
        "com.microsoft.teams2",
        "com.microsoft.Outlook",
        "org.mozilla.nightly",
        "org.chromium.Chromium",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "com.kagi.kagimacOS",
        "app.zen-browser.zen",
        "com.duckduckgo.macos.browser",
        "org.whispersystems.signal-desktop",
        "com.facebook.archon",
        "com.tencent.xinWeChat",
        "org.mozilla.thunderbird",
        "com.readdle.SparkDesktop",
        "com.mimestream.Mimestream",
        "com.cmuxterm.app.next",
    ] {
        assert!(!may_prime(PrimeApps::NotDenied, Some(id)), "{id}");
        assert!(may_prime(PrimeApps::Any, Some(id)), "{id}");
    }
    for id in ["com.apple.TextEdit", "com.apple.finder", "com.apple.Notes", "com.apple.mailplus"] {
        // A prefix match on a dot boundary is not required: "com.apple.mailplus"
        // starts with "com.apple.mail", so it is denied too (fail closed).
        let denied = id.starts_with("com.apple.mail");
        assert_eq!(may_prime(PrimeApps::NotDenied, Some(id)), !denied, "{id}");
    }
    assert!(!may_prime(PrimeApps::NotDenied, None), "unreadable bundle id");
}

/// Review of e840a32 (6): a posted press is aimed from both readings of the
/// front app: addressed when both are the target, a background press when
/// both are another app, and refused (nothing posted) when they disagree or
/// one is unread, so it can neither open the Apple menu nor raise a window.
#[test]
fn a_press_with_disagreeing_front_readings_is_not_posted() {
    use roles::{Aiming, press_aiming};
    assert_eq!(press_aiming(Some(5), Some(5), 5), Aiming::Addressed);
    assert_eq!(press_aiming(Some(9), Some(9), 5), Aiming::Unaddressed);
    assert_eq!(press_aiming(Some(9), Some(7), 5), Aiming::Unaddressed, "a panel over another app");
    assert_eq!(press_aiming(Some(5), Some(9), 5), Aiming::Refuse, "a panel over the target");
    assert_eq!(press_aiming(Some(9), Some(5), 5), Aiming::Refuse);
    assert_eq!(press_aiming(None, Some(9), 5), Aiming::Refuse);
    assert_eq!(press_aiming(Some(9), None, 5), Aiming::Refuse);
}

/// Review of e840a32 (4): where one front pid is needed (the scope's
/// checks), the readings must agree; otherwise none, and the checks fail
/// closed.
#[test]
fn one_front_pid_only_when_the_readings_agree() {
    assert_eq!(roles::agreed_front(Some(5), Some(5)), Some(5));
    assert_eq!(roles::agreed_front(Some(5), Some(9)), None);
    assert_eq!(roles::agreed_front(None, Some(9)), None);
}

/// Coordinator decision after d2b779e: text into web content or a browser's
/// field goes as posted keys (no AX write is attempted, so nothing can be
/// typed twice); elsewhere through accessibility, never followed by keys.
#[test]
fn web_content_takes_keys_and_everything_else_the_ax_insert() {
    use roles::{InsertRoute, insert_route, is_browser};
    assert_eq!(insert_route(true, false), InsertRoute::Keys, "a web area in any app");
    assert_eq!(insert_route(false, true), InsertRoute::Keys, "a browser's own field");
    assert_eq!(insert_route(false, false), InsertRoute::Ax);
    for id in [
        "com.apple.Safari",
        "com.google.Chrome.canary",
        "org.mozilla.firefox",
        "company.thebrowser.Browser",
    ] {
        assert!(is_browser(Some(id)), "{id}");
    }
    for id in ["com.apple.TextEdit", "com.apple.Notes"] {
        assert!(!is_browser(Some(id)), "{id}");
    }
    assert!(!is_browser(None));
}

/// Review of 02ca109 (3): set_value on a checkbox wants what the write sets
/// ("on" is 1), not the agent's word.
#[test]
fn a_set_value_wants_what_the_write_sets() {
    assert_eq!(roles::requested_value(true, "on").as_deref(), Some("1"));
    assert_eq!(roles::requested_value(true, "false").as_deref(), Some("0"));
    assert_eq!(roles::requested_value(true, "2.0").as_deref(), Some("2"));
    assert_eq!(roles::requested_value(true, "0.5").as_deref(), Some("0.5"));
    assert_eq!(roles::requested_value(false, "on").as_deref(), Some("on"));
    assert_eq!(roles::requested_value(true, "big"), None);
}

/// Review of 02ca109 (5): web content is the element itself or an ancestor,
/// read strictly; an unread walk counts as web content (keys route).
#[test]
fn web_content_is_the_element_or_an_ancestor_and_unknown_counts() {
    use roles::Web;
    let roles = |v: &[&str]| Some(v.iter().map(|s| s.to_string()).collect::<Vec<_>>());
    assert_eq!(roles::web_content(roles(&["AXWebArea", "AXScrollArea", "AXWindow"])), Web::In);
    assert_eq!(
        roles::web_content(roles(&["AXTextField", "AXGroup", "AXWebArea", "AXWindow"])),
        Web::In
    );
    assert_eq!(roles::web_content(roles(&["AXTextField", "AXGroup", "AXWindow"])), Web::Out);
    assert_eq!(roles::web_content(None), Web::Unknown);
}

/// Review of 2d96f16 (2): an unknown web walk takes each caller's safe
/// side: the native AX routes do not run (events and keys instead), and
/// the menu gate applies in full (unknown is not web, which would narrow
/// what it gates).
#[test]
fn an_unknown_web_walk_takes_the_safe_side_per_caller() {
    use roles::{Web, menu_gate_web, native_route};
    assert!(native_route(Web::Out));
    assert!(!native_route(Web::In));
    assert!(!native_route(Web::Unknown), "unknown: events or keys");
    assert!(menu_gate_web(Web::In));
    assert!(!menu_gate_web(Web::Out));
    assert!(!menu_gate_web(Web::Unknown), "unknown: the full menu gate");
    // The full gate: a menu button opens a menu unless known to be web.
    assert!(roles::opens_menu("AXMenuButton", menu_gate_web(Web::Unknown), false));
}

/// Review of 2d96f16 (1): a stepper's read-back allows half a step around
/// its target: one step short does not reach it, one step moved from one
/// step away is a change.
#[test]
fn a_stepper_tolerance_is_half_a_step() {
    let tol = roles::step_tolerance(1.0);
    assert!(!readback::value_matches("9", "10", Some(tol)), "one step short");
    assert!(readback::value_matches("10", "10", Some(tol)));
    assert!(readback::value_matches("10.4", "10", Some(tol)), "rounding within half a step");
    assert!(!readback::value_matches("9", "10", Some(roles::step_tolerance(1.0))), "not already");
}

/// Review of 02ca109 (4): only a clear rejection of an AX insert falls back
/// to keys; a timeout or cannot-complete may have applied it.
#[test]
fn only_a_rejected_insert_falls_back_to_keys() {
    assert!(roles::press_error_falls_back(-25201), "illegal argument");
    assert!(roles::press_error_falls_back(-25205), "attribute unsupported");
    assert!(!roles::press_error_falls_back(-25204), "cannot complete");
    assert!(!roles::press_error_falls_back(-25200), "failure");
}

/// Review of d890b98 (2): the web walk ends only at the window or the app; a
/// walk that stops anywhere else (a missing parent, an unreadable role) is
/// unknown, never "not web".
#[test]
fn a_web_walk_that_stops_short_is_unknown() {
    use roles::Web;
    let roles = |v: &[&str]| Some(v.iter().map(|s| s.to_string()).collect::<Vec<_>>());
    assert_eq!(roles::web_content(roles(&["AXTextField", "AXGroup", "AXWindow"])), Web::Out);
    assert_eq!(
        roles::web_content(roles(&["AXTextField", "AXGroup"])),
        Web::Unknown,
        "stopped short"
    );
    assert_eq!(
        roles::web_content(roles(&["AXTextField", "AXGroup", ""])),
        Web::Unknown,
        "blank role"
    );
    assert_eq!(roles::web_content(roles(&[])), Web::Unknown);
}

/// Review of e28e981 (1): keys follow an AX focus write only on the guard's
/// rules. The app naming none (a background app) needs the target's own
/// focus turned false to true by the write, its web host focused, one web
/// area (an iframe refused) and no sheet or second window with no focused
/// window; the app naming another element posts none.
#[test]
#[allow(clippy::redundant_clone)] // each case starts from the same facts
fn keys_follow_a_focus_write_only_on_the_guards_rules() {
    use roles::{FocusFacts, focus_guard};
    let safari_bg = FocusFacts {
        app_names_target: None,
        own_before: Some(false),
        own_after: Some(true),
        in_web: true,
        web_areas: 1,
        host_focused: Some(true),
        no_focused_window: false,
        other_targets: false,
    };
    assert!(focus_guard(&safari_bg));
    assert!(focus_guard(&FocusFacts { app_names_target: Some(true), ..safari_bg.clone() }));
    assert!(
        !focus_guard(&FocusFacts { app_names_target: Some(false), ..safari_bg.clone() }),
        "another element"
    );
    assert!(
        !focus_guard(&FocusFacts { own_before: Some(true), ..safari_bg.clone() }),
        "already focused: no change seen"
    );
    assert!(!focus_guard(&FocusFacts { own_before: None, ..safari_bg.clone() }));
    assert!(
        !focus_guard(&FocusFacts { host_focused: Some(false), ..safari_bg.clone() }),
        "inspector or other web view has the keys"
    );
    assert!(!focus_guard(&FocusFacts { host_focused: None, ..safari_bg.clone() }));
    assert!(!focus_guard(&FocusFacts { web_areas: 2, ..safari_bg.clone() }), "an iframe");
    assert!(
        !focus_guard(&FocusFacts {
            web_areas: 2,
            app_names_target: Some(true),
            ..safari_bg.clone()
        }),
        "an iframe"
    );
    assert!(
        !focus_guard(&FocusFacts {
            no_focused_window: true,
            other_targets: true,
            ..safari_bg.clone()
        }),
        "a sheet or a second window"
    );
    let native =
        FocusFacts { in_web: false, web_areas: 0, host_focused: None, ..safari_bg.clone() };
    assert!(focus_guard(&native), "outside web content no host is needed");
}

/// Coordinator, after 8a4399f: typing into web content without proven focus
/// writes before[..start] + text + before[end..] (UTF-16) into the value;
/// a range outside the value writes nothing.
#[test]
fn web_typing_inserts_into_the_value_at_the_selection() {
    assert_eq!(roles::insert_at("", "Zed", 0, 0).as_deref(), Some("Zed"));
    assert_eq!(roles::insert_at("ab", "Z", 1, 0).as_deref(), Some("aZb"));
    assert_eq!(
        roles::insert_at("aXXb", "Z", 1, 2).as_deref(),
        Some("aZb"),
        "replaces the selection"
    );
    assert_eq!(roles::insert_at("é1", "Z", 1, 0).as_deref(), Some("éZ1"), "UTF-16 offsets");
    assert_eq!(
        roles::insert_at("😀", "Z", 2, 0).as_deref(),
        Some("😀Z"),
        "a surrogate pair counts two"
    );
    assert_eq!(roles::insert_at("ab", "Z", 3, 0), None, "past the end");
    assert_eq!(roles::insert_at("ab", "Z", -1, 0), None);
}

/// The web value route writes only where a value is the content: a plain
/// text input, visible, not a password field (set_value may write one).
#[test]
#[allow(clippy::redundant_clone)]
fn the_web_value_route_writes_only_into_plain_visible_text_fields() {
    let plain = roles::WebField {
        kind: roles::WebKind::Plain,
        secure: false,
        width: 200.0,
        height: 22.0,
        on_screen: true,
        hidden: false,
        limited: false,
        center: Point { x: 0.0, y: 0.0 },
    };
    let typing = roles::SecureField::Refuse;
    assert!(roles::web_value_gate(Some(&plain), typing).is_ok());
    let not = |f: roles::WebField| roles::web_value_gate(Some(&f), typing).is_err();
    assert!(not(roles::WebField { secure: true, ..plain.clone() }), "password");
    assert!(not(roles::WebField { kind: roles::WebKind::Rich, ..plain.clone() }), "rich editor");
    assert!(not(roles::WebField { kind: roles::WebKind::Area, ..plain.clone() }), "text area");
    assert!(
        not(roles::WebField { kind: roles::WebKind::Other, ..plain.clone() }),
        "another control"
    );
    assert!(not(roles::WebField { width: 1.0, height: 1.0, ..plain.clone() }), "xterm-like helper");
    assert!(not(roles::WebField { on_screen: false, ..plain.clone() }), "off screen");
    assert!(not(roles::WebField { hidden: true, ..plain.clone() }), "hidden");
    assert!(roles::web_value_gate(None, typing).is_err(), "unread");
    // set_value writes a password field's value (it is read back by length),
    // and nothing else the typing gate refuses.
    let setting = roles::SecureField::Allow;
    assert!(
        roles::web_value_gate(Some(&roles::WebField { secure: true, ..plain.clone() }), setting)
            .is_ok()
    );
    for kind in [roles::WebKind::Rich, roles::WebKind::Area, roles::WebKind::Other] {
        assert!(
            roles::web_value_gate(Some(&roles::WebField { kind, ..plain.clone() }), setting)
                .is_err()
        );
    }
    let proxy = roles::WebField { width: 12.0, height: 6.0, ..plain.clone() };
    assert!(roles::web_value_gate(Some(&proxy), setting).is_err(), "a padded 1x1 helper");
}

/// Live in Safari (macOS 27.0.1): an <input> has no children; a native
/// <textarea> and a one-paragraph contenteditable (an empty ProseMirror
/// `<p><br></p>`, a one-paragraph Quill, a one-line CodeMirror 6) are both an
/// AXTextArea with one AXGroup child, with the same attributes, settable
/// attributes, parameterized attributes and actions: nothing tells them apart,
/// so a web text area is never written this way. A text field with children
/// (role="textbox" on rich content) is rich; a combobox is another control.
#[test]
fn only_a_childless_web_text_field_is_plain() {
    assert_eq!(roles::web_kind("AXTextField", 0), roles::WebKind::Plain);
    assert_eq!(roles::web_kind("AXSearchField", 0), roles::WebKind::Plain);
    assert_eq!(roles::web_kind("AXTextField", 1), roles::WebKind::Rich, "role=textbox");
    assert_eq!(roles::web_kind("AXSearchField", 2), roles::WebKind::Rich);
    assert_eq!(roles::web_kind("AXTextArea", 1), roles::WebKind::Area, "textarea or one paragraph");
    assert_eq!(roles::web_kind("AXTextArea", 0), roles::WebKind::Area);
    assert_eq!(roles::web_kind("AXComboBox", 0), roles::WebKind::Other, "Google search");
    assert_eq!(roles::web_kind("AXGroup", 0), roles::WebKind::Other);
}

/// A plain field the page is scrolled past is scrolled into view before the
/// gate, and only once every other rule holds: a tiny, hidden, rich or
/// password field (for typing) is refused without scrolling.
#[test]
#[allow(clippy::redundant_clone)]
fn only_a_plain_field_scrolled_past_is_scrolled_into_view() {
    let past = roles::WebField {
        kind: roles::WebKind::Plain,
        secure: false,
        width: 200.0,
        height: 22.0,
        on_screen: false,
        hidden: false,
        limited: false,
        center: Point { x: 0.0, y: 0.0 },
    };
    let typing = roles::SecureField::Refuse;
    let setting = roles::SecureField::Allow;
    let scrolls = |f: &roles::WebField, s| roles::scroll_into_view_first(f, s);
    assert!(scrolls(&past, typing));
    assert!(roles::web_value_gate_but_view(&past, typing).is_ok());
    assert!(roles::web_value_gate(Some(&past), typing).is_err(), "out of view until scrolled");
    assert!(!scrolls(&roles::WebField { on_screen: true, ..past.clone() }, typing));
    assert!(!scrolls(&roles::WebField { hidden: true, ..past.clone() }, typing));
    assert!(!scrolls(&roles::WebField { width: 1.0, ..past.clone() }, typing));
    assert!(!scrolls(&roles::WebField { kind: roles::WebKind::Area, ..past.clone() }, setting));
    let password = roles::WebField { secure: true, ..past.clone() };
    assert!(!scrolls(&password, typing), "typing refuses a password field first");
    assert!(scrolls(&password, setting));
}

/// Background typing into web content tries keys first: the value route is
/// the fallback only when the guard refused focus and the field is
/// eligible; else the gate's reason (a Chrome or Electron composer, a
/// textarea, a contenteditable or text with Enter take keys when focused).
#[test]
fn web_typing_tries_keys_before_the_value_route() {
    assert_eq!(roles::web_typing(true, Ok(())), roles::WebTyping::Keys);
    assert_eq!(roles::web_typing(true, Err("textarea")), roles::WebTyping::Keys, "a composer");
    assert_eq!(roles::web_typing(false, Ok(())), roles::WebTyping::Value);
    assert_eq!(roles::web_typing(false, Err("textarea")), roles::WebTyping::Refuse("textarea"));
}

/// #13742: a targeted write into a field of the person's app only where
/// their caret is not; on it, around it, or unread: refused.
#[test]
fn a_targeted_write_in_the_persons_app_needs_their_caret_elsewhere() {
    assert!(roles::caret_allows_write(roles::Caret::Elsewhere));
    assert!(!roles::caret_allows_write(roles::Caret::OnTarget));
    assert!(!roles::caret_allows_write(roles::Caret::Unread), "fail closed");
    assert!(!roles::container_holds_caret("AXWindow"), "a focused window holds no caret");
    assert!(!roles::container_holds_caret("AXApplication"));
    assert!(roles::container_holds_caret("AXWebArea"), "the caret is in a field inside it");
    assert!(roles::container_holds_caret("AXGroup"));
}

/// Every targeted write into a field (its value, selected text, selection
/// or focus, or an attribute named at run time) in actions.rs, menus.rs and
/// mod.rs goes through the one caret gate (`persons_caret_write`), or
/// through `gated`, which refuses the person's app outright, or carries a
/// `caret-gate:` note saying why it is not a field write (each listed
/// here). `focus_and_select` is called only inside `gated`. A new write
/// site must be added here, gated.
#[test]
fn every_targeted_field_write_goes_through_the_caret_gate() {
    let files = [
        ("actions.rs", include_str!("actions.rs")),
        ("menus.rs", include_str!("menus.rs")),
        ("mod.rs", include_str!("mod.rs")),
    ];
    let writes = [
        "set(\"AXSelectedText\"",
        "set(\"AXValue\"",
        "set_selected_range(",
        "set(\"AXFocused\"",
        "set(attr",
    ];
    let fn_start = |l: &str| {
        let t = l.trim_start();
        t.starts_with("fn ")
            || t.starts_with("pub(super) fn ")
            || t.starts_with("pub fn ")
            || t.starts_with("pub(crate) fn ")
    };
    // Inside a gate call: the write is on the call's line, or in a block
    // (its closure) opened on a line that makes the call.
    let gate = |l: &str| {
        l.contains("persons_caret_write(")
            || l.contains("gated(d, t,")
            || l.contains("gated(d, &t,")
    };
    let mut sites = Vec::new();
    let mut exempt = Vec::new();
    for (file, src) in files {
        let lines: Vec<&str> = src.lines().collect();
        for (i, line) in lines.iter().enumerate() {
            if line.trim_start().starts_with("//") || !writes.iter().any(|w| line.contains(w)) {
                continue;
            }
            let start = (0..=i).rev().find(|&j| fn_start(lines[j])).expect("an enclosing fn");
            let after_fn = lines[start].split("fn ").nth(1).unwrap_or("");
            let name: String =
                after_fn.chars().take_while(|c| c.is_alphanumeric() || *c == '_').collect();
            if line.contains("// caret-gate:") {
                exempt.push(format!("{file}:{name}"));
                continue;
            }
            let mut gated = gate(line);
            let mut depth = 0i32;
            for j in (start..i).rev() {
                let l = lines[j];
                depth += l.matches('}').count() as i32 - l.matches('{').count() as i32;
                if depth < 0 {
                    // A block enclosing the write opens on line j.
                    if gate(l) {
                        gated = true;
                        break;
                    }
                    depth = 0;
                }
            }
            sites.push((format!("{file}:{name}"), gated, i + 1));
        }
        for (i, line) in lines.iter().enumerate() {
            if line.contains("focus_and_select(")
                && !fn_start(line)
                && !line.trim_start().starts_with("//")
            {
                assert!(
                    line.contains("gated(d, t,"),
                    "{file}:{}: focus_and_select outside gated",
                    i + 1
                );
            }
        }
    }
    for (name, gated, line) in &sites {
        assert!(
            *gated || name == "actions.rs:focus_and_select",
            "{name} (line {line}) writes outside the caret gate"
        );
    }
    let mut names: Vec<&str> = sites.iter().map(|(n, _, _)| n.as_str()).collect();
    names.sort_unstable();
    names.dedup();
    assert_eq!(
        names,
        [
            "actions.rs:ax_insert",
            "actions.rs:ax_scroll_run",
            "actions.rs:caret_off_and_back",
            "actions.rs:focus_and_select",
            "actions.rs:set_value",
            "actions.rs:slider_drag",
            "actions.rs:type_text",
            "actions.rs:web_focus",
            "actions.rs:web_value_write",
            "actions.rs:write_attribute",
        ],
        "a new field write site: route it through persons_caret_write and list it here"
    );
    exempt.sort_unstable();
    assert_eq!(
        exempt,
        ["actions.rs:show_web_content", "actions.rs:write_attribute", "mod.rs:restore_focus"],
        "a new caret-gate exemption: say why it is not a field write and list it here"
    );
}

/// After a web value write: confirmed only while the field still holds the
/// page's focus (its own, and the web area's focused element where read).
#[test]
fn a_web_value_write_is_kept_only_while_focus_stays() {
    assert!(roles::kept_focus(Some(true), Some(true)));
    assert!(roles::kept_focus(Some(true), None), "the area's focus unread");
    assert!(!roles::kept_focus(Some(true), Some(false)), "the area names another field");
    assert!(!roles::kept_focus(Some(false), Some(true)));
    assert!(!roles::kept_focus(None, Some(true)));
}

/// Safari puts a text field's AXValue write into the field holding the
/// page's focus: a web value write is made only while the target holds it.
#[test]
fn a_web_value_write_needs_the_page_focus() {
    assert!(roles::holds_page_focus(Some(true)));
    assert!(!roles::holds_page_focus(Some(false)));
    assert!(!roles::holds_page_focus(None), "unread");
}

/// A value write that errors may still have applied, unless the error says
/// the write was refused outright (illegal argument, unsupported).
#[test]
fn only_a_refusing_ax_error_means_the_value_was_not_written() {
    use super::sys::{
        AX_ACTION_UNSUPPORTED, AX_ATTRIBUTE_UNSUPPORTED, AX_CANNOT_COMPLETE, AX_ILLEGAL_ARGUMENT,
        AX_INVALID_ELEMENT,
    };
    for e in [AX_ILLEGAL_ARGUMENT, AX_ATTRIBUTE_UNSUPPORTED, AX_ACTION_UNSUPPORTED] {
        assert!(roles::write_not_applied(e), "{e}");
    }
    for e in [AX_CANNOT_COMPLETE, AX_INVALID_ELEMENT, -25200, -25212] {
        assert!(!roles::write_not_applied(e), "{e}");
    }
}

/// The note says where the text went and how much it replaced.
#[test]
fn the_web_value_note_names_the_position_and_the_replaced_characters() {
    let n = roles::web_value_note(3, 0, false, false);
    assert!(n.contains("position 3") && !n.contains("replac"), "{n}");
    let n = roles::web_value_note(0, 5, true, true);
    assert!(n.contains("replacing the 5 selected characters"), "{n}");
    assert!(n.contains("length limit") && !n.contains("pattern"), "{n}");
    assert!(n.contains("scrolled to bring the field into view"), "{n}");
    assert!(roles::web_value_note(0, 1, false, false).contains("the 1 selected character,"));
}

/// The menu-bar check walks strictly: only the menu bar, the window or the
/// application end it; anything unread refuses (check_menu_item).
#[test]
fn the_menu_bar_walk_ends_only_at_known_roots() {
    assert_eq!(roles::menu_bar_walk_step("AXMenuBar"), Some(true));
    assert_eq!(roles::menu_bar_walk_step("AXWindow"), Some(false));
    assert_eq!(roles::menu_bar_walk_step("AXApplication"), Some(false));
    assert_eq!(roles::menu_bar_walk_step("AXGroup"), None);
    assert_eq!(roles::menu_bar_walk_step("AXButton"), None);
    assert_eq!(roles::menu_bar_walk_step("AXMenuItem"), None);
    assert_eq!(roles::menu_bar_walk_step("AXMenu"), None);
    assert_eq!(roles::menu_bar_walk_step("AXMenuBarItem"), None);
}

/// Review of 431ddaa: an element 25 or 30 levels deep in a window (VS Code,
/// Slack, a deep web page) is not in the menu bar; the walk's cap of 16
/// refused every click on it. The walk still ends only at the menu bar, a
/// window or the application, so a subview of a menu item's custom view is
/// in the menu bar; an unreadable role, or a walk past the cap, is unknown.
#[test]
fn a_deep_element_is_not_in_the_menu_bar() {
    let chain =
        |roles: Vec<&'static str>| move |depth: usize| roles.get(depth).map(|r| (*r).to_string());
    let mut deep = vec!["AXButton"];
    deep.extend(std::iter::repeat_n("AXGroup", 24));
    deep.push("AXWindow");
    assert_eq!(roles::menu_bar_walk(chain(deep)), Some(false));
    let mut deep_web = vec!["AXGroup"; 30];
    deep_web.extend(["AXWebArea", "AXScrollArea", "AXGroup", "AXWindow", "AXApplication"]);
    assert_eq!(roles::menu_bar_walk(chain(deep_web)), Some(false));
    let item = vec!["AXMenuItem", "AXMenu", "AXMenuItem", "AXMenu", "AXMenuBarItem", "AXMenuBar"];
    assert_eq!(roles::menu_bar_walk(chain(item)), Some(true));
    // A subview of a menu item's custom view (Help's search field, a
    // volume-style slider) has its own role and is in the menu bar.
    let custom = vec!["AXButton", "AXGroup", "AXMenuItem", "AXMenu", "AXMenuBarItem", "AXMenuBar"];
    assert_eq!(roles::menu_bar_walk(chain(custom)), Some(true));
    let field = vec!["AXSearchField", "AXMenuItem", "AXMenu", "AXMenuBarItem", "AXMenuBar"];
    assert_eq!(roles::menu_bar_walk(chain(field)), Some(true));
    // The parent of a menu item cannot be read: unknown, refused.
    assert_eq!(roles::menu_bar_walk(chain(vec!["AXMenuItem", "AXMenu"])), None);
    // Past the cap without reaching a root: unknown.
    assert_eq!(roles::menu_bar_walk(chain(vec!["AXGroup"; roles::MENU_WALK_MAX + 1])), None);
}

#[test]
fn a_webkit_page_takes_its_focus_through_the_caret_never_an_axfocused_write() {
    use roles::{WebEngine, WebFocusWrite, web_engine, web_focus_write};
    // Safari activates itself after an AXFocused write into its page when
    // it may (it was the active app before): the caret write moves the
    // page's focus without that.
    for id in ["com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.example.webviewapp"] {
        assert_eq!(web_focus_write(web_engine(Some(id))), WebFocusWrite::Caret, "{id}");
    }
    assert_eq!(web_focus_write(web_engine(None)), WebFocusWrite::Caret, "unknown app");
    // Chromium never activates itself for it, and a contenteditable takes
    // no focus from a caret write there.
    for id in [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "COM.BRAVE.BROWSER",
        "company.thebrowser.Browser",
    ] {
        assert_eq!(web_engine(Some(id)), WebEngine::Chromium, "{id}");
        assert_eq!(web_focus_write(web_engine(Some(id))), WebFocusWrite::Focused, "{id}");
    }
    assert_eq!(roles::caret_at_end(""), 0);
    assert_eq!(roles::caret_at_end("a😀b"), 4, "UTF-16");
}

#[test]
fn background_web_keys_go_only_where_the_page_has_the_keyboard() {
    use roles::{AppFocus, WebKeyFacts, web_keys_guard};
    // Safari in the background, its web view the window's keyboard focus:
    // the app names no focused element; the field holds its page's focus.
    let safari = WebKeyFacts {
        own: Some(true),
        app_focus: Some(AppFocus::Nothing),
        web_areas: 1,
        other_web_views: Some(false),
        no_focused_window: false,
        other_targets: false,
    };
    assert_eq!(web_keys_guard(&safari), Ok(()));
    // Chrome names the field, or an element of its page.
    assert_eq!(
        web_keys_guard(&WebKeyFacts { app_focus: Some(AppFocus::Target), ..safari }),
        Ok(())
    );
    assert_eq!(
        web_keys_guard(&WebKeyFacts { app_focus: Some(AppFocus::InPage), ..safari }),
        Ok(())
    );
    // The address bar (live: Safari typed the text into it).
    assert!(web_keys_guard(&WebKeyFacts { app_focus: Some(AppFocus::Outside), ..safari }).is_err());
    assert!(web_keys_guard(&WebKeyFacts { app_focus: None, ..safari }).is_err(), "unread");
    assert!(web_keys_guard(&WebKeyFacts { own: Some(false), ..safari }).is_err());
    assert!(web_keys_guard(&WebKeyFacts { own: None, ..safari }).is_err());
    assert!(web_keys_guard(&WebKeyFacts { web_areas: 2, ..safari }).is_err(), "an iframe");
    assert!(
        web_keys_guard(&WebKeyFacts { other_web_views: Some(true), ..safari }).is_err(),
        "a docked inspector also names nothing"
    );
    assert!(web_keys_guard(&WebKeyFacts { other_web_views: None, ..safari }).is_err());
    assert!(
        web_keys_guard(&WebKeyFacts { no_focused_window: true, other_targets: true, ..safari })
            .is_err()
    );
    assert_eq!(
        web_keys_guard(&WebKeyFacts { no_focused_window: true, other_targets: false, ..safari }),
        Ok(())
    );
}

#[test]
fn chromium_shows_its_pages_once_asked_like_a_screen_reader() {
    use roles::{web_accessibility_attribute, web_engine};
    assert_eq!(
        web_accessibility_attribute(web_engine(Some("com.google.Chrome"))),
        Some("AXEnhancedUserInterface")
    );
    assert_eq!(web_accessibility_attribute(web_engine(Some("com.apple.Safari"))), None);
    assert_eq!(web_accessibility_attribute(web_engine(None)), None);
}

#[test]
fn a_webkit_field_typed_into_with_keys_gets_its_caret_written_again() {
    use roles::{settles_caret_after_keys, web_engine};
    // Safari applied a pending autocorrection ("cmux" -> "crux") at the next
    // call's caret write into another field, after this one said confirmed.
    assert!(settles_caret_after_keys(web_engine(Some("com.apple.Safari"))));
    assert!(settles_caret_after_keys(web_engine(None)), "an unknown app is WebKit's rule");
    assert!(!settles_caret_after_keys(web_engine(Some("com.google.Chrome"))));
}

#[test]
fn after_keys_in_a_webkit_field_the_caret_leaves_the_typed_word_and_comes_back() {
    use roles::settle_caret_writes;
    // Live, Safari on macOS 26.6 (fresh words, 9/10): a caret written back
    // where it is right after the keys left the autocorrection to arrive
    // later and land at the next call's focus move ("Hello from wierd" ->
    // "weird"); moving the caret to where the typing began and back ended
    // the typing context (8/8 kept, single words too).
    assert_eq!(
        settle_caret_writes((15, 0), 15),
        vec![(0, 0), (15, 0)],
        "typed into an empty field"
    );
    assert_eq!(settle_caret_writes((9, 0), 5), vec![(4, 0), (9, 0)], "typed after other text");
    assert_eq!(settle_caret_writes((5, 0), 5), vec![(0, 0), (5, 0)], "a single word");
    assert_eq!(settle_caret_writes((3, 0), 7), vec![(0, 0), (3, 0)], "clamped at the start");
    assert_eq!(
        settle_caret_writes((6, 2), 3),
        vec![(3, 0), (6, 2)],
        "a selection is put back as it was"
    );
    assert_eq!(
        settle_caret_writes((0, 0), 0),
        Vec::<(isize, isize)>::new(),
        "nothing typed: no writes"
    );
    assert_eq!(
        settle_caret_writes((4, 0), 0),
        Vec::<(isize, isize)>::new(),
        "nothing typed: the caret is not moved"
    );
}

#[test]
fn safaris_autocorrection_bubble_is_watched_dismissed_or_reported() {
    use crate::desktop::Rect;
    use roles::{Autocorrection, autocorrection, is_correction_bubble, may_be_autocorrected};
    // Text whose last word ends it can be corrected later; text ending in a
    // space or punctuation was never corrected (live, 26.6).
    assert!(may_be_autocorrected("Hello from wierd"));
    assert!(may_be_autocorrected("wierd"));
    assert!(may_be_autocorrected("café"));
    assert!(!may_be_autocorrected("Hello from wierd "));
    assert!(!may_be_autocorrected("Hello from wierd."));
    assert!(!may_be_autocorrected("Zq9 9"));
    assert!(!may_be_autocorrected(""));
    // The bubble: two untitled windows, about 97x49 and 81x22, at the field.
    let field = Rect { x: 640.0, y: 130.0, width: 250.0, height: 22.0 };
    let r = |x: f64, y: f64, w: f64, h: f64| Rect { x, y, width: w, height: h };
    assert!(is_correction_bubble("", 0, true, true, &r(700.0, 150.0, 97.0, 49.0), &field));
    assert!(is_correction_bubble("", 0, true, true, &r(705.0, 156.0, 81.0, 22.0), &field));
    assert!(
        !is_correction_bubble("", 0, true, false, &r(700.0, 150.0, 97.0, 49.0), &field),
        "there before the keys"
    );
    assert!(
        !is_correction_bubble("webtype", 0, true, true, &r(700.0, 150.0, 97.0, 49.0), &field),
        "titled"
    );
    assert!(
        !is_correction_bubble("", 0, false, true, &r(700.0, 150.0, 97.0, 49.0), &field),
        "off screen"
    );
    assert!(
        !is_correction_bubble("", 3, true, true, &r(700.0, 150.0, 97.0, 49.0), &field),
        "another layer"
    );
    assert!(
        !is_correction_bubble("", 0, true, true, &r(660.0, 60.0, 760.0, 800.0), &field),
        "a page-sized window"
    );
    assert!(
        !is_correction_bubble("", 0, true, true, &r(100.0, 600.0, 97.0, 49.0), &field),
        "far from the field"
    );
    // What the watch found.
    assert_eq!(autocorrection(false, false), Autocorrection::NoneOffered);
    assert_eq!(autocorrection(true, false), Autocorrection::Dismissed);
    assert_eq!(autocorrection(true, true), Autocorrection::StillOffered);
}
