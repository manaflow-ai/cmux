//! The server side of the scoped Cloud trigger chat bridge.
//!
//! These methods are deliberately separate from ACP `session/new` and
//! `session/prompt`: callers must present a platform-admitted principal whose
//! machine, chat, delivery, prompt digest, cwd and harness are all fixed.

use super::{Conn, TriggerScope};
use crate::hub::Hub;
use crate::rpc::{RpcError, method};
use cmux_host::identity::HostIdentity;
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

fn scope(p: &Value) -> Result<TriggerScope, RpcError> {
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

fn validate_claims(
    principal: &Value,
    scope: &TriggerScope,
    route: &str,
    identity: &HostIdentity,
) -> Result<(), RpcError> {
    if scope.trigger != route
        || scope.machine != identity.machine
        || scope.guest_key != identity.guest_key
        || principal.get("owner").and_then(Value::as_str).is_none_or(str::is_empty)
        || principal.get("team").and_then(Value::as_str).is_none_or(str::is_empty)
        || principal.get("revision").and_then(Value::as_u64).is_none_or(|n| n == 0)
    {
        return Err(RpcError::new(-32001, "trigger authorization claims are invalid"));
    }
    let hash = &scope.prompt_hash;
    if hash.len() != 64
        || !hash.as_bytes().iter().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(b))
    {
        return Err(RpcError::new(-32001, "trigger prompt authorization is invalid"));
    }
    let issued = principal.get("issuedAt").and_then(Value::as_u64);
    let expires = principal.get("expiresAt").and_then(Value::as_u64);
    let now = u64::try_from(chrono::Utc::now().timestamp_millis()).unwrap_or(0);
    if issued.is_none_or(|at| at > now)
        || expires.is_none_or(|at| at <= now || at - issued.unwrap_or(now) > 300_000)
    {
        return Err(RpcError::new(-32001, "trigger authorization expired"));
    }
    Ok(())
}

fn token_route(token: &str) -> Result<&str, RpcError> {
    if token.len() > 8192 || !token.starts_with("ctg1.") {
        return Err(RpcError::new(-32001, "trigger token is invalid"));
    }
    let mut parts = token.split('.');
    let _ = parts.next();
    let id = parts.next().filter(|id| {
        id.len() == 36
            && id.as_bytes().iter().enumerate().all(|(i, b)| {
                ([8, 13, 18, 23].contains(&i) && *b == b'-')
                    || (!([8, 13, 18, 23].contains(&i))
                        && (b.is_ascii_digit() || (b'a'..=b'f').contains(b)))
            })
    });
    id.ok_or_else(|| RpcError::new(-32001, "trigger token is invalid"))
}

async fn identity() -> Result<HostIdentity, RpcError> {
    tokio::task::spawn_blocking(cmux_host::identity::query)
        .await
        .map_err(|_| RpcError::new(-32001, "host identity unavailable"))?
        .map_err(|_| RpcError::new(-32001, "host identity unavailable"))
}

async fn same_identity(expected: &HostIdentity) -> Result<(), RpcError> {
    if &identity().await? != expected {
        return Err(RpcError::new(-32001, "host identity changed during trigger operation"));
    }
    Ok(())
}

async fn authorize(
    params: &Value,
    operation: &str,
) -> Result<(TriggerScope, HostIdentity), RpcError> {
    let token = string(params, "token", 8192)?;
    let trigger = token_route(&token)?;
    let before = identity().await?;
    let mut op = serde_json::Map::new();
    op.insert("kind".into(), json!(operation));
    op.insert("machine".into(), json!(before.machine.clone()));
    op.insert("workspace".into(), json!(string(params, "workspace", MAX)?));
    op.insert("session".into(), json!(string(params, "session", MAX)?));
    op.insert("delivery".into(), json!(string(params, "delivery", MAX)?));
    op.insert("guestKey".into(), json!(before.guest_key.clone()));
    if operation == "ensure" {
        op.insert("cwd".into(), json!(string(params, "cwd", MAX)?));
        op.insert("harness".into(), json!(string(params, "harness", 256)?));
    } else if operation == "send" {
        op.insert("body".into(), json!(string(params, "body", 1_000_000)?));
        op.insert("quiet".into(), json!(true));
    }
    let url = format!(
        "https://cmux-platform-development.debussy.workers.dev/v1/triggers/{trigger}/authorize"
    );
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(std::time::Duration::from_millis(4500))
        .build()
        .map_err(|_| RpcError::new(-32001, "trigger authorization unavailable"))?;
    let response = client
        .post(url)
        .json(&json!({"token": token, "operation": Value::Object(op)}))
        .send()
        .await
        .map_err(|_| RpcError::new(-32001, "trigger authorization unavailable"))?;
    let status = response.status();
    if !status.is_success() {
        return Err(RpcError::new(-32001, "trigger authorization refused"));
    }
    if response.content_length().is_some_and(|n| n > 128 * 1024) {
        return Err(RpcError::new(-32001, "trigger authorization response is too large"));
    }
    let body = response
        .bytes()
        .await
        .map_err(|_| RpcError::new(-32001, "trigger authorization unavailable"))?;
    if body.len() > 128 * 1024 {
        return Err(RpcError::new(-32001, "trigger authorization response is too large"));
    }
    let envelope: Value = serde_json::from_slice(&body)
        .map_err(|_| RpcError::new(-32001, "trigger authorization refused"))?;
    let principal = envelope.get("principal").unwrap_or(&envelope);
    if !envelope.get("ok").and_then(Value::as_bool).unwrap_or(true) {
        return Err(RpcError::new(-32001, "trigger authorization refused"));
    }
    let after = identity().await?;
    if before != after {
        return Err(RpcError::new(-32001, "host identity changed during authorization"));
    }
    let scoped = scope(principal)?;
    validate_claims(principal, &scoped, trigger, &after)?;
    Ok((scoped, after))
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
    let (scope, identity) = authorize(&params, expected).await?;
    conn.admit_trigger(scope.clone())?;
    match expected {
        "ensure" => {
            same_identity(&identity).await?;
            if let Ok(existing) = hub.resolve(&scope.session) {
                return Ok(json!({
                    "delivery": scope.delivery,
                    "session": {"sessionId": existing.id, "existing": true},
                }));
            }
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
            same_identity(&identity).await?;
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
            same_identity(&identity).await?;
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
