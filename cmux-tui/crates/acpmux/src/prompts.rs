//! The person's saved prompts (`_acpmux/prompts_list`, `_acpmux/prompts_save`,
//! `_acpmux/prompts_delete`): named prompt texts the agent chat's composer can insert.
//!
//! Two sources, merged at each list and sorted by name (case-insensitive):
//!
//! - The store, `prompts.json` in acpmux's home (`{"version": 1, "prompts": [...]}`), which
//!   `prompts_save` and `prompts_delete` change. A missing file is an empty store. A file that
//!   cannot be read or parsed is never written over: a list shows the settings prompts alone,
//!   and a save or delete is refused until the person fixes or moves the file.
//! - The settings file's `agentPane.savedPrompts` (`user_settings.rs`), an object of name to
//!   text, read at each list and read only here. A value that is not a string is skipped.
//!
//! Names compare case-insensitively: a saved prompt replaces the settings prompt of the same
//! name in the list, and a save of an existing name replaces it in place.

use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::home_fs;
use crate::rpc::{RpcError, method};

/// The store's file name in acpmux's home.
pub const FILE: &str = "prompts.json";
/// The settings key that names read-only prompts.
pub const SETTINGS_KEY: &str = "agentPane.savedPrompts";
/// The store file's format version.
pub const VERSION: u32 = 1;
/// The most characters a name may have.
pub const MAX_NAME_CHARS: usize = 64;
/// The most prompts the store keeps.
pub const MAX_SAVED: usize = 200;

/// Every read-modify-write of the store holds this, so two saves at once never lose one.
static WRITES: Mutex<()> = Mutex::new(());

/// Where a listed prompt comes from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Source {
    /// The store: the person saved it, and may replace or delete it.
    Saved,
    /// The settings file's `agentPane.savedPrompts`: changed only there.
    Settings,
}

/// One prompt as the methods answer it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Prompt {
    pub name: String,
    pub text: String,
    pub source: Source,
    /// When it was last saved (ms since the epoch); `null` for a settings prompt.
    pub updated_at: Option<u64>,
}

/// The store file.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct StoreFile {
    version: u32,
    prompts: Vec<Saved>,
}

/// One prompt in the store file.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Saved {
    name: String,
    text: String,
    updated_at: u64,
}

impl Saved {
    fn row(&self) -> Prompt {
        Prompt {
            name: self.name.clone(),
            text: self.text.clone(),
            source: Source::Saved,
            updated_at: Some(self.updated_at),
        }
    }
}

/// The store's path: `prompts.json` in acpmux's home, beside `chat-settings.json`.
pub fn path() -> PathBuf {
    crate::config::home().join(FILE)
}

/// The settings prompts now: `agentPane.savedPrompts` of the settings file, or none when the
/// file is missing, unreadable or names none.
pub fn settings_now() -> Vec<(String, String)> {
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => {
            settings_prompts(crate::user_settings::value(&doc, SETTINGS_KEY).as_ref())
        }
        crate::user_settings::Settings::Missing | crate::user_settings::Settings::Unreadable(_) => {
            Vec::new()
        }
    }
}

/// The `(name, text)` pairs of an `agentPane.savedPrompts` value: its string values, by trimmed
/// name, the first of names that differ only in case. Anything else is skipped.
pub fn settings_prompts(value: Option<&Value>) -> Vec<(String, String)> {
    let Some(Value::Object(map)) = value else {
        return Vec::new();
    };
    let mut out: Vec<(String, String)> = Vec::new();
    for (name, text) in map {
        let (name, Some(text)) = (name.trim(), text.as_str()) else {
            continue;
        };
        if name.is_empty() || out.iter().any(|(seen, _)| same_name(seen, name)) {
            continue;
        }
        out.push((name.to_owned(), text.to_owned()));
    }
    out
}

/// Serves the three methods, with the store at [`path`] and the settings prompts of now.
pub fn handle(m: &str, params: &Value) -> Result<Value, RpcError> {
    let (path, settings) = (path(), settings_now());
    if m == method::MUX_PROMPTS_LIST {
        return Ok(json!({"prompts": list(&path, &settings)}));
    }
    let name = string_param(params, "name")?;
    if m == method::MUX_PROMPTS_SAVE {
        let text = string_param(params, "text")?;
        let prompt = save(&path, name, text, crate::store::now_ms())?;
        return Ok(json!({"prompt": prompt}));
    }
    if m == method::MUX_PROMPTS_DELETE {
        return Ok(json!({"removed": delete(&path, &settings, name)?}));
    }
    Err(RpcError::method_not_found(m))
}

/// Every prompt, saved and from settings, sorted by name. A saved prompt hides the settings
/// prompt of the same name. A store that cannot be read lists the settings prompts alone.
pub fn list(path: &Path, settings: &[(String, String)]) -> Vec<Prompt> {
    let saved = load(path).unwrap_or_default();
    let mut rows: Vec<Prompt> = saved.iter().map(Saved::row).collect();
    for (name, text) in settings {
        if !saved.iter().any(|s| same_name(&s.name, name)) {
            rows.push(Prompt {
                name: name.clone(),
                text: text.clone(),
                source: Source::Settings,
                updated_at: None,
            });
        }
    }
    rows.sort_by(|a, b| {
        a.name.to_lowercase().cmp(&b.name.to_lowercase()).then_with(|| a.name.cmp(&b.name))
    });
    rows
}

/// Saves `text` under `name` (trimmed), replacing a saved prompt of the same name in place.
pub fn save(path: &Path, name: &str, text: &str, now_ms: u64) -> Result<Prompt, RpcError> {
    let name = valid_name(name)?;
    if text.trim().is_empty() {
        return Err(RpcError::invalid_params("text is empty"));
    }
    // No size bound: a saved prompt is a prompt, and nothing on the send path caps one.
    let _held = WRITES.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let mut saved = load(path).map_err(unreadable)?;
    let prompt = Saved { name: name.to_owned(), text: text.to_owned(), updated_at: now_ms };
    match saved.iter().position(|s| same_name(&s.name, name)) {
        Some(at) => {
            if let Some(slot) = saved.get_mut(at) {
                *slot = prompt.clone();
            }
        }
        None if saved.len() >= MAX_SAVED => {
            return Err(RpcError::invalid_params(format!(
                "You already have {MAX_SAVED} saved prompts; delete one before you save another."
            )));
        }
        None => saved.push(prompt.clone()),
    }
    write(path, &saved).map_err(|e| RpcError::internal(format!("{FILE} is not saved: {e}")))?;
    Ok(prompt.row())
}

/// Deletes the saved prompt named `name` (trimmed, any case); whether one was there. A name only
/// the settings file has is refused: it is changed there.
pub fn delete(path: &Path, settings: &[(String, String)], name: &str) -> Result<bool, RpcError> {
    let name = name.trim();
    let _held = WRITES.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let mut saved = load(path).map_err(unreadable)?;
    let before = saved.len();
    saved.retain(|s| !same_name(&s.name, name));
    if saved.len() == before {
        if let Some((named, _)) = settings.iter().find(|(n, _)| same_name(n, name)) {
            return Err(RpcError::invalid_params(format!(
                "{named} comes from cmux-next.json; remove it there"
            )));
        }
        return Ok(false);
    }
    write(path, &saved).map_err(|e| RpcError::internal(format!("{FILE} is not saved: {e}")))?;
    Ok(true)
}

/// A required string param.
fn string_param<'a>(params: &'a Value, key: &str) -> Result<&'a str, RpcError> {
    params
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| RpcError::invalid_params(format!("{key} is required")))
}

/// `name` trimmed, when it is 1 to [`MAX_NAME_CHARS`] characters on one line.
fn valid_name(name: &str) -> Result<&str, RpcError> {
    let name = name.trim();
    if name.is_empty() {
        return Err(RpcError::invalid_params("name is empty"));
    }
    if name.chars().count() > MAX_NAME_CHARS {
        return Err(RpcError::invalid_params(format!(
            "name is longer than {MAX_NAME_CHARS} characters"
        )));
    }
    if name.contains(['\n', '\r']) {
        return Err(RpcError::invalid_params("name must be one line"));
    }
    Ok(name)
}

/// Whether two names are the same prompt's.
fn same_name(a: &str, b: &str) -> bool {
    a.to_lowercase() == b.to_lowercase()
}

/// The refusal of a write to a store that cannot be read.
fn unreadable(reason: String) -> RpcError {
    RpcError::internal(format!(
        "{reason}; saved prompts are not changed until it is fixed or moved away"
    ))
}

/// The store's prompts: none when the file is missing, an error when it cannot be read, does not
/// parse, or has another version.
fn load(path: &Path) -> Result<Vec<Saved>, String> {
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(format!("{} cannot be read: {e}", path.display())),
    };
    let file: StoreFile = serde_json::from_slice(&bytes)
        .map_err(|e| format!("{} is not a saved prompts file: {e}", path.display()))?;
    if file.version != VERSION {
        return Err(format!(
            "{} is version {}, which this acpmux does not read",
            path.display(),
            file.version
        ));
    }
    Ok(file.prompts)
}

/// Writes the store (0600, through a temp file and a rename), as `ChatSettings::save` does.
fn write(path: &Path, prompts: &[Saved]) -> io::Result<()> {
    static SAVES: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    crate::config::refuse_lost_home(path).map_err(io::Error::other)?;
    let dir = path.parent().ok_or_else(|| io::Error::other("no parent folder"))?;
    home_fs::create_dir_all(dir, 0o700)?;
    let file = StoreFile { version: VERSION, prompts: prompts.to_vec() };
    let bytes = serde_json::to_vec_pretty(&file).map_err(io::Error::other)?;
    let n = SAVES.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let tmp = path.with_extension(format!("json.{}.{n}.tmp", std::process::id()));
    let options =
        home_fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(&tmp);
    let written = options.and_then(|mut out| {
        out.write_all(&bytes)?;
        out.sync_all()?;
        home_fs::rename(&tmp, path)
    });
    if written.is_err() {
        let _ = home_fs::remove_file(&tmp);
    }
    written
}

#[cfg(test)]
#[path = "prompts_tests.rs"]
mod tests;
