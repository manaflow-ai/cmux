//! Launch: `LaunchDisplay` (which screen a launch opens on), `LaunchLayoutSettleTally` (when the
//! first window's layout settles), `LaunchRecordRequest` and `FrameStripKeyRepeat`.

use super::run;
use crate::ops::OpResult;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// `LaunchDisplay.environmentKey`.
pub const DISPLAY_ENV_KEY: &str = "CMUX_NEXT_LAUNCH_DISPLAY";

/// `LaunchDisplay`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LaunchDisplay {
    BuiltIn,
    Index(i64),
}

/// `LaunchDisplay.parse(_:isDevBuild:)`: unset is the built-in screen on dev builds.
pub fn parse_display(value: Option<&str>, is_dev_build: bool) -> Option<LaunchDisplay> {
    // `.whitespaces` trims spaces and tabs, not newlines.
    let trimmed = value.unwrap_or("").trim_matches(|c: char| {
        c.is_whitespace()
            && !matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
    });
    match trimmed.to_lowercase().as_str() {
        "" => is_dev_build.then_some(LaunchDisplay::BuiltIn),
        "builtin" | "built-in" | "internal" => Some(LaunchDisplay::BuiltIn),
        "main" => Some(LaunchDisplay::Index(0)),
        other => other.parse::<i64>().ok().filter(|i| *i >= 0).map(LaunchDisplay::Index),
    }
}

impl LaunchDisplay {
    /// `LaunchDisplay.screenIndex(builtIn:)`: `screens` says which screens are built in.
    pub fn screen_index(self, screens: &[bool]) -> Option<usize> {
        if screens.is_empty() {
            return None;
        }
        match self {
            Self::BuiltIn => screens.iter().position(|b| *b),
            Self::Index(i) => Some(i.clamp(0, screens.len() as i64 - 1) as usize),
        }
    }
}

/// `LaunchLayoutSettleTally.quietMs`.
pub const QUIET_MS: f64 = 1_500.0;
/// `LaunchLayoutSettleTally.capMs`.
pub const CAP_MS: f64 = 5_000.0;

/// The largest move: the view's mark name and how far it moved.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Move {
    pub name: String,
    pub points: f64,
}

/// `LaunchLayoutSettleTally`.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SettleTally {
    pub first_ms: Option<f64>,
    pub last_change_ms: Option<f64>,
    pub last_changed: String,
    pub changed_frames: i64,
    pub largest: Option<Move>,
}

impl SettleTally {
    pub fn first(&mut self, ms: f64) {
        if self.first_ms.is_none() {
            self.first_ms = Some(ms);
        }
    }

    pub fn note(&mut self, ms: f64, change: &str, mv: Option<Move>) {
        if self.first_ms.is_none() {
            return self.first(ms);
        }
        self.changed_frames += 1;
        self.last_change_ms = Some(ms);
        self.last_changed = change.to_string();
        if let Some(mv) = mv
            && mv.points > self.largest.as_ref().map_or(0.0, |l| l.points)
        {
            self.largest = Some(mv);
        }
    }

    pub fn is_over(&self, ms: f64) -> bool {
        let Some(first) = self.first_ms else { return false };
        ms - self.last_change_ms.unwrap_or(first) >= QUIET_MS || ms - first >= CAP_MS
    }

    pub fn marks(&self) -> Vec<(String, f64)> {
        let Some(first) = self.first_ms else { return Vec::new() };
        let settle = self.last_change_ms.unwrap_or(first);
        let mut marks = vec![
            ("layout.first_frame".to_string(), first),
            ("layout.settle".to_string(), settle),
            ("layout.max_move".to_string(), self.largest.as_ref().map_or(0.0, |l| l.points)),
            ("layout.changed_frames".to_string(), self.changed_frames as f64),
        ];
        if let Some(l) = &self.largest {
            marks.push((format!("layout.max_move.{}", l.name), l.points));
        }
        if self.last_change_ms.is_some() {
            marks.push((format!("layout.last.{}", self.last_changed), settle));
        }
        if let Some(last) = self.last_change_ms
            && last - first > CAP_MS - QUIET_MS
        {
            marks.push(("layout.capped".to_string(), settle));
        }
        marks
    }
}

/// `LaunchLayoutSettle.markName`: a view description's first word (to a space or `<`), else "view".
pub fn mark_name(name: &str) -> String {
    let word: String = name.chars().take_while(|c| *c != ' ' && *c != '<').collect();
    if word.is_empty() { "view".to_string() } else { word }
}

/// `LaunchRecordRequest`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RecordRequest {
    pub dir: String,
    pub seconds: f64,
}

/// `NSString.expandingTildeInPath` for the current user's `~`.
fn expand_tilde(path: &str, home: &str) -> String {
    if path == "~" {
        home.to_string()
    } else if let Some(rest) = path.strip_prefix("~/") {
        format!("{}/{}", home.trim_end_matches('/'), rest)
    } else {
        path.to_string()
    }
}

/// `LaunchRecordRequest.init?(arguments:)`: `--record-launch DIR [--record-launch-seconds S]`,
/// seconds in 0.1...12 (6 when unset).
pub fn record_request(arguments: &[String], home: &str) -> Option<RecordRequest> {
    let flag = arguments.iter().position(|a| a == "--record-launch")?;
    let dir = arguments.get(flag + 1).filter(|d| !d.starts_with("--"))?;
    let asked = arguments
        .iter()
        .position(|a| a == "--record-launch-seconds")
        .and_then(|i| arguments.get(i + 1))
        .and_then(|s| s.parse::<f64>().ok());
    Some(RecordRequest {
        dir: expand_tilde(dir, home),
        seconds: asked.unwrap_or(6.0).clamp(0.1, 12.0),
    })
}

/// `FrameStripKeyRepeat.interval`, in milliseconds: at least 1, 40 when unset.
pub fn key_repeat_interval(interval_ms: Option<f64>) -> i64 {
    (interval_ms.unwrap_or(40.0).trunc() as i64).max(1)
}

/// `FrameStripKeyRepeat.delay(beforeKey:elapsed:)`, in milliseconds.
pub fn key_repeat_delay(interval_ms: i64, index: i64, elapsed_ms: f64) -> f64 {
    ((interval_ms * index) as f64 - elapsed_ms).max(0.0)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ParseRequest {
    #[serde(default)]
    value: Option<String>,
    is_dev_build: bool,
}

/// `window.launchDisplayParse` `{value?, isDevBuild}` → `"builtIn"`, `{"index": N}` or null.
pub(super) fn op_display_parse(request: &Value) -> OpResult {
    run(request, |r: ParseRequest| parse_display(r.value.as_deref(), r.is_dev_build))
}

#[derive(Deserialize)]
struct ScreenIndexRequest {
    display: LaunchDisplay,
    screens: Vec<bool>,
}

/// `window.launchDisplayScreenIndex` `{display, screens}` → index or null.
pub(super) fn op_display_screen_index(request: &Value) -> OpResult {
    run(request, |r: ScreenIndexRequest| r.display.screen_index(&r.screens))
}

/// One step on the tally.
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(tag = "op", rename_all = "camelCase")]
pub enum SettleStep {
    First {
        at: f64,
    },
    Note {
        at: f64,
        change: String,
        #[serde(default, rename = "move")]
        mv: Option<Move>,
    },
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SettleRequest {
    #[serde(default)]
    tally: SettleTally,
    #[serde(default)]
    steps: Vec<SettleStep>,
    #[serde(default)]
    now: Option<f64>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SettleReply {
    tally: SettleTally,
    is_over: bool,
    marks: Vec<(String, f64)>,
}

/// `window.launchSettle` `{tally?, steps?, now?}` → `{tally, isOver, marks: [[name, ms]]}`.
pub(super) fn op_settle(request: &Value) -> OpResult {
    run(request, |r: SettleRequest| {
        let mut tally = r.tally;
        for step in r.steps {
            match step {
                SettleStep::First { at } => tally.first(at),
                SettleStep::Note { at, change, mv } => tally.note(at, &change, mv),
            }
        }
        let is_over = r.now.is_some_and(|n| tally.is_over(n));
        let marks = tally.marks();
        SettleReply { tally, is_over, marks }
    })
}

#[derive(Deserialize)]
struct NameRequest {
    name: String,
}

/// `window.launchSettleMarkName` `{name}` → name.
pub(super) fn op_mark_name(request: &Value) -> OpResult {
    run(request, |r: NameRequest| mark_name(&r.name))
}

#[derive(Deserialize)]
struct RecordRequestRequest {
    arguments: Vec<String>,
    home: String,
}

/// `window.launchRecordRequest` `{arguments, home}` → `{dir, seconds}` or null.
pub(super) fn op_record_request(request: &Value) -> OpResult {
    run(request, |r: RecordRequestRequest| record_request(&r.arguments, &r.home))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct KeyRepeatRequest {
    #[serde(default)]
    interval_ms: Option<f64>,
    #[serde(default)]
    index: i64,
    #[serde(default)]
    elapsed_ms: f64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct KeyRepeatReply {
    interval_ms: i64,
    delay_ms: f64,
}

/// `window.frameStripKeyRepeat` `{intervalMs?, index, elapsedMs}` → `{intervalMs, delayMs}`.
pub(super) fn op_key_repeat(request: &Value) -> OpResult {
    run(request, |r: KeyRepeatRequest| {
        let interval_ms = key_repeat_interval(r.interval_ms);
        KeyRepeatReply {
            interval_ms,
            delay_ms: key_repeat_delay(interval_ms, r.index, r.elapsed_ms),
        }
    })
}
