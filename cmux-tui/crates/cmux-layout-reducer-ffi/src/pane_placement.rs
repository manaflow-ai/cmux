//! `cmux-window-rules`' right column rule and subagent pane tracker over the
//! JSON channel: `right_column_decide` (where an open on the right of a pane
//! goes), `right_column_beside` (the column right of a pane, from its frames)
//! and `subagent_panes_step` (one step of a chat's subagent pane tracker,
//! whose state the app holds between calls).

use std::collections::BTreeMap;

use cmux_window_rules::right_column::{self, Column, Kind, Rect};
use cmux_window_rules::subagent_panes::{Effects, Panes};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"right_column_") || operation == b"subagent_panes_step"
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

#[derive(Deserialize)]
struct Decide {
    #[serde(default)]
    column: Column,
    #[serde(default)]
    opening: Option<Kind>,
}

#[derive(Deserialize)]
struct Beside {
    source: String,
    #[serde(default)]
    frames: BTreeMap<String, Rect>,
    #[serde(default)]
    gap: Option<f64>,
}

/// One event for the tracker.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
enum Event {
    Open {
        agent: String,
        focus: bool,
        #[serde(default)]
        asked: Option<bool>,
        chat: String,
        now: i64,
    },
    Landed {
        agent: String,
        focus: bool,
        #[serde(rename = "hasTab")]
        has_tab: bool,
        now: i64,
    },
    Begin {
        agent: String,
        focus: bool,
        #[serde(default)]
        asked: Option<bool>,
        chat: String,
        now: i64,
    },
    Finish {
        now: i64,
    },
    OwesFocus {
        agent: String,
        now: i64,
    },
    UserActed,
    Record {
        agent: String,
    },
}

#[derive(Deserialize)]
struct Step {
    #[serde(default)]
    state: Panes,
    event: Event,
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer = match operation {
        b"right_column_decide" => {
            let Decide { column, opening } = read(request)?;
            json!({ "decision": right_column::decide(&column, opening) })
        }
        b"right_column_beside" => {
            let Beside { source, frames, gap } = read(request)?;
            json!({ "panes": right_column::beside(&source, &frames, gap.unwrap_or(right_column::GAP)) })
        }
        b"subagent_panes_step" => {
            let Step { mut state, event } = read(request)?;
            let mut effects = Effects::default();
            let answer: Value = match event {
                Event::Open { agent, focus, asked, chat, now } => {
                    json!(state.open(&agent, focus, asked, &chat, now, &mut effects))
                }
                Event::Landed { agent, focus, has_tab, now } => {
                    json!(state.landed(&agent, focus, has_tab, now, &mut effects))
                }
                Event::Begin { agent, focus, asked, chat, now } => {
                    json!(state.begin(&agent, focus, asked, &chat, now))
                }
                Event::Finish { now } => {
                    effects.again = state.finish(now, &mut effects);
                    Value::Null
                }
                Event::OwesFocus { agent, now } => json!(state.owes_focus(&agent, now)),
                Event::UserActed => {
                    state.user_acted(&mut effects);
                    Value::Null
                }
                Event::Record { agent } => {
                    state.record(&agent);
                    Value::Null
                }
            };
            json!({
                "state": state,
                "answer": answer,
                "again": effects.again,
                "watch": effects.watch,
                "stopWatching": effects.stop_watching,
            })
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
