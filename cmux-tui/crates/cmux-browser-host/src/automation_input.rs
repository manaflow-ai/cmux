//! `automation.input` v1 (schemas/automation-input/event.schema.json): one
//! event per agent input, which the cmux app draws as the agent cursor.
//!
//! The gate publishes it after its policy and frame checks, right before it
//! dispatches the input, on the session's own event sink (the provider
//! engine tees cef/webkit sessions' events to the app). Refused inputs emit
//! nothing, and `seq` is gap-free per lease session. An event carries where
//! an input lands and never what it types: no text, key value or URL field.

use crate::driver::EventSink;
use crate::protocol::DriverEvent;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::{Mutex, OnceLock, PoisonError};
use std::time::Instant;

/// The event name on the driver event path.
pub const EVENT: &str = "automation.input";

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    Move,
    Click,
    DoubleClick,
    RightClick,
    Drag,
    Type,
    Key,
    Scroll,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Space {
    /// Unzoomed CSS px of the top-level document viewport (browser tabs).
    Viewport,
    /// Window-local points of a desktop window (`cua:` targets).
    Window,
}

/// One `automation.input` event, schema v1.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AutomationInputEvent {
    pub v: u8,
    pub session_id: String,
    pub target_id: String,
    pub seq: u64,
    pub kind: Kind,
    pub space: Space,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub point: Option<Point>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rect: Option<Rect>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub to: Option<Point>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub zoom: Option<f64>,
    pub t_ms: f64,
}

/// An input the gate is about to dispatch, before it has a `seq`.
#[derive(Debug, Clone, PartialEq)]
pub struct Planned {
    pub target_id: String,
    pub kind: Kind,
    pub point: Option<Point>,
    pub to: Option<Point>,
}

/// A press that has not been released yet.
#[derive(Debug, Clone, Copy)]
struct Press {
    at: Point,
    right: bool,
    clicks: i64,
}

#[derive(Debug, Default)]
struct Pointer {
    last: Option<Point>,
    press: Option<Press>,
}

/// A release this far (CSS px) from its press is a drag, not a click.
const DRAG_SLOP: f64 = 2.0;

fn now_ms() -> f64 {
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_secs_f64() * 1000.0
}

fn point_of(params: &Value) -> Option<Point> {
    let x = params.get("x").and_then(Value::as_f64)?;
    let y = params.get("y").and_then(Value::as_f64)?;
    Some(Point { x, y })
}

/// Publishes one session's inputs on its event sink.
pub struct InputEmitter {
    session_id: String,
    sink: EventSink,
    /// The next `seq`; held while an event is built and sent, so events
    /// leave in `seq` order with no gap.
    seq: Mutex<u64>,
    /// Pointer position and press per tab (a driver call may omit x/y).
    pointers: Mutex<HashMap<String, Pointer>>,
}

impl InputEmitter {
    pub fn new(session_id: impl Into<String>, sink: EventSink) -> InputEmitter {
        InputEmitter {
            session_id: session_id.into(),
            sink,
            seq: Mutex::new(0),
            pointers: Mutex::new(HashMap::new()),
        }
    }

    /// What a driver call that passed every check will input, if anything
    /// the app draws. Updates the pointer state, so call it once per
    /// dispatched call.
    pub fn plan(&self, method: &str, params: &Value) -> Option<Planned> {
        let target_id = params.get("targetId").and_then(Value::as_str).filter(|t| !t.is_empty())?;
        let planned =
            |kind, point, to| Some(Planned { target_id: target_id.to_owned(), kind, point, to });
        match method {
            "input.insertText" => planned(Kind::Type, None, None),
            "input.key" => match params.get("type").and_then(Value::as_str) {
                Some("up") => None,
                _ => planned(Kind::Key, None, None),
            },
            "input.mouse" => {
                let mut pointers = self.pointers.lock().unwrap_or_else(PoisonError::into_inner);
                let pointer = pointers.entry(target_id.to_owned()).or_default();
                let at = point_of(params).or(pointer.last);
                pointer.last = at;
                let at = at?;
                match params.get("type").and_then(Value::as_str) {
                    Some("move") => planned(Kind::Move, Some(at), None),
                    Some("down") => {
                        pointer.press = Some(Press {
                            at,
                            right: params.get("button").and_then(Value::as_str) == Some("right"),
                            clicks: params.get("clickCount").and_then(Value::as_i64).unwrap_or(1),
                        });
                        None
                    }
                    Some("up") => {
                        let press = pointer.press.take();
                        match press {
                            Some(press)
                                if (press.at.x - at.x).hypot(press.at.y - at.y) > DRAG_SLOP =>
                            {
                                planned(Kind::Drag, Some(press.at), Some(at))
                            }
                            Some(Press { right: true, .. }) => {
                                planned(Kind::RightClick, Some(at), None)
                            }
                            Some(Press { clicks, .. }) if clicks >= 2 => {
                                planned(Kind::DoubleClick, Some(at), None)
                            }
                            _ => planned(Kind::Click, Some(at), None),
                        }
                    }
                    Some("wheel") => {
                        let delta = |name| params.get(name).and_then(Value::as_f64).unwrap_or(0.0);
                        let to = Point { x: delta("deltaX"), y: delta("deltaY") };
                        planned(Kind::Scroll, Some(at), Some(to))
                    }
                    _ => None,
                }
            }
            _ => None,
        }
    }

    /// Publishes a planned input with the next `seq`.
    pub fn publish(&self, planned: Planned) {
        let mut seq = self.seq.lock().unwrap_or_else(PoisonError::into_inner);
        let event = AutomationInputEvent {
            v: 1,
            session_id: self.session_id.clone(),
            target_id: planned.target_id,
            seq: *seq,
            kind: planned.kind,
            space: Space::Viewport,
            point: planned.point,
            rect: None,
            to: planned.to,
            zoom: None,
            t_ms: now_ms(),
        };
        let Ok(payload) = serde_json::to_value(&event) else { return };
        *seq += 1;
        (self.sink)(DriverEvent { name: EVENT.to_owned(), payload });
    }
}

#[cfg(test)]
#[path = "automation_input_tests.rs"]
mod tests;

#[cfg(all(test, unix))]
#[path = "automation_input_e2e_tests.rs"]
mod e2e_tests;
