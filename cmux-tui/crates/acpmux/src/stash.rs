//! The composer's stashed drafts (`_acpmux/stash_list`, `_acpmux/stash_push`, `_acpmux/stash_get`,
//! `_acpmux/stash_drop`, `_acpmux/stash_move`): a draft put aside with ⌃S and brought back later, a short stack per chat.
//!
//! The pane's own storage does not outlive its page (its web views use a store that is not kept),
//! so the stacks live here, in acpmux's home: `stash/<sha256 of the chat>.json`, one file per chat
//! (`{"version": 1, "chat": ..., "drafts": [...]}`, newest first). A chat is the composer's key: a
//! session id, or a new chat's own key until it has one. A draft is its text and its chips as the
//! page sent them (contents included), so a reload, a new page or a relaunch brings it back whole.
//!
//! A list answers the chips without their contents (`data`, `text`, anything nested) and the start of the text
//! ([`ROW_TEXT_CHARS`]): the row needs only a preview and the chips' count. A take is two steps: `stash_get` reads the whole draft, and `stash_drop` removes it once
//! the composer holds it, so a page that goes away in between loses nothing.
//!
//! A new chat's stack follows it once it has a session: `stash_move` merges it into the session's
//! in one write under the lock, then removes the new chat's file, so no failure midway and no
//! trimming of old chats loses a draft, and a move tried again changes nothing more.
//!
//! A push may name the draft it `replaces` (a restore that puts the prompt's own draft on the stack
//! in its place): one write takes that one out and puts the new one on top, so a full stack lets no
//! other draft go.
//!
//! Bounds: [`STASH_LIMIT`] drafts per chat (a push past it lets the oldest go) and [`STASH_CHATS`]
//! chats (the file written longest ago goes). One draft is at most what `stash_get` can answer in
//! one message (`rpc::MAX_MESSAGE_BYTES` less [`REPLY_SLACK`]): a larger one is refused, and the
//! composer keeps it, so every stashed draft can come back.

use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use crate::home_fs;
use crate::rpc::{RpcError, method};

/// The stash folder in acpmux's home.
pub const DIR: &str = "stash";
/// A chat file's format version.
pub const VERSION: u32 = 1;
/// The most drafts one chat holds.
pub const STASH_LIMIT: usize = 5;
/// The most chats whose stacks are kept.
pub const STASH_CHATS: usize = 50;
/// The longest chat key.
pub const MAX_CHAT_CHARS: usize = 256;
/// The most of a draft's text a list row holds (`stash_get` answers it whole).
pub const ROW_TEXT_CHARS: usize = 2000;
/// What a `stash_get` reply holds besides the draft: its framing, id and field names.
pub const REPLY_SLACK: usize = 64 * 1024;

/// Every read-modify-write holds this, so two pushes at once never lose one.
static WRITES: Mutex<()> = Mutex::new(());

/// One stashed draft.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Draft {
    pub id: String,
    pub text: String,
    /// The chips as the page sent them.
    pub attachments: Vec<Value>,
    /// When it was stashed (ms since the epoch).
    pub at: u64,
}

impl Draft {
    /// The draft as a list shows it: its chips' plain fields only (no contents, nothing nested such
    /// as a video's frames), and at most
    /// [`ROW_TEXT_CHARS`] of its text, so a full stack of large drafts still lists in one message.
    pub fn row(&self) -> Value {
        let chips: Vec<Value> = self
            .attachments
            .iter()
            .map(|chip| match chip {
                Value::Object(map) => {
                    let light: Map<String, Value> = map
                        .iter()
                        .filter(|(key, value)| {
                            !matches!(key.as_str(), "data" | "text")
                                && !value.is_object()
                                && !value.is_array()
                        })
                        .map(|(key, value)| (key.clone(), value.clone()))
                        .collect();
                    Value::Object(light)
                }
                other => other.clone(),
            })
            .collect();
        let text: String = self.text.chars().take(ROW_TEXT_CHARS).collect();
        json!({"id": self.id, "text": text, "attachments": chips, "at": self.at})
    }
}

#[derive(Debug, Serialize, Deserialize)]
struct ChatFile {
    version: u32,
    chat: String,
    drafts: Vec<Draft>,
}

/// A new draft's id: a UUIDv7 (its time and 74 random bits), unique across chats and daemon
/// relaunches, so a restore, a drop or a move never takes one draft for another.
fn new_id() -> String {
    format!("stash-{}", uuid::Uuid::now_v7().simple())
}

/// The stash folder: `stash` in acpmux's home.
pub fn dir() -> PathBuf {
    crate::config::home().join(DIR)
}

/// Chat `chat`'s file in `dir`: a digest of the key, so any key is a safe name.
pub fn chat_path(dir: &Path, chat: &str) -> PathBuf {
    dir.join(format!("{}.json", crate::sha256::sha256_hex(chat.as_bytes())))
}

/// Serves the five methods, with the stash in [`dir`].
pub fn handle(m: &str, params: &Value) -> Result<Value, RpcError> {
    let dir = dir();
    let chat = chat_param(params)?;
    match m {
        method::MUX_STASH_LIST => {
            let drafts = load(&chat_path(&dir, chat)).map_err(unreadable)?;
            Ok(json!({"drafts": drafts.iter().map(Draft::row).collect::<Vec<_>>()}))
        }
        method::MUX_STASH_PUSH => {
            let text = params.get("text").and_then(Value::as_str).unwrap_or_default();
            let attachments = match params.get("attachments") {
                None | Some(Value::Null) => Vec::new(),
                Some(Value::Array(list)) if list.iter().all(Value::is_object) => list.clone(),
                Some(_) => {
                    return Err(RpcError::invalid_params("attachments must be a list of chips"));
                }
            };
            let replaces = params.get("replaces").and_then(Value::as_str);
            let draft = push(&dir, chat, text, attachments, replaces, crate::store::now_ms())?;
            Ok(json!({"draft": draft.row()}))
        }
        method::MUX_STASH_GET => {
            let id = id_param(params)?;
            let drafts = load(&chat_path(&dir, chat)).map_err(unreadable)?;
            let draft = drafts
                .into_iter()
                .find(|d| d.id == id)
                .ok_or_else(|| RpcError::not_found("no stashed draft with that id"))?;
            Ok(json!({"draft": draft}))
        }
        method::MUX_STASH_DROP => Ok(json!({"removed": remove(&dir, chat, id_param(params)?)?})),
        method::MUX_STASH_MOVE => {
            let to = params
                .get("to")
                .and_then(Value::as_str)
                .filter(|to| !to.is_empty() && to.chars().count() <= MAX_CHAT_CHARS)
                .ok_or_else(|| {
                    RpcError::invalid_params(format!("to must be 1 to {MAX_CHAT_CHARS} characters"))
                })?;
            let moved = move_stack(&dir, chat, to)?;
            Ok(json!({"moved": moved.count, "ids": moved.ids}))
        }
        _ => Err(RpcError::method_not_found(m)),
    }
}

/// Puts a draft on top of `chat`'s stack, in place of `replaces` when it is there; the oldest past
/// [`STASH_LIMIT`] let go.
pub fn push(
    dir: &Path,
    chat: &str,
    text: &str,
    attachments: Vec<Value>,
    replaces: Option<&str>,
    now_ms: u64,
) -> Result<Draft, RpcError> {
    if text.trim().is_empty() && attachments.is_empty() {
        return Err(RpcError::invalid_params("the draft is empty"));
    }
    let draft = Draft { id: new_id(), text: text.to_owned(), attachments, at: now_ms };
    // Only a draft `stash_get` can answer whole is kept.
    let whole = serde_json::to_vec(&draft).map_err(|e| RpcError::internal(e.to_string()))?.len();
    if whole + REPLY_SLACK > crate::rpc::MAX_MESSAGE_BYTES {
        return Err(RpcError::invalid_params(format!(
            "the draft is too large to stash (more than {} MiB); it stays in the prompt",
            (crate::rpc::MAX_MESSAGE_BYTES - REPLY_SLACK) >> 20
        )));
    }
    let _held = WRITES.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let path = chat_path(dir, chat);
    let mut drafts = load(&path).map_err(unreadable)?;
    if let Some(replaces) = replaces {
        drafts.retain(|d| d.id != replaces);
    }
    drafts.insert(0, draft.clone());
    drafts.truncate(STASH_LIMIT);
    write(&path, chat, &drafts).map_err(not_saved)?;
    trim_chats(dir, &path);
    Ok(draft)
}

/// Removes draft `id` from `chat`'s stack; whether it was there.
pub fn remove(dir: &Path, chat: &str, id: &str) -> Result<bool, RpcError> {
    let _held = WRITES.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let path = chat_path(dir, chat);
    let mut drafts = load(&path).map_err(unreadable)?;
    let before = drafts.len();
    drafts.retain(|d| d.id != id);
    if drafts.len() == before {
        return Ok(false);
    }
    if drafts.is_empty() {
        // A home that was replaced keeps its files, as a write would refuse it.
        crate::config::refuse_lost_home(&path).map_err(io::Error::other).map_err(not_saved)?;
        match home_fs::remove_file(&path) {
            Ok(()) => {}
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Err(e) => return Err(not_saved(e)),
        }
    } else {
        write(&path, chat, &drafts).map_err(not_saved)?;
    }
    Ok(true)
}

/// Moves `from`'s stack onto `to`'s: one write of `to` with `from`'s drafts on top in their order
/// (as pushing each would put them) and `to`'s own below, the oldest past [`STASH_LIMIT`] let go,
/// then `from`'s file removed; when it cannot be, `to` is put back and the move fails whole. A
/// draft `to` already holds (only a put-back that failed too leaves one) is not added again.
pub fn move_stack(dir: &Path, from: &str, to: &str) -> Result<Moved, RpcError> {
    move_stack_with(dir, from, to, |path| home_fs::remove_file(path))
}

/// [`move_stack`], with the source's removal given (a test makes it fail).
fn move_stack_with(
    dir: &Path,
    from: &str,
    to: &str,
    remove_source: impl Fn(&Path) -> io::Result<()>,
) -> Result<Moved, RpcError> {
    if from == to {
        return Ok(Moved::default());
    }
    let _held = WRITES.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let from_path = chat_path(dir, from);
    let moving = load(&from_path).map_err(unreadable)?;
    if moving.is_empty() {
        return Ok(Moved::default());
    }
    let ids: Vec<String> = moving.iter().map(|d| d.id.clone()).collect();
    let to_path = chat_path(dir, to);
    let own = load(&to_path).map_err(unreadable)?;
    // Ids are unique across chats and relaunches (`new_id`): one `to` holds is a draft an
    // earlier move put there before its removal failed.
    let mut drafts: Vec<Draft> =
        moving.into_iter().filter(|draft| !own.iter().any(|d| d.id == draft.id)).collect();
    let moved = drafts.len();
    drafts.extend(own.iter().cloned());
    // Every draft is written first, none let go: until the source is gone, a failure at any later
    // step (the put-back too) loses no draft, and a retry finds them all by id.
    write(&to_path, to, &drafts).map_err(not_saved)?;
    // A source that stays puts `to` back as it was: a move is whole or not at all, so no draft is
    // in two stacks for a later move to take twice or one of them to lose.
    let removed =
        crate::config::refuse_lost_home(&from_path).map_err(io::Error::other).and_then(|()| {
            match remove_source(&from_path) {
                Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
                other => other,
            }
        });
    if let Err(e) = removed {
        let put_back =
            if own.is_empty() { home_fs::remove_file(&to_path) } else { write(&to_path, to, &own) };
        return Err(match put_back {
            Ok(()) => not_saved(e),
            // Both stacks hold the moved drafts, `to` all of its own as well: a retry adds none twice.
            Err(back) => not_saved(io::Error::other(format!(
                "{e}; the stack it moved into could not be put back either ({back})"
            ))),
        });
    }
    // The source is gone: now the oldest past the limit go, as a push lets them. A failure here
    // leaves a longer stack, which the next push trims.
    if drafts.len() > STASH_LIMIT {
        drafts.truncate(STASH_LIMIT);
        let _ = write(&to_path, to, &drafts);
    }
    trim_chats(dir, &to_path);
    Ok(Moved { count: moved, ids })
}

/// What a move did: how many drafts it added to the stack, and the ids of every draft it took from
/// the source (those `to` held already too), so the page knows the drafts it waits for arrived.
#[derive(Debug, Default, PartialEq)]
pub struct Moved {
    pub count: usize,
    pub ids: Vec<String>,
}

/// Lets the chats written longest ago go once more than [`STASH_CHATS`] have a stack; never `keep`.
fn trim_chats(dir: &Path, keep: &Path) {
    let Ok(entries) = fs::read_dir(dir) else { return };
    let mut files: Vec<(std::time::SystemTime, PathBuf)> = entries
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "json") && path != keep)
        .filter_map(|path| Some((fs::metadata(&path).ok()?.modified().ok()?, path)))
        .collect();
    let over = (files.len() + 1).saturating_sub(STASH_CHATS);
    files.sort();
    for (_, path) in files.into_iter().take(over) {
        if crate::config::refuse_lost_home(&path).is_err() {
            return;
        }
        let _ = home_fs::remove_file(path);
    }
}

fn chat_param(params: &Value) -> Result<&str, RpcError> {
    let chat = params
        .get("chat")
        .and_then(Value::as_str)
        .ok_or_else(|| RpcError::invalid_params("chat is required"))?;
    if chat.is_empty() || chat.chars().count() > MAX_CHAT_CHARS {
        return Err(RpcError::invalid_params(format!(
            "chat must be 1 to {MAX_CHAT_CHARS} characters"
        )));
    }
    Ok(chat)
}

fn id_param(params: &Value) -> Result<&str, RpcError> {
    params
        .get("id")
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
        .ok_or_else(|| RpcError::invalid_params("id is required"))
}

fn unreadable(reason: String) -> RpcError {
    RpcError::internal(format!(
        "{reason}; the stash is not changed until it is fixed or moved away"
    ))
}

fn not_saved(e: io::Error) -> RpcError {
    RpcError::internal(format!("the stash is not saved: {e}"))
}

/// A chat's drafts: none when its file is missing, an error when it cannot be read, does not
/// parse, or has another version.
fn load(path: &Path) -> Result<Vec<Draft>, String> {
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(format!("{} cannot be read: {e}", path.display())),
    };
    let file: ChatFile = serde_json::from_slice(&bytes)
        .map_err(|e| format!("{} is not a stash file: {e}", path.display()))?;
    if file.version != VERSION {
        return Err(format!(
            "{} is version {}, which this acpmux does not read",
            path.display(),
            file.version
        ));
    }
    Ok(file.drafts)
}

/// Writes a chat's file (0600, through a temp file and a rename), as `prompts.rs` does.
fn write(path: &Path, chat: &str, drafts: &[Draft]) -> io::Result<()> {
    static SAVES: AtomicU64 = AtomicU64::new(0);
    crate::config::refuse_lost_home(path).map_err(io::Error::other)?;
    let dir = path.parent().ok_or_else(|| io::Error::other("no parent folder"))?;
    home_fs::create_dir_all(dir, 0o700)?;
    let file = ChatFile { version: VERSION, chat: chat.to_owned(), drafts: drafts.to_vec() };
    let bytes = serde_json::to_vec(&file).map_err(io::Error::other)?;
    let n = SAVES.fetch_add(1, Ordering::Relaxed);
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
#[path = "stash_tests.rs"]
mod tests;
