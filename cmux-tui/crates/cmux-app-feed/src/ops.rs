//! The JSON ops the app calls over the app FFI (`app_feed_*`). Each takes one JSON object and
//! returns one; a rule's refusal is a value (`{"error": {code, message}}` or a `reason`), and only
//! a malformed request is an [`OpError`].

use crate::bridge::{self, AnswerFacts, Posted, Presence, Strings};
use crate::control::{self, OwnerFailure};
use crate::desk::{self, Pending, Question};
use crate::json::{arr_at, str_at};
use crate::proof::{self, Context, Decision};
use crate::{github, needs_you, prompt, text, update};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Map, Value, json};

/// The prefix every op of this crate has.
pub const PREFIX: &str = "app_feed_";

#[derive(Debug, PartialEq, Eq)]
pub enum OpError {
    UnknownOp(String),
    Invalid(String),
}

impl std::fmt::Display for OpError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::UnknownOp(op) => write!(formatter, "unknown op {op}"),
            Self::Invalid(why) => write!(formatter, "invalid request: {why}"),
        }
    }
}

impl std::error::Error for OpError {}

/// The Feed's rules behind the app FFI. Stateless: the app keeps what it posted and answered.
#[derive(Debug, Default)]
pub struct AppFeed;

fn parse<T: DeserializeOwned>(request: Value) -> Result<T, OpError> {
    serde_json::from_value(request).map_err(|error| OpError::Invalid(error.to_string()))
}

fn text_at<'a>(request: &'a Value, key: &str) -> Result<&'a str, OpError> {
    str_at(request, key).ok_or_else(|| OpError::Invalid(format!("`{key}` must be a string")))
}

fn object_at(request: &Value, key: &str) -> Map<String, Value> {
    request.get(key).and_then(Value::as_object).cloned().unwrap_or_default()
}

fn items_at(request: &Value, key: &str) -> Vec<Value> {
    arr_at(request, key).cloned().unwrap_or_default()
}

fn to_value<T: serde::Serialize>(value: T) -> Result<Value, OpError> {
    serde_json::to_value(value).map_err(|error| OpError::Invalid(error.to_string()))
}

fn error_value<T: serde::Serialize>(error: T) -> Result<Value, OpError> {
    Ok(json!({"error": to_value(error)?}))
}

#[derive(Deserialize)]
struct PostRequest {
    session: String,
    permission: String,
    #[serde(default)]
    request: Value,
    host: String,
    #[serde(default)]
    strings: Strings,
}

#[derive(Deserialize)]
struct PostedRequest {
    session: String,
    permission: String,
    #[serde(default)]
    request: Value,
    #[serde(default)]
    body: Value,
}

#[derive(Deserialize)]
struct PresenceRequest {
    context: Context,
    /// `user.presence_key.list`'s value (`{"keys": [...]}`).
    #[serde(default)]
    keys: Value,
}

#[derive(Deserialize)]
struct AnswerRequest {
    item: String,
    entry: Posted,
    decision: Decision,
    by: String,
    #[serde(default)]
    own_install: Option<String>,
    #[serde(default)]
    pending: Option<Value>,
    #[serde(default)]
    presence: Option<PresenceRequest>,
    now_ms: f64,
}

#[derive(Deserialize)]
struct CheckRequest {
    decision: Decision,
    by: String,
    item: String,
    shown_sha256: String,
    context: Context,
    #[serde(default)]
    keys: Value,
    now_ms: f64,
}

#[derive(Deserialize)]
struct DeskItemRequest {
    prompt: Pending,
    #[serde(default)]
    question: Option<Question>,
    #[serde(default)]
    tab_id: Option<String>,
    #[serde(default)]
    status: Option<String>,
}

#[derive(Deserialize)]
struct DeskDenyRequest {
    #[serde(default)]
    mode: String,
    prompt: Pending,
    #[serde(default)]
    question: Option<Question>,
}

#[derive(Deserialize)]
struct DeskAnswerRequest {
    #[serde(default)]
    selections: Vec<Value>,
    question: Question,
}

fn presence(request: Option<PresenceRequest>) -> Option<Presence> {
    request.map(|request| Presence { context: request.context, keys: proof::keys(&request.keys) })
}

fn selections(values: &[Value]) -> Vec<String> {
    values.iter().filter_map(Value::as_str).map(str::to_owned).collect()
}

impl AppFeed {
    pub fn new() -> Self {
        Self
    }

    /// Whether `op` is one of this crate's.
    pub fn serves(op: &str) -> bool {
        op.starts_with(PREFIX)
    }

    /// Runs `op` on `request` (a JSON object; `null` reads as `{}`).
    pub fn call(&mut self, op: &str, request: Value) -> Result<Value, OpError> {
        let request = if request.is_null() { crate::json::empty() } else { request };
        let Some(name) = op.strip_prefix(PREFIX) else {
            return Err(OpError::UnknownOp(op.to_owned()));
        };
        match name {
            "scrub" => {
                let source = text_at(&request, "text")?;
                let out = if request.get("prefix") == Some(&Value::Bool(true)) {
                    text::scrub_prefix(source)
                } else {
                    text::scrub(source)
                };
                Ok(json!({"text": out}))
            }
            "visible" => {
                let source = text_at(&request, "text")?;
                let mut out = text::visible(source);
                if let Some(limit) = request.get("cut").and_then(Value::as_u64) {
                    out = text::cut(&out, usize::try_from(limit).unwrap_or(usize::MAX));
                }
                Ok(json!({"text": out}))
            }
            "prompt" => {
                let source = request.get("request").cloned().unwrap_or(Value::Null);
                let call = source.get("toolCall");
                let input = call.and_then(|call| call.get("rawInput"));
                let offered = prompt::offered(&source);
                Ok(json!({
                    "digest": prompt::digest(&source),
                    "summary": prompt::summary(&source),
                    "command": prompt::shown_command(input.and_then(|input| input.get("command"))),
                    "input": input.and_then(Value::as_object).and_then(prompt::input_summary),
                    "is_question": prompt::is_question(&source),
                    "is_tool_permission": prompt::is_tool_permission(&source),
                    "question": prompt::question(&source),
                    "allow_option": prompt::option(true, &offered),
                    "deny_option": prompt::option(false, &offered),
                    "once_allow_option": prompt::once_option(true, &offered),
                    "once_deny_option": prompt::once_option(false, &offered),
                    "always_option": prompt::always_option(&offered),
                }))
            }
            "shown_command" => Ok(json!({"command": prompt::shown_command(request.get("value"))})),
            "input_summary" => {
                Ok(json!({"summary": prompt::input_summary(&object_at(&request, "input"))}))
            }
            "proof_keys" => {
                Ok(json!({"keys": proof::keys(request.get("value").unwrap_or(&Value::Null))}))
            }
            "token" => {
                let token = text_at(&request, "token")?;
                Ok(
                    json!({"context": proof::context_of_token(token), "install": proof::install_of_token(token)}),
                )
            }
            "shown_sha256" => {
                let action = request.get("action").cloned().unwrap_or(Value::Null);
                Ok(
                    json!({"sha256": proof::shown_sha256(&action), "canonical": proof::ShownText::of_action(&action).canonical()}),
                )
            }
            "approve_decision" => Ok(
                json!({"decision": proof::approve_decision(request.get("item").unwrap_or(&Value::Null))}),
            ),
            "proof_check" => {
                let check: CheckRequest = parse(request)?;
                let keys = proof::keys(&check.keys);
                let result = proof::check(
                    &check.decision,
                    &check.by,
                    &check.item,
                    &check.shown_sha256,
                    &check.context,
                    &keys,
                    check.now_ms,
                );
                Ok(match result {
                    Ok(()) => json!({"ok": true}),
                    Err(failure) => json!({"ok": false, "failure": to_value(failure)?}),
                })
            }
            "bridge_post_body" => {
                let post: PostRequest = parse(request)?;
                Ok(bridge::post_body(
                    &post.session,
                    &post.permission,
                    &post.request,
                    &post.host,
                    &post.strings,
                ))
            }
            "bridge_posted" => {
                let posted: PostedRequest = parse(request)?;
                to_value(bridge::posted(
                    &posted.session,
                    &posted.permission,
                    &posted.request,
                    &posted.body,
                ))
            }
            "bridge_withdraw" => Ok(bridge::withdraw_body(text_at(&request, "item")?)),
            "bridge_admits" => {
                let by = text_at(&request, "by")?;
                Ok(match bridge::admits(by, str_at(&request, "own_install")) {
                    Ok(()) => json!({"ok": true}),
                    Err(reason) => json!({"ok": false, "reason": to_value(reason)?}),
                })
            }
            "bridge_option" => {
                let decision: Decision =
                    parse(request.get("decision").cloned().unwrap_or(Value::Null))?;
                Ok(match bridge::option_for(&decision, &items_at(&request, "offered")) {
                    Ok(option) => json!({"option": option}),
                    Err(reason) => json!({"reason": to_value(reason)?}),
                })
            }
            "bridge_answer" => {
                let answer: AnswerRequest = parse(request)?;
                let presence = presence(answer.presence);
                let facts = AnswerFacts {
                    item: &answer.item,
                    entry: &answer.entry,
                    decision: &answer.decision,
                    by: &answer.by,
                    own_install: answer.own_install.as_deref(),
                    pending: answer.pending.as_ref().filter(|pending| !pending.is_null()),
                    presence: presence.as_ref(),
                    now_ms: answer.now_ms,
                };
                to_value(bridge::answer(&facts))
            }
            "desk_item" => {
                let item: DeskItemRequest = parse(request)?;
                let status = item.status.as_deref().unwrap_or("pending");
                Ok(desk::item(&item.prompt, item.question.as_ref(), item.tab_id.as_deref(), status))
            }
            "desk_deny" => {
                let deny: DeskDenyRequest = parse(request)?;
                match desk::deny_reply(&deny.mode, &deny.prompt, deny.question.as_ref()) {
                    Ok(reply) => Ok(json!({"reply": reply})),
                    Err(error) => error_value(error),
                }
            }
            "desk_answer" => {
                let answer: DeskAnswerRequest = parse(request)?;
                match desk::answer(&selections(&answer.selections), &answer.question) {
                    Ok(chosen) => Ok(json!({"selections": to_value(chosen)?})),
                    Err(error) => error_value(error),
                }
            }
            "desk_app_choice" => Ok(
                json!({"choice": desk::app_ask_choice(&selections(&items_at(&request, "selections")))}),
            ),
            "desk_remember" => {
                let entry = request.get("entry").cloned().unwrap_or(Value::Null);
                Ok(json!({"answered": desk::remember(items_at(&request, "answered"), entry)}))
            }
            "desk_app_answered" => {
                let id = text_at(&request, "id")?;
                Ok(desk::app_ask_answered(id, request.get("reply").unwrap_or(&Value::Null)))
            }
            "control_request" => {
                match control::request(request.get("params").unwrap_or(&Value::Null)) {
                    Ok(plan) => to_value(plan),
                    Err(error) => error_value(error),
                }
            }
            "control_posted_id" => {
                match control::posted_id(request.get("reply").unwrap_or(&Value::Null)) {
                    Ok(id) => Ok(json!({"id": id, "read": control::read_body(&id)})),
                    Err(error) => error_value(error),
                }
            }
            "control_result" => {
                let wait = request.get("wait").and_then(Value::as_i64).unwrap_or(0);
                Ok(control::request_result(request.get("read").unwrap_or(&Value::Null), wait))
            }
            "control_cancel" => {
                match control::cancel(request.get("params").unwrap_or(&Value::Null)) {
                    Ok(body) => Ok(json!({"body": body})),
                    Err(error) => error_value(error),
                }
            }
            "owner_reply" => Ok(
                json!({"error": control::reply_error(request.get("reply").unwrap_or(&Value::Null))}),
            ),
            "owner_error" => {
                let failure = match text_at(&request, "failure")? {
                    "signed_out" => OwnerFailure::SignedOut,
                    "owner" => OwnerFailure::Owner {
                        code: str_at(&request, "code").unwrap_or("error").to_owned(),
                        message: str_at(&request, "message").unwrap_or_default().to_owned(),
                    },
                    _ => OwnerFailure::Other(
                        str_at(&request, "message").unwrap_or_default().to_owned(),
                    ),
                };
                error_value(control::owner_error(&failure))
            }
            "control_debug" => {
                let matches = str_at(&request, "match")
                    .map(|text| control::debug_matches(&items_at(&request, "items"), text));
                Ok(
                    json!({"matches": matches, "connection": control::connection_line(request.get("connection"))}),
                )
            }
            "github_plan" => {
                let action = text_at(&request, "action")?;
                let item = request.get("item").cloned().unwrap_or(Value::Null);
                to_value(github::plan(
                    action,
                    &item,
                    str_at(&request, "text"),
                    str_at(&request, "root").unwrap_or_default(),
                ))
            }
            "open_target" => {
                to_value(github::open_target(request.get("item").unwrap_or(&Value::Null)))
            }
            "needs_you" => {
                let view = request.get("view").cloned().unwrap_or(Value::Null);
                Ok(json!({
                    "requests": needs_you::current(&view),
                    "settled": needs_you::is_settled(&view),
                    "owner": needs_you::owner(&view),
                }))
            }
            "needs_you_requests" => {
                Ok(json!({"requests": needs_you::requests(&items_at(&request, "items"))}))
            }
            "update_step" => {
                let highlights =
                    request.get("highlights").filter(|highlights| !highlights.is_null());
                // `enabled` left out means enabled; `null` means not known yet.
                let enabled = match request.get("enabled") {
                    None => Some(true),
                    Some(value) => value.as_bool(),
                };
                let at = request.get("at").and_then(Value::as_f64).unwrap_or(0.0);
                to_value(update::step(highlights, str_at(&request, "posted"), enabled, at))
            }
            "update_card" => {
                let at = request.get("at").and_then(Value::as_f64).unwrap_or(0.0);
                Ok(
                    json!({"card": update::card(request.get("highlights").unwrap_or(&Value::Null), at)}),
                )
            }
            _ => Err(OpError::UnknownOp(op.to_owned())),
        }
    }
}
