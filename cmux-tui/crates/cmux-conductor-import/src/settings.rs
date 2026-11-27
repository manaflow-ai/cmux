//! A repository's Conductor settings, merged the way Conductor reads them:
//! the database's scripts, then (lowest to highest) `conductor.json` (only
//! when there is no `.conductor/settings.toml`), `.conductor/settings.json`,
//! `.conductor/settings.toml`, `.conductor/settings.local.json` and
//! `.conductor/settings.local.toml`. Tables merge key by key; anything else
//! a later file sets replaces the earlier value.
//!
//! What comes out is what cmux can use: the setup and archive scripts (a
//! workspace's setup and teardown), the run scripts, "files to copy"
//! (`file_include_globs`, for `.worktreeinclude`), and the names of the
//! environment variables. Values of environment variables are never kept.

use std::io::Read as _;
use std::path::Path;

use serde::Serialize;
use serde_json::{Map, Value};

use crate::catalog::Repo;

/// The largest settings file read.
const MAX_FILE_BYTES: u64 = 1024 * 1024;

/// The files read, lowest precedence first, relative to the repository.
const FILES: [&str; 5] = [
    "conductor.json",
    ".conductor/settings.json",
    ".conductor/settings.toml",
    ".conductor/settings.local.json",
    ".conductor/settings.local.toml",
];

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct RepoSettings {
    /// Runs in a new workspace before it is used (Conductor's setup script).
    pub setup: Option<String>,
    /// Runs before a workspace is removed (Conductor's archive script).
    pub teardown: Option<String>,
    /// Commands Conductor's Run button started, by id, in id order.
    pub run: Vec<RunScript>,
    /// Conductor's "files to copy" globs, for `.worktreeinclude`.
    pub files_to_copy: Vec<String>,
    /// The repository already has a `.worktreeinclude`.
    pub has_worktreeinclude: bool,
    /// Names of the variables Conductor set or forwarded; never their values.
    pub env_names: Vec<String>,
    /// `CONDUCTOR_*` variables the scripts use.
    pub conductor_variables: Vec<String>,
    /// The settings files read, relative to the repository.
    pub files: Vec<String>,
    pub notes: Vec<Note>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct RunScript {
    pub id: String,
    pub command: String,
}

/// Something about the settings that does not come over as is.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Note {
    pub code: &'static str,
    pub detail: String,
}

impl Note {
    fn new(code: &'static str, detail: impl Into<String>) -> Self {
        Self { code, detail: detail.into() }
    }
}

/// Settings keys read here; everything else is noted as not imported.
const KNOWN_KEYS: [&str; 4] =
    ["scripts", "file_include_globs", "environment_variables", "environment_variables_forward"];

pub fn read(repo: &Repo, root: &Path) -> RepoSettings {
    let mut out = RepoSettings::default();
    let mut merged = database_settings(repo, &mut out.notes);
    let has_toml = root.join(".conductor/settings.toml").is_file();
    for file in FILES {
        if file == "conductor.json" && has_toml {
            continue;
        }
        let path = root.join(file);
        if !path.is_file() {
            continue;
        }
        match parse(&path) {
            Ok(Value::Object(layer)) => {
                merge(&mut merged, layer);
                out.files.push(file.to_string());
            }
            Ok(_) => {
                out.notes.push(Note::new("malformed-settings", format!("{file} is not a table")));
            }
            Err(reason) => {
                out.notes.push(Note::new("malformed-settings", format!("{file}: {reason}")));
            }
        }
    }
    out.has_worktreeinclude = root.join(".worktreeinclude").is_file();
    let scripts = merged.get("scripts").and_then(Value::as_object);
    out.setup = scripts.and_then(|s| s.get("setup")).and_then(command);
    out.teardown = scripts.and_then(|s| s.get("archive")).and_then(command);
    out.run = run_scripts(scripts.and_then(|s| s.get("run")), &mut out.notes);
    if let Some(globs) = merged.get("file_include_globs") {
        match globs {
            Value::Array(items) => out.files_to_copy = strings(items),
            Value::String(glob) => out.files_to_copy = vec![glob.clone()],
            _ => {
                out.notes.push(Note::new("malformed-settings", "file_include_globs is not a list"));
            }
        }
    }
    let mut names = Vec::new();
    for key in ["environment_variables", "environment_variables_forward"] {
        if let Some(value) = merged.get(key) {
            env_names(value, &mut names);
        }
    }
    names.sort();
    names.dedup();
    out.env_names = names;
    let mut variables = Vec::new();
    let commands = out.setup.iter().chain(&out.teardown).chain(out.run.iter().map(|r| &r.command));
    for command in commands {
        conductor_variables(command, &mut variables);
    }
    variables.sort();
    variables.dedup();
    for name in &variables {
        if !crate::VARIABLE_ALIASES.iter().any(|(conductor, _)| conductor == name) {
            out.notes
                .push(Note::new("unknown-variable", format!("{name} has no cmux counterpart")));
        }
    }
    out.conductor_variables = variables;
    for key in merged.keys().filter(|key| !KNOWN_KEYS.contains(&key.as_str())) {
        out.notes.push(Note::new("not-imported", key.clone()));
    }
    out
}

/// The database's scripts as the lowest settings layer.
fn database_settings(repo: &Repo, notes: &mut Vec<Note>) -> Map<String, Value> {
    let mut scripts = Map::new();
    if let Some(setup) = &repo.setup_script {
        scripts.insert("setup".into(), Value::String(setup.clone()));
    }
    if let Some(archive) = &repo.archive_script {
        scripts.insert("archive".into(), Value::String(archive.clone()));
    }
    if let Some(run) = &repo.run_scripts {
        match serde_json::from_str::<Value>(run) {
            Ok(value @ Value::Object(_)) => {
                scripts.insert("run".into(), value);
            }
            _ => notes.push(Note::new("malformed-settings", "run_scripts_json is not an object")),
        }
    }
    let mut out = Map::new();
    if !scripts.is_empty() {
        out.insert("scripts".into(), Value::Object(scripts));
    }
    out
}

fn parse(path: &Path) -> Result<Value, String> {
    let file = std::fs::File::open(path).map_err(|e| e.to_string())?;
    let mut text = String::new();
    file.take(MAX_FILE_BYTES + 1).read_to_string(&mut text).map_err(|e| e.to_string())?;
    if text.len() as u64 > MAX_FILE_BYTES {
        return Err(format!("larger than {MAX_FILE_BYTES} bytes"));
    }
    if path.extension().is_some_and(|ext| ext == "json") {
        serde_json::from_str(&text).map_err(|e| e.to_string())
    } else {
        let table: toml::Table = toml::from_str(&text).map_err(|e| e.to_string())?;
        serde_json::to_value(table).map_err(|e| e.to_string())
    }
}

fn merge(base: &mut Map<String, Value>, layer: Map<String, Value>) {
    for (key, value) in layer {
        match (base.get_mut(&key), value) {
            (Some(Value::Object(below)), Value::Object(above)) => merge(below, above),
            (_, value) => {
                base.insert(key, value);
            }
        }
    }
}

fn command(value: &Value) -> Option<String> {
    value.as_str().map(str::trim).filter(|text| !text.is_empty()).map(str::to_string)
}

fn strings(items: &[Value]) -> Vec<String> {
    items.iter().filter_map(command).collect()
}

/// `scripts.run`: one command, or a table of `{command, hide, available_in}`
/// by id. Hidden and Cloud-only scripts are left out.
fn run_scripts(value: Option<&Value>, notes: &mut Vec<Note>) -> Vec<RunScript> {
    let Some(value) = value else { return Vec::new() };
    if let Some(command) = command(value) {
        return vec![RunScript { id: "run".into(), command }];
    }
    let Some(table) = value.as_object() else {
        notes.push(Note::new("malformed-settings", "scripts.run is neither a command nor a table"));
        return Vec::new();
    };
    let mut entries: Vec<(&String, &Value)> = table.iter().collect();
    entries.sort_by_key(|(id, _)| *id);
    let mut out = Vec::new();
    for (id, entry) in entries {
        let script = entry.get("command").and_then(command).or_else(|| command(entry));
        let Some(script) = script else {
            notes.push(Note::new("malformed-settings", format!("scripts.run.{id} has no command")));
            continue;
        };
        if entry.get("hide").and_then(Value::as_bool) == Some(true) {
            continue;
        }
        let places = match entry.get("available_in") {
            Some(Value::String(place)) => vec![place.as_str()],
            Some(Value::Array(items)) => items.iter().filter_map(Value::as_str).collect(),
            _ => Vec::new(),
        };
        if !places.is_empty() && places.iter().all(|place| *place == "cloud") {
            continue;
        }
        out.push(RunScript { id: id.clone(), command: script });
    }
    out
}

/// Names only: an array gives its strings, a table its keys, recursively
/// for nested tables (a per-place table of variables).
fn env_names(value: &Value, names: &mut Vec<String>) {
    match value {
        Value::Array(items) => names.extend(strings(items)),
        Value::Object(table) => {
            for (key, value) in table {
                if value.is_object() {
                    env_names(value, names);
                } else {
                    names.push(key.clone());
                }
            }
        }
        _ => {}
    }
}

/// `CONDUCTOR_*` names a command refers to (`$NAME` or `${NAME}`).
fn conductor_variables(command: &str, out: &mut Vec<String>) {
    // Text after each `$` or `{` starts with the name it refers to.
    for rest in command.split(['$', '{']).skip(1) {
        let name: String = rest
            .chars()
            .take_while(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || *c == '_')
            .collect();
        if name.strip_prefix("CONDUCTOR_").is_some_and(|tail| !tail.is_empty()) {
            out.push(name);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn variables_found_by_reference_only() {
        let mut out = Vec::new();
        conductor_variables(
            "cd \"$CONDUCTOR_ROOT_PATH\" && PORT=${CONDUCTOR_PORT} npm run dev # CONDUCTOR_NOTE",
            &mut out,
        );
        assert_eq!(out, ["CONDUCTOR_ROOT_PATH", "CONDUCTOR_PORT"]);
    }

    #[test]
    fn env_names_never_values() {
        let value: Value =
            serde_json::json!({"API_KEY": "secret", "local": {"DB_URL": "postgres://x"}});
        let mut names = Vec::new();
        env_names(&value, &mut names);
        names.sort();
        assert_eq!(names, ["API_KEY", "DB_URL"]);
        assert!(!format!("{names:?}").contains("secret"));
    }
}
