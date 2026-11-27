//! `<home>/asks/asks.jsonl`: the fold at start and the writer thread.

use std::fs::File;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{Receiver, Sender};

use super::{Line, State};

pub(crate) const FILE: &str = "asks.jsonl";

/// What the writer thread is handed.
pub(crate) enum Work {
    Line(Box<Line>),
    /// Rewrite the whole file as these lines (after a purge).
    Rewrite(Vec<Line>),
    #[cfg(test)]
    Flush(std::sync::mpsc::SyncSender<()>),
}

/// Folds `path` into `state`. A line that does not parse is skipped; a last line with no
/// newline (a write torn by a crash) is cut off, so the next append starts a line of its own.
pub(crate) fn fold(path: &Path, state: &mut State) {
    let Ok(file) = File::open(path) else { return };
    let mut reader = BufReader::new(file);
    let mut buf = Vec::new();
    let mut whole: u64 = 0;
    loop {
        buf.clear();
        match reader.read_until(b'\n', &mut buf) {
            Ok(0) => break,
            Ok(_) if buf.last() != Some(&b'\n') => break,
            Ok(n) => whole = whole.saturating_add(n as u64),
            Err(e) => {
                tracing::warn!("asks: read {}: {e}", path.display());
                break;
            }
        }
        let Ok(text) = std::str::from_utf8(&buf) else { continue };
        if text.trim().is_empty() {
            continue;
        }
        match serde_json::from_str::<Line>(text) {
            Ok(Line::Ask(ask)) => {
                state.add_ask(ask);
            }
            Ok(Line::Pr(pr)) => {
                state.put_pr(pr);
            }
            Ok(Line::Event(event)) => {
                state.add_event(event);
            }
            Ok(Line::Purge { sid }) => state.remove_session(&sid),
            Err(e) => tracing::debug!("asks: skipped a line: {e}"),
        }
    }
    let size = std::fs::metadata(path).map(|m| m.len()).unwrap_or(whole);
    if size > whole {
        let cut = crate::home_fs::OpenOptions::new()
            .write(true)
            .open(path)
            .and_then(|f| f.set_len(whole));
        if let Err(e) = cut {
            tracing::warn!("asks: cannot cut a torn line off {}: {e}", path.display());
        }
    }
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
}

impl Writer {
    fn file(&mut self) -> Option<&mut File> {
        if self.file.is_none() {
            // Owner-only whatever the umask, and never under a home that was moved or replaced.
            if let Err(e) = crate::config::private_state_dir(&self.dir) {
                tracing::warn!("asks: cannot create {}: {e:#}", self.dir.display());
                return None;
            }
            match crate::config::private_state_append(&self.path) {
                Ok(f) => self.file = Some(f),
                Err(e) => {
                    tracing::warn!("asks: cannot open {}: {e:#}", self.path.display());
                    return None;
                }
            }
        }
        self.file.as_mut()
    }

    fn write(&mut self, text: &str) {
        if text.is_empty() {
            return;
        }
        let Some(file) = self.file() else { return };
        if let Err(e) = file.write_all(text.as_bytes()) {
            tracing::warn!("asks: write failed: {e}");
        }
    }

    /// Replaces the file with `lines` through a temporary file and a rename: a crash leaves the
    /// old file or the new one, never part of either.
    fn rewrite(&mut self, lines: &[Line]) {
        let tmp = self.dir.join(format!("{FILE}.tmp"));
        let text: String = lines.iter().filter_map(encode).collect();
        let written = crate::config::private_state_dir(&self.dir)
            .and_then(|()| crate::config::private_state_rw(&tmp))
            .and_then(|mut file| {
                file.set_len(0)?;
                file.write_all(text.as_bytes())?;
                file.sync_all()?;
                Ok(())
            })
            .and_then(|()| crate::home_fs::rename(&tmp, &self.path).map_err(anyhow::Error::from));
        match written {
            Ok(()) => self.file = None,
            Err(e) => {
                let _ = crate::home_fs::remove_file(&tmp);
                tracing::warn!("asks: rewrite failed: {e:#}");
            }
        }
    }

    fn run(mut self, rx: Receiver<Work>) {
        while let Ok(first) = rx.recv() {
            let mut text = String::new();
            let mut work = Some(first);
            while let Some(w) = work.take().or_else(|| rx.try_recv().ok()) {
                match w {
                    Work::Line(line) => {
                        if let Some(s) = encode(&line) {
                            text.push_str(&s);
                        }
                    }
                    Work::Rewrite(lines) => {
                        // The snapshot holds every line queued before it.
                        text.clear();
                        self.rewrite(&lines);
                    }
                    #[cfg(test)]
                    Work::Flush(done) => {
                        self.write(&std::mem::take(&mut text));
                        let _ = done.send(());
                    }
                }
            }
            self.write(&text);
        }
    }
}

/// The writer thread and the channel that closes when it ends.
pub(crate) struct WriterThread {
    handle: std::thread::JoinHandle<()>,
    ended: Receiver<()>,
}

impl WriterThread {
    pub(crate) fn join_within(self, within: std::time::Duration) -> Result<(), Self> {
        match self.ended.recv_timeout(within) {
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                let _ = self.handle.join();
                Ok(())
            }
            _ => {
                tracing::warn!("asks: the writer did not finish within {within:?}");
                Err(self)
            }
        }
    }

    pub(crate) fn join(self) {
        let _ = self.handle.join();
    }
}

/// Starts the writer thread for `path`; it ends when its queue closes, after writing
/// everything queued before.
pub(crate) fn spawn_writer(dir: PathBuf, path: PathBuf) -> Option<(Sender<Work>, WriterThread)> {
    let (tx, rx) = std::sync::mpsc::channel();
    let (end_tx, ended) = std::sync::mpsc::sync_channel::<()>(0);
    let writer = Writer { dir, path, file: None };
    let spawned = std::thread::Builder::new().name("acpmux-asks".into()).spawn(move || {
        let _end = end_tx;
        writer.run(rx);
    });
    match spawned {
        Ok(handle) => Some((tx, WriterThread { handle, ended })),
        Err(e) => {
            tracing::warn!("asks: no writer thread: {e}");
            None
        }
    }
}
