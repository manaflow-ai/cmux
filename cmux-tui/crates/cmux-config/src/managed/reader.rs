//! Where managed preferences come from (Swift `ManagedPreferenceReaders`
//! and `ManagedPreferenceLocation`).

use std::path::{Path, PathBuf};

use serde_json::Value;

use super::{FILE_OVERRIDE_KEY, ManagedPreferences};
use crate::value::{canonical, number_value};

/// Reads the managed preferences. Implementations must be cheap enough to
/// call on every reload and must not block on the network.
pub trait ManagedReader: Send + Sync {
    fn read(&self) -> ManagedPreferences;

    /// Files whose changes mean the managed values may have changed (wake-up
    /// hints for the watcher; values are always read through `read`).
    fn watch_paths(&self) -> Vec<PathBuf> {
        Vec::new()
    }
}

/// Fixed values (tests, previews).
#[derive(Debug, Clone, Default)]
pub struct FixedManagedReader(pub ManagedPreferences);

impl ManagedReader for FixedManagedReader {
    fn read(&self) -> ManagedPreferences {
        self.0.clone()
    }
}

/// A JSON file shaped like a profile payload (Linux `/etc/cmux/managed.json`):
/// top-level keys are forced, keys under a top-level `Recommended` object
/// are recommended. A missing or unreadable file is empty.
#[derive(Debug, Clone)]
pub struct JsonFileManagedReader {
    pub path: PathBuf,
}

impl ManagedReader for JsonFileManagedReader {
    fn read(&self) -> ManagedPreferences {
        let Ok(text) = std::fs::read_to_string(&self.path) else {
            return ManagedPreferences::default();
        };
        match serde_json::from_str::<Value>(&text) {
            Ok(Value::Object(members)) => {
                split(members.into_iter().map(|(key, value)| (key, canonical(value))))
            }
            _ => ManagedPreferences::default(),
        }
    }

    fn watch_paths(&self) -> Vec<PathBuf> {
        vec![self.path.clone()]
    }
}

/// A property list file shaped like a profile payload (debug builds and
/// tests): top-level keys are forced, keys under `Recommended` are
/// recommended. A missing or unreadable file is empty.
#[derive(Debug, Clone)]
pub struct PlistFileManagedReader {
    pub path: PathBuf,
}

impl ManagedReader for PlistFileManagedReader {
    fn read(&self) -> ManagedPreferences {
        let Ok(plist::Value::Dictionary(dictionary)) = plist::Value::from_file(&self.path) else {
            return ManagedPreferences::default();
        };
        split(
            dictionary
                .into_iter()
                .filter_map(|(key, value)| json_from_plist(&value).map(|json| (key, json))),
        )
    }

    fn watch_paths(&self) -> Vec<PathBuf> {
        vec![self.path.clone()]
    }
}

fn split(entries: impl Iterator<Item = (String, Value)>) -> ManagedPreferences {
    let mut result = ManagedPreferences::default();
    for (key, value) in entries {
        match (key.as_str(), value) {
            ("Recommended", Value::Object(nested)) => {
                result.recommended = nested.into_iter().collect();
            }
            (_, value) => {
                result.forced.insert(key, value);
            }
        }
    }
    result
}

/// A property list value as JSON. Dates, data and uids have no cmux.json
/// form and are dropped.
pub fn json_from_plist(value: &plist::Value) -> Option<Value> {
    match value {
        plist::Value::Boolean(flag) => Some(Value::Bool(*flag)),
        plist::Value::Integer(integer) => {
            let x = integer
                .as_signed()
                .map(|i| i as f64)
                .or_else(|| integer.as_unsigned().map(|u| u as f64))?;
            Some(number_value(x))
        }
        plist::Value::Real(x) => Some(number_value(*x)),
        plist::Value::String(text) => Some(Value::String(text.clone())),
        plist::Value::Array(items) => {
            Some(Value::Array(items.iter().filter_map(json_from_plist).collect()))
        }
        plist::Value::Dictionary(dictionary) => Some(Value::Object(
            dictionary
                .iter()
                .filter_map(|(key, item)| json_from_plist(item).map(|json| (key.clone(), json)))
                .collect(),
        )),
        _ => None,
    }
}

/// The platform reader. Debug builds honor `CMUX_NEXT_MANAGED_PREFS_FILE`
/// (a plist on macOS, a JSON file elsewhere); release builds never do, so an
/// environment variable cannot override an administrator's profile.
pub fn default_reader(env: impl Fn(&str) -> Option<String>) -> Box<dyn ManagedReader> {
    if cfg!(debug_assertions)
        && let Some(path) = env(FILE_OVERRIDE_KEY).filter(|path| !path.is_empty())
    {
        let path = expand_tilde(&path, env("HOME"));
        return override_reader(path);
    }
    platform_reader()
}

fn expand_tilde(path: &str, home: Option<String>) -> PathBuf {
    let path = PathBuf::from(path);
    match (path.strip_prefix("~"), home) {
        (Ok(rest), Some(home)) => Path::new(&home).join(rest),
        _ => path,
    }
}

#[cfg(target_os = "macos")]
fn override_reader(path: PathBuf) -> Box<dyn ManagedReader> {
    Box::new(PlistFileManagedReader { path })
}

#[cfg(not(target_os = "macos"))]
fn override_reader(path: PathBuf) -> Box<dyn ManagedReader> {
    Box::new(JsonFileManagedReader { path })
}

#[cfg(target_os = "macos")]
fn platform_reader() -> Box<dyn ManagedReader> {
    Box::new(super::CfManagedReader::new(crate::schema::Schema::embedded()))
}

#[cfg(not(target_os = "macos"))]
fn platform_reader() -> Box<dyn ManagedReader> {
    Box::new(JsonFileManagedReader { path: PathBuf::from(super::LINUX_MANAGED_FILE) })
}
