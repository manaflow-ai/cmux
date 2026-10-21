//! The folder-trust gate: no prompt from the app's agent pane
//! (`Origin::LocalApp`) or a remote browser (`Origin::Web`), or from a peer
//! that forwards for either (`_meta.acpmux.via` = `app` or `web`), reaches an
//! agent while the session's folder has no trust answer.
//!
//! The pane asks "Trust / Don't trust" for a folder whose level is unknown
//! (`crate::trust`). Until the user answers Trust, a `session/prompt` (and the
//! `_acpmux/handoff_start` that sends a capsule as a prompt, and the
//! `_acpmux/btw` that opens a side session and prompts it) for a session in
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
//! app or the CLI. For the same reason an auto-trust rule (`trust_auto.rs`: the person's
//! project roots and organizations) answers only the app's pane: a Web client's folder needs
//! a decision a person made (`trust::web_session_level`). The unix socket (the user's own CLI and TUI) is not gated:
//! it never shows the question, and the user who types there is the one who
//! answers it. A session on a peer is the peer's to judge: this daemon marks
//! what it forwards for its pane (`via: app`) or a Web client (`via: web`),
//! and the peer gates those with its own record. A peer's own request (no
//! mark) is not gated. `_acpmux/warm` starts no agent in such a folder
//! (`hub/warm.rs`), and for a Web client none in a folder only an auto-trust rule trusts.
//! `_acpmux/prewarm` with no folder named checks the folder it picks the same way. The gate is on only when the daemon set its paths
//! (`Hub::set_trust_gate`).

use std::sync::Arc;

use serde_json::{Value, json};

use super::{Origin, session_key};
use crate::hub::Hub;
use crate::rpc::{RpcError, method};
use crate::trust::Level;

/// What the gate let through.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Verdict {
    /// Not gated, or the folder is trusted.
    Trusted,
    /// The person answered Not now for the folder, and the chat runs restricted
    /// (`hub/restricted.rs`): Claude Code from the app's pane, with the setting on.
    Restricted,
}

pub(super) async fn check(
    hub: &Arc<Hub>,
    origin: Origin,
    m: &str,
    params: &Value,
    resolved: Option<&Arc<crate::hub::Session>>,
) -> Result<Verdict, RpcError> {
    if !gated(origin, params) {
        return Ok(Verdict::Trusted);
    }
    let Some(paths) = hub.trust_gate() else { return Ok(Verdict::Trusted) };
    let web = for_web(origin, params);
    // Only the app's own pane opens or runs a restricted chat (`hub/restricted.rs`): never a
    // Web client, and never a peer forwarding for its pane.
    let pane = origin == Origin::LocalApp;
    if m == method::SESSION_NEW {
        if params
            .pointer("/_meta/acpmux/peer")
            .and_then(Value::as_str)
            .is_some_and(|peer| !peer.is_empty())
        {
            return Ok(Verdict::Trusted);
        }
        return check_new(hub, &paths, params, origin.web_class(), web, pane).await;
    }
    if m == method::MUX_PREWARM {
        return check_prewarm(hub, &paths, params, web).await.map(|()| Verdict::Trusted);
    }
    if m == method::MUX_HANDOFF_PREPARE {
        let Some(source) = resolved
            .cloned()
            .or_else(|| session_key(params).ok().and_then(|key| hub.resolve(key).ok()))
        else {
            return Ok(Verdict::Trusted);
        };
        let harness = params.get("harness").and_then(Value::as_str).unwrap_or_default();
        let (family, claude) = resolve_harness(hub, harness).await;
        let meta = source.meta();
        // A restricted chat hands off to a restricted Claude Code chat only (`hub/restricted.rs`).
        let restrictable = meta.restricted && claude && pane;
        return folder_answered(
            paths.clone(),
            meta.cwd.to_string_lossy().into_owned(),
            family,
            web,
            restrictable,
        )
        .await;
    }
    let session_id = match m {
        // A side session (`hub/btw.rs`) starts an agent in its chat's folder and prompts it.
        method::SESSION_PROMPT
        | method::SESSION_FORK
        | method::MUX_BTW
        | method::SESSION_SET_MODE
        | method::SESSION_SET_CONFIG_OPTION
        | method::MUX_SET_TOOLS => session_key(params).ok().map(str::to_owned),
        method::MUX_HANDOFF_START => params
            .get("handoffId")
            .and_then(Value::as_str)
            .and_then(|id| hub.handoff_target(id))
            .map(|(target, _)| target),
        _ => return Ok(Verdict::Trusted),
    };
    // An unknown or remote session: the request's own path answers it (a
    // peer gates what this daemon forwards, `remote_guard::mark_forwarded`).
    let session = resolved.cloned().or_else(|| session_id.and_then(|id| hub.resolve(&id).ok()));
    let Some(session) = session else { return Ok(Verdict::Trusted) };
    let meta = session.meta();
    // A fork runs its agent (a Claude fork is primed with a turn) in its own
    // folder, which the remote guard made canonical: that folder answers.
    let fork_cwd = params.get("cwd").and_then(Value::as_str).filter(|_| m == method::SESSION_FORK);
    let cwd = fork_cwd.map_or_else(|| meta.cwd.to_string_lossy().into_owned(), str::to_owned);
    let family = meta.family.clone().unwrap_or_else(|| meta.harness.clone());
    // A chat in a folder the person did not trust runs restricted (`hub/restricted.rs`); a fork
    // into another folder only when its chat already does (the fork takes its restriction).
    let restrictable =
        pane && (fork_cwd.is_none() || meta.restricted) && hub.restrictable(&meta).await;
    if folder_answered(paths, cwd.clone(), family, web, restrictable).await? == Verdict::Trusted {
        // Trusted since: the chat's next agent starts without the restrictions.
        if meta.restricted && fork_cwd.is_none() {
            hub.set_restricted(&session, false).await;
        }
        return Ok(Verdict::Trusted);
    }
    // A chat that was not restricted yet becomes so before its next agent starts; one that
    // cannot yet (a turn runs, its agent did not end) says so, and the next prompt tries again.
    if meta.restricted || hub.set_restricted(&session, true).await {
        return Ok(Verdict::Restricted);
    }
    Err(not_restricted_yet(&cwd))
}

/// A chat that runs restricted from its next agent on, but whose agent could not end now. Not
/// a trust refusal: the pane keeps Send on, so the person sends again once the chat is idle.
fn not_restricted_yet(cwd: &str) -> RpcError {
    RpcError::invalid_params(format!(
        "restricted.busy: the folder is not trusted, and this chat runs restricted once it is idle; send again then ({cwd})"
    ))
    .with_data(json!({"reason": "restricted.busy", "cwd": cwd}))
}

/// `web`: the prompt came from a Web client or a peer forwarding for one.
pub(crate) async fn check_dispatch(
    hub: &Arc<Hub>,
    gated_request: bool,
    web: bool,
    session: &Arc<crate::hub::Session>,
) -> Result<(), RpcError> {
    if !gated_request {
        return Ok(());
    }
    let Some(paths) = hub.trust_gate() else { return Ok(()) };
    let meta = session.meta();
    // A queued prompt of a chat that is restricted already goes; nothing becomes restricted here.
    let restrictable = !web && meta.restricted;
    folder_answered(
        paths,
        meta.cwd.to_string_lossy().into_owned(),
        meta.family.clone().unwrap_or(meta.harness.clone()),
        web,
        restrictable,
    )
    .await
    .map(|_| ())
}

async fn check_new(
    hub: &Arc<Hub>,
    paths: &crate::trust::Paths,
    params: &Value,
    remote: bool,
    web: bool,
    pane: bool,
) -> Result<Verdict, RpcError> {
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
                return Ok(Verdict::Trusted);
            };
            let family = if family.is_empty() {
                adopt.and_then(|a| a.get("harness")).and_then(Value::as_str).unwrap_or_default()
            } else {
                &family
            };
            hub.adopted_cwd_for_trust(family, id, remote).await?.unwrap_or_default()
        }
    };
    if cwd.is_empty() {
        return Ok(Verdict::Trusted);
    }
    // A preset shapes the command line: its chat is never restricted.
    let preset = meta
        .and_then(|m| m.get("preset"))
        .or_else(|| params.get("preset"))
        .is_some_and(|p| !p.is_null());
    // Adopting a chat that exists keeps the refusal: it was not started restricted.
    let adopting = meta.and_then(|m| m.get("adopt")).is_some_and(|a| !a.is_null());
    let (family, claude) = resolve_harness(hub, &family).await;
    let restrictable = pane && !remote && !web && !preset && !adopting && claude;
    folder_answered(paths.clone(), cwd, family, web, restrictable).await
}

async fn check_prewarm(
    hub: &Arc<Hub>,
    paths: &crate::trust::Paths,
    params: &Value,
    web: bool,
) -> Result<(), RpcError> {
    let Some(cwd) = params.get("cwd").and_then(Value::as_str) else { return Ok(()) };
    let family = params.get("harness").and_then(Value::as_str).unwrap_or_default();
    let (family, _) = resolve_harness(hub, family).await;
    // A pooled agent never runs restricted: a folder the person did not trust warms nothing.
    folder_answered(paths.clone(), cwd.to_owned(), family, web, false).await.map(|_| ())
}

/// The family of the harness named `name` (empty for none), and whether that harness, or the
/// default one for none, runs Claude Code as acpmux does (`HarnessKind::ClaudeStdio`), which
/// can run restricted (`hub/restricted.rs`).
async fn resolve_harness(hub: &Arc<Hub>, name: &str) -> (String, bool) {
    let cfg = hub.config.read().await;
    let profile = if name.is_empty() { cfg.default_harness.as_deref() } else { Some(name) }
        .and_then(|name| cfg.resolve_harness(name).ok());
    let claude = profile
        .as_ref()
        .and_then(|resolved| cfg.harnesses.get(resolved))
        .is_some_and(crate::hub::restricted::supports);
    if name.is_empty() {
        return (String::new(), claude);
    }
    let family = profile
        .and_then(|resolved| {
            cfg.harnesses.get(&resolved).map(|p| crate::config::derive_family(&resolved, p))
        })
        .unwrap_or_else(|| name.to_owned());
    (family, claude)
}

/// A Web client, or a peer that forwards for one: an auto-trust rule is no answer for it
/// (`trust::web_session_level`).
pub(super) fn for_web(origin: Origin, params: &Value) -> bool {
    match origin {
        Origin::Web => true,
        Origin::Peer => params.pointer("/_meta/acpmux/via").and_then(Value::as_str) == Some("web"),
        Origin::LocalApp | Origin::Local => false,
    }
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

/// The folder's verdict for `family`: trusted; restricted, for a folder the person did not
/// trust when the chat can run restricted (`restrictable`) and the setting is on
/// (`hub/restricted.rs`); else the refusal. For `web`, only a person's decision (or an agent's
/// own) answers, never an auto-trust rule.
async fn folder_answered(
    paths: crate::trust::Paths,
    cwd: String,
    family: String,
    web: bool,
    restrictable: bool,
) -> Result<Verdict, RpcError> {
    let asked = cwd.clone();
    let (read, restricted) = tokio::task::spawn_blocking(move || {
        let read = if web {
            crate::trust::web_session_level(&paths, &cwd, &family)
        } else {
            crate::trust::session_level(&paths, &cwd, &family)
        };
        // The setting is read only for a folder the person did not trust.
        let restricted = restrictable
            && matches!(read, Ok((_, Level::Untrusted)))
            && crate::hub::restricted::enabled();
        (read, restricted)
    })
    .await
    .map_err(|e| RpcError::internal(e.to_string()))?;
    // A record that cannot be read is no answer: the prompt waits for one.
    let (cwd, level) = read.unwrap_or((asked, Level::Unknown));
    match level {
        Level::Trusted => Ok(Verdict::Trusted),
        Level::Untrusted if restricted => Ok(Verdict::Restricted),
        level => Err(refusal(level, &cwd)),
    }
}

/// The gate's refusal for a folder at `level` (never `Trusted`).
pub(crate) fn refusal(level: Level, cwd: &str) -> RpcError {
    let (reason, why) = match level {
        Level::Untrusted => ("trust.untrusted", "the user chose not to trust the folder"),
        Level::Unknown | Level::Trusted => {
            ("trust.pending", "answer the trust question for the folder first")
        }
    };
    RpcError::invalid_params(format!("{reason}: {why} ({cwd})"))
        .with_data(json!({"reason": reason, "cwd": cwd}))
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
            // With the setting on, a Claude Code chat in a folder the person did not trust
            // runs restricted (`hub/restricted.rs`): the pane lets it send.
            crate::trust::get(&paths, &cwd).map(|mut reply| {
                if crate::hub::restricted::enabled() {
                    reply["restrictedChats"] = Value::Bool(true);
                }
                reply
            })
        }
    })
    .await
    .map_err(|e| RpcError::internal(e.to_string()))?;
    if setting && reply.is_ok() {
        // A sub-session start waiting on this folder's card goes on (`hub/trust_wait.rs`).
        hub.trust_changed();
        // A restricted chat in a folder trusted now starts its next agent without the
        // restrictions (`hub/restricted.rs`).
        hub.lift_trusted_restrictions();
    }
    reply.map_err(|failure| match failure {
        crate::trust::Failure::Invalid(message) => RpcError::invalid_params(message),
        crate::trust::Failure::Record(message) => RpcError::internal(message),
    })
}
