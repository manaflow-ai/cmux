use super::*;

/// A `width` x `height` picture whose left `split` columns are black and the rest white.
fn split(width: u32, height: u32, split: u32) -> Rgb {
    let mut pixels = Vec::new();
    for _ in 0..height {
        for x in 0..width {
            let v = if x < split { 0 } else { 255 };
            pixels.extend_from_slice(&[v, v, v]);
        }
    }
    Rgb { width, height, pixels }
}

#[test]
fn a_picture_round_trips_through_png() {
    let picture = split(40, 20, 10);
    let decoded = decode(&encode(&picture).unwrap()).unwrap();
    assert_eq!((decoded.width, decoded.height), (40, 20));
    assert_eq!(decoded.pixels, picture.pixels);
}

#[test]
fn a_look_picture_encodes_as_jpeg() {
    let picture = split(40, 20, 10);
    let bytes = encode_jpeg(&picture).unwrap();
    assert!(bytes.starts_with(&[0xff, 0xd8]), "not a JPEG: {bytes:02x?}");
    assert!(bytes.ends_with(&[0xff, 0xd9]), "missing JPEG end marker");
}

#[test]
fn an_rgba_png_decodes_to_rgb() {
    let mut bytes = Vec::new();
    {
        let mut encoder = png::Encoder::new(&mut bytes, 2, 1);
        encoder.set_color(png::ColorType::Rgba);
        let mut writer = encoder.write_header().unwrap();
        writer.write_image_data(&[1, 2, 3, 255, 4, 5, 6, 0]).unwrap();
    }
    let decoded = decode(&bytes).unwrap();
    assert_eq!(decoded.pixels, vec![1, 2, 3, 4, 5, 6]);
}

#[test]
fn shrink_keeps_the_aspect_and_never_enlarges() {
    let wide = split(2560, 1600, 100);
    let thumb = shrink(&wide, THUMB_WIDTH, None);
    assert_eq!((thumb.width, thumb.height), (320, 200));
    let look = shrink(&split(600, 1200, 1), LOOK_EDGE, Some(LOOK_EDGE));
    assert_eq!((look.width, look.height), (256, 512));
    let small = shrink(&split(100, 50, 1), FULL_WIDTH, None);
    assert_eq!((small.width, small.height), (100, 50));
}

#[test]
fn the_same_page_hashes_the_same_and_a_moved_one_does_not() {
    let a = split(800, 600, 200);
    let a_smaller = shrink(&a, 400, None);
    assert!(bits(dhash(&a), dhash(&a_smaller)) <= SAME);
    let b = split(800, 600, 600);
    assert!(bits(dhash(&a), dhash(&b)) > SAME);
}

#[test]
fn ui_files_are_the_ones_that_ask_for_a_frame() {
    for path in [
        "/w/webviews/src/App.tsx",
        "a/style.css",
        "index.html",
        "x/Sources/V.swift",
        "~/.config/cmux/cmux-next.json",
    ] {
        assert!(ui_path(path), "{path}");
    }
    for path in ["/w/README.md", "src/main.rs", "Cargo.lock", "notes.txt"] {
        assert!(!ui_path(path), "{path}");
    }
}

#[test]
fn a_finished_edit_or_shell_call_asks_and_others_do_not() {
    let edit = json!({"status": "completed", "locations": [{"path": "/w/App.tsx"}]});
    assert_eq!(trigger_of(Some("edit"), &edit), Some("edit"));
    assert_eq!(trigger_of(None, &edit), Some("edit"));
    let running = json!({"status": "in_progress", "locations": [{"path": "/w/App.tsx"}]});
    assert_eq!(trigger_of(Some("edit"), &running), None);
    let read = json!({"status": "completed", "locations": [{"path": "/w/App.tsx"}]});
    assert_eq!(trigger_of(Some("read"), &read), None);
    let rust = json!({"status": "completed", "rawInput": {"file_path": "/w/main.rs"}});
    assert_eq!(trigger_of(Some("edit"), &rust), None);
    let shell = json!({"status": "completed", "rawInput": {"command": "bun run build"}});
    assert_eq!(trigger_of(Some("execute"), &shell), Some("build"));
    let diff = json!({"status": "completed", "content": [{"type": "diff", "path": "/w/a.css"}]});
    assert_eq!(trigger_of(None, &diff), Some("edit"));
}

#[test]
fn a_frame_index_round_trips() {
    let frame = Frame {
        index: 2,
        seq: 9,
        trigger: "edit".into(),
        at: 1,
        width: 1280,
        height: 800,
        distance: 0.25,
        moved: 0.5,
        hash: u64::MAX,
        url: None,
    };
    let bytes = serde_json::to_vec(&vec![frame.clone()]).unwrap();
    let back: Vec<Frame> = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(back, vec![frame]);
}

#[test]
fn a_chat_with_no_turn_reads_no_frames() {
    let reply = read("ses_no_turn_frames", &json!({"sinceSeq": 4}));
    assert_eq!(reply["frames"], json!([]));
    assert_eq!(reply["seq"], json!(4));
    assert_eq!(reply["live"], json!(false));
}

#[test]
fn customizing_the_app_is_told_from_paths_and_commands() {
    let settings = json!({"rawInput": {"file_path": "/Users/x/cmux-next.json"}});
    assert!(customizes_app(&settings));
    let run = json!({"rawInput": {"command": "cmux customize use dir:/w --watch"}});
    assert!(customizes_app(&run));
    let other = json!({"rawInput": {"command": "cargo test"}, "locations": [{"path": "/w/a.rs"}]});
    assert!(!customizes_app(&other));
}

#[test]
fn window_frames_follow_the_swift_live_build_only_while_its_socket_is_there() {
    let home = tempfile::tempdir().unwrap();
    assert_eq!(live_socket(home.path()), None);
    let named = home.path().join(LIVE_PREVIEW);
    std::fs::create_dir_all(named.parent().unwrap()).unwrap();
    let socket = home.path().join("cmux-debug-swift-ui.sock");
    std::fs::write(&named, json!({"socket": socket, "tag": "swift-ui"}).to_string()).unwrap();
    assert_eq!(live_socket(home.path()), None, "a stale name whose socket is gone");
    std::fs::write(&socket, b"").unwrap();
    assert_eq!(live_socket(home.path()), Some(socket));
    std::fs::write(&named, b"{\"socket\": \"\"}").unwrap();
    assert_eq!(live_socket(home.path()), None);
}

#[test]
fn driving_the_simulator_is_told_from_commands_and_ios_swift_paths() {
    for command in [
        "xcrun simctl launch booted dev.cmux.ios",
        "xcodebuild -scheme App -sdk iphonesimulator build",
        "xcodebuild test -destination 'platform=iOS Simulator,name=iPhone 17'",
    ] {
        assert!(drives_simulator(&json!({"rawInput": {"command": command}})), "{command}");
    }
    let edit = json!({"locations": [{"path": "/w/cmux-next-ios/App/RootView.swift"}]});
    assert!(drives_simulator(&edit));
    let ios = json!({"rawInput": {"file_path": "/w/ios/Sources/Feed.swift"}});
    assert!(drives_simulator(&ios));
    let mac = json!({"locations": [{"path": "/w/Packages/macOS/CmuxNext/Sources/Tabs/Bar.swift"}]});
    assert!(!drives_simulator(&mac));
    let web =
        json!({"rawInput": {"command": "bun run build"}, "locations": [{"path": "/w/ios/x.tsx"}]});
    assert!(!drives_simulator(&web));
}

/// A stand-in `xcrun` that copies a fixture PNG to its last argument (`simctl io booted screenshot
/// --type=png OUT`), and one that fails as simctl does with no simulator booted.
#[cfg(unix)]
#[test]
fn a_simulator_capture_reads_back_the_png_simctl_wrote_and_fails_without_one() {
    use std::os::unix::fs::PermissionsExt as _;
    let dir = std::env::temp_dir().join(format!("acpmux-sim-shot-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let fixture = dir.join("screen.png");
    std::fs::write(&fixture, encode(&split(1179, 2556, 600)).unwrap()).unwrap();
    let booted = dir.join("xcrun-booted");
    std::fs::write(
        &booted,
        format!(
            "#!/bin/sh\n[ \"$1 $2 $3 $4 $5\" = 'simctl io booted screenshot --type=png' ] || exit 3\ncp '{}' \"$6\"\n",
            fixture.display()
        ),
    )
    .unwrap();
    let none = dir.join("xcrun-none");
    std::fs::write(&none, "#!/bin/sh\necho 'No devices are booted.' >&2\nexit 149\n").unwrap();
    for script in [&booted, &none] {
        std::fs::set_permissions(script, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    let runtime = tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap();
    let (out, booted_c, none_c) = (dir.join("out.png"), booted.clone(), none.clone());
    let (ok, missing) = runtime.block_on(async move {
        tokio::task::spawn_blocking(move || {
            let ok = simulator_shot_with(booted_c.as_os_str(), &out)
                && decode(&std::fs::read(&out).unwrap())
                    .is_some_and(|p| (p.width, p.height) == (1179, 2556));
            let _ = std::fs::remove_file(&out);
            (ok, simulator_shot_with(none_c.as_os_str(), &out))
        })
        .await
        .unwrap()
    });
    let _ = std::fs::remove_dir_all(&dir);
    assert!(ok, "the booted simulator's picture reads back");
    assert!(!missing, "no simulator booted: no frame");
}

/// The duress number for a simulator frame: the daemon's own work on one 1179x2556 capture (decode,
/// dHash, 1280 and 320 px encodes), what each frame costs beyond simctl itself.
#[test]
#[ignore = "measurement: cargo test -p acpmux --lib --release simulator_frame_cost -- --ignored --nocapture"]
fn simulator_frame_cost() {
    let bytes = encode(&split(1179, 2556, 600)).unwrap();
    let rounds = 20;
    let started = std::time::Instant::now();
    for _ in 0..rounds {
        let picture = decode(&bytes).unwrap();
        let _ = dhash(&picture);
        let _ = encode(&shrink(&picture, FULL_WIDTH, None)).unwrap();
        let _ = encode(&shrink(&picture, THUMB_WIDTH, None)).unwrap();
    }
    let each = started.elapsed() / rounds;
    println!("simulator frame: {} KB in, {each:?} of daemon CPU each", bytes.len() / 1024);
}
