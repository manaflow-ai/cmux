//! Part of `Hub`; see `hub/mod.rs`. The approvals audit trail: one line per answer a person (or
//! an ancestor session, or a queue owner) gave, in `<state dir>/audit/approvals.jsonl`.
//!
//! - What is logged: each answered permission, plan approval and question (the
//!   `permission_decision` record, observed in `Hub::append_record_locked` with the ask the
//!   review index kept from its `permission_request`), each queued prompt the owner approved or
//!   declined (`queue_approve.rs`), and each review verdict on a pull request
//!   (`_acpmux/review_verdict`). A prompt the agent withdrew, or a turn's stop cancelled, was
//!   never answered and is not logged. Tool output is never logged; the ask is one line with its
//!   secrets masked (`session::masked_preview`).
//! - Entry: `{v, seq, at, sessionId, host?, harness, vendor, kind, permissionId?, promptId?,
//!   prUrl?, ask, decision {optionId?, kind: allow|deny|answer|cancel|accept|changes, comment?},
//!   answeredBy {person, device?, via?, feedItem?}, prevHash, hash}`. A Request changes
//!   verdict's `comment` is masked and cut like an ask. `kind` is `approval`, `plan`,
//!   `question`, `queued` or `review`. `answeredBy.person` is true only for an answer the
//!   person's proof stood behind: an allow or an answer (which `respond_permission` accepts only
//!   from the person or under their decision proof), a verdict from the person's connection.
//! - Chain: `hash` = lowercase hex SHA-256 of `prevHash` followed by the entry's canonical JSON
//!   (keys sorted at every level, no spaces) without `hash`. The first entry's `prevHash` is
//!   [`GENESIS`]. `seq` counts from 1. Editing, dropping or reordering a line breaks the link
//!   after it, which `verify` reports.
//! - Opens: every open of the file (and of the purge's tmp file) goes through the private state
//!   helpers (`config::private_state_*`): no symlink is followed, only a regular file this user
//!   owns is used, and its mode is 0600.
//! - Writes: the file is opened `O_APPEND` and never rewritten; each line is synced to disk
//!   before it counts. One writer thread numbers, chains and writes every entry. An answer to a
//!   permission (recorded under a session's append lock) only sends its entry down a channel; a
//!   line that cannot be written is counted (`writeErrors` in `_acpmux/audit`) and logged, never
//!   silently dropped. A review verdict waits for its line ([`AuditLog::record_durable`]): the
//!   verdict fails, and its pull request stays in the queue, unless the line is on disk. One the
//!   writer has not taken within the wait is withdrawn, never written later; one it has taken is
//!   waited for to the end. `open`
//!   reads the file once, before it returns, for the chain's head (so a restart continues the
//!   chain) and the pull requests that already have a verdict, by session and URL, so the first
//!   queue read already leaves them out. At shutdown (`Hub::flush`) [`AuditLog::close`] ends the
//!   channel and waits, bounded, for the writer to write what was sent and exit.
//! - Purge: a purged chat (`Hub::kill` with purge, which `_acpmux/workspace_purge` sends for
//!   each chat of an incognito space) leaves no history. [`AuditLog::purge`] rewrites the file
//!   without that session's entries (a new file synced, then renamed over the old one, mode
//!   0600) and chains the rest again from [`GENESIS`], so `verify` still passes and nothing of the
//!   chat, not even its id, survives a restart. From the purge on, the writer itself refuses
//!   every entry of that session (a verdict checked before the purge and sent after it too), and
//!   the hub writes none. The purge runs first in `Hub::kill`, before anything of the chat stops: one that fails or times out fails the deletion, lifts the writer's fence and leaves the chat as it was. The audit folder must be a real owner-only directory (no link).
//! - Torn writes: a line that fails to write or sync is cut off again (the file goes back to its
//!   length before it), and the chain's head moves only after a line is on disk. A tail without
//!   its newline (a crash mid-write) is cut off when the log opens. A purge drops lines that are
//!   not entries. The chain proves the file was not edited by anything but this daemon.
//! - A memory store (tests) keeps the entries in memory, chained the same way.

use cmux_json::JsonSet as _;
use std::collections::HashSet;
use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};
#[cfg(test)]
use std::sync::atomic::AtomicBool;
use std::sync::atomic::{AtomicU8, AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex, mpsc};
use std::time::Duration;

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

/// The audit folder's file.
pub(crate) const FILE: &str = "approvals.jsonl";
/// The entry format.
pub(crate) const VERSION: u64 = 1;
/// The `prevHash` of the first entry.
pub(crate) const GENESIS: &str = "0000000000000000000000000000000000000000000000000000000000000000";
/// The most entries one `_acpmux/audit` page returns.
pub(crate) const MAX_PAGE: usize = 1000;
/// A page's entries when the request names no limit.
pub(crate) const DEFAULT_PAGE: usize = 200;
/// How long a durable record waits for the writer.
const DURABLE_WAIT: Duration = Duration::from_secs(10);

/// A pull request with a verdict: the session that opened it and its URL.
type Reviewed = HashSet<(String, String)>;

/// A durable record's answer, and whether its writer took it or its caller gave up on it.
struct Durable {
    done: mpsc::Sender<Result<Value, String>>,
    state: Arc<AtomicU8>,
}

/// [`Durable::state`]: waiting in the queue.
const QUEUED: u8 = 0;
/// The writer started on it: its outcome is coming.
const STARTED: u8 = 1;
/// The caller stopped waiting before the writer took it: never written.
const CANCELLED: u8 = 2;

enum Msg {
    /// An entry, where to answer once it is written (the entry as written) or failed, and its
    /// chat's purged flag: set by the time the writer takes it, the entry is that chat's late
    /// line and is dropped, even after a new chat took the id ([`Msg::Reopen`]).
    Entry(Value, Option<Durable>, Option<Arc<AtomicBool>>),
    /// Answered once every entry sent before it is written.
    Flush(mpsc::Sender<()>),
    /// Removes a purged session's entries: answered with how many, unless its caller withdrew
    /// it first ([`Durable::state`]). One that fails leaves the session unfenced.
    Purge(String, tokio::sync::oneshot::Sender<Result<usize, String>>, Arc<AtomicU8>),
    /// A chat was created under a purged session's id: its entries are written again. An entry
    /// sent before it (the purged chat's, late) is still refused.
    Reopen(String),
}

/// The chain's head: the last entry's `seq` and `hash`.
#[derive(Clone, Debug, PartialEq)]
struct Head {
    seq: u64,
    hash: String,
}

impl Default for Head {
    fn default() -> Self {
        Head { seq: 0, hash: GENESIS.to_owned() }
    }
}

pub(crate) struct AuditLog {
    /// None once closed: a record after that is counted as not written.
    tx: StdMutex<Option<mpsc::Sender<Msg>>>,
    /// Disconnects when the writer thread exits.
    exited: StdMutex<Option<mpsc::Receiver<()>>>,
    /// Pull requests (session, URL) whose verdict is written: they leave the review queue.
    reviewed: Arc<StdMutex<Reviewed>>,
    /// Entries the writer could not write.
    write_errors: Arc<AtomicU64>,
    path: Option<PathBuf>,
    /// The entries of a log kept in memory (no state folder).
    memory: Option<Arc<StdMutex<Vec<Value>>>>,
    /// Tests: every purge fails, after its fence went up.
    #[cfg(test)]
    fail_purges: Arc<AtomicBool>,
}

impl AuditLog {
    /// The log in `dir` (`<state dir>/audit`), or in memory when `dir` is None.
    pub(crate) fn open(dir: Option<PathBuf>) -> Self {
        let (tx, rx) = mpsc::channel();
        let reviewed = Arc::new(StdMutex::new(HashSet::new()));
        let path = dir.map(|d| d.join(FILE));
        let memory = path.is_none().then(|| Arc::new(StdMutex::new(Vec::new())));
        let write_errors = Arc::new(AtomicU64::new(0));
        #[cfg(test)]
        let fail_purges = Arc::new(AtomicBool::new(false));
        let mut writer = Writer {
            #[cfg(test)]
            fail_purges: fail_purges.clone(),
            purged: HashSet::new(),
            needs_repair: false,
            path: path.clone(),
            memory: memory.clone(),
            reviewed: reviewed.clone(),
            write_errors: write_errors.clone(),
            head: Head::default(),
            file: None,
        };
        // Before the first queue read: the verdicts already written leave their pull requests out.
        writer.load();
        let (exit_tx, exited) = mpsc::channel::<()>();
        // The thread ends when the log closes or drops (its sender), after what was sent.
        let _ = std::thread::Builder::new().name("acpmux-audit".into()).spawn(move || {
            let _exit = exit_tx;
            writer.run(rx)
        });
        AuditLog {
            tx: StdMutex::new(Some(tx)),
            exited: StdMutex::new(Some(exited)),
            reviewed,
            write_errors,
            path,
            memory,
            #[cfg(test)]
            fail_purges,
        }
    }

    /// Tests: makes every purge from now on fail (`fail`) or work again.
    #[cfg(test)]
    pub(crate) fn fail_purges(&self, fail: bool) {
        self.fail_purges.store(fail, Ordering::SeqCst);
    }

    /// Sends `entry` (without `v`, `seq`, `prevHash` and `hash`) to the writer: never blocks. A
    /// line the writer cannot write counts in [`AuditLog::write_errors`].
    pub(crate) fn record(&self, entry: Value) {
        self.record_of(entry, None);
    }

    /// [`AuditLog::record`] for a chat whose purged flag is `gone`.
    pub(crate) fn record_of(&self, entry: Value, gone: Option<Arc<AtomicBool>>) {
        if self.send(Msg::Entry(entry, None, gone)).is_err() {
            self.lost("the writer is gone");
        }
    }

    /// Writes `entry` and waits until its line is on disk: the entry as written, or why not.
    /// Blocking.
    pub(crate) fn record_durable(&self, entry: Value) -> Result<Value, String> {
        self.record_durable_of(entry, None)
    }

    /// [`AuditLog::record_durable`] for a chat whose purged flag is `gone`.
    pub(crate) fn record_durable_of(
        &self,
        entry: Value,
        gone: Option<Arc<AtomicBool>>,
    ) -> Result<Value, String> {
        let (done, rx) = mpsc::channel();
        let state = Arc::new(AtomicU8::new(QUEUED));
        let durable = Some(Durable { done, state: state.clone() });
        if self.send(Msg::Entry(entry, durable, gone)).is_err() {
            self.lost("the writer is gone");
            return Err("the audit writer is gone".into());
        }
        match rx.recv_timeout(DURABLE_WAIT) {
            Ok(r) => r,
            Err(mpsc::RecvTimeoutError::Disconnected) => Err("the audit writer is gone".into()),
            Err(mpsc::RecvTimeoutError::Timeout) => {
                // Still queued: withdrawn, so a failed verdict is never written later.
                if state
                    .compare_exchange(QUEUED, CANCELLED, Ordering::AcqRel, Ordering::Acquire)
                    .is_ok()
                {
                    self.lost("the audit writer did not take it in time");
                    return Err("the audit writer did not answer".into());
                }
                // The writer has it: its answer is the outcome.
                rx.recv().unwrap_or_else(|_| Err("the audit writer is gone".into()))
            }
        }
    }

    fn send(&self, msg: Msg) -> Result<(), ()> {
        let tx = self.tx.lock().unwrap_or_else(|e| e.into_inner());
        tx.as_ref().ok_or(())?.send(msg).map_err(|_| ())
    }

    /// At shutdown: ends the channel and waits up to `deadline` for the writer to write every
    /// entry sent before and exit. Whether it did. Later records are counted as not written.
    pub(crate) fn close(&self, deadline: Duration) -> bool {
        drop(self.tx.lock().unwrap_or_else(|e| e.into_inner()).take());
        let Some(exited) = self.exited.lock().unwrap_or_else(|e| e.into_inner()).take() else {
            return true;
        };
        match exited.recv_timeout(deadline) {
            Err(mpsc::RecvTimeoutError::Timeout) => {
                tracing::warn!("audit: the writer did not finish within {deadline:?} at shutdown");
                false
            }
            _ => true,
        }
    }

    fn lost(&self, why: &str) {
        self.write_errors.fetch_add(1, Ordering::Relaxed);
        tracing::warn!("audit: an entry was not written: {why}");
    }

    /// Entries that could not be written since this daemon started.
    pub(crate) fn write_errors(&self) -> u64 {
        self.write_errors.load(Ordering::Relaxed)
    }

    /// Removes every entry of session `session_id` from the log, after the entries sent before.
    /// The answer comes once the rewritten file is on disk (None: the writer is gone).
    #[cfg(test)]
    pub(crate) fn purge(
        &self,
        session_id: &str,
    ) -> Option<tokio::sync::oneshot::Receiver<Result<usize, String>>> {
        self.send_purge(session_id).map(|(rx, _)| rx)
    }

    fn send_purge(
        &self,
        session_id: &str,
    ) -> Option<(tokio::sync::oneshot::Receiver<Result<usize, String>>, Arc<AtomicU8>)> {
        let (tx, rx) = tokio::sync::oneshot::channel();
        let state = Arc::new(AtomicU8::new(QUEUED));
        self.send(Msg::Purge(session_id.to_owned(), tx, state.clone())).ok().map(|()| (rx, state))
    }

    /// Removes session `session_id`'s entries, waiting up to `wait` for the writer to take the
    /// purge: one it has not taken by then is withdrawn and never runs, one it has taken is
    /// waited for to the end. A purge that fails or is withdrawn leaves the log and the session
    /// as they were: its entries keep being written.
    pub(crate) async fn purge_within(
        &self,
        session_id: &str,
        wait: Duration,
    ) -> Result<usize, String> {
        let Some((mut rx, state)) = self.send_purge(session_id) else {
            return Err("the audit writer is gone".into());
        };
        match tokio::time::timeout(wait, &mut rx).await {
            Ok(r) => r.unwrap_or_else(|_| Err("the audit writer is gone".into())),
            Err(_) => {
                if state
                    .compare_exchange(QUEUED, CANCELLED, Ordering::AcqRel, Ordering::Acquire)
                    .is_ok()
                {
                    return Err("the audit writer did not take the purge in time".into());
                }
                rx.await.unwrap_or_else(|_| Err("the audit writer is gone".into()))
            }
        }
    }

    /// A chat was created under `session_id` (`Hub::new_session_with_id`): if a purge fenced that
    /// id this run, the fence comes down, after every entry sent before. Never blocks.
    pub(crate) fn reopen(&self, session_id: &str) {
        let _ = self.send(Msg::Reopen(session_id.to_owned()));
    }

    /// Whether the pull request at `url`, opened by session `session_id`, has a written verdict.
    pub(crate) fn reviewed(&self, session_id: &str, url: &str) -> bool {
        let key = (session_id.to_owned(), url.to_owned());
        self.reviewed.lock().unwrap_or_else(|e| e.into_inner()).contains(&key)
    }

    /// Waits until every entry recorded before this call is written (or the writer is gone).
    pub(crate) fn flush(&self) {
        let (tx, rx) = mpsc::channel();
        if self.send(Msg::Flush(tx)).is_ok() {
            let _ = rx.recv_timeout(DURABLE_WAIT);
        }
    }

    /// Every entry, oldest first. Blocking: reads the file.
    pub(crate) fn all(&self) -> std::io::Result<Vec<Value>> {
        self.flush();
        if let Some(m) = &self.memory {
            return Ok(m.lock().unwrap_or_else(|e| e.into_inner()).clone());
        }
        let Some(path) = &self.path else { return Ok(vec![]) };
        read_lines(path)
    }

    /// One page of entries for `_acpmux/audit`: `{entries, next?, writeErrors}`, `next` the
    /// `cursor` of the page after, `writeErrors` the entries this daemon could not write. With `verify`, also `verify: {ok, entries, brokenAt?, reason?}` over the whole
    /// chain. Blocking: reads the file.
    pub(crate) fn page(&self, q: &Query) -> std::io::Result<Value> {
        let all = self.all()?;
        let limit = q.limit.clamp(1, MAX_PAGE);
        let mut entries = Vec::new();
        let mut next = None;
        for e in &all {
            let seq = e.get("seq").and_then(Value::as_u64).unwrap_or(0);
            let at = e.get("at").and_then(Value::as_u64).unwrap_or(0);
            if q.cursor.is_some_and(|c| seq <= c)
                || q.since.is_some_and(|s| at < s)
                || q.until.is_some_and(|u| at > u)
                || q.session_id.as_deref().is_some_and(|s| e.get("sessionId") != Some(&json!(s)))
            {
                continue;
            }
            if entries.len() == limit {
                next = entries.last().and_then(|l: &Value| l.get("seq")).and_then(Value::as_u64);
                break;
            }
            entries.push(e.clone());
        }
        let mut out = json!({"entries": entries, "writeErrors": self.write_errors()});
        if let Some(n) = next {
            out.set("next", json!(n));
        }
        if q.verify {
            out.set("verify", verify(&all));
        }
        Ok(out)
    }
}

/// `_acpmux/audit` params.
#[derive(Debug, Default, Clone)]
pub(crate) struct Query {
    pub since: Option<u64>,
    pub until: Option<u64>,
    pub session_id: Option<String>,
    pub limit: usize,
    /// The `next` of the page before: entries after that `seq`.
    pub cursor: Option<u64>,
    pub verify: bool,
}

impl Query {
    pub(crate) fn from_params(p: &Value) -> Result<Self, String> {
        let num = |k: &str| -> Result<Option<u64>, String> {
            match p.get(k) {
                None | Some(Value::Null) => Ok(None),
                Some(v) => v.as_u64().map(Some).ok_or_else(|| format!("{k} must be a number")),
            }
        };
        let session_id = match p.get("sessionId") {
            None | Some(Value::Null) => None,
            Some(Value::String(s)) => Some(s.clone()),
            Some(_) => return Err("sessionId must be a string".into()),
        };
        Ok(Query {
            since: num("since")?,
            until: num("until")?,
            session_id,
            limit: num("limit")?.map_or(DEFAULT_PAGE, |l| l as usize),
            cursor: num("cursor")?,
            verify: p.get("verify").and_then(Value::as_bool).unwrap_or(false),
        })
    }
}

/// The pull request a review verdict entry is about: its session and URL.
fn review_key(entry: &Value) -> Option<(String, String)> {
    if entry.get("kind").and_then(Value::as_str) != Some("review") {
        return None;
    }
    let session = entry.get("sessionId").and_then(Value::as_str)?;
    let url = entry.get("prUrl").and_then(Value::as_str)?;
    Some((session.to_owned(), url.to_owned()))
}

struct Writer {
    #[cfg(test)]
    fail_purges: Arc<AtomicBool>,
    /// Sessions purged since start: their entries are refused.
    purged: HashSet<String>,
    /// A failed write left bytes this writer could not cut: read the file again first.
    needs_repair: bool,
    path: Option<PathBuf>,
    memory: Option<Arc<StdMutex<Vec<Value>>>>,
    reviewed: Arc<StdMutex<Reviewed>>,
    write_errors: Arc<AtomicU64>,
    head: Head,
    file: Option<std::fs::File>,
}

impl Writer {
    fn run(mut self, rx: mpsc::Receiver<Msg>) {
        while let Ok(msg) = rx.recv() {
            match msg {
                Msg::Entry(entry, durable, gone) => {
                    let taken = durable.as_ref().is_none_or(|d| {
                        d.state
                            .compare_exchange(QUEUED, STARTED, Ordering::AcqRel, Ordering::Acquire)
                            .is_ok()
                    });
                    if !taken {
                        // Its caller gave up and reported a failure: it must not appear later.
                        continue;
                    }
                    let done = durable.map(|d| d.done);
                    let sid = entry.get("sessionId").and_then(Value::as_str);
                    let late = gone.is_some_and(|g| g.load(Ordering::SeqCst));
                    if late || sid.is_some_and(|s| self.purged.contains(s)) {
                        // A purged chat leaves no history: not an error to count.
                        if let Some(done) = done {
                            let _ = done.send(Err("the session was purged".into()));
                        }
                        continue;
                    }
                    let written = self.write(entry);
                    match &written {
                        Ok(e) => {
                            if let Some(key) = review_key(e) {
                                self.reviewed.lock().unwrap_or_else(|e| e.into_inner()).insert(key);
                            }
                        }
                        Err(why) => {
                            self.write_errors.fetch_add(1, Ordering::Relaxed);
                            tracing::warn!("audit: an entry was not written: {why}");
                        }
                    }
                    if let Some(done) = done {
                        let _ = done.send(written);
                    }
                }
                Msg::Flush(done) => {
                    let _ = done.send(());
                }
                Msg::Reopen(sid) => {
                    self.purged.remove(&sid);
                }
                Msg::Purge(sid, done, state) => {
                    if state
                        .compare_exchange(QUEUED, STARTED, Ordering::AcqRel, Ordering::Acquire)
                        .is_err()
                    {
                        // Withdrawn: the chat stays, and so do its entries.
                        continue;
                    }
                    let purged = self.purge(&sid);
                    if let Err(why) = &purged {
                        tracing::warn!("audit: a purged chat's entries were not removed: {why}");
                    }
                    let _ = done.send(purged);
                }
            }
        }
    }

    /// The chain's head and the reviewed pull requests, from the file as it is (a torn tail cut
    /// off first).
    fn load(&mut self) {
        let Some(path) = self.path.clone() else { return };
        if let Err(e) = cut_torn_tail(&path) {
            tracing::warn!("audit: could not cut a torn tail of {}: {e}", path.display());
        }
        let Ok(entries) = read_lines(&path) else { return };
        let mut reviewed = self.reviewed.lock().unwrap_or_else(|e| e.into_inner());
        for e in &entries {
            if let Some(key) = review_key(e) {
                reviewed.insert(key);
            }
        }
        drop(reviewed);
        if let Some(last) = entries.last() {
            self.head = Head {
                seq: last.get("seq").and_then(Value::as_u64).unwrap_or(entries.len() as u64),
                hash: last.get("hash").and_then(Value::as_str).unwrap_or(GENESIS).to_owned(),
            };
        }
    }

    /// Numbers, chains and writes `entry`: the entry as written, or why it was not.
    fn write(&mut self, entry: Value) -> Result<Value, String> {
        if self.needs_repair {
            self.file = None;
            self.load();
            self.needs_repair = false;
        }
        let (entry, head) = seal(&self.head, entry).ok_or("not an object")?;
        if let Some(m) = &self.memory {
            m.lock().unwrap_or_else(|e| e.into_inner()).push(entry.clone());
            self.head = head;
            return Ok(entry);
        }
        let Some(path) = self.path.clone() else { return Err("no audit file".into()) };
        let mut line = entry.to_string();
        line.push('\n');
        match self.append(&path, line.as_bytes()) {
            Ok(()) => {
                self.head = head;
                Ok(entry)
            }
            Err(e) => {
                // The next entry tries again with a new handle; this one is not chained.
                self.file = None;
                Err(format!("append to {} failed: {e}", path.display()))
            }
        }
    }

    /// Drops session `sid`'s entries and chains the rest again: how many went. On a failure the
    /// session is unfenced again: the chat stays, and its entries keep being written.
    fn purge(&mut self, sid: &str) -> Result<usize, String> {
        // Before the rewrite: an entry of it sent from here on is refused.
        self.purged.insert(sid.to_owned());
        let purged = self.purge_fenced(sid);
        match &purged {
            Ok(_) => {
                self.reviewed.lock().unwrap_or_else(|e| e.into_inner()).retain(|(s, _)| s != sid);
            }
            Err(_) => {
                self.purged.remove(sid);
            }
        }
        purged
    }

    fn purge_fenced(&mut self, sid: &str) -> Result<usize, String> {
        #[cfg(test)]
        if self.fail_purges.load(Ordering::SeqCst) {
            return Err("purges fail in this test".into());
        }
        let old = if let Some(m) = &self.memory {
            m.lock().unwrap_or_else(|e| e.into_inner()).clone()
        } else if let Some(path) = &self.path {
            read_lines(path).map_err(|e| format!("read {}: {e}", path.display()))?
        } else {
            return Ok(0);
        };
        let of = |e: &Value| e.get("sessionId").and_then(Value::as_str) == Some(sid);
        let removed = old.iter().filter(|e| of(e)).count();
        if removed == 0 {
            return Ok(0);
        }
        let mut head = Head::default();
        let mut kept = Vec::with_capacity(old.len() - removed);
        // A line that is not an entry could hold anything of the chat: it goes too.
        for e in old.into_iter().filter(|e| e.is_object() && !of(e)) {
            if let Some((sealed, next)) = seal(&head, e) {
                head = next;
                kept.push(sealed);
            }
        }
        if let Some(m) = &self.memory {
            *m.lock().unwrap_or_else(|e| e.into_inner()) = kept;
        } else if let Some(path) = self.path.clone() {
            self.file = None;
            replace(&path, &kept).map_err(|e| format!("rewrite {}: {e}", path.display()))?;
        }
        self.head = head;
        Ok(removed)
    }

    fn append(&mut self, path: &Path, line: &[u8]) -> std::io::Result<()> {
        if self.file.is_none() {
            private_dir_of(path)?;
            self.file =
                Some(crate::config::private_state_append(path).map_err(std::io::Error::other)?);
        }
        let file = self.file.as_mut().ok_or_else(|| std::io::Error::other("no file"))?;
        let before = file.metadata()?.len();
        let written =
            file.write_all(line).and_then(|()| file.flush()).and_then(|()| file.sync_data());
        if let Err(e) = written {
            // Back to the last whole line, so the next one does not land on half of this one,
            // and a line whose sync failed is not chained twice.
            let cut = file.set_len(before).and_then(|()| file.sync_data());
            if cut.is_err() {
                self.needs_repair = true;
            }
            return Err(e);
        }
        Ok(())
    }
}

/// `entry` numbered and chained after `head` (without its old `v`, `seq`, `prevHash`, `hash`),
/// and the head after it; None for a value that is not an object.
fn seal(head: &Head, mut entry: Value) -> Option<(Value, Head)> {
    let o = entry.as_object_mut()?;
    o.remove("hash");
    o.insert("v".into(), json!(VERSION));
    o.insert("seq".into(), json!(head.seq + 1));
    o.insert("prevHash".into(), json!(head.hash));
    let hash = entry_hash(&head.hash, &entry);
    entry.set("hash", json!(hash));
    Some((entry, Head { seq: head.seq + 1, hash }))
}

/// The folder of `path`, made (or checked) a private state folder before anything in it is
/// opened: a real directory this user owns, mode 0700, reached through no link. A link planted
/// at the folder is refused, so no repair, read or rewrite reaches what it names.
fn private_dir_of(path: &Path) -> std::io::Result<()> {
    let Some(dir) = path.parent() else { return Ok(()) };
    crate::config::private_state_dir(dir).map_err(std::io::Error::other)?;
    let meta = std::fs::symlink_metadata(dir)?;
    if !meta.file_type().is_dir() {
        return Err(std::io::Error::other(format!("{} is not a directory", dir.display())));
    }
    Ok(())
}

/// Cuts what follows the last newline of `path` (a line a crash left half written).
fn cut_torn_tail(path: &Path) -> std::io::Result<()> {
    private_dir_of(path)?;
    if !exists(path)? {
        return Ok(());
    }
    let mut file = crate::config::private_state_rw(path).map_err(std::io::Error::other)?;
    let mut bytes = Vec::new();
    std::io::Read::read_to_end(&mut file, &mut bytes)?;
    let whole = bytes.iter().rposition(|&b| b == b'\n').map_or(0, |i| i + 1);
    if whole == bytes.len() {
        return Ok(());
    }
    file.set_len(whole as u64)?;
    file.sync_all()
}

/// Writes `entries` to `path` whole: a new file beside it, synced, renamed over it.
fn replace(path: &Path, entries: &[Value]) -> std::io::Result<()> {
    private_dir_of(path)?;
    let tmp = path.with_extension("jsonl.tmp");
    // A leftover (or planted) tmp goes first: removing a link never touches what it names.
    match std::fs::remove_file(&tmp) {
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(e),
        _ => {}
    }
    let mut file = crate::config::private_state_create_new(&tmp).map_err(std::io::Error::other)?;
    for e in entries {
        file.write_all(e.to_string().as_bytes())?;
        file.write_all(b"\n")?;
    }
    file.sync_all()?;
    std::fs::rename(&tmp, path)?;
    if let Some(dir) = path.parent()
        && let Ok(d) = std::fs::File::open(dir)
    {
        let _ = d.sync_all();
    }
    Ok(())
}

/// Whether something is at `path` (a link counts, and is refused when opened).
fn exists(path: &Path) -> std::io::Result<bool> {
    match std::fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(e),
    }
}

/// Every line of `path`, opened as private state: a link, a file that is not regular or one
/// another user owns is refused, and a wider mode is narrowed to 0600.
fn read_lines(path: &Path) -> std::io::Result<Vec<Value>> {
    private_dir_of(path)?;
    if !exists(path)? {
        return Ok(vec![]);
    }
    let file = crate::config::private_state_file(path).map_err(std::io::Error::other)?;
    let mut out = Vec::new();
    for line in std::io::BufReader::new(file).lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        // A line that is not JSON stays in the walk as a string, so `verify` names it.
        out.push(serde_json::from_str(&line).unwrap_or(Value::String(line)));
    }
    Ok(out)
}

/// `hash` of an entry whose `prevHash` is `prev`: SHA-256 of `prev` then the canonical JSON of
/// `entry` without `hash`.
pub(crate) fn entry_hash(prev: &str, entry: &Value) -> String {
    let mut body = entry.clone();
    if let Some(o) = body.as_object_mut() {
        o.remove("hash");
    }
    let mut text = String::new();
    canonical(&body, &mut text);
    let mut h = Sha256::new();
    h.update(prev.as_bytes());
    h.update(text.as_bytes());
    h.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

/// `v` as JSON with every object's keys sorted and no spaces, whatever order the map keeps.
fn canonical(v: &Value, out: &mut String) {
    match v {
        Value::Object(m) => {
            let mut members: Vec<(&String, &Value)> = m.iter().collect();
            members.sort_by(|a, b| a.0.cmp(b.0));
            out.push('{');
            for (i, (k, v)) in members.into_iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                out.push_str(&Value::String(k.clone()).to_string());
                out.push(':');
                canonical(v, out);
            }
            out.push('}');
        }
        Value::Array(a) => {
            out.push('[');
            for (i, x) in a.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                canonical(x, out);
            }
            out.push(']');
        }
        other => out.push_str(&other.to_string()),
    }
}

/// Walks the chain: `{ok, entries, brokenAt?, reason?}`, `brokenAt` the `seq` (or the 1-based
/// line, for a line with none) of the first entry that does not follow the one before it.
pub(crate) fn verify(entries: &[Value]) -> Value {
    let mut prev = Head::default();
    for (i, e) in entries.iter().enumerate() {
        let line = i as u64 + 1;
        let seq = e.get("seq").and_then(Value::as_u64);
        let broken = |reason: &str| {
            json!({"ok": false, "entries": entries.len(), "brokenAt": seq.unwrap_or(line),
                   "line": line, "reason": reason})
        };
        if !e.is_object() {
            return broken("not an entry");
        }
        if seq != Some(prev.seq + 1) {
            return broken("seq");
        }
        if e.get("prevHash").and_then(Value::as_str) != Some(prev.hash.as_str()) {
            return broken("prevHash");
        }
        let hash = entry_hash(&prev.hash, e);
        if e.get("hash").and_then(Value::as_str) != Some(hash.as_str()) {
            return broken("hash");
        }
        prev = Head { seq: prev.seq + 1, hash };
    }
    json!({"ok": true, "entries": entries.len()})
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("acpmux-audit-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        d
    }

    fn entry(session: &str, at: u64) -> Value {
        json!({"at": at, "sessionId": session, "harness": "claude", "vendor": "anthropic",
               "kind": "approval", "permissionId": format!("p-{at}"), "ask": "Run: ls",
               "decision": {"optionId": "allow", "kind": "allow"},
               "answeredBy": {"person": true}})
    }

    #[test]
    fn entries_chain_and_verify() {
        let log = AuditLog::open(None);
        for at in 1..=3 {
            log.record(entry("s1", at));
        }
        let all = log.all().unwrap();
        assert_eq!(all.len(), 3);
        assert_eq!(all[0]["prevHash"], GENESIS);
        assert_eq!(all[1]["prevHash"], all[0]["hash"]);
        assert_eq!(all[2]["seq"], 3);
        assert_eq!(all[2]["v"], VERSION);
        assert_eq!(verify(&all), json!({"ok": true, "entries": 3}));
    }

    #[test]
    fn verify_names_the_first_broken_link() {
        let log = AuditLog::open(None);
        for at in 1..=4 {
            log.record(entry("s1", at));
        }
        let mut all = log.all().unwrap();
        all[1]["ask"] = json!("Run: rm -rf /");
        let v = verify(&all);
        assert_eq!(v["ok"], false, "{v}");
        assert_eq!(v["brokenAt"], 2, "{v}");
        assert_eq!(v["reason"], "hash", "{v}");
        let mut dropped = log.all().unwrap();
        dropped.remove(2);
        let v = verify(&dropped);
        assert_eq!((v["brokenAt"].clone(), v["reason"].clone()), (json!(4), json!("seq")), "{v}");
    }

    #[test]
    fn the_hash_ignores_key_order() {
        let a = json!({"b": 1, "a": {"y": 2, "x": [3, {"q": 1, "p": 2}]}});
        let b = json!({"a": {"x": [3, {"p": 2, "q": 1}], "y": 2}, "b": 1});
        assert_eq!(entry_hash(GENESIS, &a), entry_hash(GENESIS, &b));
        assert_ne!(entry_hash(GENESIS, &a), entry_hash("1", &a));
    }

    #[test]
    fn a_restart_continues_the_chain_and_appends_only() {
        let d = dir("restart");
        {
            let log = AuditLog::open(Some(d.clone()));
            log.record(entry("s1", 1));
            log.record(json!({"at": 2, "sessionId": "s1", "kind": "review",
                              "prUrl": "https://github.com/o/r/pull/1", "ask": "Review",
                              "decision": {"kind": "accept"}, "answeredBy": {"person": true}}));
            log.flush();
        }
        let before = std::fs::read_to_string(d.join(FILE)).unwrap();
        let log = AuditLog::open(Some(d.clone()));
        log.record(entry("s2", 3));
        let all = log.all().unwrap();
        assert_eq!(all.len(), 3);
        assert_eq!(all[2]["seq"], 3);
        assert_eq!(all[2]["prevHash"], all[1]["hash"]);
        assert_eq!(verify(&all)["ok"], true);
        // The verdict a log read back still keeps its pull request out of the queue.
        assert!(log.reviewed("s1", "https://github.com/o/r/pull/1"));
        // Keyed by session: the same URL another session printed still waits for its verdict.
        assert!(!log.reviewed("s2", "https://github.com/o/r/pull/1"));
        let after = std::fs::read_to_string(d.join(FILE)).unwrap();
        assert!(after.starts_with(&before), "the file was rewritten");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(d.join(FILE)).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
        }
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn a_page_filters_and_continues_from_its_cursor() {
        let log = AuditLog::open(None);
        for at in 1..=5 {
            log.record(entry(if at % 2 == 0 { "even" } else { "odd" }, at * 10));
        }
        let q = Query { limit: 2, ..Default::default() };
        let first = log.page(&q).unwrap();
        assert_eq!(first["entries"].as_array().unwrap().len(), 2);
        assert_eq!(first["next"], 2);
        let second = log.page(&Query { cursor: Some(2), ..q.clone() }).unwrap();
        assert_eq!(second["entries"][0]["seq"], 3);
        let odd = log
            .page(&Query {
                session_id: Some("odd".into()),
                since: Some(20),
                limit: 10,
                verify: true,
                ..Default::default()
            })
            .unwrap();
        let seqs: Vec<_> =
            odd["entries"].as_array().unwrap().iter().map(|e| e["seq"].clone()).collect();
        assert_eq!(seqs, vec![json!(3), json!(5)]);
        assert_eq!(odd.get("next"), None);
        assert_eq!(odd["verify"]["ok"], true);
        assert!(Query::from_params(&json!({"since": "x"})).is_err());
        assert_eq!(odd["writeErrors"], 0);
    }

    #[test]
    fn an_entry_that_cannot_be_written_fails_its_verdict_and_is_counted() {
        // The audit folder's path is a file: no line can be written under it.
        let d = dir("unwritable");
        std::fs::write(&d, b"not a folder").unwrap();
        let log = AuditLog::open(Some(d.clone()));
        let verdict = json!({"at": 1, "sessionId": "s1", "kind": "review",
                             "prUrl": "https://github.com/o/r/pull/1", "ask": "Review",
                             "decision": {"kind": "accept"}, "answeredBy": {"person": true}});
        assert!(log.record_durable(verdict).is_err());
        assert!(!log.reviewed("s1", "https://github.com/o/r/pull/1"));
        log.record(entry("s1", 2));
        log.flush();
        assert_eq!(log.write_errors(), 2);
        let _ = std::fs::remove_file(&d);
    }

    #[tokio::test]
    async fn a_purge_leaves_nothing_of_the_session_and_a_chain_that_verifies() {
        let d = dir("purge");
        let url = "https://github.com/o/r/pull/4";
        {
            let log = AuditLog::open(Some(d.clone()));
            log.record(entry("keep", 1));
            let mut secret = entry("gone-incognito", 2);
            secret["ask"] = json!("Run: cat private-plans.txt");
            log.record(secret);
            log.record_durable(json!({"at": 3, "sessionId": "gone-incognito", "kind": "review",
                                      "prUrl": url, "ask": "Review", "decision": {"kind": "accept"},
                                      "answeredBy": {"person": true}}))
                .unwrap();
            log.record(entry("keep", 4));
            assert_eq!(log.purge("gone-incognito").unwrap().await.unwrap(), Ok(2));
            assert!(!log.reviewed("gone-incognito", url));
            // The chain goes on from the rewritten head.
            log.record(entry("keep", 5));
            log.flush();
        }
        let text = std::fs::read_to_string(d.join(FILE)).unwrap();
        for needle in ["gone-incognito", "private-plans", url] {
            assert!(!text.contains(needle), "{needle} survived the purge");
        }
        // After a restart: nothing of it, and the chain verifies.
        let log = AuditLog::open(Some(d.clone()));
        let all = log.all().unwrap();
        assert_eq!(all.len(), 3);
        assert_eq!(all[2]["seq"], 3);
        assert_eq!(verify(&all)["ok"], true, "{}", verify(&all));
        let page = log
            .page(&Query {
                session_id: Some("gone-incognito".into()),
                limit: 10,
                ..Default::default()
            })
            .unwrap();
        assert_eq!(page["entries"], json!([]));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(d.join(FILE)).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
        }
        let _ = std::fs::remove_dir_all(&d);
    }

    #[tokio::test]
    async fn an_entry_sent_after_the_purge_is_refused_by_the_writer() {
        let d = dir("fence");
        let log = AuditLog::open(Some(d.clone()));
        log.record(entry("gone", 1));
        // A verdict that passed the hub's check before the purge, sent after it.
        let purge = log.purge("gone").unwrap();
        let late = log.record_durable(json!({"at": 2, "sessionId": "gone", "kind": "review",
                                             "prUrl": "https://github.com/o/r/pull/5",
                                             "ask": "Review", "decision": {"kind": "accept"},
                                             "answeredBy": {"person": true}}));
        assert_eq!(purge.await.unwrap(), Ok(1));
        assert!(late.is_err());
        log.record(entry("gone", 3));
        log.record(entry("kept", 4));
        let all = log.all().unwrap();
        let sessions: Vec<_> = all.iter().map(|e| e["sessionId"].clone()).collect();
        assert_eq!(sessions, vec![json!("kept")]);
        assert_eq!(log.write_errors(), 0, "a refused entry of a purged chat is no write error");
        let _ = std::fs::remove_dir_all(&d);
    }

    /// The fence lasts until a chat takes the purged id again, not until a restart: a chat
    /// recreated under it (a trigger's fixed id) has its answers logged. What the purged chat
    /// sent before the new one was created is still refused.
    #[tokio::test]
    async fn a_chat_recreated_under_a_purged_id_is_logged_again() {
        let d = dir("reopen");
        let log = AuditLog::open(Some(d.clone()));
        log.record(entry("same", 1));
        assert_eq!(log.purge("same").unwrap().await.unwrap(), Ok(1));
        log.record(entry("same", 2));
        // The purged chat's verdict, built before the purge and sent after the new chat took
        // the id: its own flag says it is the old chat's, so the lifted fence does not admit it.
        let old_chat = Arc::new(AtomicBool::new(true));
        log.reopen("same");
        let late = log.record_durable_of(
            json!({"at": 2, "sessionId": "same", "kind": "review",
                   "prUrl": "https://github.com/o/r/pull/5", "ask": "Review",
                   "decision": {"kind": "accept"}, "answeredBy": {"person": true}}),
            Some(old_chat),
        );
        assert!(late.is_err(), "{late:?}");
        assert!(!log.reviewed("same", "https://github.com/o/r/pull/5"));
        log.record_of(entry("same", 3), Some(Arc::new(AtomicBool::new(false))));
        let written = log.record_durable(json!({"at": 4, "sessionId": "same", "kind": "review",
                                                "prUrl": "https://github.com/o/r/pull/6",
                                                "ask": "Review", "decision": {"kind": "accept"},
                                                "answeredBy": {"person": true}}));
        assert!(written.is_ok(), "{written:?}");
        let all = log.all().unwrap();
        let ats: Vec<_> = all.iter().map(|e| e["at"].clone()).collect();
        assert_eq!(ats, vec![json!(3), json!(4)]);
        assert!(log.reviewed("same", "https://github.com/o/r/pull/6"));
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn a_torn_tail_is_cut_at_open_and_the_chain_goes_on() {
        let d = dir("torn");
        {
            let log = AuditLog::open(Some(d.clone()));
            log.record(entry("s1", 1));
            log.record(entry("s1", 2));
            log.flush();
        }
        let path = d.join(FILE);
        let whole = std::fs::read(&path).unwrap();
        let mut torn = whole.clone();
        torn.extend_from_slice(br#"{"at":3,"sessionId":"s1","ask":"half"#);
        std::fs::write(&path, &torn).unwrap();
        let log = AuditLog::open(Some(d.clone()));
        assert_eq!(std::fs::read(&path).unwrap(), whole, "the torn tail was cut");
        log.record(entry("s1", 4));
        let all = log.all().unwrap();
        assert_eq!(all.len(), 3);
        assert_eq!(all[2]["seq"], 3, "no sequence number repeats");
        assert_eq!(verify(&all)["ok"], true, "{}", verify(&all));
        let _ = std::fs::remove_dir_all(&d);
    }

    #[tokio::test]
    async fn a_purge_drops_lines_that_are_not_entries() {
        let d = dir("purge-malformed");
        {
            let log = AuditLog::open(Some(d.clone()));
            log.record(entry("gone", 1));
            log.record(entry("kept", 2));
            log.flush();
        }
        let path = d.join(FILE);
        let mut text = std::fs::read_to_string(&path).unwrap();
        text.push_str("not json: gone private-plans\n");
        std::fs::write(&path, text).unwrap();
        let log = AuditLog::open(Some(d.clone()));
        assert_eq!(log.purge("gone").unwrap().await.unwrap(), Ok(1));
        let after = std::fs::read_to_string(&path).unwrap();
        assert!(!after.contains("private-plans"));
        assert_eq!(verify(&log.all().unwrap())["ok"], true);
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn close_writes_what_was_sent_before_it_returns() {
        let d = dir("close");
        let log = AuditLog::open(Some(d.clone()));
        for at in 1..=50 {
            log.record(entry("s1", at));
        }
        assert!(log.close(Duration::from_secs(10)));
        let lines = std::fs::read_to_string(d.join(FILE)).unwrap().lines().count();
        assert_eq!(lines, 50);
        assert_eq!(log.write_errors(), 0);
        log.record(entry("s1", 51));
        assert_eq!(log.write_errors(), 1, "a record after close is counted, not lost silently");
        assert!(log.close(Duration::from_secs(1)));
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn open_knows_the_written_verdicts_before_it_returns() {
        let d = dir("ready");
        let url = "https://github.com/o/r/pull/3";
        AuditLog::open(Some(d.clone()))
            .record_durable(json!({"at": 1, "sessionId": "s1", "kind": "review", "prUrl": url,
                                   "ask": "Review", "decision": {"kind": "accept"},
                                   "answeredBy": {"person": true}}))
            .unwrap();
        // No flush or wait: the first read after open already knows the verdict.
        assert!(AuditLog::open(Some(d.clone())).reviewed("s1", url));
        let _ = std::fs::remove_dir_all(&d);
    }

    #[cfg(unix)]
    #[test]
    fn a_planted_link_is_refused_and_what_it_names_is_untouched() {
        let d = dir("link");
        std::fs::create_dir_all(&d).unwrap();
        let target = d.join("elsewhere");
        std::fs::write(&target, b"{\"secret\":1}\n").unwrap();
        std::os::unix::fs::symlink(&target, d.join(FILE)).unwrap();
        let log = AuditLog::open(Some(d.clone()));
        assert!(log.all().is_err(), "a linked log is not read");
        let verdict = json!({"at": 1, "sessionId": "s1", "kind": "review",
                             "prUrl": "https://github.com/o/r/pull/1", "ask": "Review",
                             "decision": {"kind": "accept"}, "answeredBy": {"person": true}});
        assert!(log.record_durable(verdict).is_err(), "nothing is written through the link");
        assert_eq!(std::fs::read(&target).unwrap(), b"{\"secret\":1}\n");
        let _ = std::fs::remove_dir_all(&d);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_purge_replaces_a_planted_tmp_link_without_writing_through_it() {
        let d = dir("tmplink");
        let log = AuditLog::open(Some(d.clone()));
        log.record(entry("s1", 1));
        log.record(entry("s2", 2));
        log.flush();
        let target = d.join("elsewhere");
        std::fs::write(&target, b"keep").unwrap();
        std::os::unix::fs::symlink(&target, d.join(FILE).with_extension("jsonl.tmp")).unwrap();
        assert_eq!(log.purge("s1").unwrap().await.unwrap(), Ok(1));
        assert_eq!(std::fs::read(&target).unwrap(), b"keep");
        let meta = std::fs::symlink_metadata(d.join(FILE)).unwrap();
        assert!(meta.file_type().is_file());
        assert_eq!(log.all().unwrap().len(), 1);
        let _ = std::fs::remove_dir_all(&d);
    }

    #[cfg(unix)]
    #[test]
    fn a_linked_audit_folder_is_refused_and_its_target_left_alone() {
        let d = dir("dirlink");
        let target = d.join("elsewhere");
        std::fs::create_dir_all(&target).unwrap();
        // A torn tail in the folder the link names: a repair through the link would cut it.
        std::fs::write(target.join(FILE), b"{\"seq\":1}\ntorn").unwrap();
        let linked = d.join("audit");
        std::os::unix::fs::symlink(&target, &linked).unwrap();
        let log = AuditLog::open(Some(linked.clone()));
        assert!(log.all().is_err(), "a linked folder is not read");
        log.record(entry("s1", 1));
        log.flush();
        assert_eq!(log.write_errors(), 1, "nothing is written through the link");
        assert_eq!(std::fs::read(target.join(FILE)).unwrap(), b"{\"seq\":1}\ntorn");
        let _ = std::fs::remove_dir_all(&d);
    }

    #[tokio::test]
    async fn a_failed_purge_unfences_the_session_and_keeps_its_entries() {
        let d = dir("failpurge");
        let log = AuditLog::open(Some(d.clone()));
        log.record(entry("s1", 1));
        log.flush();
        log.fail_purges(true);
        assert!(log.purge_within("s1", Duration::from_secs(5)).await.is_err());
        log.record(entry("s1", 2));
        let all = log.all().unwrap();
        assert_eq!(all.len(), 2, "the chat's entries stay and it still records: {all:?}");
        assert_eq!(verify(&all)["ok"], true);
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn a_durable_record_given_up_on_is_never_written() {
        let d = dir("cancel");
        let log = AuditLog::open(Some(d.clone()));
        let (done, rx) = mpsc::channel();
        let state = Arc::new(AtomicU8::new(CANCELLED));
        log.send(Msg::Entry(entry("s1", 1), Some(Durable { done, state }), None)).unwrap();
        log.record(entry("s1", 2));
        log.flush();
        assert!(rx.try_recv().is_err(), "a withdrawn entry gets no answer");
        let all = log.all().unwrap();
        assert_eq!(all.len(), 1);
        assert_eq!(all[0]["at"], 2);
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn a_durable_record_answers_with_the_entry_as_written() {
        let d = dir("durable");
        let log = AuditLog::open(Some(d.clone()));
        let written = log
            .record_durable(json!({"at": 1, "sessionId": "s1", "kind": "review",
                                   "prUrl": "https://github.com/o/r/pull/2", "ask": "Review",
                                   "decision": {"kind": "changes"},
                                   "answeredBy": {"person": true}}))
            .unwrap();
        assert_eq!(written["seq"], 1);
        assert_eq!(written["prevHash"], GENESIS);
        assert!(log.reviewed("s1", "https://github.com/o/r/pull/2"));
        let on_disk = std::fs::read_to_string(d.join(FILE)).unwrap();
        assert!(on_disk.contains(written["hash"].as_str().unwrap()));
        assert_eq!(log.write_errors(), 0);
        let _ = std::fs::remove_dir_all(&d);
    }
}
