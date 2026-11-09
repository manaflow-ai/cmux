//! `diff.comments.list|save|delete|send`: the diff page's review comments,
//! kept by the session host until they are sent to the agent.
//!
//! Comments are keyed by a worktree root, an absolute path used only as a
//! key: nothing reads the folder it names. Each root's comments are one
//! file, `diff-comments/<sha256 of the root>.json` under the session's state
//! directory (directories 0700, files 0600, every write atomic), holding
//! `{root, comments}` in insertion order. A comment is the page's own JSON
//! object; the daemon owns its `id`, `createdAt` and `updatedAt`.
//!
//! Saves and deletes are keyed mutations in the session's
//! `resource_mutations` ledger, serialized per root, so a retry replays the
//! first result and concurrent writes never lose one another.
//!
//! A send (`send`) hands the caller's prompt to an acpmux session of this
//! machine as one queued prompt; once acpmux takes it, the sent comments
//! still at the caller's versions are removed, as a delete removes them.

use std::collections::HashMap;
use std::io;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock, PoisonError};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

use super::checkpoint::ledger::{self, Identity};
use super::checkpoint::record::{now_ms, rfc3339};
use super::checkpoint::store::{hex, private_directory, read_json, write_json};
use crate::resource::{ResourceError, ResourceOperation};
use crate::resource_router::ParsedResourceRequest;
use crate::{Mux, ResourceTarget};

mod send;
#[cfg(test)]
#[path = "diff_comments/send_tests.rs"]
mod send_tests;

/// Advertised in identify: the session host owns `diff.comments.*`.
pub(crate) const CAPABILITY: &str = "diff-comments-v1";
/// Advertised in identify: the session host answers `diff.comments.send`.
pub(crate) const SEND_CAPABILITY: &str = "diff-comments-send-v1";

const DIRECTORY: &str = "diff-comments";
/// The longest root, in bytes.
pub(super) const MAX_ROOT_BYTES: usize = 4096;
/// The largest stored comment, serialized.
pub(super) const MAX_COMMENT_BYTES: usize = 64 * 1024;
/// The most comments one root keeps.
pub(super) const MAX_COMMENTS: usize = 500;
/// The most ids one delete names.
pub(super) const MAX_DELETE_IDS: usize = 500;
/// The longest caller-chosen id.
const MAX_ID_LENGTH: usize = 128;
/// The longest prompt a send hands over, in bytes.
pub(super) const MAX_PROMPT_BYTES: usize = 256 * 1024;
/// The longest acpmux session id a send names.
const MAX_SESSION_LENGTH: usize = 128;

pub(super) fn handles(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        ResourceOperation::DiffCommentsList
            | ResourceOperation::DiffCommentsSave
            | ResourceOperation::DiffCommentsDelete
            | ResourceOperation::DiffCommentsSend
    )
}

pub(super) fn dispatch(
    mux: &Arc<Mux>,
    request: &ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let operation = request.envelope.operation.wire_name();
    mux.resolve_resource_path(ResourceTarget::Session, &request.selectors)?;
    let root = root(&request.fields)?;
    let store = Store::open(mux, operation)?;
    match request.envelope.operation {
        ResourceOperation::DiffCommentsList => {
            let file = store.read(root).map_err(|error| io_failed(operation, &error))?;
            Ok(json!({"root": root, "comments": file.sorted()}))
        }
        ResourceOperation::DiffCommentsSave => {
            let comment = comment(&request.fields)?;
            mutate(mux, &store, request, root, |file, key| save(file, root, key, comment))
        }
        ResourceOperation::DiffCommentsDelete => {
            let ids = ids(&request.fields)?;
            let versions = versions(&request.fields)?;
            mutate(mux, &store, request, root, |file, _| Ok(delete(file, &ids, &versions)))
        }
        ResourceOperation::DiffCommentsSend => send::send(mux, &store, request, root),
        // Dispatched only for the operations `handles` names; any other is refused, never a panic.
        _ => Err(ResourceError::operation_failed(
            operation,
            "unsupported",
            json!({"message": "diff_comments does not handle this operation"}),
        )),
    }
}

/// Runs one keyed mutation of `root`'s file under its lock: a replayed key
/// returns its first result; otherwise `change` edits the file, which is
/// written when it changed, and its value is committed to the ledger.
fn mutate(
    mux: &Arc<Mux>,
    store: &Store,
    request: &ParsedResourceRequest,
    root: &str,
    change: impl FnOnce(&mut File, &str) -> Result<(Value, bool), ResourceError>,
) -> Result<Value, ResourceError> {
    let operation = request.envelope.operation.wire_name();
    let key = super::checkpoint::mutation_key(request);
    let fingerprint = fingerprint(request);
    store.exclusive(root, || {
        if let Some(replayed) = ledger::prior(mux, &key, operation, &fingerprint)? {
            return Ok(replayed);
        }
        let mut file = store.read(root).map_err(|error| io_failed(operation, &error))?;
        let (value, changed) = change(&mut file, &key)?;
        if changed {
            store.write(root, &file).map_err(|error| io_failed(operation, &error))?;
        }
        ledger::commit(mux, &key, operation, &fingerprint, &value, false, &request.actor)
    })
}

/// The fingerprint of a diff comment mutation. Every one shares one
/// identity: the root is in the fields, so a key reused for another root is
/// idempotency.conflict.
fn fingerprint(request: &ParsedResourceRequest) -> Value {
    let identity = Identity { repository_id: DIRECTORY, worktree_id: "" };
    let selectors = serde_json::to_value(&request.selectors).unwrap_or(Value::Null);
    let fields = Value::Object(request.fields.clone());
    ledger::fingerprint(request.envelope.operation.wire_name(), &selectors, &fields, &identity)
}

/// A delivered send's clear: [`delete`]'s removal, answered as `{sent, cleared}`.
fn cleared(
    file: &mut File,
    ids: &[String],
    versions: &Map<String, Value>,
    sent: usize,
) -> (Value, bool) {
    let (deleted, changed) = delete(file, ids, versions);
    let cleared = deleted.get("ids").cloned().unwrap_or_else(|| json!([]));
    (json!({"sent": sent, "cleared": cleared}), changed)
}

/// Stamps and stores `comment`: an edit of the comment its `id` names, or a
/// new one. Returns `{comment}`.
fn save(
    file: &mut File,
    root: &str,
    key: &str,
    mut comment: Map<String, Value>,
) -> Result<(Value, bool), ResourceError> {
    const OPERATION: &str = "diff.comments.save";
    let now = rfc3339(now_ms());
    let given = comment.get("id").and_then(Value::as_str).map(str::to_string);
    let existing = given.as_deref().and_then(|id| file.position(id));
    let id = match (existing, given) {
        (Some(_), Some(id)) => id,
        (None, Some(id)) if well_formed_id(&id) => id,
        // A new id from the key and root: a retry after a crash between the
        // file write and the ledger commit edits the same comment again.
        _ => new_id(root, key),
    };
    let existing = existing.or_else(|| file.position(&id));
    let created = existing
        .and_then(|index| file.comments.get(index)?.get("createdAt").cloned())
        .filter(Value::is_string)
        .unwrap_or_else(|| Value::String(now.clone()));
    comment.insert("id".into(), Value::String(id));
    comment.insert("createdAt".into(), created);
    comment.insert("updatedAt".into(), Value::String(now));
    let bytes = serde_json::to_vec(&comment).map(|bytes| bytes.len()).unwrap_or(usize::MAX);
    if bytes > MAX_COMMENT_BYTES {
        return Err(ResourceError::validation_invalid(
            Some("comment"),
            format!("comment_too_large: a comment is at most {MAX_COMMENT_BYTES} bytes"),
        ));
    }
    match existing {
        Some(index) => {
            if let Some(slot) = file.comments.get_mut(index) {
                *slot = comment.clone();
            }
        }
        None if file.comments.len() >= MAX_COMMENTS => {
            let message = format!("this root already keeps {MAX_COMMENTS} comments");
            let extra = json!({"message": message, "maximum": MAX_COMMENTS});
            return Err(ResourceError::operation_failed(OPERATION, "too_many_comments", extra));
        }
        None => file.comments.push(comment.clone()),
    }
    Ok((json!({"comment": comment}), true))
}

/// Removes the comments `ids` names; unknown ids are ignored. A comment
/// `versions` names stays unless its `updatedAt` is still that version, so
/// an edit saved after the caller read it is never removed. Returns
/// `{deleted, ids}`: the count and the ids removed.
fn delete(file: &mut File, ids: &[String], versions: &Map<String, Value>) -> (Value, bool) {
    let mut removed = Vec::new();
    file.comments.retain(|comment| {
        let Some(id) = comment.get("id").and_then(Value::as_str) else { return true };
        if !ids.iter().any(|x| x == id) {
            return true;
        }
        if versions.get(id).is_some_and(|version| comment.get("updatedAt") != Some(version)) {
            return true;
        }
        removed.push(id.to_string());
        false
    });
    (json!({"deleted": removed.len(), "ids": removed}), !removed.is_empty())
}

/// `root`: an absolute path, at most 4096 bytes, without NUL.
fn root(fields: &Map<String, Value>) -> Result<&str, ResourceError> {
    let root = fields.get("root").and_then(Value::as_str).unwrap_or_default();
    if !root.starts_with('/') || root.len() > MAX_ROOT_BYTES || root.contains('\0') {
        return Err(ResourceError::validation_invalid(
            Some("root"),
            format!("root must be an absolute path of at most {MAX_ROOT_BYTES} bytes"),
        ));
    }
    Ok(root)
}

fn comment(fields: &Map<String, Value>) -> Result<Map<String, Value>, ResourceError> {
    fields.get("comment").and_then(Value::as_object).cloned().ok_or_else(|| {
        ResourceError::validation_invalid(Some("comment"), "comment must be an object")
    })
}

fn ids(fields: &Map<String, Value>) -> Result<Vec<String>, ResourceError> {
    let ids = fields
        .get("ids")
        .and_then(Value::as_array)
        .and_then(|ids| {
            ids.iter().map(|id| id.as_str().map(str::to_string)).collect::<Option<Vec<_>>>()
        })
        .ok_or_else(|| ResourceError::validation_invalid(Some("ids"), "ids must be strings"))?;
    if ids.len() > MAX_DELETE_IDS {
        return Err(ResourceError::validation_invalid(
            Some("ids"),
            format!("a delete or send names at most {MAX_DELETE_IDS} ids"),
        ));
    }
    Ok(ids)
}

/// `acp_session`: the acpmux session id, 1 to 128 visible ASCII characters.
fn acp_session(fields: &Map<String, Value>) -> Result<&str, ResourceError> {
    let session = fields.get("acp_session").and_then(Value::as_str).unwrap_or_default();
    if !(1..=MAX_SESSION_LENGTH).contains(&session.len())
        || !session.bytes().all(|byte| byte.is_ascii_graphic())
    {
        return Err(ResourceError::validation_invalid(
            Some("acp_session"),
            format!("acp_session must be 1 to {MAX_SESSION_LENGTH} visible ASCII characters"),
        ));
    }
    Ok(session)
}

/// `text`: the prompt, not blank, at most 256 KiB.
fn prompt(fields: &Map<String, Value>) -> Result<&str, ResourceError> {
    let text = fields.get("text").and_then(Value::as_str).unwrap_or_default();
    if text.trim().is_empty() || text.len() > MAX_PROMPT_BYTES {
        return Err(ResourceError::validation_invalid(
            Some("text"),
            format!("text must be a prompt of 1 to {MAX_PROMPT_BYTES} bytes"),
        ));
    }
    Ok(text)
}

/// `versions`: optional, each id's `updatedAt` as the caller last read it.
fn versions(fields: &Map<String, Value>) -> Result<Map<String, Value>, ResourceError> {
    match fields.get("versions") {
        None | Some(Value::Null) => Ok(Map::new()),
        Some(Value::Object(versions))
            if versions.len() <= MAX_DELETE_IDS && versions.values().all(Value::is_string) =>
        {
            Ok(versions.clone())
        }
        Some(_) => Err(ResourceError::validation_invalid(
            Some("versions"),
            format!("versions maps at most {MAX_DELETE_IDS} ids to updatedAt strings"),
        )),
    }
}

/// A caller-chosen id the daemon keeps: 1 to 128 visible ASCII characters.
fn well_formed_id(id: &str) -> bool {
    (1..=MAX_ID_LENGTH).contains(&id.len()) && id.bytes().all(|byte| byte.is_ascii_graphic())
}

fn new_id(root: &str, key: &str) -> String {
    let digest = Sha256::digest(format!("diff-comment\0{root}\0{key}").as_bytes());
    format!("dc_{}", hex(digest.get(..16).unwrap_or_default()))
}

fn io_failed(operation: &str, error: &io::Error) -> ResourceError {
    let message = format!("the diff comment store could not be read or written: {error}");
    ResourceError::operation_failed(operation, "store_failed", json!({"message": message}))
}

/// One root's comments, as stored.
#[derive(Debug, Default, Serialize, Deserialize)]
pub(super) struct File {
    root: String,
    comments: Vec<Map<String, Value>>,
}

impl File {
    fn position(&self, id: &str) -> Option<usize> {
        self.comments
            .iter()
            .position(|comment| comment.get("id").and_then(Value::as_str) == Some(id))
    }

    /// Oldest first: by `createdAt` (RFC 3339 UTC, which sorts as text),
    /// then insertion order.
    fn sorted(&self) -> Vec<&Map<String, Value>> {
        let mut comments: Vec<_> = self.comments.iter().collect();
        comments.sort_by(|left, right| {
            let created = |comment: &Map<String, Value>| {
                comment.get("createdAt").and_then(Value::as_str).unwrap_or_default().to_string()
            };
            created(left).cmp(&created(right))
        });
        comments
    }
}

/// The session's diff comment directory.
pub(super) struct Store {
    directory: PathBuf,
}

impl Store {
    /// The session's store, or `no_state_directory` for an in-memory session.
    fn open(mux: &Mux, operation: &str) -> Result<Self, ResourceError> {
        let Some(session) = mux.session_state_directory() else {
            let message = "this session keeps no durable state, so it cannot hold diff comments";
            return Err(ResourceError::operation_failed(
                operation,
                "no_state_directory",
                json!({"message": message}),
            ));
        };
        Ok(Self::at(session.join(DIRECTORY)))
    }

    pub(super) fn at(directory: PathBuf) -> Self {
        Self { directory }
    }

    fn path(&self, root: &str) -> PathBuf {
        self.directory.join(format!("{}.json", hex(&Sha256::digest(root.as_bytes()))))
    }

    /// `root`'s comments; none when it has no file.
    pub(super) fn read(&self, root: &str) -> io::Result<File> {
        let file: Option<File> = read_json(&self.path(root))?;
        Ok(file
            .filter(|file| file.root == root)
            .unwrap_or_else(|| File { root: root.to_string(), comments: Vec::new() }))
    }

    pub(super) fn write(&self, root: &str, file: &File) -> io::Result<()> {
        private_directory(&self.directory)?;
        write_json(&self.path(root), file)
    }

    /// Runs `body` holding `root`'s lock, shared by every connection.
    fn exclusive<T>(&self, root: &str, body: impl FnOnce() -> T) -> T {
        static LOCKS: OnceLock<Mutex<HashMap<PathBuf, Arc<Mutex<()>>>>> = OnceLock::new();
        let lock = LOCKS
            .get_or_init(Mutex::default)
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .entry(self.path(root))
            .or_default()
            .clone();
        let _guard = lock.lock().unwrap_or_else(PoisonError::into_inner);
        body()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn comment(value: Value) -> Map<String, Value> {
        value.as_object().unwrap().clone()
    }

    #[test]
    fn save_stamps_edits_and_deletes() {
        let mut file = File::default();
        let (first, _) = save(&mut file, "/r", "k1", comment(json!({"message": "a"}))).unwrap();
        let id = first["comment"]["id"].as_str().unwrap().to_string();
        assert!(id.starts_with("dc_") && id.len() == 35, "{first}");
        let created = first["comment"]["createdAt"].clone();
        assert_eq!(first["comment"]["updatedAt"], created);
        let edit = comment(json!({"id": id, "message": "b", "createdAt": "1999"}));
        let (edited, _) = save(&mut file, "/r", "k2", edit).unwrap();
        assert_eq!(edited["comment"]["createdAt"], created, "createdAt is the daemon's");
        assert_eq!(edited["comment"]["message"], "b");
        assert_eq!(file.comments.len(), 1);
        let (chosen, _) = save(&mut file, "/r", "k3", comment(json!({"id": "mine"}))).unwrap();
        assert_eq!(chosen["comment"]["id"], "mine");
        let (bad, _) = save(&mut file, "/r", "k4", comment(json!({"id": "has space"}))).unwrap();
        assert!(bad["comment"]["id"].as_str().unwrap().starts_with("dc_"));
        let stale = Map::from_iter([("mine".to_string(), json!("1999"))]);
        let (kept, changed) = delete(&mut file, &["mine".into()], &stale);
        assert_eq!(
            kept,
            json!({"deleted": 0, "ids": []}),
            "an edit since the caller read it stays"
        );
        assert!(!changed);
        let (deleted, changed) = delete(&mut file, &[id.clone(), "unknown".into()], &Map::new());
        assert_eq!(deleted, json!({"deleted": 1, "ids": [id]}));
        assert!(changed);
        assert_eq!(file.comments.len(), 2);
    }

    #[test]
    fn save_refuses_large_comments_and_full_roots() {
        let mut file = File::default();
        let large = comment(json!({"message": "x".repeat(MAX_COMMENT_BYTES)}));
        assert_eq!(save(&mut file, "/r", "k", large).unwrap_err().code, "validation.invalid");
        for index in 0..MAX_COMMENTS {
            save(&mut file, "/r", &format!("k{index}"), comment(json!({}))).unwrap();
        }
        let error = save(&mut file, "/r", "full", comment(json!({}))).unwrap_err();
        assert_eq!(error.details["reason"], "too_many_comments", "{error:?}");
    }

    #[test]
    fn send_clears_only_comments_still_at_their_sent_version() {
        let mut file = File::default();
        let (a, _) = save(&mut file, "/r", "k1", comment(json!({"message": "a"}))).unwrap();
        let (b, _) = save(&mut file, "/r", "k2", comment(json!({"message": "b"}))).unwrap();
        let (a, b) = (a["comment"].clone(), b["comment"].clone());
        let ids = [a["id"].as_str().unwrap().to_string(), b["id"].as_str().unwrap().to_string()];
        let versions = Map::from_iter([
            (ids[0].clone(), a["updatedAt"].clone()),
            (ids[1].clone(), json!("1999-01-01T00:00:00.000Z")),
        ]);
        let (answer, changed) = cleared(&mut file, &ids, &versions, ids.len());
        assert_eq!(answer, json!({"sent": 2, "cleared": [ids[0]]}));
        assert!(changed);
        assert_eq!(file.comments.len(), 1, "the comment edited since the send stays");
        let (answer, changed) = cleared(&mut file, &ids[..1], &Map::new(), 1);
        assert_eq!(answer, json!({"sent": 1, "cleared": []}));
        assert!(!changed);
    }

    #[test]
    fn send_fields_are_checked() {
        let fields = |value: Value| value.as_object().unwrap().clone();
        let ok = fields(json!({"acp_session": "fake-session-1", "text": "Review comment"}));
        assert_eq!(acp_session(&ok).unwrap(), "fake-session-1");
        assert_eq!(prompt(&ok).unwrap(), "Review comment");
        for bad in [json!({}), json!({"acp_session": ""}), json!({"acp_session": "a b"})] {
            let error = acp_session(&fields(bad)).unwrap_err();
            assert_eq!(error.code, "validation.invalid");
        }
        let large = "x".repeat(MAX_PROMPT_BYTES + 1);
        for bad in [json!({}), json!({"text": " \n"}), json!({"text": large})] {
            assert_eq!(prompt(&fields(bad)).unwrap_err().code, "validation.invalid");
        }
        assert!(prompt(&fields(json!({"text": "x".repeat(MAX_PROMPT_BYTES)}))).is_ok());
    }

    #[test]
    fn store_round_trips_and_lists_oldest_first() {
        let directory =
            std::env::temp_dir().join(format!("diff-comments-{}-{}", std::process::id(), now_ms()));
        let store = Store::at(directory.clone());
        assert!(store.read("/repo").unwrap().comments.is_empty());
        let mut file = store.read("/repo").unwrap();
        file.comments.push(comment(json!({"id": "b", "createdAt": "2026-11-07T12:00:01.000Z"})));
        file.comments.push(comment(json!({"id": "a", "createdAt": "2026-11-07T12:00:00.000Z"})));
        store.write("/repo", &file).unwrap();
        let read = store.read("/repo").unwrap();
        let ids: Vec<_> = read.sorted().iter().map(|c| c["id"].as_str().unwrap()).collect();
        assert_eq!(ids, ["a", "b"]);
        assert!(store.read("/other").unwrap().comments.is_empty());
        let _ = std::fs::remove_dir_all(directory);
    }
}
