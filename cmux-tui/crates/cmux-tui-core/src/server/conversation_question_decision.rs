//! `conversation-question-decision`: what Home's native card has the person sign before it answers
//! a Chief question (`conversation-question-decision-v1`).
//!
//! The daemon reads the stored question and the live acpmux prompt it names, checks they are the
//! same question, and returns the unsigned decision ([`cmux_conversation::question_wire`]): the
//! prompt's run (`personInstance`), its one-use `decisionNonce`, the answer's option and the exact
//! `answers` the daemon will send. The app checks the run, nonce and request digest against its
//! own person-proven read of the same prompt, signs `decision_answers_proof` with the key it keeps
//! in memory, and sends the proof as the `question.answer` op's ephemeral `decision`. Nothing here
//! holds or sees a key, and a result grants nothing: acpmux alone verifies and spends the proof.

use cmux_conversation::question_wire::{self, UnsignedDecision, WireError};
use cmux_conversation::{Part, Question, QuestionAnswer, QuestionState};
use serde::Deserialize;
use serde_json::Value;

use crate::mux::Mux;

/// Advertised only where the daemon reaches acpmux (a Unix socket).
#[cfg(unix)]
pub const CAPABILITY: &str = "conversation-question-decision-v1";

#[derive(Deserialize)]
pub(super) struct DecisionParams {
    conversation: String,
    message_id: String,
    part_index: usize,
    answer: QuestionAnswer,
    /// The question exactly as Home displayed it (the stored `Question` JSON it received). The
    /// person signs for this, not for whatever the daemon reads now: the decision is refused
    /// `question.stale` unless it equals the stored question. Required, except with `native_record`.
    #[serde(default)]
    question: Option<Value>,
    /// `true`: the stored tool-approval card itself ([`record_question`]), for the record the app
    /// sends after it answered acpmux natively. Reads no prompt and builds no decision.
    #[serde(default)]
    native_record: bool,
}

/// A refusal with a stable code (`question.*`), as the reply's error text.
#[derive(Debug)]
pub(in crate::server) struct DecisionRefused(pub &'static str);
impl std::fmt::Display for DecisionRefused {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.0)
    }
}
impl std::error::Error for DecisionRefused {}

fn refused(code: &'static str) -> anyhow::Error {
    DecisionRefused(code).into()
}

/// The refusal's code, for the reply's `code` field (responses.rs).
pub(super) fn error_code(error: &anyhow::Error) -> Option<String> {
    error.downcast_ref::<DecisionRefused>().map(|refused| refused.0.to_owned())
}

impl From<WireError> for DecisionRefused {
    fn from(error: WireError) -> Self {
        Self(error.code())
    }
}

/// The stored question part `message_id`/`part_index` of `conversation`.
fn stored_question(mux: &Mux, params: &DecisionParams) -> anyhow::Result<Question> {
    let message = mux
        .with_conversations(|store| store.message(&params.message_id))?
        .filter(|message| message.conversation == params.conversation)
        .ok_or_else(|| refused("question.not_found"))?;
    match message.parts.get(params.part_index) {
        Some(Part::Question(question)) => Ok(question.clone()),
        _ => Err(refused("question.not_found")),
    }
}

/// The question Home displayed is the stored one: the displayed JSON, parsed as a `Question`,
/// equals `stored`. A missing snapshot (`required`), one that is no question, or one the stored
/// question has moved on from (answered, cancelled, edited) is `question.stale`.
fn check_displayed(
    stored: &Question,
    displayed: Option<&Value>,
    required: bool,
) -> anyhow::Result<()> {
    let Some(displayed) = displayed else {
        return if required { Err(refused("question.stale")) } else { Ok(()) };
    };
    match serde_json::from_value::<Question>(displayed.clone()) {
        Ok(shown) if shown == *stored => Ok(()),
        _ => Err(refused("question.stale")),
    }
}

/// The reply: the unsigned decision, the stored question (equal to the displayed one), and the live request it was read from
/// with its digest (sha256 of its canonical JSON), which the app compares with its own read
/// of the prompt. With the person's proof added, the reply's `question`, `request`, `digest`,
/// `instance`, `option_id` and `decision_nonce` are the `question.answer` op's `decision`.
fn reply(
    question: &Question,
    decision: UnsignedDecision,
    request: &Value,
) -> anyhow::Result<Value> {
    let mut value = serde_json::to_value(decision)?;
    value["question"] = serde_json::to_value(question)?;
    value["request"] = request.clone();
    // The same request as canonical text: the app parses this rather than `request`, so no number
    // passes through a lossy JSON value on the way (an integer past 2^53 stays exact).
    value["request_json"] = Value::String(question_wire::canonical_json(request));
    value["digest"] = Value::String(request_digest(request));
    Ok(value)
}

/// Lowercase hex sha256 of `request`'s canonical JSON ([`question_wire::canonical_json`]), the
/// digest the app computes over its own read of the prompt.
pub(in crate::server) fn request_digest(request: &Value) -> String {
    use sha2::{Digest, Sha256};
    format!("{:x}", Sha256::digest(question_wire::canonical_json(request).as_bytes()))
}

/// `{question}`: the stored tool-approval card, unchanged, while it is pending. The app answers
/// acpmux natively with a delivery attempt and sends this question back with the receipt in the
/// `question.answer` op's `native_record` decision, which the delivery path checks against the
/// exact acpmux receipt. A question card gets no record here: its answer needs the person's proof.
pub(in crate::server) fn record_question(question: &Question) -> anyhow::Result<Value> {
    if !question_wire::is_native_approval(question) {
        return Err(refused("question.not_approval"));
    }
    if question.state != QuestionState::Pending {
        return Err(refused("question.closed"));
    }
    Ok(serde_json::json!({ "question": question }))
}

/// The unsigned decision from `pending`, the prompt's live `_acpmux/info` pending entries.
pub(in crate::server) fn decide_from(
    question: &Question,
    answer: &QuestionAnswer,
    info: &Value,
) -> anyhow::Result<Value> {
    if !info.get("peer").is_none_or(Value::is_null) {
        // A peer's prompt is that machine's to decide; its key is not this app's.
        return Err(refused("question.not_local"));
    }
    if question_wire::is_native_approval(question) {
        // A tool-permission card: the app answers acpmux natively and only records the card.
        return Err(refused("question.native_approval"));
    }
    let permission =
        question.permission.as_deref().ok_or_else(|| refused("question.no_request"))?;
    let entry = info
        .get("pending")
        .and_then(Value::as_array)
        .and_then(|entries| {
            entries
                .iter()
                .find(|entry| entry.get("permissionId").and_then(Value::as_str) == Some(permission))
        })
        .ok_or_else(|| refused("question.closed"))?;
    // The signed identity is the raw local session id, which acpmux verifies and `prepare` binds
    // (`local_session`); the stored question keeps its own spelling (`local/` or not) untouched.
    let raw = super::chief_question_routes::local_session_id(&question.session)
        .ok_or_else(|| refused("question.not_local"))?;
    let mut decision = question_wire::unsigned_decision(question, answer, entry)
        .map_err(|error| anyhow::Error::from(DecisionRefused::from(error)))?;
    decision.session = raw.to_owned();
    reply(question, decision, &entry["request"])
}

/// One budget for the whole exchange (every socket's connect, initialize and info read), and the
/// longest any one call may take. A connect has its own bound of this size, so none starts with
/// less than this left.
#[cfg(any(unix, test))]
const BUDGET: std::time::Duration = std::time::Duration::from_secs(15);
#[cfg(any(unix, test))]
const CALL_CAP: std::time::Duration = std::time::Duration::from_secs(3);

/// Reads `_acpmux/info` for `session` from the acpmux at `socket`: connect, initialize, info,
/// every call within `deadline` (and none past [`CALL_CAP`]).
#[cfg(unix)]
fn read_info(
    socket: &std::path::Path,
    session: &str,
    deadline: std::time::Instant,
) -> Result<Value, &'static str> {
    use super::agent_session_attach::agent_session_link::{AcpmuxLink, LinkError};
    use serde_json::json;
    use std::time::Instant;

    let link = AcpmuxLink::connect(socket, |_| {}).map_err(|_| "question.agent_gone")?;
    let call = |method: &str, params: Value| {
        let until = deadline.min(Instant::now() + CALL_CAP);
        link.call_until(method, params, until).map_err(|error| match error {
            LinkError::Closed => "question.agent_gone",
            LinkError::Timeout => "question.agent_busy",
            _ => "question.refused",
        })
    };
    let info = call(
        "initialize",
        json!({"protocolVersion": 1, "clientCapabilities": {},
               "clientInfo": {"name": "cmux-home-question-decision", "version": "1"}}),
    )
    .and_then(|_| call("_acpmux/info", json!({"sessionId": format!("local/{session}")})));
    link.close();
    info
}

/// The unsigned decision from the first of `sockets` whose acpmux holds `raw` as this machine's
/// own session (`sessionId == raw`, no peer) and, when a Chief route resolved (`owner` is its
/// home id), as that Chief's owner subagent. A socket that does not is not asked for a decision.
/// `read` gets the one `deadline` all sockets share; no socket is tried once less than a connect's
/// bound is left of it.
#[cfg(any(unix, test))]
fn decide_over(
    question: &Question,
    answer: &QuestionAnswer,
    raw: &str,
    sockets: &[std::path::PathBuf],
    owner: Option<&str>,
    deadline: std::time::Instant,
    mut read: impl FnMut(&std::path::Path, &str, std::time::Instant) -> Result<Value, &'static str>,
) -> anyhow::Result<Value> {
    let mut refusal = "question.agent_gone";
    for socket in sockets {
        if deadline.saturating_duration_since(std::time::Instant::now()) < CALL_CAP {
            refusal = "question.agent_busy";
            break;
        }
        match read(socket, raw, deadline) {
            Err(code) => refusal = code,
            Ok(info) => {
                let own = info.get("sessionId").and_then(Value::as_str) == Some(raw)
                    && info.get("peer").is_none_or(Value::is_null)
                    && owner.is_none_or(|home| {
                        super::chief_question_routes::is_owner_subagent(&info, raw, home)
                    });
                if own {
                    return decide_from(question, answer, &info);
                }
                refusal = "question.not_local";
            }
        }
    }
    Err(refused(refusal))
}

#[cfg(unix)]
pub(in crate::server) fn decision(mux: &Mux, params: DecisionParams) -> anyhow::Result<Value> {
    use super::chief_question_routes as routes;

    let question = stored_question(mux, &params)?;
    check_displayed(&question, params.question.as_ref(), !params.native_record)?;
    if params.native_record {
        return record_question(&question);
    }
    let raw =
        routes::local_session_id(&question.session).ok_or_else(|| refused("question.not_local"))?;
    // The route is the stored message's Chief author's, never a caller's choice (as `transport`).
    let chief = mux.with_conversations(|store| {
        store.message_chief_author(&params.conversation, &params.message_id, params.part_index)
    })?;
    let resolved = chief
        .as_deref()
        .map(|chief| routes::resolve(mux, chief))
        .transpose()
        .map_err(|_| refused("question.agent_gone"))?;
    let sockets = resolved
        .as_ref()
        .map(|r| r.candidates.clone())
        .unwrap_or_else(|| mux.control_clients.agent_sessions.socket().into_iter().collect());
    let owner = resolved.as_ref().map(|r| r.chief_home_id.as_str());
    let deadline = std::time::Instant::now() + BUDGET;
    decide_over(&question, &params.answer, raw, &sockets, owner, deadline, read_info)
}

/// Other daemon builds reach no acpmux: they refuse, and do not advertise the capability.
#[cfg(not(unix))]
pub(in crate::server) fn decision(_mux: &Mux, _params: DecisionParams) -> anyhow::Result<Value> {
    Err(refused("question.unsupported_platform"))
}

#[cfg(test)]
#[path = "conversation_question_decision_tests.rs"]
mod tests;
