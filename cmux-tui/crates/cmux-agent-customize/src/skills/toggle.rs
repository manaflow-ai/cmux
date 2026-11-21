//! Turning one skill on or off in its agent's own settings, the way the agent's own switch does:
//! Claude Code's `/skills` writes `skillOverrides`, Codex's `skills/config/write` a
//! `[[skills.config]]` path rule. Everything else in the file stays as written (order, comments,
//! unknown keys). The edit holds the file's lock in cmux's private edit store and keeps the prior
//! file there ([`crate::write::Store`]), never beside a project's settings.

use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};

use super::{Agent, CodexLive, Kind, ListOptions, Skill, list};
use crate::ordered_json::{Members, raw_string};
use crate::paths::Homes;

/// One on/off: the skill is named by its file (the `path` a listing printed).
#[derive(Debug, Clone)]
pub struct SetEnabled {
    pub agent: Agent,
    pub path: PathBuf,
    pub enabled: bool,
    pub cwd: Option<PathBuf>,
    /// Find it in Codex's own list (a remote plugin's skill is in no folder cmux reads).
    pub codex_live: Option<CodexLive>,
}

#[derive(Debug)]
pub enum ToggleError {
    /// No listed skill of that agent has that file.
    NotListed(PathBuf),
    /// The agent has no switch for it (a slash command, or a plugin's skill: turn the plugin off).
    NoSwitch(String),
    /// The settings file is not valid JSON or TOML; cmux leaves it alone.
    Unreadable(PathBuf, String),
    Write(PathBuf, std::io::Error),
}

impl fmt::Display for ToggleError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotListed(path) => write!(f, "no listed skill has the file {}", path.display()),
            Self::NoSwitch(name) => write!(
                f,
                "{name} has no on/off switch in its agent; edit or remove its file instead"
            ),
            Self::Unreadable(path, why) => {
                write!(f, "{} is not valid ({why}); cmux left it as it is", path.display())
            }
            Self::Write(path, why) => write!(f, "could not write {}: {why}", path.display()),
        }
    }
}

impl std::error::Error for ToggleError {}

impl ToggleError {
    /// The `--json` error code.
    pub fn code(&self) -> &'static str {
        match self {
            Self::NotListed(_) => "skill.not_found",
            Self::NoSwitch(_) => "skill.no_switch",
            Self::Unreadable(..) => "config.invalid",
            Self::Write(..) => "config.write_failed",
        }
    }
}

/// Turns the skill at `change.path` on or off, then returns it as listed afterwards.
pub fn set_enabled(homes: &Homes, change: &SetEnabled) -> Result<Skill, ToggleError> {
    let options = ListOptions { cwd: change.cwd.clone(), codex_live: change.codex_live.clone() };
    let find = |skills: &[Skill]| {
        let wanted = fs::canonicalize(&change.path).unwrap_or_else(|_| change.path.clone());
        skills
            .iter()
            .find(|s| s.agent == change.agent && (s.path == change.path || s.path == wanted))
            .cloned()
    };
    let skill = find(&list(homes, &options).skills)
        .ok_or_else(|| ToggleError::NotListed(change.path.clone()))?;
    let switch = match (&skill.switch_file, skill.kind, skill.plugin.is_some(), skill.agent) {
        (Some(file), Kind::Skill, false, _) | (Some(file), Kind::Skill, true, Agent::Codex) => {
            file.clone()
        }
        _ => return Err(ToggleError::NoSwitch(skill.name)),
    };
    match skill.agent {
        Agent::Claude => claude(homes, &switch, &skill.name, change.enabled)?,
        Agent::Codex => codex(homes, &switch, &skill.path, change.enabled)?,
    }
    // As listed afterwards: a rule in another settings layer can still keep it as it was.
    Ok(find(&list(homes, &options).skills).unwrap_or(skill))
}

/// `"skillOverrides": {"<name>": "off"}` to turn it off; on removes the override.
fn claude(homes: &Homes, file: &Path, name: &str, enabled: bool) -> Result<(), ToggleError> {
    let _edit = homes.edits.lock(file).map_err(|e| ToggleError::Write(file.to_path_buf(), e))?;
    let text = match fs::read_to_string(file) {
        Ok(text) => text,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(err) => return Err(ToggleError::Write(file.to_path_buf(), err)),
    };
    let mut members = Members::parse(&text)
        .map_err(|e| ToggleError::Unreadable(file.to_path_buf(), e.to_string()))?;
    let mut overrides = match members.get("skillOverrides") {
        Some(raw) => Members::parse(raw.get())
            .map_err(|e| ToggleError::Unreadable(file.to_path_buf(), e.to_string()))?,
        None => Members(Vec::new()),
    };
    overrides.set(name, if enabled { None } else { raw_string("off") });
    let value = if overrides.0.is_empty() {
        None
    } else {
        Some(
            serde_json::value::RawValue::from_string(overrides.render(2))
                .map_err(|e| ToggleError::Unreadable(file.to_path_buf(), e.to_string()))?,
        )
    };
    members.set("skillOverrides", value);
    homes
        .edits
        .replace(file, &format!("{}\n", members.render(0)))
        .map_err(|e| ToggleError::Write(file.to_path_buf(), e))
}

/// A `[[skills.config]]` rule for the skill's path: updated in place when one exists, else added.
fn codex(homes: &Homes, file: &Path, skill: &Path, enabled: bool) -> Result<(), ToggleError> {
    let _lock = cmux_tui_platform::codex_config_lock::lock(
        &homes.codex.join(cmux_tui_platform::codex_config_lock::LOCK_FILE),
    );
    let _edit = homes.edits.lock(file).map_err(|e| ToggleError::Write(file.to_path_buf(), e))?;
    let text = match fs::read_to_string(file) {
        Ok(text) => text,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(err) => return Err(ToggleError::Write(file.to_path_buf(), err)),
    };
    let mut doc = text
        .parse::<toml_edit::DocumentMut>()
        .map_err(|e| ToggleError::Unreadable(file.to_path_buf(), e.to_string()))?;
    let path_text = skill.to_string_lossy().into_owned();
    let skills = doc.entry("skills").or_insert_with(|| {
        let mut table = toml_edit::Table::new();
        table.set_implicit(true);
        toml_edit::Item::Table(table)
    });
    let Some(skills) = skills.as_table_like_mut() else {
        return Err(ToggleError::Unreadable(file.to_path_buf(), "`skills` is not a table".into()));
    };
    let rules =
        skills.entry("config").or_insert(toml_edit::Item::ArrayOfTables(Default::default()));
    let Some(rules) = rules.as_array_of_tables_mut() else {
        return Err(ToggleError::Unreadable(
            file.to_path_buf(),
            "`skills.config` is not [[skills.config]]".into(),
        ));
    };
    let existing = rules
        .iter()
        .position(|rule| rule.get("path").and_then(|p| p.as_str()) == Some(path_text.as_str()));
    match existing.and_then(|index| rules.get_mut(index)) {
        Some(rule) => {
            rule["enabled"] = toml_edit::value(enabled);
        }
        None => {
            let mut rule = toml_edit::Table::new();
            rule["path"] = toml_edit::value(path_text);
            rule["enabled"] = toml_edit::value(enabled);
            rules.push(rule);
        }
    }
    homes
        .edits
        .replace(file, &doc.to_string())
        .map_err(|e| ToggleError::Write(file.to_path_buf(), e))
}
