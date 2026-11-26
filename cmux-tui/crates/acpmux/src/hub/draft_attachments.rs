//! Part of `Hub`; see `hub/mod.rs`. A chat's unsent composer attachments, kept with its draft.
//!
//! Leo, 2026-11-22: "there's prob additional lifecycle stuff with making sure they dont get lost
//! sometimes if random state happens". The draft's text (`SessionMeta::composer_draft`) holds each
//! placed attachment as its id between two marks (webviews `attachments.ts` `inlineToken`), so
//! the text says where each one sits; this keeps the attachments those ids name, in their order,
//! with their contents, in the chat's own folder beside `session.json`:
//!
//! ```text
//! sessions/<id>/draft-attachments/list.json      the chips, contents left out, in order
//! sessions/<id>/draft-attachments/<digest>.data  a chip's bytes (base64, as the page sent them)
//! sessions/<id>/draft-attachments/<digest>.text  a chip's text (a pasted chip's, a text file's)
//! ```
//!
//! So every path that shows the chat again reads the same chips: a daemon or app restart, another
//! pane or client, a session switch and back, a reconnect, and a move to another machine
//! (`transfer.rs` export and import carry the folder; a committed move forgets it here, as the
//! draft's text). A chip's contents travel once: a later write names it without them and the
//! folder keeps the file it has (`held` answers which ids it holds contents for). An empty list
//! forgets the chat's chips. File names come from the chip's id (a digest) and a fixed field
//! name, never from the list, so a bundle's list cannot name a file outside the folder.

use super::*;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// The folder in a chat's own folder.
pub(crate) const DIR: &str = "draft-attachments";
const LIST: &str = "list.json";
/// A chip's contents fields, each kept in a file of its own.
const CONTENTS: [&str; 2] = ["data", "text"];

/// A chat's chips where its store keeps no folder (the memory store): by session id, for the
/// daemon's life, as the memory store keeps the rest of the chat.
static IN_MEMORY: std::sync::LazyLock<std::sync::Mutex<HashMap<String, Vec<Value>>>> =
    std::sync::LazyLock::new(Default::default);

/// One chat's reads and writes take turns: two panes writing the same chat never interleave.
static TURNS: std::sync::LazyLock<std::sync::Mutex<HashMap<PathBuf, Arc<std::sync::Mutex<()>>>>> =
    std::sync::LazyLock::new(Default::default);

fn turn(folder: &Path) -> Arc<std::sync::Mutex<()>> {
    let mut turns = TURNS.lock().unwrap_or_else(|e| e.into_inner());
    turns.entry(folder.to_owned()).or_default().clone()
}

/// The list on disk: the chips without their contents, and which contents fields each id has a
/// file for.
#[derive(Default, Serialize, Deserialize)]
struct Saved {
    attachments: Vec<Value>,
    #[serde(default)]
    held: BTreeMap<String, Vec<String>>,
}

fn file_name(id: &str, field: &str) -> String {
    let digest = Sha256::digest(id.as_bytes());
    let hex: String = digest.iter().take(16).map(|b| format!("{b:02x}")).collect();
    format!("{hex}.{field}")
}

fn saved(folder: &Path) -> std::io::Result<Option<Saved>> {
    let path = folder.join(LIST);
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e),
    };
    serde_json::from_str(&text).map(Some).map_err(std::io::Error::other)
}

/// The chips as the page sent them: a list of objects, each with a non-empty string `id`, no id
/// twice. Anything else is refused whole, so a bad write never replaces a good list.
pub(crate) fn checked(list: &Value) -> Result<Vec<Value>, RpcError> {
    let Some(chips) = list.as_array() else {
        return Err(RpcError::invalid_params("attachments must be a list"));
    };
    let mut seen = std::collections::HashSet::new();
    for chip in chips {
        let id = chip.get("id").and_then(Value::as_str).filter(|id| !id.is_empty());
        let Some(id) = id else {
            return Err(RpcError::invalid_params("each attachment needs a string id"));
        };
        if !chip.is_object() || !seen.insert(id) {
            return Err(RpcError::invalid_params(format!("attachment {id:?} is not one chip")));
        }
    }
    Ok(chips.clone())
}

/// The chips kept in `folder`, in order, with every declared contents file restored. A missing
/// declared file is an error so a transfer cannot commit a partial draft.
pub(crate) fn read(folder: &Path) -> std::io::Result<Vec<Value>> {
    let Some(saved) = saved(folder)? else { return Ok(Vec::new()) };
    let mut chips = saved.attachments;
    for chip in &mut chips {
        let Some(id) = chip.get("id").and_then(Value::as_str).map(str::to_owned) else { continue };
        let Some(fields) = saved.held.get(&id) else { continue };
        for field in fields.iter().filter(|f| CONTENTS.contains(&f.as_str())) {
            let contents = std::fs::read_to_string(folder.join(file_name(&id, field)))?;
            if let Some(object) = chip.as_object_mut() {
                object.insert(field.to_owned(), Value::String(contents));
            }
        }
    }
    Ok(chips)
}

/// Keeps `chips` (already [`checked`]) in `folder`, and answers the ids whose contents it holds.
/// A chip without a contents field keeps the file the folder has for it; none forgets them all.
/// The contents go first and the list last, atomically: a write that fails part way leaves the
/// list before it and the files it names.
pub(crate) fn write(folder: &Path, chips: &[Value]) -> std::io::Result<Vec<String>> {
    if chips.is_empty() {
        return match crate::home_fs::remove_dir_all(folder) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e),
            _ => Ok(Vec::new()),
        };
    }
    crate::home_fs::create_dirs(folder)?;
    let before = saved(folder)?.unwrap_or_default();
    let mut saved = Saved::default();
    for chip in chips {
        let mut chip = chip.clone();
        let id = chip.get("id").and_then(Value::as_str).unwrap_or_default().to_owned();
        let mut held = Vec::new();
        for field in CONTENTS {
            let name = file_name(&id, field);
            match chip.as_object_mut().and_then(|o| o.remove(field)) {
                Some(Value::String(contents)) => {
                    crate::home_fs::write_json_private(&folder.join(&name), contents.as_bytes())?;
                    held.push(field.to_owned());
                }
                // Sent without it: the file kept before stays, if there is one.
                None if before.held.get(&id).is_some_and(|f| f.iter().any(|f| f == field))
                    && folder.join(&name).is_file() =>
                {
                    held.push(field.to_owned());
                }
                _ => {}
            }
        }
        if !held.is_empty() {
            saved.held.insert(id, held);
        }
        saved.attachments.push(chip);
    }
    let list = serde_json::to_vec(&saved).map_err(std::io::Error::other)?;
    crate::home_fs::write_json_private(&folder.join(LIST), &list)?;
    // Files no chip names now (a chip taken out) go.
    let named: std::collections::HashSet<String> = saved
        .held
        .iter()
        .flat_map(|(id, fields)| fields.iter().map(move |f| file_name(id, f)))
        .chain([LIST.to_owned()])
        .collect();
    if let Ok(entries) = std::fs::read_dir(folder) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if !named.contains(&name) && entry.path().is_file() {
                let _ = crate::home_fs::remove_file(entry.path());
            }
        }
    }
    Ok(saved.held.into_keys().collect())
}

impl Hub {
    /// The chat's attachments folder; none for a store that keeps no folders.
    fn draft_attachments_folder(&self, session: &Session) -> Option<PathBuf> {
        self.store.session_path(&session.id).map(|dir| dir.join(DIR))
    }

    /// `_acpmux/draft_get {attachments: true}`: the chat's unsent chips, in order, contents and all.
    pub async fn draft_attachments(&self, session: &Session) -> Result<Vec<Value>, RpcError> {
        let Some(folder) = self.draft_attachments_folder(session) else {
            let kept = IN_MEMORY.lock().unwrap_or_else(|e| e.into_inner());
            return Ok(kept.get(&session.id).cloned().unwrap_or_default());
        };
        let read = tokio::task::spawn_blocking(move || {
            let turn = turn(&folder);
            let _turn = turn.lock().unwrap_or_else(|e| e.into_inner());
            read(&folder)
        })
        .await
        .map_err(|e| RpcError::internal(format!("draft attachments read task: {e}")))?;
        read.map_err(|e| RpcError::internal(format!("draft attachments could not be read: {e}")))
    }

    /// `_acpmux/draft_set {attachments}`: keeps `chips` as the chat's unsent chips, and answers
    /// the ids whose contents acpmux holds. Answered once they are on disk.
    pub async fn set_draft_attachments(
        &self,
        session: &Session,
        chips: Vec<Value>,
    ) -> Result<Vec<String>, RpcError> {
        if session.moving().is_some() {
            return Err(RpcError::invalid_params(queue::moving_error(session).message));
        }
        let Some(folder) = self.draft_attachments_folder(session) else {
            let mut kept = IN_MEMORY.lock().unwrap_or_else(|e| e.into_inner());
            let before = kept.remove(&session.id).unwrap_or_default();
            if chips.is_empty() {
                return Ok(Vec::new());
            }
            // Contents travel once here too: a chip sent without them keeps what was held.
            let merged: Vec<Value> = chips
                .into_iter()
                .map(|mut chip| {
                    let id = chip.get("id").cloned();
                    if let Some(old) = before.iter().find(|c| c.get("id") == id.as_ref()) {
                        for field in CONTENTS {
                            if chip.get(field).is_none()
                                && let Some(v) = old.get(field)
                            {
                                if let Some(object) = chip.as_object_mut() {
                                    object.insert(field.to_owned(), v.clone());
                                }
                            }
                        }
                    }
                    chip
                })
                .collect();
            let mut held: Vec<String> = merged
                .iter()
                .filter(|c| CONTENTS.iter().any(|f| c.get(*f).is_some()))
                .filter_map(|c| c.get("id").and_then(Value::as_str).map(str::to_owned))
                .collect();
            held.sort();
            kept.insert(session.id.clone(), merged);
            return Ok(held);
        };
        let written = tokio::task::spawn_blocking(move || {
            let turn = turn(&folder);
            let _turn = turn.lock().unwrap_or_else(|e| e.into_inner());
            write(&folder, &chips)
        })
        .await
        .map_err(|e| RpcError::internal(format!("draft attachments: {e}")))?;
        written.map_err(|e| RpcError::internal(format!("draft attachments were not kept: {e}")))
    }

    /// A move's bundle carries the chat's chips (`transfer.rs` export).
    pub(super) fn export_draft_attachments(&self, session: &Session, dir: &Path) -> Result<()> {
        let chips = match self.draft_attachments_folder(session) {
            Some(folder) => {
                let lock = turn(&folder);
                let _lock = lock.lock().unwrap_or_else(|e| e.into_inner());
                read(&folder)?
            }
            None => IN_MEMORY
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .get(&session.id)
                .cloned()
                .unwrap_or_default(),
        };
        if !chips.is_empty() {
            write(&dir.join(DIR), &chips)?;
        }
        Ok(())
    }

    /// The bundle's chips become the imported chat's (`transfer.rs` import), checked as a write
    /// of the page's is. Errors abort the import before the source can commit.
    pub(super) fn import_draft_attachments(&self, bundle: &Path, id: &str) -> Result<()> {
        let chips = read(&bundle.join(DIR))?;
        if chips.is_empty() {
            return Ok(());
        }
        checked(&Value::Array(chips.clone())).map_err(|e| anyhow::anyhow!(e.message))?;
        match self.store.session_path(id) {
            Some(dir) => {
                let folder = dir.join(DIR);
                let lock = turn(&folder);
                let _lock = lock.lock().unwrap_or_else(|e| e.into_inner());
                write(&folder, &chips)?;
            }
            None => {
                IN_MEMORY.lock().unwrap_or_else(|e| e.into_inner()).insert(id.to_owned(), chips);
            }
        }
        Ok(())
    }

    /// A committed move: the chips live on the target now, as the draft's text does.
    pub(super) fn forget_draft_attachments(&self, session: &Session) -> Result<()> {
        match self.draft_attachments_folder(session) {
            Some(folder) => {
                let lock = turn(&folder);
                let _lock = lock.lock().unwrap_or_else(|e| e.into_inner());
                write(&folder, &[])?;
            }
            None => {
                IN_MEMORY.lock().unwrap_or_else(|e| e.into_inner()).remove(&session.id);
            }
        }
        Ok(())
    }
}

#[cfg(test)]
#[path = "draft_attachments_tests.rs"]
mod tests;
