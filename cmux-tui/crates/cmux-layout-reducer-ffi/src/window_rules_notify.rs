//! The notification posting rules' ops: what a banner says
//! (`window_notifications_banner`, `_plain_text`), which OSC 7501 record a
//! terminal notification was posted for (`_program_alert`,
//! `_looks_like_alert`, `_alert_notifies`), which `cmux status run`s finished
//! and whether they notify (`_status_runs`, `_run_notifies`), and the
//! notifications panel's selection (`_panel_move`, `_panel_reconcile`).

use cmux_window_rules::{banner, notifications_panel, status_alerts};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::ERR_INVALID;

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

fn value<T: serde::Serialize>(answer: T) -> Result<Value, i32> {
    serde_json::to_value(answer).map_err(|_| ERR_INVALID)
}

/// The ops this module answers (exact names: the other `window_notifications_*` ops are misc's).
const OPS: [&[u8]; 9] = [
    b"window_notifications_banner",
    b"window_notifications_plain_text",
    b"window_notifications_program_alert",
    b"window_notifications_looks_like_alert",
    b"window_notifications_alert_notifies",
    b"window_notifications_status_runs",
    b"window_notifications_run_notifies",
    b"window_notifications_panel_move",
    b"window_notifications_panel_reconcile",
];

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    OPS.contains(&operation)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Markdown {
    markdown: String,
    #[serde(default = "body_limit")]
    max_body_characters: usize,
}

fn body_limit() -> usize {
    banner::MAX_BODY_CHARACTERS
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Posted {
    title: String,
    #[serde(default)]
    body: String,
    level: status_alerts::Level,
    #[serde(default)]
    records: Vec<status_alerts::Record>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Titled {
    title: String,
    level: status_alerts::Level,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Alerted {
    reason: status_alerts::Reason,
    #[serde(default)]
    visibility: status_alerts::Visibility,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Looked {
    #[serde(default)]
    running: Vec<status_alerts::Run>,
    #[serde(default)]
    statuses: Vec<status_alerts::WorkspaceStatus>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Finished {
    duration_ms: Option<u64>,
    #[serde(default)]
    behavior: status_alerts::RunBehavior,
    #[serde(default)]
    visibility: status_alerts::Visibility,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Moved {
    selected: Option<String>,
    offset: i64,
    #[serde(default)]
    rows: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Reloaded {
    selected: Option<String>,
    #[serde(default)]
    old: Vec<String>,
    #[serde(default)]
    new: Vec<String>,
}

pub(crate) fn respond_notify(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer = match operation {
        // The banner's title, subtitle and body.
        b"window_notifications_banner" => value(banner::content(&read(request)?))?,
        b"window_notifications_plain_text" => {
            let request: Markdown = read(request)?;
            json!({ "text": banner::plain_text(&request.markdown, request.max_body_characters) })
        }
        // The OSC 7501 record a terminal notification was posted for; `alert` null: none.
        b"window_notifications_program_alert" => {
            let request: Posted = read(request)?;
            json!({ "alert": status_alerts::alert(&request.title, &request.body, request.level, &request.records) })
        }
        b"window_notifications_looks_like_alert" => {
            let request: Titled = read(request)?;
            json!({ "looksLikeAlert": status_alerts::looks_like_alert(&request.title, request.level) })
        }
        b"window_notifications_alert_notifies" => {
            let request: Alerted = read(request)?;
            json!({ "notifies": status_alerts::alert_notifies(request.reason, request.visibility) })
        }
        // The runs that finished since the last look, and the busy ones for the next.
        b"window_notifications_status_runs" => {
            let request: Looked = read(request)?;
            value(status_alerts::update_runs(&request.running, &request.statuses))?
        }
        b"window_notifications_run_notifies" => {
            let request: Finished = read(request)?;
            json!({ "notifies": status_alerts::run_notifies(request.duration_ms, request.behavior, request.visibility) })
        }
        b"window_notifications_panel_move" => {
            let request: Moved = read(request)?;
            json!({ "selected": notifications_panel::move_selection(request.selected.as_deref(), request.offset, &request.rows) })
        }
        b"window_notifications_panel_reconcile" => {
            let request: Reloaded = read(request)?;
            json!({ "selected": notifications_panel::reconcile_selection(request.selected.as_deref(), &request.old, &request.new) })
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
