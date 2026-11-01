//! The server side of the scoped Cloud trigger chat bridge.
//!
//! These methods are deliberately separate from ACP `session/new` and
//! `session/prompt`: callers must present a platform-admitted principal whose
//! machine, chat, delivery, prompt digest, cwd and harness are all fixed.

use super::{Conn, TriggerScope};
use crate::hub::Hub;
use crate::rpc::{RpcError, method};
use serde_json::{Value, json};
use sha2::Digest;
use std::sync::Arc;

const MAX: usize = 4096;

fn string(value: &Value, key: &str, max: usize) -> Result<String, RpcError> {
    value
        .get(key)
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty() && s.len() <= max && !s.chars().any(char::is_control))
        .map(str::to_owned)
        .ok_or_else(|| RpcError::invalid_params(format!("trigger principal {key} is invalid")))
}

fn scope(params: &Value) -> Result<TriggerScope, RpcError> {
    let p = params
        .get("principal")
        .ok_or_else(|| RpcError::new(-32001, "trigger authorization is required"))?;
    let audience = string(p, "audience", 64)?;
    if audience != "cmux-trigger-chat-v1" {
        return Err(RpcError::new(-32001, "trigger audience is invalid"));
    }
    let operations = p
        .get("operations")
        .and_then(Value::as_array)
        .ok_or_else(|| RpcError::new(-32001, "trigger operations are invalid"))?;
    if operations.len() != 3
        || operations
            .iter()
            .zip(["ensure", "send", "status"])
            .any(|(v, expected)| v.as_str() != Some(expected))
    {
        return Err(RpcError::new(-32001, "trigger operations are invalid"));
    }
    let guest_key = string(p, "guestKey", 128)?;
    if !guest_key.starts_with("sha256:") {
        return Err(RpcError::new(-32001, "trigger guest key is invalid"));
    }
    Ok(TriggerScope {
        trigger: string(p, "trigger", 128)?,
        machine: string(p, "machine", MAX)?,
        workspace: string(p, "workspace", MAX)?,
        session: string(p, "session", MAX)?,
        delivery: string(p, "delivery", MAX)?,
        prompt_hash: string(p, "promptHash", 128)?,
        cwd: string(p, "cwd", MAX)?,
        harness: string(p, "harness", 256)?,
        guest_key,
    })
}

fn operation(params: &Value, expected: &str) -> Result<(), RpcError> {
    if params.get("operation").and_then(Value::as_str) != Some(expected) {
        return Err(RpcError::invalid_params(format!("trigger operation must be {expected}")));
    }
    Ok(())
}

pub(super) async fn handle(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: Value,
) -> Result<Value, RpcError> {
    let expected = match m {
        method::TRIGGER_CHAT_ENSURE => "ensure",
        method::TRIGGER_CHAT_SEND => "send",
        method::TRIGGER_CHAT_STATUS => "status",
        _ => return Err(RpcError::method_not_found(m)),
    };
    operation(&params, expected)?;
    let scope = scope(&params)?;
    conn.admit_trigger(scope.clone())?;
    match expected {
        "ensure" => {
            let result = super::requests::handle_request(
                hub,
                conn,
                method::SESSION_NEW,
                json!({
                    "cwd": scope.cwd,
                    "harness": scope.harness,
                    "name": format!("trigger-{}", scope.trigger),
                    "_meta": {"acpmux": {"trigger": true}},
                }),
            )
            .await?;
            Ok(json!({"delivery": scope.delivery, "session": result}))
        }
        "send" => {
            let prompt = string(&params, "body", 1_000_000)?;
            let digest = format!("{:x}", sha2::Sha256::digest(prompt.as_bytes()));
            if digest != scope.prompt_hash {
                return Err(RpcError::new(-32001, "trigger prompt does not match authorization"));
            }
            let result = super::requests::handle_request(
                hub,
                conn,
                method::SESSION_PROMPT,
                json!({
                    "sessionId": scope.session,
                    "prompt": [{"type": "text", "text": prompt}],
                    "_meta": {"acpmux": {
                        "promptId": scope.delivery,
                        "provenance": {
                            "kind": "trigger", "triggerId": scope.trigger,
                            "deliveryId": scope.delivery, "machine": scope.machine,
                            "workspace": scope.workspace, "session": scope.session,
                        },
                    }},
                }),
            )
            .await?;
            Ok(result)
        }
        "status" => {
            // Keep the status response scoped to the exact session/delivery;
            // no list, owner or machine data is exposed on this RPC.
            let result = super::requests::handle_request(
                hub,
                conn,
                method::MUX_INFO,
                json!({"sessionId": scope.session, "delivery": scope.delivery}),
            )
            .await?;
            Ok(json!({"delivery": scope.delivery, "status": result}))
        }
        _ => unreachable!(),
    }
}
