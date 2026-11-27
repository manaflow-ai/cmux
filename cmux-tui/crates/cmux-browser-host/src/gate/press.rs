//! The press target check (classic cmux BrowserReplPressTarget): an
//! `input.mouse` press that names what it must reach (`expect`) is checked
//! right before it is sent, on every engine, and refused `stale` when the
//! page put another element (or another frame) at the point since the
//! runtime's own check.
//!
//! `expect` is `{frameId?, handle, x, y, owners?: [{frameId?, handle, x, y}]}`:
//! the target in its frame at the point in that frame's viewport, then each
//! parent frame's `<iframe>` at the point where the frame below lands.
//! `selector` (optional, the target level only) is the locator's selector in
//! the target's frame: when the page replaced the target (a re-render) and
//! exactly one element that matches it is at the point, the press goes to
//! that one, as a person's press there would. Each
//! level is checked with the page agent's `hitTarget` in the frame's agent
//! world (an act, as the press is: the press's lease covers it). The engine
//! never sees `expect`.

use super::Gate;
use crate::protocol::{DriverError, ErrorCode};
use cmux_json::JsonSet as _;
use serde_json::{Value, json};

/// A tab holds at most 1,000 frames, so no owner chain is longer.
const MAX_LEVELS: usize = 1_000;
const MAX_HANDLE_BYTES: usize = 256;

/// The check, in the frame's agent world. The marker comment stays first
/// (tests find the step by it).
const PRESS_CHECK: &str = "/* cmux-press-check */ (handle, point, behavior, selector) => { \
    const agent = globalThis[Symbol.for('cmux.browserRepl.agent')]; \
    if (!agent || agent.document !== document) return 'the frame shows another document'; \
    const hit = agent.hitTarget(handle, point, behavior); \
    if (hit !== 'error:notconnected' || typeof selector !== 'string') return hit; \
    const ids = agent.queryAll(selector, undefined, 2); \
    return Array.isArray(ids) && ids.length === 1 && agent.hitTarget(ids[0], point, behavior) === 'done' ? 'done' : hit; }";

/// One frame's part of a press.
struct Level {
    frame_id: Option<String>,
    /// The target level's locator selector (re-render rule above).
    selector: Option<String>,
    handle: String,
    /// The point as the caller gave it (`{x, y}`, finite numbers).
    point: Value,
}

fn invalid(message: &str) -> DriverError {
    DriverError::invalid(format!("input.mouse: {message}"))
}

fn refused(why: &str) -> DriverError {
    DriverError::new(
        ErrorCode::Stale,
        format!(
            "no press was sent: {why} when the press was about to be sent (the page changed under the pointer)"
        ),
    )
}

fn level(value: &Value) -> Result<Level, DriverError> {
    let Some(object) = value.as_object() else {
        return Err(invalid("expect and each of expect.owners must be an object"));
    };
    let frame_id = match object.get("frameId") {
        None | Some(Value::Null) => None,
        Some(Value::String(id)) if id.is_empty() => None,
        Some(Value::String(id)) => Some(id.clone()),
        Some(_) => return Err(invalid("expect.frameId must be a string")),
    };
    let handle = object
        .get("handle")
        .and_then(Value::as_str)
        .filter(|h| !h.is_empty() && h.len() <= MAX_HANDLE_BYTES)
        .ok_or_else(|| invalid("expect.handle must be an element handle"))?
        .to_owned();
    let coordinate =
        |name: &str| object.get(name).and_then(Value::as_f64).filter(|n| n.is_finite());
    let (Some(_), Some(_)) = (coordinate("x"), coordinate("y")) else {
        return Err(invalid("expect.x and expect.y must be finite numbers"));
    };
    let selector = match object.get("selector") {
        None | Some(Value::Null) => None,
        Some(Value::String(text)) if text.len() <= 64 * 1024 => Some(text.clone()),
        Some(_) => return Err(invalid("expect.selector must be a selector string")),
    };
    Ok(Level { frame_id, selector, handle, point: json!({"x": object["x"], "y": object["y"]}) })
}

/// The levels of `expect`, the target first.
fn levels(expect: &Value) -> Result<Vec<Level>, DriverError> {
    let mut levels = vec![level(expect)?];
    match expect.get("owners") {
        None | Some(Value::Null) => {}
        Some(Value::Array(owners)) if owners.len() < MAX_LEVELS => {
            for owner in owners {
                levels.push(level(owner)?);
            }
        }
        Some(Value::Array(_)) => {
            return Err(invalid("expect.owners names more frames than a tab holds"));
        }
        Some(_) => return Err(invalid("expect.owners must be an array")),
    }
    Ok(levels)
}

impl Gate {
    /// Takes `expect` out of an `input.mouse` call and, for a press, checks
    /// each level right before the press goes to the engine.
    pub(super) fn check_press(&self, params: &mut Value) -> Result<(), DriverError> {
        let Some(expect) = params.as_object_mut().and_then(|p| p.remove("expect")) else {
            return Ok(());
        };
        if expect.is_null() || params.get("type").and_then(Value::as_str) != Some("down") {
            return Ok(());
        }
        let target = params.get("targetId").cloned().unwrap_or(Value::Null);
        for (i, level) in levels(&expect)?.iter().enumerate() {
            // The target retargets as a click does (a label's control, a
            // button's descendant); an owner level is the <iframe> itself.
            let behavior = if i == 0 { "button-link" } else { "none" };
            let mut call = json!({
                "targetId": target,
                "world": "agent",
                "source": PRESS_CHECK,
                "args": [level.handle, level.point, behavior, if i == 0 { json!(level.selector) } else { Value::Null }],
            });
            if let Some(frame) = &level.frame_id {
                call.set("frameId", json!(frame));
            }
            let hit = match self.driver.call("frame.evaluate", &call) {
                Ok(hit) => hit,
                Err(error) if matches!(error.code, ErrorCode::Stale | ErrorCode::NotFound) => {
                    return Err(refused(&error.message));
                }
                Err(error) => return Err(error),
            };
            match hit.as_str() {
                Some("done") => {}
                Some(why @ "the frame shows another document") => return Err(refused(why)),
                Some("error:notconnected") => {
                    return Err(refused(if i == 0 {
                        "the target was detached from the DOM"
                    } else {
                        "a frame's <iframe> was detached from the DOM"
                    }));
                }
                Some(other) => return Err(refused(&format!("{other} intercepts pointer events"))),
                None => return Err(refused("the frame did not answer the check")),
            }
        }
        Ok(())
    }
}
