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
    hub: &std::sync::Arc<crate::hub::Hub>,
    origin: super::Origin,
    m: &str,
    params: &mut Value,
) -> Result<(), RpcError> {
    let _ = hub; // RED: no F1-F4 rules yet.
    if origin == super::Origin::Web {
        web_only(m, params)?;
    }
    // Which machines this daemon reaches with the user's ssh keys and
    // tokens changes over the unix socket only (LocalApp included).
    if matches!(m, "_acpmux/peer_add" | "_acpmux/peer_remove") {
        return Err(refused("changing peers"));
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

/// The only harness modes a Web connection may pick: modes shown to ask
/// before they act. Everything else, unknown names included, is refused.
const ASKING_MODES: &[&str] = &[
    // Claude Code "default": "Standard behavior - prompts for permission on
    // first use of each tool" (https://docs.anthropic.com/en/docs/claude-code/iam#permission-modes).
    // acpmux's own Claude backend offers it as "Normal" and answers each
    // permission prompt through its policy (claude_stdio/mod.rs `MODES`,
    // claude_stdio/outbound.rs `supportedDialogKinds: ["permission"]`).
    "default",
    // Claude Code "plan": "Claude can analyze but not modify files or execute
    // commands" (same page); opencode's plan agent sets file edits and bash to
    // "ask" (https://opencode.ai/docs/agents/#plan).
    "plan",
];

/// Config options a Web connection may set to any value: they choose a model
/// or how hard it thinks, never what runs without asking.
const FREE_CONFIG_OPTIONS: &[&str] =
    &["model", "effort", "reasoning_effort", "thought_level", "thinking"];

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
        method::SESSION_SET_MODE => {
            let mode = params.get("modeId").and_then(Value::as_str);
            if mode.is_some_and(|m| ASKING_MODES.contains(&m)) {
                Ok(())
            } else {
                Err(refused("a mode other than default or plan"))
            }
        }
        method::SESSION_SET_CONFIG_OPTION => {
            let id = params.get("configId").and_then(Value::as_str).unwrap_or_default();
            if FREE_CONFIG_OPTIONS.contains(&id) {
                return Ok(());
            }
            let value = params.get("value").and_then(Value::as_str);
            if id == "mode" && value.is_some_and(|v| ASKING_MODES.contains(&v)) {
                Ok(())
            } else {
                Err(refused("this config option or value"))
            }
        }
        "_acpmux/directories" => Err(RpcError::method_not_found(
            "_acpmux/directories (not served to a remote WebSocket connection)",
        )),
        _ => Ok(()),
    }
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
