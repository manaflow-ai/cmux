//! A session's namespace manifest (RFD 0181 B7, after Plan 9's per-process namespace): what the
//! session sees, recorded once at its first start and carried in its metadata, so a move (the
//! bundle carries `session.json`) and a fork (its meta copies its parent's) read it instead of
//! deriving it again on the other side.
//!
//! This first step holds the folder and the tools: whether its cmux server lists every tool
//! (`agent_tools::lists_all_tools`, which reads the folder's and the Claude home's settings
//! files) and the names of the MCP servers its agent was given. Step 3 adds Codex's answer for
//! the person's own `cmux` entry (`codex mcp get cmux`, up to 2 s a start), kept with a digest of
//! everything it depends on and reused only while the digest is the same ([`CodexRecord`]).
//! Step 4 adds the names of the env its agent started with ([`SessionManifest::env`]), never a
//! value: a key or token stays on the machine that has it, and each start resolves its values
//! from its own profile, preset and login env as before. A later start (after a move, or a fork's
//! first) that lacks a recorded name is logged with the names it lacks and counted
//! ([`env_missing`]), so a move to a machine without the chat's key shows up at its start, not as
//! an agent that fails its first turn. Ports come next.
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
    /// Codex's answer for the person's own `cmux` entry, with the digest it holds for.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codex: Option<CodexRecord>,
    /// The names of the env its agent started with, sorted, without the hub's own markers
    /// ([`env_names`]). Names only: no value is ever kept here, secret or not.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub env: Vec<String>,
}

/// The person's own `cmux` entry as Codex answered it (`codex_cmux_entry::CmuxEntry`), only the
/// answers that are sure: no answer and doubt are never kept.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum RecordedEntry {
    None,
    Stdio { command: String, args: Vec<String> },
    Http,
}

/// Codex's answer and the digest of what it depends on (`codex_cmux_entry::fingerprint`: the
/// program, its config arguments, the folder, the env it finds its config with, every config
/// file). A start reads it only when its own digest is the same; else it asks Codex.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CodexRecord {
    pub key: String,
    pub entry: RecordedEntry,
}

impl CodexRecord {
    /// The record of `entry` asked under `key`; none for no answer or doubt (skip on doubt,
    /// `codex_cmux_entry.rs`): those are asked again.
    pub fn of(key: String, entry: &crate::codex_cmux_entry::CmuxEntry) -> Option<Self> {
        use crate::codex_cmux_entry::CmuxEntry;
        let entry = match entry {
            CmuxEntry::None => RecordedEntry::None,
            CmuxEntry::Stdio { command, args } => {
                RecordedEntry::Stdio { command: command.clone(), args: args.clone() }
            }
            CmuxEntry::Http => RecordedEntry::Http,
            CmuxEntry::Unknown | CmuxEntry::Doubt(_) => return None,
        };
        Some(Self { key, entry })
    }

    /// The answer as Codex gave it.
    pub fn entry(&self) -> crate::codex_cmux_entry::CmuxEntry {
        use crate::codex_cmux_entry::CmuxEntry;
        match &self.entry {
            RecordedEntry::None => CmuxEntry::None,
            RecordedEntry::Stdio { command, args } => {
                CmuxEntry::Stdio { command: command.clone(), args: args.clone() }
            }
            RecordedEntry::Http => CmuxEntry::Http,
        }
    }
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

static CODEX_ASKED: AtomicU64 = AtomicU64::new(0);

/// How many times this process asked Codex for the person's own `cmux` entry
/// (`agent_tools::persons_cmux_entry`): the same measure for the Codex answer.
pub fn codex_asked() -> u64 {
    CODEX_ASKED.load(Ordering::Relaxed)
}

/// Counts one `codex mcp get cmux` (`agent_tools::persons_cmux_entry`), switch on or off.
pub fn count_codex_ask() {
    CODEX_ASKED.fetch_add(1, Ordering::Relaxed);
}

/// The marker the hub sets in a start's or a fork's profile env ([`mark`]): the manifest's
/// [`CodexRecord`] as JSON, which `agent_tools::persons_cmux_entry` takes out ([`take_codex`])
/// and reads in place of asking Codex when its digest is the same. Never in an agent's env
/// (`agent/command.rs`) or a pool key (`hub/pool`).
pub const CODEX_ENV: &str = "ACPMUX_MANIFEST_CODEX_ENTRY";

/// Takes [`CODEX_ENV`] out of `env`: the record it carries, none for no marker or one that does
/// not parse.
pub fn take_codex(env: &mut BTreeMap<String, String>) -> Option<CodexRecord> {
    env.remove(CODEX_ENV).and_then(|v| serde_json::from_str(&v).ok())
}

/// Keeps this start's fresh `codex` record in `manifest` when the switch is on and the manifest
/// holds for `cwd` (`hub/idle_census.rs` `note_launch`): a later start reads it while its digest
/// is the same. A start that asked nothing, or got no sure answer, leaves the manifest as it is.
pub fn keep_codex(
    on: bool,
    manifest: &mut Option<SessionManifest>,
    cwd: &Path,
    codex: Option<CodexRecord>,
) {
    if on
        && let Some(m) = manifest.as_mut().filter(|m| m.folder == cwd)
        && let Some(codex) = codex
    {
        m.codex = Some(codex);
    }
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
    env.remove(CODEX_ENV);
    if on && let Some(m) = manifest.filter(|m| m.folder == cwd) {
        env.insert(RECORDED_ENV.to_owned(), if m.all_tools { "1" } else { "0" }.to_owned());
        if let Some(json) = m.codex.as_ref().and_then(|c| serde_json::to_string(c).ok()) {
            env.insert(CODEX_ENV.to_owned(), json);
        }
    }
}

/// Sets [`RECORDED_ENV`] (and [`CODEX_ENV`] when it keeps Codex's answer) in a start's or a
/// fork's profile env when the switch is on and the manifest holds for `cwd`; else no marker (a
/// profile's own is removed), and the command build derives, and Codex is asked.
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
    Some(SessionManifest {
        folder: cwd.to_path_buf(),
        all_tools,
        servers: server_names(servers),
        codex: None,
        env: Vec::new(),
    })
}

/// The names in a start's env the manifest keeps: every one but the hub's own markers
/// ([`RECORDED_ENV`], [`CODEX_ENV`]), which say what the manifest held, not what the agent needs.
pub fn env_names(env: &BTreeMap<String, String>) -> Vec<String> {
    env.keys().filter(|k| *k != RECORDED_ENV && *k != CODEX_ENV).cloned().collect()
}

/// Keeps the names of this start's `env` in `manifest` when the switch is on, the manifest holds
/// for `cwd` and has none yet (recorded once, at the first start that has them:
/// `hub/idle_census.rs` `note_launch`). No env (this daemon started no agent) leaves it as it is.
pub fn keep_env(
    on: bool,
    manifest: &mut Option<SessionManifest>,
    cwd: &Path,
    env: Option<&BTreeMap<String, String>>,
) {
    if on
        && let Some(m) = manifest.as_mut().filter(|m| m.folder == cwd && m.env.is_empty())
        && let Some(env) = env
    {
        m.env = env_names(env);
    }
}

static ENV_MISSING: AtomicU64 = AtomicU64::new(0);

/// How many starts in this process lacked a name their manifest recorded ([`check_env_with`]).
pub fn env_missing() -> u64 {
    ENV_MISSING.load(Ordering::Relaxed)
}

/// The recorded names this start's `env` lacks, when the switch is on and the manifest holds for
/// `cwd`; a start that lacks any is counted ([`env_missing`]). Empty while off, for another
/// folder, or with nothing recorded.
pub fn check_env_with(
    on: bool,
    manifest: Option<&SessionManifest>,
    cwd: &Path,
    env: &BTreeMap<String, String>,
) -> Vec<String> {
    let Some(m) = manifest.filter(|m| on && m.folder == cwd) else { return Vec::new() };
    let missing: Vec<String> = m.env.iter().filter(|k| !env.contains_key(*k)).cloned().collect();
    if !missing.is_empty() {
        ENV_MISSING.fetch_add(1, Ordering::Relaxed);
    }
    missing
}

/// [`check_env_with`] under this daemon's switch.
pub fn check_env(
    manifest: Option<&SessionManifest>,
    cwd: &Path,
    env: &BTreeMap<String, String>,
) -> Vec<String> {
    check_env_with(on(), manifest, cwd, env)
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
