//! Follow mode's focus signals (host to viewer, the `focus` data channel),
//! ported from `FocusSignals.swift`: coordinate conversion, the JSON event
//! text, damage coalescing and the producer's per-tick decision. One JSON
//! event per message, coordinates in the streamed display's pixels, origin
//! top left, `t_us` the host's monotonic clock in microseconds (an input).

use crate::geometry::{Point, Rect, Size};
use serde::{Deserialize, Serialize};

/// The streamed display, for converting global coordinates to its pixels.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct FocusGeometry {
    /// The display's frame in global display coordinates (points, top left, y down).
    pub display: Rect,
    /// The display's native size in pixels.
    pub pixels: Size,
}

impl FocusGeometry {
    /// An AppKit point (bottom left origin, y up) in global display coordinates.
    pub fn flipped_point(point: Point, main_height: f64) -> Point {
        Point { x: point.x, y: main_height - point.y }
    }

    /// An AppKit rect in global display coordinates.
    pub fn flipped_rect(rect: Rect, main_height: f64) -> Rect {
        Rect::new(rect.min_x(), main_height - rect.max_y(), rect.width(), rect.height())
    }

    fn scale(&self) -> Size {
        let dw = self.display.width();
        let dh = self.display.height();
        Size {
            w: if dw > 0.0 { self.pixels.w / dw } else { 0.0 },
            h: if dh > 0.0 { self.pixels.h / dh } else { 0.0 },
        }
    }

    /// A global point in display pixels; `None` when it is off this display.
    pub fn point(&self, global: Point) -> Option<Point> {
        if !(self.display.width() > 0.0
            && self.display.height() > 0.0
            && self.display.contains(global))
        {
            return None;
        }
        let s = self.scale();
        Some(Point {
            x: (global.x - self.display.min_x()) * s.w,
            y: (global.y - self.display.min_y()) * s.h,
        })
    }

    /// A global rect in display pixels, clipped to the display; `None` when
    /// none of it is on it. A zero-width rect (a caret) keeps its height.
    pub fn rect(&self, global: Rect) -> Option<Rect> {
        let d = self.display;
        let finite = [global.min_x(), global.min_y(), global.width(), global.height()]
            .iter()
            .all(|v| v.is_finite());
        if !(d.width() > 0.0 && d.height() > 0.0 && finite) {
            return None;
        }
        let left = global.min_x().max(d.min_x());
        let right = global.max_x().min(d.max_x());
        let top = global.min_y().max(d.min_y());
        let bottom = global.max_y().min(d.max_y());
        if !(right >= left && bottom >= top && left < d.max_x() && top < d.max_y()) {
            return None;
        }
        let s = self.scale();
        Some(Rect::new(
            (left - d.min_x()) * s.w,
            (top - d.min_y()) * s.h,
            (right - left) * s.w,
            (bottom - top) * s.h,
        ))
    }

    /// A rect in the captured picture's pixels (`captured` its size) in
    /// display pixels, clipped to the display.
    pub fn captured(&self, rect: Rect, captured: Size) -> Option<Rect> {
        if !(captured.w > 0.0 && captured.h > 0.0) || rect.is_empty() {
            return None;
        }
        let sx = self.pixels.w / captured.w;
        let sy = self.pixels.h / captured.h;
        let scaled =
            Rect::new(rect.min_x() * sx, rect.min_y() * sy, rect.width() * sx, rect.height() * sy);
        let clipped = scaled.intersection(&Rect::new(0.0, 0.0, self.pixels.w, self.pixels.h))?;
        if clipped.is_empty() { None } else { Some(clipped) }
    }
}

/// The focused window: its window-list number and frame in global display
/// coordinates, and its owning process.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct FocusWindow {
    pub id: u64,
    pub frame: Rect,
    #[serde(default)]
    pub pid: i32,
}

/// What a focus event carries.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum FocusSignal {
    Source { w: f64, h: f64 },
    Pointer { x: f64, y: f64 },
    Caret(Rect),
    Window { id: u64, rect: Rect },
    Damage(Rect),
    Cut,
}

/// One focus event, as cmux-follow-cam's serde `Event` reads it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FocusEvent {
    pub t_us: u64,
    pub signal: FocusSignal,
}

impl FocusEvent {
    /// The message: `t_us`, the `kind` tag, then its fields.
    pub fn json(&self) -> String {
        let n = Self::number;
        let rect = |r: &Rect| {
            format!(
                r#""x":{},"y":{},"w":{},"h":{}"#,
                n(r.min_x()),
                n(r.min_y()),
                n(r.width()),
                n(r.height())
            )
        };
        let head = format!(r#"{{"t_us":{},"kind":"#, self.t_us);
        let tail = match &self.signal {
            FocusSignal::Source { w, h } => format!(r#""source","w":{},"h":{}}}"#, n(*w), n(*h)),
            FocusSignal::Pointer { x, y } => format!(r#""pointer","x":{},"y":{}}}"#, n(*x), n(*y)),
            FocusSignal::Caret(r) => format!(r#""caret",{}}}"#, rect(r)),
            FocusSignal::Window { id, rect: r } => format!(r#""window","id":{},{}}}"#, id, rect(r)),
            FocusSignal::Damage(r) => format!(r#""damage",{}}}"#, rect(r)),
            FocusSignal::Cut => r#""cut"}"#.to_string(),
        };
        head + &tail
    }

    /// A coordinate to a tenth, clamped to ±1e9, never in exponent form or
    /// non-finite (non-finite is "0"); integral values print as integers.
    pub fn number(value: f64) -> String {
        if !value.is_finite() {
            return "0".to_string();
        }
        let tenth = ((value * 10.0).round() / 10.0).clamp(-1e9, 1e9);
        if tenth == tenth.round() {
            return (tenth as i64).to_string();
        }
        // Rust's shortest round-trip text equals Swift's for |v| in [0.1, 1e9).
        format!("{tenth}")
    }
}

/// Screen damage between two sends: nearby rects merged into regions, at
/// most [`FocusDamage::MAXIMUM_REGIONS`] kept. A send takes the largest few.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FocusDamage {
    regions: Vec<Rect>,
}

fn area(r: &Rect) -> f64 {
    r.width() * r.height()
}

fn distance(a: &Rect, b: &Rect) -> f64 {
    (a.mid_x() - b.mid_x()).hypot(a.mid_y() - b.mid_y())
}

/// Index of the first minimum, as Swift's `indices.min(by:)`.
fn first_min(values: impl Iterator<Item = f64>) -> Option<usize> {
    let mut best: Option<(usize, f64)> = None;
    for (i, v) in values.enumerate() {
        if best.is_none_or(|(_, b)| v < b) {
            best = Some((i, v));
        }
    }
    best.map(|(i, _)| i)
}

impl FocusDamage {
    pub const MAXIMUM_REGIONS: usize = 16;
    /// Rects closer than this (pixels) are one region.
    pub const GAP: f64 = 32.0;

    pub fn new() -> Self {
        Self::default()
    }

    pub fn count(&self) -> usize {
        self.regions.len()
    }

    pub fn add(&mut self, rects: &[Rect]) {
        for rect in rects {
            if !rect.is_empty() && rect.width().is_finite() && rect.height().is_finite() {
                self.insert(*rect);
            }
        }
    }

    fn insert(&mut self, rect: Rect) {
        let mut merged = rect;
        let mut index = 0;
        while index < self.regions.len() {
            let grown = self.regions[index].inset(-Self::GAP, -Self::GAP);
            if grown.is_some_and(|g| g.intersects(&merged)) {
                merged = merged.union(&self.regions.remove(index));
                index = 0;
            } else {
                index += 1;
            }
        }
        self.regions.push(merged);
        if self.regions.len() <= Self::MAXIMUM_REGIONS {
            return;
        }
        // Too many: the smallest joins the region nearest it.
        let Some(smallest) = first_min(self.regions.iter().map(area)) else { return };
        let small = self.regions.remove(smallest);
        let Some(nearest) = first_min(self.regions.iter().map(|r| distance(r, &small))) else {
            return;
        };
        let other = self.regions.remove(nearest);
        self.insert(small.union(&other));
    }

    /// The largest `limit` regions, largest first; the rest is dropped.
    pub fn drain(&mut self, limit: usize) -> Vec<Rect> {
        let mut regions = std::mem::take(&mut self.regions);
        regions.sort_by(|a, b| area(b).partial_cmp(&area(a)).unwrap_or(std::cmp::Ordering::Equal));
        regions.truncate(limit);
        regions
    }
}

/// One tick's readings, as the Swift producer reads them: the geometry and
/// the probe's pointer, focused window and caret (global coordinates).
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct FocusSample {
    pub geometry: Option<FocusGeometry>,
    pub pointer: Option<Point>,
    pub window: Option<FocusWindow>,
    pub caret: Option<Rect>,
}

/// What the producer last sent successfully.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FocusSent {
    pub source: Option<Size>,
    pub pointer: Option<Point>,
    pub caret: Option<Rect>,
    pub window: Option<(u64, Rect)>,
}

/// One tick's decision: the messages to send in order, and the state to
/// commit once they all went.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FocusTick {
    pub messages: Vec<String>,
    pub next: FocusSent,
}

/// The producer's state machine: each signal at its own rate (pointer every
/// tick, caret every 2nd, window every 6th, damage every 3rd), and once a
/// second or after a failed send everything again.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FocusProducer {
    damage: FocusDamage,
    ticks: u64,
    resync: bool,
    sent: FocusSent,
}

impl Default for FocusProducer {
    fn default() -> Self {
        Self::new()
    }
}

impl FocusProducer {
    pub const TICKS_PER_SECOND: u64 = 30;
    pub const CARET_EVERY: u64 = 2;
    pub const WINDOW_EVERY: u64 = 6;
    pub const DAMAGE_EVERY: u64 = 3;
    pub const DAMAGE_REGIONS_PER_SEND: usize = 3;
    /// A pointer move shorter than this (display pixels) is not sent.
    pub const POINTER_STEP: f64 = 0.5;

    pub fn new() -> Self {
        Self { damage: FocusDamage::new(), ticks: 0, resync: true, sent: FocusSent::default() }
    }

    /// One captured picture's changed rects, in that picture's pixels.
    pub fn damage(&mut self, geometry: Option<&FocusGeometry>, rects: &[Rect], captured: Size) {
        let Some(geometry) = geometry else { return };
        let converted: Vec<Rect> =
            rects.iter().filter_map(|r| geometry.captured(*r, captured)).collect();
        if !converted.is_empty() {
            self.damage.add(&converted);
        }
    }

    /// Decides one tick. Advances the tick count and drains due damage;
    /// `None` without geometry. Follow with [`commit`](Self::commit) or
    /// [`failed`](Self::failed).
    pub fn tick(&mut self, sample: &FocusSample, now_us: u64) -> Option<FocusTick> {
        let tick = self.ticks;
        self.ticks += 1;
        let full = self.resync || tick.is_multiple_of(Self::TICKS_PER_SECOND);
        let geometry = sample.geometry?;
        let state = self.sent;
        let mut next = state;
        let mut signals = Vec::new();
        if full || state.source != Some(geometry.pixels) {
            signals.push(FocusSignal::Source { w: geometry.pixels.w, h: geometry.pixels.h });
            next.source = Some(geometry.pixels);
        }
        if let Some(pointer) = sample.pointer.and_then(|p| geometry.point(p)) {
            let moved = state.pointer.is_none_or(|last| {
                (last.x - pointer.x).hypot(last.y - pointer.y) >= Self::POINTER_STEP
            });
            if full || moved {
                signals.push(FocusSignal::Pointer { x: pointer.x, y: pointer.y });
                next.pointer = Some(pointer);
            }
        }
        if (full || tick.is_multiple_of(Self::WINDOW_EVERY))
            && let Some(window) = sample.window
            && let Some(rect) = geometry.rect(window.frame)
            && (full || state.window.is_none_or(|(id, r)| id != window.id || r != rect))
        {
            signals.push(FocusSignal::Window { id: window.id, rect });
            next.window = Some((window.id, rect));
        }
        if full || tick.is_multiple_of(Self::CARET_EVERY) {
            let caret = sample.caret.and_then(|c| geometry.rect(c));
            if let Some(c) = caret
                && (full || caret != state.caret)
            {
                signals.push(FocusSignal::Caret(c));
            }
            next.caret = caret;
        }
        if tick.is_multiple_of(Self::DAMAGE_EVERY) {
            signals.extend(
                self.damage
                    .drain(Self::DAMAGE_REGIONS_PER_SEND)
                    .into_iter()
                    .map(FocusSignal::Damage),
            );
        }
        let messages =
            signals.into_iter().map(|signal| FocusEvent { t_us: now_us, signal }.json()).collect();
        Some(FocusTick { messages, next })
    }

    /// Every message went: remember what was sent.
    pub fn commit(&mut self, tick: FocusTick) {
        self.sent = tick.next;
        self.resync = false;
    }

    /// A send failed (the channel is not open yet): everything goes again
    /// next tick; nothing is committed.
    pub fn failed(&mut self) {
        self.resync = true;
    }

    /// Swift's `tick(now:)`: decide, send in order until one fails, then
    /// commit or mark failed.
    pub fn run_tick(
        &mut self,
        sample: &FocusSample,
        now_us: u64,
        mut send: impl FnMut(&str) -> bool,
    ) {
        let Some(tick) = self.tick(sample, now_us) else { return };
        if tick.messages.iter().all(|m| send(m)) {
            self.commit(tick);
        } else {
            self.failed();
        }
    }
}

#[cfg(test)]
#[path = "focus_tests.rs"]
mod tests;
