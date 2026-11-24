//! Which parts of a cache this launch may apply. Geometry never ages out (layout is layout: a
//! split that was 60/40 last week is still 60/40), it only follows the displays. Pictures are
//! another matter: a different build may draw differently, and an old picture shows stale text.
use serde::{Deserialize, Serialize};

use crate::model::{Display, LayoutCache, Rect, WindowLayout};

/// A saved picture older than this is not drawn.
pub const CONTENT_MAX_AGE_MS: u64 = 24 * 60 * 60 * 1000;

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct NowState {
    pub build_key: String,
    pub displays: Vec<Display>,
    /// Wall clock; 0 skips the picture age check.
    pub now_ms: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReasonKind {
    /// The window's display is gone or changed frame or scale: its frame was clamped onto the
    /// nearest display now (and its pictures dropped when its size or scale changed).
    DisplayMoved,
    /// Another build wrote the pictures: geometry still applies, pictures do not.
    BuildChanged,
    /// A picture older than `CONTENT_MAX_AGE_MS`.
    ContentStale,
    /// No display at all: nothing to place a window on.
    NoDisplay,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Reason {
    pub window_id: String,
    pub kind: ReasonKind,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub pane_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WindowPlacement {
    pub id: String,
    /// The cached frame, or its clamp onto a display that exists now.
    pub frame: Rect,
    pub display_id: u32,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Usable {
    /// Windows whose cached geometry applies, in cache order.
    pub windows: Vec<String>,
    /// Where each of those windows goes.
    pub frames: Vec<WindowPlacement>,
    /// Panes whose `last_content` picture may be drawn.
    pub content: Vec<String>,
    pub reasons: Vec<Reason>,
}

/// What of `cache` this launch may apply, given the build and displays now.
pub fn usable(cache: &LayoutCache, now: &NowState) -> Usable {
    let mut out = Usable::default();
    let same_build = cache.build_key == now.build_key;
    for w in &cache.windows {
        let reason = |kind, pane_id| Reason { window_id: w.id.clone(), kind, pane_id };
        let Some((placement, moved)) = place(w, &cache.displays, &now.displays) else {
            out.reasons.push(reason(ReasonKind::NoDisplay, None));
            continue;
        };
        if moved {
            out.reasons.push(reason(ReasonKind::DisplayMoved, None));
        }
        // A window that changed size or scale lays out anew, so its pictures no longer fit.
        let pictures_fit = same_build
            && placement.frame.width == w.frame.width
            && placement.frame.height == w.frame.height
            && now
                .displays
                .iter()
                .any(|d| d.id == placement.display_id && d.backing_scale == w.backing_scale);
        let has_pictures = w.panes.leaves().iter().any(|l| l.last_content.is_some());
        if has_pictures && !same_build {
            out.reasons.push(reason(ReasonKind::BuildChanged, None));
        }
        if pictures_fit {
            for l in w.panes.leaves() {
                let Some(c) = &l.last_content else { continue };
                let taken =
                    if c.captured_at_ms == 0 { cache.written_at_ms } else { c.captured_at_ms };
                if now.now_ms != 0 && now.now_ms.saturating_sub(taken) > CONTENT_MAX_AGE_MS {
                    out.reasons.push(reason(ReasonKind::ContentStale, Some(l.pane_id.clone())));
                } else {
                    out.content.push(l.pane_id.clone());
                }
            }
        }
        out.windows.push(w.id.clone());
        out.frames.push(placement);
    }
    out
}

/// The window's placement now and whether it moved. Its display unchanged (same id, frame and
/// scale as the cache recorded, and the window still on it) keeps the frame exactly; otherwise the
/// frame is clamped onto the display it overlaps most, or the nearest one.
fn place(
    w: &WindowLayout,
    recorded: &[Display],
    displays: &[Display],
) -> Option<(WindowPlacement, bool)> {
    let then = recorded.iter().find(|d| d.id == w.display_id);
    if let Some(d) = displays.iter().find(|d| d.id == w.display_id)
        && d.backing_scale == w.backing_scale
        && then.is_none_or(|t| t.frame == d.frame && t.backing_scale == d.backing_scale)
        && clamp_onto(&w.frame, &d.frame) == w.frame
    {
        return Some((
            WindowPlacement { id: w.id.clone(), frame: w.frame, display_id: d.id },
            false,
        ));
    }
    let d = nearest_display(&w.frame, displays)?;
    let frame = clamp_onto(&w.frame, &d.frame);
    Some((WindowPlacement { id: w.id.clone(), frame, display_id: d.id }, true))
}

fn nearest_display<'a>(frame: &Rect, displays: &'a [Display]) -> Option<&'a Display> {
    let overlap = |d: &&Display| frame.intersection_area(&d.frame);
    let best = displays.iter().max_by(|a, b| overlap(a).total_cmp(&overlap(b)))?;
    if overlap(&best) > 0.0 {
        return Some(best);
    }
    let center = |r: &Rect| (r.x + r.width / 2.0, r.y + r.height / 2.0);
    let (cx, cy) = center(frame);
    let distance = |d: &&Display| {
        let (dx, dy) = center(&d.frame);
        (dx - cx).powi(2) + (dy - cy).powi(2)
    };
    displays.iter().min_by(|a, b| distance(a).total_cmp(&distance(b)))
}

/// `frame` moved (and shrunk only if it must) to lie inside `area`.
pub fn clamp_onto(frame: &Rect, area: &Rect) -> Rect {
    let width = frame.width.min(area.width);
    let height = frame.height.min(area.height);
    // min then max, not `clamp`: rounding can put `max_x - width` a hair under `x`, which clamp
    // panics on; this way the origin wins.
    let x = frame.x.min(area.max_x() - width).max(area.x);
    let y = frame.y.min(area.max_y() - height).max(area.y);
    Rect::new(x, y, width, height)
}

#[cfg(test)]
#[path = "usable_tests.rs"]
mod tests;
