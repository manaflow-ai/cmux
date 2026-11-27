//! The cmux settings file, read only (the app's settings owner writes it):
//! `CMUX_NEXT_CONFIG_FILE`, else `~/.config/cmux/cmux-next.json`, else
//! classic `~/.config/cmux/cmux.json` before the app's first launch copies
//! it: `cmux_config::location`'s `config_path` and `seed_path`, read with
//! `cmux_config::jsonc`, the settings owner's own reader. Read at each use,
//! so a settings change applies to the next new chat.

use cmux_config::{jsonc, location};
use serde_json::Value;
use std::ffi::OsString;
use std::path::PathBuf;

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
mod tests {
    use super::*;

    #[test]
    fn with_no_home_both_files_stay_relative() {
        assert_eq!(
            paths_from(|_| None, || None),
            [PathBuf::from(".config/cmux/cmux-next.json"), PathBuf::from(".config/cmux/cmux.json")]
        );
    }

    #[test]
    fn home_and_override_resolve_as_cmux_config_does() {
        let home = |name: &str| (name == "HOME").then(|| OsString::from("/h"));
        assert_eq!(
            paths_from(home, || None),
            [
                PathBuf::from("/h/.config/cmux/cmux-next.json"),
                PathBuf::from("/h/.config/cmux/cmux.json")
            ]
        );
        let fallback = paths_from(|_| None, || Some(PathBuf::from("/d")));
        assert_eq!(fallback[1], PathBuf::from("/d/.config/cmux/cmux.json"));
        let over = |name: &str| match name {
            "HOME" => Some(OsString::from("/h")),
            CONFIG_OVERRIDE => Some(OsString::from("~/t.json")),
            _ => None,
        };
        assert_eq!(paths_from(over, || None), [PathBuf::from("/h/t.json")]);
    }
}
