//! `WindowZoom`: the green button's zoom toggle between the user's frame and the standard frame.
//! The app reads the frames, animates and calls back; this keeps the state and the decisions.

use super::{Rect, run};
use crate::ops::OpResult;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// `WindowZoom.tolerance`: frames within a point on every edge are the same.
pub const TOLERANCE: f64 = 1.0;

/// `WindowZoom`'s stored state.
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct WindowZoom {
    pub user_frame: Option<Rect>,
    pub animating_to: Option<Rect>,
    pub animating_standard: Option<Rect>,
    pub generation: i64,
}

/// `WindowZoom.same`.
pub fn same(a: &Rect, b: &Rect) -> bool {
    (a.min_x() - b.min_x()).abs() <= TOLERANCE
        && (a.min_y() - b.min_y()).abs() <= TOLERANCE
        && (a.width - b.width).abs() <= TOLERANCE
        && (a.height - b.height).abs() <= TOLERANCE
}

impl WindowZoom {
    /// `WindowZoom.target(from:standard:)`: at the standard frame, back to the user's (none: stay);
    /// else note the user's frame and go to the standard one.
    pub fn target(&mut self, frame: Rect, standard: Rect) -> Option<Rect> {
        let current = self.animating_to.unwrap_or(frame);
        if same(&current, &standard) {
            return self.user_frame.take();
        }
        self.user_frame = Some(current);
        Some(standard)
    }

    /// `WindowZoom.begin(to:standard:)`: the animation's generation.
    pub fn begin(&mut self, target: Rect, standard: Rect) -> i64 {
        self.generation = self.generation.wrapping_add(1);
        self.animating_to = Some(target);
        self.animating_standard = Some(standard);
        self.generation
    }

    /// `WindowZoom.end(_:)`: only the latest animation's end clears it.
    pub fn end(&mut self, finished: i64) {
        if finished != self.generation {
            return;
        }
        self.animating_to = None;
        self.animating_standard = None;
    }

    /// `WindowZoom.isZoomingIn`.
    pub fn is_zooming_in(&self) -> Option<bool> {
        match (self.animating_to, self.animating_standard) {
            (Some(t), Some(s)) => Some(same(&t, &s)),
            _ => None,
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ZoomReply<T> {
    state: WindowZoom,
    is_zooming_in: Option<bool>,
    #[serde(flatten)]
    out: T,
}

fn reply<T>(state: WindowZoom, out: T) -> ZoomReply<T> {
    ZoomReply { is_zooming_in: state.is_zooming_in(), state, out }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TargetRequest {
    #[serde(default)]
    state: WindowZoom,
    frame: Rect,
    standard: Rect,
}

#[derive(Serialize)]
struct TargetOut {
    target: Option<Rect>,
}

/// `window.zoomTarget` `{state?, frame, standard}` → `{state, isZoomingIn, target}`.
pub(super) fn op_target(request: &Value) -> OpResult {
    run(request, |r: TargetRequest| {
        let mut state = r.state;
        let target = state.target(r.frame, r.standard);
        reply(state, TargetOut { target })
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BeginRequest {
    #[serde(default)]
    state: WindowZoom,
    target: Rect,
    standard: Rect,
}

#[derive(Serialize)]
struct BeginOut {
    generation: i64,
}

/// `window.zoomBegin` `{state?, target, standard}` → `{state, isZoomingIn, generation}`.
pub(super) fn op_begin(request: &Value) -> OpResult {
    run(request, |r: BeginRequest| {
        let mut state = r.state;
        let generation = state.begin(r.target, r.standard);
        reply(state, BeginOut { generation })
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EndRequest {
    #[serde(default)]
    state: WindowZoom,
    finished: i64,
}

#[derive(Serialize)]
struct Nothing {}

/// `window.zoomEnd` `{state?, finished}` → `{state, isZoomingIn}`.
pub(super) fn op_end(request: &Value) -> OpResult {
    run(request, |r: EndRequest| {
        let mut state = r.state;
        state.end(r.finished);
        reply(state, Nothing {})
    })
}

#[derive(Deserialize)]
struct SameRequest {
    a: Rect,
    b: Rect,
}

/// `window.zoomSame` `{a, b}` → bool.
pub(super) fn op_same(request: &Value) -> OpResult {
    run(request, |r: SameRequest| same(&r.a, &r.b))
}
