//! The `cloud` area's ops: the cloud link state machine, the session
//! lease's rules and the cloud proxy's reply errors (the client's decisions;
//! URLSession and socket I/O stay in each app).

use crate::ops::{OpError, parse, reply};
use serde::Deserialize;
use serde_json::{Value, json};

pub mod lease;
pub mod link;
pub mod reply;

/// This area's op names (without the `cloud.` prefix).
pub const OPS: &[&str] =
    &["cloud_id", "jwt_claims", "lease_check", "link_step", "origin", "reply_classify"];

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
        _ => Err(OpError::Unknown),
    }
}
