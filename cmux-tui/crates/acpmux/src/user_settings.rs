//! The cmux settings file, read only (the app's settings owner writes it):
//! `CMUX_NEXT_CONFIG_FILE`, else `~/.config/cmux/cmux-next.json` (in
//! `~/.config/cmux-next/` on macOS): `cmux_config::location`'s `config_path`,
//! read with `cmux_config::jsonc`, the settings owner's own reader. Classic is
//! imported by the app only after the person consents. Read at each use,
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

/// The single NEXT settings file `read` looks at. The settings watcher
/// (`hub/settings_watch.rs`) watches it.
pub fn paths() -> Vec<PathBuf> {
    location::migrate_legacy_once();
    vec![resolved_path()]
}

/// The path for an environment and a home lookup. With no home at all the
/// settings file stays relative to the working directory, as before.
fn path_from(
    var: impl Fn(&str) -> Option<OsString>,
    home_dir: impl Fn() -> Option<PathBuf>,
) -> PathBuf {
    let env = |name: &str| match name {
        "HOME" => Some(var("HOME").or_else(|| home_dir().map(OsString::from)).unwrap_or_default()),
        _ => var(name),
    };
    location::config_path_from(env)
}

/// The settings file as it is now.
pub fn read() -> Settings {
    let path = resolved_path();
    match std::fs::read_to_string(&path) {
        Ok(text) => match document(&text) {
            Some(doc) => Settings::Parsed(doc),
            None => Settings::Unreadable(format!("{}: not valid JSONC", path.display())),
        },
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Settings::Missing,
        Err(error) => Settings::Unreadable(format!("{}: {error}", path.display())),
    }
}

/// The NEXT settings file passed to a server that cmux starts.
pub fn resolved_path() -> PathBuf {
    path_from(|name| std::env::var_os(name).filter(|v| !v.is_empty()), dirs::home_dir)
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
