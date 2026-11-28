//! `cmux-window-rules`' empty workspace repair over the JSON channel:
//! `empty_workspace_step` (one call into the reducer whose state the app holds
//! between calls) and `empty_workspace_cause` (why a workspace emptied, from
//! the daemon's terminal registry).

use std::collections::BTreeSet;

use cmux_window_rules::empty_workspace::{self, Cause, Now, Repair, Terminal};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"empty_workspace_")
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

/// One call into the reducer.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
enum Event {
    Membership {
        present: BTreeSet<String>,
    },
    TakeRetries,
    #[serde(rename_all = "camelCase")]
    Examine {
        key: String,
        has_pane: bool,
        #[serde(default)]
        home: bool,
    },
    CauseKnown {
        key: String,
        cause: Cause,
    },
    #[serde(rename_all = "camelCase")]
    CloseFailed {
        key: String,
        #[serde(default)]
        populated_epoch: Option<i64>,
    },
    CreateFailed {
        key: String,
        error: String,
    },
    #[serde(rename_all = "camelCase")]
    Check {
        key: String,
        has_pane: bool,
        #[serde(default)]
        home: bool,
    },
    CreateFirstTab {
        key: String,
    },
    IsSettling {
        key: String,
    },
    Failure {
        key: String,
    },
    BeginClosing {
        key: String,
    },
    EndClosing {
        key: String,
    },
    BeginFill {
        key: String,
    },
    BeginPopulating {
        key: String,
    },
    FinishPopulating {
        key: String,
        succeeded: bool,
        #[serde(default)]
        error: Option<String>,
    },
    KeepAfterFailedClose {
        key: String,
    },
}

#[derive(Deserialize)]
struct Step {
    #[serde(default)]
    state: Repair,
    #[serde(default)]
    now: Now,
    event: Event,
}

#[derive(Deserialize)]
struct CauseRequest {
    #[serde(default)]
    terminals: Vec<Terminal>,
    key: String,
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer = match operation {
        b"empty_workspace_step" => {
            let Step { mut state, now, event } = read(request)?;
            let answer: Value = match event {
                Event::Membership { present } => {
                    state.membership(&present);
                    Value::Null
                }
                Event::TakeRetries => json!(state.take_retries()),
                Event::Examine { key, has_pane, home } => {
                    json!(state.examine(&key, has_pane, home, now))
                }
                Event::CauseKnown { key, cause } => json!(state.cause_known(&key, cause)),
                Event::CloseFailed { key, populated_epoch } => {
                    state.close_failed(&key, populated_epoch, now);
                    Value::Null
                }
                Event::CreateFailed { key, error } => {
                    state.create_failed(&key, &error, now);
                    Value::Null
                }
                Event::Check { key, has_pane, home } => {
                    json!(state.check(&key, has_pane, home, now))
                }
                Event::CreateFirstTab { key } => json!(state.create_first_tab(&key, now)),
                Event::IsSettling { key } => json!(state.is_settling(&key)),
                Event::Failure { key } => json!(state.failure(&key)),
                Event::BeginClosing { key } => {
                    state.begin_closing(&key);
                    Value::Null
                }
                Event::EndClosing { key } => {
                    state.end_closing(&key);
                    Value::Null
                }
                Event::BeginFill { key } => {
                    state.begin_fill(&key);
                    Value::Null
                }
                Event::BeginPopulating { key } => {
                    state.begin_populating(&key);
                    Value::Null
                }
                Event::FinishPopulating { key, succeeded, error } => {
                    state.finish_populating(&key, succeeded, error.as_deref(), now);
                    Value::Null
                }
                Event::KeepAfterFailedClose { key } => {
                    state.keep_after_failed_close(&key);
                    Value::Null
                }
            };
            json!({ "state": state, "answer": answer })
        }
        b"empty_workspace_cause" => {
            let CauseRequest { terminals, key } = read(request)?;
            json!({ "cause": empty_workspace::cause(&terminals, &key) })
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
