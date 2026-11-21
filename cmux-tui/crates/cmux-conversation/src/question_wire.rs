//! A conversation question's answer as acpmux reads it, and the check that a stored question is
//! the live request it claims to answer. One encoder for every party that must agree on the bytes:
//! the daemon that sends `_acpmux/permission_respond`, and the app that signs the person's
//! decision over those exact `answers` (acpmux `decision_answers_proof`, the sha256 of their
//! canonical JSON). If the two encoded differently, acpmux would refuse every Home answer.
//!
//! Pure: no I/O, no key, no proof. A result here grants nothing; acpmux alone verifies and spends
//! the person's decision under its pending-request lock.

use serde_json::{Map, Value, json};

use crate::{Question, QuestionAnswer, QuestionHarness, QuestionItem, QuestionState};

/// Why a question and a request or answer do not go together. Each is a stable refusal code.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WireError {
    /// The question is no longer pending, or no longer matches the live request.
    Stale,
    /// The request is a tool permission, not a question.
    NotQuestion,
    /// The question has no acpmux permission to answer.
    NoRequest,
    /// An item of the question has no selection.
    InvalidAnswer,
    /// Two items share a prompt, so a prompt-keyed answer cannot say which is which.
    Ambiguous,
    /// acpmux takes no answers for this harness.
    UnsupportedHarness,
}

impl WireError {
    pub fn code(self) -> &'static str {
        match self {
            Self::Stale => "question.stale",
            Self::NotQuestion => "question.not_question",
            Self::NoRequest => "question.no_request",
            Self::InvalidAnswer => "question.invalid_answer",
            Self::Ambiguous => "question.ambiguous",
            Self::UnsupportedHarness => "question.unsupported_harness",
        }
    }
}

impl std::fmt::Display for WireError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.code())
    }
}
impl std::error::Error for WireError {}

/// The stored, still pending `question` is the one the live acpmux `request` asks: the same
/// harness and items as the request's normalized question (`toolCall._meta.acpmux.question`).
pub fn check_request(question: &Question, request: &Value) -> Result<(), WireError> {
    if question.state != QuestionState::Pending {
        return Err(WireError::Stale);
    }
    let normalized =
        request.pointer("/toolCall/_meta/acpmux/question").ok_or(WireError::NotQuestion)?;
    let items = normalized.get("items").and_then(Value::as_array).ok_or(WireError::NotQuestion)?;
    // acpmux spells the flags in camelCase; the conversation stores them in snake_case.
    let items: Vec<Value> = items
        .iter()
        .map(|item| {
            let mut item = item.clone();
            if let Some(map) = item.as_object_mut() {
                for (from, to) in [("multiSelect", "multi_select"), ("allowsOther", "allows_other")]
                {
                    if let Some(value) = map.remove(from) {
                        map.insert(to.to_owned(), value);
                    }
                }
            }
            item
        })
        .collect();
    let items: Vec<QuestionItem> =
        serde_json::from_value(Value::Array(items)).map_err(|_| WireError::Stale)?;
    let harness = serde_json::to_value(question.harness).map_err(|_| WireError::Stale)?;
    if items != question.items || normalized.get("harness") != Some(&harness) {
        return Err(WireError::Stale);
    }
    Ok(())
}

/// The one option a question's answer goes with: the request's only `allow_once` option.
pub fn answer_option(request: &Value) -> Result<String, WireError> {
    let mut once = request
        .get("options")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|option| option.get("kind").and_then(Value::as_str) == Some("allow_once"))
        .filter_map(|option| option.get("optionId").and_then(Value::as_str));
    match (once.next(), once.next()) {
        (Some(id), None) if !id.trim().is_empty() => Ok(id.to_owned()),
        _ => Err(WireError::Stale),
    }
}

/// `answer` as `_acpmux/permission_respond`'s `answers`: Claude and Chief key each item's chosen
/// labels (and a trimmed Other), joined with ", ", by its prompt; Codex keys `{"answers": [..]}`
/// by item id. Labels keep the question's option order, whatever order they were picked in.
pub fn acpmux_answers(question: &Question, answer: &QuestionAnswer) -> Result<Value, WireError> {
    let mut answers = Map::new();
    for item in &question.items {
        let selection = answer.selections.get(&item.id).ok_or(WireError::InvalidAnswer)?;
        let mut labels: Vec<String> = item
            .options
            .iter()
            .filter(|option| selection.option_ids.contains(&option.id))
            .map(|option| option.label.clone())
            .collect();
        if let Some(other) = &selection.other {
            let other = other.trim();
            if !other.is_empty() {
                labels.push(other.to_owned());
            }
        }
        if labels.is_empty() {
            return Err(WireError::InvalidAnswer);
        }
        match question.harness {
            QuestionHarness::Claude | QuestionHarness::Chief => {
                if answers.insert(item.prompt.clone(), json!(labels.join(", "))).is_some() {
                    return Err(WireError::Ambiguous);
                }
            }
            QuestionHarness::Codex => {
                answers.insert(item.id.clone(), json!({ "answers": labels }));
            }
            QuestionHarness::Acp => return Err(WireError::UnsupportedHarness),
        }
    }
    Ok(Value::Object(answers))
}

/// Home's tool-permission card (Swift `HomeApprovalRowProvider.digest`): one Chief item
/// `approval:<request sha256>` offering only `allow` and `deny`. The app answers its acpmux prompt
/// itself, natively, on its person-proven connection, before it records the card; the record
/// sends nothing to acpmux and needs no decision (by then the prompt and its nonce are gone).
pub fn is_native_approval(question: &Question) -> bool {
    let [item] = question.items.as_slice() else { return false };
    let digest = item.id.strip_prefix("approval:").unwrap_or_default();
    let mut ids: Vec<&str> = item.options.iter().map(|option| option.id.as_str()).collect();
    ids.sort_unstable();
    question.harness == QuestionHarness::Chief
        && question.permission.is_some()
        && !item.multi_select
        && !item.allows_other
        && ids == ["allow", "deny"]
        && digest.len() == 64
        && digest.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

/// What the person signs for one Home answer, before any key touches it: the live request's
/// identity and the exact `answers` the daemon will send. The app checks `instance`,
/// `decision_nonce` and `digest` against its own person-proven read of the same prompt before it
/// signs, so a wrong daemon cannot get a proof for another prompt.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct UnsignedDecision {
    pub session: String,
    pub permission: String,
    pub option_id: String,
    pub instance: String,
    pub decision_nonce: String,
    pub answers: Value,
}

/// The unsigned decision for answering `question` with `answer`, from the prompt's live acpmux
/// pending entry (`_acpmux/info` `pending[]`: `permissionId`, `personInstance`,
/// `decisionNonce`, `request`).
pub fn unsigned_decision(
    question: &Question,
    answer: &QuestionAnswer,
    pending: &Value,
) -> Result<UnsignedDecision, WireError> {
    let permission = question.permission.as_deref().ok_or(WireError::NoRequest)?;
    if pending.get("permissionId").and_then(Value::as_str) != Some(permission) {
        return Err(WireError::Stale);
    }
    let request = pending.get("request").ok_or(WireError::Stale)?;
    check_request(question, request)?;
    let text = |key: &str| {
        pending
            .get(key)
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(str::to_owned)
            .ok_or(WireError::Stale)
    };
    Ok(UnsignedDecision {
        session: question.session.clone(),
        permission: permission.to_owned(),
        option_id: answer_option(request)?,
        instance: text("personInstance")?,
        decision_nonce: text("decisionNonce")?,
        answers: acpmux_answers(question, answer)?,
    })
}

/// `value` as the bytes every party hashes (acpmux `approvers::canonical_json`, the app's
/// `AcpmuxSecretKey.canonicalJSON`): object keys in UTF-8 byte order, no whitespace, and only `"`,
/// `\` and control characters escaped (`\b \f \n \r \t`, else `\u00xx`). The request
/// digest the app checks before it signs is the sha256 of these bytes; golden cases in
/// `tests/fixtures/canonical_json.json` are checked here and in the app.
pub fn canonical_json(value: &Value) -> String {
    let mut out = String::new();
    write_canonical(value, &mut out);
    out
}

fn write_canonical(value: &Value, out: &mut String) {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(flag) => out.push_str(if *flag { "true" } else { "false" }),
        Value::Number(number) => out.push_str(&number.to_string()),
        Value::String(text) => write_string(text, out),
        Value::Array(items) => {
            out.push('[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_canonical(item, out);
            }
            out.push(']');
        }
        Value::Object(map) => {
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort_by(|a, b| a.as_bytes().cmp(b.as_bytes()));
            out.push('{');
            for (index, key) in keys.into_iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_string(key, out);
                out.push(':');
                write_canonical(&map[key], out);
            }
            out.push('}');
        }
    }
}

fn write_string(text: &str, out: &mut String) {
    out.push('"');
    for ch in text.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            ch if (ch as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", ch as u32)),
            ch => out.push(ch),
        }
    }
    out.push('"');
}

#[cfg(test)]
#[path = "question_wire_tests.rs"]
mod tests;
