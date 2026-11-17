//! `floating-panes-v1`: the `float-pane` command and the `Screen.floating`
//! read shape (screen_json.rs). `quick-terminal-v1`: the `quick-terminal`
//! command and the `Screen.quick_terminal` read shape.
//!
//! A floating pane stays a leaf of `Screen.layout`; `Screen.floating` names
//! the leaves the tiled layout leaves out, back to front, each with its frame
//! as four fractions of the screen's pane area. A client without the
//! capability ignores the list and shows every pane tiled.

use cmux_layout_reducer::floating_panes::{FloatFrame, FloatMode, Floating, Quick, QuickMode};

use super::*;
use crate::FloatPaneError;
use crate::panic_free::JsonFields;

/// `float-pane` and the optional `Screen.floating` field.
pub(super) const FLOATING_PANES_CAPABILITY: &str = "floating-panes-v1";

/// `float-pane`: float `pane` above the tiled layout of its screen, put it
/// back, or give a floating pane a frame. `mode` stays a string so a bad
/// value answers with `error_code:"invalid-argument"` instead of a decode
/// error; no `mode` is `toggle`. `x`, `y`, `w` and `h` are the frame: all four
/// or none.
#[derive(Deserialize)]
pub(super) struct FloatPaneParams {
    pane: PaneId,
    #[serde(default)]
    mode: Option<String>,
    #[serde(default)]
    x: Option<f64>,
    #[serde(default)]
    y: Option<f64>,
    #[serde(default)]
    w: Option<f64>,
    #[serde(default)]
    h: Option<f64>,
    /// Changes with one transaction are one layout-undo entry (a drag).
    #[serde(default)]
    transaction: Option<u64>,
}

pub(super) fn float_pane(
    mux: &Arc<Mux>,
    client: u64,
    actor: crate::Actor,
    params: FloatPaneParams,
) -> anyhow::Result<Value> {
    let FloatPaneParams { pane, mode, x, y, w, h, transaction } = params;
    let mode = match mode.as_deref() {
        None => FloatMode::Toggle,
        Some(name) => FloatMode::parse(name).ok_or_else(|| FloatPaneError::InvalidArgument {
            field: "mode",
            value: name.to_string(),
        })?,
    };
    let frame = requested_frame(x, y, w, h)?;
    let outcome = mux.float_pane_as(
        &actor,
        pane,
        mode,
        frame,
        transaction.map(|transaction| (client, transaction)),
    )?;
    let mut data = json!({
        "screen": outcome.screen,
        "floating": outcome.frame.is_some(),
        "changed": outcome.changed,
    });
    if let Some(frame) = outcome.frame {
        data.insert("frame", frame_json(frame));
    }
    if let Some(transaction) = transaction {
        data.insert("transaction", json!(transaction));
    }
    Ok(data)
}

/// The frame of a request: all four of `x`, `y`, `w` and `h`, or none.
fn requested_frame(
    x: Option<f64>,
    y: Option<f64>,
    w: Option<f64>,
    h: Option<f64>,
) -> Result<Option<FloatFrame>, FloatPaneError> {
    match (x, y, w, h) {
        (None, None, None, None) => Ok(None),
        (Some(x), Some(y), Some(w), Some(h)) => FloatFrame::from_fractions(x, y, w, h)
            .map(Some)
            .ok_or_else(|| FloatPaneError::InvalidArgument {
                field: "frame",
                value: format!("{x}, {y}, {w}, {h}"),
            }),
        _ => Err(FloatPaneError::InvalidArgument {
            field: "frame",
            value: format!("{x:?}, {y:?}, {w:?}, {h:?}"),
        }),
    }
}

/// `quick-terminal` and the optional `Screen.quick_terminal` field.
pub(super) const QUICK_TERMINAL_CAPABILITY: &str = "quick-terminal-v1";

/// `quick-terminal`: make the quick terminal of `screen`, show it with the
/// focus, or hide it. `mode` stays a string so a bad value answers with
/// `error_code:"invalid-argument"` instead of a decode error; no `mode` is
/// `toggle`. `x`, `y`, `w` and `h` are the frame of a quick terminal that
/// the request makes: all four or none.
#[derive(Deserialize)]
pub(super) struct QuickTerminalParams {
    screen: ScreenId,
    #[serde(default)]
    mode: Option<String>,
    #[serde(default)]
    x: Option<f64>,
    #[serde(default)]
    y: Option<f64>,
    #[serde(default)]
    w: Option<f64>,
    #[serde(default)]
    h: Option<f64>,
}

pub(super) fn quick_terminal(
    mux: &Arc<Mux>,
    client: u64,
    actor: crate::Actor,
    params: QuickTerminalParams,
) -> anyhow::Result<Value> {
    let QuickTerminalParams { screen, mode, x, y, w, h } = params;
    let mode = match mode.as_deref() {
        None => QuickMode::Toggle,
        Some(name) => QuickMode::parse(name).ok_or_else(|| FloatPaneError::InvalidArgument {
            field: FloatPaneError::QUICK_MODE_FIELD,
            value: name.to_string(),
        })?,
    };
    let frame = requested_frame(x, y, w, h)?;
    // The terminal of a new quick terminal is the daemon's default one. It
    // starts in the folder of the pane that it splits, by the creation's rule.
    let spawn = placement_spawn_options(None, None, None, None, frontend_shell(mux, client))?;
    let surface = mux.quick_terminal_as(&actor, screen, mode, frame, spawn, None)?;
    // The answer says the state after the act, so it is true when another
    // request changed the screen between the two.
    let (mark, focused) = mux
        .with_state(|state| {
            state
                .workspaces
                .iter()
                .flat_map(|workspace| &workspace.screens)
                .find(|item| item.id == screen)
                .map(|found| (found.quick_terminal(), found.active_pane))
        })
        .ok_or(FloatPaneError::ScreenNotFound { screen })?;
    let mut data = json!({
        "screen": screen,
        "created": surface.is_some(),
        "hidden": mark.is_some_and(|(_, mark)| mark.hidden),
        "focused": focused,
    });
    if let Some((pane, _)) = mark {
        data.insert("pane", json!(pane));
    }
    if let Some(surface) = surface {
        data.insert("surface", json!(surface));
    }
    Ok(data)
}

pub(super) fn error_code(error: &anyhow::Error) -> Option<String> {
    error.downcast_ref::<FloatPaneError>().and_then(|error| error.code()).map(str::to_string)
}

fn frame_json(frame: FloatFrame) -> Value {
    let [x, y, w, h] = frame.fractions();
    json!({"x": x, "y": y, "w": w, "h": h})
}

/// `Screen.floating`: one `{pane, x, y, w, h}` for each floating pane, back to
/// front.
pub(super) fn floating_json(list: &[Floating<PaneId>]) -> Value {
    Value::Array(
        list.iter()
            .map(|entry| {
                let [x, y, w, h] = entry.frame.fractions();
                json!({"pane": entry.pane, "x": x, "y": y, "w": w, "h": h})
            })
            .collect(),
    )
}

/// `Screen.quick_terminal`: the pane of the quick terminal, whether it is
/// hidden, and `from`, the pane that gets the focus back at a hide (null when
/// the mark names none).
pub(super) fn quick_terminal_json(pane: PaneId, mark: Quick<PaneId>) -> Value {
    json!({"pane": pane, "hidden": mark.hidden, "from": mark.from})
}

#[cfg(test)]
#[path = "floating_panes_tests.rs"]
mod tests;

/// Wire tests for the quick terminal (`quick-terminal-v1`): its mark rides on the floating list.
#[cfg(test)]
#[path = "quick_terminal_tests.rs"]
mod quick_terminal_tests;
