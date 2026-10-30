//! The file store's event logs are written by one background thread (plans/cmux-next/perf-lead.md
//! A1 and D1: "transcript writes are background appends, never one sync write per token").
//!
//! An append used to write its line in place, under one lock for every session's log, on the
//! thread that read the agent's output (a tokio worker): one `write(2)` per streamed token. When
//! more sessions wrote than the store keeps open (`open_logs_for`), each append that opened a log
//! first closed the least recently written one with `sync_data`, an F_FULLFSYNC on macOS
//! (20-50 ms), still under that lock, so every chat's next token waited for it.
//!
//! Now `append` queues the line and returns. The thread writes each session's queued lines in
//! one write, sessions in turn, and never syncs: a log it closes (evicted, full, or its session
//! closed) stays on the dirty list, and `flush` (shutdown) syncs every log written since the
//! last flush, closed ones too, so a flush still leaves everything durable. A read of a session's
//! log (`settle`) first waits for the lines that session had queued when the read began (written
//! in the next batch of waited-for sessions; see Order below), so readers see every append made
//! before the read; a flush waits for every line queued
//! before it. Neither waits for a queue to be empty: a chat that streams queues its next token
//! while the one before it is written, so its queue never is, and a read that waited for that
//! got no reply while the chat streamed (fleet job 88f5f7da34f5480fc9817e95). `progress` tells
//! an agent host's reader what is on disk, so a host entry is acknowledged only once its record
//! is written (`agent_host` keeps it until then).
//!
//! Order: requests and reads that wait for a session's lines (`expedite`, `settle`) are served
//! in batches, in the order they arrived. The writer takes every session with a waiter as one
//! batch; a waiter that arrives while a batch is written goes in the next batch, never ahead of
//! one that waited before it (the newest waiter used to go first, and at 80 clients an early
//! request waited until the others stopped: 20.4 s at p99, fleet job 7bc67123c95ede759d91350d).
//! Between two batches the writer writes one session in its background turn, so a streaming chat
//! and a shutdown flush are never starved by a steady stream of requests. A waiter therefore
//! waits for at most: the write in progress, the rest of the current batch, one background
//! write, and its own batch.
//!
//! Priority: the thread runs at Utility. A waiter raises it to the waiter's QoS for as long as
//! it waits (`cmux_threads::OwnerBoost`: the writer holds it for each write, a waiter that comes
//! during a write raises that write, and each later write starts raised while a waiter is
//! counted), as Chromium's priority-inheritance locks raise the owner a higher thread waits on.
//! With no waiter the writes run at Utility again.
//!
//! The thread is hang-watched (`daemon/hang_watch.rs`): each session's write is one item of
//! [`WRITE_ITEM`], never the wait for the next one.

use super::open_private_append;
use crate::daemon::hang_watch::{SyncThread, WRITE_ITEM};
use anyhow::Result;
use std::collections::{HashMap, HashSet, VecDeque};
use std::fs::File;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};

use crate::supervised::{Fatal, OwnedThread, ShutdownBehavior, Supervisor};

/// What of one session's log is on disk: every record up to `written` is, and `queued` is the
/// last record handed to the writer. Nothing is pending when they are equal.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Progress {
    pub queued: u64,
    pub written: u64,
    /// A write of this session's log failed; nothing after it is written.
    pub failed: bool,
}

impl Progress {
    /// Whether every record up to `seq`, among those appended so far, is on disk.
    pub fn covers(&self, seq: u64) -> bool {
        !self.failed && (self.written >= seq || self.written == self.queued)
    }
}

/// The lines one session has queued, the last record among them, and the ticket of the last
/// line ([`State::tickets`]).
#[derive(Default)]
struct Queued {
    lines: Vec<u8>,
    last: u64,
    ticket: u64,
}

#[derive(Default)]
struct State {
    queued: HashMap<String, Queued>,
    /// Sessions with queued lines, in the order they first queued: each is written in turn (the
    /// background turn). A session is listed at most once ([`State::listed`]); an entry whose
    /// lines a batch wrote stays in its place, and the writer skips it if nothing is queued then.
    order: VecDeque<String>,
    /// The sessions `order` lists, each once: the list never grows past the sessions it names. A
    /// batch write takes the session off the list (it had its turn), so a chat nobody waits for is
    /// written in the background turn after each batch, not after a turn of every waited-for chat
    /// (review of 69d858ce9764, finding 1).
    listed: HashSet<String>,
    /// Sessions a request or a read waits for, in the order the first waiter of each came, not in
    /// the batch being written: the next batch.
    waiting: VecDeque<String>,
    /// The batch being written: the sessions that had a waiter when it began.
    batch: VecDeque<String>,
    /// The next write is the background turn's (one after each batch).
    background_turn: bool,
    writing: Option<String>,
    /// The ticket of the last line of the batch being written.
    writing_ticket: u64,
    /// Lines appended so far, every session's: each append takes the next number as its ticket.
    tickets: u64,
    /// The ticket of each session's last line written (or dropped by a failed write), from its
    /// first append until `forget`. A wait for session `id` up to ticket `t` is over once
    /// `done[id] >= t`: lines queued after the wait began never hold it.
    done: HashMap<String, u64>,
    /// Sessions whose log closes once their queued lines are written (`close_log`).
    close_after: HashSet<String>,
    progress: HashMap<String, tokio::sync::watch::Sender<Progress>>,
    stop: bool,
}

impl State {
    /// The ticket of session `id`'s last line not yet written, queued or being written.
    fn pending(&self, id: &str) -> Option<u64> {
        match self.queued.get(id) {
            Some(q) => Some(q.ticket),
            None => (self.writing.as_deref() == Some(id)).then_some(self.writing_ticket),
        }
    }

    /// Whether session `id`'s lines up to `ticket` are written (or it was forgotten).
    fn written(&self, id: &str, ticket: u64) -> bool {
        self.done.get(id).is_none_or(|done| *done >= ticket)
    }

    /// Queues `line` for session `id`, record `seq`: it takes the next ticket.
    fn queue(&mut self, id: &str, line: &[u8], seq: u64) {
        if self.listed.insert(id.to_owned()) {
            self.order.push_back(id.to_owned());
        }
        self.tickets += 1;
        let ticket = self.tickets;
        self.done.entry(id.to_owned()).or_default();
        let q = self.queued.entry(id.to_owned()).or_default();
        q.lines.extend_from_slice(line);
        q.last = q.last.max(seq);
        q.ticket = ticket;
    }

    /// The session whose queued lines the writer writes next: the rest of the current batch,
    /// then one background session, then the sessions waited for since the batch began, as the
    /// next batch.
    fn next(&mut self) -> Option<String> {
        loop {
            while let Some(id) = self.batch.pop_front() {
                if self.queued.contains_key(&id) {
                    // A batch write is the session's turn: it leaves the background list (lines it
                    // queues later list it again, at the back), so a session nobody waits for is
                    // not held behind a background turn of every waited-for session.
                    if self.listed.remove(&id)
                        && let Some(at) = self.order.iter().position(|o| *o == id)
                    {
                        self.order.remove(at);
                    }
                    return Some(id);
                }
            }
            if !self.waiting.is_empty() && !self.background_turn {
                self.batch = std::mem::take(&mut self.waiting);
                self.background_turn = true;
                continue;
            }
            self.background_turn = false;
            while let Some(id) = self.order.pop_front() {
                self.listed.remove(&id);
                if self.queued.contains_key(&id) {
                    return Some(id);
                }
            }
            if self.waiting.is_empty() {
                return None;
            }
        }
    }

    /// Drops session `id`'s queued lines and its places in the write order (`forget`).
    fn drop_queued(&mut self, id: &str) {
        self.queued.remove(id);
        self.order.retain(|o| o != id);
        self.listed.remove(id);
        self.waiting.retain(|o| o != id);
        self.batch.retain(|o| o != id);
        self.close_after.remove(id);
    }

    /// The end of `forget`, once no write of session `id` is in progress: a `settle` of it
    /// waits no more, nothing of it is written now. Lines appended while `forget` waited are
    /// dropped too: its count goes, so a line left queued would count as written before it is
    /// (and the writer would write it into the folder the caller deletes).
    fn forgotten(&mut self, id: &str) {
        self.drop_queued(id);
        self.progress.remove(id);
        self.done.remove(id);
    }

    /// A request or a read waits for session `id`'s queued lines: they go in the current batch
    /// if they are in it already, else in the next one, after every session waited for before.
    /// Nothing queued (written, or being written): nothing to order.
    fn wait_first(&mut self, id: &str) {
        if !self.queued.contains_key(id)
            || self.batch.iter().any(|b| b == id)
            || self.waiting.iter().any(|w| w == id)
        {
            return;
        }
        self.waiting.push_back(id.to_owned());
    }
}

/// The open logs, at most `open_logs`, and every log written since the last flush.
struct Files {
    root: PathBuf,
    segment_bytes: u64,
    /// The most logs held open (`super::open_logs_for`).
    open_logs: usize,
    open: HashMap<String, Segment>,
    /// Counts writes; a segment's `used` is the count at its last one.
    clock: u64,
    dirty: HashSet<PathBuf>,
}

struct Segment {
    index: u32,
    path: PathBuf,
    file: File,
    written: u64,
    used: u64,
}

struct Shared {
    /// The writer's QoS boost: the writer holds it for each write, a waiter raises it to its
    /// own QoS while it waits (`cmux_threads::OwnerBoost`).
    boost: Arc<cmux_threads::OwnerBoost>,
    state: Mutex<State>,
    work: Condvar,
    done: Condvar,
    files: Mutex<Files>,
}

pub(super) struct LogWriter {
    shared: Arc<Shared>,
    thread: Mutex<Option<OwnedThread>>,
}

impl LogWriter {
    /// Starts the writer thread under `supervisor`, holding at most `open_logs` logs open.
    pub(super) fn start(
        root: PathBuf,
        segment_bytes: u64,
        open_logs: usize,
        supervisor: &Supervisor,
    ) -> Self {
        Self::start_with_write_delay(root, segment_bytes, open_logs, supervisor, test_write_delay())
    }

    /// [`Self::start`], each write held `delay` first (a test's slow disk; [`test_write_delay`]).
    pub(super) fn start_with_write_delay(
        root: PathBuf,
        segment_bytes: u64,
        open_logs: usize,
        supervisor: &Supervisor,
        delay: Option<std::time::Duration>,
    ) -> Self {
        let shared = Arc::new(Shared {
            boost: Arc::new(cmux_threads::OwnerBoost::new()),
            state: Mutex::new(State::default()),
            work: Condvar::new(),
            done: Condvar::new(),
            files: Mutex::new(Files {
                root,
                segment_bytes,
                open_logs: open_logs.max(1),
                open: HashMap::new(),
                clock: 0,
                dirty: HashSet::new(),
            }),
        });
        let worker = shared.clone();
        // A panic in the thread leaves its queue half-written and every `flush` waiting:
        // Fatal. Continue on shutdown: the owner's drop writes what is queued and joins it.
        let thread = crate::supervised::owned_thread(
            supervisor,
            THREAD,
            cmux_threads::ThreadQos::Utility,
            Fatal,
            ShutdownBehavior::Continue,
            move || run(&worker, delay),
        )
        .map_err(|e| {
            tracing::error!("the event log writer did not start; logs are written in place: {e}")
        })
        .ok();
        Self { shared, thread: Mutex::new(thread) }
    }

    /// Queues `line` (one serialized record and its newline) for session `id`'s log; record `seq`.
    /// Refused once a write of this log failed.
    pub(super) fn append(&self, id: &str, line: Vec<u8>, seq: u64) -> Result<()> {
        if !self.running() {
            return lock(&self.shared.files).write(id, &line);
        }
        let mut state = lock(&self.shared.state);
        let progress = state
            .progress
            .entry(id.to_owned())
            .or_insert_with(|| tokio::sync::watch::channel(Progress::default()).0);
        if progress.borrow().failed {
            anyhow::bail!("the event log of {id} failed earlier; nothing after it is written");
        }
        progress.send_modify(|p| p.queued = p.queued.max(seq));
        state.queue(id, &line, seq);
        self.shared.work.notify_one();
        Ok(())
    }

    /// Writes session `id`'s queued lines in the next batch of waited-for sessions, ahead of
    /// background streaming (a request waits for them; `hub/request_writes.rs`), after every
    /// session a request waited for before it.
    pub(super) fn expedite(&self, id: &str) {
        lock(&self.shared.state).wait_first(id);
    }

    /// Waits until every line queued for session `id` before this call is written: before its
    /// log is read. Its queued lines go in the next batch of waited-for sessions (a reader waits
    /// for them), so the wait is at most the write in progress, the rest of the current batch, one
    /// background write and its own batch; lines it queues meanwhile never hold it.
    pub(super) fn settle(&self, id: &str) {
        let mut state = lock(&self.shared.state);
        let Some(ticket) = state.pending(id) else { return };
        state.wait_first(id);
        // The writer runs at this reader's QoS while it waits.
        let _raise = self.shared.boost.wait();
        while !state.written(id, ticket) {
            state = self.shared.done.wait(state).unwrap_or_else(|e| e.into_inner());
        }
    }

    /// What of session `id`'s log is on disk, as it changes.
    pub(super) fn progress(&self, id: &str) -> tokio::sync::watch::Receiver<Progress> {
        let mut state = lock(&self.shared.state);
        state
            .progress
            .entry(id.to_owned())
            .or_insert_with(|| tokio::sync::watch::channel(Progress::default()).0)
            .subscribe()
    }

    /// Closes session `id`'s log once its queued lines are written (a closed session's log is
    /// not held open). It stays on the dirty list: `flush` syncs it.
    pub(super) fn close_log(&self, id: &str) {
        let mut state = lock(&self.shared.state);
        if state.queued.contains_key(id) || state.writing.as_deref() == Some(id) {
            state.close_after.insert(id.to_owned());
            return;
        }
        drop(state);
        lock(&self.shared.files).open.remove(id);
    }

    /// Forgets session `id` before its folder is deleted: its queued lines are dropped, a write
    /// of it in progress is waited for, its log is closed.
    pub(super) fn forget(&self, id: &str) {
        let mut state = lock(&self.shared.state);
        state.drop_queued(id);
        while state.writing.as_deref() == Some(id) {
            state = self.shared.done.wait(state).unwrap_or_else(|e| e.into_inner());
        }
        state.forgotten(id);
        self.shared.done.notify_all();
        drop(state);
        let mut files = lock(&self.shared.files);
        if let Some(segment) = files.open.remove(id) {
            files.dirty.remove(&segment.path);
        }
        let dir = files.root.join(id);
        files.dirty.retain(|p| !p.starts_with(&dir));
    }

    /// Writes everything queued before this call, then syncs every log written since the last
    /// flush. Lines queued after it began never hold it (chats that keep streaming during a
    /// shutdown whose agents did not stop in time).
    pub(super) fn flush(&self) -> Result<()> {
        let mut state = lock(&self.shared.state);
        let mut pending: Vec<(String, u64)> = state
            .queued
            .iter()
            .map(|(id, q)| (id.clone(), q.ticket))
            .chain(state.writing.clone().map(|id| (id, state.writing_ticket)))
            .collect();
        loop {
            pending.retain(|(id, ticket)| !state.written(id, *ticket));
            if pending.is_empty() {
                break;
            }
            state = self.shared.done.wait(state).unwrap_or_else(|e| e.into_inner());
        }
        drop(state);
        lock(&self.shared.files).sync_dirty()
    }

    fn running(&self) -> bool {
        lock(&self.thread).is_some()
    }

    /// The writer's QoS boost: a request that waits for a write holds a
    /// [`cmux_threads::OwnerBoost::wait`] on it for as long as it waits (`hub/request_writes.rs`).
    pub(super) fn boost(&self) -> Arc<cmux_threads::OwnerBoost> {
        self.shared.boost.clone()
    }

    /// The QoS overrides the writer thread got from the requests that waited on it.
    #[cfg(test)]
    fn boost_counts(&self) -> cmux_threads::BoostCounts {
        self.shared.boost.counts()
    }
}

impl Drop for LogWriter {
    /// Writes what is queued, then ends the thread.
    fn drop(&mut self) {
        lock(&self.shared.state).stop = true;
        self.shared.work.notify_one();
        if let Some(thread) = lock(&self.thread).take() {
            thread.join();
        }
    }
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// The writer thread's name, also its name in a hang record.
const THREAD: &str = "acpmux-log-writer";

/// Debug builds only: `ACPMUX_TEST_LOG_WRITE_DELAY_MS` holds each write that long, so a test can
/// stop the daemon while a record is queued and not yet written (at most 2 s). Release builds
/// have no seam.
fn test_write_delay() -> Option<std::time::Duration> {
    #[cfg(debug_assertions)]
    {
        std::env::var("ACPMUX_TEST_LOG_WRITE_DELAY_MS")
            .ok()
            .and_then(|ms| ms.parse::<u64>().ok())
            // Capped as the other test seams are: a stray value never stalls the writer long.
            .map(|ms| std::time::Duration::from_millis(ms.min(2_000)))
    }
    #[cfg(not(debug_assertions))]
    None
}

fn run(shared: &Shared, delay: Option<std::time::Duration>) {
    let watched = SyncThread::register(THREAD, WRITE_ITEM);
    let mut state = lock(&shared.state);
    loop {
        let Some(id) = state.next() else {
            if state.stop {
                return;
            }
            state = shared.work.wait(state).unwrap_or_else(|e| e.into_inner());
            continue;
        };
        let Some(q) = state.queued.remove(&id) else { continue };
        state.writing = Some(id.clone());
        state.writing_ticket = q.ticket;
        drop(state);
        let result = {
            // Held for this write: it runs at the QoS of the highest waiter, if any.
            let _hold = cmux_threads::OwnerBoost::hold(&*shared.boost);
            if let Some(delay) = delay {
                cmux_threads::checked::sync::sleep(delay);
            }
            let _item = watched.item();
            lock(&shared.files).write(&id, &q.lines)
        };
        state = lock(&shared.state);
        state.writing = None;
        // A failed write drops what the session still has queued (below): all of it is done.
        let done = if result.is_ok() { q.ticket } else { state.tickets };
        if let Some(d) = state.done.get_mut(&id) {
            *d = (*d).max(done);
        }
        if let Some(progress) = state.progress.get(&id) {
            match &result {
                Ok(()) => progress.send_modify(|p| p.written = p.written.max(q.last)),
                Err(e) => {
                    tracing::warn!(session = %id, "event log write failed: {e:#}");
                    progress.send_modify(|p| p.failed = true);
                }
            }
        }
        if result.is_err() {
            // Nothing after a failed write is written: the log never has a hole.
            state.queued.remove(&id);
            state.order.retain(|o| *o != id);
            state.listed.remove(&id);
        }
        if !state.queued.contains_key(&id) && state.close_after.remove(&id) {
            lock(&shared.files).open.remove(&id);
        }
        shared.done.notify_all();
    }
}

impl Files {
    /// Appends `bytes` to session `id`'s newest segment, opening it (and closing the least
    /// recently written log past `open_logs`) or starting the next segment when it is full.
    fn write(&mut self, id: &str, bytes: &[u8]) -> Result<()> {
        if !self.open.contains_key(id)
            && self.open.len() >= self.open_logs
            && let Some(oldest) =
                self.open.iter().min_by_key(|(_, w)| w.used).map(|(k, _)| k.clone())
        {
            // Closed without a sync: it stays dirty, and `flush` syncs it.
            self.open.remove(&oldest);
        }
        if !self.open.contains_key(id) {
            let segment = self.open_segment(id)?;
            self.open.insert(id.to_owned(), segment);
        }
        self.clock += 1;
        let clock = self.clock;
        if self.open.get(id).is_some_and(|w| w.written >= self.segment_bytes)
            && let Some(old) = self.open.remove(id)
        {
            let index = old.index + 1;
            let path = self.root.join(id).join("events").join(format!("{index:06}.ndjson"));
            let file = open_private_append(&path)?;
            self.open.insert(id.to_owned(), Segment { index, path, file, written: 0, used: clock });
        }
        let Some(w) = self.open.get_mut(id) else {
            anyhow::bail!("no segment writer for session {id}");
        };
        w.used = clock;
        w.file.write_all(bytes)?;
        w.written += bytes.len() as u64;
        self.dirty.insert(w.path.clone());
        Ok(())
    }

    fn open_segment(&self, id: &str) -> Result<Segment> {
        let dir = self.root.join(id).join("events");
        crate::config::private_state_dir(&self.root.join(id))?;
        crate::config::private_state_dir(&dir)?;
        let (index, path) =
            super::segments_in(&dir)?.pop().unwrap_or_else(|| (1, dir.join("000001.ndjson")));
        let file = open_private_append(&path)?;
        let written = file.metadata().map(|m| m.len()).unwrap_or(0);
        Ok(Segment { index, path, file, written, used: 0 })
    }

    /// Syncs every log written since the last flush: an open one through its descriptor, a
    /// closed one opened again for the sync.
    fn sync_dirty(&mut self) -> Result<()> {
        let open: HashMap<&Path, &File> =
            self.open.values().map(|w| (w.path.as_path(), &w.file)).collect();
        let mut first_error = None;
        for path in &self.dirty {
            let result = match open.get(path.as_path()) {
                Some(file) => file.sync_data(),
                None => File::open(path).and_then(|f| f.sync_data()),
            };
            if let Err(e) = result
                && e.kind() != std::io::ErrorKind::NotFound
            {
                first_error.get_or_insert_with(|| {
                    anyhow::Error::from(e).context(format!("sync {}", path.display()))
                });
            }
        }
        drop(open);
        self.dirty.clear();
        match first_error {
            Some(e) => Err(e),
            None => Ok(()),
        }
    }
}

#[cfg(test)]
#[path = "write_order_tests.rs"]
mod write_order_tests;

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn root(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "acpmux-logw-{name}-{}-{}",
            std::process::id(),
            uuid::Uuid::now_v7()
        ));
        crate::config::private_state_dir(&dir).unwrap();
        dir
    }

    fn line(seq: u64) -> Vec<u8> {
        format!("{{\"seq\":{seq},\"at\":0,\"dir\":\"in\",\"kind\":\"k\",\"msg\":null}}\n")
            .into_bytes()
    }

    fn log_text(root: &Path, id: &str) -> String {
        let dir = root.join(id).join("events");
        super::super::segments_in(&dir)
            .unwrap()
            .into_iter()
            .map(|(_, p)| std::fs::read_to_string(p).unwrap())
            .collect()
    }

    #[test]
    fn appends_to_more_logs_than_stay_open_are_all_written_in_order() {
        let dir = root("many");
        let writer = LogWriter::start(
            dir.clone(),
            1 << 20,
            super::super::OPEN_LOGS,
            &crate::supervised::embedded(),
        );
        let sessions = super::super::OPEN_LOGS + 16;
        for seq in 1..=5 {
            for s in 0..sessions {
                writer.append(&format!("s{s}"), line(seq), seq).unwrap();
            }
        }
        for s in 0..sessions {
            let id = format!("s{s}");
            writer.settle(&id);
            let want: String = (1..=5).map(|seq| String::from_utf8(line(seq)).unwrap()).collect();
            assert_eq!(log_text(&dir, &id), want, "{id}");
            assert!(writer.progress(&id).borrow().covers(5));
        }
        assert!(lock(&writer.shared.files).open.len() <= super::super::OPEN_LOGS);
        writer.flush().unwrap();
        assert!(lock(&writer.shared.files).dirty.is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn progress_covers_a_record_only_once_it_is_written() {
        let dir = root("progress");
        let writer = LogWriter::start(
            dir.clone(),
            1 << 20,
            super::super::OPEN_LOGS,
            &crate::supervised::embedded(),
        );
        let rx = writer.progress("s");
        assert!(rx.borrow().covers(0), "nothing appended: nothing pending");
        // Hold the files so the thread cannot write yet.
        let files = lock(&writer.shared.files);
        writer.append("s", line(1), 1).unwrap();
        writer.append("s", line(2), 2).unwrap();
        std::thread::sleep(Duration::from_millis(20));
        assert!(!rx.borrow().covers(2), "{:?}", *rx.borrow());
        drop(files);
        writer.settle("s");
        assert!(rx.borrow().covers(2), "{:?}", *rx.borrow());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_forgotten_session_writes_nothing_more() {
        let dir = root("forget");
        let writer = LogWriter::start(
            dir.clone(),
            1 << 20,
            super::super::OPEN_LOGS,
            &crate::supervised::embedded(),
        );
        writer.append("s", line(1), 1).unwrap();
        writer.settle("s");
        let files = lock(&writer.shared.files);
        writer.append("s", line(2), 2).unwrap();
        drop(files);
        writer.forget("s");
        std::fs::remove_dir_all(dir.join("s")).unwrap();
        writer.flush().unwrap();
        assert!(!dir.join("s").exists(), "a write after the forget brought the log back");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 100 chats that stream at once keep their logs open under the daemon's raised limit: no
    /// record closes another chat's log to open its own.
    #[test]
    fn a_hundred_chats_written_in_turn_keep_their_logs_open() {
        let dir = root("hundred");
        let writer = LogWriter::start(
            dir.clone(),
            64 * 1024,
            super::super::open_logs_for(10_240),
            &crate::supervised::embedded(),
        );
        for seq in 1..=3 {
            for chat in 0..100 {
                writer.append(&format!("chat-{chat:03}"), line(seq), seq).unwrap();
            }
        }
        for chat in 0..100 {
            writer.settle(&format!("chat-{chat:03}"));
        }
        assert_eq!(lock(&writer.shared.files).open.len(), 100);
        let want: String = (1..=3).map(|seq| String::from_utf8(line(seq)).unwrap()).collect();
        assert_eq!(log_text(&dir, "chat-042"), want);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
