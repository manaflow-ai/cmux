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
//! With `keep`, they stay instead, each with a `thread` naming the chat and
//! prompt it went out as; `list` fills in the reply once that turn ends.

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
/// Advertised in identify: a send with `keep` leaves its comments as threads,
/// and `diff.comments.list` brings each thread the agent's reply
/// (`crate::comment_threads`). Any surface's comment (`surface`: diff,
/// browser, terminal) is stored, sent and answered the same way.
pub(crate) const THREADS_CAPABILITY: &str = "comment-threads-v1";

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
            let mut file = store.read(root).map_err(|error| io_failed(operation, &error))?;
            if file.has_open_threads() {
                file = answer_threads(mux, &store, root, file)
                    .map_err(|error| io_failed(operation, &error))?;
            }
            let mut listed = json!({"root": root, "comments": file.sorted()});
            // A pull request review's worktree (`git.review.start`) says which
            // pull request its comments go to.
            if let (Some(review), Some(fields)) = (&file.review, listed.as_object_mut()) {
                fields.insert("review".into(), review.clone());
            }
            Ok(listed)
        }
        ResourceOperation::DiffCommentsSave => {
            let comment = comment(&request.fields)?;
            mutate(mux, &store, request, root, |file, key| save(file, root, key, comment))
        }
        ResourceOperation::DiffCommentsDelete => {
            let ids = ids(&request.fields)?;
            let versions = versions(&request.fields, false)?;
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
pub(super) fn mutate(
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

/// A delivered `keep` send: each sent comment still at its version stays,
/// with `thread: {promptId, acpSession, sentAt, state: "sent"}`, answered as
/// `{sent, cleared: [], threaded}`. The comment's `updatedAt` is not touched: it is the
/// person's edit, which a later send's `versions` compares.
fn threaded(
    file: &mut File,
    ids: &[String],
    versions: &Map<String, Value>,
    sent: usize,
    prompt_id: &str,
    acp_session: &str,
) -> (Value, bool) {
    let now_at = now_ms();
    let now = rfc3339(now_at);
    let mut threaded = Vec::new();
    for comment in &mut file.comments {
        let Some(id) = comment.get("id").and_then(Value::as_str).map(str::to_owned) else {
            continue;
        };
        if !ids.contains(&id)
            || versions.get(&id).is_some_and(|version| comment.get("updatedAt") != Some(version))
        {
            continue;
        }
        let thread = json!({
            "promptId": prompt_id,
            "acpSession": acp_session,
            "sentAt": now,
            "sentMs": now_at,
            "state": "sent",
        });
        comment.insert("thread".into(), thread);
        threaded.push(id);
    }
    let changed = !threaded.is_empty();
    (json!({"sent": sent, "cleared": [], "threaded": threaded}), changed)
}

/// The most prompts one list asks acpmux about, newest sent first.
const MAX_THREAD_READS: usize = 8;
/// How long one list may spend asking acpmux, over all its chats; a thread
/// not answered by then stays open for the next list.
const THREAD_READ_BUDGET: std::time::Duration = std::time::Duration::from_millis(1500);
/// A thread sent longer ago than this with no ended turn found is closed as
/// failed: its turn fell out of the pages a read walks, or its chat is gone,
/// and leaving it open would have every surface poll for it forever.
const THREAD_GIVE_UP_MS: u64 = 24 * 60 * 60 * 1000;
/// The reply a thread closed by [`THREAD_GIVE_UP_MS`] shows.
const THREAD_GAVE_UP: &str =
    "The agent's reply could not be found: its chat is gone or the turn is too far back.";

/// Asks acpmux how each open thread's turn ended and stores the answers on
/// their comments (under the root's lock, re-read, so a save or delete
/// meanwhile is kept). One link and one walk per chat answers all of its
/// threads; the newest [`MAX_THREAD_READS`] are asked, within
/// [`THREAD_READ_BUDGET`]. An acpmux that cannot be read leaves them open
/// until [`THREAD_GIVE_UP_MS`].
fn answer_threads(mux: &Arc<Mux>, store: &Store, root: &str, file: File) -> io::Result<File> {
    use crate::comment_threads::TurnReply;
    let now = now_ms();
    // Open threads, newest sent first, so old ones never starve new ones.
    let mut open: Vec<(String, String, Option<u64>)> = Vec::new();
    for comment in &file.comments {
        let Some((session, prompt_id)) = open_thread(comment) else { continue };
        if open.iter().any(|(_, id, _)| *id == prompt_id) {
            continue;
        }
        open.push((session, prompt_id, sent_at_ms(comment)));
    }
    open.sort_by(|a, b| b.2.cmp(&a.2));
    let mut answers: Vec<(String, Value)> = Vec::new();
    let stamp = |state: &str, text: String| json!({"state": state, "reply": {"text": text, "at": rfc3339(now)}});
    let mut sessions: Vec<(String, Vec<String>)> = Vec::new();
    for (session, prompt_id, sent) in open.iter().take(MAX_THREAD_READS) {
        if sent.is_some_and(|sent| now.saturating_sub(sent) > THREAD_GIVE_UP_MS) {
            answers.push((prompt_id.clone(), stamp("failed", THREAD_GAVE_UP.to_owned())));
            continue;
        }
        match sessions.iter_mut().find(|(s, _)| s == session) {
            Some((_, ids)) => ids.push(prompt_id.clone()),
            None => sessions.push((session.clone(), vec![prompt_id.clone()])),
        }
    }
    // Past the newest few, only the give-up check runs (no read).
    for (_, prompt_id, sent) in open.iter().skip(MAX_THREAD_READS) {
        if sent.is_some_and(|sent| now.saturating_sub(sent) > THREAD_GIVE_UP_MS) {
            answers.push((prompt_id.clone(), stamp("failed", THREAD_GAVE_UP.to_owned())));
        }
    }
    let deadline = std::time::Instant::now() + THREAD_READ_BUDGET;
    for (session, ids) in &sessions {
        let Some(replies) = mux.acp_prompt_replies(session, ids, deadline) else { continue };
        for (prompt_id, reply) in ids.iter().zip(replies) {
            match reply {
                TurnReply::Answered(text) => {
                    answers.push((prompt_id.clone(), stamp("answered", text)))
                }
                TurnReply::Failed(text) => answers.push((prompt_id.clone(), stamp("failed", text))),
                TurnReply::Pending => {}
            }
        }
    }
    if answers.is_empty() {
        return Ok(file);
    }
    store.exclusive(root, || {
        let mut file = store.read(root)?;
        let mut changed = false;
        for comment in &mut file.comments {
            let Some((_, prompt_id)) = open_thread(comment) else { continue };
            let Some((_, answer)) = answers.iter().find(|(id, _)| *id == prompt_id) else {
                continue;
            };
            if let Some(Value::Object(thread)) = comment.get_mut("thread") {
                for (key, value) in answer.as_object().into_iter().flatten() {
                    thread.insert(key.clone(), value.clone());
                }
                changed = true;
            }
        }
        if changed {
            store.write(root, &file)?;
        }
        Ok(file)
    })
}

/// When a comment's thread was sent, in Unix milliseconds (its `sentMs`).
fn sent_at_ms(comment: &Map<String, Value>) -> Option<u64> {
    comment.get("thread")?.get("sentMs")?.as_u64()
}

/// A comment's thread still waiting on the agent: its chat and prompt id.
fn open_thread(comment: &Map<String, Value>) -> Option<(String, String)> {
    let thread = comment.get("thread")?;
    if thread.get("state").and_then(Value::as_str) != Some("sent") {
        return None;
    }
    let session = thread.get("acpSession").and_then(Value::as_str)?;
    let prompt_id = thread.get("promptId").and_then(Value::as_str)?;
    Some((session.to_owned(), prompt_id.to_owned()))
}

/// Stamps and stores `comment`: an edit of the comment its `id` names, or a
/// new one. Returns `{comment}`.
pub(super) fn save(
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
pub(super) fn delete(
    file: &mut File,
    ids: &[String],
    versions: &Map<String, Value>,
) -> (Value, bool) {
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
pub(super) fn root(fields: &Map<String, Value>) -> Result<&str, ResourceError> {
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

pub(super) fn ids(fields: &Map<String, Value>) -> Result<Vec<String>, ResourceError> {
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

/// `versions`: each id's `updatedAt` as the caller last read it. Delete may
/// omit it; send must provide an object, including an empty one.
pub(super) fn versions(
    fields: &Map<String, Value>,
    required: bool,
) -> Result<Map<String, Value>, ResourceError> {
    match fields.get("versions") {
        None | Some(Value::Null) if !required => Ok(Map::new()),
        Some(Value::Object(versions))
            if versions.len() <= MAX_DELETE_IDS && versions.values().all(Value::is_string) =>
        {
            Ok(versions.clone())
        }
        None | Some(_) => Err(ResourceError::validation_invalid(
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

pub(super) fn io_failed(operation: &str, error: &io::Error) -> ResourceError {
    let message = format!("the diff comment store could not be read or written: {error}");
    ResourceError::operation_failed(operation, "store_failed", json!({"message": message}))
}

/// One root's comments, as stored.
#[derive(Debug, Default, Serialize, Deserialize)]
pub(super) struct File {
    root: String,
    pub(super) comments: Vec<Map<String, Value>>,
    /// The pull request a review worktree's comments go to, when
    /// `git.review.start` made the worktree: `{url, repo, number, title,
    /// head, base}`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(super) review: Option<Value>,
}

impl File {
    fn has_open_threads(&self) -> bool {
        self.comments.iter().any(|comment| open_thread(comment).is_some())
    }

    fn position(&self, id: &str) -> Option<usize> {
        self.comments
            .iter()
            .position(|comment| comment.get("id").and_then(Value::as_str) == Some(id))
    }

    /// Oldest first: by `createdAt` (RFC 3339 UTC, which sorts as text),
    /// then insertion order.
    pub(super) fn sorted(&self) -> Vec<&Map<String, Value>> {
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
    pub(super) fn open(mux: &Mux, operation: &str) -> Result<Self, ResourceError> {
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
            .unwrap_or_else(|| File { root: root.to_string(), ..File::default() }))
    }

    pub(super) fn write(&self, root: &str, file: &File) -> io::Result<()> {
        private_directory(&self.directory)?;
        write_json(&self.path(root), file)
    }

    /// Records the pull request `root`'s comments go to (`git.review.start`).
    /// A review of the same pull request and head keeps its drafts; any
    /// other comments under the root (a removed worktree's path made again,
    /// another head) are dropped, so they never go to this review.
    pub(super) fn set_review(&self, root: &str, review: Value) -> io::Result<()> {
        self.exclusive(root, || {
            let mut file = self.read(root)?;
            let same = |name: &str| {
                file.review.as_ref().and_then(|prior| prior.get(name)) == review.get(name)
            };
            if !(same("url") && same("head")) {
                file.comments.clear();
            }
            file.review = Some(review);
            self.write(root, &file)
        })
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
#[path = "diff_comments_tests.rs"]
mod tests;
