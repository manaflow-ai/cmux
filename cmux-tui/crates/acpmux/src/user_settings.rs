//! The cmux settings file, read only (the app's settings owner writes it):
//! `CMUX_NEXT_CONFIG_FILE`, else `~/.config/cmux/cmux-next.json`, else
//! classic `~/.config/cmux/cmux.json` before the app's first launch copies
//! it: `cmux_config::location`'s `config_path` and `seed_path`, read with
//! `cmux_config::jsonc`, the settings owner's own reader. Read at each use,
//! so a settings change applies to the next new chat.
//!
//! [`read_for`] is what a chat started in a folder reads: the user's file with the folder's
//! project layer over it (`<project>/.cmux/cmux-next.json`, `cmux_config::project`), only when
//! that project folder is trusted, only for the per-project keys, and never over a value MDM
//! forces. A key a chat reads at its start reads it through `read_for(cwd)`, and joins
//! `cmux_config::project::PROJECT_KEYS`.

use cmux_config::{jsonc, location};
use serde_json::Value;
use std::ffi::OsString;
use std::path::{Path, PathBuf};

/// The override the app and tests set.
pub use cmux_config::CONFIG_OVERRIDE;

/// What the settings file holds now.
pub enum Settings {
    /// No settings file: every key has its default.
    Missing,
    /// The file, parsed.
    Parsed(Value),
    /// A file that exists but cannot be read or parsed: a key whose default
    /// widens what runs without asking must not take that default.
    Unreadable(String),
}

/// The files `read` looks at, first that exists wins: the override alone,
/// else `cmux-next.json` then classic `cmux.json`. The settings watcher
/// (`hub/settings_watch.rs`) watches these.
pub fn paths() -> Vec<PathBuf> {
    paths_from(|name| std::env::var_os(name).filter(|v| !v.is_empty()), dirs::home_dir)
}

/// `paths` for an environment and a home lookup. With no home at all both
/// files stay relative to the working directory, as before cmux-config read
/// them (#42064 F1): `seed_path_from` alone would drop classic `cmux.json`.
fn paths_from(
    var: impl Fn(&str) -> Option<OsString>,
    home_dir: impl Fn() -> Option<PathBuf>,
) -> Vec<PathBuf> {
    let env = |name: &str| match name {
        "HOME" => Some(var("HOME").or_else(|| home_dir().map(OsString::from)).unwrap_or_default()),
        _ => var(name),
    };
    std::iter::once(location::config_path_from(env)).chain(location::seed_path_from(env)).collect()
}

/// The settings file as it is now.
pub fn read() -> Settings {
    let read_one = |path: &std::path::Path| match std::fs::read_to_string(path) {
        Ok(text) => Some(match document(&text) {
            Some(doc) => Settings::Parsed(doc),
            None => Settings::Unreadable(format!("{}: not valid JSONC", path.display())),
        }),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => Some(Settings::Unreadable(format!("{}: {e}", path.display()))),
    };
    paths().iter().find_map(|path| read_one(path)).unwrap_or(Settings::Missing)
}

/// The settings file `read` reads: the first of [`paths`] that exists, else
/// the first (the one the app creates). What a server cmux starts is told to
/// read (`agent_tools::cmux_server`).
pub fn resolved_path() -> PathBuf {
    let paths = paths();
    // `paths` always lists the config path first, so the empty default is never taken.
    paths.iter().find(|path| path.exists()).or_else(|| paths.first()).cloned().unwrap_or_default()
}

/// The settings a chat started in `cwd` reads: [`read`] with the per-project keys of `cwd`'s
/// trusted project over it (see the module doc). A user file that does not parse stays
/// unreadable: a project file never makes it readable.
pub fn read_for(cwd: &Path) -> Settings {
    let user = read();
    let Some(layer) = trusted_project(cwd) else { return user };
    if layer.values.is_empty() {
        return user;
    }
    let forced =
        cmux_config::managed::default_reader(|name| std::env::var(name).ok()).read().forced;
    overlay(user, &layer, &|key: &str| forced.contains_key(key))
}

/// `cwd`'s project layer when its project folder is trusted (`trust::get`'s level; a damaged
/// trust record is no answer). None: no project file, or the folder is not trusted.
fn trusted_project(cwd: &Path) -> Option<cmux_config::project::ProjectLayer> {
    let home = dirs::home_dir();
    let folder = cmux_config::project::find(cwd, home.as_deref())?;
    let paths = crate::trust::Paths::current()?;
    let reply = crate::trust::get(&paths, &folder.to_string_lossy()).ok()?;
    (reply["level"] == "trusted")
        .then(|| cmux_config::project::ProjectLayer::read(&folder, cmux_config::Schema::embedded()))
}

/// `user` with `layer`'s values over it, except the keys `managed` says a managed layer sets.
/// A flat key in the user's file (`"agents.promptCache": ...`) gives way to the project's value.
pub fn overlay(
    user: Settings,
    layer: &cmux_config::project::ProjectLayer,
    managed: &dyn Fn(&str) -> bool,
) -> Settings {
    let mut doc = match user {
        Settings::Parsed(doc) if doc.is_object() => doc,
        Settings::Missing => Value::Object(Default::default()),
        other => return other,
    };
    for (key, value) in layer.values.iter().filter(|(key, _)| !managed(key)) {
        if let Some(members) = doc.as_object_mut() {
            members.remove(key);
        }
        doc = cmux_config::value::with_value(
            &doc,
            value.clone(),
            &cmux_config::keypath::key_path(key),
        );
    }
    Settings::Parsed(doc)
}

/// The settings file's text, or `None` when there is none to read.
pub fn text() -> Option<String> {
    match read() {
        Settings::Parsed(doc) => Some(doc.to_string()),
        Settings::Missing | Settings::Unreadable(_) => None,
    }
}

/// The settings document (JSONC: `//` and `/* */` comments, trailing
/// commas and a BOM, as the app's settings owner reads it), or `None` when
/// it does not parse.
pub fn document(text: &str) -> Option<Value> {
    serde_json::from_str::<Value>(&jsonc::strip(text).ok()?).ok()
}

/// The value at a dotted settings key (`agents.defaultPermissionMode`), in
/// either form the settings owner writes: nested objects or one flat key.
pub fn value(doc: &Value, key: &str) -> Option<Value> {
    if let Some(v) = doc.get(key) {
        return Some(v.clone());
    }
    let pointer = format!("/{}", key.replace('.', "/"));
    doc.pointer(&pointer).cloned()
}

#[cfg(test)]
#[path = "user_settings_tests.rs"]
mod tests;
