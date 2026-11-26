//! The focus UI's input holds over the JSON channel (cmux_focus_core::ui):
//!
//! - `focus_ui_type_ahead_tail`: `{tail?, op}` → `{tail, surface?, isEmpty,
//!   reply?}`.
//! - `focus_ui_creation_claims`: `{claims?, op}` → `{claims, isEmpty, ended,
//!   reply?}`; `ended` lists the claims that ended after keeping keys (the
//!   app logs them).
//! - `focus_ui_decided_keys`: `{decided?, op}` → `{decided, reply?}`; the app
//!   matches an event by identity itself.
//!
//! Each state (`tail`, `claims`, `decided`) is the value the last answer
//! gave; absent, a new one.

use crate::ERR_INVALID;
use cmux_focus_core::ui::creation_claims::CreationKeyboardClaims;
use cmux_focus_core::ui::decided_keys::{DecidedKeys, KeySignature};
use cmux_focus_core::ui::type_ahead_tail::TypeAheadTail;
use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TailRequest {
    #[serde(default)]
    tail: Option<TypeAheadTail>,
    op: TailOp,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
enum TailOp {
    Holds {
        surface: String,
    },
    Count {
        surface: String,
    },
    #[serde(rename_all = "camelCase")]
    Takes {
        key_code: u16,
        #[serde(default)]
        chord: bool,
        surface: String,
        #[serde(default)]
        behind_text: bool,
    },
    Hold {
        key: u64,
        surface: String,
        #[serde(default)]
        delivering: bool,
    },
    TextWasTaken {
        surface: String,
    },
    Settle {
        surface: String,
    },
    Drop,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClaimsRequest {
    #[serde(default)]
    claims: Option<CreationKeyboardClaims>,
    op: ClaimsOp,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
enum ClaimsOp {
    #[serde(rename_all = "camelCase")]
    Claim {
        window: i64,
        ticket: u64,
        #[serde(default)]
        input: Option<f64>,
        intents: u64,
    },
    #[serde(rename_all = "camelCase")]
    Made {
        workspace: String,
        ticket: u64,
        window: i64,
    },
    #[serde(rename_all = "camelCase")]
    PersonActed {
        window: i64,
        #[serde(default)]
        input: Option<f64>,
    },
    End {
        window: i64,
    },
    #[serde(rename_all = "camelCase")]
    Holds {
        window: i64,
        same_window: bool,
        #[serde(default)]
        shown: Option<String>,
        intents: u64,
        #[serde(default)]
        last_input: Option<f64>,
    },
    #[serde(rename_all = "camelCase")]
    Keeps {
        window: i64,
        key_code: u16,
        #[serde(default)]
        chord_pending: bool,
        #[serde(default)]
        runs_binding: bool,
    },
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DecidedRequest {
    #[serde(default)]
    decided: Option<DecidedKeys>,
    op: DecidedOp,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
enum DecidedOp {
    Add { key: KeySignature },
    Contains { key: KeySignature },
}

fn parse<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

fn reply(value: Value) -> Result<Vec<u8>, i32> {
    serde_json::to_vec(&value).map_err(|_| ERR_INVALID)
}

/// The answer to one of this file's ops, or None when `operation` is not one.
pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Option<Result<Vec<u8>, i32>> {
    Some(match operation {
        b"focus_ui_type_ahead_tail" => type_ahead_tail(request),
        b"focus_ui_creation_claims" => creation_claims(request),
        b"focus_ui_decided_keys" => decided_keys(request),
        _ => return None,
    })
}

fn type_ahead_tail(request: &[u8]) -> Result<Vec<u8>, i32> {
    let TailRequest { tail, op } = parse(request)?;
    let mut tail = tail.unwrap_or_default();
    let answer = match op {
        TailOp::Holds { surface } => json!(tail.holds(&surface)),
        TailOp::Count { surface } => json!(tail.count(&surface)),
        TailOp::Takes { key_code, chord, surface, behind_text } => {
            json!(tail.takes(key_code, chord, &surface, behind_text))
        }
        TailOp::Hold { key, surface, delivering } => {
            tail.hold(key, &surface, delivering);
            Value::Null
        }
        TailOp::TextWasTaken { surface } => {
            tail.text_was_taken(&surface);
            Value::Null
        }
        TailOp::Settle { surface } => json!(tail.settle(&surface)),
        TailOp::Drop => {
            tail.drop_all();
            Value::Null
        }
    };
    let mut out = json!({ "tail": tail, "isEmpty": tail.is_empty() });
    if let Some(surface) = tail.surface() {
        out["surface"] = json!(surface);
    }
    if !answer.is_null() {
        out["reply"] = answer;
    }
    reply(out)
}

fn creation_claims(request: &[u8]) -> Result<Vec<u8>, i32> {
    let ClaimsRequest { claims, op } = parse(request)?;
    let mut claims = claims.unwrap_or_default();
    let answer = match op {
        ClaimsOp::Claim { window, ticket, input, intents } => {
            claims.claim(window, ticket, input, intents);
            Value::Null
        }
        ClaimsOp::Made { workspace, ticket, window } => {
            claims.made(&workspace, ticket, window);
            Value::Null
        }
        ClaimsOp::PersonActed { window, input } => json!(claims.person_acted(window, input)),
        ClaimsOp::End { window } => {
            claims.end(window);
            Value::Null
        }
        ClaimsOp::Holds { window, same_window, shown, intents, last_input } => {
            json!(claims.holds(window, same_window, shown.as_deref(), intents, last_input))
        }
        // An Escape answers null: it ends the claim and goes on.
        ClaimsOp::Keeps { window, key_code, chord_pending, runs_binding } => {
            json!({ "keeps": claims.keeps(window, key_code, chord_pending, runs_binding) })
        }
    };
    let ended = claims.take_ended();
    let mut out = json!({ "claims": claims, "isEmpty": claims.is_empty(), "ended": ended });
    if !answer.is_null() {
        out["reply"] = answer;
    }
    reply(out)
}

fn decided_keys(request: &[u8]) -> Result<Vec<u8>, i32> {
    let DecidedRequest { decided, op } = parse(request)?;
    let mut decided = decided.unwrap_or_default();
    let mut out = json!({});
    match op {
        DecidedOp::Add { key } => decided.add(&key),
        DecidedOp::Contains { key } => out["reply"] = json!(decided.contains(&key)),
    }
    out["decided"] = json!(decided);
    reply(out)
}
