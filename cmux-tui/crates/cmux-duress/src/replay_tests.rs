use std::path::Path;

use super::*;

fn recordings() -> Inputs {
    // affected-reads: cmux-tui webviews/test/fixtures/chat-sim/replay-lane-session.ndjson
    // affected-reads: cmux-tui/crates/cmux-agent-cli-render/tests/fixtures/claude-code-2.1.310/pty.jsonl webviews/test/fixtures/chat-sim/replay-lane-session.ndjson
    let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
    Inputs::load_repo(&repo).expect("the PTY and chat fixtures (a full checkout)")
}

fn scenario(text: &str) -> Scenario {
    Scenario::parse(text).unwrap()
}

#[test]
fn a_pause_is_caught_up_in_frames_of_frame_bytes() {
    // 512 kbit/s for 6 s, a 2 s pause: about 128 KB held, written 16 KB a frame.
    let s = scenario(
        r#"
name = "t"
summary = "t"
spec = "idle,stream_kbps=512,stream_seconds=6"
headless = true
frame_bytes = 16384
[[event]]
kind = "pause"
at_ms = 2000
ms = 2000
[[check]]
metric = "resume_catch_up_frames"
min = 4
[sim]
ui = ["X"]
"#,
    );
    let run = run(&s, &recordings()).unwrap();
    let frames = run.metrics.0["resume_catch_up_frames"].samples[0];
    assert!((4.0..=40.0).contains(&frames), "{frames}");
    assert!(run.metrics.0["resume_catch_up_ms"].samples[0] >= (frames - 1.0) * FRAME_MS);
    assert_eq!(run.metrics.0["unfinished_marks"].samples, vec![0.0]);
    let judged = scenario::judge(&s.checks, &run.metrics);
    assert!(judged[0].pass, "{judged:?}");
}

#[test]
fn resizes_and_themes_land_in_the_frame() {
    let s = scenario(
        r##"
name = "t"
summary = "t"
spec = "idle,stream_kbps=128,stream_seconds=3"
headless = true
[[event]]
kind = "resize"
every_ms = 250
rows = [40, 22]
[[event]]
kind = "theme"
every_ms = 400
themes = [{ name = "dark", fg = "#ffffff", bg = "#000000" }, { name = "light", fg = "#111111", bg = "#fafafa" }]
[[check]]
metric = "resize_mismatch"
max = 0
[sim]
ui = ["X"]
"##,
    );
    let run = run(&s, &recordings()).unwrap();
    assert_eq!(run.metrics.0["resize_ms"].samples.len(), 11);
    assert_eq!(run.metrics.0["resize_mismatch"].samples, vec![0.0]);
    assert_eq!(run.metrics.0["theme_ms"].samples.len(), 7);
    assert_eq!(run.metrics.0["theme_mismatch"].samples, vec![0.0]);
}

#[test]
fn projection_paints_what_the_mac_shows() {
    let s = scenario(
        r#"
name = "t"
summary = "t"
spec = "idle"
headless = true
path = "projection"
cols = 80
rows = 24
[tui]
doc_lines = 500
append_lines_per_s = 20
seconds = 2
[[event]]
kind = "scroll"
every_ms = 50
rows = -3
[[check]]
metric = "paint_mismatch"
max = 0
[sim]
ui = ["X"]
"#,
    );
    let run = run(&s, &recordings()).unwrap();
    assert_eq!(run.metrics.0["paint_mismatch"].samples, vec![0.0]);
    assert!(run.metrics.0["scroll_to_paint_ms"].samples.len() >= 30);
    for stage in [
        "mac_queue_ms",
        "mac_grid_ms",
        "mac_diff_ms",
        "mac_encode_ms",
        "wire_ms",
        "phone_decode_ms",
        "phone_paint_ms",
        "vsync_wait_ms",
    ] {
        assert!(!run.metrics.0[stage].samples.is_empty(), "{stage}");
    }
}

/// The default path: the same TUI as PTY bytes, one event per redraw, or coalesced.
#[test]
fn a_tui_on_the_terminal_path_paints_what_the_mac_shows() {
    let text = |coalesce: &str| {
        format!(
            r#"
name = "t"
summary = "t"
spec = "idle,link=lan"
headless = true
cols = 50
rows = 40
{coalesce}
[tui]
doc_lines = 500
append_lines_per_s = 62
redraw_fps = 62
seconds = 2
[[event]]
kind = "scroll"
every_ms = 50
rows = -3
[[event]]
kind = "echo"
every_ms = 250
[[check]]
metric = "paint_mismatch"
max = 0
[sim]
ui = ["X"]
"#
        )
    };
    let each = run(&scenario(&text("")), &recordings()).unwrap().metrics;
    let held = run(&scenario(&text("coalesce_ms = 17")), &recordings()).unwrap().metrics;
    for metrics in [&each, &held] {
        assert_eq!(metrics.0["paint_mismatch"].samples, vec![0.0]);
        assert!(metrics.0["scroll_to_paint_ms"].samples.len() >= 30);
        assert!(metrics.0["echo_to_paint_ms"].samples.len() >= 7);
        for stage in ["mac_queue_ms", "wire_ms", "phone_parse_ms", "phone_build_ms"] {
            assert!(!metrics.0[stage].samples.is_empty(), "{stage}");
        }
    }
    // Every redraw carried, in fewer events when held.
    let carried = |m: &Metrics| m.0["redraws_per_event"].samples.iter().sum::<f64>();
    assert_eq!(carried(&each), carried(&held));
    assert!(held.0["wire_bytes"].samples.len() < each.0["wire_bytes"].samples.len());
}

/// A phone slower than the events: painting at most once per display frame
/// (`phone_coalesce`) shows every scroll sooner than a paint per event, in fewer paints,
/// with the same screen.
#[test]
fn a_slow_phone_painting_once_per_hop_keeps_up() {
    let text = |phone: &str| {
        format!(
            r#"
name = "t"
summary = "t"
spec = "idle,link=lan"
headless = true
cols = 50
rows = 40
phone_event_ms = 19.0
{phone}
[tui]
doc_lines = 500
append_lines_per_s = 62
redraw_fps = 62
seconds = 2
[[event]]
kind = "scroll"
every_ms = 50
rows = -3
[[event]]
kind = "echo"
every_ms = 250
[[check]]
metric = "paint_mismatch"
max = 0
[sim]
ui = ["X"]
"#
        )
    };
    let each = run(&scenario(&text("")), &recordings()).unwrap().metrics;
    let once = run(&scenario(&text("phone_coalesce = true")), &recordings()).unwrap().metrics;
    let p95 = |m: &Metrics, name: &str| {
        let mut v = m.0[name].samples.clone();
        v.sort_by(f64::total_cmp);
        v[(v.len() * 95 / 100).min(v.len() - 1)]
    };
    for metrics in [&each, &once] {
        assert_eq!(metrics.0["paint_mismatch"].samples, vec![0.0]);
    }
    // Every scroll and echo still painted.
    for name in ["scroll_to_paint_ms", "echo_to_paint_ms"] {
        assert_eq!(each.0[name].samples.len(), once.0[name].samples.len(), "{name}");
    }
    assert!(once.0["phone_paint_ms"].samples.len() < each.0["phone_paint_ms"].samples.len());
    assert!(p95(&once, "scroll_to_paint_ms") < p95(&each, "scroll_to_paint_ms"));
    // At most one paint per display frame.
    assert!(once.0["phone_paints_per_s"].samples[0] <= 1000.0 / FRAME_MS + 1.0);
}

#[test]
fn sim_only_scenarios_do_not_run() {
    let s = scenario(
        r#"
name = "t"
summary = "t"
spec = "duress"
headless = false
headless_reason = "SwiftUI only"
[sim]
ui = ["X"]
"#,
    );
    assert!(run(&s, &recordings()).err().unwrap().contains("sim-only"));
}
