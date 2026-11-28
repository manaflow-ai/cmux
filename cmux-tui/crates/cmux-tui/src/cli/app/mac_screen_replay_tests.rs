use std::time::Duration;

use serde_json::json;

use super::super::{AppCommand, parse};
use super::{Replay, human, report};

fn args(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

fn replay(words: &[&str]) -> Replay {
    match parse(&args(words)).unwrap().unwrap() {
        AppCommand::MacScreenReplay(replay) => replay,
        other => panic!("expected a replay, got {other:?}"),
    }
}

/// `cmux app mac-screen-replay --path <movie>` asks `mac_screen.replay` for the movie (made
/// absolute), 20 loops, any home tab, and waits for the app's whole 120-frame window for 60 s.
#[test]
fn mac_screen_replay_parses_path_tab_frames_loops_and_timeout() {
    let command = replay(&["app", "mac-screen-replay", "--path", "/tmp/share.mp4"]);
    assert_eq!(
        command,
        Replay {
            params: json!({"path": "/tmp/share.mp4", "loops": 20}),
            frames: 120,
            timeout: Duration::from_secs(60),
        }
    );
    let command = replay(&[
        "app",
        "mac-screen-replay",
        "--path=/tmp/share.mp4",
        "--tab",
        "tab_3",
        "--frames",
        "30",
        "--loops",
        "2",
        "--timeout",
        "90",
    ]);
    assert_eq!(command.params, json!({"path": "/tmp/share.mp4", "loops": 2, "tab": "tab_3"}));
    assert_eq!((command.frames, command.timeout), (30, Duration::from_secs(90)));
    let relative = replay(&["app", "mac-screen-replay", "--path", "share.mp4"]);
    let path = relative.params["path"].as_str().unwrap();
    assert!(std::path::Path::new(path).is_absolute() && path.ends_with("share.mp4"), "{path}");
    for bad in [
        &["app", "mac-screen-replay"][..],
        &["app", "mac-screen-replay", "--path", ""],
        &["app", "mac-screen-replay", "--path", "/m.mp4", "--frames", "0"],
        &["app", "mac-screen-replay", "--path", "/m.mp4", "--frames", "121"],
        &["app", "mac-screen-replay", "--path", "/m.mp4", "--loops", "many"],
        &["app", "mac-screen-replay", "--path", "/m.mp4", "--timeout", "0"],
        &["app", "mac-screen-replay", "/m.mp4"],
        &["app", "mac-screen-replay", "--path", "/m.mp4", "--host", "x"],
    ] {
        assert!(parse(&args(bad)).is_err(), "{bad:?} should be refused");
    }
}

/// The report carries the pane's three stages, and the summary names the decode-to-glass p50; a
/// replay that never reached its frames says so instead of a number.
#[test]
fn mac_screen_replay_report_names_decode_present_p50() {
    let started = json!({"tab": "k1", "store_tab": "tab_3", "frame": "1920x1080", "samples": 300});
    let row = json!({
        "decode_present_ms": {"count": 120, "p50": 9.5, "p95": 14.0, "max": 20.1},
        "decode_ms": {"count": 120, "p50": 3.2, "p95": 5.0, "max": 7.0},
        "glass_ms": {"count": 120, "p50": 6.1, "p95": 9.0, "max": 13.0},
        "unpresented_frames": 0,
    });
    let done = report(&started, &row, 120, true);
    assert_eq!(done["tab"], "k1");
    assert_eq!(done["frames_presented"], 120);
    assert_eq!(done["decode_present_ms"]["p50"], 9.5);
    assert_eq!(done["glass_ms"]["p50"], 6.1);
    assert!(human(&done).starts_with("decode_present p50 9.5 ms p95 14 ms over 120 frames"));
    let short = report(&started, &json!({"unpresented_frames": 40}), 120, false);
    assert_eq!(short["ok"], false);
    assert_eq!(short["frames_presented"], 0);
    assert!(human(&short).contains("presented 0 of 120 frames"));
}
