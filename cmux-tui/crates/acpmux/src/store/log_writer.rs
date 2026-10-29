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
//! log (`settle`) first waits for that session's queued lines, so readers see every append made
//! before the read. `progress` tells an agent host's reader what is on disk, so a host entry is
//! acknowledged only once its record is written (`agent_host` keeps it until then).
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

/// The lines one session has queued, and the last record among them.
#[derive(Default)]
struct Queued {
    lines: Vec<u8>,
    last: u64,
}

#[derive(Default)]
struct State {
    queued: HashMap<String, Queued>,
    /// Sessions with queued lines, in the order they first queued: each is written in turn.
    order: VecDeque<String>,
    writing: Option<String>,
    /// Sessions whose log closes once their queued lines are written (`close_log`).
    close_after: HashSet<String>,
    progress: HashMap<String, tokio::sync::watch::Sender<Progress>>,
    stop: bool,
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
        let shared = Arc::new(Shared {
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
            move || run(&worker),
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
        if !state.queued.contains_key(id) {
            state.order.push_back(id.to_owned());
        }
        let q = state.queued.entry(id.to_owned()).or_default();
        q.lines.extend_from_slice(&line);
        q.last = q.last.max(seq);
        self.shared.work.notify_one();
        Ok(())
    }

    /// Waits until every line queued for session `id` is written: before its log is read.
    pub(super) fn settle(&self, id: &str) {
        let mut state = lock(&self.shared.state);
        while state.queued.contains_key(id) || state.writing.as_deref() == Some(id) {
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
        state.queued.remove(id);
        state.order.retain(|o| o != id);
        state.close_after.remove(id);
        while state.writing.as_deref() == Some(id) {
            state = self.shared.done.wait(state).unwrap_or_else(|e| e.into_inner());
        }
        state.progress.remove(id);
        drop(state);
        let mut files = lock(&self.shared.files);
        if let Some(segment) = files.open.remove(id) {
            files.dirty.remove(&segment.path);
        }
        let dir = files.root.join(id);
        files.dirty.retain(|p| !p.starts_with(&dir));
    }

    /// Writes everything queued, then syncs every log written since the last flush.
    pub(super) fn flush(&self) -> Result<()> {
        let mut state = lock(&self.shared.state);
        while !state.queued.is_empty() || state.writing.is_some() {
            state = self.shared.done.wait(state).unwrap_or_else(|e| e.into_inner());
        }
        drop(state);
        lock(&self.shared.files).sync_dirty()
    }

    fn running(&self) -> bool {
        lock(&self.thread).is_some()
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

fn run(shared: &Shared) {
    let watched = SyncThread::register(THREAD, WRITE_ITEM);
    let mut state = lock(&shared.state);
    loop {
        let Some(id) = state.order.pop_front() else {
            if state.stop {
                return;
            }
            state = shared.work.wait(state).unwrap_or_else(|e| e.into_inner());
            continue;
        };
        let Some(q) = state.queued.remove(&id) else { continue };
        state.writing = Some(id.clone());
        drop(state);
        let result = {
            let _item = watched.item();
            lock(&shared.files).write(&id, &q.lines)
        };
        state = lock(&shared.state);
        state.writing = None;
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
