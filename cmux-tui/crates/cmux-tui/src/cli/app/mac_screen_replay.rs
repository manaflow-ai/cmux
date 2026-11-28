//! `cmux app mac-screen-replay --path <movie> [--tab <tab>] [--frames <1-120>] [--loops <N>]
//! [--timeout <seconds>]`: plays a recorded screen share (an MP4 the Screen Sharing toolbar's
//! Record wrote, or any H.264 or HEVC movie) through a Screen Sharing tab's own decoder and
//! presenter with no host peer (`mac_screen.replay`, every build), waits until that pane has put
//! `--frames` frames on the glass (default 120, the app's window), and prints the pane's Decode,
//! Present and the two together (`decode_ms`, `glass_ms`, `decode_present_ms`: count, p50, p95,
//! max) from `mac_screen.state`. Goal screen-share-viewer-present: a number nightly can read
//! without a second Mac. `--tab` names a Screen Sharing tab (`cmux tab new-mac-screen --json`'s
//! id); without it the app picks one showing its home page. The tab must be on screen: a hidden
//! viewer presents nothing, and the command says so when it times out (exit 1).

use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};

use super::super::OutputMode;
use super::{AppCommand, GlobalArgs, Options, UsageError};

/// The app method (MacScreenPages.releaseMethods[1], every build).
pub(super) const METHOD: &str = "mac_screen.replay";
/// The app keeps the last 120 frames' timings (MacScreenFrameCounter), so no more can be waited for.
pub(super) const MAX_FRAMES: u64 = 120;
pub(super) const DEFAULT_LOOPS: u64 = 20;
pub(super) const DEFAULT_TIMEOUT_SECONDS: u64 = 60;
const USAGE: &str = "usage: cmux app mac-screen-replay --path <movie> [--tab <tab>] [--frames <1-120>] [--loops <1-1000>] [--timeout <1-600>]";
/// Loading a long movie reads every sample first.
const LOAD_TIMEOUT: Duration = Duration::from_secs(60);
const POLL: Duration = Duration::from_millis(500);

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Replay {
    pub(crate) params: Value,
    pub(crate) frames: u64,
    pub(crate) timeout: Duration,
}

fn bounded(value: Option<&str>, default: u64, max: u64) -> Result<u64, UsageError> {
    match value {
        None => Ok(default),
        Some(value) => value
            .parse::<u64>()
            .ok()
            .filter(|number| (1..=max).contains(number))
            .ok_or_else(|| UsageError::new(USAGE)),
    }
}

/// `rest` starts with `mac-screen-replay`. A relative `--path` is made absolute: the app runs
/// elsewhere.
pub(super) fn parse(rest: &[String]) -> Result<AppCommand, UsageError> {
    let options = Options::parse(
        rest.get(1..).unwrap_or_default(),
        &["path", "tab", "frames", "loops", "timeout"],
        &[],
    )?;
    let Some(path) = options.value("path").filter(|path| !path.is_empty()) else {
        return Err(UsageError::new(USAGE));
    };
    let path = if Path::new(path).is_absolute() || path.starts_with('~') {
        path.to_owned()
    } else {
        std::env::current_dir()
            .map(|cwd| cwd.join(path).to_string_lossy().into_owned())
            .unwrap_or_else(|_| path.to_owned())
    };
    let frames = bounded(options.value("frames"), MAX_FRAMES, MAX_FRAMES)?;
    let loops = bounded(options.value("loops"), DEFAULT_LOOPS, 1000)?;
    let timeout = bounded(options.value("timeout"), DEFAULT_TIMEOUT_SECONDS, 600)?;
    let mut params = Map::new();
    params.insert("path".into(), json!(path));
    params.insert("loops".into(), json!(loops));
    if let Some(tab) = options.value("tab").filter(|tab| !tab.is_empty()) {
        params.insert("tab".into(), json!(tab));
    }
    Ok(AppCommand::MacScreenReplay(Replay {
        params: Value::Object(params),
        frames,
        timeout: Duration::from_secs(timeout),
    }))
}

/// The number at `row[key].count`, 0 when the pane has no timings yet.
fn count(row: &Value, key: &str) -> u64 {
    row.get(key).and_then(|value| value.get("count")).and_then(Value::as_u64).unwrap_or(0)
}

/// The report: the replay's answer and the pane's timings once `frames` are presented.
pub(crate) fn report(started: &Value, row: &Value, frames: u64, done: bool) -> Value {
    let field = |key: &str| row.get(key).cloned().unwrap_or(Value::Null);
    json!({
        "ok": done,
        "tab": started.get("tab").cloned().unwrap_or(Value::Null),
        "store_tab": started.get("store_tab").cloned().unwrap_or(Value::Null),
        "movie_frame": started.get("frame").cloned().unwrap_or(Value::Null),
        "samples": started.get("samples").cloned().unwrap_or(Value::Null),
        "frames_wanted": frames,
        "frames_presented": count(row, "decode_present_ms"),
        "decode_present_ms": field("decode_present_ms"),
        "decode_ms": field("decode_ms"),
        "glass_ms": field("glass_ms"),
        "present_ms": field("present_ms"),
        "unpresented_frames": field("unpresented_frames"),
        "frames_decoded": field("frames_decoded"),
        "frame": field("frame"),
        "state": field("state"),
        "window_on_primary_display": field("window_on_primary_display"),
    })
}

pub(super) fn run(global: &GlobalArgs, stream: &mut UnixStream, replay: Replay) -> i32 {
    let started = match super::request(stream, METHOD, replay.params, LOAD_TIMEOUT) {
        Ok(Ok(answer)) => answer,
        Ok(Err(mut error)) => {
            if super::error_code(&error) == Some("method_not_found") {
                super::skew::annotate(stream, METHOD, &mut error);
            }
            return super::super::wire::print_local_error(&error, global.output, 1);
        }
        Err(error) => {
            return super::super::wire::print_local_error(
                &json!({"code": "app_unreachable", "message": error}),
                global.output,
                3,
            );
        }
    };
    if let Some(message) = started.get("error").and_then(Value::as_str) {
        return super::super::wire::print_local_error(
            &json!({"code": "replay_failed", "message": message}),
            global.output,
            1,
        );
    }
    let Some(tab) = started.get("tab").and_then(Value::as_str).map(str::to_owned) else {
        return super::super::wire::print_local_error(
            &json!({"code": "replay_failed", "message": "the app named no tab"}),
            global.output,
            1,
        );
    };
    let deadline = Instant::now() + replay.timeout;
    let mut row = Value::Null;
    let done = loop {
        match super::super::mac_screen_view::request_state(stream, Some(&tab)) {
            Ok(state) => {
                if let Some(found) = super::super::mac_screen_view::row_for(&state, &tab) {
                    row = found.clone();
                }
            }
            Err(error) => {
                return super::super::wire::print_local_error(
                    &json!({"code": "app_unreachable", "message": error}),
                    global.output,
                    3,
                );
            }
        }
        if count(&row, "decode_present_ms") >= replay.frames {
            break true;
        }
        if Instant::now() >= deadline {
            break false;
        }
        std::thread::sleep(POLL);
    };
    let report = report(&started, &row, replay.frames, done);
    let code = i32::from(!done);
    match global.output {
        OutputMode::Human => {
            println!("{}", human(&report));
            code
        }
        _ => {
            let printed = super::super::wire::print_local_success(&report, global.output);
            if printed == 0 { code } else { printed }
        }
    }
}

/// One line: the decode-to-glass p50 and p95 over the frames presented, or why it has none.
pub(crate) fn human(report: &Value) -> String {
    let ms = |key: &str, stat: &str| {
        report
            .get(key)
            .and_then(|value| value.get(stat))
            .and_then(Value::as_f64)
            .map_or_else(|| "-".to_owned(), |value| format!("{value}"))
    };
    let presented = report["frames_presented"].as_u64().unwrap_or(0);
    let wanted = report["frames_wanted"].as_u64().unwrap_or(0);
    if report["ok"].as_bool() != Some(true) {
        return format!(
            "replay presented {presented} of {wanted} frames before the timeout (unpresented {}); is the tab on screen?",
            report["unpresented_frames"]
        );
    }
    format!(
        "decode_present p50 {} ms p95 {} ms over {presented} frames (decode p50 {} ms, glass p50 {} ms)",
        ms("decode_present_ms", "p50"),
        ms("decode_present_ms", "p95"),
        ms("decode_ms", "p50"),
        ms("glass_ms", "p50"),
    )
}

#[cfg(test)]
#[path = "mac_screen_replay_tests.rs"]
mod tests;
