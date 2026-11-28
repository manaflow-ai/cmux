//! `<home>/ledger/turns.jsonl`: the fold at start, the appends at the event, and the writer
//! thread's rewrites (compaction and the first start's seed).
//!
//! A line reaches the file as it is emitted: [`Disk::append`] writes it on the caller, under the
//! ledger's state lock, so a kill of the daemon right after loses nothing (the page cache keeps
//! it; appends are not synced). That is one write per line, whatever the size of the file, the
//! number of sessions or the length of their logs. The writer thread only rewrites the file, and
//! orders each rewrite against the appends:
//!
//! - Under the lock it takes the state's snapshot and starts [`Disk::tail`]. Outside it, it
//!   writes and syncs the snapshot to a temporary file. Under the lock again it writes the tail
//!   (every line appended since the snapshot) after it and renames it over the file. A line
//!   appended meanwhile went to the old file and to the tail: the old file holds it until the
//!   rename, the new one after it, and no append reaches the old file once it is replaced (the
//!   next one opens the new file).
//! - Until the first start's seed is in the file ([`Disk::holding`]) nothing is appended: a line
//!   held then is in the state, which the seed's snapshot carries, or in the seed's tail.
//! - The appends after a rewrite go to a handle the writer thread opened before its rename (on
//!   the temporary file the rename makes the ledger), so a caller opens the file only for the
//!   first append of the process, or when that open failed.
//! - A purge's tombstone is followed by a compaction, after a close too. A start that folds a
//!   tombstone compacts at once: a kill between the two left the purged lines in the file.

use std::fs::File;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, Sender};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use super::{Line, State, Work};

pub(crate) const FILE: &str = "turns.jsonl";

/// Folds `path` into `state`; returns its size, and whether it holds a purge's tombstone (no
/// compaction followed it, which drops tombstones: the start's step compacts). A complete line
/// that does not parse is skipped. A last line with no newline (a write torn by a crash) is cut
/// off the file, so the next append starts a line of its own instead of joining the fragment.
/// The file counts as existing (`State::existed`, no seed) only once a line of it parsed: an
/// empty file, or one holding only a torn or unreadable first write, is seeded again rather than
/// taken for a ledger.
pub(crate) fn fold(path: &Path, state: &mut State) -> (u64, bool) {
    let Ok(file) = File::open(path) else { return (0, false) };
    let mut reader = BufReader::new(file);
    let mut buf = Vec::new();
    let mut whole: u64 = 0;
    let mut purged = false;
    loop {
        buf.clear();
        match reader.read_until(b'\n', &mut buf) {
            Ok(0) => break,
            Ok(_) if buf.last() != Some(&b'\n') => break,
            Ok(n) => whole += n as u64,
            Err(e) => {
                tracing::warn!("ledger: read {}: {e}", path.display());
                break;
            }
        }
        let Ok(text) = std::str::from_utf8(&buf) else { continue };
        if text.trim().is_empty() {
            continue;
        }
        match serde_json::from_str::<Line>(text) {
            Ok(line) => {
                state.existed = true;
                purged |= matches!(line, Line::Purge { .. });
                apply(state, line);
            }
            Err(e) => tracing::debug!("ledger: skipped a line: {e}"),
        }
    }
    let size = std::fs::metadata(path).map(|m| m.len()).unwrap_or(whole);
    if size > whole {
        let cut = crate::home_fs::OpenOptions::new()
            .write(true)
            .open(path)
            .and_then(|f| f.set_len(whole));
        match cut {
            Ok(()) => tracing::warn!("ledger: cut a torn last line off {}", path.display()),
            Err(e) => tracing::warn!("ledger: cannot cut a torn line off {}: {e}", path.display()),
        }
    }
    (whole, purged)
}

fn apply(state: &mut State, line: Line) {
    match line {
        Line::Spend { sid, at, model, pv, mut totals, saved } => {
            // A line from before acpmux counted cache savings has none: its cache reads at
            // today's table, so a ledger kept across the upgrade does not read as $0 saved. A
            // line that recorded a saving keeps it, a recorded zero included.
            totals.cache_saved_usd = match saved {
                Some(usd) => usd,
                None if totals.cache_read_tokens > 0 => {
                    let usage = crate::store::TurnUsage {
                        cache_read_tokens: Some(totals.cache_read_tokens),
                        ..Default::default()
                    };
                    crate::pricing::table().cache_savings(&model, &usage).unwrap_or(0.0)
                }
                None => 0.0,
            };
            state.add_bucket(&sid, &model, &pv, at, &totals)
        }
        Line::Session { sid, info } => {
            state.merge_session(&sid, info);
        }
        Line::Purge { sid } => state.remove_session(&sid),
    }
}

/// Every session and bucket in `state`, one line each: the compacted file.
fn snapshot(state: &State) -> Vec<Line> {
    let mut lines: Vec<Line> = state
        .sessions
        .iter()
        .map(|(sid, info)| Line::Session { sid: sid.to_string(), info: info.clone() })
        .collect();
    lines.sort_by(|a, b| match (a, b) {
        (Line::Session { sid: a, .. }, Line::Session { sid: b, .. }) => a.cmp(b),
        _ => std::cmp::Ordering::Equal,
    });
    for buckets in state.days.values() {
        let mut day: Vec<_> = buckets.iter().collect();
        day.sort_by(|a, b| a.0.cmp(b.0));
        for (key, bucket) in day {
            lines.push(Line::Spend {
                sid: key.session.to_string(),
                at: bucket.last_at,
                model: key.model.to_string(),
                pv: key.price_version.to_string(),
                totals: bucket.totals.clone(),
                saved: None,
            });
        }
    }
    lines
}

fn encode(line: &Line) -> Option<String> {
    serde_json::to_string(line).ok().map(|mut s| {
        s.push('\n');
        s
    })
}

/// The ledger file as the callers append to it, kept in the state under its lock
/// (`State::disk`).
pub(crate) struct Disk {
    dir: PathBuf,
    path: PathBuf,
    /// Open for append; `None` until the first append after the start, or after a rewrite whose
    /// reopen failed.
    file: Option<File>,
    size: u64,
    compact_bytes: u64,
    /// The next compaction waits for the file to double past the last one's snapshot.
    floor: u64,
    /// A first start that the hub will seed: nothing reaches the file before the seed's rewrite.
    /// A line appended before it (a watcher's turn while the store loads) would read as a ledger,
    /// and a crash before the rewrite landed would skip the seed for good.
    awaiting_seed: bool,
    /// The seed's rewrite is under way, or failed: nothing is appended (a line in the file would
    /// read as a ledger and skip the seed for good) and every step tries the rewrite again. A
    /// restart before one lands finds no ledger and seeds again.
    seed_pending: bool,
    /// A purge was written, or the start folded one: the writer's next step compacts at once,
    /// after a close too, so the purged session's lines leave the file now, not at the next size
    /// bound.
    purge_due: bool,
    /// While a rewrite runs: every line appended since its snapshot, for the end of its file.
    tail: Option<String>,
    /// A [`Work::Step`] is queued and not taken yet: one is enough.
    asked: bool,
    /// Set by `Ledger::close`: nothing is appended after it.
    closed: Arc<AtomicBool>,
}

impl Disk {
    /// The file at `path` (`size` bytes now), appended to from the start unless `awaiting_seed`.
    /// `purge_due`: the file holds a purge's tombstone ([`fold`]), so the first step compacts.
    pub(crate) fn new(
        dir: PathBuf,
        path: PathBuf,
        size: u64,
        compact_bytes: u64,
        awaiting_seed: bool,
        purge_due: bool,
        closed: Arc<AtomicBool>,
    ) -> Self {
        Self {
            dir,
            path,
            file: None,
            size,
            compact_bytes,
            floor: 0,
            awaiting_seed,
            seed_pending: false,
            purge_due,
            tail: None,
            asked: false,
            closed,
        }
    }

    /// True while the first start's seed is not in the file yet: appends wait for it.
    fn holding(&self) -> bool {
        self.awaiting_seed || self.seed_pending
    }

    fn over_bound(&self) -> bool {
        self.size > self.compact_bytes.max(self.floor.saturating_mul(2))
    }

    /// Writes `line` to the file now (or, while [`Disk::holding`], leaves it to the seed's
    /// rewrite), and to the tail of a rewrite under way. True when the writer has a step to take
    /// (a compaction due, a purge, a seed to try again) and none is queued yet: the caller queues
    /// one. Constant cost: one encode and one write.
    pub(crate) fn append(&mut self, line: &Line) -> bool {
        if self.closed.load(Ordering::SeqCst) {
            // After the close: kept in memory only.
            return false;
        }
        let Some(text) = encode(line) else { return false };
        self.purge_due |= matches!(line, Line::Purge { .. });
        if let Some(tail) = self.tail.as_mut() {
            tail.push_str(&text);
        }
        if !self.holding() {
            self.write(&text);
        }
        let due = !self.awaiting_seed && (self.seed_pending || self.purge_due || self.over_bound());
        if due && !self.asked {
            self.asked = true;
            return true;
        }
        false
    }

    fn file(&mut self) -> Option<&mut File> {
        if self.file.is_none() {
            // Owner-only whatever the umask, and never under a home that was moved or replaced
            // (`config::refuse_lost_home`): a shutdown's last append makes no folder again.
            if let Err(e) = crate::config::private_state_dir(&self.dir) {
                tracing::warn!("ledger: cannot create {}: {e:#}", self.dir.display());
                return None;
            }
            match crate::config::private_state_append(&self.path) {
                Ok(f) => self.file = Some(f),
                Err(e) => {
                    tracing::warn!("ledger: cannot open {}: {e:#}", self.path.display());
                    return None;
                }
            }
        }
        self.file.as_mut()
    }

    fn write(&mut self, text: &str) {
        let Some(file) = self.file() else { return };
        match file.write_all(text.as_bytes()) {
            Ok(()) => self.size += text.len() as u64,
            Err(e) => tracing::warn!("ledger: write failed: {e}"),
        }
    }
}

/// The writer thread: the file's rewrites and the repository lookups, never an append of its
/// callers'.
struct Writer {
    dir: PathBuf,
    path: PathBuf,
    state: Arc<Mutex<State>>,
    /// Set by `Ledger::close`: what is queued after it is skipped, but a seed.
    closed: Arc<AtomicBool>,
    /// The next rewrite stops between its snapshot's write and its rename (tests).
    #[cfg(test)]
    pause: Option<(std::sync::mpsc::SyncSender<()>, Receiver<()>)>,
}

impl Writer {
    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Rewrites the file as the state's buckets and sessions, through a temporary file and a
    /// rename: a crash leaves the old file or the new one, never part of either. Lines appended
    /// while it runs are in both (the module's doc). True when it did.
    fn rewrite(&mut self) -> bool {
        let lines = {
            let mut state = self.lock();
            let lines = snapshot(&state);
            let Some(disk) = state.disk.as_mut() else { return false };
            disk.tail = Some(String::new());
            lines
        };
        let tmp = self.dir.join(format!("{FILE}.tmp"));
        let text: String = lines.iter().filter_map(encode).collect();
        // The first seed's rewrite may be the first write of all: the folder may not exist yet.
        // Folder and file are owner-only and refused under a lost home, as in `Disk::file`.
        let written = crate::config::private_state_dir(&self.dir)
            .and_then(|()| crate::config::private_state_rw(&tmp))
            .and_then(|mut file| {
                file.set_len(0)?;
                file.write_all(text.as_bytes())?;
                file.sync_all()?;
                Ok(file)
            });
        // The handle for the appends after the rename, opened here outside the lock so no caller
        // pays the folder's checks and an open after a rewrite. It is the temporary file's, which
        // the rename makes the ledger. If it fails, the next append opens the file itself.
        let reopened = match &written {
            Ok(_) => match crate::config::private_state_append(&tmp) {
                Ok(file) => Some(file),
                Err(e) => {
                    tracing::warn!("ledger: cannot reopen {}: {e:#}", tmp.display());
                    None
                }
            },
            Err(_) => None,
        };
        #[cfg(test)]
        if let Some((reached, resume)) = self.pause.take() {
            let _ = reached.send(());
            let _ = resume.recv();
        }
        // The tail and the rename under the lock: no append lands between them, and none goes to
        // the old file after it. The tail is a few lines (those of one rewrite's time), not synced,
        // like any append.
        let mut state = self.lock();
        let Some(disk) = state.disk.as_mut() else { return false };
        let tail = disk.tail.take().unwrap_or_default();
        let landed = written.and_then(|mut file| {
            file.write_all(tail.as_bytes())?;
            drop(file);
            crate::home_fs::rename(&tmp, &self.path)?;
            Ok(())
        });
        match landed {
            Ok(()) => {
                disk.file = reopened;
                disk.size = (text.len() + tail.len()) as u64;
                // The snapshot's size, not the tail's too: a burst appended during the rewrite
                // (any number of lines) would raise the floor with it, and the next compaction
                // would wait for twice that. An append that landed in the tail queued a step,
                // which compacts again when the tail took the file past the bound.
                disk.floor = text.len() as u64;
                // The whole state is in the file: a first start's hold is over.
                disk.seed_pending = false;
                true
            }
            Err(e) => {
                let _ = crate::home_fs::remove_file(&tmp);
                tracing::warn!("ledger: compaction failed: {e:#}");
                // Try again only after as much again has been appended.
                disk.floor = disk.size;
                false
            }
        }
    }

    /// The first start's seed ([`super::Ledger::seed`]): written as one rewrite, so a crash
    /// while seeding leaves no ledger file and the next start seeds again. A rewrite that fails
    /// is tried again at every step ([`Disk::seed_pending`]), never replaced by appends.
    fn seed(&mut self) {
        {
            let mut state = self.lock();
            let Some(disk) = state.disk.as_mut() else { return };
            disk.awaiting_seed = false;
            disk.seed_pending = true;
        }
        self.rewrite();
    }

    /// One step: a pending seed's rewrite again, else a compaction when a purge or the size
    /// bound calls for one. Once the ledger is closed only a purge's compaction: the purged
    /// session's lines must not stay in the file until a later start.
    fn step(&mut self) {
        let closed = self.closed.load(Ordering::SeqCst);
        let due = {
            let mut state = self.lock();
            let Some(disk) = state.disk.as_mut() else { return };
            disk.asked = false;
            let purge = std::mem::take(&mut disk.purge_due);
            !disk.awaiting_seed && (purge || (!closed && (disk.seed_pending || disk.over_bound())))
        };
        if due {
            self.rewrite();
        }
    }

    fn repo(&mut self, sid: String, cwd: &Path) {
        let Some(repo) = crate::git_state::origin_repo(cwd) else { return };
        let mut state = self.lock();
        // Purged while the lookup waited: nothing comes back for it.
        if !state.sessions.contains_key(sid.as_str()) {
            return;
        }
        let info = super::SessionInfo { repo: Some(repo), ..Default::default() };
        if !state.merge_session(&sid, info) {
            return;
        }
        let info = super::SessionInfo {
            repo: state.sessions.get(sid.as_str()).and_then(|i| i.repo.clone()),
            ..Default::default()
        };
        // Appended here like any caller's line; the step after it takes what it makes due.
        let _ = state.emit(&Line::Session { sid, info });
    }

    fn run(mut self, rx: Receiver<Work>) {
        self.step();
        while let Ok(work) = rx.recv() {
            // After the close every line is in the file already. A queued step still runs, but
            // compacts only for a purge (`Writer::step`). A queued repository lookup is skipped:
            // a stop must not wait on git, and the next start asks again for every session with
            // no repository, so one is lost only when its folder is gone by then, which costs
            // that session's repository, never its spend. A queued seed is still written: it is
            // the first start's whole ledger.
            let closed = self.closed.load(Ordering::SeqCst);
            match work {
                Work::Step => self.step(),
                Work::Repo { sid, cwd } if !closed => {
                    self.repo(sid, &cwd);
                    self.step();
                }
                Work::Seed => self.seed(),
                #[cfg(test)]
                Work::Flush(done) => {
                    self.step();
                    let _ = done.send(());
                }
                #[cfg(test)]
                Work::Pause { reached, resume } => self.pause = Some((reached, resume)),
                _ => {}
            }
        }
        // Closed: a purge whose step was never queued (its caller lost the race with the close)
        // still gets its compaction.
        if self.closed.load(Ordering::SeqCst) {
            self.step();
        }
    }
}

/// The writer thread and the channel that closes when it ends.
pub(crate) struct WriterThread {
    handle: std::thread::JoinHandle<()>,
    ended: Receiver<()>,
}

impl WriterThread {
    /// Waits up to `within` for the thread to end (its queue closed first). A writer still
    /// running then comes back, for a later [`WriterThread::join`].
    pub(crate) fn join_within(self, within: std::time::Duration) -> Result<(), Self> {
        match self.ended.recv_timeout(within) {
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                let _ = self.handle.join();
                Ok(())
            }
            _ => {
                tracing::warn!("ledger: the writer did not finish within {within:?}");
                Err(self)
            }
        }
    }

    /// Waits for the thread to end, however long it takes (its queue closed first).
    pub(crate) fn join(self) {
        let _ = self.handle.join();
    }
}

/// Starts the writer thread for the file in `dir` (the state's [`Disk`]); it ends when its queue
/// closes.
pub(crate) fn spawn_writer(
    dir: PathBuf,
    path: PathBuf,
    state: Arc<Mutex<State>>,
    closed: Arc<AtomicBool>,
) -> Option<(Sender<Work>, WriterThread)> {
    let (tx, rx) = std::sync::mpsc::channel();
    let (end_tx, ended) = std::sync::mpsc::sync_channel::<()>(0);
    let writer = Writer {
        dir,
        path,
        state,
        closed,
        #[cfg(test)]
        pause: None,
    };
    let spawned = std::thread::Builder::new().name("acpmux-ledger".into()).spawn(move || {
        let _end = end_tx;
        writer.run(rx);
    });
    match spawned {
        Ok(handle) => Some((tx, WriterThread { handle, ended })),
        Err(e) => {
            tracing::warn!("ledger: no writer thread: {e}");
            None
        }
    }
}
