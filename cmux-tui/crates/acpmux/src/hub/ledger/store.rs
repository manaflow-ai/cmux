//! `<home>/ledger/turns.jsonl`: the fold at start, the writer thread, and compaction.

use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{Receiver, Sender};
use std::sync::{Arc, Mutex, PoisonError};

use super::{Line, State, Work};

pub(crate) const FILE: &str = "turns.jsonl";

/// Folds `path` into `state`; returns its size. A line that does not parse (a torn last write)
/// is skipped.
pub(crate) fn fold(path: &Path, state: &mut State) -> u64 {
    let Ok(file) = File::open(path) else { return 0 };
    state.existed = true;
    let size = file.metadata().map(|m| m.len()).unwrap_or(0);
    for line in BufReader::new(file).lines().map_while(Result::ok) {
        if line.trim().is_empty() {
            continue;
        }
        match serde_json::from_str::<Line>(&line) {
            Ok(line) => apply(state, line),
            Err(e) => tracing::debug!("ledger: skipped a line: {e}"),
        }
    }
    size
}

fn apply(state: &mut State, line: Line) {
    match line {
        Line::Spend { sid, at, model, pv, totals } => {
            state.add_bucket(&sid, &model, &pv, at, &totals)
        }
        Line::Session { sid, info } => {
            state.merge_session(&sid, info);
        }
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
    state: Arc<Mutex<State>>,
}

impl Writer {
    fn file(&mut self) -> Option<&mut File> {
        if self.file.is_none() {
            if let Err(e) = std::fs::create_dir_all(&self.dir) {
                tracing::warn!("ledger: cannot create {}: {e}", self.dir.display());
                return None;
            }
            match OpenOptions::new().create(true).append(true).open(&self.path) {
                Ok(f) => self.file = Some(f),
                Err(e) => {
                    tracing::warn!("ledger: cannot open {}: {e}", self.path.display());
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

    fn maybe_compact(&mut self) {
        if self.size <= self.compact_bytes.max(self.floor.saturating_mul(2)) {
            return;
        }
        let (lines, seq) = {
            let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            (snapshot(&state), state.seq)
        };
        let tmp = self.dir.join(format!("{FILE}.tmp"));
        let text: String = lines.iter().filter_map(encode).collect();
        let written = std::fs::write(&tmp, text.as_bytes())
            .and_then(|()| File::open(&tmp)?.sync_all())
            .and_then(|()| std::fs::rename(&tmp, &self.path));
        match written {
            Ok(()) => {
                self.file = None;
                self.size = text.len() as u64;
                self.floor = self.size;
                self.written_upto = seq;
            }
            Err(e) => {
                let _ = std::fs::remove_file(&tmp);
                tracing::warn!("ledger: compaction failed: {e}");
                // Try again only after as much again has been appended.
                self.floor = self.size;
            }
        }
    }

    fn repo(&mut self, sid: String, cwd: &Path) {
        let Some(repo) = crate::git_state::origin_repo(cwd) else { return };
        let line = {
            let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
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
            let mut work = Some(first);
            while let Some(w) = work.take().or_else(|| rx.try_recv().ok()) {
                match w {
                    Work::Line(seq, line) => {
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
                    #[cfg(test)]
                    Work::Flush(done) => {
                        self.write(&std::mem::take(&mut text));
                        self.maybe_compact();
                        let _ = done.send(());
                    }
                }
            }
            self.write(&text);
            self.maybe_compact();
        }
    }
}

/// Starts the writer thread for `path` (`size` bytes now); it ends when the ledger is dropped.
pub(crate) fn spawn_writer(
    dir: PathBuf,
    path: PathBuf,
    size: u64,
    compact_bytes: u64,
    state: Arc<Mutex<State>>,
) -> Sender<Work> {
    let (tx, rx) = std::sync::mpsc::channel();
    let writer =
        Writer { dir, path, file: None, size, compact_bytes, floor: 0, written_upto: 0, state };
    let spawned =
        std::thread::Builder::new().name("acpmux-ledger".into()).spawn(move || writer.run(rx));
    if let Err(e) = spawned {
        tracing::warn!("ledger: no writer thread: {e}");
    }
    tx
}
