//! Live checks of the Windows desktop against real apps. They need an
//! interactive, unlocked session (not SSH's session 0), so they are
//! ignored by default:
//!
//! ```text
//! cargo test -p cmux-computer-use --target x86_64-pc-windows-gnu live_ -- --ignored --test-threads=1
//! ```
//!
//! `CMUX_CU_EVIDENCE=<dir>` saves the screenshots and trees they take.

use std::path::PathBuf;
use std::time::{Duration, Instant};

use super::WindowsDesktop;
use crate::cursor::CursorEvent;
use crate::desktop::*;
use crate::frame;
use crate::keys::KeyCombo;

fn evidence(name: &str, bytes: &[u8]) {
    if let Ok(dir) = std::env::var("CMUX_CU_EVIDENCE") {
        let dir = PathBuf::from(dir);
        let _ = std::fs::create_dir_all(&dir);
        let _ = std::fs::write(dir.join(name), bytes);
    }
}

fn png(name: &str, f: &RawFrame) {
    let encoded = frame::encode_png(f.width, f.height, &f.rgba).expect("png");
    evidence(name, &encoded);
}

fn find(d: &WindowsDesktop, app: &str, deadline: Duration) -> Window {
    let end = Instant::now() + deadline;
    loop {
        if let Some(w) = d.list_windows().expect("list").into_iter().find(|w| w.app_id == app) {
            return w;
        }
        assert!(Instant::now() < end, "no {app} window appeared");
        std::thread::sleep(Duration::from_millis(200));
    }
}

fn first<'a>(e: &'a Element, pred: &dyn Fn(&Element) -> bool) -> Option<&'a Element> {
    if pred(e) {
        return Some(e);
    }
    e.children.iter().find_map(|c| first(c, pred))
}

fn wait_for(mut cond: impl FnMut() -> bool) -> bool {
    let end = Instant::now() + Duration::from_secs(5);
    while Instant::now() < end {
        if cond() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    false
}

fn edit_text(d: &WindowsDesktop, w: &Window) -> String {
    let tree = d.ui_tree(&w.id, TreeOptions::default()).expect("tree");
    first(&tree.root, &|e| e.role == "text_field" || e.role == "document")
        .map(|e| e.value.clone())
        .unwrap_or_default()
}

#[test]
#[ignore = "needs an interactive Windows session"]
fn live_desktop_end_to_end() {
    let d = WindowsDesktop::new().expect("desktop");
    let info = d.info();
    let perms = d.permissions();
    evidence(
        "info.json",
        serde_json::to_string_pretty(&(&info, &perms)).unwrap_or_default().as_bytes(),
    );
    assert_eq!(perms.input, Grant::NotNeeded, "session not interactive: {info:?}");

    let apps = d.list_apps().expect("apps");
    let windows = d.list_windows().expect("windows");
    evidence("apps.json", serde_json::to_string_pretty(&apps).unwrap_or_default().as_bytes());
    evidence("windows.json", serde_json::to_string_pretty(&windows).unwrap_or_default().as_bytes());

    // The agent cursor's sprite at 100% and 200%, as drawn (premultiplied
    // BGRA composed over white).
    for (name, scale) in [("cursor-sprite-1x.png", 1.15), ("cursor-sprite-2x.png", 2.3)] {
        let a = super::pure::arrow_bitmap(scale, crate::cursor::CMUX_BLUE, crate::cursor::OUTLINE);
        let rgba: Vec<u8> = a
            .bgra
            .chunks_exact(4)
            .flat_map(|p| {
                let over = |c: u8| c.saturating_add(255 - p[3]);
                [over(p[2]), over(p[1]), over(p[0]), 255]
            })
            .collect();
        evidence(name, &frame::encode_png(a.width as u32, a.height as u32, &rgba).expect("png"));
    }

    // The cursor overlay, created before the display shot.
    let cursor = super::cursor_overlay();
    let display = d.capture(&CaptureTarget::Display(None)).expect("display capture");
    assert!(display.width > 0 && display.height > 0);
    png("display.png", &display);

    let notepad = d.launch_app("notepad.exe").expect("launch notepad");
    evidence(
        "launched.json",
        serde_json::to_string_pretty(&notepad).unwrap_or_default().as_bytes(),
    );
    let w = find(&d, "notepad.exe", Duration::from_secs(15));
    let center = Point { x: w.frame.x + w.frame.width / 2.0, y: w.frame.y + w.frame.height / 2.0 };
    cursor.show(CursorEvent::Move {
        session: "live".into(),
        label: "live test".into(),
        at: center,
    });

    let shot = d.capture(&CaptureTarget::Window(w.id.clone())).expect("window capture");
    assert!(!super::pure::all_black(&shot.rgba), "notepad rendered black");
    png("notepad-before.png", &shot);

    let tree = d.ui_tree(&w.id, TreeOptions::default()).expect("tree");
    evidence(
        "notepad-tree.json",
        serde_json::to_string_pretty(&tree).unwrap_or_default().as_bytes(),
    );
    assert_eq!(tree.root.role, "window");

    // Background typing into the focused control.
    d.type_text(&w.id, None, "cmux background typing\n", Delivery::Background).expect("type");
    assert!(
        wait_for(|| edit_text(&d, &w).contains("cmux background typing")),
        "typed text did not land: {:?}",
        edit_text(&d, &w)
    );
    // A key in the background (End), and a refused ctrl combo.
    d.press_keys(&w.id, &KeyCombo::parse("End").expect("combo"), Delivery::Background)
        .expect("End");
    let refused =
        d.press_keys(&w.id, &KeyCombo::parse("ctrl+a").expect("combo"), Delivery::Background);
    assert!(matches!(refused, Err(DesktopError::Unsupported(_))), "{refused:?}");

    // set_value on the edit element (UIA Value pattern), when the edit has one.
    let tree = d.ui_tree(&w.id, TreeOptions::default()).expect("tree");
    if let Some(edit) = first(&tree.root, &|e| e.role == "text_field" || e.role == "document") {
        match d.set_value(&w.id, &edit.id, "set through UI Automation") {
            Ok(out) => evidence(
                "set-value.json",
                serde_json::to_string_pretty(&out).unwrap_or_default().as_bytes(),
            ),
            Err(e) => evidence("set-value.json", format!("{e}").as_bytes()),
        }
        // A stale id after a new walk.
        let _ = d.ui_tree(&w.id, TreeOptions::default()).expect("tree");
        assert!(matches!(d.set_value(&w.id, &edit.id, "x"), Err(DesktopError::StaleElement(_))));
    }

    // Scroll and a click by point in the background.
    d.scroll(&PointerTarget::Point { window_id: w.id.clone(), point: center }, 0.0, 3.0)
        .expect("scroll");
    let spec = ClickSpec {
        button: Button::Left,
        count: 1,
        modifiers: vec![],
        delivery: Delivery::Background,
    };
    d.click(&PointerTarget::Point { window_id: w.id.clone(), point: center }, &spec)
        .expect("click");
    let outside = Point { x: w.frame.x - 50.0, y: w.frame.y - 50.0 };
    assert!(
        d.click(&PointerTarget::Point { window_id: w.id.clone(), point: outside }, &spec).is_err()
    );

    cursor.show(CursorEvent::Click {
        session: "live".into(),
        label: "live test".into(),
        at: center,
        button: "left".into(),
    });
    std::thread::sleep(Duration::from_millis(400));
    png("notepad-after.png", &d.capture(&CaptureTarget::Window(w.id.clone())).expect("capture"));
    // The screen with the agent cursor on it, through GDI's screen DC.
    png("display-with-cursor.png", &d.capture(&CaptureTarget::Display(None)).expect("capture"));
    evidence("notepad-text.txt", edit_text(&d, &w).as_bytes());

    // Refusals before any input: a URI and a script are not apps.
    assert!(d.launch_app("ms-settings:privacy").is_err());
    assert!(d.launch_app("cmd.bat").is_err());
}

#[test]
#[ignore = "needs an interactive Windows session"]
fn live_activity_ignores_own_injection() {
    super::activity::note_injected();
    let activity = super::person_activity();
    // Our own SendInput right now must not count as the person's.
    assert!(activity.wait_idle(Duration::from_secs(3)));
}
