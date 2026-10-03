//! Folder trust (`acp.trust.get` / `acp.trust.set`), owned by acpmux.
//!
//! `get` is a read-only projection: each agent's own level for the folder,
//! read from Claude Code's `~/.claude.json` (`projects[cwd].hasTrustDialogAccepted`)
//! and Codex's `~/.codex/config.toml` (`[projects."<cwd>"] trust_level`), and
//! acpmux's own decision for the folder. Those agent files keep their one
//! writer; acpmux never writes them. `set` records the user's decision in
//! acpmux's own per-folder record (`<home>/trust.json`); level `unknown`
//! clears it, so each agent's own level answers again.

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
#[derive(Clone, Debug)]
pub struct Paths {
    pub claude_json: PathBuf,
    pub codex_config: PathBuf,
    pub record: PathBuf,
}

impl Paths {
    /// The user's files and this daemon's record (`config::home()`).
    pub fn current() -> Self {
        let user = dirs::home_dir().unwrap_or_default();
        Self {
            claude_json: user.join(".claude.json"),
            codex_config: user.join(".codex").join("config.toml"),
            record: crate::config::home().join("trust.json"),
        }
    }
}

/// A folder path the record can key: absolute, without a trailing slash.
pub fn normalize_cwd(cwd: &str) -> Result<String, String> {
    let trimmed = cwd.trim();
    if trimmed.is_empty() || !Path::new(trimmed).is_absolute() {
        return Err(format!("cwd must be an absolute path, got {cwd:?}"));
    }
    let without_slash = trimmed.trim_end_matches('/');
    Ok(if without_slash.is_empty() { "/".to_owned() } else { without_slash.to_owned() })
}

/// Claude Code's level: trusted once its trust dialog was accepted for the folder.
pub fn claude_level(claude_json: &str, cwd: &str) -> Level {
    let Ok(value) = serde_json::from_str::<Value>(claude_json) else { return Level::Unknown };
    match value.pointer("/projects").and_then(|projects| projects.get(cwd)) {
        Some(project)
            if project.get("hasTrustDialogAccepted").and_then(Value::as_bool) == Some(true) =>
        {
            Level::Trusted
        }
        _ => Level::Unknown,
    }
}

/// Codex's level from `[projects."<cwd>"] trust_level = "…"` in its config.toml.
pub fn codex_level(config_toml: &str, cwd: &str) -> Level {
    let headers = [format!("[projects.\"{cwd}\"]"), format!("[projects.'{cwd}']")];
    let mut in_section = false;
    for line in config_toml.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_section = headers.iter().any(|header| line == header);
            continue;
        }
        if !in_section {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else { continue };
        if key.trim() != "trust_level" {
            continue;
        }
        let value =
            value.split('#').next().unwrap_or("").trim().trim_matches(|c| c == '"' || c == '\'');
        return Level::parse(value).unwrap_or(Level::Unknown);
    }
    Level::Unknown
}

fn read_record(path: &Path) -> BTreeMap<String, String> {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default()
}

/// `acp.trust.get {cwd}` → `{cwd, level, harnesses: {claude, codex}, decided}`.
pub fn get(paths: &Paths, cwd: &str) -> Result<Value, String> {
    let cwd = normalize_cwd(cwd)?;
    let claude =
        claude_level(&std::fs::read_to_string(&paths.claude_json).unwrap_or_default(), &cwd);
    let codex =
        codex_level(&std::fs::read_to_string(&paths.codex_config).unwrap_or_default(), &cwd);
    let decided = read_record(&paths.record).get(&cwd).and_then(|level| Level::parse(level));
    // acpmux's own decision answers first; without one, the stricter of the agents' levels.
    let level = decided.unwrap_or_else(|| claude.stricter(codex));
    Ok(json!({
        "cwd": cwd,
        "level": level.as_str(),
        "harnesses": {"claude": claude.as_str(), "codex": codex.as_str()},
        "decided": decided.is_some(),
    }))
}

/// `acp.trust.set {cwd, level}`: records the decision; `unknown` forgets it.
pub fn set(paths: &Paths, cwd: &str, level: &str) -> Result<Value, String> {
    let cwd = normalize_cwd(cwd)?;
    let level = Level::parse(level)
        .ok_or_else(|| format!("level must be trusted, untrusted or unknown, got {level:?}"))?;
    let mut record = read_record(&paths.record);
    match level {
        Level::Unknown => record.remove(&cwd),
        decided => record.insert(cwd.clone(), decided.as_str().to_owned()),
    };
    if let Some(parent) = paths.record.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("trust record: {e}"))?;
    }
    let bytes = serde_json::to_vec_pretty(&record).map_err(|e| e.to_string())?;
    crate::config::write_atomic(&paths.record, &bytes).map_err(|e| format!("trust record: {e}"))?;
    Ok(json!({"cwd": cwd, "level": level.as_str()}))
}

#[cfg(test)]
mod tests;
