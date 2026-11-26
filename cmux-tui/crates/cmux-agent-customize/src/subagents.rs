//! Claude Code's subagents, read from its own folders the way Claude Code finds them, with which
//! one of a name wins (`cmux agent-config subagents`).
//!
//! What Claude Code loads: every `*.md` with `name` and `description` frontmatter under the
//! project's `.claude/agents` (each folder from the working folder up to its git root, the nearest
//! first), then `~/.claude/agents`, then each enabled plugin's `agents/` (named `plugin:name`).
//! When two share a name the earlier wins: project over user over plugin. The frontmatter's
//! `tools` (a comma list or a YAML list; none is every tool), `model` and `color` are shown as
//! written. Codex has no user-defined subagents.

use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::frontmatter;
use crate::paths::{Homes, project_dirs};
use crate::skills::{claude_enabled_plugins, claude_installed_plugins, read_head};

/// Subagent folders are searched this deep.
const MAX_DEPTH: usize = 6;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Scope {
    /// The working folder's project (`.claude/agents`).
    Project,
    /// The person's own (`~/.claude/agents`).
    User,
    /// An installed plugin's (`<plugin>/agents`).
    Plugin,
}

/// One subagent file as Claude Code reads it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Subagent {
    pub scope: Scope,
    /// What the model and `@` mentions call it.
    pub name: String,
    pub description: String,
    /// The tools it may use; empty is every tool the session has.
    pub tools: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    /// The file to read or edit.
    pub path: PathBuf,
    /// `plugin@marketplace` for a plugin's.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub plugin: Option<String>,
    /// Claude Code uses this one: its plugin is on and no earlier file has its name.
    pub active: bool,
    /// The file that wins over this one's name, when one does.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub shadowed_by: Option<PathBuf>,
}

/// A file Claude Code skips, and why.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Problem {
    pub path: PathBuf,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Listing {
    pub subagents: Vec<Subagent>,
    pub problems: Vec<Problem>,
}

impl Listing {
    pub fn active_count(&self) -> usize {
        self.subagents.iter().filter(|s| s.active).count()
    }
}

/// Every subagent Claude Code would see from `cwd` (`None`: the person's own and plugins' only),
/// in precedence order (project, user, plugin), each scope's in name order.
pub fn list(homes: &Homes, cwd: Option<&Path>) -> Listing {
    let dirs = cwd.map(|cwd| project_dirs(cwd, &homes.home)).unwrap_or_default();
    let root = dirs.last().cloned();
    let mut problems = Vec::new();
    let mut out = Vec::new();
    for dir in &dirs {
        folder(&dir.join(".claude/agents"), Scope::Project, None, &mut out, &mut problems);
    }
    folder(&homes.claude.join("agents"), Scope::User, None, &mut out, &mut problems);
    let mut settings = vec![homes.claude_settings()];
    if let Some(root) = &root {
        settings.push(root.join(".claude/settings.json"));
        settings.push(root.join(".claude/settings.local.json"));
    }
    let plugins_on = claude_enabled_plugins(&settings);
    let mut installed = claude_installed_plugins(homes, root.as_deref());
    installed.sort();
    for (id, install) in installed {
        let on = plugins_on.iter().rev().find(|(p, _)| *p == id).is_some_and(|(_, on)| *on);
        let short = id.split('@').next().unwrap_or(&id).to_owned();
        let start = out.len();
        folder(
            &install.join("agents"),
            Scope::Plugin,
            Some((&short, &id)),
            &mut out,
            &mut problems,
        );
        for agent in out.iter_mut().skip(start) {
            agent.active = on;
        }
    }
    // The same file reached twice (a symlinked folder) counts once.
    let mut seen_files = HashSet::new();
    out.retain(|a| seen_files.insert(fs::canonicalize(&a.path).unwrap_or_else(|_| a.path.clone())));
    // The first of a name wins; a plugin that is off never shadows anything.
    let mut winners: Vec<(String, PathBuf)> = Vec::new();
    for agent in &mut out {
        if let Some((_, path)) = winners.iter().find(|(name, _)| *name == agent.name) {
            agent.shadowed_by = Some(path.clone());
            agent.active = false;
        } else if agent.active {
            winners.push((agent.name.clone(), agent.path.clone()));
        }
    }
    Listing { subagents: out, problems }
}

/// Every `*.md` under `root` (hidden entries skipped), sorted by name within the folder.
fn folder(
    root: &Path,
    scope: Scope,
    plugin: Option<(&str, &str)>,
    out: &mut Vec<Subagent>,
    problems: &mut Vec<Problem>,
) {
    let mut files = Vec::new();
    find_md(root, 0, &mut files);
    files.sort();
    let start = out.len();
    for path in files {
        let text = read_head(&path);
        let front = frontmatter::parse(&text);
        let Some(front) = front else {
            problems.push(Problem { path, message: "no `---` frontmatter block".into() });
            continue;
        };
        let (Some(name), Some(description)) = (front.name.clone(), front.description.clone())
        else {
            problems.push(Problem {
                path,
                message: "frontmatter needs both `name` and `description`".into(),
            });
            continue;
        };
        out.push(Subagent {
            scope,
            name: match plugin {
                Some((short, _)) => format!("{short}:{name}"),
                None => name,
            },
            description,
            tools: front.tools,
            model: front.model,
            color: front.color,
            path,
            plugin: plugin.map(|(_, id)| id.to_owned()),
            active: true,
            shadowed_by: None,
        });
    }
    if let Some(added) = out.get_mut(start..) {
        added.sort_by(|a, b| a.name.cmp(&b.name));
    }
}

fn find_md(dir: &Path, depth: usize, out: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let name = entry.file_name();
        if name.to_string_lossy().starts_with('.') {
            continue;
        }
        let path = entry.path();
        let Ok(meta) = fs::metadata(&path) else { continue };
        if meta.is_dir() {
            if depth + 1 < MAX_DEPTH {
                find_md(&path, depth + 1, out);
            }
        } else if path.extension().is_some_and(|ext| ext == "md") {
            out.push(path);
        }
    }
}

#[cfg(test)]
#[path = "subagents_tests.rs"]
mod tests;
