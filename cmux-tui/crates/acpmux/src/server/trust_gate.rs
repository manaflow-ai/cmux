//! The folder-trust gate: no prompt from the app's agent pane
//! (`Origin::LocalApp`) or a remote browser (`Origin::Web`), or from a peer
//! that forwards for either (`_meta.acpmux.via` = `app` or `web`), reaches an
//! agent while the session's folder has no trust answer.
//!
//! The pane asks "Trust / Don't trust" for a folder whose level is unknown
//! (`crate::trust`). Until the user answers Trust, a `session/prompt` (and the
//! `_acpmux/handoff_start` that sends a capsule as a prompt) for a session in
//! that folder is refused with `data.reason`:
//! - `trust.pending`: no answer yet (the question is open);
//! - `trust.untrusted`: the user answered Don't trust.
//!
//! The level is `trust::session_level`: acpmux's decision, else the session's
//! own agent's level. A record that cannot be read is no answer. The check is
//! here, in the daemon, so a page cannot get around it.
//!
//! A Web client cannot answer the question (`acp.trust.set` is refused for it
//! in `remote_guard.rs`), so its prompts wait for the user's answer in the
//! app or the CLI. The unix socket (the user's own CLI and TUI) is not gated:
//! it never shows the question, and the user who types there is the one who
//! answers it. A session on a peer is the peer's to judge: this daemon marks
//! what it forwards for its pane (`via: app`) or a Web client (`via: web`),
//! and the peer gates those with its own record. A peer's own request (no
//! mark) is not gated. `_acpmux/warm` starts no agent in such a folder
//! (`hub/warm.rs`). The gate is on only when the daemon set its paths
//! (`Hub::set_trust_gate`).

use std::sync::Arc;

use serde_json::{Value, json};

use super::{Origin, session_key};
use crate::hub::Hub;
use crate::rpc::{RpcError, method};
use crate::trust::Level;

pub(super) async fn check(
    hub: &Arc<Hub>,
    origin: Origin,
    m: &str,
    params: &Value,
    resolved: Option<&Arc<crate::hub::Session>>,
) -> Result<(), RpcError> {
    if !gated(origin, params) {
        return Ok(());
    }
    let Some(paths) = hub.trust_gate() else { return Ok(()) };
    if m == method::SESSION_NEW {
        if params
            .pointer("/_meta/acpmux/peer")
            .and_then(Value::as_str)
            .is_some_and(|peer| !peer.is_empty())
        {
            return Ok(());
        }
        return check_new(hub, &paths, params).await;
    }
    if m == method::MUX_PREWARM {
        return check_prewarm(hub, &paths, params).await;
    }
    if m == method::MUX_HANDOFF_PREPARE {
        let Some(source) = resolved
            .cloned()
            .or_else(|| session_key(params).ok().and_then(|key| hub.resolve(key).ok()))
        else {
            return Ok(());
        };
        let harness = params.get("harness").and_then(Value::as_str).unwrap_or_default();
        let family = resolve_family(hub, harness).await;
        return folder_answered(
            paths.clone(),
            source.meta().cwd.to_string_lossy().into_owned(),
            family,
        )
        .await;
    }
    let session_id = match m {
        method::SESSION_PROMPT
        | method::SESSION_FORK
        | method::SESSION_SET_MODE
        | method::SESSION_SET_CONFIG_OPTION => session_key(params).ok().map(str::to_owned),
        method::MUX_HANDOFF_START => params
            .get("handoffId")
            .and_then(Value::as_str)
            .and_then(|id| hub.handoff_target(id))
            .map(|(target, _)| target),
        _ => return Ok(()),
    };
    // An unknown or remote session: the request's own path answers it (a
    // peer gates what this daemon forwards, `remote_guard::mark_forwarded`).
    let session = resolved.cloned().or_else(|| session_id.and_then(|id| hub.resolve(&id).ok()));
    let Some(session) = session else { return Ok(()) };
    let meta = session.meta();
    // A fork runs its agent (a Claude fork is primed with a turn) in its own
    // folder, which the remote guard made canonical: that folder answers.
    let fork_cwd = params.get("cwd").and_then(Value::as_str).filter(|_| m == method::SESSION_FORK);
    let cwd = fork_cwd.map_or_else(|| meta.cwd.to_string_lossy().into_owned(), str::to_owned);
    let family = meta.family.clone().unwrap_or_else(|| meta.harness.clone());
    folder_answered(paths, cwd, family).await
}

pub(crate) async fn check_dispatch(
    hub: &Arc<Hub>,
    gated_request: bool,
    session: &Arc<crate::hub::Session>,
) -> Result<(), RpcError> {
    if !gated_request {
        return Ok(());
    }
    let Some(paths) = hub.trust_gate() else { return Ok(()) };
    let meta = session.meta();
    folder_answered(
        paths,
        meta.cwd.to_string_lossy().into_owned(),
        meta.family.clone().unwrap_or(meta.harness.clone()),
    )
    .await
}

async fn check_new(
    hub: &Arc<Hub>,
    paths: &crate::trust::Paths,
    params: &Value,
) -> Result<(), RpcError> {
    let cwd = params.get("cwd").and_then(Value::as_str).map(str::to_owned);
    let meta = params.get("_meta").and_then(|v| v.get("acpmux"));
    let family = meta
        .and_then(|m| m.get("harness"))
        .and_then(Value::as_str)
        .map(str::to_owned)
        .unwrap_or_default();
    let cwd = match cwd {
        Some(cwd) => cwd,
        None => {
            let adopt = meta.and_then(|m| m.get("adopt"));
            let Some(id) = adopt.and_then(|a| a.get("agentSessionId")).and_then(Value::as_str)
            else {
                return Ok(());
            };
            let family = if family.is_empty() {
                adopt.and_then(|a| a.get("harness")).and_then(Value::as_str).unwrap_or_default()
            } else {
                &family
            };
            hub.adopted_cwd_for_trust(family, id).await?.unwrap_or_default()
        }
    };
    if cwd.is_empty() {
        return Ok(());
    }
    let family = resolve_family(hub, &family).await;
    folder_answered(paths.clone(), cwd, family).await
}

async fn check_prewarm(
    hub: &Arc<Hub>,
    paths: &crate::trust::Paths,
    params: &Value,
) -> Result<(), RpcError> {
    let Some(cwd) = params.get("cwd").and_then(Value::as_str) else { return Ok(()) };
    let family = params.get("harness").and_then(Value::as_str).unwrap_or_default();
    folder_answered(paths.clone(), cwd.to_owned(), resolve_family(hub, family).await).await
}

async fn resolve_family(hub: &Arc<Hub>, name: &str) -> String {
    if name.is_empty() {
        return String::new();
    }
    let cfg = hub.config.read().await;
    cfg.resolve_harness(name)
        .ok()
        .and_then(|resolved| {
            cfg.harnesses.get(&resolved).map(|p| crate::config::derive_family(&resolved, p))
        })
        .unwrap_or_else(|| name.to_owned())
}

/// The app's pane, a Web client, and a peer that forwards for either.
pub(super) fn gated(origin: Origin, params: &Value) -> bool {
    let via = params.pointer("/_meta/acpmux/via").and_then(Value::as_str);
    match origin {
        Origin::LocalApp | Origin::Web => true,
        Origin::Peer => matches!(via, Some("web" | "app")),
        Origin::Local => false,
    }
}

pub(super) fn peer_unsupported(peer: &str) -> RpcError {
    RpcError::invalid_params(format!(
        "trust.peer_unsupported: peer {peer} does not advertise the folder trust gate"
    ))
    .with_data(json!({"reason": "trust.peer_unsupported", "peer": peer}))
}

/// Ok when the folder is trusted for `family`; else the refusal.
async fn folder_answered(
    paths: crate::trust::Paths,
    cwd: String,
    family: String,
) -> Result<(), RpcError> {
    let asked = cwd.clone();
    let read =
        tokio::task::spawn_blocking(move || crate::trust::session_level(&paths, &cwd, &family))
            .await
            .map_err(|e| RpcError::internal(e.to_string()))?;
    // A record that cannot be read is no answer: the prompt waits for one.
    let (cwd, level) = read.unwrap_or((asked, Level::Unknown));
    let (reason, why) = match level {
        Level::Trusted => return Ok(()),
        Level::Unknown => ("trust.pending", "answer the trust question for the folder first"),
        Level::Untrusted => ("trust.untrusted", "the user chose not to trust the folder"),
    };
    Err(RpcError::invalid_params(format!("{reason}: {why} ({cwd})"))
        .with_data(json!({"reason": reason, "cwd": cwd})))
}

/// `acp.trust.get {cwd}` and `acp.trust.set {cwd, level}`: read off the
/// runtime threads, from the gate's files when it is on, so the answer and the
/// gate read one record.
pub(super) async fn answer(hub: &Arc<Hub>, m: &str, params: &Value) -> Result<Value, RpcError> {
    let cwd = params.get("cwd").and_then(Value::as_str).unwrap_or_default().to_owned();
    let level = params.get("level").and_then(Value::as_str).map(str::to_owned);
    let setting = m == method::ACP_TRUST_SET;
    let gate = hub.trust_gate();
    let reply = tokio::task::spawn_blocking(move || {
        let paths = gate
            .or_else(crate::trust::Paths::current)
            .ok_or_else(|| crate::trust::Failure::Record("no home directory".into()))?;
        if setting {
            crate::trust::set(&paths, &cwd, level.as_deref().unwrap_or_default())
        } else {
            crate::trust::get(&paths, &cwd)
        }
    })
    .await
    .map_err(|e| RpcError::internal(e.to_string()))?;
    reply.map_err(|failure| match failure {
        crate::trust::Failure::Invalid(message) => RpcError::invalid_params(message),
        crate::trust::Failure::Record(message) => RpcError::internal(message),
    })
}
