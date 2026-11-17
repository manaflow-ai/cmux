//! `floating-panes-v1`: the `float-pane` command and the `Screen.floating`
//! read shape (screen_json.rs).
//!
//! A floating pane stays a leaf of `Screen.layout`; `Screen.floating` names
//! the leaves the tiled layout leaves out, back to front, each with its frame
//! as four fractions of the screen's pane area. A client without the
//! capability ignores the list and shows every pane tiled.

use cmux_layout_reducer::floating_panes::{FloatFrame, FloatMode, Floating};

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
    let frame = match (x, y, w, h) {
        (None, None, None, None) => None,
        (Some(x), Some(y), Some(w), Some(h)) => {
            Some(FloatFrame::from_fractions(x, y, w, h).ok_or_else(|| {
                FloatPaneError::InvalidArgument {
                    field: "frame",
                    value: format!("{x}, {y}, {w}, {h}"),
                }
            })?)
        }
        _ => {
            return Err(FloatPaneError::InvalidArgument {
                field: "frame",
                value: format!("{x:?}, {y:?}, {w:?}, {h:?}"),
            }
            .into());
        }
    };
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

#[cfg(test)]
#[path = "floating_panes_tests.rs"]
mod tests;

/// Wire tests for the quick terminal (`quick-terminal-v1`): its mark rides on the floating list.
#[cfg(test)]
#[path = "quick_terminal_tests.rs"]
mod quick_terminal_tests;
