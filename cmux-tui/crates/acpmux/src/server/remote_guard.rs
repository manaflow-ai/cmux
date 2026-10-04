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
//! - Web only (ACP-REMOTE-GUARD): no permission setting that skips asking
//!   (`approve-reads`, `approve-edits`, `approve-all`, an auto-approve rule,
//!   a harness mode that bypasses its own asks) at `session/new`,
//!   `session/set_mode`, `session/set_config_option`, `_acpmux/set_policy`,
//!   `_acpmux/set_default_policy`, `_acpmux/set_rules`, or a defaults or
//!   preset write; and no `_acpmux/directories` listing (answered "Method not found", so
//!   the dashboard falls back to typed paths, which `session/new` checks).
//!   LocalApp keeps both: the daemon cannot see user gestures, and the
//!   native relay enforces a fresh gesture for LocalApp before it sends one.
//! - Web and LocalApp: no `_acpmux/peer_add` or `_acpmux/peer_remove` (they
//!   change which machines this daemon reaches with the user's ssh keys and
//!   tokens); `peer_reconnect` only retries a configured peer.
//!
//! The unix socket keeps today's behavior.

use crate::rpc::{RpcError, method};
use serde_json::Value;
use std::path::Path;

fn refused(what: &str) -> RpcError {
    RpcError::invalid_params(format!(
        "{what} is accepted only over the local unix socket, never from a WebSocket connection"
    ))
}

/// Check (and canonicalize the folder fields of) a request from a
/// connection that is not the unix socket.
pub(super) async fn check(
    origin: super::Origin,
    m: &str,
    params: &mut Value,
) -> Result<(), RpcError> {
    // RED stub: no Web-only rules, no peer rule.
    let _ = (origin, web_only as fn(&str, &Value) -> Result<(), RpcError>);
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
    let folders = matches!(
        m,
        method::SESSION_NEW
            | method::SESSION_FORK
            | method::SESSION_LOAD
            | method::SESSION_RESUME
            | method::ACP_TRUST_SET
    );
    if folders {
        if let Some(cwd) = params.get("cwd").filter(|v| !v.is_null()) {
            let cwd = cwd.as_str().ok_or_else(|| folder_refused("cwd"))?;
            let canonical = canonical_dir(cwd).await.ok_or_else(|| folder_refused("cwd"))?;
            params["cwd"] = Value::String(canonical);
        }
        if let Some(dirs) = params.get("additionalDirectories").filter(|v| !v.is_null()) {
            let list = dirs.as_array().ok_or_else(|| folder_refused("additionalDirectories"))?;
            let mut out = Vec::with_capacity(list.len());
            for d in list {
                let d = d.as_str().ok_or_else(|| folder_refused("additionalDirectories"))?;
                let c = canonical_dir(d)
                    .await
                    .ok_or_else(|| folder_refused("additionalDirectories"))?;
                out.push(Value::String(c));
            }
            params["additionalDirectories"] = Value::Array(out);
        }
    }
    Ok(())
}

/// Harness modes that skip the harness's own permission asks.
const SKIP_ASK_MODES: &[&str] =
    &["bypassPermissions", "acceptEdits", "dontAsk", "yolo", "full-access", "auto"];

fn skips_asking(policy: &str) -> bool {
    !matches!(policy.parse::<crate::config::PermissionPolicy>(), Ok(p) if matches!(p, crate::config::PermissionPolicy::Ask | crate::config::PermissionPolicy::DenyAll))
}

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
    let policy_at = |v: Option<&Value>| v.and_then(Value::as_str).is_some_and(skips_asking);
    match m {
        method::SESSION_NEW
            if policy_at(params.get("policy"))
                || policy_at(params.pointer("/_meta/acpmux/policy")) =>
        {
            Err(refused("a permission policy that skips asking"))
        }
        method::MUX_SET_POLICY | "_acpmux/set_default_policy"
            if policy_at(params.get("policy")) =>
        {
            Err(refused("a permission policy that skips asking"))
        }
        method::MUX_DEFAULTS | method::MUX_PRESETS
            if policy_at(params.pointer("/set/policy")) =>
        {
            Err(refused("a permission policy that skips asking"))
        }
        method::MUX_SET_RULES => {
            let rules = params.get("rules");
            let auto = non_empty(rules.and_then(|r| r.get("autoApprove")))
                || rules.and_then(|r| r.get("default")).and_then(Value::as_str) == Some("approve");
            if auto { Err(refused("an auto-approve rule")) } else { Ok(()) }
        }
        method::SESSION_SET_MODE | method::SESSION_SET_CONFIG_OPTION => {
            let value = params.get("modeId").or_else(|| params.get("value")).and_then(Value::as_str);
            let skips = |v: &str| {
                SKIP_ASK_MODES.contains(&v)
                    || (v.parse::<crate::config::PermissionPolicy>().is_ok() && skips_asking(v))
            };
            if value.is_some_and(skips) {
                Err(refused("a mode that skips asking"))
            } else {
                Ok(())
            }
        }
        "_acpmux/directories" => Err(RpcError::method_not_found(
            "_acpmux/directories (not served to a remote WebSocket connection)",
        )),
        _ => Ok(()),
    }
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

/// The canonical form of `path` when it is absolute and names a directory.
async fn canonical_dir(path: &str) -> Option<String> {
    if !Path::new(path).is_absolute() {
        return None;
    }
    let canonical = tokio::fs::canonicalize(path).await.ok()?;
    tokio::fs::metadata(&canonical)
        .await
        .ok()?
        .is_dir()
        .then(|| canonical.to_string_lossy().into_owned())
}
