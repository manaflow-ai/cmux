//! A sandboxed local agent keeps its Seatbelt boundary through this daemon (cmuxterm-hq#32166).
//!
//! A local Claude Code chat runs under `sandbox-exec` (`local_sandbox.rs`), and its profile lets
//! it reach this daemon's unix socket. The daemon itself runs unconfined, so every request that
//! makes the daemon execute something would run with the daemon's authority, not the chat's.
//!
//! Who is sandboxed comes from the kernel, never from the request: at accept the daemon reads
//! the peer's audit token (`LOCAL_PEERTOKEN`) and asks `sandbox_check_by_audit_token`
//! (`cmux_link::app_caller::sandboxed`). A token the kernel gives no answer for counts as
//! sandboxed. Nothing persisted under `ACPMUX_HOME` (which the profile lets the agent write) and
//! nothing in the agent's env takes part. The proven person (`hub/person.rs`) is never gated.
//!
//! A sandboxed connection that is not the person:
//! - [`DENIED`] (and the [`DENIED_PREFIXES`] families) are refused: each executes, restarts or
//!   respawns an agent or a harness, writes outside the chat's folders, reaches another machine,
//!   or mints authority, and none keeps the caller's boundary.
//! - `session/new` and `_acpmux/subsession/start` start a chat only inside the caller's own
//!   boundary: its proven caller token is required, the harness is the caller's (pinned), no
//!   peer, host, worktree, preset or env, and the folder and every additional folder sit inside
//!   a folder of the caller's boundary, re-derived by the daemon (`Hub::bg_launch`). The child's
//!   own launch then gets its own boundary from the same builder.
//! - `_acpmux/bg/start` and `_acpmux/workflow` run their tasks inside the owning chat's boundary
//!   (`sandbox_authority.rs`); a chat whose boundary the daemon cannot derive (Claude Code's own
//!   sandbox on, no wrap) is refused rather than run unconfined.
//! - Config writes (`_acpmux/defaults`, `_acpmux/presets` with a change) are refused: they put
//!   the env and args of later launches in the daemon's hands.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde_json::Value;

use super::{Conn, str_param};
use crate::hub::Hub;
use crate::rpc::{RpcError, method};

/// The JSON-RPC error code of a request a sandboxed agent may not make.
pub const SANDBOXED: i64 = -32005;

/// Every method a sandboxed agent's connection is refused (module docs).
pub(super) const DENIED: &[&str] = &[
    // Agents started or restarted outside the caller's boundary.
    method::SESSION_FORK,
    method::SESSION_LOAD,
    method::SESSION_RESUME,
    method::MUX_DISPATCH,
    method::MUX_RACE_START,
    method::MUX_HANDOFF_START,
    method::MUX_WARM,
    method::MUX_PREWARM,
    method::CHAT_FIX_FROM_LINK,
    method::CHAT_FIX_FROM_LINK_PREPARE,
    method::MUX_SET_DIRECTORIES,
    method::MUX_SET_TOOLS,
    method::MUX_MCP_RECONNECT,
    method::MUX_SESSIONS_RESTART_HARNESS,
    // Harness administration: installs, runs or switches the programs every launch runs.
    method::MUX_HARNESS_ADD,
    method::MUX_HARNESS_DOCTOR,
    method::MUX_HARNESS_UPDATE,
    method::MUX_HARNESS_ENABLE,
    method::MUX_HARNESS_DISABLE,
    method::MUX_HARNESS_SECRET_SET,
    method::MUX_AGENT_LOGIN_START,
    method::MUX_AGENT_LOGIN_FINISH,
    method::MUX_AGENT_LOGIN_CANCEL,
    method::MUX_AGENT_LOGIN_API_KEY,
    method::MUX_RELOAD_CONFIG,
    // One-shot commands the daemon runs itself.
    method::MUX_COMPLETE,
    method::MUX_HUNK_SUMMARY,
    method::MUX_SECRET_RUN,
    method::MUX_CUSTOMIZE_RUN,
    method::MUX_RUN_ELSEWHERE_PLAN,
    method::MUX_RUN_ELSEWHERE_START,
    // Files and processes outside the chat's folders.
    method::MUX_PROJECT_NEW,
    method::MUX_WORKTREE_CLEAN,
    method::MUX_WORKTREE_RESTORE,
    method::MUX_PROCESS_KILL,
    // Other machines, and authority minted for them.
    method::MUX_MACHINE_FILES_CALL,
    method::MUX_COMPUTER_USE_CALL,
    method::MUX_MESH_CONTROL,
    method::MUX_KEYS_MINT,
];

/// Method families refused whole: moving a chat between machines and writing files by path.
pub(super) const DENIED_PREFIXES: &[&str] = &["_acpmux/transfer_", "_acpmux/file_put"];

/// The workflow lifecycle method (`workflow_runs.rs`).
const WORKFLOW: &str = "_acpmux/workflow";

/// Fields of `_acpmux/defaults` and `_acpmux/presets` that change config, not read it.
const CONFIG_WRITES: &[&str] = &["set", "clear", "approve", "remove", "delete", "rename"];

/// `_meta.acpmux` fields a contained `session/new` may carry: none shapes the launch.
const NEW_META_ALLOWED: &[&str] =
    &["name", "harness", "model", "effort", "mode", "policy", "createKey", "ephemeral"];

/// Whether a sandboxed agent is refused `m` outright.
pub(super) fn denied(m: &str) -> bool {
    DENIED.contains(&m) || DENIED_PREFIXES.iter().any(|p| m.starts_with(p))
}

fn refused(what: &str) -> RpcError {
    RpcError::new(SANDBOXED, format!("a sandboxed agent may not {what} (cmuxterm-hq#32166)"))
}

/// The request as it goes on, or its refusal (module docs). Ungated connections pass unchanged.
pub(super) async fn gate(
    hub: &Arc<Hub>,
    conn: &Conn,
    m: &str,
    params: Value,
) -> Result<Value, RpcError> {
    if !conn.sandboxed_peer() {
        return Ok(params);
    }
    if denied(m) {
        return Err(refused(&format!("call {m}")));
    }
    if (m == method::MUX_DEFAULTS || m == method::MUX_PRESETS)
        && CONFIG_WRITES.iter().any(|k| params.get(*k).is_some_and(|v| !v.is_null()))
    {
        return Err(refused("change launch config"));
    }
    match m {
        method::SESSION_NEW | method::MUX_SUBSESSION_START => {
            let caller = caller_session(hub, conn)?;
            let folders = boundary_folders(hub, &caller).await?;
            contain_start(m, params, &caller.meta().harness, &folders).await
        }
        method::MUX_BG_START | WORKFLOW => {
            // The task runs in the owning chat's boundary; without one it would run unconfined.
            let owner = match str_param(&params, "sessionId") {
                Some(key) => hub.resolve(key)?,
                None => caller_session(hub, conn)?,
            };
            boundary_folders(hub, &owner).await?;
            Ok(params)
        }
        _ => Ok(params),
    }
}

fn caller_session(hub: &Hub, conn: &Conn) -> Result<Arc<crate::hub::Session>, RpcError> {
    let caller = conn.caller().ok_or_else(|| refused("act without its chat's caller proof"))?;
    hub.resolve(caller)
}

/// The folders of `session`'s boundary as the daemon derives it now (`CWD`, `DIRn`),
/// canonical; an error when it has none.
async fn boundary_folders(
    hub: &Arc<Hub>,
    session: &Arc<crate::hub::Session>,
) -> Result<Vec<PathBuf>, RpcError> {
    let (_, boundary) = hub.bg_launch(session, &session.meta()).await?;
    let prefix = boundary.ok_or_else(|| {
        refused("delegate work from a chat whose boundary the daemon cannot derive")
    })?;
    let mut out = Vec::new();
    for folder in prefix_folders(&prefix) {
        out.push(tokio::fs::canonicalize(&folder).await.unwrap_or(folder));
    }
    Ok(out)
}

/// The `CWD` and `DIRn` parameters of a `sandbox-exec` prefix.
pub(super) fn prefix_folders(prefix: &[String]) -> Vec<PathBuf> {
    prefix
        .chunks(2)
        .filter(|pair| pair[0] == "-D")
        .filter_map(|pair| pair.get(1)?.split_once('='))
        .filter(|(k, _)| {
            *k == "CWD"
                || k.strip_prefix("DIR")
                    .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
        })
        .map(|(_, v)| PathBuf::from(v))
        .collect()
}

/// Whether `path` (canonical) sits in one of `folders`.
pub(super) fn inside(path: &Path, folders: &[PathBuf]) -> bool {
    folders.iter().any(|f| path.starts_with(f))
}

/// A start request held to the caller's boundary, with its folders canonical and its harness
/// pinned to the caller's.
pub(super) async fn contain_start(
    m: &str,
    mut params: Value,
    harness: &str,
    folders: &[PathBuf],
) -> Result<Value, RpcError> {
    let obj = params
        .as_object_mut()
        .ok_or_else(|| RpcError::invalid_params("params must be an object"))?;
    let launch_fields: &[&str] = if m == method::SESSION_NEW {
        &["mcpServers", "env"]
    } else {
        &["host", "worktree", "env", "preset", "peer"]
    };
    for k in launch_fields {
        let set = match obj.get(*k) {
            None | Some(Value::Null) | Some(Value::Bool(false)) => false,
            Some(Value::Array(a)) => !a.is_empty(),
            Some(_) => true,
        };
        if set {
            return Err(refused(&format!("start a chat with {k}")));
        }
    }
    if m == method::SESSION_NEW {
        let meta = obj
            .entry("_meta")
            .or_insert_with(|| Value::Object(Default::default()))
            .as_object_mut()
            .ok_or_else(|| RpcError::invalid_params("_meta must be an object"))?
            .entry("acpmux")
            .or_insert_with(|| Value::Object(Default::default()))
            .as_object_mut()
            .ok_or_else(|| RpcError::invalid_params("_meta.acpmux must be an object"))?;
        if let Some(k) = meta.keys().find(|k| !NEW_META_ALLOWED.contains(&k.as_str())) {
            return Err(refused(&format!("start a chat with _meta.acpmux.{k}")));
        }
        pin_harness(meta, harness)?;
    } else {
        pin_harness(obj, harness)?;
    }
    // The folder: given, it must sit in the boundary; absent, the daemon picks the parent's
    // (subsession) or home (session/new), and home is never inside a chat's boundary.
    let cwd = match obj.get("cwd").and_then(Value::as_str).filter(|c| !c.is_empty()) {
        Some(c) => Some(contained(c, folders, "cwd").await?),
        None if m == method::SESSION_NEW => return Err(refused("start a chat without a folder")),
        None => None,
    };
    if let Some(c) = cwd {
        obj.insert("cwd".into(), Value::String(c));
    }
    if let Some(dirs) = obj.get("additionalDirectories").filter(|v| !v.is_null()) {
        let list = dirs
            .as_array()
            .ok_or_else(|| RpcError::invalid_params("additionalDirectories must be a list"))?;
        let mut out = Vec::with_capacity(list.len());
        for d in list {
            let d = d
                .as_str()
                .ok_or_else(|| RpcError::invalid_params("additionalDirectories must be paths"))?;
            out.push(Value::String(contained(d, folders, "additionalDirectories").await?));
        }
        obj.insert("additionalDirectories".into(), Value::Array(out));
    }
    Ok(params)
}

fn pin_harness(obj: &mut serde_json::Map<String, Value>, harness: &str) -> Result<(), RpcError> {
    match obj.get("harness").and_then(Value::as_str) {
        Some(h) if !h.is_empty() && h != harness => {
            Err(refused(&format!("start a {h} chat from a {harness} chat")))
        }
        _ => {
            obj.insert("harness".into(), Value::String(harness.to_owned()));
            Ok(())
        }
    }
}

async fn contained(path: &str, folders: &[PathBuf], field: &str) -> Result<String, RpcError> {
    let canonical = tokio::fs::canonicalize(path)
        .await
        .map_err(|_| RpcError::invalid_params(format!("{field} is not an existing folder")))?;
    if !inside(&canonical, folders) {
        return Err(refused(&format!("start a chat with {field} outside its own folders")));
    }
    Ok(canonical.to_string_lossy().into_owned())
}

#[cfg(test)]
#[path = "sandbox_gate_tests.rs"]
mod tests;
