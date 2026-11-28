//! A session's namespace manifest (RFD 0181 B7, after Plan 9's per-process namespace): what the
//! session sees, recorded once at its first start and carried in its metadata, so a move (the
//! bundle carries `session.json`) and a fork (its meta copies its parent's) read it instead of
//! deriving it again on the other side.
//!
//! This first step holds the folder and the tools: whether its cmux server lists every tool
//! (`agent_tools::lists_all_tools`, which reads the folder's and the Claude home's settings
//! files) and the names of the MCP servers its agent was given. Secrets and ports come next.
//!
//! Off unless [`SWITCH_ENV`] is `1`: then the record is kept and read. Off, nothing is recorded
//! and every start derives as before; the counter still counts, so the before number is the same
//! code's.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// `1` turns the manifest on for this daemon: recorded at a start, read at later ones.
pub const SWITCH_ENV: &str = "ACPMUX_SESSION_MANIFEST";

/// What a session sees, as its first start found it.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SessionManifest {
    /// The folder the record holds for. A move rebinds it to the chat's folder on the target
    /// (`transfer_in.rs`, [`rebind`]); a fork into another folder does not keep it.
    pub folder: PathBuf,
    /// Its cmux server lists every tool, not code mode.
    pub all_tools: bool,
    /// The names of the MCP servers its agent was given, in order.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub servers: Vec<String>,
}

/// The switch, as this daemon's env sets it.
pub fn on() -> bool {
    std::env::var(SWITCH_ENV).is_ok_and(|v| v.trim() == "1")
}

static DERIVED: AtomicU64 = AtomicU64::new(0);

/// How many times this process derived a session's tool listing instead of reading it from a
/// manifest: the measure of B7 ("moves/forks re-deriving setup → 0").
pub fn derived() -> u64 {
    DERIVED.load(Ordering::Relaxed)
}

/// Whether the session's cmux server lists every tool: the manifest's answer when the switch is
/// on and the manifest holds for `cwd`, else `derive()` (counted).
pub fn all_tools_with(
    on: bool,
    manifest: Option<&SessionManifest>,
    cwd: &Path,
    derive: impl FnOnce() -> bool,
) -> bool {
    if on && let Some(m) = manifest.filter(|m| m.folder == cwd) {
        return m.all_tools;
    }
    DERIVED.fetch_add(1, Ordering::Relaxed);
    derive()
}

/// [`all_tools_with`] under this daemon's switch.
pub fn all_tools(
    manifest: Option<&SessionManifest>,
    cwd: &Path,
    derive: impl FnOnce() -> bool,
) -> bool {
    all_tools_with(on(), manifest, cwd, derive)
}

/// The marker the hub sets in a Claude Code start's profile env (`hub/spawn.rs`, [`mark`]): `1`
/// or `0`, the manifest's tool listing, for the command build (`agent_tools.rs`
/// `claude_args_and_hooks_for`), which reads it in place of the settings files. The build
/// removes it from the agent's env (`agent/command.rs`).
pub const RECORDED_ENV: &str = "ACPMUX_MANIFEST_ALL_TOOLS";

/// [`mark`] under an explicit switch.
pub fn mark_with(
    on: bool,
    env: &mut BTreeMap<String, String>,
    manifest: Option<&SessionManifest>,
    cwd: &Path,
) {
    env.remove(RECORDED_ENV);
    if on && let Some(m) = manifest.filter(|m| m.folder == cwd) {
        env.insert(RECORDED_ENV.to_owned(), if m.all_tools { "1" } else { "0" }.to_owned());
    }
}

/// Sets [`RECORDED_ENV`] in a start's profile env when the switch is on and the manifest holds
/// for `cwd`; else no marker (a profile's own is removed), and the command build derives.
pub fn mark(env: &mut BTreeMap<String, String>, manifest: Option<&SessionManifest>, cwd: &Path) {
    mark_with(on(), env, manifest, cwd)
}

/// Whether a Claude Code command line lists every cmux tool: [`RECORDED_ENV`]'s answer when the
/// hub marked one, else `derive()` (counted).
pub fn claude_all_tools(env: &BTreeMap<String, String>, derive: impl FnOnce() -> bool) -> bool {
    if let Some(v) = env.get(RECORDED_ENV) {
        return v.trim() == "1";
    }
    DERIVED.fetch_add(1, Ordering::Relaxed);
    derive()
}

/// The names in an ACP `mcpServers` array.
pub fn server_names(servers: Option<&Value>) -> Vec<String> {
    servers
        .and_then(Value::as_array)
        .map(|list| {
            list.iter()
                .filter_map(|s| s.get("name").and_then(Value::as_str).map(str::to_owned))
                .collect()
        })
        .unwrap_or_default()
}

/// The manifest a start records: none when the switch is off or one already holds for `cwd`
/// (recorded once; a later start reads it), else what this start used.
pub fn to_record(
    on: bool,
    kept: Option<&SessionManifest>,
    cwd: &Path,
    all_tools: bool,
    servers: Option<&Value>,
) -> Option<SessionManifest> {
    if !on || kept.is_some_and(|m| m.folder == cwd) {
        return None;
    }
    Some(SessionManifest { folder: cwd.to_path_buf(), all_tools, servers: server_names(servers) })
}

/// A fork's manifest: its parent's while it works in the same folder; a fork into another
/// folder derives its own at its first start.
pub fn for_fork(parent: Option<&SessionManifest>, cwd: &Path) -> Option<SessionManifest> {
    parent.filter(|m| m.folder == cwd).cloned()
}

/// A moved chat's `session.json` (as JSON) with its manifest bound to `cwd`, its folder on this
/// machine: the same branch checked out, so the same namespace (Plan 9's `bind`).
pub fn rebind(meta: &mut Value, cwd: &str) {
    if let Some(m) = meta.get_mut("manifest").and_then(Value::as_object_mut) {
        m.insert("folder".into(), Value::String(cwd.to_owned()));
    }
}

#[cfg(test)]
#[path = "session_manifest_tests.rs"]
mod tests;
