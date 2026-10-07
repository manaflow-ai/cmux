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
//!   with the canonical path (symlinks resolved, no `..`).
//! - A session method acpmux does not handle itself is not passed to the
//!   harness (`requests.rs` catch-all), so no harness extension method can
//!   take caller params that spawn or read.
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
//! - Web and LocalApp: no `_acpmux/peer_add` or `_acpmux/peer_remove` (they
//!   change which machines this daemon reaches with the user's ssh keys and
//!   tokens); `peer_reconnect` only retries a configured peer.
//!
//! The unix socket keeps today's behavior.

use crate::rpc::{RpcError, method};
use serde_json::Value;
use std::path::Path;

/// The rules a control request from `origin` runs under. A proven peer
/// forwarding for its own Web client marks it `_meta.acpmux.via = "web"`.
pub(super) fn control_of(origin: super::Origin, params: &Value) -> crate::hub::Control {
    use crate::hub::Control;
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
pub(super) fn mark_forwarded(origin: super::Origin, params: &Value, forwarded: &mut Value) {
    if control_of(origin, params) == crate::hub::Control::Web {
        crate::hub::merge_mux_meta(forwarded, serde_json::json!({"via": "web"}));
    } else if origin == super::Origin::LocalApp {
        crate::hub::merge_mux_meta(forwarded, serde_json::json!({"via": "app"}));
    }
}

fn refused(what: &str) -> RpcError {
    RpcError::invalid_params(format!(
        "{what} is accepted only over the local unix socket, never from a WebSocket connection"
    ))
}

/// Check (and canonicalize the folder fields of) a request from a
/// connection that is not the unix socket.
pub(super) async fn check(
    hub: &std::sync::Arc<crate::hub::Hub>,
    origin: super::Origin,
    m: &str,
    params: &mut Value,
) -> Result<(), RpcError> {
    let web = origin.web_class();
    // A per-session env is set over the unix socket only (session_env.rs).
    if matches!(m, method::SESSION_NEW | method::SESSION_FORK)
        && crate::session_env::present(params.pointer("/_meta/acpmux"))
    {
        return Err(crate::session_env::origin_refused());
    }
    // Which machines this daemon reaches with the user's ssh keys and
    // tokens changes over the unix socket only (LocalApp included).
    if matches!(m, "_acpmux/peer_add" | "_acpmux/peer_remove") {
        return Err(refused("changing peers"));
    }
    // The native relay reads the guard's own table and lists over the unix
    // socket; no WebSocket origin (LocalApp and Peer included) gets them.
    if m == method::MUX_WEB_MODES {
        return Err(refused("_acpmux/web_modes"));
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
    if web {
        web_only(m, params)?;
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
    let folders = matches!(
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
        if let Some(cwd) = params.get("cwd").filter(|v| !v.is_null()) {
            let cwd = cwd.as_str().ok_or_else(|| folder_refused("cwd"))?;
            let canonical = canonical_dir(cwd).await.ok_or_else(|| folder_refused("cwd"))?;
            if !inside(&canonical) {
                return Err(outside_roots("cwd"));
            }
            params["cwd"] = Value::String(canonical);
        } else if web && m == method::SESSION_NEW {
            // An absent cwd means the home directory, which is never a root.
            return Err(outside_roots("cwd"));
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
            params["additionalDirectories"] = Value::Array(out);
        }
    }
    // The folder-trust question is the user's: a remote browser cannot answer
    // it for itself (`trust_gate.rs`). After the folder checks, so a bad path
    // is still refused as one.
    if m == method::ACP_TRUST_SET && control_of(origin, params) == crate::hub::Control::Web {
        return Err(RpcError::invalid_params(
            "trust.remote: the folder's trust is answered only in the app or over the local unix socket",
        )
        .with_data(serde_json::json!({"reason": "trust.remote"})));
    }
    // After the folder checks: what the request starts from, and its mode.
    if web {
        web_starts_asking(hub, control_of(origin, params), m, params).await?;
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
    hub.web_modes().session_asks(m)
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
    if mode_asks(hub, &s.meta()).await {
        return Ok(());
    }
    let refuse = || {
        RpcError::invalid_params(
            "this harness has no reviewed asking mode for a remote WebSocket connection",
        )
    };
    let Some(default) = asking_modes(hub, &family_of(&s.meta())).await.into_iter().next() else {
        let _ = hub.kill(s, true).await;
        return Err(refuse());
    };
    if hub.set_mode(s, &default).await.is_err() || !mode_asks(hub, &s.meta()).await {
        let _ = hub.kill(s, true).await;
        return Err(refuse());
    }
    // The daemon's own move to the asking default clears the flag its
    // starting mode set.
    hub.restore_web_control(s);
    Ok(())
}

/// The only permission policies a Web connection may set: `ask` (every
/// tool call asks) and `deny-all` (nothing runs, nothing is approved). The
/// exact names only; aliases, other policies and unknown values are refused.
const ASKING_POLICIES: &[&str] = &["ask", "deny-all"];

/// What a Web (remote-origin) connection may never do; LocalApp and the
/// unix socket may. The daemon cannot see user gestures: for LocalApp the
/// native relay enforces a fresh gesture before it sends a policy that
/// skips asking.
fn web_only(m: &str, params: &Value) -> Result<(), RpcError> {
    let refused = |what: &str| {
        RpcError::invalid_params(format!(
            "{what} is accepted only from the local app or the unix socket, never from a remote WebSocket connection"
        ))
    };
    // Absent: nothing is set. Present: one of the asking policies, exactly.
    let policy_ok = |v: Option<&Value>| match v {
        None | Some(Value::Null) => true,
        Some(Value::String(p)) => ASKING_POLICIES.contains(&p.as_str()),
        Some(_) => false,
    };
    let policy_refused = || refused("a permission policy other than ask or deny-all");
    if m == method::SESSION_NEW
        && crate::web_modes::MODE_FIELDS.iter().any(|f| {
            params.get(*f).is_some() || params.pointer(&format!("/_meta/acpmux/{f}")).is_some()
        })
    {
        return Err(refused("a mode at session start"));
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
        method::MUX_SET_RULES if !rules_cannot_auto_approve(params.get("rules")) => {
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
    if m == method::SESSION_NEW
        && params.get("policy").is_none_or(Value::is_null)
        && params.pointer("/_meta/acpmux/policy").is_none_or(Value::is_null)
    {
        params["policy"] = Value::String("ask".into());
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
        return if hub.web_modes().config_value_asks(&family_of(&meta), id, value) {
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

/// Rules a Web connection may set: none (a clear), or only `autoDeny` and
/// `ask` lists with a `default` of `ask` or `deny`. No `autoApprove` entry,
/// no `default: "approve"`, and no field this check does not know.
fn rules_cannot_auto_approve(rules: Option<&Value>) -> bool {
    let Some(rules) = rules.filter(|r| !r.is_null()) else { return true };
    let Some(obj) = rules.as_object() else { return false };
    obj.iter().all(|(k, v)| match k.as_str() {
        "autoApprove" => !non_empty(Some(v)),
        "autoDeny" | "ask" => v.is_null() || v.is_array(),
        "default" => v.is_null() || matches!(v.as_str(), Some("ask" | "deny")),
        _ => false,
    })
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
}

fn outside_roots(field: &str) -> RpcError {
    RpcError::invalid_params(format!(
        "{field} is refused: a remote WebSocket connection may use only a known project or a configured webRoots folder"
    ))
}

/// The folders a Web connection may work in: `webRoots` from config.json
/// and the known projects (every local session's cwd), each in the
/// filesystem's own spelling. A root that is `/`, the home directory or any
/// ancestor of it is dropped: one session started in `~` must not open
/// `~/.ssh` or `~/Library` to the Web. Compared by path components.
async fn web_roots(hub: &std::sync::Arc<crate::hub::Hub>) -> Vec<std::path::PathBuf> {
    let mut raw: Vec<String> = hub.config.read().await.web_roots.clone();
    raw.extend(hub.sessions().iter().map(|s| s.meta().cwd.to_string_lossy().into_owned()));
    raw.sort();
    raw.dedup();
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
async fn fs_spelling(path: &str) -> Option<std::path::PathBuf> {
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
