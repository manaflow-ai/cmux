use super::*;
use crate::hub::turn_frames::{FULL_WIDTH, Rgb, THUMB_WIDTH, decode, dhash, encode, shrink};
use std::cell::RefCell;

fn shell(command: &str) -> Value {
    json!({"kind": "execute", "rawInput": {"command": command}})
}

fn app(command: &str) -> Option<String> {
    runs_mac_app(&shell(command))
}

#[test]
fn launching_a_mac_app_is_told_from_the_command() {
    assert_eq!(app("open -a Notes").as_deref(), Some("Notes"));
    assert_eq!(app("open -a /Applications/Safari.app").as_deref(), Some("Safari"));
    assert_eq!(app("open -b com.example.Demo").as_deref(), Some("com.example.Demo"));
    assert_eq!(
        app("open 'build/Build/Products/Debug/My App.app/' --args -x").as_deref(),
        Some("My App")
    );
    assert_eq!(app("swift build && swift run Demo").as_deref(), Some("Demo"));
    assert_eq!(app("swift run -c release --package-path pkg Demo --flag").as_deref(), Some("Demo"));
    assert_eq!(app("RUST_LOG=1 nohup .build/debug/Demo &").as_deref(), Some("Demo"));
    assert_eq!(app("./DerivedData/Build/Products/Debug/Demo.app/Contents/MacOS/Demo").as_deref(), Some("Demo"));
    // Arrays of words, as some harnesses send.
    let words = json!({"rawInput": {"command": ["open", "-a", "Notes"]}});
    assert_eq!(runs_mac_app(&words).as_deref(), Some("Notes"));
}

#[test]
fn other_commands_launch_no_app() {
    for command in [
        "swift run",
        "swift build",
        "swift test",
        "open README.md",
        "open https://example.com",
        "cargo run",
        "ls .build/debug/",
        ".build/debug/libDemo.dylib",
        "cat Demo.app/Contents/Info.plist",
        "echo open -a Notes",
    ] {
        assert_eq!(app(command), None, "{command}");
    }
    assert_eq!(runs_mac_app(&json!({"kind": "edit", "rawInput": {"path": "a.swift"}})), None);
}

#[test]
fn only_a_mode_that_looks_without_asking_captures() {
    assert!(may_capture(&json!({"mode": "fullAccess"})));
    assert!(may_capture(&json!({"mode": "lookOnly", "screen_locked": false})));
    assert!(!may_capture(&json!({"mode": "fullAccess", "screen_locked": true})));
    for mode in ["approvedApps", "askEveryTime", "off", ""] {
        assert!(!may_capture(&json!({"mode": mode})), "{mode}");
    }
}

#[test]
fn the_front_shown_window_of_the_app_is_picked() {
    let listed = json!({"windows": [
        {"window_id": "1", "app_id": "com.apple.Terminal", "app_name": "Terminal", "on_screen": true},
        {"window_id": "2", "app_id": "com.example.demo", "app_name": "Demo", "on_screen": true, "minimized": true},
        {"window_id": "3", "app_id": "com.example.demo", "app_name": "Demo", "on_screen": false},
        {"window_id": "4", "app_id": "com.example.demo", "app_name": "Demo", "on_screen": true, "denied": true},
        {"window_id": 5, "app_id": "com.example.demo", "app_name": "Demo", "on_screen": true},
        {"window_id": "6", "app_id": "com.example.demo", "app_name": "Demo", "on_screen": true},
    ]});
    assert_eq!(front_window(&listed, "demo").as_deref(), Some("5"));
    assert_eq!(front_window(&listed, "com.example.Demo").as_deref(), Some("5"));
    assert_eq!(front_window(&listed, "Terminal").as_deref(), Some("1"));
    assert_eq!(front_window(&listed, "Notes"), None);
    assert_eq!(front_window(&json!({}), "Demo"), None);
}

/// A worker that answers from a script and keeps what it was asked.
struct Fake {
    mode: &'static str,
    png: Option<String>,
    asked: RefCell<Vec<(String, Value)>>,
}

impl Worker for Fake {
    fn call(&self, name: &str, arguments: Value) -> Option<ToolOutput> {
        self.asked.borrow_mut().push((name.to_owned(), arguments));
        Some(match name {
            "status" => ToolOutput::ok(json!({"mode": self.mode})),
            "list_windows" => ToolOutput::ok(json!({"windows": [
                {"window_id": "w9", "app_id": "com.example.Demo", "app_name": "Demo", "on_screen": true}
            ]})),
            "screenshot" => ToolOutput {
                png_base64: self.png.clone(),
                ..ToolOutput::ok(json!({"width": 2, "height": 1}))
            },
            _ => return None,
        })
    }
}

#[test]
fn a_capture_screenshots_the_apps_window_and_decodes_it() {
    use base64::Engine as _;
    let png = encode(&Rgb { width: 2, height: 1, pixels: vec![0, 0, 0, 255, 255, 255] }).unwrap();
    let fake = Fake {
        mode: "lookOnly",
        png: Some(base64::engine::general_purpose::STANDARD.encode(&png)),
        asked: RefCell::default(),
    };
    assert_eq!(capture_with(&fake, "Demo"), Ok(png));
    let last = fake.asked.borrow().last().cloned().unwrap();
    assert_eq!(last, ("screenshot".into(), json!({"window_id": "w9", "force": true})));
    assert_eq!(capture_with(&fake, "Other"), Err("no window"));
}

#[test]
fn a_mode_that_would_ask_takes_no_screenshot() {
    let fake = Fake { mode: "askEveryTime", png: Some(String::new()), asked: RefCell::default() };
    assert_eq!(capture_with(&fake, "Demo"), Err("asks first"));
    assert_eq!(fake.asked.borrow().len(), 1, "only status: no list, no screenshot");
    let blank = Fake { mode: "fullAccess", png: None, asked: RefCell::default() };
    assert_eq!(capture_with(&blank, "Demo"), Err("no picture"));
}

#[test]
fn off_a_mac_or_with_no_worker_there_is_no_frame() {
    let out = std::env::temp_dir().join(format!("turn-frames-native-{}.png", std::process::id()));
    if !cfg!(target_os = "macos") {
        assert!(!native_shot("chat", "Demo", &out));
        assert!(!out.exists());
    }
}

/// The duress number for a native window frame: the daemon's own work on one 2880x1800 (a Retina
/// 1440x900 window) capture as the worker hands it (base64 decode, PNG decode, dHash, 1280 and 320 px
/// encodes), what each frame costs beyond the worker's screenshot.
#[test]
#[ignore = "measurement: cargo test -p acpmux --lib --release native_frame_cost -- --ignored --nocapture"]
fn native_frame_cost() {
    use base64::Engine as _;
    let (width, height) = (2880u32, 1800u32);
    let mut pixels = Vec::with_capacity((width * height * 3) as usize);
    for y in 0..height {
        for x in 0..width {
            let v = if x < 900 { 30 } else if y < 120 { 200 } else { 245 };
            pixels.extend_from_slice(&[v, v, v]);
        }
    }
    let png = encode(&Rgb { width, height, pixels }).unwrap();
    let wire = base64::engine::general_purpose::STANDARD.encode(&png);
    let rounds = 20;
    let started = std::time::Instant::now();
    for _ in 0..rounds {
        let bytes = base64::engine::general_purpose::STANDARD.decode(&wire).unwrap();
        let picture = decode(&bytes).unwrap();
        let _ = dhash(&picture);
        let _ = encode(&shrink(&picture, FULL_WIDTH, None)).unwrap();
        let _ = encode(&shrink(&picture, THUMB_WIDTH, None)).unwrap();
    }
    let each = started.elapsed() / rounds;
    println!("native frame: {} KB in, {each:?} of daemon CPU each", png.len() / 1024);
}
