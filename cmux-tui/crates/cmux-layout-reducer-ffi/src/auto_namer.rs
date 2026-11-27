//! `cmux-window-rules`' workspace auto-naming bookkeeping over the JSON
//! channel: `auto_namer_step` (one call into `WorkspaceAutoNamer`'s state,
//! which the app holds between calls) and `auto_name_hold_step` (the same for
//! `WorkspaceAutoNameHold`).

use cmux_window_rules::auto_namer::{Hold, Namer, Rename, Slot, Target};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    matches!(operation, b"auto_namer_step" | b"auto_name_hold_step")
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

/// One call into the namer.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
enum NamerEvent {
    List {
        slots: Vec<Slot>,
    },
    Plan {
        target: Target,
        #[serde(default)]
        candidate: Option<Rename>,
    },
    Apply {
        candidate: Rename,
        #[serde(default)]
        current: Option<Rename>,
    },
    MaySend {
        slot: Slot,
        attempt: u64,
        #[serde(default)]
        current: Option<Rename>,
    },
    Release {
        slot: Slot,
        attempt: u64,
    },
}

/// One call into the hold.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
enum HoldEvent {
    Settle {
        workspace: String,
        namer: String,
        #[serde(default)]
        label: Option<String>,
    },
    LauncherNamed {
        workspace: String,
        name: String,
        session: String,
        matches: bool,
    },
    Forget {
        workspace: String,
    },
}

#[derive(Deserialize)]
struct Step<S, E> {
    #[serde(default)]
    state: S,
    event: E,
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer = match operation {
        b"auto_namer_step" => {
            let Step { mut state, event }: Step<Namer, NamerEvent> = read(request)?;
            let answer: Value = match event {
                NamerEvent::List { slots } => {
                    state.list(&slots);
                    Value::Null
                }
                NamerEvent::Plan { target, candidate } => json!(state.plan(&target, candidate)),
                NamerEvent::Apply { candidate, current } => {
                    json!(state.apply(&candidate, current.as_ref()))
                }
                NamerEvent::MaySend { slot, attempt, current } => {
                    json!(state.may_send(&slot, attempt, current.as_ref()))
                }
                NamerEvent::Release { slot, attempt } => {
                    state.release(&slot, attempt);
                    Value::Null
                }
            };
            json!({ "state": state, "answer": answer })
        }
        b"auto_name_hold_step" => {
            let Step { mut state, event }: Step<Hold, HoldEvent> = read(request)?;
            let answer: Value = match event {
                HoldEvent::Settle { workspace, namer, label } => {
                    json!(state.settle(&workspace, &namer, label.as_deref()))
                }
                HoldEvent::LauncherNamed { workspace, name, session, matches } => {
                    json!(state.launcher_named(&workspace, &name, &session, matches))
                }
                HoldEvent::Forget { workspace } => {
                    state.forget(&workspace);
                    Value::Null
                }
            };
            json!({ "state": state, "answer": answer })
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
