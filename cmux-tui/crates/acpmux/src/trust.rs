//! Folder trust (`acp.trust.get` / `acp.trust.set`), owned by acpmux.
//!
//! `get` is a read-only projection: each agent's own level for the folder,
//! read from Claude Code's `~/.claude.json` (`projects[cwd].hasTrustDialogAccepted`)
//! and Codex's `~/.codex/config.toml` (`[projects."<cwd>"] trust_level`), and
//! acpmux's own decision for the folder. Those agent files keep their one
//! writer; acpmux never writes them. `set` records the user's decision in
//! acpmux's own per-folder record (`<home>/trust.json`); level `unknown`
//! clears it, so each agent's own level answers again.
//!
//! A folder the app made for a new chat (agent-home, `made_by_cmux`) is
//! trusted by construction when acpmux has no record for it: nobody is asked.
//! This one rule serves `get` and the trust gate (`session_level`) alike.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

/// A folder's trust: what the pane shows and asks about.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Level {
    Trusted,
    Untrusted,
    Unknown,
}

impl Level {
    pub fn parse(text: &str) -> Option<Self> {
        match text {
            "trusted" => Some(Self::Trusted),
            "untrusted" => Some(Self::Untrusted),
            "unknown" => Some(Self::Unknown),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Trusted => "trusted",
            Self::Untrusted => "untrusted",
            Self::Unknown => "unknown",
        }
    }

    /// The stricter of two levels: untrusted over unknown over trusted.
    pub fn stricter(self, other: Self) -> Self {
        let rank = |level: Self| match level {
            Self::Untrusted => 0,
            Self::Unknown => 1,
            Self::Trusted => 2,
        };
        if rank(self) <= rank(other) { self } else { other }
    }
}

/// Where the agents' files and acpmux's record live.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Paths {
    pub claude_json: PathBuf,
    pub codex_config: PathBuf,
    pub record: PathBuf,
    /// The folder that holds cmux's agent-home folders (`agent_home_root`): the private folder
    /// cmux makes for each new chat in a workspace without a folder. None: no such folder.
    pub agent_home: Option<PathBuf>,
}

impl Paths {
    /// The user's files and this daemon's record (`config::home()`).
    pub fn current() -> Option<Self> {
        let user = dirs::home_dir()?;
        Some(Self {
            claude_json: user.join(".claude.json"),
            codex_config: user.join(".codex").join("config.toml"),
            record: crate::config::home().join("trust.json"),
            agent_home: agent_home_root(),
        })
    }
}

/// `~/Library/Application Support/cmux/agent-home` on macOS (the app's `AgentHome.standard`):
/// the app makes each workspace's agent-home folder there.
pub fn agent_home_root() -> Option<PathBuf> {
    dirs::data_dir().map(|data| data.join("cmux").join("agent-home"))
}

/// The file the app writes in each agent-home folder it makes (`AgentHome.ensure`).
pub const AGENT_HOME_MARKER: &str = ".cmux-agent-home";

/// A folder path the record can key: absolute, without a trailing slash.
/// The path is resolved (symlinks, `.` and `..`, /tmp vs /private/tmp) when it exists,
/// so one folder has one key.
pub fn normalize_cwd(cwd: &str) -> Result<String, String> {
    if cwd.is_empty() || !Path::new(cwd).is_absolute() {
        return Err(format!("cwd must be an absolute path, got {cwd:?}"));
    }
    let resolved = std::fs::canonicalize(cwd).map(|path| path.to_string_lossy().into_owned());
    let path = resolved.unwrap_or_else(|_| cwd.to_owned());
    let without_slash = path.trim_end_matches('/');
    Ok(if without_slash.is_empty() { "/".to_owned() } else { without_slash.to_owned() })
}

/// `cwd` and its parent folders, nearest first: an agent that trusts a folder
/// trusts what is inside it.
fn ancestors(cwd: &str) -> impl Iterator<Item = &str> {
    Path::new(cwd).ancestors().filter_map(Path::to_str).filter(|path| !path.is_empty())
}

/// Claude Code's level: trusted once its trust dialog was accepted for the folder.
pub fn claude_level(claude_json: &str, cwd: &str) -> Level {
    let Ok(value) = serde_json::from_str::<Value>(claude_json) else { return Level::Unknown };
    let Some(projects) = value.get("projects") else { return Level::Unknown };
    let accepted = |path: &str| {
        projects
            .get(path)
            .and_then(|project| project.get("hasTrustDialogAccepted"))
            .and_then(Value::as_bool)
            == Some(true)
    };
    if ancestors(cwd).any(accepted) { Level::Trusted } else { Level::Unknown }
}

/// Codex's level from `[projects."<path>"] trust_level = "…"` in its config.toml,
/// for the folder or its nearest parent that has one.
pub fn codex_level(config_toml: &str, cwd: &str) -> Level {
    let Ok(config) = config_toml.parse::<toml::Table>() else { return Level::Unknown };
    let Some(projects) = config.get("projects").and_then(toml::Value::as_table) else {
        return Level::Unknown;
    };
    ancestors(cwd)
        .find_map(|path| projects.get(path)?.get("trust_level")?.as_str().and_then(Level::parse))
        .unwrap_or(Level::Unknown)
}

/// Serializes `set`'s read, change and write of the record within this daemon.
static RECORD_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// Why a trust call failed: a bad request, or the record could not be read or written.
#[derive(Debug, PartialEq, Eq)]
pub enum Failure {
    Invalid(String),
    Record(String),
}

/// acpmux's record; a missing file is empty, an unreadable one is an error, so a
/// damaged record is never overwritten with a fresh one.
fn read_record(path: &Path) -> Result<BTreeMap<String, String>, Failure> {
    match std::fs::read_to_string(path) {
        Ok(text) => serde_json::from_str(&text).map_err(|e| {
            Failure::Record(format!("trust record {} is damaged: {e}", path.display()))
        }),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(BTreeMap::new()),
        Err(e) => Err(Failure::Record(format!("trust record {}: {e}", path.display()))),
    }
}

/// `acp.trust.get {cwd}` → `{cwd, level, harnesses: {claude, codex}, decided}`.
pub fn get(paths: &Paths, cwd: &str) -> Result<Value, Failure> {
    let cwd = normalize_cwd(cwd).map_err(Failure::Invalid)?;
    let claude =
        claude_level(&std::fs::read_to_string(&paths.claude_json).unwrap_or_default(), &cwd);
    let codex =
        codex_level(&std::fs::read_to_string(&paths.codex_config).unwrap_or_default(), &cwd);
    let decided = read_record(&paths.record)?.get(&cwd).and_then(|level| Level::parse(level));
    let agent_home = paths.agent_home.as_deref().is_some_and(|root| made_by_cmux(root, &cwd));
    // acpmux's own decision answers first; then a folder cmux made for a chat (trusted by
    // construction); then the stricter of the agents' levels.
    let level =
        decided.unwrap_or_else(|| if agent_home { Level::Trusted } else { claude.stricter(codex) });
    Ok(json!({
        "cwd": cwd,
        "level": level.as_str(),
        "harnesses": {"claude": claude.as_str(), "codex": codex.as_str()},
        // acpmux answered (its record, or its agent-home rule): `level` holds for every agent.
        "decided": decided.is_some() || agent_home,
    }))
}

/// Whether `cwd` (normalized: canonical when it exists) is an agent-home folder the app made: a
/// real folder that is a direct child of the canonical `root`, holding the app's marker as a
/// regular file. A symlink in agent-home resolves to its target, which is then no child of the
/// root; a folder inside an agent-home folder is not one either.
fn made_by_cmux(root: &Path, cwd: &str) -> bool {
    let Ok(root) = std::fs::canonicalize(root) else { return false };
    let path = Path::new(cwd);
    if path.parent() != Some(root.as_path()) {
        return false;
    }
    // The path is its own canonical spelling and a folder, never a symlink to one.
    let canonical = std::fs::canonicalize(path).is_ok_and(|resolved| resolved == path);
    let folder = std::fs::symlink_metadata(path).is_ok_and(|meta| meta.file_type().is_dir());
    let marker = std::fs::symlink_metadata(path.join(AGENT_HOME_MARKER))
        .is_ok_and(|meta| meta.file_type().is_file());
    canonical && folder && marker
}

/// The folder's level for a session of the agent `family`: acpmux's own
/// decision first; without one, that agent's own level (Claude Code's or
/// Codex's), or the stricter of both for any other agent. The pane reads the
/// same rule from `get` (`decided`, `harnesses`), so its question and the
/// trust gate (`server/trust_gate.rs`) agree.
pub fn session_level(paths: &Paths, cwd: &str, family: &str) -> Result<(String, Level), Failure> {
    let reply = get(paths, cwd)?;
    let cwd = reply["cwd"].as_str().unwrap_or_default().to_owned();
    let level_at =
        |pointer: &str| reply.pointer(pointer).and_then(Value::as_str).and_then(Level::parse);
    let level = if reply["decided"].as_bool() == Some(true) {
        level_at("/level")
    } else {
        match family {
            "claude" | "codex" => level_at(&format!("/harnesses/{family}")),
            _ => level_at("/level"),
        }
    };
    Ok((cwd, level.unwrap_or(Level::Unknown)))
}

/// `acp.trust.set {cwd, level}`: records the decision; `unknown` forgets it.
pub fn set(paths: &Paths, cwd: &str, level: &str) -> Result<Value, Failure> {
    let cwd = normalize_cwd(cwd).map_err(Failure::Invalid)?;
    let level = Level::parse(level).ok_or_else(|| {
        Failure::Invalid(format!("level must be trusted, untrusted or unknown, got {level:?}"))
    })?;
    let _serialized = RECORD_LOCK.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let mut record = read_record(&paths.record)?;
    match level {
        Level::Unknown => record.remove(&cwd),
        decided => record.insert(cwd.clone(), decided.as_str().to_owned()),
    };
    if let Some(parent) = paths.record.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| Failure::Record(format!("trust record: {e}")))?;
    }
    let bytes = serde_json::to_vec_pretty(&record).map_err(|e| Failure::Record(e.to_string()))?;
    crate::config::write_atomic(&paths.record, &bytes)
        .map_err(|e| Failure::Record(format!("trust record: {e}")))?;
    Ok(json!({"cwd": cwd, "level": level.as_str()}))
}

#[cfg(test)]
mod tests;
