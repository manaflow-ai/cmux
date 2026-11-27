//! The project settings layer: `<project>/.cmux/cmux-next.json`, the settings one project's
//! chats start with (Claude Code's `.claude/settings.json`, Codex's project `.codex/config.toml`).
//!
//! The order, highest first: MDM forced and team enforced (managed), the project file, the
//! user's file, the layers below it. Only the keys in [`PROJECT_KEYS`] apply per project: the
//! agent-chat settings acpmux reads at each chat start, keyed by the chat's folder. Every other
//! key in a project file is ignored (and listed as such), so a repository cannot change the
//! app's look, the trust rules or anything read once for the whole app.
//!
//! The project of a folder is the nearest folder at or above it that holds the file, stopping
//! below the home folder ([`find`]). acpmux applies the layer only when that folder is trusted
//! (`acpmux::user_settings::read_for`): anybody who can change the repository can change the
//! file, as for a folder harness profile.
//!
//! Writes (`cmux settings set KEY V --project DIR`) go to `DIR/.cmux/cmux-next.json` with the
//! same checks as a user write: a catalog key the schema accepts, never a managed key.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use crate::jsonc;
use crate::keypath::key_path;
use crate::managed::ManagedSource;
use crate::refusal::Refusal;
use crate::schema::{Schema, accepts};
use crate::store::{Origin, State};
use crate::value::{canonical, value_at};

/// The project settings file, relative to the project folder (as `.cmux/worktree.toml` is).
pub const PROJECT_FILE: &str = ".cmux/cmux-next.json";

/// The settings a project may set: each one is read by acpmux at a chat's start through
/// `user_settings::read_for(cwd)`. A key joins this list once its reader is.
pub const PROJECT_KEYS: &[&str] = &["agents.promptCache"];

/// Whether `key` applies per project.
pub fn is_project_key(key: &str) -> bool {
    PROJECT_KEYS.contains(&key)
}

/// `folder/.cmux/cmux-next.json`.
pub fn project_file(folder: &Path) -> PathBuf {
    folder.join(PROJECT_FILE)
}

/// The nearest folder at or above `folder` that holds a project file, never `home` or a folder
/// above it (`~/.cmux` is cmux's own state, not a project). With no home every ancestor counts.
pub fn find(folder: &Path, home: Option<&Path>) -> Option<PathBuf> {
    let in_home = |dir: &Path| home.is_some_and(|home| home.starts_with(dir));
    folder
        .ancestors()
        .take_while(|dir| !in_home(dir))
        .find(|dir| project_file(dir).is_file())
        .map(Path::to_path_buf)
}

/// One project's settings file, read.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ProjectLayer {
    /// The folder that holds `.cmux/cmux-next.json`.
    pub folder: PathBuf,
    /// The values of [`PROJECT_KEYS`] it sets.
    pub values: BTreeMap<String, Value>,
    /// Catalog keys it sets that do not apply per project.
    pub ignored: Vec<String>,
    /// Why the file could not be used (not JSONC, not an object, unreadable).
    pub problem: Option<String>,
}

impl ProjectLayer {
    /// The layer of the project `folder` (`project_file(folder)`); empty when the file is missing.
    pub fn read(folder: &Path, schema: &Schema) -> ProjectLayer {
        let path = project_file(folder);
        match std::fs::read_to_string(&path) {
            Ok(text) => ProjectLayer::from_text(folder, &text, schema),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                ProjectLayer { folder: folder.to_path_buf(), ..ProjectLayer::default() }
            }
            Err(error) => ProjectLayer {
                folder: folder.to_path_buf(),
                problem: Some(format!("{}: {error}", path.display())),
                ..ProjectLayer::default()
            },
        }
    }

    /// The layer the file text `text` makes. A dotted key may be written nested or flat.
    pub fn from_text(folder: &Path, text: &str, schema: &Schema) -> ProjectLayer {
        let mut layer = ProjectLayer { folder: folder.to_path_buf(), ..ProjectLayer::default() };
        let root = match jsonc::parse(text) {
            Ok(root @ Value::Object(_)) => root,
            Ok(_) => {
                layer.problem = Some("the project settings file is not a JSON object".into());
                return layer;
            }
            Err(error) => {
                layer.problem = Some(format!("the project settings file is not JSONC: {error}"));
                return layer;
            }
        };
        for row in &schema.rows {
            let found = root.get(&row.key).or_else(|| value_at(&root, &key_path(&row.key)));
            let Some(value) = found else { continue };
            if is_project_key(&row.key) {
                layer.values.insert(row.key.clone(), canonical(value.clone()));
            } else {
                layer.ignored.push(row.key.clone());
            }
        }
        layer
    }

    /// The project's value of `key`, when it applies per project and the project sets it.
    pub fn value(&self, key: &str) -> Option<&Value> {
        self.values.get(key)
    }
}

/// Where a key's effective value for a project comes from.
#[derive(Debug, Clone, PartialEq)]
pub enum Source {
    Managed(ManagedSource),
    Project,
    User,
    Default,
}

impl Source {
    pub fn wire_name(&self) -> &'static str {
        match self {
            Source::Managed(_) => "managed",
            Source::Project => "project",
            Source::User => "user",
            Source::Default => "default",
        }
    }
}

/// `settings.get` with `project`: the key's value for chats started in the project, and why.
pub fn get_json(state: &State, key: &str, asked: &Path, layer: Option<&ProjectLayer>) -> Value {
    let view = state.get(&crate::store::Target::Key(key.to_string()));
    let mut reply = view.to_json();
    let project_value = layer.and_then(|layer| layer.value(key));
    let (value, source) = if let Some((_, managed)) = view.managed {
        (view.value, Source::Managed(managed))
    } else if let Some(value) = project_value {
        (Some(value.clone()), Source::Project)
    } else if view.file_value.is_some() {
        (view.value, Source::User)
    } else {
        (view.value, Source::Default)
    };
    if let Some(members) = reply.as_object_mut() {
        members.insert("value".into(), value.unwrap_or(Value::Null));
        members.insert("source".into(), Value::String(source.wire_name().into()));
        members.insert(
            "project".into(),
            json!({
                "asked": asked.to_string_lossy(),
                "folder": layer.map(|layer| layer.folder.to_string_lossy().into_owned()),
                "file": layer.map(|layer| project_file(&layer.folder).to_string_lossy().into_owned()),
                "value": project_value,
                "per_project": is_project_key(key),
                "ignored": layer.map(|layer| layer.ignored.clone()).unwrap_or_default(),
                "problem": layer.and_then(|layer| layer.problem.clone()),
                "applies": "to new chats started in the folder or below, once the folder is trusted",
            }),
        );
    }
    reply
}

/// The checks of a project write of `key`: a per-project catalog key no managed layer sets. An
/// agent's write (origin `mcp`: an MCP tool, a sandboxed app, a peer) of a user-only row is
/// refused as in the user's file; the CLI's is not, since the file is the repository's and folder
/// trust decides whether it applies.
fn check_key(state: &State, key: &str, origin: Origin) -> Result<(), Refusal> {
    if !is_project_key(key) {
        return Err(Refusal::InvalidParams {
            message: format!(
                "{key} does not apply per project; per-project keys: {}",
                PROJECT_KEYS.join(", ")
            ),
        });
    }
    if let Some(row) = state.schema().row(key)
        && origin == Origin::Mcp
        && !row.agent_settable
    {
        return Err(Refusal::AgentRefused {
            key: key.to_string(),
            reason: row.agent_refusal.clone(),
        });
    }
    if let Some(source) = state.effective().managed_keys.get(key) {
        return Err(Refusal::Managed { key: key.to_string(), source: source.clone() });
    }
    Ok(())
}

/// The project file's text with `key` set to `value` (comments and other keys kept).
pub fn set_text(
    state: &State,
    source: &str,
    key: &str,
    value: Value,
    origin: Origin,
) -> Result<String, Refusal> {
    check_key(state, key, origin)?;
    let row = state
        .schema()
        .row(key)
        .ok_or_else(|| Refusal::InvalidParams { message: format!("{key} is no settings key") })?;
    let value = canonical(value);
    accepts(row, &value, state.domains())?;
    let text = if source.trim().is_empty() { "{}\n" } else { source };
    let text = jsonc::remove(text, &[key.to_string()]).map_err(unreadable)?;
    jsonc::set(&text, &key_path(key), &value).map_err(unreadable)
}

/// The project file's text without `key` (nested or flat).
pub fn reset_text(
    state: &State,
    source: &str,
    key: &str,
    origin: Origin,
) -> Result<String, Refusal> {
    check_key(state, key, origin)?;
    if source.trim().is_empty() {
        return Ok(source.to_string());
    }
    let text = jsonc::remove(source, &[key.to_string()]).map_err(unreadable)?;
    jsonc::remove(&text, &key_path(key)).map_err(unreadable)
}

/// `settings.set` / `settings.reset` with `project` from `origin`: writes `folder/.cmux/cmux-next.json`
/// (`None` resets). Returns the file written.
pub fn write(
    state: &State,
    folder: &Path,
    key: &str,
    value: Option<Value>,
    origin: Origin,
) -> Result<PathBuf, Refusal> {
    let path = project_file(folder);
    let source = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(error) => return Err(Refusal::Io { message: format!("{}: {error}", path.display()) }),
    };
    let text = match value {
        Some(value) => set_text(state, &source, key, value, origin)?,
        None => reset_text(state, &source, key, origin)?,
    };
    if text != source {
        crate::fsio::publish(&path, &text)
            .map_err(|error| Refusal::Io { message: format!("{}: {error}", path.display()) })?;
    }
    Ok(path)
}

fn unreadable(error: jsonc::JsoncError) -> Refusal {
    Refusal::FileUnreadable { message: format!("the project settings file: {error}") }
}

#[cfg(test)]
#[path = "project_tests.rs"]
mod tests;
