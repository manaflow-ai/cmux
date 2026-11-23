//! Claude Code's and Codex's skills and Claude Code's slash commands, read from each agent's own
//! folders the way the agent finds them, with whether each is on and where turning it off is
//! written (`cmux agent-config skills`, Settings > Claude Code & Codex > Skills).
//!
//! What each CLI loads (checked against Claude Code 2.1.322's `system/init` and Codex 0.164's
//! app-server `skills/list`, 2026-11-19):
//! - Claude Code skills: `<dir>/SKILL.md` directly under `~/.claude/skills`, under each
//!   `.claude/skills` from the working folder up to its git root, and under each enabled plugin's
//!   `skills/`. The name is the folder's (frontmatter `name` is not the name); a plugin's are
//!   `plugin:name`. Turned off with `"skillOverrides": {"<name>": "off"}` in `~/.claude/settings.json`
//!   (a user skill) or the project's `.claude/settings.local.json` (a project skill).
//! - Claude Code slash commands: every `*.md` under `~/.claude/commands` and the project's
//!   `.claude/commands`, a subfolder naming it `sub:name`; a plugin's under its `commands/`.
//! - Codex skills: every `SKILL.md` (folders searched 6 deep, hidden ones skipped) under
//!   `$CODEX_HOME/skills`, `~/.agents/skills`, `$CODEX_HOME/skills/.system` (system), each
//!   `.codex/skills` and `.agents/skills` from the git root down to the working folder, and the
//!   enabled plugins' `skills/` (`plugin:name`). `name` and `description` are required. Turned off
//!   with `[[skills.config]] path = "...", enabled = false` in `$CODEX_HOME/config.toml`.
//!   Codex's own app-server answers `skills/list` with remote plugins too, so [`list`] asks it when
//!   `codex` is installed and falls back to the folders otherwise.

mod codex_live;
mod toggle;

use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::frontmatter;
use crate::ordered_json::Members;
use crate::paths::{Homes, project_dirs};

pub use codex_live::CodexLive;
pub use toggle::{SetEnabled, ToggleError, set_enabled};

/// Bytes of a SKILL.md read for its frontmatter.
const HEAD_BYTES: u64 = 64 * 1024;
/// Codex searches skill roots this many folders deep.
const CODEX_MAX_DEPTH: usize = 6;
/// Slash command folders are searched this deep.
const COMMAND_MAX_DEPTH: usize = 6;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Agent {
    Claude,
    Codex,
}

impl Agent {
    pub fn parse(word: &str) -> Option<Self> {
        match word {
            "claude" => Some(Self::Claude),
            "codex" => Some(Self::Codex),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Skill,
    Command,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Scope {
    /// The person's own (`~/.claude`, `~/.codex`, `~/.agents`).
    User,
    /// The working folder's project.
    Project,
    /// An installed plugin's.
    Plugin,
    /// Shipped with the agent (Codex's `.system`).
    System,
    /// The machine's administrator (`/etc/codex/skills`).
    Admin,
}

/// One skill or slash command as its agent loads it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Skill {
    pub agent: Agent,
    pub kind: Kind,
    pub scope: Scope,
    /// What the person types after `/` (Claude Code) or `$` (Codex).
    pub name: String,
    pub description: String,
    /// The file to read or edit: the SKILL.md or the command's `.md`.
    pub path: PathBuf,
    /// `plugin@marketplace` for a plugin's.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub plugin: Option<String>,
    /// The agent loads it (its plugin is on and no override turns it off).
    pub enabled: bool,
    /// Claude Code's `skillOverrides` value for it, when one is set (`off`, `name-only`, ...).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub r#override: Option<String>,
    /// Where turning it on or off is written; `None` when the agent has no switch for it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub switch_file: Option<PathBuf>,
}

/// A file an agent would refuse, in the agent's words.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Problem {
    pub agent: Agent,
    pub path: PathBuf,
    pub message: String,
}

/// Where each agent's list came from: `files` (cmux read the folders) or `app-server` (Codex's own).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Sources {
    pub claude: &'static str,
    pub codex: &'static str,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Listing {
    pub skills: Vec<Skill>,
    pub problems: Vec<Problem>,
    pub sources: Sources,
}

impl Listing {
    /// How many of `agent`'s `kind` the agent loads.
    pub fn enabled_count(&self, agent: Agent, kind: Kind) -> usize {
        self.skills.iter().filter(|s| s.agent == agent && s.kind == kind && s.enabled).count()
    }
}

#[derive(Debug, Clone, Default)]
pub struct ListOptions {
    /// The working folder whose project skills count; `None` lists only the person's own.
    pub cwd: Option<PathBuf>,
    /// Ask Codex's app-server (`None`: read Codex's folders only).
    pub codex_live: Option<CodexLive>,
}

/// Every skill and slash command of both agents, Claude Code's first, each agent's in name order.
pub fn list(homes: &Homes, options: &ListOptions) -> Listing {
    let mut problems = Vec::new();
    let mut skills = claude(homes, options.cwd.as_deref());
    let mut codex_source = "files";
    let (codex, apply_rules) =
        match options.codex_live.as_ref().and_then(|live| live.list(homes, options.cwd.as_deref()))
        {
            Some((live, live_problems)) => {
                codex_source = "app-server";
                problems.extend(live_problems);
                (live, false)
            }
            None => (codex_files(homes, options.cwd.as_deref(), &mut problems), true),
        };
    skills.extend(with_codex_switches(homes, codex, apply_rules));
    Listing { skills, problems, sources: Sources { claude: "files", codex: codex_source } }
}

// ----- Claude Code -----

/// Claude Code's `skillOverrides`, merged user then project then local (later wins).
fn claude_overrides(files: &[PathBuf]) -> Vec<(String, String)> {
    let mut merged: Vec<(String, String)> = Vec::new();
    for file in files {
        let Ok(text) = fs::read_to_string(file) else { continue };
        let Ok(members) = Members::parse(&text) else { continue };
        let Some(raw) = members.get("skillOverrides") else { continue };
        let Ok(map) = serde_json::from_str::<serde_json::Map<String, serde_json::Value>>(raw.get())
        else {
            continue;
        };
        for (name, value) in map {
            if let Some(value) = value.as_str() {
                merged.retain(|(existing, _)| *existing != name);
                merged.push((name, value.to_owned()));
            }
        }
    }
    merged
}

/// Claude Code's `enabledPlugins` (`plugin@marketplace` → on), merged the same way.
pub(crate) fn claude_enabled_plugins(files: &[PathBuf]) -> Vec<(String, bool)> {
    let mut merged: Vec<(String, bool)> = Vec::new();
    for file in files {
        let Ok(text) = fs::read_to_string(file) else { continue };
        let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) else { continue };
        let Some(map) = value.get("enabledPlugins").and_then(|v| v.as_object()) else { continue };
        for (id, on) in map {
            merged.retain(|(existing, _)| existing != id);
            merged.push((id.clone(), on.as_bool().unwrap_or(false)));
        }
    }
    merged
}

fn claude(homes: &Homes, cwd: Option<&Path>) -> Vec<Skill> {
    let dirs = cwd.map(|cwd| project_dirs(cwd, &homes.home)).unwrap_or_default();
    let root = dirs.last().cloned();
    let mut settings = vec![homes.claude_settings()];
    if let Some(root) = &root {
        settings.push(root.join(".claude/settings.json"));
        settings.push(root.join(".claude/settings.local.json"));
    }
    let overrides = claude_overrides(&settings);
    let plugins_on = claude_enabled_plugins(&settings);
    let mut out = Vec::new();
    let user_switch = Some(homes.claude_settings());
    claude_skill_folder(&homes.claude.join("skills"), Scope::User, None, &user_switch, &mut out);
    claude_commands(&homes.claude.join("commands"), Scope::User, None, &mut out);
    let project_switch = root.as_ref().map(|root| root.join(".claude/settings.local.json"));
    for dir in &dirs {
        claude_skill_folder(
            &dir.join(".claude/skills"),
            Scope::Project,
            None,
            &project_switch,
            &mut out,
        );
        claude_commands(&dir.join(".claude/commands"), Scope::Project, None, &mut out);
    }
    for (id, install) in claude_installed_plugins(homes, root.as_deref()) {
        let on = plugins_on.iter().rev().find(|(p, _)| *p == id).is_some_and(|(_, on)| *on);
        let start = out.len();
        let short = id.split('@').next().unwrap_or(&id).to_owned();
        claude_skill_folder(
            &install.join("skills"),
            Scope::Plugin,
            Some((short.as_str(), id.as_str())),
            &None,
            &mut out,
        );
        claude_commands(
            &install.join("commands"),
            Scope::Plugin,
            Some((short.as_str(), id.as_str())),
            &mut out,
        );
        for skill in &mut out[start..] {
            skill.enabled = on;
        }
    }
    for skill in &mut out {
        if let Some((_, value)) = overrides.iter().find(|(name, _)| *name == skill.name) {
            skill.r#override = Some(value.clone());
            if value == "off" {
                skill.enabled = false;
            }
        }
    }
    dedup_by_path(&mut out);
    out.sort_by(|a, b| (a.kind as u8, &a.name).cmp(&(b.kind as u8, &b.name)));
    out
}

/// `<folder>/<name>/SKILL.md`, one level deep (Claude Code does not search deeper).
fn claude_skill_folder(
    folder: &Path,
    scope: Scope,
    plugin: Option<(&str, &str)>,
    switch_file: &Option<PathBuf>,
    out: &mut Vec<Skill>,
) {
    let Ok(entries) = fs::read_dir(folder) else { return };
    for entry in entries.flatten() {
        let dir = entry.path();
        // `metadata` follows a symlinked skill folder, as Claude Code does.
        if !fs::metadata(&dir).is_ok_and(|m| m.is_dir()) {
            continue;
        }
        let file = dir.join("SKILL.md");
        if !fs::metadata(&file).is_ok_and(|m| m.is_file()) {
            continue;
        }
        let folder_name = entry.file_name().to_string_lossy().into_owned();
        let front = frontmatter::parse(&read_head(&file)).unwrap_or_default();
        out.push(Skill {
            agent: Agent::Claude,
            kind: Kind::Skill,
            scope,
            name: match plugin {
                Some((short, _)) => format!("{short}:{folder_name}"),
                None => folder_name,
            },
            description: front.description.unwrap_or_default(),
            path: file,
            plugin: plugin.map(|(_, id)| id.to_owned()),
            enabled: true,
            r#override: None,
            switch_file: switch_file.clone(),
        });
    }
}

/// Every `*.md` under `folder`; `a/b.md` is `a:b`.
fn claude_commands(
    folder: &Path,
    scope: Scope,
    plugin: Option<(&str, &str)>,
    out: &mut Vec<Skill>,
) {
    let mut stack = vec![(folder.to_path_buf(), Vec::<String>::new())];
    while let Some((dir, prefix)) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') {
                continue;
            }
            let Ok(meta) = fs::metadata(&path) else { continue };
            if meta.is_dir() {
                if prefix.len() + 1 < COMMAND_MAX_DEPTH {
                    let mut deeper = prefix.clone();
                    deeper.push(name);
                    stack.push((path, deeper));
                }
                continue;
            }
            let Some(stem) = name.strip_suffix(".md") else { continue };
            let mut words = prefix.clone();
            words.push(stem.to_owned());
            let base = words.join(":");
            let front = frontmatter::parse(&read_head(&path)).unwrap_or_default();
            out.push(Skill {
                agent: Agent::Claude,
                kind: Kind::Command,
                scope,
                name: match plugin {
                    Some((short, _)) => format!("{short}:{base}"),
                    None => base,
                },
                description: front.description.unwrap_or_default(),
                path,
                plugin: plugin.map(|(_, id)| id.to_owned()),
                enabled: true,
                r#override: None,
                switch_file: None,
            });
        }
    }
}

/// `~/.claude/plugins/installed_plugins.json`: each plugin's install folder (user-scoped ones,
/// and project-scoped ones installed for this project).
pub(crate) fn claude_installed_plugins(
    homes: &Homes,
    project: Option<&Path>,
) -> Vec<(String, PathBuf)> {
    let file = homes.claude.join("plugins/installed_plugins.json");
    let Ok(text) = fs::read_to_string(file) else { return Vec::new() };
    let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) else { return Vec::new() };
    let Some(plugins) = value.get("plugins").and_then(|p| p.as_object()) else { return Vec::new() };
    let mut out = Vec::new();
    for (id, installs) in plugins {
        let installs: Vec<&serde_json::Value> = match installs {
            serde_json::Value::Array(list) => list.iter().collect(),
            other => vec![other],
        };
        let chosen = installs.iter().find(|install| {
            let scope = install.get("scope").and_then(|s| s.as_str()).unwrap_or("user");
            match scope {
                "project" | "local" => {
                    let at = install.get("projectPath").and_then(|p| p.as_str()).map(PathBuf::from);
                    project.is_some_and(|project| at.as_deref() == Some(project))
                }
                _ => true,
            }
        });
        if let Some(path) =
            chosen.and_then(|install| install.get("installPath")).and_then(|p| p.as_str())
        {
            out.push((id.clone(), PathBuf::from(path)));
        }
    }
    out
}

// ----- Codex -----

/// One Codex skills folder: its path, scope, owning plugin (short name, id) and whether
/// symlinks under it are followed.
type CodexRoot = (PathBuf, Scope, Option<(String, String)>, bool);

/// Codex's skills from its folders (no app-server).
fn codex_files(homes: &Homes, cwd: Option<&Path>, problems: &mut Vec<Problem>) -> Vec<Skill> {
    let mut roots: Vec<CodexRoot> = vec![
        (homes.codex.join("skills"), Scope::User, None, true),
        (homes.agents_skills(), Scope::User, None, true),
        (homes.codex.join("skills/.system"), Scope::System, None, false),
    ];
    if let Some(cwd) = cwd {
        for dir in project_dirs(cwd, &homes.home).iter().rev() {
            roots.push((dir.join(".codex/skills"), Scope::Project, None, true));
            roots.push((dir.join(".agents/skills"), Scope::Project, None, true));
        }
    }
    for (id, folder) in codex_enabled_plugins(homes) {
        let short = id.split('@').next().unwrap_or(&id).to_owned();
        roots.push((folder.join("skills"), Scope::Plugin, Some((short, id)), true));
    }
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    for (root, scope, plugin, follow) in roots {
        let mut files = Vec::new();
        find_skill_files(&root, 0, follow, &mut files);
        files.sort();
        for file in files {
            let canonical = fs::canonicalize(&file).unwrap_or(file);
            if !seen.insert(canonical.clone()) {
                continue;
            }
            let text = read_head(&canonical);
            let front = frontmatter::parse(&text);
            let (name, description) =
                match front.as_ref().map(|f| (f.name.clone(), f.description.clone())) {
                    Some((Some(name), Some(description))) => (name, description),
                    Some((None, _)) => {
                        codex_problem(problems, scope, &canonical, "missing field `name`");
                        continue;
                    }
                    Some((_, None)) => {
                        codex_problem(problems, scope, &canonical, "missing field `description`");
                        continue;
                    }
                    None => {
                        codex_problem(
                            problems,
                            scope,
                            &canonical,
                            "missing YAML frontmatter delimited by ---",
                        );
                        continue;
                    }
                };
            out.push(Skill {
                agent: Agent::Codex,
                kind: Kind::Skill,
                scope,
                name: match &plugin {
                    Some((short, _)) => format!("{short}:{name}"),
                    None => name,
                },
                description,
                path: canonical,
                plugin: plugin.as_ref().map(|(_, id)| id.clone()),
                enabled: true,
                r#override: None,
                switch_file: None,
            });
        }
    }
    out
}

fn codex_problem(problems: &mut Vec<Problem>, scope: Scope, path: &Path, message: &str) {
    // Codex keeps a broken system skill to itself.
    if scope != Scope::System {
        problems.push(Problem {
            agent: Agent::Codex,
            path: path.to_path_buf(),
            message: message.to_owned(),
        });
    }
}

/// Every `SKILL.md` under `dir`: a folder holding one is a skill (not searched further); hidden
/// folders are skipped; symlinked folders are followed when `follow`.
fn find_skill_files(dir: &Path, depth: usize, follow: bool, out: &mut Vec<PathBuf>) {
    if depth > CODEX_MAX_DEPTH {
        return;
    }
    let skill = dir.join("SKILL.md");
    if depth > 0 && fs::metadata(&skill).is_ok_and(|m| m.is_file()) {
        out.push(skill);
        return;
    }
    let Ok(entries) = fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        if entry.file_name().to_string_lossy().starts_with('.') {
            continue;
        }
        let path = entry.path();
        let Ok(kind) = entry.file_type() else { continue };
        let is_dir = if kind.is_symlink() {
            follow && fs::metadata(&path).is_ok_and(|m| m.is_dir())
        } else {
            kind.is_dir()
        };
        if is_dir {
            find_skill_files(&path, depth + 1, follow, out);
        }
    }
}

/// `[plugins."name@marketplace"] enabled = true` in config.toml, each with its newest cached
/// version folder (`plugins/cache/<marketplace>/<name>/<version>`).
fn codex_enabled_plugins(homes: &Homes) -> Vec<(String, PathBuf)> {
    let Ok(text) = fs::read_to_string(homes.codex_config()) else { return Vec::new() };
    let Ok(doc) = text.parse::<toml_edit::DocumentMut>() else { return Vec::new() };
    let Some(plugins) = doc.get("plugins").and_then(|p| p.as_table_like()) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for (id, entry) in plugins.iter() {
        let on = entry.get("enabled").and_then(|e| e.as_bool()).unwrap_or(false);
        let Some((name, market)) = id.split_once('@') else { continue };
        if !on {
            continue;
        }
        let folder = homes.codex.join("plugins/cache").join(market).join(name);
        let Ok(versions) = fs::read_dir(&folder) else { continue };
        let newest = versions
            .flatten()
            .filter(|v| v.file_type().is_ok_and(|t| t.is_dir()))
            .max_by_key(|v| v.metadata().and_then(|m| m.modified()).ok());
        if let Some(version) = newest {
            out.push((id.to_owned(), version.path()));
        }
    }
    out
}

/// `[[skills.config]]` rules from config.toml: (path or name selector, enabled), in file order.
pub(crate) fn codex_rules(homes: &Homes) -> Vec<(Option<PathBuf>, Option<String>, bool)> {
    let Ok(text) = fs::read_to_string(homes.codex_config()) else { return Vec::new() };
    let Ok(doc) = text.parse::<toml_edit::DocumentMut>() else { return Vec::new() };
    let Some(rules) =
        doc.get("skills").and_then(|s| s.get("config")).and_then(|c| c.as_array_of_tables())
    else {
        return Vec::new();
    };
    rules
        .iter()
        .filter_map(|rule| {
            let enabled = rule.get("enabled").and_then(|e| e.as_bool())?;
            let path = rule.get("path").and_then(|p| p.as_str()).map(PathBuf::from);
            let name = rule.get("name").and_then(|n| n.as_str()).map(str::to_owned);
            Some((path, name, enabled))
        })
        .collect()
}

/// Codex's on/off from config.toml when cmux read the folders (`apply_rules`; a live list comes
/// with Codex's own answer), and the switch file on every Codex skill.
fn with_codex_switches(homes: &Homes, mut skills: Vec<Skill>, apply_rules: bool) -> Vec<Skill> {
    let rules = if apply_rules { codex_rules(homes) } else { Vec::new() };
    let config = homes.codex_config();
    for skill in &mut skills {
        let canonical = fs::canonicalize(&skill.path).unwrap_or_else(|_| skill.path.clone());
        for (path, name, enabled) in &rules {
            let hit = path.as_ref().is_some_and(|p| *p == canonical || *p == skill.path)
                || name.as_ref().is_some_and(|n| *n == skill.name);
            if hit {
                skill.enabled = *enabled;
            }
        }
        skill.switch_file = Some(config.clone());
    }
    skills.sort_by(|a, b| a.name.cmp(&b.name));
    skills
}

// ----- shared -----

fn dedup_by_path(skills: &mut Vec<Skill>) {
    let mut seen = HashSet::new();
    skills.retain(|skill| {
        seen.insert(fs::canonicalize(&skill.path).unwrap_or_else(|_| skill.path.clone()))
    });
}

/// The start of `file`, enough for its frontmatter.
pub(crate) fn read_head(file: &Path) -> String {
    use std::io::Read as _;
    let Ok(handle) = fs::File::open(file) else { return String::new() };
    let mut bytes = Vec::new();
    let _ = handle.take(HEAD_BYTES).read_to_end(&mut bytes);
    String::from_utf8_lossy(&bytes).into_owned()
}

#[cfg(test)]
mod tests;
