use super::*;

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn parse_defaults_and_bounds() {
    let Ok(AppCommand::Record(request)) = parse(Noun::Window, &words("record")) else { panic!() };
    assert_eq!((request.seconds, request.fps, request.target, request.out), (5, 30, None, None));
    let Ok(AppCommand::Record(request)) =
        parse(Noun::Pane, &words("record --target pane_1 --seconds 10 --fps 60 --out /tmp/a.mp4"))
    else {
        panic!()
    };
    assert_eq!(request.noun, Noun::Pane);
    assert_eq!(request.target.as_deref(), Some("pane_1"));
    assert_eq!((request.seconds, request.fps), (10, 60));
    assert_eq!(request.out.as_deref(), Some("/tmp/a.mp4"));
    for bad in [
        "record --seconds 0",
        "record --seconds 61",
        "record --fps 0",
        "record --fps 61",
        "record --seconds 60 --fps 60",
        "record --bogus 1",
        "record --fps x",
    ] {
        assert!(parse(Noun::Window, &words(bad)).is_err(), "{bad}");
    }
}

#[test]
fn window_record_is_the_recording_not_an_app_action() {
    let parsed = super::super::parse(&words("window record --fps 10 --seconds 2")).unwrap();
    let Some(AppCommand::Record(request)) = parsed else { panic!("{parsed:?}") };
    assert_eq!((request.noun, request.fps, request.seconds), (Noun::Window, 10, 2));
    assert!(super::super::parse(&words("window record --fps 0")).is_err());
}

#[test]
fn the_encode_reads_the_folders_list_at_the_frames_own_times() {
    let args = ffmpeg_args(Path::new("/f"), Path::new("/x/clip.mp4"));
    let at = |word: &str| args.iter().position(|arg| arg == word).unwrap();
    assert_eq!(args[at("-i") + 1], "/f/frames.ffconcat");
    assert_eq!(args[at("-fps_mode") + 1], "vfr");
    assert_eq!(args[at("-enc_time_base") + 1], "1/1000");
    assert!(!args.iter().any(|arg| arg == "-r"), "ffmpeg 9 refuses -r with vfr: {args:?}");
    assert_eq!(args.last().unwrap(), "/x/clip.mp4");
    assert_eq!(shell_word("/a b/c's"), "'/a b/c'\\''s'");
    assert_eq!(shell_word("pad=ceil(iw/2)*2"), "'pad=ceil(iw/2)*2'");
    assert_eq!(shell_word("-fps_mode"), "-fps_mode");
}

#[test]
fn a_relative_out_is_the_callers() {
    let Ok(AppCommand::Record(request)) = parse(Noun::Window, &words("record --out clip.mp4"))
    else {
        panic!()
    };
    let out = request.out.unwrap();
    assert!(Path::new(&out).is_absolute() && out.ends_with("clip.mp4"), "{out}");
}

#[test]
fn destinations() {
    let temporary = Path::new("/var/t");
    assert_eq!(
        destination(Some("/x/clip.MP4"), 7, temporary),
        Destination { frames: "/x/clip.MP4.frames".into(), movie: Some("/x/clip.MP4".into()) }
    );
    assert_eq!(
        destination(Some("/x/shots"), 7, temporary),
        Destination { frames: "/x/shots".into(), movie: None }
    );
    assert_eq!(
        destination(None, 7, temporary),
        Destination {
            frames: "/var/t/cmux-recordings/record-7.frames".into(),
            movie: Some("/var/t/cmux-recordings/record-7.mp4".into()),
        }
    );
}

fn frame(index: u64, at_ms: u64) -> Frame {
    Frame {
        index,
        at_ms,
        file: format!("frame-{index:05}.png"),
        result: Ok(json!({"result": {"path": "p", "masked_areas": ["tab-strip", "chat"]}})),
    }
}

#[test]
fn the_timeline_keeps_each_frames_time() {
    let frames = [frame(0, 0), frame(1, 40), frame(3, 100)];
    let refs: Vec<&Frame> = frames.iter().collect();
    let rows = timeline(&refs, 25);
    let durations: Vec<u64> = rows.iter().map(|row| row["duration_ms"].as_u64().unwrap()).collect();
    assert_eq!(durations, vec![40, 60, 40]);
    assert_eq!(masked_areas(&refs), vec!["chat".to_owned(), "tab-strip".to_owned()]);
    let list = concat_list(&rows);
    assert!(
        list.starts_with("ffconcat version 1.0\nfile 'frame-00000.png'\nduration 0.040\n"),
        "{list}"
    );
    assert!(list.ends_with("duration 0.040\nfile 'frame-00003.png'\n"), "{list}");
}

#[test]
fn the_summary_names_masks_and_skips() {
    let messages = &crate::localization::catalog().app_control.record;
    let report = json!({"frames": 120, "seconds": 4.02, "fps": 29.9, "asked_fps": 30, "path": "/x/clip.mp4",
                        "masked_areas": ["chat"], "dropped": 2, "failed": 0});
    let text = human(&report, messages);
    assert!(
        text.contains("120") && text.contains("/x/clip.mp4") && text.contains("chat"),
        "{text}"
    );
    assert!(text.contains('2'), "{text}");
}
