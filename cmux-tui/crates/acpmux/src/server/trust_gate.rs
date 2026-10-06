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
) -> Result<(), RpcError> {
    if !gated(origin, params) {
        return Ok(());
    }
    let Some(paths) = hub.trust_gate() else { return Ok(()) };
    let session_id = match m {
        method::SESSION_PROMPT | method::SESSION_FORK => {
            session_key(params).ok().map(str::to_owned)
        }
        method::MUX_HANDOFF_START => params
            .get("handoffId")
            .and_then(Value::as_str)
            .and_then(|id| hub.handoff_target(id))
            .map(|(target, _)| target),
        _ => return Ok(()),
    };
    // An unknown or remote session: the request's own path answers it (a
    // peer gates what this daemon forwards, `remote_guard::mark_forwarded`).
    let Some(session) = session_id.and_then(|id| hub.resolve(&id).ok()) else { return Ok(()) };
    let meta = session.meta();
    // A fork runs its agent (a Claude fork is primed with a turn) in its own
    // folder, which the remote guard made canonical: that folder answers.
    let fork_cwd = params.get("cwd").and_then(Value::as_str).filter(|_| m == method::SESSION_FORK);
    let cwd = fork_cwd.map_or_else(|| meta.cwd.to_string_lossy().into_owned(), str::to_owned);
    let family = meta.family.clone().unwrap_or_else(|| meta.harness.clone());
    folder_answered(paths, cwd, family).await
}

/// The app's pane, a Web client, and a peer that forwards for either.
fn gated(origin: Origin, params: &Value) -> bool {
    let via = params.pointer("/_meta/acpmux/via").and_then(Value::as_str);
    match origin {
        Origin::LocalApp | Origin::Web => true,
        Origin::Peer => matches!(via, Some("web" | "app")),
        Origin::Local => false,
    }
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
