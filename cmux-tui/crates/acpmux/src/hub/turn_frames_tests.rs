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
fn a_live_swap_reaches_the_turns_that_worked_in_its_tree() {
    let tree = "/w/cmux";
    assert!(worked_in(tree, "/w/cmux/webviews", &[]), "the chat's folder is in the tree");
    assert!(worked_in(tree, "/home/a", &["/w/cmux/cmux-tui/src/lib.rs".into()]));
    assert!(worked_in(tree, "/w/cmux", &["src/x.rs".into()]));
    assert!(
        !worked_in(tree, "/w/cmux-other", &["/w/cmux-other/a.rs".into()]),
        "a sibling, not inside"
    );
    assert!(!worked_in(tree, "/home/a", &["relative.rs".into()]));
    assert!(!worked_in(tree, "/", &[]), "a folder above the tree is not in it");
}

fn live_turn(session: &str, cwd: &str, touched: &[&str], chrome: bool, live: bool) {
    turns().insert(
        session.to_owned(),
        Turn {
            id: format!("{session}-turn"),
            workspace: "ws".into(),
            frames: Vec::new(),
            live,
            capturing: false,
            again: None,
            debounce: 0,
            kinds: HashMap::new(),
            chrome,
            cwd: cwd.into(),
            touched: touched.iter().map(|p| (*p).to_owned()).collect(),
        },
    );
}

#[test]
fn a_live_swap_asks_a_window_frame_of_each_turn_in_its_tree_only() {
    let tree = "/built/rfd0152-tree";
    live_turn("rfd0152-in", "/home/a", &["/built/rfd0152-tree/cmux-tui/src/a.rs"], false, true);
    live_turn("rfd0152-customizes", "/elsewhere", &[], true, true);
    live_turn("rfd0152-other", "/elsewhere", &["/elsewhere/a.rs"], false, true);
    live_turn("rfd0152-ended", "/built/rfd0152-tree", &[], false, false);
    assert!(any_live());
    assert!(built(tree) >= 2, "other tests' turns may be live too");
    let all = turns();
    let in_tree = &all["rfd0152-in"];
    assert!(in_tree.chrome, "the swapped build is the app's: its window when there is no page");
    assert_eq!(in_tree.debounce, 1);
    assert_eq!(all["rfd0152-customizes"].debounce, 1);
    assert_eq!(all["rfd0152-other"].debounce, 0);
    assert!(!all["rfd0152-other"].chrome);
    assert_eq!(all["rfd0152-ended"].debounce, 0);
    drop(all);
    for s in ["rfd0152-in", "rfd0152-customizes", "rfd0152-other", "rfd0152-ended"] {
        turns().remove(s);
    }
}

/// End to end from a `cmux live` loop's beacon to the turn's frame ask, with its latency (RFD 0152:
/// a change shows in under 5 s for Rust; this hop must stay a small part of it).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_beacon_write_asks_the_turns_frame_within_a_poll() {
    let dir = tempfile::tempdir().unwrap();
    let tree = dir.path().join("cmux");
    let beacon = dir.path().join("live-build-done.json");
    let edited = tree.join("cmux-tui/src/lib.rs").to_string_lossy().into_owned();
    live_turn("rfd0152-e2e", "/home/a", &[&edited], false, true);
    let follow = {
        let beacon = beacon.clone();
        tokio::spawn(async move { super::super::live_builds::follow(&beacon).await })
    };
    tokio::time::sleep(Duration::from_millis(50)).await;
    let mut samples = Vec::new();
    for round in 1..=3u64 {
        let wrote = std::time::Instant::now();
        let at = now_ms();
        std::fs::write(
            &beacon,
            format!(r#"{{"at": {at}, "surface": "rust", "tree": "{}"}}"#, tree.display()),
        )
        .unwrap();
        loop {
            if turns().get("rfd0152-e2e").is_some_and(|t| t.debounce == round) {
                break;
            }
            assert!(wrote.elapsed() < Duration::from_secs(5), "no frame asked for round {round}");
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        samples.push(wrote.elapsed());
        // Each beacon a distinct modification time on coarse clocks.
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    // Gone before SETTLE: no capture runs (no page, and no app to shoot in a test).
    turns().remove("rfd0152-e2e");
    follow.abort();
    let worst = samples.iter().max().unwrap();
    eprintln!("rfd0152 beacon-to-ask: {samples:?} (poll {:?})", super::super::live_builds::POLL);
    assert!(*worst < super::super::live_builds::POLL + Duration::from_millis(300), "{samples:?}");
}
