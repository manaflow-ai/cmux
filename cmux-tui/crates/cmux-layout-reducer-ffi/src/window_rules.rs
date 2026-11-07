//! `cmux-window-rules` over the JSON channel (ops `window_*`): the window
//! handlers' rules. The app reads its tab models, settings and the daemon's
//! answers, sends the facts and acts on the answer (the dialog, the toast,
//! the daemon command).

use cmux_window_rules::close::{self, ClosingTab, TerminalAnswer, Warnings};
use serde::Deserialize;
use serde_json::json;

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"window_")
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Closing {
    #[serde(default)]
    tabs: Vec<ClosingTab>,
    #[serde(default, flatten)]
    warnings: Warnings,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Asked {
    #[serde(default)]
    agents: Vec<Option<String>>,
    #[serde(default)]
    answers: Vec<TerminalAnswer>,
    #[serde(default)]
    unanswered_asks: bool,
    #[serde(default, flatten)]
    warnings: Warnings,
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer = match operation {
        // Whether closing these tabs together earns the undo toast.
        b"window_close_toast" => {
            let request: Closing = read(request)?;
            serde_json::to_value(close::toast(&request.tabs)).map_err(|_| ERR_INVALID)?
        }
        // What a close reads before it knows its question; `reads` null: it never asks.
        b"window_close_reads" => {
            let request: Closing = read(request)?;
            json!({ "reads": close::reads(&request.tabs, request.warnings) })
        }
        // The close's question from the terminals' answers; `warning` null: close at once.
        b"window_close_warning" => {
            let request: Asked = read(request)?;
            json!({ "warning": close::warning(&request.agents, &request.answers, request.unanswered_asks, request.warnings) })
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
