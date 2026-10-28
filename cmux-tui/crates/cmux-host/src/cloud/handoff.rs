//! Hand-off reports for the machine's agent sessions (sans I/O): the agent
//! socket line `{"handoff_report": {"session", "turn", "status",
//! "summary"?}}` that acpmux sends when a session's turn changes, the Cloud
//! API request it becomes (`POST /v1/handoffs/<id>/report` as this
//! machine's `vm` install), and the one reply line the agent writes back.
//!
//! The hand-off store (backend/apps/api/src/handoffs) keeps one hand-off per
//! session, named from its owner and session id, so the agent names it the
//! same way from the bound install's user: a session nobody handed off has no
//! hand-off and its report answers 404. The store accepts a VM install bound
//! to the hand-off's machine, so the machine needs no other credential, and
//! the bearer stays in the agent as it does for GitHub tokens (`github.rs`).
//! The reply carries the hand-off's turn, state, status and `statusAt`
//! (never its summary), so acpmux learns the current turn, and when the owner
//! opened it, from a `handoff.stale` refusal.

use crate::json::JsonField;
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

use super::sender::Answer;

/// The socket line's key.
pub const REQUEST_KEY: &str = "handoff_report";

/// What a machine may report (the store's `MACHINE_STATUSES`).
pub const STATUSES: [&str; 4] = ["running", "needs-you", "done", "failed"];

/// The store's `SUMMARY_MAX_CHARS`, counted as JavaScript does (UTF-16 units).
pub const SUMMARY_MAX: usize = 2_000;

/// One checked report.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HandoffReport {
    pub session: String,
    pub turn: u64,
    pub status: String,
    pub summary: Option<String>,
}

/// The store's session id shape: `[A-Za-z0-9_.:-]{1,128}`.
pub fn valid_session(session: &str) -> bool {
    !session.is_empty()
        && session.len() <= 128
        && session.bytes().all(|b| b.is_ascii_alphanumeric() || b"_.:-".contains(&b))
}

/// The hand-off of `owner`'s `session`: `ho_` and the first 20 hex digits of
/// sha256(owner NUL session), as the store names it at create.
pub fn handoff_id(owner: &str, session: &str) -> String {
    let digest = Sha256::digest(format!("{owner}\u{0}{session}").as_bytes());
    let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
    format!("ho_{}", hex.get(..20).unwrap_or_default())
}

/// The report route of hand-off `id`.
pub fn report_path(id: &str) -> String {
    format!("/v1/handoffs/{id}/report")
}

impl HandoffReport {
    /// The `handoff_report` object of a socket line, refused unless every
    /// field has the store's shape (the API checks again).
    pub fn from_json(v: &Value) -> Result<HandoffReport, String> {
        let session = v.field("session").as_str().unwrap_or("");
        if !valid_session(session) {
            return Err("session must be 1-128 of [A-Za-z0-9_.:-]".to_owned());
        }
        // The store's bounds (routes.ts `turnNumber`): a safe integer, from 1.
        let Some(turn) = v.field("turn").as_u64().filter(|t| *t >= 1 && *t < (1 << 53)) else {
            return Err("turn must be a whole number from 1".to_owned());
        };
        let status = v.field("status").as_str().unwrap_or("");
        if !STATUSES.contains(&status) {
            return Err("status must be running, needs-you, done or failed".to_owned());
        }
        // A missing or null summary is no summary, as the store reads it (routes.ts `text`).
        let summary = match v.field("summary") {
            Value::Null => None,
            Value::String(s) if s.encode_utf16().count() <= SUMMARY_MAX => Some(s.clone()),
            _ => return Err(format!("summary must be text of at most {SUMMARY_MAX} characters")),
        };
        Ok(HandoffReport { session: session.to_owned(), turn, status: status.to_owned(), summary })
    }

    /// The socket line a client sends.
    pub fn to_line(&self) -> String {
        let mut fields = Map::new();
        fields.insert("session".to_owned(), json!(self.session));
        fields.insert("turn".to_owned(), json!(self.turn));
        fields.insert("status".to_owned(), json!(self.status));
        if let Some(summary) = &self.summary {
            fields.insert("summary".to_owned(), json!(summary));
        }
        json!({ REQUEST_KEY: Value::Object(fields) }).to_string()
    }

    /// The API request body: `{turn, status, summary?}`.
    pub fn api_body(&self) -> Value {
        let mut out = Map::new();
        out.insert("turn".to_owned(), json!(self.turn));
        out.insert("status".to_owned(), json!(self.status));
        if let Some(summary) = &self.summary {
            out.insert("summary".to_owned(), json!(summary));
        }
        Value::Object(out)
    }
}

/// The hand-off fields a reply carries: who it is and where its turn is (its status and when
/// that status was set: for a turn not begun, when the owner opened it).
fn brief(handoff: &Value) -> Option<Value> {
    let id = handoff.field("id").as_str()?;
    let turn = handoff.field("turn").as_u64()?;
    let state = handoff.field("state").as_str()?;
    let status = handoff.field("status").as_str()?;
    let mut out = json!({ "id": id, "turn": turn, "state": state, "status": status });
    if let Some(at) = handoff.field("statusAt").as_str().filter(|at| at.chars().count() <= 40) {
        out["statusAt"] = json!(at);
    }
    Some(out)
}

/// A refusal reply (`ok: false`) with an error code and message.
pub fn refusal(code: &str, message: &str) -> Value {
    json!({ "ok": false, "error": { "code": code, "message": message } })
}

/// The reply line for the API's answer: the hand-off's turn and state, or
/// the API's error (code, message, HTTP status) with the hand-off when the
/// store sent it (`handoff.stale` names the current turn).
pub fn reply_for(answer: &Answer) -> Value {
    match answer {
        Answer::Http { status: 200, body } => match brief(body.field("handoff")) {
            Some(handoff) => json!({ "ok": true, "handoff": handoff }),
            None => refusal("handoff.bad_answer", "the API's answer lacks the hand-off"),
        },
        Answer::Http { status, body } => {
            let error = body.field("error");
            let code = error
                .field("code")
                .as_str()
                .map_or_else(|| format!("http.{status}"), str::to_owned);
            let message: String =
                error.field("message").as_str().unwrap_or("").chars().take(300).collect();
            let mut out = Map::new();
            out.insert("ok".to_owned(), json!(false));
            out.insert("status".to_owned(), json!(status));
            out.insert("error".to_owned(), json!({ "code": code, "message": message }));
            if let Some(handoff) = brief(body.field("handoff")) {
                out.insert("handoff".to_owned(), handoff);
            }
            Value::Object(out)
        }
        Answer::Transport => refusal("handoff.unreachable", "the cmux Cloud API did not answer"),
    }
}

/// A journal line for one answer: the hand-off, turn, status and outcome
/// (never the summary).
pub fn note_for(id: &str, report: &HandoffReport, reply: &Value) -> String {
    let outcome = if *reply.field("ok") == true {
        "accepted".to_owned()
    } else {
        format!("refused {}", reply.field("error").field("code").as_str().unwrap_or("?"))
    };
    format!("handoff {id} turn {} {}: {outcome}", report.turn, report.status)
}
