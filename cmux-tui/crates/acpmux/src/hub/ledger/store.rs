//! `<home>/ledger/turns.jsonl`: the fold at start, the writer thread, and compaction.

use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{Receiver, Sender};
use std::sync::{Arc, Mutex, PoisonError};

use super::{Line, State, Work};

pub(crate) const FILE: &str = "turns.jsonl";

/// Folds `path` into `state`; returns its size. A complete line that does not parse is skipped.
/// A last line with no newline (a write torn by a crash) is cut off the file, so the next append
/// starts a line of its own instead of joining the fragment. The file counts as existing
/// (`State::existed`, no seed) only once a line of it parsed: an empty file, or one holding only a
/// torn or unreadable first write, is seeded again rather than taken for a ledger.
pub(crate) fn fold(path: &Path, state: &mut State) -> u64 {
    let Ok(file) = File::open(path) else { return 0 };
    let mut reader = BufReader::new(file);
    let mut buf = Vec::new();
    let mut whole: u64 = 0;
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
                apply(state, line);
            }
            Err(e) => tracing::debug!("ledger: skipped a line: {e}"),
        }
    }
    let size = std::fs::metadata(path).map(|m| m.len()).unwrap_or(whole);
    if size > whole {
        let cut = OpenOptions::new().write(true).open(path).and_then(|f| f.set_len(whole));
        match cut {
            Ok(()) => tracing::warn!("ledger: cut a torn last line off {}", path.display()),
            Err(e) => tracing::warn!("ledger: cannot cut a torn line off {}: {e}", path.display()),
        }
    }
    whole
}

fn apply(state: &mut State, line: Line) {
    match line {
        Line::Spend { sid, at, model, pv, totals } => {
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

struct Writer {
    dir: PathBuf,
    path: PathBuf,
    file: Option<File>,
    size: u64,
    compact_bytes: u64,
    /// The next compaction waits for the file to double past what the last one wrote.
    floor: u64,
    /// Lines up to this seq are already in a compacted file.
    written_upto: u64,
    /// The first seed's rewrite failed: nothing is appended (a line in the file would read as a
    /// ledger and skip the seed for good) and every step tries the rewrite again. A restart
    /// before one lands finds no ledger and seeds again.
    seed_pending: bool,
    /// A first start that the hub will seed: nothing reaches the file before the seed's rewrite.
    /// A line appended before it (a watcher's turn while the store loads) would read as a ledger,
    /// and a crash before the rewrite landed would skip the seed for good.
    awaiting_seed: bool,
    state: Arc<Mutex<State>>,
}

impl Writer {
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
        if self.seed_pending || self.awaiting_seed || text.is_empty() {
            // Held in the state: the seed's rewrite carries it.
            return;
        }
        let Some(file) = self.file() else { return };
        match file.write_all(text.as_bytes()) {
            Ok(()) => self.size += text.len() as u64,
            Err(e) => tracing::warn!("ledger: write failed: {e}"),
        }
    }

    fn maybe_compact(&mut self) {
        if self.awaiting_seed || self.size <= self.compact_bytes.max(self.floor.saturating_mul(2)) {
            return;
        }
        let _ = self.compact();
    }

    /// Rewrites the file as the state's buckets and sessions, through a temporary file and a
    /// rename: a crash leaves the old file or the new one, never part of either. True when it did.
    fn compact(&mut self) -> bool {
        let (lines, seq) = {
            let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            (snapshot(&state), state.seq)
        };
        let tmp = self.dir.join(format!("{FILE}.tmp"));
        let text: String = lines.iter().filter_map(encode).collect();
        // The first seed's rewrite may be the first write of all: the folder may not exist yet.
        // Folder and file are owner-only and refused under a lost home, as in `Writer::file`.
        let written = crate::config::private_state_dir(&self.dir)
            .and_then(|()| crate::config::private_state_rw(&tmp))
            .and_then(|mut file| {
                file.set_len(0)?;
                file.write_all(text.as_bytes())?;
                file.sync_all()?;
                Ok(())
            })
            .and_then(|()| std::fs::rename(&tmp, &self.path).map_err(anyhow::Error::from));
        match written {
            Ok(()) => {
                self.file = None;
                self.size = text.len() as u64;
                self.floor = self.size;
                self.written_upto = seq;
                true
            }
            Err(e) => {
                let _ = std::fs::remove_file(&tmp);
                tracing::warn!("ledger: compaction failed: {e:#}");
                // Try again only after as much again has been appended.
                self.floor = self.size;
                false
            }
        }
    }

    /// The first start's seed ([`super::Ledger::seed`]): written as one compaction, so a crash
    /// while seeding leaves no ledger file and the next start seeds again. A rewrite that fails
    /// is tried again at every step ([`Writer::seed_pending`]), never replaced by appends.
    fn seed(&mut self) {
        self.awaiting_seed = false;
        self.seed_pending = !self.compact();
    }

    /// Ends a step: a pending seed's rewrite again, else a compaction when one is due (`now`:
    /// at once, for a purge).
    fn settle(&mut self, now: bool) {
        if self.awaiting_seed {
            // The seed's rewrite carries everything held.
        } else if self.seed_pending {
            self.seed_pending = !self.compact();
        } else if now {
            let _ = self.compact();
        } else {
            self.maybe_compact();
        }
    }

    fn repo(&mut self, sid: String, cwd: &Path) {
        let Some(repo) = crate::git_state::origin_repo(cwd) else { return };
        let line = {
            let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
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
            Line::Session { sid, info }
        };
        if let Some(text) = encode(&line) {
            self.write(&text);
        }
    }

    fn run(mut self, rx: Receiver<Work>) {
        self.maybe_compact();
        while let Ok(first) = rx.recv() {
            let mut text = String::new();
            let mut purged = false;
            let mut work = Some(first);
            while let Some(w) = work.take().or_else(|| rx.try_recv().ok()) {
                match w {
                    Work::Line(seq, line) => {
                        purged |= matches!(*line, Line::Purge { .. });
                        if seq > self.written_upto
                            && let Some(s) = encode(&line)
                        {
                            text.push_str(&s);
                        }
                    }
                    Work::Repo { sid, cwd } => {
                        self.write(&std::mem::take(&mut text));
                        self.repo(sid, &cwd);
                    }
                    Work::Seed => {
                        // Lines queued before it are in the state the seed writes: none is
                        // appended first, so the file is the whole rewrite or nothing.
                        text.clear();
                        self.seed();
                    }
                    #[cfg(test)]
                    Work::Flush(done) => {
                        self.write(&std::mem::take(&mut text));
                        self.settle(std::mem::take(&mut purged));
                        let _ = done.send(());
                    }
                }
            }
            self.write(&text);
            // A purged session's lines leave the file now, not at the next size bound.
            self.settle(purged);
        }
    }
}

/// The writer thread and the channel that closes when it ends.
pub(crate) struct WriterThread {
    handle: std::thread::JoinHandle<()>,
    ended: Receiver<()>,
}

impl WriterThread {
    /// Waits up to `within` for the thread to end (its queue closed first); true when it did.
    pub(crate) fn join_within(self, within: std::time::Duration) -> bool {
        match self.ended.recv_timeout(within) {
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                let _ = self.handle.join();
                true
            }
            _ => {
                tracing::warn!("ledger: the writer did not finish within {within:?}");
                false
            }
        }
    }
}

/// Starts the writer thread for `path` (`size` bytes now); it ends when its queue closes, after
/// writing everything queued before.
pub(crate) fn spawn_writer(
    dir: PathBuf,
    path: PathBuf,
    size: u64,
    compact_bytes: u64,
    awaiting_seed: bool,
    state: Arc<Mutex<State>>,
) -> Option<(Sender<Work>, WriterThread)> {
    let (tx, rx) = std::sync::mpsc::channel();
    let (end_tx, ended) = std::sync::mpsc::sync_channel::<()>(0);
    let writer = Writer {
        dir,
        path,
        file: None,
        size,
        compact_bytes,
        floor: 0,
        written_upto: 0,
        seed_pending: false,
        awaiting_seed,
        state,
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
