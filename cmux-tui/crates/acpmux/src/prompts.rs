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

use crate::rpc::{RpcError, method};

/// The store's file name in acpmux's home.
pub const FILE: &str = "prompts.json";
/// The settings key that names read-only prompts.
pub const SETTINGS_KEY: &str = "agentPane.savedPrompts";
/// The store file's format version.
pub const VERSION: u32 = 1;
/// The most characters a name may have.
pub const MAX_NAME_CHARS: usize = 64;
/// The most bytes a prompt's text may have.
pub const MAX_TEXT_BYTES: usize = 32 * 1024;
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
    if text.len() > MAX_TEXT_BYTES {
        return Err(RpcError::invalid_params(format!(
            "text is longer than {} KiB",
            MAX_TEXT_BYTES / 1024
        )));
    }
    let _held = WRITES.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let mut saved = load(path).map_err(unreadable)?;
    let prompt = Saved { name: name.to_owned(), text: text.to_owned(), updated_at: now_ms };
    match saved.iter_mut().find(|s| same_name(&s.name, name)) {
        Some(slot) => *slot = prompt.clone(),
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
    fs::create_dir_all(dir)?;
    let file = StoreFile { version: VERSION, prompts: prompts.to_vec() };
    let bytes = serde_json::to_vec_pretty(&file).map_err(io::Error::other)?;
    let n = SAVES.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let tmp = path.with_extension(format!("json.{}.{n}.tmp", std::process::id()));
    let mut options = fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let written = options.open(&tmp).and_then(|mut out| {
        out.write_all(&bytes)?;
        out.sync_all()?;
        fs::rename(&tmp, path)
    });
    if written.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    written
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> (tempfile::TempDir, PathBuf) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(FILE);
        (dir, path)
    }

    fn settings(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
        pairs.iter().map(|(n, t)| ((*n).to_owned(), (*t).to_owned())).collect()
    }

    fn names(rows: &[Prompt]) -> Vec<&str> {
        rows.iter().map(|p| p.name.as_str()).collect()
    }

    #[test]
    fn a_missing_file_is_an_empty_store() {
        let (_dir, path) = store();
        assert!(list(&path, &[]).is_empty());
    }

    #[test]
    fn a_save_is_listed_sorted_and_written_as_version_one() {
        let (_dir, path) = store();
        let saved = save(&path, "  review  ", "Review this diff.", 7).unwrap();
        assert_eq!(
            saved,
            Prompt {
                name: "review".into(),
                text: "Review this diff.".into(),
                source: Source::Saved,
                updated_at: Some(7),
            }
        );
        save(&path, "Alpha", "a", 8).unwrap();
        save(&path, "beta", "b", 9).unwrap();
        assert_eq!(names(&list(&path, &[])), ["Alpha", "beta", "review"]);
        let file: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        assert_eq!(file["version"], 1);
        let first = json!({"name": "review", "text": "Review this diff.", "updatedAt": 7});
        assert_eq!(file["prompts"][0], first);
        let row = serde_json::to_value(&list(&path, &[])[0]).unwrap();
        assert_eq!(row, json!({"name": "Alpha", "text": "a", "source": "saved", "updatedAt": 8}));
    }

    #[test]
    fn the_same_name_in_any_case_replaces_in_place() {
        let (_dir, path) = store();
        save(&path, "Review", "old", 1).unwrap();
        save(&path, "other", "o", 2).unwrap();
        save(&path, "REVIEW", "new", 3).unwrap();
        let rows = list(&path, &[]);
        assert_eq!(names(&rows), ["other", "REVIEW"]);
        assert_eq!((rows[1].text.as_str(), rows[1].updated_at), ("new", Some(3)));
        let file: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        assert_eq!(file["prompts"][0]["name"], "REVIEW", "replaced where it was");
    }

    #[test]
    fn names_and_texts_out_of_bounds_are_refused() {
        let (_dir, path) = store();
        let refused = |name: &str, text: &str| save(&path, name, text, 1).unwrap_err();
        assert_eq!(refused("   ", "t").code, -32602);
        assert_eq!(refused(&"n".repeat(65), "t").code, -32602);
        assert_eq!(refused("two\nlines", "t").code, -32602);
        assert_eq!(refused("n", "  \n ").code, -32602);
        assert_eq!(refused("n", &"x".repeat(MAX_TEXT_BYTES + 1)).code, -32602);
        save(&path, &"é".repeat(64), &"x".repeat(MAX_TEXT_BYTES), 1).unwrap();
        assert_eq!(list(&path, &[]).len(), 1);
    }

    #[test]
    fn the_store_keeps_at_most_two_hundred() {
        let (_dir, path) = store();
        for i in 0..MAX_SAVED {
            save(&path, &format!("p{i}"), "t", 1).unwrap();
        }
        let refused = save(&path, "one more", "t", 2).unwrap_err();
        assert_eq!(refused.code, -32602);
        assert!(refused.message.contains("200 saved prompts"), "{}", refused.message);
        save(&path, "P0", "replaced", 3).unwrap();
        assert_eq!(list(&path, &[]).len(), MAX_SAVED);
    }

    #[test]
    fn delete_removes_a_saved_prompt_in_any_case() {
        let (_dir, path) = store();
        save(&path, "Review", "t", 1).unwrap();
        assert!(delete(&path, &[], " review ").unwrap());
        assert!(!delete(&path, &[], "review").unwrap());
        assert!(list(&path, &[]).is_empty());
    }

    #[test]
    fn settings_prompts_merge_and_a_saved_one_wins() {
        let (_dir, path) = store();
        save(&path, "review", "mine", 5).unwrap();
        let from_settings = settings(&[("Review", "theirs"), ("deploy", "ship it")]);
        let rows = list(&path, &from_settings);
        assert_eq!(names(&rows), ["deploy", "review"]);
        assert_eq!((rows[0].source, rows[0].updated_at), (Source::Settings, None));
        assert_eq!((rows[1].source, rows[1].text.as_str()), (Source::Saved, "mine"));
        assert_eq!(serde_json::to_value(&rows[0]).unwrap()["updatedAt"], Value::Null);
        // Deleting the saved one shows the settings one again.
        assert!(delete(&path, &from_settings, "review").unwrap());
        let rows = list(&path, &from_settings);
        assert_eq!((rows[1].name.as_str(), rows[1].source), ("Review", Source::Settings));
    }

    #[test]
    fn a_settings_only_prompt_is_not_deleted() {
        let (_dir, path) = store();
        let refused = delete(&path, &settings(&[("Deploy", "ship it")]), "deploy").unwrap_err();
        assert_eq!(refused.code, -32602);
        assert_eq!(refused.message, "Deploy comes from cmux-next.json; remove it there");
        assert!(!path.exists(), "nothing was written");
    }

    #[test]
    fn the_settings_value_keeps_only_strings() {
        let value = json!({" a ": "one", "b": 2, "c": null, " ": "blank", "d": {"x": 1}});
        assert_eq!(settings_prompts(Some(&value)), settings(&[("a", "one")]));
        // Names that differ only in case are one prompt.
        let value = json!({"a": "one", "A": "two"});
        assert_eq!(settings_prompts(Some(&value)).len(), 1);
        assert!(settings_prompts(Some(&json!(["a"]))).is_empty());
        assert!(settings_prompts(None).is_empty());
    }

    #[test]
    fn an_unreadable_store_is_never_written_over() {
        let (_dir, path) = store();
        for text in ["{not json", r#"{"version": 2, "prompts": []}"#] {
            fs::write(&path, text).unwrap();
            let rows = list(&path, &settings(&[("deploy", "ship it")]));
            assert_eq!(names(&rows), ["deploy"]);
            assert_eq!(save(&path, "new", "t", 1).unwrap_err().code, -32603);
            assert_eq!(delete(&path, &[], "new").unwrap_err().code, -32603);
            assert_eq!(fs::read_to_string(&path).unwrap(), text, "the file is as it was");
        }
    }

    #[test]
    fn concurrent_saves_keep_every_prompt() {
        let (_dir, path) = store();
        let threads: Vec<_> = (0..4)
            .map(|t| {
                let path = path.clone();
                std::thread::spawn(move || {
                    for i in 0..10 {
                        save(&path, &format!("t{t}-{i}"), "t", 1).unwrap();
                    }
                })
            })
            .collect();
        for thread in threads {
            thread.join().unwrap();
        }
        assert_eq!(list(&path, &[]).len(), 40);
    }
}
