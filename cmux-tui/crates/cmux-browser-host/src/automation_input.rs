//! `automation.input` v1 (schemas/automation-input/event.schema.json): one
//! event per agent input, which the cmux app draws as the agent cursor.
//!
//! When: after the gate's policy, secret and frame checks and the driver's
//! own checks (a provider session's lease and session state), right before
//! the dispatch (`Driver::call_announced`). A call refused by any check
//! emits nothing and takes no seq; `seq` is gap-free per lease session, from
//! 0. A dispatch that fails after the announcement keeps its event (the
//! input was sent to the engine).
//!
//! Where: down the driver's own session event path
//! (`Driver::send_session_event`); a provider engine sends it through its
//! session sink, which `tee_inputs` forwards to the app as one `input`
//! frame; an ended provider session drops it. A driver with no such path
//! (headless) leaves it to the gate, which hands it to the session sink.
//!
//! Order: the event is delivered on the caller's thread before the dispatch
//! starts, so it comes before every event the dispatch causes (a navigation
//! after a click), on the session sink and to the app. There is no order
//! against events with other causes, which arrive on the provider's or the
//! CDP reader's thread.
//!
//! An event carries where an input lands. Type and key events also carry
//! what the agent types (`typing`), so the app can show it next to the
//! cursor (user, 2026-10-18: "a small keystroke overlay showing typed
//! text/keys"); the gate masks it (`Typing::masked`) for a secret, a
//! password field and any field it cannot see into, and the text never
//! holds a secret's value. No URL field.

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

/// What a type or key event types, as the app shows it.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Typing {
    /// The typed text (type), or the text a key press types (key). When
    /// `masked`, one `•` per character (eight for a secret, whose length
    /// is not shown); at most `MAX_TYPED_CHARS` characters, the end kept.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    /// The DOM key value of a key event (`Enter`, `a`); absent for a
    /// masked printable key.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key: Option<String>,
    /// Held modifiers of a key event (`Alt`, `Control`, `Meta`, `Shift`).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub modifiers: Vec<String>,
    /// The text is hidden: a secret, a password field, or a field the
    /// host cannot see into (a cross-origin frame).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub masked: bool,
    /// The text replaces the field's value (`locator.fill`) instead of
    /// adding to it.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub replace: bool,
}

/// The most characters of typed text one event carries.
pub const MAX_TYPED_CHARS: usize = 64;

impl Typing {
    /// `text` as the event carries it: at most `MAX_TYPED_CHARS` characters
    /// (the end kept), or that many `•` when masked.
    pub fn shown(text: &str, masked: bool) -> String {
        let count = text.chars().count();
        if masked {
            return "•".repeat(count.min(MAX_TYPED_CHARS));
        }
        text.chars().skip(count.saturating_sub(MAX_TYPED_CHARS)).collect()
    }
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
    /// Type and key events: what is typed (see `Typing`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub typing: Option<Typing>,
    pub t_ms: f64,
}

/// An input the gate is about to dispatch, before it has a `seq`.
#[derive(Debug, Clone, PartialEq)]
pub struct Planned {
    pub target_id: String,
    pub kind: Kind,
    pub point: Option<Point>,
    pub to: Option<Point>,
    /// The focused element a type or key event goes to, when measured.
    pub rect: Option<Rect>,
    pub typing: Option<Typing>,
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

/// The marker `locator.fill` passes after a secret's stand-in value
/// (runtime-core.js), so the stand-in is not shown as typed.
pub const FILL_STAND_IN: &str = "cmux-secret-stand-in";

/// A page-agent `fill` (`frame.evaluate` in the agent world with args
/// `["fill", handle, value]`) that is not a secret's stand-in.
pub fn is_agent_fill(params: &Value) -> bool {
    let args = params.get("args").and_then(Value::as_array);
    params.get("world").and_then(Value::as_str) == Some("agent")
        && args.and_then(|a| a.first()).and_then(Value::as_str) == Some("fill")
        && args.and_then(|a| a.get(2)).is_some_and(Value::is_string)
        && args.and_then(|a| a.get(3)).and_then(Value::as_str) != Some(FILL_STAND_IN)
}

/// Publishes one session's inputs on its event sink.
pub struct InputEmitter {
    session_id: String,
    /// The session's sink, for drivers with no session event path of their
    /// own (`Driver::send_session_event` returns false: headless).
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
        let planned = |kind, point, to| {
            Some(Planned {
                target_id: target_id.to_owned(),
                kind,
                point,
                to,
                rect: None,
                typing: None,
            })
        };
        match method {
            "input.insertText" => planned(Kind::Type, None, None),
            // `locator.fill`'s value, set by the page agent (not a secret's
            // stand-in, which the host's secret typing follows).
            "frame.evaluate" if is_agent_fill(params) => planned(Kind::Type, None, None),
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

    /// The lease session the events name.
    pub fn session_id(&self) -> &str {
        &self.session_id
    }

    /// Sends another gate event of this session (no `seq`) the same way as
    /// an input: through `via`, or the session sink when `via` returns
    /// false.
    pub fn send(&self, event: DriverEvent, via: &dyn Fn(DriverEvent) -> bool) {
        if !via(event.clone()) {
            (self.sink)(event);
        }
    }

    /// Publishes a planned input with the next `seq`: through `via` (the
    /// driver's own session event path), or the session sink when `via`
    /// returns false. Exactly one of them gets the event.
    pub fn publish(&self, planned: Planned, via: &dyn Fn(DriverEvent) -> bool) {
        let mut seq = self.seq.lock().unwrap_or_else(PoisonError::into_inner);
        let event = AutomationInputEvent {
            v: 1,
            session_id: self.session_id.clone(),
            target_id: planned.target_id,
            seq: *seq,
            kind: planned.kind,
            space: Space::Viewport,
            point: planned.point,
            rect: planned.rect,
            to: planned.to,
            zoom: None,
            typing: planned.typing,
            t_ms: now_ms(),
        };
        let Ok(payload) = serde_json::to_value(&event) else { return };
        *seq += 1;
        let event = DriverEvent { name: EVENT.to_owned(), payload };
        if !via(event.clone()) {
            (self.sink)(event);
        }
    }
}

#[cfg(test)]
#[path = "automation_input_tests.rs"]
mod tests;
