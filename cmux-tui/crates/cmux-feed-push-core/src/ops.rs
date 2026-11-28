//! The JSON ops both bindings answer (the Mac's `cmux_feed_push_call`, the
//! phones' uniffi `feed_push_json`): one op name and one request object in,
//! one reply object out.
//!
//! - `shown_text` `{action}` -> `{canonical, sha256, truncated}`; `action` is
//!   a feed item's `prompt.action`.
//! - `approve_message` `{environment, user, phone_install, mac_install, item,
//!   shown_sha256, decision, scope, timestamp_ms}` -> `{text}`: the bytes the
//!   presence key signs (UTF-8 of `text`).
//! - `categories` `{}` -> `{categories: [{id, actions: [{id, style,
//!   destructive, requires_unlock}]}]}`; `style` is `answer`, `text_input` or
//!   `open_app`.
//! - `answer_for_action` `{action, text?}` -> `{answer: FeedAnswer|null,
//!   value: object|null}`.
//! - `answer_value` `{answer: FeedAnswer}` -> `{value}`: the wire `answer`.
//! - `op_register_push_target` `{token: [u8], topic, environment,
//!   device_name, idempotency_key}`, `op_remove_push_target` `{token,
//!   idempotency_key}`, `op_answer` `{item, answer: FeedAnswer,
//!   idempotency_key}` -> `{body}`: the `POST /v1/ops` body as a JSON string.
//! - `op_reply` `{body: string}` -> `{committed: bool, replayed, code,
//!   retryable}`.
//! - `push_payload` `{user_info}` -> `{payload: {item, kind, type,
//!   category}|null}`.
//! - `push_response` `{action_identifier, user_text?, user_info}` ->
//!   `{response: "send"|"open"|"ignore", item?, answer?, idempotency_key?,
//!   body?}`.
//!
//! `FeedAnswer` is [`crate::FeedAnswer`]'s JSON (`{"kind": ...}`).

use crate::{
    ApnsEnvironment, ApproveMessage, CloudOp, CloudOpReply, FeedAnswer, FeedPushAction, FeedPushActionStyle,
    FeedPushCategory, FeedPushPayload, FeedPushResponse, ShownText,
};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

/// Why an op gave no reply.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OpError {
    /// The op is not one of these.
    Unknown,
    /// The request is not the object the op takes.
    Invalid,
}

fn de<T: DeserializeOwned>(request: &Value) -> Result<T, OpError> {
    serde_json::from_value(request.clone()).map_err(|_| OpError::Invalid)
}

#[derive(Deserialize)]
struct Action {
    #[serde(default)]
    action: Value,
}

#[derive(Deserialize)]
struct AnswerForAction {
    action: String,
    #[serde(default)]
    text: Option<String>,
}

#[derive(Deserialize)]
struct AnswerOnly {
    answer: FeedAnswer,
}

#[derive(Deserialize)]
struct Register {
    token: Vec<u8>,
    topic: String,
    environment: ApnsEnvironment,
    device_name: String,
    idempotency_key: String,
}

#[derive(Deserialize)]
struct Remove {
    token: Vec<u8>,
    idempotency_key: String,
}

#[derive(Deserialize)]
struct Answer {
    item: String,
    answer: FeedAnswer,
    idempotency_key: String,
}

#[derive(Deserialize)]
struct Reply {
    body: String,
}

#[derive(Deserialize)]
struct UserInfo {
    #[serde(default)]
    user_info: Value,
}

#[derive(Deserialize)]
struct Response {
    action_identifier: String,
    #[serde(default)]
    user_text: Option<String>,
    #[serde(default)]
    user_info: Value,
}

fn style(action: FeedPushAction) -> Value {
    match action.style() {
        FeedPushActionStyle::Answer { destructive, requires_unlock } => {
            json!({"id": action.id(), "style": "answer", "destructive": destructive, "requires_unlock": requires_unlock})
        }
        FeedPushActionStyle::TextInput => {
            json!({"id": action.id(), "style": "text_input", "destructive": false, "requires_unlock": false})
        }
        FeedPushActionStyle::OpenApp => {
            json!({"id": action.id(), "style": "open_app", "destructive": false, "requires_unlock": false})
        }
    }
}

fn answer_json(answer: &FeedAnswer) -> Value {
    serde_json::to_value(answer).unwrap_or(Value::Null)
}

/// Runs one op.
pub fn call(op: &str, request: &Value) -> Result<Value, OpError> {
    match op {
        "shown_text" => {
            let Action { action } = de(request)?;
            let shown = ShownText::from_action(&action);
            Ok(json!({"canonical": shown.canonical(), "sha256": shown.sha256(), "truncated": shown.truncated}))
        }
        "approve_message" => {
            let message: ApproveMessage = de(request)?;
            Ok(json!({"text": message.text()}))
        }
        "categories" => {
            let categories: Vec<Value> = FeedPushCategory::ALL
                .into_iter()
                .map(|category| {
                    json!({
                        "id": category.id(),
                        "actions": category.actions().iter().map(|action| style(*action)).collect::<Vec<_>>(),
                    })
                })
                .collect();
            Ok(json!({"categories": categories}))
        }
        "answer_for_action" => {
            let AnswerForAction { action, text } = de(request)?;
            let answer =
                FeedPushAction::from_id(&action).and_then(|action| FeedAnswer::for_action(action, text.as_deref()));
            Ok(match answer {
                Some(answer) => json!({"answer": answer_json(&answer), "value": answer.value()}),
                None => json!({"answer": null, "value": null}),
            })
        }
        "answer_value" => {
            let AnswerOnly { answer } = de(request)?;
            Ok(json!({"value": answer.value()}))
        }
        "op_register_push_target" => {
            let Register { token, topic, environment, device_name, idempotency_key } = de(request)?;
            let op = CloudOp::register_push_target(&token, &topic, environment, &device_name, &idempotency_key);
            Ok(json!({"body": op.body()}))
        }
        "op_remove_push_target" => {
            let Remove { token, idempotency_key } = de(request)?;
            Ok(json!({"body": CloudOp::remove_push_target(&token, &idempotency_key).body()}))
        }
        "op_answer" => {
            let Answer { item, answer, idempotency_key } = de(request)?;
            Ok(json!({"body": CloudOp::answer(&item, &answer, &idempotency_key).body()}))
        }
        "op_reply" => {
            let Reply { body } = de(request)?;
            Ok(match CloudOpReply::decode(body.as_bytes()) {
                CloudOpReply::Committed { replayed } => {
                    json!({"committed": true, "replayed": replayed, "code": null, "retryable": false})
                }
                CloudOpReply::Rejected { code, retryable } => {
                    json!({"committed": false, "replayed": false, "code": code, "retryable": retryable})
                }
            })
        }
        "push_payload" => {
            let UserInfo { user_info } = de(request)?;
            Ok(match FeedPushPayload::from_user_info(&user_info) {
                Some(payload) => json!({"payload": {
                    "item": payload.item,
                    "kind": payload.kind,
                    "type": payload.r#type,
                    "category": payload.category.map(FeedPushCategory::id),
                }}),
                None => json!({"payload": null}),
            })
        }
        "push_response" => {
            let Response { action_identifier, user_text, user_info } = de(request)?;
            let response = FeedPushResponse::new(&action_identifier, user_text.as_deref(), &user_info);
            let body = response.op().map(|op| op.body());
            Ok(match response {
                FeedPushResponse::Send { item, answer, idempotency_key } => json!({
                    "response": "send",
                    "item": item,
                    "answer": answer_json(&answer),
                    "idempotency_key": idempotency_key,
                    "body": body,
                }),
                FeedPushResponse::Open { item } => json!({"response": "open", "item": item}),
                FeedPushResponse::Ignore => json!({"response": "ignore"}),
            })
        }
        _ => Err(OpError::Unknown),
    }
}
