//! `ClickTrace`: the last 200 presses, each with what took it and where focus landed.
//!
//! The app reads the clock, the wall time and the window names and passes them in; this ring
//! decides what is recorded.

use super::{EventKind, run};
use crate::ops::OpResult;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Presses kept.
pub const CAPACITY: usize = 200;
/// How long after a press a page's first-frame grant still counts as that press's (seconds).
pub const GRANT_WINDOW: f64 = 1.5;
/// Grants kept per press.
pub const GRANTS_PER_PRESS: usize = 4;
/// The control socket method the `cmux` CLI asks (`CLICKS_METHOD` in cmux-tui `cli/app.rs`).
pub const CONTROL_METHOD: &str = "input.clicks";

/// One press. The JSON keys are the Swift `Codable`'s snake_case ones.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Entry {
    pub seq: u64,
    pub at: String,
    pub button: String,
    pub x: i64,
    pub y: i64,
    pub window: String,
    pub window_number: i64,
    #[serde(default)]
    pub overlay_took: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub forwarded_to: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub forwarded_to_number: Option<i64>,
    #[serde(default)]
    pub page_grants: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key_window: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key_window_number: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub first_responder: Option<String>,
}

/// The `input.clicks` reply.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Report {
    pub capacity: usize,
    pub clicks: Vec<Entry>,
}

/// A window as the trace names it: its class name and number.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowRef {
    pub name: String,
    pub number: i64,
}

/// The key window after a press settled, with its first responder's class name.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeyWindow {
    pub name: String,
    pub number: i64,
    #[serde(default)]
    pub first_responder: Option<String>,
}

/// A press as the app saw it: its type, timestamp, screen point and window.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Press {
    pub kind: EventKind,
    pub timestamp: f64,
    pub x: f64,
    pub y: f64,
    #[serde(default)]
    pub window: Option<WindowRef>,
}

/// The newest press: its ring index, the clock and the event timestamp when it was recorded.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Open {
    pub index: usize,
    pub uptime: f64,
    pub timestamp: f64,
}

/// The ring.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClickTrace {
    #[serde(default)]
    pub ring: Vec<Entry>,
    #[serde(default)]
    pub head: usize,
    #[serde(default = "first_seq")]
    pub next_seq: u64,
    #[serde(default)]
    pub open: Option<Open>,
}

fn first_seq() -> u64 {
    1
}

impl Default for ClickTrace {
    fn default() -> Self {
        Self { ring: Vec::new(), head: 0, next_seq: 1, open: None }
    }
}

/// Whether `kind` is a press (left, right or other mouse down).
pub fn is_press(kind: EventKind) -> bool {
    matches!(kind, EventKind::LeftMouseDown | EventKind::RightMouseDown | EventKind::OtherMouseDown)
}

/// The press's button name.
pub fn button(kind: EventKind) -> &'static str {
    match kind {
        EventKind::LeftMouseDown => "left",
        EventKind::RightMouseDown => "right",
        _ => "other",
    }
}

/// A screen coordinate as a whole point: not finite is 0, out of range clamps.
pub fn point(value: f64) -> i64 {
    if !value.is_finite() {
        return 0;
    }
    let rounded = value.round();
    if rounded >= i64::MAX as f64 {
        return i64::MAX;
    }
    if rounded <= i64::MIN as f64 {
        return i64::MIN;
    }
    rounded as i64
}

impl ClickTrace {
    /// Records a press, unless it is the newest one again (same nonzero timestamp).
    /// `uptime` is the clock now, `at` the ISO 8601 wall time.
    pub fn press(&mut self, press: &Press, uptime: f64, at: &str) {
        if !is_press(press.kind) {
            return;
        }
        if let Some(open) = self.open
            && open.timestamp == press.timestamp
            && open.timestamp != 0.0
        {
            return;
        }
        let (window, window_number) = match &press.window {
            Some(w) => (w.name.clone(), w.number),
            None => ("none".to_string(), -1),
        };
        let entry = Entry {
            seq: 0,
            at: at.to_string(),
            button: button(press.kind).to_string(),
            x: point(press.x),
            y: point(press.y),
            window,
            window_number,
            overlay_took: false,
            forwarded_to: None,
            forwarded_to_number: None,
            page_grants: Vec::new(),
            key_window: None,
            key_window_number: None,
            first_responder: None,
        };
        self.append(entry, uptime, press.timestamp);
    }

    /// An overlay panel took the press: record it and name the panel.
    pub fn overlay_took(&mut self, press: &Press, panel: &WindowRef, uptime: f64, at: &str) {
        if !is_press(press.kind) {
            return;
        }
        self.press(press, uptime, at);
        self.update(|entry| {
            entry.overlay_took = true;
            entry.forwarded_to = Some(panel.name.clone());
            entry.forwarded_to_number = Some(panel.number);
        });
    }

    /// The newest press went on to `target`.
    pub fn forwarded(&mut self, kind: EventKind, timestamp: f64, target: &WindowRef) {
        if !is_press(kind) || self.open.map(|o| o.timestamp) != Some(timestamp) {
            return;
        }
        self.update(|entry| {
            entry.forwarded_to = Some(target.name.clone());
            entry.forwarded_to_number = Some(target.number);
        });
    }

    /// A page granted a first-frame hold within [`GRANT_WINDOW`] of the newest press.
    pub fn page_grant(&mut self, tab: &str, outcome: &str, uptime: f64) {
        let Some(open) = self.open else { return };
        if uptime - open.uptime > GRANT_WINDOW {
            return;
        }
        self.update(|entry| {
            if entry.page_grants.len() < GRANTS_PER_PRESS {
                entry.page_grants.push(format!("{tab}: {outcome}"));
            }
        });
    }

    /// The press reached its window: note the key window.
    pub fn dispatched(&mut self, kind: EventKind, timestamp: f64, key_window: Option<&KeyWindow>) {
        if !is_press(kind) {
            return;
        }
        self.settled(timestamp, key_window);
    }

    /// The frame after the press committed: note the key window.
    pub fn settled(&mut self, timestamp: f64, key_window: Option<&KeyWindow>) {
        if self.open.map(|o| o.timestamp) != Some(timestamp) {
            return;
        }
        self.update(|entry| {
            entry.key_window = key_window.map(|k| k.name.clone());
            entry.key_window_number = key_window.map(|k| k.number);
            entry.first_responder = key_window.and_then(|k| k.first_responder.clone());
        });
    }

    /// Oldest first; `limit` in `0..count` keeps the newest that many.
    pub fn entries(&self, limit: Option<i64>) -> Vec<Entry> {
        let ordered: Vec<Entry> = if self.ring.len() < CAPACITY {
            self.ring.clone()
        } else {
            self.ring[self.head..].iter().chain(&self.ring[..self.head]).cloned().collect()
        };
        suffix(ordered, limit)
    }

    /// Every trace's entries by time, then sequence.
    pub fn report(traces: &[ClickTrace], limit: Option<i64>) -> Report {
        let mut all: Vec<Entry> = traces.iter().flat_map(|t| t.entries(None)).collect();
        all.sort_by(|a, b| (a.at.as_str(), a.seq).cmp(&(b.at.as_str(), b.seq)));
        Report { capacity: CAPACITY, clicks: suffix(all, limit) }
    }

    fn append(&mut self, mut entry: Entry, uptime: f64, timestamp: f64) {
        entry.seq = self.next_seq;
        self.next_seq += 1;
        let index = if self.ring.len() < CAPACITY {
            self.ring.push(entry);
            self.ring.len() - 1
        } else {
            let index = self.head;
            self.ring[index] = entry;
            self.head = (self.head + 1) % CAPACITY;
            index
        };
        self.open = Some(Open { index, uptime, timestamp });
    }

    fn update(&mut self, change: impl FnOnce(&mut Entry)) {
        let Some(open) = self.open else { return };
        if let Some(entry) = self.ring.get_mut(open.index) {
            change(entry);
        }
    }
}

fn suffix(all: Vec<Entry>, limit: Option<i64>) -> Vec<Entry> {
    match limit {
        Some(limit) if limit >= 0 && (limit as usize) < all.len() => {
            let start = all.len() - limit as usize;
            all[start..].to_vec()
        }
        _ => all,
    }
}

/// One change to the ring.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Step {
    Press { press: Press, uptime: f64, at: String },
    OverlayTook { press: Press, panel: WindowRef, uptime: f64, at: String },
    Forwarded { kind: EventKind, timestamp: f64, target: WindowRef },
    PageGrant { tab: String, outcome: String, uptime: f64 },
    Dispatched { kind: EventKind, timestamp: f64, key_window: Option<KeyWindow> },
    Settled { timestamp: f64, key_window: Option<KeyWindow> },
}

impl ClickTrace {
    /// Applies one [`Step`].
    pub fn apply(&mut self, step: &Step) {
        match step {
            Step::Press { press, uptime, at } => self.press(press, *uptime, at),
            Step::OverlayTook { press, panel, uptime, at } => {
                self.overlay_took(press, panel, *uptime, at);
            }
            Step::Forwarded { kind, timestamp, target } => {
                self.forwarded(*kind, *timestamp, target);
            }
            Step::PageGrant { tab, outcome, uptime } => self.page_grant(tab, outcome, *uptime),
            Step::Dispatched { kind, timestamp, key_window } => {
                self.dispatched(*kind, *timestamp, key_window.as_ref());
            }
            Step::Settled { timestamp, key_window } => {
                self.settled(*timestamp, key_window.as_ref());
            }
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StepRequest {
    #[serde(default)]
    trace: ClickTrace,
    steps: Vec<Step>,
}

/// `window.clickTraceStep` `{trace?, steps: [Step]}` → the trace after them.
pub(super) fn op_step(request: &Value) -> OpResult {
    run(request, |r: StepRequest| {
        let mut trace = r.trace;
        for step in &r.steps {
            trace.apply(step);
        }
        trace
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EntriesRequest {
    trace: ClickTrace,
    #[serde(default)]
    limit: Option<i64>,
}

/// `window.clickEntries` `{trace, limit?}` → `[Entry]`.
pub(super) fn op_entries(request: &Value) -> OpResult {
    run(request, |r: EntriesRequest| r.trace.entries(r.limit))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReportRequest {
    traces: Vec<ClickTrace>,
    #[serde(default)]
    limit: Option<i64>,
}

/// `window.clickReport` `{traces, limit?}` → `{capacity, clicks}`.
pub(super) fn op_report(request: &Value) -> OpResult {
    run(request, |r: ReportRequest| ClickTrace::report(&r.traces, r.limit))
}

#[derive(Deserialize)]
struct PointRequest {
    value: f64,
}

/// `window.clickPoint` `{value}` → whole point.
pub(super) fn op_point(request: &Value) -> OpResult {
    run(request, |r: PointRequest| point(r.value))
}

#[derive(Deserialize)]
struct KindRequest {
    kind: EventKind,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ButtonReply {
    is_press: bool,
    button: &'static str,
}

/// `window.clickButton` `{kind}` → `{isPress, button}`.
pub(super) fn op_button(request: &Value) -> OpResult {
    run(request, |r: KindRequest| ButtonReply {
        is_press: is_press(r.kind),
        button: button(r.kind),
    })
}
