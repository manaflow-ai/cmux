//! `cmux-window-rules` `handlers_close` over the JSON channel (ops `handlers_close_*`): the
//! close handlers' decisions (Handlers/ TabCloseGuard, TabLifecycle, CloseUndoToasts, the
//! workspace closes, DestructiveConfirmation, DaemonClosedHistory, TabRestart, HistoryHandlers).
//! The app sends the facts it read and acts on the answer: the dialog, the toast, the daemon
//! request.

use cmux_window_rules::close::Warning;
use cmux_window_rules::handlers_close::{
    self as rules, BulkRunFacts, ChatTabFacts, ItemKind, LeavingPart, LinkTarget, Lookup,
    PressEvent, ReopenAnswer,
};
use serde::Deserialize;
use serde_json::json;

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"handlers_close_")
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

/// A close's warning as the app sends it (the rules' `Warning` only serializes).
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
enum WarningRequest {
    Agent {
        #[serde(default)]
        name: Option<String>,
    },
    Programs {
        #[serde(default)]
        programs: Vec<String>,
        #[serde(default)]
        unanswered: Vec<String>,
    },
}

impl From<WarningRequest> for Warning {
    fn from(warning: WarningRequest) -> Self {
        match warning {
            WarningRequest::Agent { name } => Warning::Agent { name },
            WarningRequest::Programs { programs, unanswered } => {
                Warning::Programs { programs, unanswered }
            }
        }
    }
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct Code {
    code: Option<String>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct Kind {
    kind: ItemKind,
    grouped: bool,
    code: Option<String>,
    tab_in_pane: bool,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct Undo {
    user: bool,
    names: usize,
    survivor: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Id {
    id: String,
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer = match operation {
        // TabCloseGuard: whether a person's close hides its tabs while the daemon is read.
        b"handlers_close_hides" => {
            #[derive(Deserialize, Default)]
            #[serde(rename_all = "camelCase", default)]
            struct Request {
                parts: Vec<LeavingPart>,
                known_to_ask: bool,
            }
            let request: Request = read(request)?;
            json!({ "hides": rules::hides(&request.parts, request.known_to_ask) })
        }
        b"handlers_close_press" => {
            #[derive(Deserialize, Default)]
            #[serde(rename_all = "camelCase", default)]
            struct Request {
                event: PressEvent,
                is_repeat: bool,
            }
            let request: Request = read(request)?;
            json!(rules::press(request.event, request.is_repeat))
        }
        b"handlers_close_tab_prompt" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                warning: WarningRequest,
                #[serde(default)]
                titles: Vec<String>,
            }
            let request: Request = read(request)?;
            json!(rules::tab_close_prompt(&request.warning.into(), &request.titles))
        }
        // TabLifecycle.
        b"handlers_close_chat_route" => {
            let facts: ChatTabFacts = read(request)?;
            json!(rules::chat_tab_route(facts))
        }
        b"handlers_close_reopen_step" => {
            let answer: ReopenAnswer = read(request)?;
            json!(rules::reopen_step(&answer))
        }
        b"handlers_close_link_open" => {
            #[derive(Deserialize)]
            struct Request {
                target: LinkTarget,
            }
            let request: Request = read(request)?;
            json!(rules::link_open(request.target))
        }
        // TabRestart.
        b"handlers_close_restart_step" => {
            #[derive(Deserialize, Default)]
            #[serde(rename_all = "camelCase", default)]
            struct Request {
                refusal: Option<String>,
                answered: bool,
            }
            let request: Request = read(request)?;
            json!(rules::restart_step(request.refusal.as_deref(), request.answered))
        }
        // HistoryHandlers.
        b"handlers_close_history_opening" => {
            #[derive(Deserialize, Default)]
            #[serde(rename_all = "camelCase", default)]
            struct Request {
                lookup: Lookup,
                available: bool,
            }
            let request: Request = read(request)?;
            json!(rules::history_opening(request.lookup, request.available))
        }
        // CloseUndoToasts.
        b"handlers_close_recent_overflow" => {
            #[derive(Deserialize)]
            struct Request {
                count: usize,
            }
            let request: Request = read(request)?;
            json!({ "drop": rules::recent_overflow(request.count) })
        }
        b"handlers_close_toast_message" => {
            #[derive(Deserialize, Default)]
            #[serde(rename_all = "camelCase", default)]
            struct Request {
                tabs: usize,
                title: String,
            }
            let request: Request = read(request)?;
            json!(rules::toast_message(request.tabs, &request.title))
        }
        b"handlers_close_one_group" => {
            #[derive(Deserialize)]
            struct Request {
                daemons: Vec<usize>,
            }
            let request: Request = read(request)?;
            json!({ "oneGroup": rules::one_group(&request.daemons) })
        }
        // The workspace closes.
        b"handlers_close_bulk_run" => {
            let facts: BulkRunFacts = read(request)?;
            json!(rules::bulk_run(facts))
        }
        b"handlers_close_group_offers_undo" => {
            let undo: Undo = read(request)?;
            json!({ "offers": rules::group_close_offers_undo(undo.user, undo.names, undo.survivor) })
        }
        b"handlers_close_selection_offers_undo" => {
            let undo: Undo = read(request)?;
            json!({ "offers": rules::selection_offers_undo(undo.names, undo.survivor) })
        }
        // DestructiveConfirmation: the fixed question of an action id, and whether Return confirms.
        b"handlers_close_fixed_prompt" => {
            let request: Id = read(request)?;
            match rules::fixed_prompt(&request.id) {
                Some(prompt) => json!({
                    "prompt": prompt,
                    "returnConfirms": rules::fixed_returns_confirm(prompt),
                }),
                None => json!({ "prompt": null }),
            }
        }
        // DaemonClosedHistory.
        b"handlers_close_history_id" => {
            let request: Id = read(request)?;
            json!({ "historyId": rules::history_id(&request.id) })
        }
        b"handlers_close_daemon_id" => {
            let request: Id = read(request)?;
            json!({ "daemonId": rules::daemon_id(&request.id) })
        }
        b"handlers_close_record_window" => {
            #[derive(Deserialize)]
            struct Request {
                record: String,
            }
            let request: Request = read(request)?;
            json!({ "window": rules::record_window(&request.record) })
        }
        b"handlers_close_since_ms" => {
            #[derive(Deserialize)]
            struct Request {
                seconds: f64,
            }
            let request: Request = read(request)?;
            json!({ "sinceMs": rules::since_ms(request.seconds) })
        }
        b"handlers_close_clears" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                closed_at_ms: u64,
                #[serde(default)]
                since_ms: Option<u64>,
            }
            let request: Request = read(request)?;
            json!({ "clears": rules::clears(request.closed_at_ms, request.since_ms) })
        }
        b"handlers_close_reopen_failure" => {
            let facts: Kind = read(request)?;
            json!(rules::reopen_failure(facts.kind, facts.grouped, facts.code.as_deref()))
        }
        b"handlers_close_delete_done" => {
            let request: Code = read(request)?;
            json!({ "done": rules::delete_done(request.code.as_deref()) })
        }
        b"handlers_close_reopen_show" => {
            let facts: Kind = read(request)?;
            json!(rules::reopen_show(facts.kind, facts.grouped, facts.tab_in_pane))
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
