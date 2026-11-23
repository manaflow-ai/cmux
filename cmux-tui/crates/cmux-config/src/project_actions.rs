//! Per-project actions: the buttons a repository names for its own setup,
//! run and test scripts (matrix row `project-actions`; Codex desktop's local
//! environment actions, T3 Code's `t3.json`).
//!
//! The repository says them in `.cmux/actions.json` (JSONC), in the shape of
//! cmux-next.json's own `actions` key, so an entry moves between the two
//! unchanged:
//!
//! ```jsonc
//! {
//!   "actions": {
//!     "setup": { "title": "Setup", "command": "npm install", "icon": "shippingbox" },
//!     "test":  { "title": "Test", "command": "npm test", "target": "currentTerminal" },
//!     "review": { "type": "agent", "agent": "claude", "args": "-p review" }
//!   }
//! }
//! ```
//!
//! [`discover`] finds the file from a working directory: the nearest folder
//! at or above it that holds `.cmux/actions.json`, never above the
//! repository's root (the first folder holding `.git`) and never the home
//! folder itself (`~/.cmux` is cmux's own state). [`resolve`] reads it, checks
//! every entry with the rules the app's `ConfigActionParser` uses for the
//! global `actions`, and merges it with the global ones: a project action
//! with a global action's name takes its place (`shadows`). A project action
//! runs in its project's folder (`cwd`); nothing here runs anything, and the
//! app runs one only when the person picks it.
//!
//! The file is the repository's own: a `.cmux` folder or file that is a
//! symbolic link is not read, and the reply says so.

use std::collections::BTreeMap;
use std::io::Read as _;
use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_json::{Map, Value};

/// The project file, relative to the folder it names.
pub const PROJECT_FILE: &str = ".cmux/actions.json";
/// The largest project file read.
pub const MAX_FILE_BYTES: u64 = 256 * 1024;
/// The targets an action may name (`ConfigCommandAction.Target`).
pub const TARGETS: &[&str] = &["newTabInCurrentPane", "currentTerminal"];
const DEFAULT_TARGET: &str = "newTabInCurrentPane";
const LINK_PROBLEM: &str = "not read: the file or its .cmux folder is a symbolic link";

/// Where an action comes from.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Source {
    /// The project's `.cmux/actions.json`.
    Project,
    /// cmux-next.json `actions`.
    Global,
}

/// One action, checked and ready to run.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Action {
    /// The entry's key under `actions`.
    pub name: String,
    pub source: Source,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tooltip: Option<String>,
    /// The shell text the action types (an `agent` entry's CLI and args).
    pub command: String,
    /// `{type: symbol, name}` or `{type: image, path}` (absolute).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon: Option<Value>,
    /// `newTabInCurrentPane` or `currentTerminal`.
    pub target: String,
    /// The folder a project action runs in; none for a global one.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    /// The file the action is in.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
    /// A project action that takes a global action's place.
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub shadows: bool,
}

/// What is wrong with one entry or file, which is skipped or partly read.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Problem {
    pub source: Source,
    /// The dotted key (`actions.test.command`), or the file for a file problem.
    pub path: String,
    pub message: String,
}

/// The project a working directory is in, as [`discover`] finds it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Found {
    /// The folder holding `.cmux/actions.json`, else the repository root.
    pub root: Option<PathBuf>,
    /// The project file, when there is one.
    pub file: Option<PathBuf>,
}

/// The project of `start` (an absolute folder or file): the nearest folder
/// at or above it with `.cmux/actions.json`, not above the repository root
/// and never `home` itself.
pub fn discover(start: &Path, home: Option<&Path>) -> Found {
    let start = if start.is_file() { start.parent().unwrap_or(start) } else { start };
    let mut repository = None;
    for folder in start.ancestors() {
        if home.is_some_and(|home| folder == home) {
            break;
        }
        // symlink_metadata: a link named .cmux still counts as there (and is refused on read).
        if std::fs::symlink_metadata(folder.join(PROJECT_FILE)).is_ok()
            || std::fs::symlink_metadata(folder.join(".cmux")).is_ok_and(|m| m.is_symlink())
        {
            return Found {
                root: Some(folder.to_path_buf()),
                file: Some(folder.join(PROJECT_FILE)),
            };
        }
        if folder.join(".git").exists() {
            repository = Some(folder.to_path_buf());
            break;
        }
    }
    Found { root: repository, file: None }
}

/// The project's actions merged with the global ones.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Resolved {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project_root: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
    /// Project actions by name, then the global ones they leave, by name.
    pub actions: Vec<Action>,
    pub problems: Vec<Problem>,
}

/// Reads the project of `start` and merges it with `global` (cmux-next.json's
/// parsed document, or `None` to leave the global actions out).
pub fn resolve(start: &Path, home: Option<&Path>, global: Option<&Value>) -> Resolved {
    let found = discover(start, home);
    let mut resolved = Resolved {
        project_root: found.root.as_ref().map(|root| root.to_string_lossy().into_owned()),
        file: found.file.as_ref().map(|file| file.to_string_lossy().into_owned()),
        ..Resolved::default()
    };
    let mut project = BTreeMap::new();
    if let (Some(root), Some(file)) = (&found.root, &found.file) {
        match read_file(root, file) {
            Ok(text) => match crate::jsonc::parse(&text) {
                Ok(document) => {
                    project =
                        parse(&document, Source::Project, root, Some(file), &mut resolved.problems);
                }
                Err(error) => resolved.problems.push(file_problem(file, error.to_string())),
            },
            Err(message) => resolved.problems.push(file_problem(file, message)),
        }
    }
    let mut global_actions = BTreeMap::new();
    if let Some(document) = global {
        let folder = crate::config_path();
        let folder = folder.parent().unwrap_or(Path::new("/"));
        global_actions = parse(document, Source::Global, folder, None, &mut resolved.problems);
    }
    resolved.actions = merge(project, global_actions);
    resolved
}

/// Project actions first, by name; then the global ones whose name no
/// project action takes.
pub fn merge(project: BTreeMap<String, Action>, global: BTreeMap<String, Action>) -> Vec<Action> {
    let mut actions: Vec<Action> = Vec::with_capacity(project.len() + global.len());
    for (name, mut action) in project {
        action.shadows = global.contains_key(&name);
        actions.push(action);
    }
    let taken: Vec<String> = actions.iter().map(|action| action.name.clone()).collect();
    actions.extend(global.into_values().filter(|action| !taken.contains(&action.name)));
    actions
}

/// The `actions` of `document`, checked as `ConfigActionParser` checks them.
/// `folder` is where a relative image icon is, and a project action's `cwd`.
pub fn parse(
    document: &Value,
    source: Source,
    folder: &Path,
    file: Option<&Path>,
    problems: &mut Vec<Problem>,
) -> BTreeMap<String, Action> {
    let mut actions = BTreeMap::new();
    let Some(section) = document.get("actions") else { return actions };
    let Some(entries) = section.as_object() else {
        problems.push(problem(source, "actions", "expected an object"));
        return actions;
    };
    let icon_folder = match (source, file) {
        (Source::Project, Some(file)) => file.parent().unwrap_or(folder).to_path_buf(),
        _ => folder.to_path_buf(),
    };
    for (name, value) in entries {
        let path = format!("actions.{name}");
        if name.trim().is_empty() {
            problems.push(problem(source, &path, "an action needs a nonempty name"));
            continue;
        }
        let Some(fields) = value.as_object() else {
            problems.push(problem(source, &path, "expected an object"));
            continue;
        };
        let kind = trimmed(fields.get("type")).unwrap_or(if fields.contains_key("agent") {
            "agent"
        } else {
            "command"
        });
        let Some(command) = command_text(kind, fields, source, &path, problems) else { continue };
        let tooltip = trimmed(fields.get("tooltip")).map(str::to_string);
        let target = match fields.get("target") {
            None => DEFAULT_TARGET.to_string(),
            Some(value) => match value.as_str().filter(|raw| TARGETS.contains(raw)) {
                Some(raw) => raw.to_string(),
                None => {
                    let message = "expected newTabInCurrentPane or currentTerminal";
                    problems.push(problem(source, &format!("{path}.target"), message));
                    DEFAULT_TARGET.to_string()
                }
            },
        };
        let action = Action {
            name: name.clone(),
            source,
            title: trimmed(fields.get("title"))
                .map(str::to_string)
                .or_else(|| tooltip.clone())
                .unwrap_or_else(|| name.clone()),
            tooltip,
            command,
            icon: icon(fields.get("icon"), &icon_folder),
            target,
            cwd: (source == Source::Project).then(|| folder.to_string_lossy().into_owned()),
            file: file.map(|file| file.to_string_lossy().into_owned()),
            shadows: false,
        };
        actions.insert(name.clone(), action);
    }
    actions
}

/// The shell text of a `command` or `agent` entry, or `None` (reported).
fn command_text(
    kind: &str,
    fields: &Map<String, Value>,
    source: Source,
    path: &str,
    problems: &mut Vec<Problem>,
) -> Option<String> {
    match kind {
        "command" => {
            let command = trimmed(fields.get("command"));
            if command.is_none() {
                problems.push(problem(
                    source,
                    &format!("{path}.command"),
                    "command actions need a command",
                ));
            }
            command.map(str::to_string)
        }
        "agent" => {
            let Some(agent) =
                trimmed(fields.get("agent")).filter(|agent| !agent.contains(char::is_whitespace))
            else {
                let message = "agent must be one command name; put flags in args";
                problems.push(problem(source, &format!("{path}.agent"), message));
                return None;
            };
            let name = match agent {
                "claude" | "claudeCode" | "claude-code" => "claude",
                "opencode" | "openCode" | "open-code" => "opencode",
                other => other,
            };
            Some(match trimmed(fields.get("args")) {
                Some(args) => format!("{name} {args}"),
                None => name.to_string(),
            })
        }
        other => {
            let message = format!("type '{other}' is not supported in cmux-next yet");
            problems.push(problem(source, &format!("{path}.type"), &message));
            None
        }
    }
}

/// `"name"`, `{type: symbol, name}` or `{type: image, path}`; anything else
/// is no icon (the action's default glyph).
fn icon(value: Option<&Value>, folder: &Path) -> Option<Value> {
    let value = value?;
    if let Some(name) = trimmed(Some(value)) {
        return Some(serde_json::json!({"type": "symbol", "name": name}));
    }
    let fields = value.as_object()?;
    match trimmed(fields.get("type"))? {
        "symbol" | "sfSymbol" | "systemImage" => trimmed(fields.get("name"))
            .map(|name| serde_json::json!({"type": "symbol", "name": name})),
        "image" | "file" => {
            let path = trimmed(fields.get("path"))?;
            let expanded = match (path.strip_prefix("~/"), std::env::var_os("HOME")) {
                (Some(rest), Some(home)) => Path::new(&home).join(rest),
                _ => PathBuf::from(path),
            };
            let absolute = if expanded.is_absolute() { expanded } else { folder.join(expanded) };
            Some(serde_json::json!({"type": "image", "path": absolute.to_string_lossy()}))
        }
        _ => None,
    }
}

/// The text of the project file: a regular file, no link at it or at its
/// `.cmux` folder, at most [`MAX_FILE_BYTES`].
fn read_file(root: &Path, file: &Path) -> Result<String, String> {
    let folder =
        std::fs::symlink_metadata(root.join(".cmux")).map_err(|error| error.to_string())?;
    if folder.is_symlink() {
        return Err(LINK_PROBLEM.into());
    }
    let meta = std::fs::symlink_metadata(file).map_err(|error| error.to_string())?;
    if meta.is_symlink() {
        return Err(LINK_PROBLEM.into());
    }
    if !meta.is_file() {
        return Err("not a regular file".into());
    }
    let handle = std::fs::File::open(file).map_err(|error| error.to_string())?;
    let mut text = String::new();
    handle.take(MAX_FILE_BYTES + 1).read_to_string(&mut text).map_err(|error| error.to_string())?;
    if text.len() as u64 > MAX_FILE_BYTES {
        return Err(format!("larger than {MAX_FILE_BYTES} bytes"));
    }
    Ok(text)
}

fn trimmed(value: Option<&Value>) -> Option<&str> {
    value?.as_str().map(str::trim).filter(|text| !text.is_empty())
}

fn problem(source: Source, path: &str, message: &str) -> Problem {
    Problem { source, path: path.to_string(), message: message.to_string() }
}

fn file_problem(file: &Path, message: String) -> Problem {
    Problem { source: Source::Project, path: file.to_string_lossy().into_owned(), message }
}

#[cfg(test)]
#[path = "project_actions_tests.rs"]
mod tests;
