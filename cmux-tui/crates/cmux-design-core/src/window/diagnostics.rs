//! Diagnostics and debug probes: `SwitchKeyChanges`, `NSEvent.syntheticScroll`'s fields,
//! `SyntheticPointer`'s sweep schedule, move and report, and `TopAlignmentProbe`'s report.

use super::{Point, Rect, run};
use crate::ops::OpResult;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet};

/// A key-window change mark.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Mark {
    pub became: bool,
    pub at: f64,
}

/// `SwitchKeyChanges`.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct SwitchKeyChanges {
    pub marks: Vec<Mark>,
    pub full: bool,
}

/// A trace span: its name and start.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Span {
    pub name: String,
    pub start: f64,
}

/// A row of numbers by column name.
pub type Row = BTreeMap<String, f64>;

impl SwitchKeyChanges {
    /// `init(spans:capacity:)`: `key.become` and `key.resign` spans; a ring at capacity may have lost some.
    pub fn from_spans(spans: &[Span], capacity: usize) -> Self {
        let marks = spans
            .iter()
            .filter(|s| s.name == "key.become" || s.name == "key.resign")
            .map(|s| Mark { became: s.name == "key.become", at: s.start })
            .collect();
        Self { marks, full: spans.len() >= capacity }
    }

    /// `columns(forRowsAt:)`: each row counts the marks from its start to the next row's.
    pub fn columns(&self, starts: &[Option<f64>]) -> Vec<Row> {
        let mut placed: Vec<f64> = starts.iter().flatten().copied().collect();
        placed.sort_by(f64::total_cmp);
        starts
            .iter()
            .map(|start| {
                let Some(start) = *start else { return Row::new() };
                let end = placed.iter().copied().find(|p| *p > start).unwrap_or(f64::INFINITY);
                let own: Vec<&Mark> =
                    self.marks.iter().filter(|m| m.at >= start && m.at < end).collect();
                let became = own.iter().filter(|m| m.became).count() as f64;
                let total = own.len() as f64;
                Row::from([
                    ("key_changes".to_string(), total),
                    ("key_become".to_string(), became),
                    ("key_resign".to_string(), total - became),
                    ("key_marks_full".to_string(), if self.full { 1.0 } else { 0.0 }),
                ])
            })
            .collect()
    }

    /// `counted(_:)`: the rows with their counts (by `at_ms`), a row's own values winning.
    pub fn counted(&self, rows: &[Row]) -> Vec<Row> {
        let starts: Vec<Option<f64>> = rows.iter().map(|r| r.get("at_ms").copied()).collect();
        rows.iter()
            .zip(self.columns(&starts))
            .map(|(row, counts)| {
                let mut merged = counts;
                merged.extend(row.iter().map(|(k, v)| (k.clone(), *v)));
                merged
            })
            .collect()
    }
}

/// The scroll event `NSEvent.syntheticScroll` posts.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SyntheticScroll {
    pub wheel1: i32,
    pub wheel2: i32,
    /// `scrollWheelEventScrollPhase` (with `isContinuous` set), when the phase is known.
    pub phase: Option<i64>,
    /// Quartz's top-left location.
    pub location: Point,
}

/// The phase names the probe takes.
pub fn scroll_phase(phase: &str) -> Option<i64> {
    match phase {
        "began" => Some(1),
        "changed" => Some(2),
        "ended" => Some(4),
        _ => None,
    }
}

/// `NSEvent.syntheticScroll`'s fields from the screen point and the primary screen's height.
pub fn synthetic_scroll(
    screen: Point,
    primary_height: f64,
    dx: f64,
    dy: f64,
    phase: Option<&str>,
) -> SyntheticScroll {
    SyntheticScroll {
        wheel1: dy.round() as i32,
        wheel2: dx.round() as i32,
        phase: phase.and_then(scroll_phase),
        location: Point { x: screen.x, y: primary_height - screen.y },
    }
}

/// `SyntheticPointer.sweep`'s guard: a sweep needs moves and a rate.
pub fn sweep_runs(count: i64, hz: f64) -> bool {
    count > 0 && hz > 0.0
}

/// Move `index`'s due time from the start, in seconds.
pub fn sweep_due(index: i64, hz: f64) -> f64 {
    index as f64 / hz
}

/// A move started more than a period after its due time is late.
pub fn sweep_late(now: f64, due: f64, hz: f64) -> bool {
    now - due > 1.0 / hz
}

/// `SyntheticPointer.Sweep`.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Sweep {
    pub move_ms: Vec<f64>,
    pub late: i64,
    pub missing: i64,
    pub landed: i64,
    pub seconds: f64,
    pub areas: i64,
}

fn milli_round(v: f64) -> f64 {
    (v * 1_000.0).round() / 1_000.0
}

impl Sweep {
    /// `Sweep.foundation`: the report's fields, times rounded to a thousandth.
    pub fn foundation(&self) -> Value {
        json!({
            "move_ms": self.move_ms.iter().map(|m| milli_round(*m)).collect::<Vec<_>>(),
            "late": self.late,
            "missing": self.missing,
            "landed": self.landed,
            "seconds": milli_round(self.seconds),
            "moves": self.move_ms.len(),
            "areas": self.areas,
        })
    }
}

/// A tracking area as `SyntheticPointer.move` sees it.
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Area {
    pub id: u64,
    /// The owner's type name; null when the owner is not a responder.
    #[serde(default)]
    pub owner: Option<String>,
    /// The view is in the probed window.
    pub live: bool,
    /// `isHiddenOrHasHiddenAncestor`.
    #[serde(default)]
    pub hidden: bool,
    /// The point in the view's coordinates (null when there is no point).
    #[serde(default)]
    pub local: Option<Point>,
    pub rect: Rect,
    #[serde(default)]
    pub visible_rect: Rect,
    #[serde(default)]
    pub in_visible_rect: bool,
    #[serde(default)]
    pub enter_exit: bool,
    #[serde(default)]
    pub mouse_moved: bool,
}

/// `SyntheticPointer.Move`, plus the areas the pointer is now in.
#[derive(Debug, Clone, PartialEq, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PointerMove {
    pub entered: Vec<String>,
    pub exited: Vec<String>,
    pub inside: Vec<String>,
    pub moved: i64,
    pub now: Vec<u64>,
}

/// `SyntheticPointer.move(to:areas:)`'s decisions: `before` holds the areas the pointer was in
/// (with their owners and options), `areas` the window's areas now.
pub fn pointer_move(has_point: bool, before: &[Area], areas: &[Area]) -> PointerMove {
    let attached: BTreeSet<u64> = areas.iter().map(|a| a.id).collect();
    let mut now: BTreeMap<u64, &Area> = BTreeMap::new();
    for area in areas {
        if !has_point || !area.live || area.hidden {
            continue;
        }
        let Some(local) = area.local else { continue };
        let rect = if area.in_visible_rect { area.visible_rect } else { area.rect };
        if rect.contains(local) {
            now.insert(area.id, area);
        }
    }
    let was: BTreeSet<u64> = before.iter().map(|a| a.id).collect();
    let mut report = PointerMove::default();
    for area in before {
        if now.contains_key(&area.id) || !attached.contains(&area.id) || !area.enter_exit {
            continue;
        }
        if let Some(owner) = &area.owner {
            report.exited.push(owner.clone());
        }
    }
    for area in now.values() {
        let Some(owner) = &area.owner else { continue };
        if !was.contains(&area.id) && area.enter_exit {
            report.entered.push(owner.clone());
        }
        if area.mouse_moved {
            report.moved += 1;
        }
    }
    report.entered.sort();
    report.exited.sort();
    report.inside = now.values().filter_map(|a| a.owner.clone()).collect();
    report.inside.sort();
    report.now = now.keys().copied().collect();
    report
}

/// `TopAlignmentProbe.bandButtons`: report key and accessibility identifier.
pub const BAND_BUTTONS: [(&str, &str); 3] = [
    ("toggle", "cmux.titlebar.toggleSidebar"),
    ("back", "cmux.titlebar.back"),
    ("forward", "cmux.titlebar.forward"),
];

/// `TopAlignmentProbe.num`: to the hundredth.
pub fn num(value: f64) -> f64 {
    (value * 100.0).round() / 100.0
}

/// `TopAlignmentProbe.box`: `[minX, minY, width, height]`, each to the hundredth.
pub fn rect_box(rect: &Rect) -> [f64; 4] {
    [rect.min_x(), rect.min_y(), rect.width, rect.height].map(num)
}

/// A window rect flipped to the content's top-left origin.
pub fn top_left(in_window: &Rect, height: f64) -> Rect {
    Rect::new(in_window.min_x(), height - in_window.max_y(), in_window.width, in_window.height)
}

/// The band button key for an accessibility identifier.
pub fn band_key(identifier: &str) -> Option<&'static str> {
    BAND_BUTTONS.iter().find(|(_, id)| *id == identifier).map(|(key, _)| *key)
}

/// A reporter of `kind` anchored at `anchor` replaces the best so far when higher, then further left.
pub fn prefers(anchor: &Rect, best: Option<&Rect>) -> bool {
    best.is_none_or(|b| (anchor.min_y(), anchor.min_x()) < (b.min_y(), b.min_x()))
}

/// A view the probe visited, in its visit order, its rects already flipped to the top-left origin.
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProbeView {
    #[serde(default)]
    pub identifier: Option<String>,
    pub bounds: Rect,
    /// `TopAlignmentReporting.topAlignmentKind`, for reporters.
    #[serde(default)]
    pub kind: Option<String>,
    #[serde(default)]
    pub frames: BTreeMap<String, Rect>,
}

/// `TopAlignmentProbe.report()`'s map from what the app read (visible views only).
pub fn top_alignment(
    scale: f64,
    window: &Rect,
    height: f64,
    lights: Option<&Rect>,
    views: &[ProbeView],
) -> Map<String, Value> {
    let mut out = Map::new();
    out.insert("scale".into(), json!(scale));
    out.insert("window".into(), json!(rect_box(window)));
    if let Some(l) = lights {
        out.insert("lights".into(), json!(rect_box(&top_left(l, height))));
    }
    let mut best: BTreeMap<&str, (&Rect, &BTreeMap<String, Rect>)> = BTreeMap::new();
    for view in views {
        if view.bounds.width <= 0.0 {
            continue;
        }
        if let Some(key) = view.identifier.as_deref().and_then(band_key) {
            out.insert(key.into(), json!(rect_box(&view.bounds)));
        }
        if let Some(kind) = view.kind.as_deref() {
            if prefers(&view.bounds, best.get(kind).map(|b| b.0)) {
                best.insert(kind, (&view.bounds, &view.frames));
            }
        }
    }
    for (kind, (anchor, frames)) in best {
        out.insert(kind.into(), json!(rect_box(anchor)));
        for (name, frame) in frames {
            let value =
                if frame.width == 0.0 { json!(num(frame.min_x())) } else { json!(rect_box(frame)) };
            out.insert(name.clone(), value);
        }
    }
    out
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SwitchKeyRequest {
    #[serde(default)]
    changes: Option<SwitchKeyChanges>,
    #[serde(default)]
    spans: Option<Vec<Span>>,
    #[serde(default)]
    capacity: Option<usize>,
    #[serde(default)]
    starts: Option<Vec<Option<f64>>>,
    #[serde(default)]
    rows: Option<Vec<Row>>,
}

/// `window.switchKeyChanges` `{changes? | spans + capacity, starts? | rows?}` →
/// `{changes, columns?, counted?}`.
pub(super) fn op_switch_key_changes(request: &Value) -> OpResult {
    run(request, |r: SwitchKeyRequest| {
        let changes = match (r.changes, r.spans) {
            (Some(c), _) => c,
            (None, Some(spans)) => {
                SwitchKeyChanges::from_spans(&spans, r.capacity.unwrap_or(usize::MAX))
            }
            (None, None) => SwitchKeyChanges::default(),
        };
        let columns = r.starts.map(|s| changes.columns(&s));
        let counted = r.rows.map(|rows| changes.counted(&rows));
        json!({ "changes": changes, "columns": columns, "counted": counted })
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ScrollRequest {
    screen: Point,
    primary_height: f64,
    dx: f64,
    dy: f64,
    #[serde(default)]
    phase: Option<String>,
}

/// `window.syntheticScroll` `{screen, primaryHeight, dx, dy, phase?}` → [`SyntheticScroll`].
pub(super) fn op_synthetic_scroll(request: &Value) -> OpResult {
    run(request, |r: ScrollRequest| {
        synthetic_scroll(r.screen, r.primary_height, r.dx, r.dy, r.phase.as_deref())
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SweepScheduleRequest {
    count: i64,
    hz: f64,
    #[serde(default)]
    index: i64,
    #[serde(default)]
    now: Option<f64>,
}

/// `window.sweepSchedule` `{count, hz, index?, now?}` → `{runs, period, due, late}`.
pub(super) fn op_sweep_schedule(request: &Value) -> OpResult {
    run(request, |r: SweepScheduleRequest| {
        let runs = sweep_runs(r.count, r.hz);
        let due = if runs { Some(sweep_due(r.index, r.hz)) } else { None };
        let late = match (due, r.now) {
            (Some(due), Some(now)) => sweep_late(now, due, r.hz),
            _ => false,
        };
        json!({ "runs": runs, "period": if runs { Some(1.0 / r.hz) } else { None }, "due": due, "late": late })
    })
}

/// `window.sweepFoundation` [`Sweep`] → the report's fields.
pub(super) fn op_sweep_foundation(request: &Value) -> OpResult {
    run(request, |r: Sweep| r.foundation())
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PointerMoveRequest {
    has_point: bool,
    #[serde(default)]
    before: Vec<Area>,
    #[serde(default)]
    areas: Vec<Area>,
}

/// `window.pointerMove` `{hasPoint, before, areas}` → [`PointerMove`].
pub(super) fn op_pointer_move(request: &Value) -> OpResult {
    run(request, |r: PointerMoveRequest| pointer_move(r.has_point, &r.before, &r.areas))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TopAlignmentRequest {
    scale: f64,
    window: Rect,
    height: f64,
    #[serde(default)]
    lights: Option<Rect>,
    #[serde(default)]
    views: Vec<ProbeView>,
}

/// `window.topAlignment` `{scale, window, height, lights?, views}` → the report map.
pub(super) fn op_top_alignment(request: &Value) -> OpResult {
    run(request, |r: TopAlignmentRequest| {
        top_alignment(r.scale, &r.window, r.height, r.lights.as_ref(), &r.views)
    })
}
