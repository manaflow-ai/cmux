//! The `record` tool through the engine on the fake desktop: the file reads
//! back, the cap ends it, one runs at a time, the policy of a display
//! screenshot holds for every frame.

use std::time::{Duration, Instant};

use super::*;
use crate::desktop::fake::FakeDesktop;
use crate::record::{mp4, synthetic};

fn ctx_of(session: &str) -> CallContext {
    CallContext {
        session: session.into(),
        label: "Claude".into(),
        call_id: None,
        origin: OriginKind::Local,
        tag: None,
    }
}

fn ctx() -> CallContext {
    ctx_of("s1")
}

fn engine(desktop: Arc<FakeDesktop>, config: PolicyConfig) -> Engine {
    let mut parts = EngineParts::new(desktop);
    parts.config = config;
    Engine::new(parts)
}

fn rig() -> (Arc<FakeDesktop>, Engine) {
    let d = Arc::new(FakeDesktop::standard());
    let e = engine(d.clone(), PolicyConfig::default());
    (d, e)
}

/// The file the result names, read back.
fn track(out: &ToolOutput) -> mp4::Track {
    assert!(!out.is_error, "{:?}", out.body);
    mp4::read_samples(std::path::Path::new(out.body["path"].as_str().unwrap())).unwrap()
}

#[test]
fn one_call_records_for_seconds_and_returns_a_file_that_reads_back() {
    let (_d, e) = rig();
    let began = Instant::now();
    let out = e.call(&ctx(), "record", &json!({"seconds": 0.4, "fps": 20}));
    let took = began.elapsed();
    assert!(!out.is_error, "{:?}", out.body);
    assert!(took >= Duration::from_millis(400), "{took:?}");
    assert_eq!(out.body["ended"], "max_seconds");
    assert_eq!(out.body["recording"], false);
    assert_eq!(out.body["codec"], "h264");
    assert_eq!(out.body["display"], "main");
    // The fake display is 2000x1600 px: the long edge comes down to 1920.
    assert_eq!((out.body["width"].as_u64(), out.body["height"].as_u64()), (Some(1920), Some(1536)));
    let t = track(&out);
    assert_eq!(t.info.codec, "avc1");
    assert_eq!((t.info.width, t.info.height), (1920, 1536));
    assert_eq!(out.body["frames"].as_u64(), Some(t.info.frames));
    assert_eq!(out.body["bytes"].as_u64(), Some(t.info.bytes));
    assert_eq!(out.body["duration_ms"].as_u64(), Some(t.info.duration_ms));
    assert!(t.info.frames >= 2, "{:?}", t.info);
    // The cap is honoured: the file is as long as asked, not longer than a
    // slow machine's slack.
    assert!((400..3000).contains(&t.info.duration_ms), "{:?}", t.info);
    // The first frame is a keyframe and the frames are in order.
    assert!(t.samples[0].key);
    for (i, s) in t.samples.iter().enumerate() {
        let stats = synthetic::stats(&s.data).unwrap();
        assert_eq!(stats.index as usize, i);
        assert_eq!((stats.width, stats.height), (1920, 1536));
    }
    // The engine's own folder, private to the user.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let path = std::path::Path::new(out.body["path"].as_str().unwrap());
        assert_eq!(std::fs::metadata(path).unwrap().permissions().mode() & 0o777, 0o600);
        let dir = std::fs::metadata(path.parent().unwrap()).unwrap();
        assert_eq!(dir.permissions().mode() & 0o777, 0o700);
    }
}

#[test]
fn start_returns_at_once_and_stop_returns_the_finished_file() {
    let (_d, e) = rig();
    let began = Instant::now();
    let started = e.call(&ctx(), "record", &json!({"action": "start", "fps": 20}));
    assert!(!started.is_error, "{:?}", started.body);
    assert!(began.elapsed() < Duration::from_secs(5));
    assert_eq!(started.body["recording"], true);
    assert_eq!(started.body["max_seconds"], 300.0);
    let id = started.body["recording_id"].as_str().unwrap().to_string();
    // Other calls go on while it records.
    let shot = e.call(&ctx(), "screenshot", &json!({}));
    assert!(!shot.is_error, "{:?}", shot.body);
    std::thread::sleep(Duration::from_millis(200));
    let out = e.call(&ctx(), "record", &json!({"action": "stop"}));
    assert!(!out.is_error, "{:?}", out.body);
    assert_eq!(out.body["recording_id"], id.as_str());
    assert_eq!(out.body["ended"], "stopped");
    let t = track(&out);
    assert!(t.info.frames >= 2, "{:?}", t.info);
    assert!(t.info.duration_ms >= 200, "{:?}", t.info);
    // Stopping again by id returns the same file; without an id there is
    // nothing left to stop.
    let again = e.call(&ctx(), "record", &json!({"action": "stop", "recording_id": id}));
    assert_eq!(again.body["path"], out.body["path"]);
    let none = e.call(&ctx(), "record", &json!({"action": "stop"}));
    assert_eq!(none.code.as_deref(), Some("not_recording"));
}

#[test]
fn a_started_recording_ends_by_itself_at_max_seconds() {
    let (_d, e) = rig();
    let started =
        e.call(&ctx(), "record", &json!({"action": "start", "max_seconds": 0.3, "fps": 20}));
    assert!(!started.is_error, "{:?}", started.body);
    // Nobody stops it: it is over when the cap passes.
    let deadline = Instant::now() + Duration::from_secs(20);
    while e.recorder.active().is_some() {
        assert!(Instant::now() < deadline, "the recording outlived its cap");
        std::thread::sleep(Duration::from_millis(10));
    }
    // A later stop still hands over the file, once.
    let out = e.call(&ctx(), "record", &json!({"action": "stop"}));
    assert_eq!(out.body["ended"], "max_seconds");
    let t = track(&out);
    assert!((300..3000).contains(&t.info.duration_ms), "{:?}", t.info);
    // Over the hard cap is refused, not clamped in silence.
    let over = e.call(&ctx(), "record", &json!({"action": "start", "max_seconds": 1e9}));
    assert_eq!(over.code.as_deref(), Some("invalid_arguments"));
    let none = e.call(&ctx(), "record", &json!({}));
    assert_eq!(none.code.as_deref(), Some("invalid_arguments"));
}

#[test]
fn a_second_start_while_recording_is_a_typed_error() {
    let (_d, e) = rig();
    let first = e.call(&ctx(), "record", &json!({"action": "start", "max_seconds": 30}));
    assert!(!first.is_error, "{:?}", first.body);
    let second = e.call(&ctx(), "record", &json!({"action": "start"}));
    assert_eq!(second.code.as_deref(), Some("already_recording"));
    let one_call = e.call(&ctx(), "record", &json!({"seconds": 1}));
    assert_eq!(one_call.code.as_deref(), Some("already_recording"));
    // Another session neither starts one, nor stops or reads this one.
    let other = ctx_of("s2");
    let theirs = e.call(&other, "record", &json!({"action": "start"}));
    assert_eq!(theirs.code.as_deref(), Some("already_recording"));
    let id = first.body["recording_id"].as_str().unwrap();
    let stop = e.call(&other, "record", &json!({"action": "stop", "recording_id": id}));
    assert_eq!(stop.code.as_deref(), Some("not_recording"));
    let out = e.call(&ctx(), "record", &json!({"action": "stop"}));
    assert!(!out.is_error, "{:?}", out.body);
    let read = e.call(&other, "record", &json!({"action": "read", "recording_id": id}));
    assert_eq!(read.code.as_deref(), Some("not_recording"));
    // The slot is free again.
    let next = e.call(&other, "record", &json!({"seconds": 0.1}));
    assert!(!next.is_error, "{:?}", next.body);
}

#[test]
fn a_locked_screen_refuses_a_recording_and_ends_a_running_one() {
    let (d, e) = rig();
    *d.locked.lock().unwrap() = true;
    for args in [json!({"seconds": 0.1}), json!({"action": "start"})] {
        let out = e.call(&ctx(), "record", &args);
        assert_eq!(out.code.as_deref(), Some(crate::locked::CODE), "{args}");
    }
    assert!(e.recorder.active().is_none());
    assert_eq!(*d.captures.lock().unwrap(), 0);
    // The screen locks during a recording: it ends by itself, and the stop
    // (which captures nothing) still returns the file while locked.
    *d.locked.lock().unwrap() = false;
    let started = e.call(&ctx(), "record", &json!({"action": "start", "fps": 30}));
    assert!(!started.is_error, "{:?}", started.body);
    std::thread::sleep(Duration::from_millis(100));
    *d.locked.lock().unwrap() = true;
    let deadline = Instant::now() + Duration::from_secs(20);
    while e.recorder.active().is_some() {
        assert!(Instant::now() < deadline, "the recording went on over a locked screen");
        std::thread::sleep(Duration::from_millis(10));
    }
    let captures = *d.captures.lock().unwrap();
    let out = e.call(&ctx(), "record", &json!({"action": "stop"}));
    assert_eq!(out.body["ended"], "locked");
    assert_eq!(*d.captures.lock().unwrap(), captures);
    track(&out);
}

#[test]
fn denied_apps_are_out_of_every_frame_as_in_a_display_screenshot() {
    // 1Password (denied by default) is a 300x200 pt window: painted out of
    // every frame where the capture cannot leave its process out.
    let (_d, e) = rig();
    let out = e.call(&ctx(), "record", &json!({"seconds": 0.2, "fps": 20}));
    assert_eq!(out.body["redacted_windows"], 1);
    assert_eq!(out.body["left_out_apps"], 0);
    for s in &track(&out).samples {
        let painted = synthetic::stats(&s.data).unwrap().painted;
        // 600x400 px of the 2000x1600 capture, scaled by 0.96 each way.
        assert!((200_000..240_000).contains(&painted), "{painted}");
    }
    // Nothing denied: nothing painted out.
    let (_d, e) = {
        let d = Arc::new(FakeDesktop::standard());
        let e = engine(d.clone(), PolicyConfig { denied_apps: vec![], ..PolicyConfig::default() });
        (d, e)
    };
    let out = e.call(&ctx(), "record", &json!({"seconds": 0.2, "fps": 20}));
    assert_eq!(out.body["redacted_windows"], 0);
    assert!(track(&out).samples.iter().all(|s| synthetic::stats(&s.data).unwrap().painted == 0));
    // Where the capture leaves processes out (macOS), it does, per frame.
    let mut desktop = FakeDesktop::standard();
    desktop.excludes_apps = true;
    let desktop = Arc::new(desktop);
    let e = engine(desktop.clone(), PolicyConfig::default());
    let out = e.call(&ctx(), "record", &json!({"seconds": 0.2, "fps": 20}));
    assert_eq!(out.body["left_out_apps"], 1);
    assert_eq!(out.body["redacted_windows"], 0);
    assert_eq!(*desktop.last_excluded.lock().unwrap(), vec![20]);
}

#[test]
fn an_app_denied_during_a_recording_leaves_the_frames_after_it() {
    let d = Arc::new(FakeDesktop::standard());
    let e = engine(d, PolicyConfig { denied_apps: vec![], ..PolicyConfig::default() });
    let started = e.call(&ctx(), "record", &json!({"action": "start", "fps": 30}));
    assert!(!started.is_error, "{:?}", started.body);
    std::thread::sleep(Duration::from_millis(150));
    let mut config = e.config();
    config.denied_apps.push("com.1password.1password".into());
    e.set_config(config);
    std::thread::sleep(Duration::from_millis(250));
    let out = e.call(&ctx(), "record", &json!({"action": "stop"}));
    let blacks: Vec<u32> =
        track(&out).samples.iter().map(|s| synthetic::stats(&s.data).unwrap().painted).collect();
    assert_eq!(blacks[0], 0, "{blacks:?}");
    assert!(*blacks.last().unwrap() > 200_000, "{blacks:?}");
    // Once painted out, never back in.
    let first_black = blacks.iter().position(|b| *b > 0).unwrap();
    assert!(blacks[first_black..].iter().all(|b| *b > 200_000), "{blacks:?}");
}

#[test]
fn turning_computer_use_off_or_stopping_the_session_ends_the_recording() {
    let (_d, e) = rig();
    let started = e.call(&ctx(), "record", &json!({"action": "start", "fps": 30}));
    assert!(!started.is_error, "{:?}", started.body);
    let id = started.body["recording_id"].as_str().unwrap().to_string();
    e.stops.stop("s1");
    let summary = e.recorder.wait(&id).unwrap();
    assert_eq!(summary.ended, "stopped_by_person");
    e.stops.resume("s1");

    let started = e.call(&ctx(), "record", &json!({"action": "start", "fps": 30}));
    assert!(!started.is_error, "{:?}", started.body);
    let id = started.body["recording_id"].as_str().unwrap().to_string();
    let mut config = e.config();
    config.mode = policy::Mode::Off;
    e.set_config(config);
    let summary = e.recorder.wait(&id).unwrap();
    assert_eq!(summary.ended, "computer_use_off");
    // And Off refuses a new one, like every tool.
    let out = e.call(&ctx(), "record", &json!({"seconds": 0.1}));
    assert!(out.is_error);
    assert_ne!(out.code.as_deref(), Some("already_recording"));
}

#[test]
fn read_returns_the_file_in_pieces_and_never_takes_a_path() {
    let (_d, e) = rig();
    let out = e.call(&ctx(), "record", &json!({"seconds": 0.2, "fps": 20}));
    let id = out.body["recording_id"].as_str().unwrap();
    let on_disk = std::fs::read(out.body["path"].as_str().unwrap()).unwrap();
    let mut got = Vec::new();
    let mut offset = 0u64;
    loop {
        let piece = e.call(
            &ctx(),
            "record",
            &json!({"action": "read", "recording_id": id, "offset": offset}),
        );
        assert!(!piece.is_error, "{:?}", piece.body);
        assert_eq!(piece.body["bytes"].as_u64(), Some(on_disk.len() as u64));
        let data = base64::Engine::decode(
            &base64::engine::general_purpose::STANDARD,
            piece.body["data_base64"].as_str().unwrap(),
        )
        .unwrap();
        assert!(data.len() <= crate::record::READ_CHUNK);
        got.extend_from_slice(&data);
        offset = piece.body["next_offset"].as_u64().unwrap();
        if piece.body["eof"] == true {
            break;
        }
    }
    assert_eq!(got, on_disk);
    // A path is not an id, and the schema has no path to give.
    let path = out.body["path"].as_str().unwrap();
    let by_path = e.call(&ctx(), "record", &json!({"action": "read", "recording_id": path}));
    assert_eq!(by_path.code.as_deref(), Some("not_recording"));
    let tool = tools::TOOLS.iter().find(|t| t.name == "record").unwrap();
    assert_eq!(tool.access, Access::Observe);
    let schema = tool.schema();
    for key in ["path", "out", "file"] {
        assert!(schema["properties"].get(key).is_none(), "{key}");
    }
}

#[test]
fn bad_arguments_are_refused_and_hold_no_slot() {
    let d = Arc::new(FakeDesktop::standard());
    let e = engine(d, PolicyConfig::default());
    let window = e.call(&ctx(), "record", &json!({"seconds": 1, "window_id": "1"}));
    assert_eq!(window.code.as_deref(), Some("invalid_arguments"));
    let fps = e.call(&ctx(), "record", &json!({"seconds": 1, "fps": 500}));
    assert_eq!(fps.code.as_deref(), Some("invalid_arguments"));
    let action = e.call(&ctx(), "record", &json!({"action": "pause"}));
    assert_eq!(action.code.as_deref(), Some("invalid_arguments"));
    assert!(e.recorder.active().is_none());
}
