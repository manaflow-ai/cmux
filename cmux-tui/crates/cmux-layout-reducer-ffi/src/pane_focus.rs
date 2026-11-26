//! `cmux-layout-reducer`'s focus-key rule over the JSON channel (op
//! `layout_pane_neighbor`): the pane a focus key moves to. The app sends one
//! row per pane of the screen (its frame, its column, its place in the focus
//! history, its id's place among the ids) and gets back the row the key gives.

use cmux_layout_reducer::pane_focus::{self, FocusDirection, FocusFrame, FocusPane};
use serde::Deserialize;
use serde_json::json;

use crate::ERR_INVALID;

/// Whether `operation` is this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation == b"layout_pane_neighbor"
}

#[derive(Deserialize)]
struct Frame {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Pane {
    #[serde(default)]
    frame: Option<Frame>,
    #[serde(default)]
    column: Option<u32>,
    #[serde(default)]
    recency: Option<u32>,
    #[serde(default)]
    floating: Option<u32>,
    order: u32,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
enum Direction {
    Left,
    Right,
    Up,
    Down,
}

#[derive(Deserialize)]
struct Request {
    panes: Vec<Pane>,
    source: usize,
    direction: Direction,
}

pub(crate) fn respond(request: &[u8]) -> Result<Vec<u8>, i32> {
    let request: Request = serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
    let panes: Vec<FocusPane> = request
        .panes
        .iter()
        .map(|pane| FocusPane {
            frame: pane.frame.as_ref().map(|frame| FocusFrame {
                x: frame.x,
                y: frame.y,
                w: frame.w,
                h: frame.h,
            }),
            column: pane.column,
            recency: pane.recency,
            floating: pane.floating,
            order: pane.order,
        })
        .collect();
    let direction = match request.direction {
        Direction::Left => FocusDirection::Left,
        Direction::Right => FocusDirection::Right,
        Direction::Up => FocusDirection::Up,
        Direction::Down => FocusDirection::Down,
    };
    let index = pane_focus::neighbor(&panes, request.source, direction);
    serde_json::to_vec(&json!({ "index": index })).map_err(|_| ERR_INVALID)
}
