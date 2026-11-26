//! The `cloud` area's ops: the cloud link state machine, the session
//! lease's rules and the cloud proxy's reply errors (the client's decisions;
//! URLSession and socket I/O stay in each app).

use crate::ops::{OpError, parse, reply};
use serde::Deserialize;
use serde_json::{Value, json};

pub mod lease;
pub mod link;
pub mod reply;
pub mod source;

/// This area's op names (without the `cloud.` prefix).
pub const OPS: &[&str] = &[
    "cloud_id",
    "jwt_claims",
    "lease_check",
    "link_step",
    "origin",
    "reply_classify",
    "source_answer",
    "source_derived_keys",
    "source_for_account",
    "source_hydrate",
    "source_inbox_merge",
    "source_inbox_page",
    "source_internal_id",
    "source_masked",
    "source_message_request",
    "source_releases_key",
    "source_revision",
];

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct UrlRequest {
    url: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StackUserRequest {
    stack_user_id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClassifyRequest {
    error: reply::ReplyError,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ForAccountRequest {
    event: source::EventAccount,
    #[serde(default)]
    cloud_id: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ValueRequest {
    #[serde(default)]
    value: Option<Value>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TextRequest {
    text: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReleaseRequest {
    op: String,
    #[serde(default)]
    rejection: Option<reply::Rejection>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct KeysRequest {
    key: String,
    #[serde(default)]
    participants: usize,
    #[serde(default)]
    invites: usize,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MaskRequest {
    contact: source::Contact,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RowRequest {
    request: Value,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AnswerRequest {
    answer: String,
}

/// Runs `cloud.NAME`.
pub fn call(name: &str, request: &Value) -> Result<Value, OpError> {
    match name {
        "origin" => {
            let req: UrlRequest = parse(request)?;
            Ok(json!({ "origin": lease::origin(&req.url) }))
        }
        "cloud_id" => {
            let req: StackUserRequest = parse(request)?;
            Ok(json!({ "cloudId": lease::cloud_id(&req.stack_user_id) }))
        }
        "jwt_claims" => reply(&lease::jwt_claims(&parse(request)?)),
        "lease_check" => reply(&lease::check(&parse(request)?)),
        "link_step" => {
            let req: link::StepRequest = parse(request)?;
            let (state, effects) = link::step(req.state, req.event);
            reply(&link::StepReply { state, effects })
        }
        "reply_classify" => {
            let req: ClassifyRequest = parse(request)?;
            reply(&reply::classify(&req.error))
        }
        "source_for_account" => {
            let req: ForAccountRequest = parse(request)?;
            Ok(json!({ "keep": source::is_for_account(&req.event, req.cloud_id.as_deref()) }))
        }
        "source_revision" => {
            let req: ValueRequest = parse(request)?;
            Ok(json!({ "revision": source::revision(req.value.as_ref()) }))
        }
        "source_inbox_page" => reply(&source::inbox_page(parse(request)?)),
        "source_inbox_merge" => reply(&source::inbox_merge(parse(request)?)),
        "source_hydrate" => reply(&source::hydrate(parse(request)?)),
        "source_releases_key" => {
            let req: ReleaseRequest = parse(request)?;
            Ok(json!({ "release": source::releases_key(&req.op, req.rejection.as_ref()) }))
        }
        "source_derived_keys" => {
            let req: KeysRequest = parse(request)?;
            reply(&source::derived_keys(&req.key, req.participants, req.invites))
        }
        "source_masked" => {
            let req: MaskRequest = parse(request)?;
            Ok(json!({ "masked": source::masked(&req.contact) }))
        }
        "source_internal_id" => {
            let req: TextRequest = parse(request)?;
            Ok(json!({ "internal": source::is_home_internal_id(&req.text) }))
        }
        "source_message_request" => {
            let req: RowRequest = parse(request)?;
            Ok(json!({ "request": source::message_request(&req.request) }))
        }
        "source_answer" => {
            let req: AnswerRequest = parse(request)?;
            source::answer_op(&req.answer)
                .ok_or_else(|| OpError::Invalid(format!("unknown answer {}", req.answer)))
        }
        _ => Err(OpError::Unknown),
    }
}
