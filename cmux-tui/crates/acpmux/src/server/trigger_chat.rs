//! The server side of the scoped Cloud trigger chat bridge.
//!
//! These methods are deliberately separate from ACP `session/new` and
//! `session/prompt`: callers must present a platform-admitted principal whose
//! machine, chat, delivery, prompt digest, cwd and harness are all fixed.

use super::{Conn, Origin, TriggerScope};
use crate::hub::Hub;
use crate::rpc::{RpcError, method};
use cmux_host::identity::HostIdentity;
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use sha2::Digest;
use std::path::{Path, PathBuf};
use std::sync::Arc;

#[cfg(test)]
#[path = "trigger_chat_tests.rs"]
mod trigger_chat_tests;

const MAX: usize = 4096;
const MAX_PROMPT: usize = 64 * 1024;

fn prompt(value: &Value, key: &str) -> Result<String, RpcError> {
    let text = value
        .get(key)
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty() && s.len() <= MAX_PROMPT)
        .ok_or_else(|| RpcError::invalid_params("trigger prompt is invalid"))?;
    if text.chars().any(|c| c.is_control() && !matches!(c, '\n' | '\r' | '\t')) {
        return Err(RpcError::invalid_params("trigger prompt contains a forbidden control"));
    }
    Ok(text.to_owned())
}

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
        owner: string(p, "owner", MAX)?,
        team: string(p, "team", MAX)?,
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
        || expires.is_none_or(|at| {
            at <= now || issued.is_none_or(|when| at <= when || at - when > 300_000)
        })
    {
        return Err(RpcError::new(-32001, "trigger authorization expired"));
    }
    Ok(())
}

fn token_route(token: &str) -> Result<&str, RpcError> {
    if token.len() > 8192 {
        return Err(RpcError::new(-32001, "trigger token is invalid"));
    }
    let mut parts = token.split('.');
    if parts.next() != Some("ctg1") {
        return Err(RpcError::new(-32001, "trigger token is invalid"));
    }
    let id = parts.next().filter(|id| {
        id.len() == 36
            && id.as_bytes().iter().enumerate().all(|(i, b)| {
                ([8, 13, 18, 23].contains(&i) && *b == b'-')
                    || (!([8, 13, 18, 23].contains(&i))
                        && (b.is_ascii_digit() || (b'a'..=b'f').contains(b)))
            })
    });
    let payload = parts.next().filter(|payload| {
        !payload.is_empty()
            && payload
                .as_bytes()
                .iter()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'))
    });
    let signature = parts.next().filter(|signature| {
        signature.len() == 43
            && signature
                .as_bytes()
                .iter()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'))
    });
    if parts.next().is_some() || id.is_none() || payload.is_none() || signature.is_none() {
        return Err(RpcError::new(-32001, "trigger token is invalid"));
    }
    id.ok_or_else(|| RpcError::new(-32001, "trigger token is invalid"))
}

async fn identity() -> Result<HostIdentity, RpcError> {
    #[cfg(not(target_os = "linux"))]
    {
        return Err(RpcError::new(-32001, "host identity unavailable"));
    }
    #[cfg(target_os = "linux")]
    {
        tokio::task::spawn_blocking(cmux_host::identity::query)
            .await
            .map_err(|_| RpcError::new(-32001, "host identity unavailable"))?
            .map_err(|_| RpcError::new(-32001, "host identity unavailable"))
    }
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
    if params.get("principal").is_some() {
        return Err(RpcError::new(-32001, "trigger principal is server-issued"));
    }
    let token = string(params, "token", 8192)?;
    let trigger = token_route(&token)?;
    // Only the authority embedded in this build can attest a principal. In
    // particular, neither a caller nor a runtime environment variable can
    // redirect a release daemon to the development service.
    let environment = match super::trigger_authority::configured()
        .map_err(|message| RpcError::new(-32001, message))?
    {
        super::trigger_authority::Authority::Production => cmux_host::cloud::wire::Env::Prod,
        super::trigger_authority::Authority::Staging => cmux_host::cloud::wire::Env::Stg,
        super::trigger_authority::Authority::Development => cmux_host::cloud::wire::Env::Dev,
    };
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
        op.insert("body".into(), json!(prompt(params, "body")?));
        op.insert("quiet".into(), json!(true));
    }
    let url = format!("{}/v1/triggers/{trigger}/authorize", environment.platform_origin());
    let client = reqwest::Client::builder()
        .https_only(true)
        .no_proxy()
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
    use futures_util::StreamExt;
    let mut body = Vec::new();
    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk =
            chunk.map_err(|_| RpcError::new(-32001, "trigger authorization unavailable"))?;
        if body.len().saturating_add(chunk.len()) > 128 * 1024 {
            return Err(RpcError::new(-32001, "trigger authorization response is too large"));
        }
        body.extend_from_slice(&chunk);
    }
    let envelope: Value = serde_json::from_slice(&body)
        .map_err(|_| RpcError::new(-32001, "trigger authorization refused"))?;
    let principal = envelope
        .get("principal")
        .filter(|principal| principal.is_object())
        .ok_or_else(|| RpcError::new(-32001, "trigger authorization refused"))?;
    if envelope.get("active").and_then(Value::as_bool) != Some(true) {
        return Err(RpcError::new(-32001, "trigger authorization refused"));
    }
    let after = identity().await?;
    if before != after {
        return Err(RpcError::new(-32001, "host identity changed during authorization"));
    }
    let scoped = scope(principal)?;
    validate_claims(principal, &scoped, trigger, &after)?;
    if scoped.workspace != string(params, "workspace", MAX)?
        || scoped.session != string(params, "session", MAX)?
        || scoped.delivery != string(params, "delivery", MAX)?
    {
        return Err(RpcError::new(-32001, "trigger authorization scope does not match request"));
    }
    if operation == "ensure"
        && (scoped.cwd != string(params, "cwd", MAX)?
            || scoped.harness != string(params, "harness", 256)?)
    {
        return Err(RpcError::new(-32001, "trigger authorization scope does not match request"));
    }
    Ok((scoped, after))
}

fn operation(params: &Value, expected: &str) -> Result<(), RpcError> {
    if params.get("operation").and_then(Value::as_str) != Some(expected) {
        return Err(RpcError::invalid_params(format!("trigger operation must be {expected}")));
    }
    Ok(())
}

fn exact_session(hub: &Hub, id: &str) -> Result<Arc<crate::hub::Session>, RpcError> {
    let session = hub.resolve(id)?;
    if session.id != id {
        return Err(RpcError::not_found("trigger session id is not exact"));
    }
    Ok(session)
}

fn bound_session(hub: &Hub, scope: &TriggerScope) -> Result<Arc<crate::hub::Session>, RpcError> {
    let session = exact_session(hub, &scope.session)?;
    let meta = session.meta();
    if meta.cwd != Path::new(&scope.cwd)
        || meta.harness != scope.harness
        || meta.workspace_id.as_deref() != Some(scope.workspace.as_str())
    {
        return Err(RpcError::new(-32001, "trigger session binding changed"));
    }
    Ok(session)
}

async fn ensure(hub: &Arc<Hub>, scope: &TriggerScope) -> Result<Value, RpcError> {
    if let Ok(session) = exact_session(hub, &scope.session) {
        let meta = session.meta();
        if meta.cwd != Path::new(&scope.cwd)
            || meta.harness != scope.harness
            || meta.workspace_id.as_deref() != Some(scope.workspace.as_str())
        {
            return Err(RpcError::new(-32001, "trigger session binding changed"));
        }
        return Ok(json!({
            "ok": true, "state": "started", "machine": scope.machine,
            "workspace": scope.workspace, "session": session.id, "delivery": scope.delivery,
        }));
    }
    let session = hub
        .new_session_with_id(
            crate::hub::NewRequest {
                harness: Some(scope.harness.clone()),
                name: Some(scope.session.clone()),
                cwd: Some(PathBuf::from(&scope.cwd)),
                workspace_id: Some(scope.workspace.clone()),
                remote: true,
                ..Default::default()
            },
            Some(scope.session.clone()),
        )
        .await?;
    hub.start_in_mode(
        false,
        None,
        &json!({"_meta": {"acpmux": {"trigger": true}}}),
        &session,
        false,
    )
    .await?;
    Ok(json!({
        "ok": true, "state": "started", "machine": scope.machine,
        "workspace": scope.workspace, "session": session.id, "delivery": scope.delivery,
    }))
}

async fn send(hub: &Arc<Hub>, scope: &TriggerScope, body: String) -> Result<Value, RpcError> {
    let session = bound_session(hub, scope)?;
    let prior = hub.trigger_delivery(&session, &scope.delivery);
    let replay = prior.get("turnId").and_then(Value::as_str).is_some();
    if prior.get("error").is_some() {
        return Err(RpcError::new(-32001, "trigger delivery journal is unavailable"));
    }
    // A prompt id may have been consumed by a human or harness. If the durable
    // journal already knows this id, require a complete matching trigger receipt
    // before allowing a resend; a missing digest fails closed.
    if hub.knows_prompt(&session, &scope.delivery, true)
        && (prior.get("promptHash").and_then(Value::as_str) != Some(scope.prompt_hash.as_str())
            || prior.get("turnId").and_then(Value::as_str).is_none())
    {
        return Err(RpcError::new(-32001, "trigger delivery prompt does not match prior delivery"));
    }
    let provenance = json!({
        "kind": "trigger", "triggerId": scope.trigger, "deliveryId": scope.delivery,
        "owner": scope.owner, "team": scope.team, "machine": scope.machine,
        "workspace": scope.workspace, "session": scope.session,
    });
    let provenance = Hub::prompt_provenance(
        &json!({"_meta": {"acpmux": {"provenance": provenance}}}),
        Origin::Local,
        true,
    )?;
    let (accepted_tx, accepted_rx) = tokio::sync::oneshot::channel();
    let delivery = scope.delivery.clone();
    let hub_for_task = hub.clone();
    let session_for_task = session.clone();
    let options = crate::hub::PromptOptions {
        prompt_id: Some(delivery.clone()),
        resend: true,
        control: crate::hub::Control::Web,
        trust_gate: true,
        provenance,
        on_accepted: Some(Box::new(move |receipt| {
            let _ = accepted_tx.send(receipt);
        })),
        ..Default::default()
    };
    tokio::spawn(async move {
        let _ = hub_for_task
            .prompt_with(
                &session_for_task,
                vec![json!({"type": "text", "text": body})],
                "cloud-trigger",
                false,
                options,
            )
            .await;
    });
    let _accepted = tokio::time::timeout(std::time::Duration::from_secs(4), accepted_rx).await.ok();
    // Always reconstruct from the strict journal. This recovers duplicate callbacks
    // whose accepted receipt is null and rejects a callback from another prompt id.
    let mut receipt = validate_durable_receipt(&hub.trigger_delivery(&session, &delivery), scope)?;
    receipt.set("duplicate", Value::Bool(replay));
    Ok(receipt)
}

fn status(hub: &Hub, scope: &TriggerScope) -> Result<Value, RpcError> {
    let session = bound_session(hub, scope)?;
    let mut out =
        validate_durable_receipt(&hub.trigger_delivery(&session, &scope.delivery), scope)?;
    out.set("machine", Value::String(scope.machine.clone()));
    out.set("workspace", Value::String(scope.workspace.clone()));
    out.set("session", Value::String(session.id.clone()));
    Ok(out)
}

/// Accept only the durable receipt reconstructed from the journal. The callback from
/// `prompt_with` is an admission hint and may be a stale or unrelated prompt receipt.
fn validate_durable_receipt(receipt: &Value, scope: &TriggerScope) -> Result<Value, RpcError> {
    if receipt.get("error").is_some() {
        return Err(RpcError::new(-32001, "trigger delivery journal is unavailable"));
    }
    let turn_id = receipt.get("turnId").and_then(Value::as_str).filter(|id| !id.is_empty());
    if turn_id.is_none() {
        return Err(RpcError::new(-32001, "trigger delivery was not durably accepted"));
    }
    if receipt.get("promptHash").and_then(Value::as_str) != Some(scope.prompt_hash.as_str()) {
        return Err(RpcError::new(-32001, "trigger delivery prompt does not match authorization"));
    }
    Ok(receipt.clone())
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
            ensure(hub, &scope).await
        }
        "send" => {
            let body = prompt(&params, "body")?;
            let digest = format!("{:x}", sha2::Sha256::digest(body.as_bytes()));
            if digest != scope.prompt_hash {
                return Err(RpcError::new(-32001, "trigger prompt does not match authorization"));
            }
            same_identity(&identity).await?;
            let result = send(hub, &scope, body).await?;
            let duplicate = result.get("duplicate").and_then(Value::as_bool) == Some(true)
                || result.pointer("/_meta/acpmux/duplicate").and_then(Value::as_bool) == Some(true);
            Ok(json!({
                "ok": true,
                "state": if duplicate { "replayed" } else { "sent" },
                "machine": scope.machine,
                "workspace": scope.workspace,
                "session": scope.session,
                "delivery": scope.delivery,
                "turn": result.get("turnId").cloned().or_else(|| result.pointer("/_meta/acpmux/turnId").cloned()).unwrap_or(Value::Null),
            }))
        }
        "status" => {
            // Keep the status response scoped to the exact session/delivery;
            // no list, owner or machine data is exposed on this RPC.
            same_identity(&identity).await?;
            let requested_turn = string(&params, "turn", MAX)?;
            let result = status(hub, &scope)?;
            if result.get("turnId").and_then(Value::as_str).is_none_or(|id| id != requested_turn) {
                return Err(RpcError::new(-32001, "trigger delivery turn mismatch"));
            }
            let current_state = result.get("state").and_then(Value::as_str).unwrap_or("failed");
            let state = match current_state {
                "running" | "queued" => "running",
                "completed" => "completed",
                "failed" => "failed",
                "unknown" => "failed",
                "attention" => "attention",
                _ => "failed",
            }
            .to_owned();
            let mut result = result;
            if let Some(turn) = result.get("turnId").cloned() {
                result.set("turn", turn);
            }
            result.set("ok", Value::Bool(true));
            result.set("state", Value::String(state.to_owned()));
            result.set("machine", Value::String(scope.machine.clone()));
            result.set("workspace", Value::String(scope.workspace.clone()));
            result.set("session", Value::String(scope.session.clone()));
            Ok(result)
        }
        // `expected` is one of the three above, set from the method just before.
        _ => Err(RpcError::method_not_found(m)),
    }
}
