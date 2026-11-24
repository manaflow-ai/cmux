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
//! - Writes, at the event: the file is opened `O_APPEND` and never rewritten. The caller of a
//!   record numbers, chains and writes its line itself, under one small lock (`Chain`): one
//!   `write` of the whole line and no sync, so a `kill -9` of the daemon right after the record
//!   loses nothing (the page cache outlives the process, and a line a kill tore mid-write is cut
//!   when the log opens). That costs one hash and one write, whatever the size of the file or
//!   of the chat. One thread (`acpmux-audit`) syncs what was written (`sync_data`, once for
//!   every line written before the sync starts) and runs purges. An answer to a permission
//!   (recorded under a session's append lock) does not wait for the sync; a line that cannot
//!   be written is counted (`writeErrors` in `_acpmux/audit`) and logged, never silently
//!   dropped. A review verdict waits for its line to be synced ([`AuditLog::record_durable_of`]):
//!   the verdict fails, and its pull request stays in the queue, unless the line is on disk (a
//!   sync that fails is counted and fails the verdict, its line cut off again while it is the
//!   file's last, else left in it and the failure says so). `open` reads
//!   the file once, before it returns, for the chain's head (so a restart continues the chain)
//!   and the pull requests that already have a verdict, by session and URL, so the first queue
//!   read already leaves them out. At shutdown (`Hub::flush`) [`AuditLog::close`] refuses later
//!   records and joins the sync thread: nothing is left to write, only the last sync (and a
//!   purge already running) to finish.
//! - Purge: a purged chat (`Hub::kill` with purge, which `_acpmux/workspace_purge` sends for
//!   each chat of an incognito space) leaves no history. [`AuditLog::purge`] rewrites the file
//!   without that session's entries (a new file synced, then renamed over the old one, mode
//!   0600) and chains the rest again from [`GENESIS`], so `verify` still passes and nothing of the
//!   chat, not even its id, survives a restart. From the purge's start on, every entry of that
//!   session is refused (a verdict checked before the purge and given after it too), and the hub
//!   writes none. One written while the purge waited in the queue is in the file and goes with
//!   the rest; a purge that fails or is given up on refused nothing. The rewrite does not hold
//!   the lock over the whole file: as it starts, under the lock, the purge fences the session
//!   and notes the file's length; the lines before that length are read and written to the new
//!   file, synced, while callers go on appending to the old one; then, under the lock again,
//!   the lines appended meanwhile follow the kept ones, chained on from them, and the new file
//!   is synced and renamed over the old one. A record that meets a purge waits only for that
//!   last step, which grows with the lines written during the purge, never with the file. The
//!   purge runs first in `Hub::kill`, before anything of the chat stops: one that fails or
//!   times out fails the deletion, lifts the fence it raised and leaves the chat as it was. The
//!   audit folder must be a real owner-only directory (no link).
//! - Torn writes: a line that fails to write is cut off again (the file goes back to its length
//!   before it; when that cut fails too, the next record or the thread cuts it), and the chain's
//!   head moves only after a line is written. A verdict whose sync failed is cut off again while
//!   it is still the file's last line. A tail without its newline (a crash mid-write) is cut off
//!   when the log opens. A purge drops lines that are not entries. The chain proves the file
//!   was not edited by anything but this daemon.
//! - A memory store (tests) keeps the entries in memory, chained the same way.

use cmux_json::JsonSet as _;
use std::collections::HashSet;
use std::io::{BufRead, Seek, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;
use std::sync::atomic::{AtomicU8, AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex, MutexGuard, mpsc};
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
/// How long a flush waits for the sync thread.
// timeout: a flush still waiting past this gives up; the lines are written, only not yet synced.
const DURABLE_WAIT: Duration = Duration::from_secs(10);

/// A pull request with a verdict: the session that opened it and its URL.
type Reviewed = HashSet<(String, String)>;

/// [`Msg::Purge`]'s state: waiting in the queue.
const QUEUED: u8 = 0;
/// The thread started on it: its outcome is coming.
const STARTED: u8 = 1;
/// The caller stopped waiting before the thread took it: never run.
const CANCELLED: u8 = 2;

/// What the sync thread is asked to do. Entries never go through it: their callers write them.
enum Msg {
    /// Lines were written since the last sync: sync them.
    Written,
    /// Answered once every line written before it is synced.
    Flush(mpsc::Sender<()>),
    /// Removes a purged session's entries: answered with how many, unless its caller withdrew
    /// it first (the state goes from [`QUEUED`] to [`CANCELLED`]). Its ticket names it in
    /// [`Chain::queued`]. One that fails leaves the session unfenced.
    Purge(String, tokio::sync::oneshot::Sender<Result<usize, String>>, Arc<AtomicU8>, u64),
    /// A failed write left bytes it could not cut: cut them, unless a record did first.
    Repair,
    /// Tests: tells the first sender the thread is held, then holds it until the second
    /// channel gets a message or ends.
    #[cfg(test)]
    Hold(mpsc::Sender<()>, mpsc::Receiver<()>),
}

/// A purge sent to the thread and not yet taken by it.
struct Queued {
    ticket: u64,
    sid: String,
    /// A chat was created under the id since the purge was sent (`AuditLog::reopen`).
    reopened: bool,
}

/// A line a record wrote.
struct Written {
    /// The entry as written.
    entry: Value,
    /// On disk: the file, and where the line starts and ends in it.
    at: Option<(Arc<std::fs::File>, u64, u64)>,
    /// The first line since the last sync started: the thread is asked for one.
    ask_sync: bool,
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

/// What the callers of a record and the sync thread share, under one lock held for one write:
/// the chain's head and where its next line goes.
struct Chain {
    head: Head,
    /// The file the next line goes to, opened `O_APPEND`; None: opened again first.
    file: Option<Arc<std::fs::File>>,
    /// The last file opened, kept when a failed write drops `file`: what the sync thread
    /// syncs, outside the lock. A later open of the same path is the same file, so a sync of
    /// either covers every line written through both.
    last_file: Option<Arc<std::fs::File>>,
    /// Sessions purged since start: their entries are refused.
    purged: HashSet<String>,
    /// Purges sent and not yet taken by the thread.
    queued: Vec<Queued>,
    /// The last purge ticket given out.
    next_ticket: u64,
    /// A failed write left bytes from here on that it could not cut: cut before the next line.
    torn_at: Option<u64>,
    /// [`Msg::Repair`] is sent and not yet taken.
    repair_asked: bool,
    /// A running purge's snapshot length: it reads the lines before it outside the lock, so
    /// none of them is cut until it ends.
    purging_upto: Option<u64>,
    /// Set by `close`: a record after it is counted as not written.
    closed: bool,
    /// The entries of a log kept in memory (no state folder).
    memory: Option<Vec<Value>>,
}

/// Why a record was not written.
enum NotWritten {
    /// Its chat was purged: not an error to count.
    Purged,
    /// Why, and whether the thread is to cut what the failed write left ([`Msg::Repair`]).
    Failed(String, bool),
}

/// The log's state, shared by its handle and the sync thread.
struct Inner {
    path: Option<PathBuf>,
    chain: StdMutex<Chain>,
    /// Lines were written since the sync thread last started a sync. Set and cleared only
    /// under the `chain` lock.
    dirty: AtomicBool,
    /// Pull requests (session, URL) whose verdict is written: they leave the review queue.
    reviewed: StdMutex<Reviewed>,
    /// Entries that could not be written, and syncs that failed.
    write_errors: AtomicU64,
    /// Tests: every purge fails, after its fence went up.
    #[cfg(test)]
    fail_purges: AtomicBool,
    /// Tests: the lines the last purge copied from after its snapshot.
    #[cfg(test)]
    late_copied: AtomicU64,
}

pub(crate) struct AuditLog {
    /// None once closed: the sync thread exits once it has synced what was written.
    tx: StdMutex<Option<mpsc::Sender<Msg>>>,
    /// Disconnects when the sync thread exits.
    exited: StdMutex<Option<mpsc::Receiver<()>>>,
    inner: Arc<Inner>,
}

impl AuditLog {
    /// The log in `dir` (`<state dir>/audit`), or in memory when `dir` is None.
    pub(crate) fn open(dir: Option<PathBuf>) -> Self {
        let (tx, rx) = mpsc::channel();
        let path = dir.map(|d| d.join(FILE));
        let memory = path.is_none().then(Vec::new);
        let inner = Arc::new(Inner {
            path,
            chain: StdMutex::new(Chain {
                head: Head::default(),
                file: None,
                last_file: None,
                purged: HashSet::new(),
                queued: Vec::new(),
                next_ticket: 0,
                torn_at: None,
                repair_asked: false,
                purging_upto: None,
                closed: false,
                memory,
            }),
            dirty: AtomicBool::new(false),
            reviewed: StdMutex::new(HashSet::new()),
            write_errors: AtomicU64::new(0),
            #[cfg(test)]
            fail_purges: AtomicBool::new(false),
            #[cfg(test)]
            late_copied: AtomicU64::new(0),
        });
        // Before the first record and the first queue read: the head to chain on, and the
        // verdicts already written leave their pull requests out.
        inner.load(&mut inner.lock());
        let (exit_tx, exited) = mpsc::channel::<()>();
        let thread = inner.clone();
        // The thread ends when the log closes or drops (its sender), after a last sync.
        let _ = std::thread::Builder::new().name("acpmux-audit".into()).spawn(move || {
            let _exit = exit_tx;
            thread.run(rx)
        });
        AuditLog { tx: StdMutex::new(Some(tx)), exited: StdMutex::new(Some(exited)), inner }
    }

    /// Tests: makes every purge from now on fail (`fail`) or work again.
    #[cfg(test)]
    pub(crate) fn fail_purges(&self, fail: bool) {
        self.inner.fail_purges.store(fail, Ordering::SeqCst);
    }

    /// [`AuditLog::record_of`] with no chat flag (tests).
    #[cfg(test)]
    pub(crate) fn record(&self, entry: Value) {
        self.record_of(entry, None);
    }

    /// Numbers, chains and writes `entry` (without `v`, `seq`, `prevHash` and `hash`) at once,
    /// and leaves its sync to the sync thread: one write, never a wait for the disk. A line that
    /// cannot be written counts in [`AuditLog::write_errors`]. `gone` is its chat's purged flag:
    /// set by now, the entry is dropped.
    pub(crate) fn record_of(&self, entry: Value, gone: Option<Arc<AtomicBool>>) {
        match self.inner.write(entry, gone.as_deref()) {
            Ok(w) => {
                self.inner.note_reviewed(&w.entry);
                self.written(&w);
            }
            Err(e) => {
                self.not_written(e);
            }
        }
    }

    /// Tests: the lines the last purge copied from after its snapshot.
    #[cfg(test)]
    fn late_copied(&self) -> u64 {
        self.inner.late_copied.load(Ordering::SeqCst)
    }

    /// [`AuditLog::record_durable_of`] with no chat flag (tests).
    #[cfg(test)]
    pub(crate) fn record_durable(&self, entry: Value) -> Result<Value, String> {
        self.record_durable_of(entry, None)
    }

    /// Writes `entry` and syncs it before it returns: the entry as written, or why not.
    /// Blocking (one sync). `gone` as for [`AuditLog::record_of`].
    pub(crate) fn record_durable_of(
        &self,
        entry: Value,
        gone: Option<Arc<AtomicBool>>,
    ) -> Result<Value, String> {
        let w = match self.inner.write(entry, gone.as_deref()) {
            Ok(w) => w,
            Err(e) => {
                return Err(self.not_written(e).unwrap_or_else(|| "the session was purged".into()));
            }
        };
        // Asked even though this verdict syncs itself: `dirty` is set now, so a line written
        // after it asks for no sync of its own and waits for this one.
        self.written(&w);
        if let Some((file, _, _)) = &w.at
            && let Err(e) = file.sync_data()
        {
            // The verdict fails and may be given again: its line goes, unless a line follows it.
            let why = if self.inner.unwrite(&w) {
                format!("sync of the audit file failed: {e}")
            } else {
                format!("sync of the audit file failed (its line stays in the file): {e}")
            };
            self.inner.lost(&why);
            return Err(why);
        }
        self.inner.note_reviewed(&w.entry);
        Ok(w.entry)
    }

    /// Asks the sync thread for a sync when `w` is the first line since the last one started.
    fn written(&self, w: &Written) {
        if w.ask_sync {
            let _ = self.send(Msg::Written);
        }
    }

    /// Counts and logs a record that failed, asking the thread to cut what its write left when
    /// it could not: why it failed. None for a purged chat's entry, which is no error.
    fn not_written(&self, e: NotWritten) -> Option<String> {
        match e {
            NotWritten::Purged => None,
            NotWritten::Failed(why, torn) => {
                if torn {
                    let _ = self.send(Msg::Repair);
                }
                self.inner.lost(&why);
                Some(why)
            }
        }
    }

    fn send(&self, msg: Msg) -> Result<(), ()> {
        let tx = self.tx.lock().unwrap_or_else(|e| e.into_inner());
        tx.as_ref().ok_or(())?.send(msg).map_err(|_| ())
    }

    /// Refuses every later record (counted as not written) and ends the channel: the sync
    /// thread syncs what was written and exits.
    fn stop(&self) {
        self.inner.lock().closed = true;
        drop(self.tx.lock().unwrap_or_else(|e| e.into_inner()).take());
    }

    /// At shutdown: every line is already written; waits up to `deadline` for the sync thread
    /// to sync them (and finish a purge it is running) and exit. Whether it did.
    pub(crate) fn close(&self, deadline: Duration) -> bool {
        self.stop();
        let Some(exited) = self.exited.lock().unwrap_or_else(|e| e.into_inner()).take() else {
            return true;
        };
        match exited.recv_timeout(deadline) {
            Err(mpsc::RecvTimeoutError::Timeout) => {
                tracing::warn!("audit: the sync thread did not finish within {deadline:?}");
                // Kept for `wait_closed`: a sync or a purge is still running.
                *self.exited.lock().unwrap_or_else(|e| e.into_inner()) = Some(exited);
                false
            }
            _ => true,
        }
    }

    /// Ends the channel and waits for the sync thread to exit, however long that takes: what
    /// holds the daemon's home lock until then (`Hub::persist_for_handoff`).
    pub(crate) fn wait_closed(&self) {
        self.stop();
        let exited = self.exited.lock().unwrap_or_else(|e| e.into_inner()).take();
        if let Some(exited) = exited {
            // Disconnected once the thread ends (its sender drops).
            let _ = exited.recv();
        }
    }

    /// Entries that could not be written, and syncs that failed, since this daemon started.
    pub(crate) fn write_errors(&self) -> u64 {
        self.inner.write_errors.load(Ordering::Relaxed)
    }

    /// Removes every entry of session `session_id` from the log; one recorded after the thread
    /// starts the purge is refused. The answer comes once the rewritten file is on disk (None:
    /// the thread is gone).
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
        // No fence yet: it goes up when the thread starts the purge (`Inner::purge_fenced`), so
        // a purge that waits, then fails or is given up on, refused no entry. One written while
        // it waits is in the file, and goes with the rest when it runs.
        let ticket = {
            let mut c = self.inner.lock();
            c.next_ticket += 1;
            let ticket = c.next_ticket;
            c.queued.push(Queued { ticket, sid: session_id.to_owned(), reopened: false });
            ticket
        };
        let sent = self.send(Msg::Purge(session_id.to_owned(), tx, state.clone(), ticket));
        if sent.is_err() {
            self.inner.lock().queued.retain(|q| q.ticket != ticket);
            return None;
        }
        Some((rx, state))
    }

    /// Removes session `session_id`'s entries, waiting up to `wait` for the sync thread to take
    /// the purge: one it has not taken by then is withdrawn and never runs, one it has taken is
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
                    // Never runs, so its fence never went up: the session's entries were
                    // written all along, and stay.
                    return Err("the audit writer did not take the purge in time".into());
                }
                rx.await.unwrap_or_else(|_| Err("the audit writer is gone".into()))
            }
        }
    }

    /// A chat was created under `session_id` (`Hub::new_session_with_id`): if a purge fenced that
    /// id this run, the fence comes down at once. Never blocks on the disk.
    ///
    /// A purge of the id still waiting in the queue is marked: when it starts it raises no
    /// fence, so the id stays writable afterwards, as when the reopen queued behind the purge.
    /// It still removes every entry of the id written before it starts. A new chat's entries
    /// written between the reopen and that start would go with them, but `Hub::kill` keeps the
    /// purged chat, and its id, until its purge ended or was given up on (a create under a live
    /// id is refused), so a reopen does not meet a waiting purge of its id there.
    pub(crate) fn reopen(&self, session_id: &str) {
        let mut c = self.inner.lock();
        c.purged.remove(session_id);
        for q in c.queued.iter_mut().filter(|q| q.sid == session_id) {
            q.reopened = true;
        }
    }

    /// Whether the pull request at `url`, opened by session `session_id`, has a written verdict.
    pub(crate) fn reviewed(&self, session_id: &str, url: &str) -> bool {
        let key = (session_id.to_owned(), url.to_owned());
        self.inner.reviewed.lock().unwrap_or_else(|e| e.into_inner()).contains(&key)
    }

    /// Waits until every entry recorded before this call is synced (or the thread is gone).
    pub(crate) fn flush(&self) {
        let (tx, rx) = mpsc::channel();
        if self.send(Msg::Flush(tx)).is_ok() {
            let _ = rx.recv_timeout(DURABLE_WAIT);
        }
    }

    /// Every entry, oldest first. Blocking: reads the file.
    pub(crate) fn all(&self) -> std::io::Result<Vec<Value>> {
        self.flush();
        if let Some(m) = &self.inner.lock().memory {
            return Ok(m.clone());
        }
        let Some(path) = &self.inner.path else { return Ok(vec![]) };
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

impl Inner {
    fn lock(&self) -> MutexGuard<'_, Chain> {
        self.chain.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn lost(&self, why: &str) {
        self.write_errors.fetch_add(1, Ordering::Relaxed);
        tracing::warn!("audit: an entry was not written: {why}");
    }

    /// A written verdict's pull request leaves the review queue.
    fn note_reviewed(&self, entry: &Value) {
        if let Some(key) = review_key(entry) {
            self.reviewed.lock().unwrap_or_else(|e| e.into_inner()).insert(key);
        }
    }

    /// The sync thread: syncs what callers wrote and runs purges, in the order asked.
    fn run(&self, rx: mpsc::Receiver<Msg>) {
        while let Ok(msg) = rx.recv() {
            match msg {
                Msg::Written => self.sync(),
                Msg::Flush(done) => {
                    self.sync();
                    let _ = done.send(());
                }
                Msg::Purge(sid, done, state, ticket) => {
                    if state
                        .compare_exchange(QUEUED, STARTED, Ordering::AcqRel, Ordering::Acquire)
                        .is_err()
                    {
                        // Withdrawn: it never ran, so it never fenced; the chat stays, and so do
                        // its entries.
                        self.lock().queued.retain(|q| q.ticket != ticket);
                        continue;
                    }
                    let purged = self.purge(&sid, ticket);
                    if let Err(why) = &purged {
                        tracing::warn!("audit: a purged chat's entries were not removed: {why}");
                    }
                    let _ = done.send(purged);
                }
                Msg::Repair => self.repair(),
                #[cfg(test)]
                Msg::Hold(held, release) => {
                    let _ = held.send(());
                    let _ = release.recv();
                }
            }
        }
        // Closed (`AuditLog::stop` set `closed` under the lock before it ended the channel) or
        // dropped: no line is written from here on, and this sync, which reads `dirty` under
        // the same lock, covers every line written before.
        self.sync();
    }

    /// Syncs every line written before it starts, if any was. The lock is held only to take the
    /// file: a caller writes while the disk syncs.
    fn sync(&self) {
        let file = {
            let c = self.lock();
            // Read and cleared under the lock every append sets it under: a line written before
            // is in what this sync covers, one written after asks for the next sync.
            if !self.dirty.swap(false, Ordering::AcqRel) {
                return;
            }
            c.last_file.clone()
        };
        let Some(file) = file else { return };
        if let Err(e) = file.sync_data() {
            self.write_errors.fetch_add(1, Ordering::Relaxed);
            tracing::warn!("audit: the sync of the audit file failed: {e}");
        }
    }

    /// The chain's head and the reviewed pull requests, from the file as it is (a torn tail cut
    /// off first).
    fn load(&self, c: &mut Chain) {
        let Some(path) = &self.path else { return };
        if let Err(e) = cut_torn_tail(path) {
            tracing::warn!("audit: could not cut a torn tail of {}: {e}", path.display());
        }
        let Ok(entries) = read_lines(path) else { return };
        let mut reviewed = self.reviewed.lock().unwrap_or_else(|e| e.into_inner());
        for e in &entries {
            if let Some(key) = review_key(e) {
                reviewed.insert(key);
            }
        }
        drop(reviewed);
        if let Some(last) = entries.last() {
            c.head = Head {
                seq: last.get("seq").and_then(Value::as_u64).unwrap_or(entries.len() as u64),
                hash: last.get("hash").and_then(Value::as_str).unwrap_or(GENESIS).to_owned(),
            };
        }
    }

    /// Under the lock, at the event: numbers, chains and writes `entry` (one write, no sync).
    fn write(&self, entry: Value, gone: Option<&AtomicBool>) -> Result<Written, NotWritten> {
        let mut c = self.lock();
        if c.closed {
            return Err(NotWritten::Failed("the audit log is closed".into(), false));
        }
        let sid = entry.get("sessionId").and_then(Value::as_str);
        if gone.is_some_and(|g| g.load(Ordering::SeqCst))
            || sid.is_some_and(|s| c.purged.contains(s))
        {
            // A purged chat leaves no history.
            return Err(NotWritten::Purged);
        }
        self.append_locked(&mut c, entry)
    }

    fn append_locked(&self, c: &mut Chain, entry: Value) -> Result<Written, NotWritten> {
        let Some((entry, head)) = seal(&c.head, entry) else {
            return Err(NotWritten::Failed("not an object".into(), false));
        };
        if let Some(m) = &mut c.memory {
            m.push(entry.clone());
            c.head = head;
            return Ok(Written { entry, at: None, ask_sync: false });
        }
        let Some(path) = &self.path else {
            return Err(NotWritten::Failed("no audit file".into(), false));
        };
        let mut line = entry.to_string();
        line.push('\n');
        match append(c, path, line.as_bytes()) {
            Ok((file, start)) => {
                c.head = head;
                // Under the lock: a sync that starts after this (the last one at close too)
                // covers this line.
                let ask_sync = !self.dirty.swap(true, Ordering::AcqRel);
                let end = start + line.len() as u64;
                Ok(Written { entry, at: Some((file, start, end)), ask_sync })
            }
            Err(e) => {
                // The next entry tries again with a new handle; this one is not chained.
                c.file = None;
                // Bytes the write left and could not cut: the next append cuts them first (one
                // `set_len`, no read), so a record meanwhile is written after the cut and loses
                // nothing when the disk works; the thread is asked once to cut them in case no
                // record comes. A cut that fails again fails that record, counted.
                let torn = c.torn_at.is_some() && !c.repair_asked;
                if torn {
                    c.repair_asked = true;
                }
                Err(NotWritten::Failed(format!("append to {} failed: {e}", path.display()), torn))
            }
        }
    }

    /// The thread's side of a failed write: cuts the bytes it left, unless a record or a purge
    /// did first. One `set_len` under the lock, no read: the torn line never moved the head.
    fn repair(&self) {
        let mut c = self.lock();
        c.repair_asked = false;
        if c.torn_at.is_none() {
            return;
        }
        let Some(path) = &self.path else { return };
        if let Err(e) = open_locked(&mut c, path) {
            c.file = None;
            tracing::warn!("audit: could not cut a failed write off {}: {e}", path.display());
        }
    }

    /// A verdict whose sync failed: its line is cut off again while it is still the file's last
    /// (no line written after it, no purge since), and the head goes back to the entry before
    /// it. Whether it was. Otherwise the line stays: a cut would take later lines with it, so a
    /// restart counts it and a retry of the verdict writes a second entry.
    fn unwrite(&self, w: &Written) -> bool {
        let Some((file, start, end)) = &w.at else { return false };
        let seq = w.entry.get("seq").and_then(Value::as_u64).unwrap_or(0);
        let hash = w.entry.get("hash").and_then(Value::as_str).unwrap_or_default();
        let prev = w.entry.get("prevHash").and_then(Value::as_str).unwrap_or(GENESIS);
        let mut c = self.lock();
        let last = c.head.seq == seq
            && c.head.hash == hash
            && c.torn_at.is_none()
            && c.purging_upto.is_none_or(|upto| *start >= upto)
            && c.file.as_ref().is_some_and(|f| Arc::ptr_eq(f, file))
            && file.metadata().is_ok_and(|m| m.len() == *end);
        if !last || file.set_len(*start).is_err() {
            return false;
        }
        c.head = Head { seq: seq.saturating_sub(1), hash: prev.to_owned() };
        true
    }

    /// Drops session `sid`'s entries and chains the rest again: how many went. On a failure a
    /// fence this purge raised comes down again: the chat stays, and its entries keep being
    /// written.
    fn purge(&self, sid: &str, ticket: u64) -> Result<usize, String> {
        let mut fenced = false;
        let purged = self.purge_fenced(sid, ticket, &mut fenced);
        let mut c = self.lock();
        c.purging_upto = None;
        match &purged {
            Ok(_) => {
                drop(c);
                self.reviewed.lock().unwrap_or_else(|e| e.into_inner()).retain(|(s, _)| s != sid);
            }
            Err(_) => {
                if fenced {
                    c.purged.remove(sid);
                }
            }
        }
        purged
    }

    /// [`Inner::purge`]; `fenced` is set when it raised the session's fence.
    fn purge_fenced(&self, sid: &str, ticket: u64, fenced: &mut bool) -> Result<usize, String> {
        // Under the lock, as the purge starts: the fence goes up with the length snapshot, so
        // every entry of the session written before is in the file before that length, which
        // bounds what the slow part reads, and every later one is refused.
        let upto = {
            let mut c = self.lock();
            let reopened = match c.queued.iter().position(|q| q.ticket == ticket) {
                Some(i) => c.queued.swap_remove(i).reopened,
                None => false,
            };
            if !reopened {
                // Only when it was not already up (an earlier purge), so a failure lowers only
                // its own. A purge a reopen of the id met in the queue raises none: the new chat
                // took the id, and the old queue order would have lowered it again.
                *fenced = c.purged.insert(sid.to_owned());
            }
            #[cfg(test)]
            if self.fail_purges.load(Ordering::SeqCst) {
                return Err("purges fail in this test".into());
            }
            if let Some(m) = c.memory.take() {
                // In memory (tests): all of it under the lock.
                let (kept, removed, head) = without(&m, Some(sid), Head::default());
                if removed == 0 {
                    c.memory = Some(m);
                    return Ok(0);
                }
                c.memory = Some(kept);
                c.head = head;
                return Ok(removed);
            }
            let Some(path) = &self.path else { return Ok(0) };
            // The snapshot ends on a whole line: before the bytes a failed write left, if any
            // (no line follows them until they are cut).
            let upto = match c.torn_at {
                Some(at) => at,
                None => file_len(path).map_err(|e| format!("stat {}: {e}", path.display()))?,
            };
            c.purging_upto = Some(upto);
            upto
        };
        let Some(path) = &self.path else { return Ok(0) };
        // Outside the lock: callers keep appending to the old file, after `upto`.
        let old = read_lines_in(path, 0, Some(upto))
            .map_err(|e| format!("read {}: {e}", path.display()))?;
        let (kept, removed, head) = without(&old, Some(sid), Head::default());
        if removed == 0 {
            return Ok(0);
        }
        let (tmp, mut file) =
            write_tmp(path, &kept).map_err(|e| format!("rewrite {}: {e}", path.display()))?;
        // Under the lock again: the lines written since the snapshot follow, chained on, and
        // the new file takes the old one's place before any later line is written.
        let mut c = self.lock();
        // Up to the bytes a failed write left meanwhile, if any: they are no line.
        let late_end = c.torn_at;
        let swapped = (|| {
            let late = read_lines_in(path, upto, late_end)?;
            let (late, _, head) = without(&late, None, head);
            write_entries(&mut file, &late)?;
            file.sync_all()?;
            crate::home_fs::rename(&tmp, path)?;
            Ok::<(Head, usize), std::io::Error>((head, late.len()))
        })();
        match swapped {
            Ok((head, _late)) => {
                c.head = head;
                // The next line opens the new file, which holds only whole lines, synced.
                c.file = None;
                c.last_file = None;
                c.torn_at = None;
                #[cfg(test)]
                self.late_copied.store(_late as u64, Ordering::SeqCst);
            }
            Err(e) => return Err(format!("rewrite {}: {e}", path.display())),
        }
        drop(c);
        if let Some(dir) = path.parent()
            && let Ok(d) = std::fs::File::open(dir)
        {
            let _ = d.sync_all();
        }
        Ok(removed)
    }
}

/// The chain's file, opened if needed, with the bytes a failed write left cut off first.
/// Under the lock. The folder check runs on the caller of a record at the first open (once per
/// process, and again after a failed write dropped the handle): a few `stat`s, no read.
fn open_locked(c: &mut Chain, path: &Path) -> std::io::Result<Arc<std::fs::File>> {
    let file = match c.file.clone() {
        Some(f) => f,
        None => {
            private_dir_of(path)?;
            let file = crate::config::private_state_append(path).map_err(std::io::Error::other)?;
            let file = Arc::new(file);
            c.file = Some(file.clone());
            c.last_file = Some(file.clone());
            file
        }
    };
    if let Some(at) = c.torn_at {
        file.set_len(at)?;
        c.torn_at = None;
    }
    Ok(file)
}

/// Appends `line` to the chain's file (opened first if needed) in one write: the file, for its
/// sync, and where the line starts. A write that fails is cut off again, so the next line does
/// not land on half of it; when that cut fails, `torn_at` keeps where to cut.
fn append(c: &mut Chain, path: &Path, line: &[u8]) -> std::io::Result<(Arc<std::fs::File>, u64)> {
    let file = open_locked(c, path)?;
    // Every write is under the lock: the length before is where this line starts.
    let before = file.metadata()?.len();
    let mut out: &std::fs::File = &file;
    if let Err(e) = out.write_all(line) {
        if file.set_len(before).is_err() {
            c.torn_at = Some(before);
        }
        return Err(e);
    }
    Ok((file, before))
}

/// The entries of `old` that are not `sid`'s (all of them for None), chained again after `head`,
/// how many of `sid`'s went, and the head after them. A line that is not an entry could hold
/// anything of the chat: it goes too.
fn without(old: &[Value], sid: Option<&str>, mut head: Head) -> (Vec<Value>, usize, Head) {
    let of =
        |e: &Value| sid.is_some_and(|sid| e.get("sessionId").and_then(Value::as_str) == Some(sid));
    let removed = old.iter().filter(|e| of(e)).count();
    let mut kept = Vec::with_capacity(old.len() - removed);
    for e in old.iter().filter(|e| e.is_object() && !of(e)) {
        if let Some((sealed, next)) = seal(&head, e.clone()) {
            head = next;
            kept.push(sealed);
        }
    }
    (kept, removed, head)
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

/// A new file beside `path` holding `entries`, synced: the purge's rewrite, renamed over `path`
/// once the lines written meanwhile follow them. Its path and the file, open for those lines.
fn write_tmp(path: &Path, entries: &[Value]) -> std::io::Result<(PathBuf, std::fs::File)> {
    private_dir_of(path)?;
    let tmp = path.with_extension("jsonl.tmp");
    // A leftover (or planted) tmp goes first: removing a link never touches what it names.
    match crate::home_fs::remove_file(&tmp) {
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(e),
        _ => {}
    }
    let mut file = crate::config::private_state_create_new(&tmp).map_err(std::io::Error::other)?;
    write_entries(&mut file, entries)?;
    file.sync_data()?;
    Ok((tmp, file))
}

/// Writes `entries` to `file`, one line each.
fn write_entries(file: &mut std::fs::File, entries: &[Value]) -> std::io::Result<()> {
    let mut out = std::io::BufWriter::new(file);
    for e in entries {
        out.write_all(e.to_string().as_bytes())?;
        out.write_all(b"\n")?;
    }
    out.flush()
}

/// Whether something is at `path` (a link counts, and is refused when opened).
fn exists(path: &Path) -> std::io::Result<bool> {
    match std::fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(e),
    }
}

/// The length of what is at `path` (0 for nothing).
fn file_len(path: &Path) -> std::io::Result<u64> {
    match std::fs::symlink_metadata(path) {
        Ok(m) => Ok(m.len()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(0),
        Err(e) => Err(e),
    }
}

/// Every line of `path`, opened as private state: a link, a file that is not regular or one
/// another user owns is refused, and a wider mode is narrowed to 0600.
fn read_lines(path: &Path) -> std::io::Result<Vec<Value>> {
    read_lines_in(path, 0, None)
}

/// The lines of `path` from byte `from` up to byte `upto` (the end for None), each a whole
/// line when both are where a line starts. Opened as [`read_lines`] opens it.
fn read_lines_in(path: &Path, from: u64, upto: Option<u64>) -> std::io::Result<Vec<Value>> {
    private_dir_of(path)?;
    if !exists(path)? {
        return Ok(vec![]);
    }
    let mut file = crate::config::private_state_file(path).map_err(std::io::Error::other)?;
    if from > 0 {
        file.seek(std::io::SeekFrom::Start(from))?;
    }
    let limit = upto.map_or(u64::MAX, |u| u.saturating_sub(from));
    let mut out = Vec::new();
    for line in std::io::BufReader::new(std::io::Read::take(file, limit)).lines() {
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

    /// An entry given while the purge waits in the queue is written, then goes with the rest; one
    /// given after the purge started (a verdict that passed the hub's check before) is refused.
    #[tokio::test]
    async fn an_entry_after_the_purge_started_is_refused_and_one_before_goes_with_it() {
        let d = dir("fence");
        let log = AuditLog::open(Some(d.clone()));
        log.record(entry("gone", 1));
        let (held_tx, held) = mpsc::channel();
        let (release, release_rx) = mpsc::channel::<()>();
        log.send(Msg::Hold(held_tx, release_rx)).unwrap();
        held.recv_timeout(Duration::from_secs(10))
            .unwrap_or_else(|e| panic!("the writer did not reach its hold: {e}"));
        let purge = log.purge("gone").unwrap();
        let waiting = log.record_durable(json!({"at": 2, "sessionId": "gone", "kind": "review",
                                                "prUrl": "https://github.com/o/r/pull/5",
                                                "ask": "Review", "decision": {"kind": "accept"},
                                                "answeredBy": {"person": true}}));
        assert!(waiting.is_ok(), "{waiting:?}");
        drop(release);
        assert_eq!(purge.await.unwrap(), Ok(2));
        assert!(!log.reviewed("gone", "https://github.com/o/r/pull/5"));
        let late = log.record_durable(json!({"at": 3, "sessionId": "gone", "kind": "review",
                                             "prUrl": "https://github.com/o/r/pull/6",
                                             "ask": "Review", "decision": {"kind": "accept"},
                                             "answeredBy": {"person": true}}));
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
    fn a_purge_given_up_on_never_runs() {
        let d = dir("cancel");
        let log = AuditLog::open(Some(d.clone()));
        log.record(entry("s1", 1));
        let (done, mut rx) = tokio::sync::oneshot::channel();
        let state = Arc::new(AtomicU8::new(CANCELLED));
        log.send(Msg::Purge("s1".into(), done, state, 0)).unwrap();
        log.record(entry("s1", 2));
        log.flush();
        assert!(rx.try_recv().is_err(), "a withdrawn purge gets no answer");
        let all = log.all().unwrap();
        let ats: Vec<_> = all.iter().map(|e| e["at"].clone()).collect();
        assert_eq!(ats, vec![json!(1), json!(2)]);
        let _ = std::fs::remove_dir_all(&d);
    }

    /// What a `kill -9` right after a record keeps: the audit thread is held before the records,
    /// so it runs nothing of them, and a fresh read of the file, as the next daemon's open does,
    /// already has both entries, chained. A record that only queued its line for the thread
    /// fails this.
    #[test]
    fn a_record_is_in_the_file_when_it_returns_before_the_thread_runs() {
        let d = dir("kill");
        let log = AuditLog::open(Some(d.clone()));
        let (held_tx, held) = mpsc::channel();
        let (release, release_rx) = mpsc::channel::<()>();
        log.send(Msg::Hold(held_tx, release_rx)).unwrap();
        held.recv_timeout(Duration::from_secs(10))
            .unwrap_or_else(|e| panic!("the writer did not reach its hold: {e}"));
        log.record(entry("s1", 1));
        log.record(entry("s2", 2));
        let on_disk = read_lines(&d.join(FILE)).unwrap();
        let ats: Vec<_> = on_disk.iter().map(|e| e["at"].clone()).collect();
        assert_eq!(ats, vec![json!(1), json!(2)], "a record returned before its line was written");
        assert_eq!(verify(&on_disk), json!({"ok": true, "entries": 2}));
        drop(release);
        drop(log);
        // The next daemon continues the chain from them.
        let next = AuditLog::open(Some(d.clone()));
        next.record(entry("s1", 3));
        let all = next.all().unwrap();
        assert_eq!(all[2]["seq"], 3);
        assert_eq!(verify(&all)["ok"], true, "{}", verify(&all));
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn records_from_many_threads_keep_one_chain() {
        let d = dir("threads");
        let log = Arc::new(AuditLog::open(Some(d.clone())));
        let (threads, each) = (8u64, 200u64);
        let workers: Vec<_> = (0..threads)
            .map(|t| {
                let log = log.clone();
                std::thread::spawn(move || {
                    for i in 0..each {
                        log.record(entry(&format!("s{t}"), t * each + i));
                    }
                })
            })
            .collect();
        for w in workers {
            w.join().unwrap();
        }
        let all = read_lines(&d.join(FILE)).unwrap();
        assert_eq!(all.len() as u64, threads * each);
        assert_eq!(verify(&all)["ok"], true, "{}", verify(&all));
        let mut ats: Vec<u64> = all.iter().map(|e| e["at"].as_u64().unwrap()).collect();
        ats.sort_unstable();
        assert_eq!(ats, (0..threads * each).collect::<Vec<_>>(), "an entry is missing or twice");
        assert_eq!(log.write_errors(), 0);
        let _ = std::fs::remove_dir_all(&d);
    }

    /// Records keep coming while a purge reads and rewrites the file: every one of them is in
    /// the rewritten file, after the kept ones, and the chain verifies. At least one run (of a
    /// bounded number) has a line written after the purge's snapshot, copied by its last step.
    #[tokio::test]
    async fn a_purge_racing_records_loses_none_of_them() {
        let mut copied = 0;
        for attempt in 0..20 {
            copied = purge_racing_records(attempt).await;
            if copied > 0 {
                break;
            }
        }
        assert!(copied > 0, "no record landed after the purge's snapshot in 20 runs");
    }

    /// One run of [`a_purge_racing_records_loses_none_of_them`]: the lines the purge copied
    /// from after its snapshot.
    async fn purge_racing_records(attempt: u32) -> u64 {
        let d = dir(&format!("purge-race-{attempt}"));
        let log = Arc::new(AuditLog::open(Some(d.clone())));
        // Enough of the purged chat that the rewrite takes a while.
        for at in 0..5_000 {
            log.record(entry(if at % 2 == 0 { "gone" } else { "keep" }, at));
        }
        let stop = Arc::new(AtomicBool::new(false));
        let writers: Vec<_> = (0..4u64)
            .map(|t| {
                let (log, stop) = (log.clone(), stop.clone());
                std::thread::spawn(move || {
                    let mut n = 0u64;
                    while !stop.load(Ordering::SeqCst) || n < 50 {
                        log.record(entry(&format!("late{t}"), 1_000_000 * (t + 1) + n));
                        n += 1;
                    }
                    n
                })
            })
            .collect();
        let purged = log.purge("gone").unwrap().await.unwrap();
        stop.store(true, Ordering::SeqCst);
        let late: u64 = writers.into_iter().map(|w| w.join().unwrap()).sum();
        assert_eq!(purged, Ok(2_500));
        let all = log.all().unwrap();
        assert_eq!(verify(&all)["ok"], true, "{}", verify(&all));
        let of = |s: &str| all.iter().filter(|e| e["sessionId"] == s).count() as u64;
        assert_eq!(of("gone"), 0);
        assert_eq!(of("keep"), 2_500);
        let late_kept: u64 = (0..4).map(|t| of(&format!("late{t}"))).sum();
        assert_eq!(late_kept, late, "a record written during the purge was lost");
        // Each thread's records stay in the order they were written.
        for t in 0..4u64 {
            let ats: Vec<u64> = all
                .iter()
                .filter(|e| e["sessionId"] == format!("late{t}").as_str())
                .map(|e| e["at"].as_u64().unwrap())
                .collect();
            assert!(ats.windows(2).all(|w| w[0] < w[1]), "late{t} out of order");
        }
        assert_eq!(log.write_errors(), 0);
        let copied = log.late_copied();
        let _ = std::fs::remove_dir_all(&d);
        copied
    }

    /// A purge that waits in the queue, then is given up on or fails, refuses no record of its
    /// session meanwhile: every one is in the file after it.
    #[tokio::test]
    async fn a_purge_that_did_not_run_or_failed_refused_nothing() {
        let d = dir("purge-wait");
        let log = AuditLog::open(Some(d.clone()));
        let (held_tx, held) = mpsc::channel();
        let (release, release_rx) = mpsc::channel::<()>();
        log.send(Msg::Hold(held_tx, release_rx)).unwrap();
        held.recv_timeout(Duration::from_secs(10))
            .unwrap_or_else(|e| panic!("the writer did not reach its hold: {e}"));
        // Queued behind the held thread, recorded while it waits, then given up on. The record
        // yields first, so it runs after the purge was sent whichever future is polled first.
        let (given_up, ()) =
            tokio::join!(log.purge_within("s1", Duration::from_millis(200)), async {
                tokio::task::yield_now().await;
                log.record(entry("s1", 1));
            });
        assert!(given_up.is_err());
        log.record(entry("s1", 2));
        drop(release);
        log.fail_purges(true);
        let (held_tx, held) = mpsc::channel();
        let (release, release_rx) = mpsc::channel::<()>();
        log.send(Msg::Hold(held_tx, release_rx)).unwrap();
        held.recv_timeout(Duration::from_secs(10))
            .unwrap_or_else(|e| panic!("the writer did not reach its hold: {e}"));
        // Queued, then fails.
        let failed = log.purge("s1").unwrap();
        log.record(entry("s1", 3));
        drop(release);
        assert!(failed.await.unwrap().is_err());
        log.record(entry("s1", 4));
        let all = log.all().unwrap();
        let ats: Vec<_> = all.iter().map(|e| e["at"].clone()).collect();
        assert_eq!(ats, vec![json!(1), json!(2), json!(3), json!(4)]);
        assert_eq!(log.write_errors(), 0);
        let _ = std::fs::remove_dir_all(&d);
    }

    /// A chat recreated under an id whose purge still waits in the queue: the purge removes
    /// what was written before it starts and leaves the id writable after it.
    #[tokio::test]
    async fn a_reopen_while_a_purge_waits_leaves_the_id_writable() {
        let d = dir("purge-reopen");
        let log = AuditLog::open(Some(d.clone()));
        log.record(entry("same", 1));
        let (held_tx, held) = mpsc::channel();
        let (release, release_rx) = mpsc::channel::<()>();
        log.send(Msg::Hold(held_tx, release_rx)).unwrap();
        held.recv_timeout(Duration::from_secs(10))
            .unwrap_or_else(|e| panic!("the writer did not reach its hold: {e}"));
        let purge = log.purge("same").unwrap();
        log.reopen("same");
        drop(release);
        assert_eq!(purge.await.unwrap(), Ok(1));
        log.record(entry("same", 2));
        let all = log.all().unwrap();
        let ats: Vec<_> = all.iter().map(|e| e["at"].clone()).collect();
        assert_eq!(ats, vec![json!(2)]);
        let _ = std::fs::remove_dir_all(&d);
    }

    /// A verdict whose sync fails is cut off again while its line is the file's last, and the
    /// chain goes on from the entry before it.
    #[test]
    fn an_unsynced_verdict_is_cut_while_it_is_the_last_line() {
        let d = dir("unwrite");
        let log = AuditLog::open(Some(d.clone()));
        log.record(entry("s1", 1));
        let before = std::fs::read(d.join(FILE)).unwrap();
        let w = log.inner.write(entry("s1", 2), None).ok().unwrap();
        assert!(log.inner.unwrite(&w));
        assert_eq!(std::fs::read(d.join(FILE)).unwrap(), before);
        let w = log.inner.write(entry("s1", 3), None).ok().unwrap();
        log.record(entry("s1", 4));
        assert!(!log.inner.unwrite(&w), "a line followed by another stays");
        let all = log.all().unwrap();
        let ats: Vec<_> = all.iter().map(|e| e["at"].clone()).collect();
        assert_eq!(ats, vec![json!(1), json!(3), json!(4)]);
        assert_eq!(verify(&all)["ok"], true, "{}", verify(&all));
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

#[cfg(test)]
#[path = "audit_log_bench.rs"]
mod audit_log_bench;
