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
//! - A chat's own narrower policy holds its mode for every client (`hub/policy_mode.rs`), so
//!   a chat a remote connection started (policy `ask`, below) never leaves the asking modes,
//!   unless a paired machine the person let run chats in Full access sends the switch
//!   (`full_access_device`); deny-all still holds it then, and a chat started on this machine
//!   keeps its policy's mode whoever asks.
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
//! - Web only: no `_acpmux/set_tools` or `_acpmux/mcp/reconnect`
//!   (`tools.remote`). Turning an MCP server on, or reconnecting it, makes
//!   the harness start the stdio command the user's config names on this
//!   machine; unlike a mode, no asking table makes that safe.
//! - Web and Peer: no `session/cancel` of a chat started on this machine, but from the
//!   owner's own peer daemon (`cancel_owner.rs`).
//! - Web and Peer: no `_acpmux/btw` (`btw.remote`). A side session is a new
//!   session on this machine, in the chat's harness and folder, with a policy
//!   that approves reads: the app and the unix socket only.
//! - Web and LocalApp: no `_acpmux/peer_add`, `_acpmux/peer_remove` or
//!   `_acpmux/peer_lease` (they change which machines this daemon reaches
//!   with the user's ssh keys and tokens); `peer_reconnect` only retries a
//!   configured peer.
//! - Web only: the legacy `_acpmux/file_put` stays denied. Resumable prompt
//!   uploads begin with a fresh daemon-issued capability; subsequent operations
//!   and prompt references must prove ownership of an upload begun under Web
//!   control. Neither a local upload id nor its token grants Web access. The
//!   original bytes stay in that chat's owner-only uploads folder.
//! - Web only: no `_acpmux/workflows` (`workflows.remote`): it names the
//!   daemon's chats and their workflows' args.
//! - Web only: no `_acpmux/media_open` or `_acpmux/media_range`
//!   (`mediaRead.remote`). They read a chat's images and videos on this
//!   machine for the app's pane (`hub/media_read.rs`): the unix socket, the
//!   app and a peer forwarding for either.
//! - Web, LocalApp and Peer: no `_acpmux/github_action` (`github_broker.rs`), which an agent
//!   session asks over the unix socket only, and no `_acpmux/github_app_lease`
//!   (`github_app_token.rs`), which only the app's unix-socket call makes.
//! - Web only: no `_acpmux/subagent_transcript` (`transcriptRead.remote`),
//!   which reads a subagent's transcript from the chat's Claude store
//!   (`hub/subagent_transcript.rs`): the unix socket, the app and a peer
//!   forwarding for either. Nor `_acpmux/native_history`, which reads a
//!   chat's older turns from its Claude Code transcript (`hub/native_history.rs`).
//!
//! The unix socket keeps today's behavior.

use crate::no_panic::JsonExt;
use crate::rpc::{RpcError, method};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

mod cancel_owner;
pub(super) mod hint;
mod peer_folder;
pub(super) use hint::POLICY_REFUSED;
pub(super) use hint::check;
use hint::{CWD_MISSING, CWD_OUTSIDE_ROOTS, MODE_REFUSED};
use peer_folder::{
    configured_web_roots, cwd_refused, guarded_roots, make_inside_root, outside_told,
};

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

/// The paired machine whose Full-access setting covers this request
/// (`crate::pairing` module docs), or None: the connection presented that
/// machine's own `client` or `phone` credential (`ConnAuth::Device`; never the shared
/// dashboard token, a peer token, LocalApp or a read-only machine), the
/// request is held to the Web's rules (it forwards for that machine's Web
/// client, `via: web`), and the setting is on now, read from the pairing
/// store for this request. Which machine it is comes from the handshake
/// (`Conn::device`), never from the request.
pub(super) fn full_access_device(
    hub: &crate::hub::Hub,
    conn: &super::Conn,
    params: &Value,
) -> Option<String> {
    let id = conn.device.as_deref().filter(|_| conn.auth == super::ConnAuth::Device)?;
    (control_of(conn.origin, conn.auth, params) == crate::hub::Control::Web
        && hub.pairing.full_access(id))
    .then(|| id.to_owned())
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
    // the prompt goes there without it. Its `author` goes on as it came (`author.rs`): the peer
    // takes it from this link and stamps the provenance itself.
    if let Some(mux) = forwarded.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
        mux.remove("provenance");
    }
    let control = control_of(origin, auth, params);
    if control == crate::hub::Control::Web {
        crate::hub::merge_mux_meta(forwarded, serde_json::json!({"via": "web"}));
    } else if origin == super::Origin::LocalApp {
        crate::hub::merge_mux_meta(forwarded, serde_json::json!({"via": "app"}));
    } else if !crate::hub::vm_boundary::owner(auth, control, params) {
        // A paired machine's request, or one a peer forwarded for one: never the
        // owner's at the peer's VM boundary (`hub/vm_boundary.rs`).
        let via = crate::hub::vm_boundary::VIA_DEVICE;
        crate::hub::merge_mux_meta(forwarded, serde_json::json!({"via": via}));
    }
}

fn refused(what: &str) -> RpcError {
    RpcError::invalid_params(format!(
        "{what} is accepted only over the local unix socket, never from a WebSocket connection"
    ))
}

/// Check (and canonicalize the folder fields of) a request from a
/// connection that is not the unix socket (`hint::check` adds `servedAs`).
async fn check_inner(
    hub: &std::sync::Arc<crate::hub::Hub>,
    origin: super::Origin,
    auth: super::ConnAuth,
    device: Option<&str>,
    m: &str,
    params: &mut Value,
    policy_proved: bool,
) -> Result<(), RpcError> {
    // The mode rules below give an authenticated connection more (any mode
    // of the Codex bridge, `Hub::any_mode_for_web`): none without a proof.
    if !auth.authenticated() {
        return Err(super::conn_auth::refused());
    }
    // A GitHub action runs with the person's GitHub login on their Mac (`github_broker.rs`): an
    // agent session of this daemon asks over the unix socket; no page, app or peer does.
    if m == method::MUX_GITHUB_ACTION || m == method::MUX_GITHUB_APP_LEASE {
        return Err(refused(m));
    }
    // A person's name (`author.rs`) comes over the unix socket, or from a peer forwarding one it
    // took there; never from Web, the app's pane or a peer forwarding for its own Web client.
    if crate::author::present(params)
        && !(origin == super::Origin::Peer
            && control_of(origin, auth, params) == crate::hub::Control::Peer)
    {
        return Err(crate::author::origin_refused());
    }
    // What the Mac's mobile host refuses a phone by its own rule (cmux-mobile-host
    // `acpmux_policy.rs`: a mode that does not ask, a chat in one) it sends marked when the
    // phone presented its own credential: it runs only when that phone's Full-access setting
    // covers it (`device`, from `full_access_device`). The mark only narrows.
    if params.pointer("/_meta/acpmux/requireFullAccess").and_then(Value::as_bool) == Some(true)
        && device.is_none()
    {
        return Err(RpcError::new(
            -32000,
            "Full access is off for this device: turn it on for this device in Settings > Devices on the Mac",
        )
        .with_data(serde_json::json!({"reason": "remote.full_access_required"})));
    }
    let web = origin.web_class();
    // Taking over a watched conversation starts its harness on this machine (`hub/watch.rs`):
    // only a local client does that.
    if web && m == method::MUX_WATCH_TAKE_OVER {
        return Err(RpcError::new(-32602, "a watched chat is taken over only on this machine")
            .with_data(serde_json::json!({"reason": "watch.origin_refused"})));
    }
    if m == method::SESSION_CANCEL && web {
        cancel_owner::check(hub, origin, auth, params)?;
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
    // And so is draining a chat's inbox into a digest (`hub/inbox_digest.rs`).
    if m == method::MUX_INBOX_DIGEST {
        return Err(crate::hub::Hub::inbox_digest_origin_refused());
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
        match web_only(m, params, peer, policy_proved) {
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
        if let Some(cwd) = params.get("cwd").filter(|v| !v.is_null()) {
            let cwd = cwd.as_str().ok_or_else(|| folder_refused("cwd"))?;
            let canonical = match canonical_dir(cwd).await {
                Some(canonical) => Some(canonical),
                None if peer_new => {
                    let roots = roots.as_deref().unwrap_or_default();
                    match make_inside_root(cwd, roots, deferred.is_none()).await {
                        Ok(made) => made,
                        Err(Some(e)) => return Err(e),
                        Err(None) => return Err(outside_told(cwd, &told).await),
                    }
                }
                None => return Err(cwd_refused(cwd).await),
            };
            if let Some(canonical) = canonical {
                if !inside(&canonical) {
                    return Err(outside_told(cwd, &told).await);
                }
                params.set("cwd", Value::String(canonical));
            }
        } else if web && m == method::SESSION_NEW {
            // An absent cwd means the home directory, which is never a root. A proven
            // peer (the owner's own daemon) gets a scratch folder named after the
            // session instead: "acpmux is too belt and suspenders there" (Leo).
            if control_of(origin, auth, params) != crate::hub::Control::Peer {
                return Err(outside_roots("cwd"));
            }
            if deferred.is_none() {
                let cloud_peer =
                    crate::hub::vm_boundary::asked(auth, control_of(origin, auth, params), params);
                let scratch = peer_scratch(params, cloud_peer).await?;
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
                    return Err(outside_roots("additionalDirectories"));
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
    // Reconnecting one starts its configured command again: the same callers.
    let tools = matches!(m, method::MUX_SET_TOOLS | method::MUX_MCP_RECONNECT);
    if tools && control_of(origin, auth, params) == crate::hub::Control::Web {
        return Err(RpcError::invalid_params(
            "tools.remote: a chat's tools are turned on or off, or reconnected, only in the app or over the local unix socket",
        )
        .with_data(serde_json::json!({"reason": "tools.remote"})));
    }
    // Web may stage a prompt attachment. This is only the wire shape: the owning
    // daemon verifies its private Web marker and capability in file_uploads::web.
    // The legacy one-shot put remains app/unix-only.
    if matches!(
        m,
        method::MUX_FILE_PUT
            | method::MUX_FILE_PUT_BEGIN
            | method::MUX_FILE_PUT_CHUNK
            | method::MUX_FILE_PUT_FINISH
            | method::MUX_FILE_PUT_CANCEL
            | method::MUX_FILE_PUT_STATUS
    ) && control_of(origin, auth, params) == crate::hub::Control::Web
        && !crate::hub::file_uploads::web::request_shape(m, params)
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
    // And a chat's older turns, read from its Claude Code transcript (`hub/native_history.rs`).
    if m == method::MUX_NATIVE_HISTORY
        && control_of(origin, auth, params) == crate::hub::Control::Web
    {
        return Err(RpcError::invalid_params(
            "transcriptRead.remote: a chat's transcript is read only for the app or over the local unix socket",
        )
        .with_data(serde_json::json!({"reason": "transcriptRead.remote"})));
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
        let control = control_of(origin, auth, params);
        let vm_boundary = crate::hub::vm_boundary::asked(auth, control, params);
        web_starts_asking(hub, control, vm_boundary, m, params).await?;
    }
    // A chat in Full access by a machine's setting: every request that controls or changes its
    // turn and queue comes from that machine (`Hub::full_access_hold`; `device`, from
    // `full_access_device`).
    if matches!(
        m,
        method::SESSION_PROMPT
            | method::SESSION_CANCEL
            | method::MUX_QUEUE_EDIT
            | method::MUX_QUEUE_REMOVE
            | method::MUX_PERMISSION_RESPOND
            | method::MUX_PERMISSION_GROUP_RESPOND
    ) && let Ok(s) = super::session_key(params).and_then(|key| hub.resolve(key))
    {
        hub.full_access_hold(&s.meta(), control_of(origin, auth, params), device)?;
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
        return Err(outside_roots("cwd"));
    }
    Ok(())
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
        if origin == super::Origin::Peer {
            super::redact::hide_peers_from_peer(v);
        }
    }
}

/// A new Web session in a mode that does not ask is moved to its family's
/// asking default; a family with none (unknown) is ended and refused. `peer`:
/// an enrolled peer of this host started it ([`settles_as_peer`]).
pub(super) async fn settle_web_session_mode(
    hub: &std::sync::Arc<crate::hub::Hub>,
    s: &std::sync::Arc<crate::hub::Session>,
    peer: bool,
) -> Result<(), RpcError> {
    // The Codex bridge takes any mode from an authenticated Web connection
    // (`any_mode_for_web`), but a session the Web STARTS begins in a mode
    // that asks before every change (`BRIDGE_ASKING_MODES`), never in the
    // bridge's own default (`agent`: edits and commands without asking);
    // one an enrolled peer starts under deny-all, in the policy's `read-only`
    // (`hub/policy_mode.rs` `bridge_settle_modes`), whose sandbox refuses
    // every write.
    if hub.any_mode_for_web(&s.meta()) {
        let settled = hub.bridge_settle_modes(s, peer).await;
        let asks = |m: &crate::store::SessionMeta| {
            crate::web_modes::mode_of(m).is_some_and(|mode| settled.contains(&mode))
        };
        if asks(&s.meta()) {
            return Ok(());
        }
        let Some(start) = settled.first() else {
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

/// Whether a connection is an enrolled peer of this host for
/// [`settle_web_session_mode`]: another acpmux that presented this launch's
/// peer token (`peer_auth.rs`), for itself, not forwarding for a Web client
/// (`via: web`). A paired device, the Web and an unknown origin are not.
pub(super) fn settles_as_peer(
    origin: super::Origin,
    auth: super::ConnAuth,
    params: &Value,
) -> bool {
    auth == super::ConnAuth::PeerToken
        && control_of(origin, auth, params) == crate::hub::Control::Peer
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
/// skips asking. `policy_proved`: a policy raise the person proved for this
/// one chat (`hub/person/policy_grant.rs`), whoever relays it.
fn web_only(m: &str, params: &Value, peer: bool, policy_proved: bool) -> Result<(), RpcError> {
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
        method::MUX_SET_POLICY if policy_proved => Ok(()),
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
    vm_boundary: bool,
    m: &str,
    params: &mut Value,
) -> Result<(), RpcError> {
    // A remote chain never resumes a local harness session (REMOTE-FLOOR v3).
    let web = control == crate::hub::Control::Web;
    // A session whose caller asked for the VM boundary this machine takes
    // (`hub/vm_boundary.rs`): the owner's peer daemon's session with no policy
    // stays without one, and `requests.rs` starts it approve-all.
    let vm_host_peer = crate::hub::vm_boundary_peer_approves(
        vm_boundary && hub.takes_vm_boundary().await,
        cfg!(target_os = "macos"),
        control == crate::hub::Control::Peer,
        hub.approve_all_allowed(),
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
    // again at dispatch. A permission answer that only narrows, or carries
    // the person's proof, is held to less (`Hub::web_answer_check`).
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
            settle_web_session_mode(hub, &t, false).await?;
        } else if draft && hub.any_mode_for_web(&t.meta()) {
            // A new Codex bridge target starts asking too (a Web connection
            // may switch it later, as any bridge session).
            settle_web_session_mode(hub, &t, false).await?;
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
            Ok(s) if m == method::MUX_PERMISSION_RESPOND => {
                let (narrows, proved) = hub.answer_shape(params);
                hub.web_answer_check(&s, control, narrows, proved)
            }
            Ok(s) if m == method::MUX_PERMISSION_GROUP_RESPOND => {
                let narrows = params["decision"].as_str() == Some("deny");
                hub.web_answer_check(&s, control, narrows, false)
            }
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
    // A copy or a mode switch of a session at its owner's VM boundary is its owner's alone
    // (`hub/vm_boundary.rs`): a fork keeps the boundary.
    if sets_mode || (web && copies && s.meta().vm_boundary) {
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

/// The folder a proven peer's `session/new` with no `cwd` runs in. Cloud peers
/// get the same durable per-chat location as the daemon start path,
/// `~/chats/<id>`; other peers retain the owner-only temporary scratch root.
async fn peer_scratch(params: &Value, cloud_peer: bool) -> Result<String, RpcError> {
    let name = params
        .pointer("/_meta/acpmux/name")
        .or_else(|| params.get("name"))
        .and_then(Value::as_str)
        .map(scratch_name)
        .filter(|n| !n.is_empty())
        .unwrap_or_else(|| format!("session-{}", uuid::Uuid::now_v7().simple()));
    let dir = if cloud_peer {
        // Daemon starts use numeric surface ids. Keep a peer's numeric session
        // name in its own namespace so the two paths cannot share a chat.
        let folder_name = name
            .parse::<u64>()
            .ok()
            .map(|_| format!("peer-{name}"))
            .unwrap_or_else(|| name.clone());
        cloud_chat_folder(&folder_name).await?
    } else {
        peer_scratch_root()?.join(name)
    };
    let failed = |why: String| {
        RpcError::invalid_params(format!("the peer's scratch folder could not be made: {why}"))
    };
    // `cloud_chat_folder` creates the stable directory itself and retries
    // must reuse it. The legacy peer scratch path remains fresh per name.
    if !cloud_peer {
        let dir = dir.clone();
        let made = tokio::task::spawn_blocking(move || {
            let mut builder = std::fs::DirBuilder::new();
            builder.recursive(true);
            #[cfg(unix)]
            std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
            builder.create(&dir)
        })
        .await;
        made.map_err(|e| failed(e.to_string()))?.map_err(|e| failed(e.to_string()))?;
    }
    crate::config::private_state_dir(&dir).map_err(|e| failed(e.to_string()))?;
    canonical_dir(&dir.to_string_lossy()).await.ok_or_else(|| folder_refused("cwd"))
}

async fn cloud_chat_folder(name: &str) -> Result<PathBuf, RpcError> {
    let home = dirs::home_dir()
        .ok_or_else(|| RpcError::invalid_params("the Cloud machine has no home folder"))?;
    let name = name.to_owned();
    tokio::task::spawn_blocking(move || cloud_chat_folder_under(&home, &name)).await.map_err(
        |error| {
            RpcError::invalid_params(format!("the Cloud chat folder could not be made: {error}"))
        },
    )?
}

fn cloud_chat_folder_under(home: &std::path::Path, name: &str) -> Result<PathBuf, RpcError> {
    let chats = home.join("chats");
    let dir = chats.join(name);
    let failed = |why: String| {
        RpcError::invalid_params(format!("the Cloud chat folder could not be made: {why}"))
    };
    let safe_dir = |metadata: &std::fs::Metadata| {
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt as _;
            metadata.is_dir()
                && metadata.uid() == unsafe { libc::geteuid() }
                && metadata.mode() & 0o022 == 0
        }
        #[cfg(not(unix))]
        {
            metadata.is_dir()
        }
    };
    for path in [&chats, &dir] {
        match std::fs::symlink_metadata(path) {
            Ok(metadata) if safe_dir(&metadata) => {}
            Ok(_) => return Err(failed(format!("{} is not a directory", path.display()))),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                let mut builder = std::fs::DirBuilder::new();
                #[cfg(unix)]
                std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
                builder.create(path).map_err(|e| failed(e.to_string()))?;
            }
            Err(error) => return Err(failed(error.to_string())),
        }
    }
    Ok(dir)
}

fn peer_scratch_root() -> Result<PathBuf, RpcError> {
    static ROOT: OnceLock<Result<PathBuf, String>> = OnceLock::new();
    ROOT.get_or_init(|| {
        let uid = {
            #[cfg(unix)]
            {
                unsafe { libc::getuid() }.to_string()
            }
            #[cfg(not(unix))]
            {
                "user".to_owned()
            }
        };
        let root = std::env::temp_dir()
            .join(format!("acpmux-peer-scratch-{uid}-{}", uuid::Uuid::now_v7().simple()));
        let mut builder = std::fs::DirBuilder::new();
        #[cfg(unix)]
        std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
        builder.create(&root).map_err(|e| format!("{}: {e}", root.display())).and_then(|_| {
            crate::config::private_state_dir(&root).map(|_| root).map_err(|e| e.to_string())
        })
    })
    .clone()
    .map_err(|e| {
        RpcError::invalid_params(format!("the peer's scratch root could not be made: {e}"))
    })
}

/// A session name as one folder name: letters, digits, `.`, `-` and `_`; anything
/// else is `-`, and no name of dots only.
fn scratch_name(name: &str) -> String {
    let n: String = name
        .chars()
        .take(80)
        .map(|c| if c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_') { c } else { '-' })
        .collect();
    if n.chars().all(|c| c == '.') { String::new() } else { n }
}

fn outside_roots(field: &str) -> RpcError {
    RpcError::invalid_params(format!(
        "{field} is refused: a remote WebSocket connection may use only a known project or a configured webRoots folder"
    ))
    .with_data(serde_json::json!({"reason": CWD_OUTSIDE_ROOTS, "field": field}))
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

#[cfg(test)]
mod cloud_chat_tests {
    use super::*;

    #[test]
    fn cloud_peer_uses_a_durable_chat_folder() {
        let home = std::env::temp_dir().join(format!("cmux-cloud-peer-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        // A Cloud machine's home folder exists; only `chats` and the chat's
        // folder are made here.
        std::fs::create_dir_all(&home).unwrap();
        let dir = cloud_chat_folder_under(&home, "chat-1").unwrap();
        assert_eq!(dir, home.join("chats/chat-1"));
        assert!(dir.is_dir());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                std::fs::metadata(home.join("chats")).unwrap().permissions().mode() & 0o777,
                0o700
            );
            assert_eq!(std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777, 0o700);
        }
        let _ = std::fs::remove_dir_all(home);
    }
}
