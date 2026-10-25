//! What a request from a connection that is not the local unix socket (the
//! WebSocket listener: `Origin::Web` and `Origin::LocalApp`) may carry. Such
//! a connection drives agents, but it never makes this machine spawn a
//! process, set a spawn environment, or read or write a path of its choice:
//!
//! - `mcpServers` with any entry, in any request. A stdio MCP server is
//!   `{command, args, env}`, which a harness spawns. acpmux has no daemon-side
//!   list of named MCP servers a caller could pick, so every entry is refused.
//! - `env` in `_acpmux/defaults` and `_acpmux/presets` writes: a spawn env
//!   (`NODE_OPTIONS`, `LD_PRELOAD`, `PATH`) runs code.
//! - `_acpmux/export` with a `dest` (a write anywhere) and `_acpmux/import`
//!   of a path outside acpmux's own bundle directory (a read anywhere).
//! - A folder field (`cwd`, `additionalDirectories`) of `session/new`,
//!   `session/fork`, `session/load`, `session/resume` and `acp.trust.set`
//!   must be an absolute path to an existing directory; the request goes on
//!   with the canonical path (symlinks resolved, no `..`). An `acp.trust.set`
//!   for a peer's session names the peer's folder: it goes on to that peer
//!   unchanged, and the peer's own guard checks the folder there.
//! - A session method acpmux does not handle itself is not passed to the
//!   harness (`requests.rs` catch-all), so no harness extension method can
//!   take caller params that spawn or read. LocalApp may pass
//!   `_acpmux/subagent_stop`, which only stops a task the agent already runs
//!   (`forwards`).
//!
//! - Web only (ACP-REMOTE-GUARD), allow lists: only the `ask` and `deny-all`
//!   policies, rules that cannot auto-approve, the cited asking modes
//!   (`ASKING_MODES`) and the listed config options; every other value,
//!   unknown ones included, is refused. Paths: `session/new`,
//!   `session/set_mode`, `session/set_config_option`, `_acpmux/set_policy`,
//!   `_acpmux/set_default_policy`, `_acpmux/set_rules`, or a defaults or
//!   preset write; and no `_acpmux/directories` listing (answered "Method not found", so
//!   the dashboard falls back to typed paths, which `session/new` checks).
//!   LocalApp keeps both: the daemon cannot see user gestures, and the
//!   native relay enforces a fresh gesture for LocalApp before it sends one.
//! - Web only: no `acp.trust.set` (`trust.remote`); the folder-trust
//!   question is the user's, and the trust gate (`trust_gate.rs`) holds Web
//!   prompts until the user answers it in the app or the CLI.
//! - Web and Peer: no `_acpmux/process/*` (a process's command line and
//!   its kill are local), refused in `processes.rs`, which runs first.
//! - Web only: no `_acpmux/set_tools` (`tools.remote`). Turning an MCP
//!   server on makes the harness start the stdio command the user's config
//!   names on this machine; unlike a mode, no asking table makes that safe.
//! - Web and Peer: no `_acpmux/btw` (`btw.remote`). A side session is a new
//!   session on this machine, in the chat's harness and folder, with a policy
//!   that approves reads: the app and the unix socket only.
//! - Web and LocalApp: no `_acpmux/peer_add`, `_acpmux/peer_remove` or
//!   `_acpmux/peer_lease` (they change which machines this daemon reaches
//!   with the user's ssh keys and tokens); `peer_reconnect` only retries a
//!   configured peer.
//! - Web only: no `_acpmux/file_put` (`filePut.remote`). It writes a file
//!   of the caller's bytes on this machine (under acpmux's own `uploads`
//!   folder, never a path of the caller's), for a file the person dropped
//!   into a chat in the app: the unix socket, the app (LocalApp) and a peer
//!   forwarding for either take it; a peer forwarding for its own Web client
//!   does not. The app sends it over the unix socket after the person's
//!   gesture, but a LocalApp page could send it itself with no gesture: that
//!   is accepted, since the page can already prompt the agent, and it writes
//!   at most `MAX_BYTES` owner-only into a fresh folder under `uploads`.
//! - Web only: no `_acpmux/workflows` (`workflows.remote`): it names the
//!   daemon's chats and their workflows' args.
//! - Web only: no `_acpmux/media_open` or `_acpmux/media_range`
//!   (`mediaRead.remote`). They read a chat's images and videos on this
//!   machine for the app's pane (`hub/media_read.rs`): the unix socket, the
//!   app and a peer forwarding for either.
//! - Web only: no `_acpmux/subagent_transcript` (`transcriptRead.remote`),
//!   which reads a subagent's transcript from the chat's Claude store
//!   (`hub/subagent_transcript.rs`): the unix socket, the app and a peer
//!   forwarding for either.
//!
//! The unix socket keeps today's behavior.

use crate::no_panic::JsonExt;
use crate::rpc::{RpcError, method};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

/// Whether a session method acpmux does not handle itself goes on to the
/// harness from `origin`: anything from the unix socket, and from the app only
/// the stop of a running background subagent (no params that spawn or read).
pub(super) fn forwards(origin: super::Origin, m: &str) -> bool {
    use super::Origin::{Local, LocalApp};
    origin == Local || (origin == LocalApp && m == method::MUX_SUBAGENT_STOP)
}

/// The rules a control request from `origin` runs under. A proven peer
/// forwarding for its own Web client marks it `_meta.acpmux.via = "web"`.
/// `auth` is the proof the connection presented: an unauthenticated one is
/// held to the Web's rules whatever its origin (and `check` refuses it).
pub(super) fn control_of(
    origin: super::Origin,
    auth: super::ConnAuth,
    params: &Value,
) -> crate::hub::Control {
    use crate::hub::Control;
    if !auth.authenticated() {
        return Control::Web;
    }
    match origin {
        super::Origin::Local | super::Origin::LocalApp => Control::Local,
        super::Origin::Web => Control::Web,
        super::Origin::Peer
            if params.pointer("/_meta/acpmux/via").and_then(Value::as_str) == Some("web") =>
        {
            Control::Web
        }
        super::Origin::Peer => Control::Peer,
    }
}

/// A request forwarded to a peer, which serves this daemon as Peer: one
/// this daemon holds to the Web's rules says so, and the peer applies them.
/// One from the app's pane says `via: app`, so the peer's folder-trust gate
/// (`trust_gate.rs`) holds it as it holds its own pane's.
pub(super) fn mark_forwarded(
    origin: super::Origin,
    auth: super::ConnAuth,
    params: &Value,
    forwarded: &mut Value,
) {
    // A peer takes a prompt's provenance from its own unix socket only (prompt_provenance.rs):
    // the prompt goes there without it.
    if let Some(mux) = forwarded.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
        mux.remove("provenance");
    }
    if control_of(origin, auth, params) == crate::hub::Control::Web {
        crate::hub::merge_mux_meta(forwarded, serde_json::json!({"via": "web"}));
    } else if origin == super::Origin::LocalApp {
        crate::hub::merge_mux_meta(forwarded, serde_json::json!({"via": "app"}));
    }
}

/// Why a remote `session/new` was refused, in `data.reason`: the daemon that forwarded it
/// turns each into a command that works (`remote_new_hint.rs`).
pub(crate) const POLICY_REFUSED: &str = "remote.policy_refused";
pub(crate) const MODE_REFUSED: &str = "remote.mode_refused";
pub(crate) const CWD_MISSING: &str = "remote.cwd_missing";
pub(crate) const CWD_OUTSIDE_ROOTS: &str = "remote.cwd_outside_roots";

fn refused(what: &str) -> RpcError {
    RpcError::invalid_params(format!(
        "{what} is accepted only over the local unix socket, never from a WebSocket connection"
    ))
}

/// Check (and canonicalize the folder fields of) a request from a
/// connection that is not the unix socket. A refused remote `session/new` says how this daemon
/// served the caller (`data.servedAs`: `peer` or `remote`), for the forwarding daemon's hint
/// (`remote_new_hint.rs`).
pub(super) async fn check(
    hub: &std::sync::Arc<crate::hub::Hub>,
    origin: super::Origin,
    auth: super::ConnAuth,
    m: &str,
    params: &mut Value,
) -> Result<(), RpcError> {
    let served = match control_of(origin, auth, params) {
        crate::hub::Control::Peer => "peer",
        _ => "remote",
    };
    let mut result = check_inner(hub, origin, auth, m, params).await;
    if m == method::SESSION_NEW
        && origin.web_class()
        && let Err(e) = &mut result
        && let Some(Value::Object(data)) = &mut e.data
        && data.get("reason").and_then(Value::as_str).is_some_and(|r| r.starts_with("remote."))
    {
        data.insert("servedAs".into(), Value::from(served));
    }
    result
}

async fn check_inner(
    hub: &std::sync::Arc<crate::hub::Hub>,
    origin: super::Origin,
    auth: super::ConnAuth,
    m: &str,
    params: &mut Value,
) -> Result<(), RpcError> {
    // The mode rules below give an authenticated connection more (any mode
    // of the Codex bridge, `Hub::any_mode_for_web`): none without a proof.
    if !auth.authenticated() {
        return Err(super::conn_auth::refused());
    }
    let web = origin.web_class();
    // Taking over a watched conversation starts its harness on this machine (`hub/watch.rs`):
    // only a local client does that.
    if web && m == method::MUX_WATCH_TAKE_OVER {
        return Err(RpcError::new(-32602, "a watched chat is taken over only on this machine")
            .with_data(serde_json::json!({"reason": "watch.origin_refused"})));
    }
    if m == method::SESSION_CANCEL && web {
        check_cancel_ownership(hub, params)?;
    }
    // A per-session env is set over the unix socket only (session_env.rs).
    if matches!(m, method::SESSION_NEW | method::SESSION_FORK)
        && crate::session_env::present(params.pointer("/_meta/acpmux"))
    {
        return Err(crate::session_env::origin_refused());
    }
    // So is a chat's route: it decides where the harness sends its model traffic.
    if m == method::SESSION_NEW
        && params
            .pointer("/_meta/acpmux/route")
            .or_else(|| params.get("route"))
            .is_some_and(|v| !v.is_null())
    {
        return Err(RpcError::new(
            -32602,
            "a session route is accepted only over the local unix socket",
        )
        .with_data(serde_json::json!({"reason": "route.origin_refused"})));
    }
    // So is a prompt's provenance (prompt_provenance.rs): no remote text passes as an agent's.
    // Nor does the app pane's: its reply in place is no prompt (`app_reply.rs`).
    if m == method::SESSION_PROMPT
        && crate::prompt_provenance::present(params.pointer("/_meta/acpmux"))
    {
        return Err(crate::prompt_provenance::origin_refused());
    }
    // And so is taking an agent message back (`hub/withdraw.rs`).
    if m == method::MUX_PROMPT_WITHDRAW {
        return Err(crate::prompt_provenance::withdraw_origin_refused());
    }
    // A paused agent pair is the person's to resume, on this machine (`hub/agent_pairs.rs`).
    if m == method::MUX_AGENT_PAIR_RESUME && origin.web_class() {
        return Err(RpcError::invalid_params(
            "resuming agent pairs is accepted only from this machine's app or unix socket",
        ));
    }
    // Which machines this daemon reaches with the user's ssh keys and
    // tokens changes over the unix socket only (LocalApp included).
    if matches!(m, "_acpmux/peer_add" | "_acpmux/peer_remove" | "_acpmux/peer_lease") {
        return Err(refused("changing peers"));
    }
    // The native relay reads the guard's own table and lists over the unix
    // socket; no WebSocket origin (LocalApp and Peer included) gets them.
    if m == method::MUX_WEB_MODES {
        return Err(refused("_acpmux/web_modes"));
    }
    // The listener's own credential changes over the unix socket only.
    if m == method::MUX_WEB_TOKEN_ROTATE {
        return Err(refused("rotating the web token"));
    }
    // A side session starts a new local session that approves reads (`hub/btw.rs`):
    // never for a Web connection or a peer, whatever the chat.
    if m == method::MUX_BTW && origin.web_class() {
        return Err(RpcError::invalid_params(
            "btw.remote: a side session is opened only in the app or over the local unix socket",
        )
        .with_data(serde_json::json!({"reason": "btw.remote"})));
    }
    if non_empty(params.get("mcpServers")) || non_empty(params.pointer("/_meta/acpmux/mcpServers"))
    {
        return Err(refused("mcpServers"));
    }
    let set_env = params.get("set").and_then(|s| s.get("env")).is_some_and(|v| !v.is_null());
    if (m == method::MUX_DEFAULTS || m == method::MUX_PRESETS) && set_env {
        return Err(refused("a spawn env"));
    }
    if m == method::MUX_EXPORT && params.get("dest").is_some_and(|v| !v.is_null()) {
        return Err(refused("an export dest"));
    }
    if m == method::MUX_IMPORT {
        let path = params.get("path").and_then(Value::as_str).unwrap_or_default();
        let bundles = crate::config::home().join("bundles");
        let inside =
            match (tokio::fs::canonicalize(path).await, tokio::fs::canonicalize(&bundles).await) {
                (Ok(p), Ok(b)) => p.starts_with(&b),
                _ => false,
            };
        if !inside {
            return Err(refused("an import from outside acpmux's bundle directory"));
        }
    }
    // A new session's folder is judged first, so one refusal names every field the caller
    // must change; nothing is made for a start the policy or mode check refuses anyway.
    let mut deferred = None;
    if web {
        let peer = control_of(origin, auth, params) == crate::hub::Control::Peer;
        match web_only(m, params, peer) {
            Err(e) if m == method::SESSION_NEW => deferred = Some(e),
            other => other?,
        }
        // A remote-origin session (a Web device, or a peer) never resumes a
        // local harness session (REMOTE-FLOOR v3, D13).
        if m == method::SESSION_NEW
            && params.pointer("/_meta/acpmux/adopt").is_some_and(|v| !v.is_null())
        {
            return Err(RpcError::invalid_params(
                "a remote device cannot adopt a local agent session; start a new chat from this device",
            )
            .with_data(serde_json::json!({"reason": "remote.adopt_refused"})));
        }
    }
    // The pane's Trust for a chat on a peer names a folder on that peer, which this machine
    // may not have: the set is forwarded whole (`peer_forward.rs`), and the peer, which serves
    // it as Peer, checks the folder on its own disk. Only its spelling is checked here.
    let peers_folder = m == method::ACP_TRUST_SET && names_a_peers_session(hub, params);
    if peers_folder
        && let Some(cwd) = params.get("cwd").filter(|v| !v.is_null())
        && !cwd.as_str().is_some_and(|c| Path::new(c).is_absolute())
    {
        return Err(folder_refused("cwd"));
    }
    let folders = !peers_folder
        && matches!(
            m,
            method::SESSION_NEW
                | method::SESSION_FORK
                | method::SESSION_LOAD
                | method::SESSION_RESUME
                | method::ACP_TRUST_SET
        );
    if folders {
        // A Web folder must also sit inside a root (`web_roots`); LocalApp
        // keeps the native relay's pane roots (no daemon root check).
        let roots = if web { Some(web_roots(hub).await) } else { None };
        let inside = |c: &str| {
            roots.as_ref().is_none_or(|r| r.iter().any(|root| Path::new(c).starts_with(root)))
        };
        // The owner's own daemon starting a session: told the configured roots when its
        // folder is outside them, and a missing folder inside one is made for it.
        let peer_new = m == method::SESSION_NEW
            && control_of(origin, auth, params) == crate::hub::Control::Peer;
        let told = if peer_new { Some(configured_web_roots(hub).await) } else { None };
        let outside = |field: &str| outside_roots(field, told.as_deref());
        if let Some(cwd) = params.get("cwd").filter(|v| !v.is_null()) {
            let cwd = cwd.as_str().ok_or_else(|| folder_refused("cwd"))?;
            let canonical = match canonical_dir(cwd).await {
                Some(canonical) => Some(canonical),
                None if peer_new => {
                    let roots = roots.as_deref().unwrap_or_default();
                    let made = make_inside_root(cwd, roots, deferred.is_none()).await;
                    made.map_err(|e| e.unwrap_or_else(|| outside("cwd")))?
                }
                None => return Err(folder_refused("cwd")),
            };
            if let Some(canonical) = canonical {
                if !inside(&canonical) {
                    return Err(outside("cwd"));
                }
                params.set("cwd", Value::String(canonical));
            }
        } else if web && m == method::SESSION_NEW {
            // An absent cwd means the home directory, which is never a root. A proven
            // peer (the owner's own daemon) gets a scratch folder named after the
            // session instead: "acpmux is too belt and suspenders there" (Leo).
            if control_of(origin, auth, params) != crate::hub::Control::Peer {
                return Err(outside("cwd"));
            }
            if deferred.is_none() {
                let scratch = peer_scratch(params).await?;
                params.set("cwd", Value::String(scratch));
            }
        }
        if let Some(dirs) = params.get("additionalDirectories").filter(|v| !v.is_null()) {
            let list = dirs.as_array().ok_or_else(|| folder_refused("additionalDirectories"))?;
            let mut out = Vec::with_capacity(list.len());
            for d in list {
                let d = d.as_str().ok_or_else(|| folder_refused("additionalDirectories"))?;
                let c = canonical_dir(d)
                    .await
                    .ok_or_else(|| folder_refused("additionalDirectories"))?;
                if !inside(&c) {
                    return Err(outside("additionalDirectories"));
                }
                out.push(Value::String(c));
            }
            params.set("additionalDirectories", Value::Array(out));
        }
    }
    if let Some(e) = deferred {
        return Err(e);
    }
    // The folder-trust question is the user's: a remote browser cannot answer
    // it for itself (`trust_gate.rs`). After the folder checks, so a bad path
    // is still refused as one.
    if m == method::ACP_TRUST_SET && control_of(origin, auth, params) == crate::hub::Control::Web {
        return Err(RpcError::invalid_params(
            "trust.remote: the folder's trust is answered only in the app or over the local unix socket",
        )
        .with_data(serde_json::json!({"reason": "trust.remote"})));
    }
    // An MCP server turned on runs its configured command here: the app and
    // the unix socket only (a peer forwarding for its own Web client too).
    if m == method::MUX_SET_TOOLS && control_of(origin, auth, params) == crate::hub::Control::Web {
        return Err(RpcError::invalid_params(
            "tools.remote: a chat's tools are turned on or off only in the app or over the local unix socket",
        )
        .with_data(serde_json::json!({"reason": "tools.remote"})));
    }
    // A dropped file is saved from the app or the unix socket only (`hub/file_uploads.rs`).
    if matches!(
        m,
        method::MUX_FILE_PUT
            | method::MUX_FILE_PUT_BEGIN
            | method::MUX_FILE_PUT_CHUNK
            | method::MUX_FILE_PUT_FINISH
            | method::MUX_FILE_PUT_CANCEL
    ) && control_of(origin, auth, params) == crate::hub::Control::Web
    {
        return Err(RpcError::invalid_params(
            "filePut.remote: a file is saved for a chat only from the app or over the local unix socket",
        )
        .with_data(serde_json::json!({"reason": "filePut.remote"})));
    }
    // So is a chat's media read (`hub/media_read.rs`).
    if matches!(m, method::MUX_MEDIA_OPEN | method::MUX_MEDIA_RANGE)
        && control_of(origin, auth, params) == crate::hub::Control::Web
    {
        return Err(RpcError::invalid_params(
            "mediaRead.remote: a chat's media is read only for the app or over the local unix socket",
        )
        .with_data(serde_json::json!({"reason": "mediaRead.remote"})));
    }
    // And a subagent's transcript (`hub/subagent_transcript.rs`).
    if m == method::MUX_SUBAGENT_TRANSCRIPT
        && control_of(origin, auth, params) == crate::hub::Control::Web
    {
        return Err(RpcError::invalid_params(
            "transcriptRead.remote: a subagent's transcript is read only for the app or over the local unix socket",
        )
        .with_data(serde_json::json!({"reason": "transcriptRead.remote"})));
    }
    // The daemon's workflows name its chats and their workflows' args
    // (`hub/workflow_index.rs`): the app and the unix socket only.
    if m == method::MUX_WORKFLOWS && control_of(origin, auth, params) == crate::hub::Control::Web {
        return Err(RpcError::invalid_params(
            "workflows.remote: the daemon's workflows are listed only for the app or over the local unix socket",
        )
        .with_data(serde_json::json!({"reason": "workflows.remote"})));
    }
    // After the folder checks: what the request starts from, and its mode.
    if web {
        web_starts_asking(hub, control_of(origin, auth, params), m, params).await?;
    }
    Ok(())
}

/// Whether the request's session lives on a peer: what `peer_forward::forward` forwards an
/// `acp.trust.*` request on. A session this daemon holds, an unknown key or none is not one.
fn names_a_peers_session(hub: &crate::hub::Hub, params: &Value) -> bool {
    super::session_key(params)
        .is_ok_and(|key| hub.resolve(key).is_err() && hub.resolve_remote(key).is_some())
}

/// The folder an `acp.trust.set` from a connection that is not the unix socket records on this
/// daemon: one `check` made canonical (inside a root for a Web or Peer connection), or none.
/// `check` passes a peer's folder on unchecked for the peer to judge; if that peer's session is
/// gone before the forward, the set lands here and is refused rather than recorded unchecked.
pub(super) async fn local_trust_folder(
    hub: &std::sync::Arc<crate::hub::Hub>,
    origin: super::Origin,
    params: &Value,
) -> Result<(), RpcError> {
    let Some(cwd) = params.get("cwd").filter(|v| !v.is_null()) else { return Ok(()) };
    let cwd = cwd.as_str().ok_or_else(|| folder_refused("cwd"))?;
    if canonical_dir(cwd).await.as_deref() != Some(cwd) {
        return Err(folder_refused("cwd"));
    }
    if origin.web_class()
        && !web_roots(hub).await.iter().any(|root| Path::new(cwd).starts_with(root))
    {
        return Err(outside_roots("cwd", None));
    }
    Ok(())
}

/// A remote connection may stop only a session that was created by a remote
/// origin. Local-origin sessions belong to the person at this daemon, even
/// when a Web/Peer caller can resolve their id.
fn check_cancel_ownership(
    hub: &std::sync::Arc<crate::hub::Hub>,
    params: &Value,
) -> Result<(), RpcError> {
    let key = super::session_key(params)?;
    match hub.resolve(key) {
        Ok(session) if session.meta().remote_origin => Ok(()),
        Ok(_) => Err(
            RpcError::invalid_params(
                "session/cancel is refused for a local-origin session; only its local owner may cancel it",
            )
            .with_data(serde_json::json!({"reason": "remote.session_cancel_ownership"})),
        ),
        Err(_) if hub.resolve_remote(key).is_some() => Ok(()),
        Err(e) => Err(RpcError::invalid_params(format!(
            "session/cancel from a remote WebSocket connection is refused: the session cannot be resolved ({})",
            e.message
        ))),
    }
}

/// The asking modes for `family`: the merged table (`web_modes.rs`).
async fn asking_modes(hub: &std::sync::Arc<crate::hub::Hub>, family: &str) -> Vec<String> {
    hub.web_modes().modes(family).to_vec()
}

fn family_of(m: &crate::store::SessionMeta) -> String {
    crate::web_modes::family_of(m)
}

/// Whether a session's mode asks: none reported, or listed for its family.
async fn mode_asks(hub: &std::sync::Arc<crate::hub::Hub>, m: &crate::store::SessionMeta) -> bool {
    hub.any_mode_for_web(m) || hub.web_modes().session_asks(m)
}

/// After a request ran: every reply to a non-unix connection is redacted
/// (only the unix socket reads a token back), and a mode or option set
/// re-checks the session's Web control (a set from the unix socket or the
/// local app to an asking mode restores it; any set that leaves the table
/// ends it).
pub(super) fn after(
    hub: &std::sync::Arc<crate::hub::Hub>,
    origin: super::Origin,
    m: &str,
    key: Option<&str>,
    reply: &mut Result<Value, RpcError>,
) {
    // A set from the unix socket or the local app to an asking mode clears
    // the sticky flag; any write that leaves the table set it already
    // (`Hub::write_mode_state`).
    if matches!(m, method::SESSION_SET_MODE | method::SESSION_SET_CONFIG_OPTION)
        && !origin.web_class()
        && reply.is_ok()
        && let Some(s) = key.and_then(|k| hub.resolve(k).ok())
    {
        hub.restore_web_control(&s);
    }
    if origin != super::Origin::Local
        && let Ok(v) = reply
    {
        super::redact::redact_for_remote(m, v);
    }
}

/// A new Web session in a mode that does not ask is moved to its family's
/// asking default; a family with none (unknown) is ended and refused.
pub(super) async fn settle_web_session_mode(
    hub: &std::sync::Arc<crate::hub::Hub>,
    s: &std::sync::Arc<crate::hub::Session>,
) -> Result<(), RpcError> {
    // The Codex bridge takes any mode from an authenticated Web connection
    // (`any_mode_for_web`), but a session the Web STARTS begins in a mode
    // that asks before every change (`BRIDGE_ASKING_MODES`), never in the
    // bridge's own default (`agent`: edits and commands without asking).
    if hub.any_mode_for_web(&s.meta()) {
        let asks = |m: &crate::store::SessionMeta| {
            crate::web_modes::mode_of(m)
                .is_some_and(|mode| crate::web_modes::BRIDGE_ASKING_MODES.contains(&mode.as_str()))
        };
        if asks(&s.meta()) {
            return Ok(());
        }
        let Some(&start) = crate::web_modes::BRIDGE_ASKING_MODES.first() else {
            let _ = hub.kill(s, true).await;
            return Err(no_reviewed_asking_mode());
        };
        if hub.set_mode(s, start).await.is_err() || !asks(&s.meta()) {
            let _ = hub.kill(s, true).await;
            return Err(no_reviewed_asking_mode());
        }
        hub.restore_web_control(s);
        return Ok(());
    }
    if mode_asks(hub, &s.meta()).await {
        return Ok(());
    }
    let Some(default) = asking_modes(hub, &family_of(&s.meta())).await.into_iter().next() else {
        let _ = hub.kill(s, true).await;
        return Err(no_reviewed_asking_mode());
    };
    if hub.set_mode(s, &default).await.is_err() || !mode_asks(hub, &s.meta()).await {
        let _ = hub.kill(s, true).await;
        return Err(no_reviewed_asking_mode());
    }
    // The daemon's own move to the asking default clears the flag its
    // starting mode set.
    hub.restore_web_control(s);
    Ok(())
}

fn no_reviewed_asking_mode() -> RpcError {
    RpcError::invalid_params(
        "this harness has no reviewed asking mode for a remote WebSocket connection",
    )
    .with_data(serde_json::json!({"reason": "remote.mode_not_asking"}))
}

/// What a Web (remote-origin) connection may never do; LocalApp and the
/// unix socket may. The daemon cannot see user gestures: for LocalApp the
/// native relay enforces a fresh gesture before it sends a policy that
/// skips asking.
fn web_only(m: &str, params: &Value, peer: bool) -> Result<(), RpcError> {
    let refused = |what: &str| {
        RpcError::invalid_params(format!(
            "{what} is accepted only from the local app or the unix socket, never from a remote WebSocket connection"
        ))
    };
    let because =
        |what: &str, reason: &str| refused(what).with_data(serde_json::json!({"reason": reason}));
    // Absent: nothing is set. Present: one of the asking policies, exactly
    // (`ask`, `deny-all`; the person rule's list, `hub/person.rs`).
    let policy_ok = crate::hub::person::asking_policy_value;
    let policy_refused =
        || because("a permission policy other than ask or deny-all", POLICY_REFUSED);
    if m == method::SESSION_NEW
        && crate::web_modes::MODE_FIELDS.iter().any(|f| {
            params.get(*f).is_some() || params.pointer(&format!("/_meta/acpmux/{f}")).is_some()
        })
    {
        return Err(because("a mode at session start", MODE_REFUSED));
    }
    // Defaults and preset writes: only the fields known not to shape what
    // runs without asking (no `mode`, `env`, `args`, unknown fields).
    let set_keys: &[&str] = match m {
        method::MUX_DEFAULTS => &["model", "effort", "policy", "prefer"],
        method::MUX_PRESETS => &["harness", "model", "effort", "policy", "description"],
        _ => &["*"],
    };
    if set_keys != ["*"]
        && let Some(set) = params.get("set").and_then(Value::as_object)
        && set.keys().any(|k| !set_keys.contains(&k.as_str()))
    {
        return Err(refused("this defaults or preset field"));
    }
    if m == method::MUX_WARM
        && params
            .as_object()
            .is_some_and(|o| o.keys().any(|k| !matches!(k.as_str(), "sessionIds" | "limit")))
    {
        return Err(refused("this warm field"));
    }
    match m {
        // A proven peer (`Control::Peer`: the owner's own daemon, by the peer token
        // or a `client` pairing) starts a session with any policy, as the same user
        // would over ssh: "acpmux is too belt and suspenders there" (Leo). Its
        // modes, rules, defaults and presets keep the rules below.
        method::SESSION_NEW if peer => Ok(()),
        method::SESSION_NEW
            if !policy_ok(params.get("policy"))
                || !policy_ok(params.pointer("/_meta/acpmux/policy")) =>
        {
            Err(policy_refused())
        }
        method::MUX_SET_POLICY | "_acpmux/set_default_policy"
            if !policy_ok(params.get("policy")) =>
        {
            Err(policy_refused())
        }
        method::MUX_DEFAULTS | method::MUX_PRESETS if !policy_ok(params.pointer("/set/policy")) => {
            Err(policy_refused())
        }
        method::MUX_SET_RULES
            if !crate::hub::person::rules_cannot_auto_approve(params.get("rules")) =>
        {
            Err(refused("a permission rule that could auto-approve"))
        }
        "_acpmux/directories" => Err(RpcError::method_not_found(
            "_acpmux/directories (not served to a remote WebSocket connection)",
        )),
        _ => Ok(()),
    }
}

fn asking_policy(p: crate::config::PermissionPolicy) -> bool {
    matches!(p, crate::config::PermissionPolicy::Ask | crate::config::PermissionPolicy::DenyAll)
}

/// What a Web request starts from must ask:
/// - session/new with no policy runs with `ask`, never the daemon default or
///   a preset's or a family default's policy (an explicit policy wins over
///   both in `new_session`);
/// - fork, load, resume and a handoff are REFUSED (not downgraded) when the
///   source session's effective policy skips asking or its mode is a known
///   permissive one: a downgrade could not reach a mode held inside the
///   harness, which a fork copies.
async fn web_starts_asking(
    hub: &std::sync::Arc<crate::hub::Hub>,
    control: crate::hub::Control,
    m: &str,
    params: &mut Value,
) -> Result<(), RpcError> {
    // A remote chain never resumes a local harness session (REMOTE-FLOOR v3).
    let web = control == crate::hub::Control::Web;
    // On a dedicated agent VM (vmHost, not a Mac) the owner's peer daemon's
    // session with no policy stays without one: `requests.rs` starts it
    // approve-all (hub/remote_sandbox.rs `vm_host_peer_approves`).
    let vm_host_peer = crate::hub::vm_host_peer_approves(
        hub.config.read().await.vm_host,
        cfg!(target_os = "macos"),
        control == crate::hub::Control::Peer,
    );
    if m == method::SESSION_NEW {
        let meta = params.pointer("/_meta/acpmux");
        let pick = |key: &str| {
            meta.and_then(|m| m.get(key))
                .and_then(Value::as_str)
                .map(str::to_owned)
                .or_else(|| params.get(key).and_then(Value::as_str).map(str::to_owned))
        };
        let cwd = params.get("cwd").and_then(Value::as_str).map(Path::new).map(Path::to_path_buf);
        let (family, any_mode) =
            hub.preflight_remote_new(pick("harness"), pick("preset"), pick("model"), cwd).await?;
        if !any_mode && asking_modes(hub, &family).await.is_empty() {
            return Err(no_reviewed_asking_mode());
        }
    }
    if m == method::SESSION_NEW
        && !vm_host_peer
        && params.get("policy").is_none_or(Value::is_null)
        && params.pointer("/_meta/acpmux/policy").is_none_or(Value::is_null)
    {
        // Fail closed: params that are not an object cannot carry the forced policy.
        if !params.set("policy", Value::String("ask".into())) {
            return Err(RpcError::invalid_params("session/new params must be an object"));
        }
    }
    let copies = matches!(
        m,
        method::SESSION_FORK
            | method::SESSION_LOAD
            | method::SESSION_RESUME
            | method::MUX_HANDOFF_PREPARE
    );
    let sets_mode = matches!(m, method::SESSION_SET_MODE | method::SESSION_SET_CONFIG_OPTION);
    if copies
        && crate::web_modes::MODE_FIELDS.iter().any(|f| {
            params.get(*f).is_some() || params.pointer(&format!("/_meta/acpmux/{f}")).is_some()
        })
    {
        return Err(RpcError::invalid_params(format!(
            "{m} from a remote WebSocket connection is refused: it carries a mode field"
        )));
    }
    // Web CONTROL of a session (not reads) needs its current mode in the
    // asking table and no drift since (`hub/web_control.rs`); the hub checks
    // again at dispatch.
    let controls = matches!(
        m,
        method::SESSION_PROMPT
            | method::SESSION_CANCEL
            | method::MUX_QUEUE_EDIT
            | method::MUX_PERMISSION_RESPOND
            | method::MUX_PERMISSION_GROUP_RESPOND
    );
    if m == method::MUX_HANDOFF_START && control == crate::hub::Control::Web {
        // The handoff prompts its target: the same rule as a prompt there.
        // An unknown handoff is the handler's not-found.
        let Some((target, draft)) =
            params.get("handoffId").and_then(Value::as_str).and_then(|id| hub.handoff_target(id))
        else {
            return Ok(());
        };
        let t = hub.resolve(&target).map_err(|e| {
            RpcError::invalid_params(format!(
                "{m} from a remote WebSocket connection is refused: the handoff's target cannot be resolved ({})",
                e.message
            ))
        })?;
        // A NEW target (a draft, never prompted, never drifted) in its
        // harness's own mode is moved to the asking default, like a new Web
        // session; a family with none is ended and refused.
        if let Err(e) = hub.web_control_check(&t, control) {
            let not_asking = e.data.as_ref().and_then(|d| d.get("reason"))
                == Some(&Value::from("remote.mode_not_asking"));
            if !(draft && not_asking) {
                return Err(e);
            }
            settle_web_session_mode(hub, &t).await?;
        } else if draft && hub.any_mode_for_web(&t.meta()) {
            // A new Codex bridge target starts asking too (a Web connection
            // may switch it later, as any bridge session).
            settle_web_session_mode(hub, &t).await?;
        }
        return hub.web_control_check(&t, control);
    }
    // D13: a remote device does not change or end a Claude session the Mac
    // started either (its rules, policy, model, its life or its log).
    let mutates = matches!(
        m,
        method::MUX_SET_RULES
            | method::MUX_SET_POLICY
            | method::MUX_KILL
            | method::SESSION_DELETE
            | method::SESSION_CLOSE
            | method::SESSION_SET_MODEL
    );
    if web
        && mutates
        && let Ok(s) = super::session_key(params).and_then(|key| hub.resolve(key))
        && let Some(e) = hub.local_claude_refusal(&s.meta())
    {
        return Err(e);
    }
    if !(copies || sets_mode || controls) {
        return Ok(());
    }
    if controls {
        let key = super::session_key(params)?;
        return match hub.resolve(key) {
            Ok(s) => hub.web_control_check(&s, control),
            // A configured peer's session: forwarded with `via: web`, so
            // that peer applies the Web's rules on its own fresh state.
            Err(_) if hub.resolve_remote(key).is_some() => Ok(()),
            // A local not-found or ambiguous key is refused, never assumed
            // to be a peer's.
            Err(e) => Err(e),
        };
    }
    // The handler's own resolution; a source it cannot resolve (unknown, or
    // an ambiguous prefix) is refused for the Web, never passed unchecked.
    let s = super::session_key(params).and_then(|key| hub.resolve(key)).map_err(|e| {
        RpcError::invalid_params(format!(
            "{m} from a remote WebSocket connection is refused: the session cannot be resolved ({})",
            e.message
        ))
    })?;
    // D13: a copy of a Claude Code session the Mac started carries its
    // local state; a remote chain starts fresh.
    if web
        && matches!(m, method::SESSION_FORK | method::MUX_HANDOFF_PREPARE)
        && let Some(e) = hub.local_claude_refusal(&s.meta())
    {
        return Err(e);
    }
    if sets_mode {
        hub.web_control_check(&s, control)?;
    }
    let meta = s.meta();
    if sets_mode {
        // The decision `_acpmux/web_modes` reports as `asks`.
        let (id, value) = if m == method::SESSION_SET_MODE {
            (None, params.get("modeId").and_then(Value::as_str))
        } else {
            let id = params.get("configId").and_then(Value::as_str);
            (Some(id.unwrap_or_default()), params.get("value").and_then(Value::as_str))
        };
        return if hub.any_mode_for_web(&meta)
            || hub.web_modes().config_value_asks(&family_of(&meta), id, value)
        {
            Ok(())
        } else {
            Err(RpcError::invalid_params(format!(
                "{m}: this mode or option is accepted only from the local app or the unix socket, never from a remote WebSocket connection"
            )))
        };
    }
    let default = hub.config.read().await.permission_policy;
    let policy = meta.permission_policy.as_deref().and_then(|p| p.parse().ok()).unwrap_or(default);
    if !asking_policy(policy) || !mode_asks(hub, &meta).await {
        return Err(RpcError::invalid_params(format!(
            "{m} from a remote WebSocket connection is refused: the session's policy or mode does not ask"
        )));
    }
    Ok(())
}

fn non_empty(v: Option<&Value>) -> bool {
    match v {
        None | Some(Value::Null) => false,
        Some(Value::Array(a)) => !a.is_empty(),
        Some(Value::Object(o)) => !o.is_empty(),
        Some(_) => true,
    }
}

fn folder_refused(field: &str) -> RpcError {
    RpcError::invalid_params(format!(
        "{field} is refused: from a WebSocket connection it must be an absolute path to an existing directory"
    ))
    .with_data(serde_json::json!({"reason": CWD_MISSING, "field": field}))
}

/// A proven peer's missing `cwd` that lies inside a root once its nearest existing folder is
/// resolved: made (owner-only) when `make`, and returned canonical; `Ok(None)` when it would
/// be made but `make` is off. `Err(None)`: it would lie outside every root, so nothing is
/// made; `Err(Some(_))`: it is no absolute path, or the make failed.
async fn make_inside_root(
    cwd: &str,
    roots: &[PathBuf],
    make: bool,
) -> Result<Option<String>, Option<RpcError>> {
    let path = Path::new(cwd);
    if !path.is_absolute() {
        return Err(Some(folder_refused("cwd")));
    }
    let inside = |p: &Path| roots.iter().any(|root| p.starts_with(root));
    let mut base = None;
    for ancestor in path.ancestors().skip(1) {
        if let Some(found) = fs_spelling(&ancestor.to_string_lossy()).await
            && found.is_dir()
        {
            base = Some((ancestor, found));
            break;
        }
    }
    let Some((ancestor, found)) = base else { return Err(None) };
    let rest = path.strip_prefix(ancestor).map_err(|_| None)?.to_path_buf();
    // Only plain names below the folder that exists: a `..` or `.` there is not followed.
    if !rest.components().all(|c| matches!(c, std::path::Component::Normal(_))) {
        return Err(None);
    }
    let target = found.join(&rest);
    if !inside(&target) {
        return Err(None);
    }
    if !make {
        return Ok(None);
    }
    let made = tokio::task::spawn_blocking(move || make_below(&found, &rest)).await;
    if !matches!(made, Ok(Ok(()))) {
        return Err(Some(folder_refused("cwd")));
    }
    // Resolved again: the folder made is the one checked.
    let canonical =
        canonical_dir(&target.to_string_lossy()).await.ok_or(Some(folder_refused("cwd")))?;
    if inside(Path::new(&canonical)) { Ok(Some(canonical)) } else { Err(None) }
}

/// Make each name of `rest` below `base`, one folder at a time through descriptors that
/// never follow a link: a link (dangling or not) or a file in the way fails the make, so
/// no folder is ever made outside `base`.
#[cfg(unix)]
fn make_below(base: &Path, rest: &Path) -> std::io::Result<()> {
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::ffi::OsStrExt;
    let open = |at: libc::c_int, name: &std::ffi::CStr| {
        let flags = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
        // SAFETY: `name` is a NUL-terminated path and `at` a descriptor this function holds
        // (or AT_FDCWD); the returned descriptor is owned by the OwnedFd below.
        let fd = unsafe { libc::openat(at, name.as_ptr(), flags) };
        if fd < 0 {
            Err(std::io::Error::last_os_error())
        } else {
            // SAFETY: `fd` was just opened and nothing else owns it.
            Ok(unsafe { OwnedFd::from_raw_fd(fd) })
        }
    };
    let c = |bytes: &[u8]| {
        std::ffi::CString::new(bytes).map_err(|_| std::io::Error::other("a NUL in the path"))
    };
    let mut dir = open(libc::AT_FDCWD, &c(base.as_os_str().as_bytes())?)?;
    for part in rest.components() {
        let name = c(part.as_os_str().as_bytes())?;
        // SAFETY: as above; mkdirat never follows a link in the last component.
        if unsafe { libc::mkdirat(dir.as_raw_fd(), name.as_ptr(), 0o700) } != 0 {
            let e = std::io::Error::last_os_error();
            if e.kind() != std::io::ErrorKind::AlreadyExists {
                return Err(e);
            }
        }
        dir = open(dir.as_raw_fd(), &name)?;
    }
    Ok(())
}

#[cfg(not(unix))]
fn make_below(_base: &Path, _rest: &Path) -> std::io::Result<()> {
    Err(std::io::Error::other("folders are made for a peer on unix only"))
}

/// `told`: the configured roots, said only to a proven peer (the owner's own daemon), with
/// the scratch folder it gets when it names none. The Web is not told this machine's folders.
fn outside_roots(field: &str, told: Option<&[PathBuf]>) -> RpcError {
    let mut message = format!(
        "{field} is refused: a remote WebSocket connection may use only a known project or a configured webRoots folder"
    );
    let mut data = serde_json::json!({"reason": CWD_OUTSIDE_ROOTS, "field": field});
    if let Some(roots) = told {
        let listed: Vec<String> = roots.iter().map(|r| r.to_string_lossy().into_owned()).collect();
        if listed.is_empty() {
            message.push_str("; this machine has no webRoots");
        } else {
            message.push_str(&format!("; this machine's webRoots: {}", listed.join(", ")));
        }
        message.push_str(" (with no folder at all, a scratch folder is made for the session)");
        data["roots"] = serde_json::json!(listed);
    }
    RpcError::invalid_params(message).with_data(data)
}

/// `webRoots` from config.json, under `web_roots`' guards, in config order.
async fn configured_web_roots(hub: &std::sync::Arc<crate::hub::Hub>) -> Vec<PathBuf> {
    let raw = hub.config.read().await.web_roots.clone();
    guarded_roots(raw).await
}

/// The folders a Web connection may work in: `webRoots` from config.json,
/// the known projects (every local session's cwd) and the workspace folders
/// the person's app set (`_acpmux/workspace_roots_set`), each in the
/// filesystem's own spelling. A root that is `/`, the home directory or any
/// ancestor of it is dropped: one session started in `~` must not open
/// `~/.ssh` or `~/Library` to the Web. Compared by path components.
async fn web_roots(hub: &std::sync::Arc<crate::hub::Hub>) -> Vec<std::path::PathBuf> {
    let mut raw: Vec<String> = hub.config.read().await.web_roots.clone();
    raw.extend(hub.sessions().iter().map(|s| s.meta().cwd.to_string_lossy().into_owned()));
    // The folders of the workspaces the person's app lists now (its own
    // daemon's tabs, `_acpmux/workspace_roots_set`), under the same guards.
    raw.extend(hub.person.workspace_roots());
    raw.sort();
    raw.dedup();
    guarded_roots(raw).await
}

/// Each folder of `raw` in the filesystem's own spelling, once, without `/`, the home
/// directory or any ancestor of it.
async fn guarded_roots(raw: Vec<String>) -> Vec<PathBuf> {
    let home = match dirs::home_dir() {
        Some(h) => fs_spelling(&h.to_string_lossy()).await.unwrap_or(h),
        None => std::path::PathBuf::from("/"),
    };
    let mut roots = Vec::new();
    for r in raw {
        if let Some(root) = fs_spelling(&r).await
            && !home.starts_with(&root)
            && !roots.contains(&root)
        {
            roots.push(root);
        }
    }
    roots
}

/// `path` resolved (symlinks, `..`) and spelled as the filesystem stores it:
/// on macOS, F_GETPATH gives the stored case and Unicode form of every
/// component, so a case-different or differently normalized spelling of a
/// path compares equal to its root. Elsewhere `realpath` already returns
/// the stored names.
pub(crate) async fn fs_spelling(path: &str) -> Option<std::path::PathBuf> {
    let canonical = tokio::fs::canonicalize(path).await.ok()?;
    #[cfg(target_os = "macos")]
    if let Some(stored) = stored_path(&canonical) {
        return Some(stored);
    }
    Some(canonical)
}

#[cfg(target_os = "macos")]
fn stored_path(path: &Path) -> Option<std::path::PathBuf> {
    use std::os::fd::AsRawFd;
    use std::os::unix::ffi::OsStringExt;
    let file = std::fs::File::open(path).ok()?;
    let mut buf = vec![0u8; libc::PATH_MAX as usize];
    // SAFETY: F_GETPATH writes at most PATH_MAX bytes into `buf`, which holds
    // PATH_MAX bytes, for a descriptor this function owns.
    let r = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETPATH, buf.as_mut_ptr()) };
    if r == -1 {
        return None;
    }
    let end = buf.iter().position(|&b| b == 0)?;
    buf.truncate(end);
    Some(std::path::PathBuf::from(std::ffi::OsString::from_vec(buf)))
}

/// The canonical form of `path` when it is absolute and names a directory.
async fn canonical_dir(path: &str) -> Option<String> {
    if !Path::new(path).is_absolute() {
        return None;
    }
    let canonical = fs_spelling(path).await?;
    tokio::fs::metadata(&canonical)
        .await
        .ok()?
        .is_dir()
        .then(|| canonical.to_string_lossy().into_owned())
}
