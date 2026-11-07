//! The agent page ring (CmuxNextAgentPane/AgentPageFlickerLog.swift):
//! `<Application Support>/<bundle id>/diagnostics/agent-page-flicker.ndjson`
//! and its older half `agent-page-flicker.1.ndjson`, one JSON object per line
//! with `at` (ISO 8601 UTC with milliseconds) and `kind`. The app writes it on
//! every build, so a recording only reads the lines inside its window.
//!
//! - `long-frame` {ms}: a frame over 100 ms while visible; an `X` slice that
//!   ends at `at`.
//! - `frames` {n, p50, p95, max, miss120, miss60, over50, ms}: one window of a
//!   page's frames (at most one a second per page): `n` frames that had a page
//!   change, interval percentiles in ms, how many intervals missed a 120 Hz
//!   frame (over 12.5 ms), a 60 Hz frame (over 25 ms) or were over 50 ms, and
//!   the span covered. Counter tracks per page, and the page rows of the summary.
//! - Every other kind (`page-load`, `visibility`, `transcript-mount`,
//!   `navigation`, `web-content-ended`, `window-occlusion`): an instant.
//!
//! A page line carries `page` (`chat:<session>` or `new-tab`) and the pid of
//! its WebContent process, so its events sit with that process's counters,
//! one thread per page.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::clock::parse_timestamp;
use crate::trace::Event;

pub const FILE_NAME: &str = "agent-page-flicker.ndjson";
pub const OLDER_NAME: &str = "agent-page-flicker.1.ndjson";

/// One `frames` window.
#[derive(Debug, Clone, PartialEq)]
pub struct Frames {
    pub page: String,
    pub at_us: i64,
    pub n: f64,
    pub p50: f64,
    pub p95: f64,
    pub max: f64,
    pub miss120: f64,
    pub miss60: f64,
    pub over50: f64,
    pub ms: f64,
}

/// What the ring held inside the window.
#[derive(Debug, Default, PartialEq)]
pub struct Parsed {
    pub events: Vec<Event>,
    pub frames: Vec<Frames>,
    pub long_frames: usize,
    pub lines: usize,
    /// (pid, tid, page): the thread names to give the page tracks.
    pub threads: Vec<(i64, u64, String)>,
}

/// The ring's two files, older first.
pub fn files(diagnostics: &Path) -> [PathBuf; 2] {
    [diagnostics.join(OLDER_NAME), diagnostics.join(FILE_NAME)]
}

/// The lines of `text` between `start_us` and `end_us`. A line with no pid
/// goes to `app_pid`.
pub fn parse<'a>(
    lines: impl IntoIterator<Item = &'a str>,
    start_us: i64,
    end_us: i64,
    app_pid: i64,
) -> Parsed {
    let mut parsed = Parsed::default();
    let mut tids: HashMap<(i64, String), u64> = HashMap::new();
    for line in lines {
        let Ok(Value::Object(mut object)) = serde_json::from_str::<Value>(line.trim()) else {
            continue;
        };
        let Some(at) = object.get("at").and_then(Value::as_str).and_then(parse_timestamp) else {
            continue;
        };
        if at < start_us || at > end_us {
            continue;
        }
        let Some(kind) = object.remove("kind").and_then(|kind| kind.as_str().map(str::to_owned))
        else {
            continue;
        };
        object.remove("at");
        parsed.lines += 1;
        let pid = object.get("pid").and_then(Value::as_i64).unwrap_or(app_pid);
        let page = object.get("page").and_then(Value::as_str).unwrap_or("app").to_owned();
        let next = tids.len() as u64 + 1;
        let tid = *tids.entry((pid, page.clone())).or_insert_with(|| {
            parsed.threads.push((pid, 900_000 + next, format!("page {page}")));
            900_000 + next
        });
        let number = |key: &str| object.get(key).and_then(Value::as_f64).unwrap_or(0.0);
        match kind.as_str() {
            "long-frame" => {
                let dur = (number("ms") * 1000.0).round() as i64;
                parsed.long_frames += 1;
                let mut slice = Event::slice("long-frame", "page", at - dur, dur, pid, tid);
                slice.args = object;
                parsed.events.push(slice);
            }
            "frames" => {
                let frames = Frames {
                    page: page.clone(),
                    at_us: at,
                    n: number("n"),
                    p50: number("p50"),
                    p95: number("p95"),
                    max: number("max"),
                    miss120: number("miss120"),
                    miss60: number("miss60"),
                    over50: number("over50"),
                    ms: number("ms"),
                };
                parsed.events.push(Event::counter(
                    &format!("frame ms {page}"),
                    at,
                    pid,
                    &[("p50", frames.p50), ("p95", frames.p95), ("max", frames.max)],
                ));
                parsed.events.push(Event::counter(
                    &format!("frames {page}"),
                    at,
                    pid,
                    &[
                        ("n", frames.n),
                        ("miss120", frames.miss120),
                        ("miss60", frames.miss60),
                        ("over50", frames.over50),
                    ],
                ));
                parsed.frames.push(frames);
            }
            _ => {
                let mut instant = Event::instant(&kind, "page", at, pid, tid);
                instant.args = object;
                parsed.events.push(instant);
            }
        }
    }
    parsed
}
