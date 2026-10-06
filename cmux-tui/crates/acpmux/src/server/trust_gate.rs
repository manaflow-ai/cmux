//! The folder-trust gate: no prompt from the app's agent pane
//! (`Origin::LocalApp`) or a remote browser (`Origin::Web`, and a peer that
//! forwards for its own Web client) reaches an agent while the session's
//! folder has no trust answer.
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
//! answers it. A peer's own request (not marked `via: web`) is not gated: a
//! session on a peer is the peer's to judge, and that peer gates its own
//! LocalApp and Web clients. The gate is on only when the daemon set its paths
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
) -> Result<(), RpcError> {
    let gated = origin == Origin::LocalApp
        || super::remote_guard::control_of(origin, params) == crate::hub::Control::Web;
    if !gated {
        return Ok(());
    }
    let Some(paths) = hub.trust_gate() else { return Ok(()) };
    let session_id = match m {
        method::SESSION_PROMPT => session_key(params).ok().map(str::to_owned),
        method::MUX_HANDOFF_START => params
            .get("handoffId")
            .and_then(Value::as_str)
            .and_then(|id| hub.handoff_target(id))
            .map(|(target, _)| target),
        _ => return Ok(()),
    };
    // An unknown or remote session: the request's own path answers it.
    let Some(session) = session_id.and_then(|id| hub.resolve(&id).ok()) else { return Ok(()) };
    let meta = session.meta();
    let cwd = meta.cwd.to_string_lossy().into_owned();
    let family = meta.family.clone().unwrap_or_else(|| meta.harness.clone());
    let read = tokio::task::spawn_blocking(move || {
        crate::trust::session_level(&paths, &cwd, &family).map(|answer| (cwd, answer))
    })
    .await
    .map_err(|e| RpcError::internal(e.to_string()))?;
    // A record that cannot be read is no answer: the prompt waits for one.
    let (cwd, level) = match read {
        Ok((_, (cwd, level))) => (cwd, level),
        Err(_) => (meta.cwd.to_string_lossy().into_owned(), Level::Unknown),
    };
    let (reason, why) = match level {
        Level::Trusted => return Ok(()),
        Level::Unknown => ("trust.pending", "answer the trust question for the folder first"),
        Level::Untrusted => ("trust.untrusted", "the user chose not to trust the folder"),
    };
    Err(RpcError::invalid_params(format!("{reason}: {why} ({cwd})"))
        .with_data(json!({"reason": reason, "cwd": cwd})))
}
