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
