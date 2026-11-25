use super::*;

/// A 180x80 RGB PNG of 9x8 blocks whose brightness follows `seed`: each seed a different dHash.
fn blocks(seed: u64) -> Vec<u8> {
    let (w, h) = (180u32, 80u32);
    let level = |bx: u32, by: u32| -> u8 {
        let mut x = seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) ^ u64::from(bx * 31 + by * 977);
        x ^= x >> 29;
        x = x.wrapping_mul(0xBF58_476D_1CE4_E5B9);
        x ^= x >> 32;
        (x & 0xff) as u8
    };
    let mut data = Vec::with_capacity((w * h * 3) as usize);
    for y in 0..h {
        for x in 0..w {
            let v = level(x / 20, y / 10);
            data.extend([v, v, v]);
        }
    }
    let mut out = Vec::new();
    let mut e = png::Encoder::new(&mut out, w, h);
    e.set_color(png::ColorType::Rgb);
    e.set_depth(png::BitDepth::Eight);
    e.write_header().unwrap().write_image_data(&data).unwrap();
    out
}

/// A running turn of `session` as `turn_began` makes one, without its prune task.
fn begin(session: &str, turn: &str) -> (String, String) {
    live().insert(
        session.to_owned(),
        Live {
            turn: turn.to_owned(),
            workspace: "ws_ab".to_owned(),
            tab: None,
            url: None,
            edits: 0,
            edit_calls: HashSet::new(),
            write: Arc::default(),
        },
    );
    (session.to_owned(), turn.to_owned())
}

#[test]
fn the_same_picture_hashes_the_same_and_another_far_from_it() {
    let a = analyze(&blocks(1), false).unwrap();
    let again = analyze(&blocks(1), false).unwrap();
    let b = analyze(&blocks(2), false).unwrap();
    assert_eq!(a.hash, again.hash);
    assert!(distance(a.hash, b.hash) > SAME_FRAME, "{}", distance(a.hash, b.hash));
    assert_eq!((a.width, a.height), (180, 80));
}

#[test]
fn a_thumbnail_is_320_wide_and_a_look_at_most_512() {
    let mut data = Vec::new();
    let mut e = png::Encoder::new(&mut data, 1600, 1000);
    e.set_color(png::ColorType::Rgba);
    e.set_depth(png::BitDepth::Eight);
    e.write_header().unwrap().write_image_data(&vec![200; 1600 * 1000 * 4]).unwrap();
    let picture = analyze(&data, true).unwrap();
    assert_eq!(picture.thumb_size, (320, 200));
    let (jpeg, w, h) = picture.look.unwrap();
    assert_eq!((w, h), (512, 320));
    assert_eq!(&jpeg[..2], &[0xFF, 0xD8], "a JPEG");
    assert_eq!(&picture.thumb[..2], &[0xFF, 0xD8]);
    assert!(analyze(b"not a png", false).is_none());
}

#[test]
fn a_frame_like_the_last_is_dropped() {
    let base = tempfile::tempdir().unwrap();
    let key = begin("frames-test-dedupe", "t1");
    let first =
        keep(base.path(), &key, &blocks(7), Trigger::Start, Some("http://a/"), false).unwrap();
    assert!(first.kept);
    assert_eq!(first.frame.distance, None);
    let same = keep(base.path(), &key, &blocks(7), Trigger::Edit, None, false).unwrap();
    assert!(!same.kept, "nothing changed on screen");
    let other = keep(base.path(), &key, &blocks(8), Trigger::Edit, None, false).unwrap();
    assert!(other.kept);
    assert_eq!(other.frame.index, 1);
    assert!(other.frame.distance.unwrap() > SAME_FRAME);
    assert_eq!(other.frame.first_distance, other.frame.distance.unwrap());
    assert!(other.frame.seq > first.frame.seq);
    let read = read_frames(base.path(), &key.0, Some(&key.1), None, None);
    let frames = read["frames"].as_array().unwrap();
    assert_eq!(frames.len(), 2);
    assert_eq!(read["live"], true);
    assert!(frames[0]["thumbnail"].as_str().unwrap().starts_with("data:image/jpeg;base64,"));
    assert!(frames[0].get("image").is_none(), "full pictures only by index");
    // A poller past the first frame gets only the second.
    let since = read_frames(base.path(), &key.0, None, Some(first.frame.seq), None);
    assert_eq!(since["frames"].as_array().unwrap().len(), 1);
    assert_eq!(since["frames"][0]["trigger"], "edit");
    let one = read_frames(base.path(), &key.0, None, None, Some(1));
    assert!(one["frames"][0]["image"].as_str().unwrap().starts_with("data:image/png;base64,"));
    live().remove(&key.0);
}

#[test]
fn a_turn_keeps_at_most_max_frames_and_the_newest_takes_the_last_place() {
    let base = tempfile::tempdir().unwrap();
    let key = begin("frames-test-cap", "t1");
    let mut last = None;
    for seed in 100..(100 + MAX_FRAMES as u64 + 6) {
        let kept = keep(base.path(), &key, &blocks(seed), Trigger::Edit, None, false).unwrap();
        assert!(kept.kept, "seed {seed}");
        assert!(kept.frame.index < MAX_FRAMES);
        last = Some(kept.frame);
    }
    let dir = turn_shots::turn_dir(base.path(), &key.0, &key.1).unwrap();
    let frames = read_index(&dir);
    assert_eq!(frames.len(), MAX_FRAMES);
    assert_eq!(frames.last(), last.as_ref());
    assert_eq!(last.unwrap().index, MAX_FRAMES - 1);
    live().remove(&key.0);
}

#[test]
fn place_appends_drops_or_replaces() {
    let frame = |index: usize, hash: u64| Frame {
        index,
        seq: index as u64,
        trigger: "edit".into(),
        at: 0,
        width: 1,
        height: 1,
        hash: format!("{hash:016x}"),
        distance: None,
        first_distance: 0,
        url: None,
        thumbnail_width: 1,
        thumbnail_height: 1,
        has_image: true,
    };
    assert_eq!(place(&[], 0), Place::Append);
    assert_eq!(place(&[frame(0, 0)], 0b1111), Place::Same, "4 bits is the same");
    assert_eq!(place(&[frame(0, 0)], 0b11111), Place::Append, "5 bits is new");
    let full: Vec<Frame> = (0..MAX_FRAMES).map(|i| frame(i, 0)).collect();
    assert_eq!(place(&full, u64::MAX), Place::Replace(MAX_FRAMES - 1));
}

#[test]
fn ui_files_are_web_and_app_sources() {
    for ui in [
        "src/App.tsx",
        "a/b.ts",
        "x.jsx",
        "styles/site.CSS",
        "index.html",
        "Views/Main.swift",
        "C.vue",
        "Page.svelte",
        "webviews/src/thing.json",
        "Packages/macOS/Sources/X/data.plist",
    ] {
        assert!(is_ui_path(ui), "{ui}");
    }
    for not in ["src/main.rs", "README.md", "Cargo.toml", ".ts", "tests/x.py", "mysources/a.rs"] {
        assert!(!is_ui_path(not), "{not}");
    }
}

#[test]
fn a_ui_edit_record_is_seen_and_others_are_not() {
    let record = |update: Value| json!({"method": "session/update", "params": {"update": update}});
    let edit = record(json!({
        "sessionUpdate": "tool_call", "toolCallId": "c1", "kind": "edit",
        "locations": [{"path": "/w/src/App.tsx"}],
    }));
    assert_eq!(seen("tool_call", &edit), Some(Seen::UiEdit(Some("c1".into()))));
    assert_eq!(seen("tool_call.replay", &edit), None, "a replay takes no frame");
    let rust =
        record(json!({"toolCallId": "c2", "kind": "edit", "rawInput": {"file_path": "/w/lib.rs"}}));
    assert_eq!(seen("tool_call", &rust), None);
    let diff =
        record(json!({"toolCallId": "c3", "content": [{"type": "diff", "path": "/w/a.css"}]}));
    assert_eq!(seen("tool_call_update", &diff), Some(Seen::UiEdit(Some("c3".into()))));
    let read =
        record(json!({"toolCallId": "c4", "kind": "read", "locations": [{"path": "/w/App.tsx"}]}));
    assert_eq!(seen("tool_call", &read), None, "a read changes nothing");
    let done = record(json!({"toolCallId": "c1", "status": "completed"}));
    assert_eq!(seen("tool_call_update", &done), Some(Seen::Completed("c1".into())));
}

#[test]
fn a_burst_of_edits_takes_one_frame_after_its_last() {
    let session = "frames-test-debounce";
    begin(session, "t1");
    let a = note_edit(session, &Seen::UiEdit(Some("c1".into()))).unwrap();
    let b = note_edit(session, &Seen::UiEdit(Some("c2".into()))).unwrap();
    assert!(!still_newest(session, "t1", a.1), "a later edit cancels the earlier wait");
    assert!(still_newest(session, "t1", b.1));
    // Another call's completion is no edit; an edit call's completion waits again.
    assert_eq!(note_edit(session, &Seen::Completed("other".into())), None);
    assert!(still_newest(session, "t1", b.1));
    let c = note_edit(session, &Seen::Completed("c1".into())).unwrap();
    assert!(!still_newest(session, "t1", b.1));
    assert!(still_newest(session, "t1", c.1));
    assert_eq!(note_edit(session, &Seen::Completed("c1".into())), None, "once");
    // No running turn: nothing is armed.
    live().remove(session);
    assert_eq!(note_edit(session, &Seen::UiEdit(None)), None);
    assert!(!still_newest(session, "t1", c.1));
}

#[tokio::test(start_paused = true)]
async fn the_debounced_capture_fires_once_after_the_quiet_period() {
    let session = "frames-test-debounce-timer";
    begin(session, "t1");
    let fired = Arc::new(AtomicU64::new(0));
    for _ in 0..3 {
        let (turn, edits) = note_edit(session, &Seen::UiEdit(None)).unwrap();
        let fired = fired.clone();
        tokio::spawn(async move {
            tokio::time::sleep(DEBOUNCE).await;
            if still_newest(session, &turn, edits) {
                fired.fetch_add(1, Ordering::SeqCst);
            }
        });
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    tokio::time::sleep(DEBOUNCE * 2).await;
    assert_eq!(fired.load(Ordering::SeqCst), 1);
    live().remove(session);
}

#[test]
fn old_turns_and_chats_are_pruned() {
    let base = tempfile::tempdir().unwrap();
    for turn in 0..KEEP_TURNS + 3 {
        std::fs::create_dir_all(base.path().join("s1").join(format!("t{turn}"))).unwrap();
    }
    prune_all(base.path());
    assert_eq!(std::fs::read_dir(base.path().join("s1")).unwrap().count(), KEEP_TURNS);
}

#[test]
fn seqs_only_grow() {
    let a = next_seq();
    let b = next_seq();
    assert!(b > a && a >= now_ms());
}
