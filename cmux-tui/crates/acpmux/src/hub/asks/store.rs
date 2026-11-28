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
    /// A purge is acknowledged only after its snapshot or tombstone is durable.
    Purge {
        sid: String,
        lines: Vec<Line>,
        done: tokio::sync::oneshot::Sender<Result<(), String>>,
    },
    #[cfg(test)]
    Flush(std::sync::mpsc::SyncSender<()>),
}

/// Folds `path` into `state`. A line that does not parse is skipped; a last line with no
/// newline (a write torn by a crash) is cut off, so the next append starts a line of its own.
pub(crate) fn fold(path: &Path, state: &mut State) -> std::io::Result<()> {
    let file = match File::open(path) {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(e),
    };
    fold_reader(path, BufReader::new(file), state)
}

fn fold_reader(path: &Path, mut reader: impl BufRead, state: &mut State) -> std::io::Result<()> {
    // Publish only a complete replay: a prefix may omit a later purge or capture.
    let mut recovered = State::default();
    let mut buf = Vec::new();
    let mut whole: u64 = 0;
    loop {
        buf.clear();
        match reader.read_until(b'\n', &mut buf)? {
            0 => break,
            _ if buf.last() != Some(&b'\n') => {
                // read_until returned successfully at EOF: only this is a torn tail.
                // If cutting it fails, the caller must not append or compact this store.
                crate::home_fs::OpenOptions::new().write(true).open(path)?.set_len(whole)?;
                break;
            }
            n => whole = whole.saturating_add(n as u64),
        }
        let Ok(text) = std::str::from_utf8(&buf) else { continue };
        if text.trim().is_empty() {
            continue;
        }
        match serde_json::from_str::<Line>(text) {
            Ok(Line::Ask(ask)) => {
                recovered.add_ask(ask);
            }
            Ok(Line::Pr(pr)) => {
                recovered.put_pr(pr);
            }
            Ok(Line::Event(event)) => {
                recovered.add_event(event);
            }
            Ok(Line::Purge { sid }) => recovered.remove_session(&sid),
            Err(e) => tracing::debug!("asks: skipped a line: {e}"),
        }
    }
    *state = recovered;
    Ok(())
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
    fn file(&mut self) -> anyhow::Result<&mut File> {
        if self.file.is_none() {
            crate::config::private_state_dir(&self.dir)?;
            self.file = Some(crate::config::private_state_append(&self.path)?);
        }
        self.file.as_mut().ok_or_else(|| anyhow::anyhow!("Ask ledger append handle unavailable"))
    }

    fn write(&mut self, text: &str) -> anyhow::Result<()> {
        if !text.is_empty() {
            append(self.file()?, |file| file.write_all(text.as_bytes()))?;
        }
        Ok(())
    }

    fn purge(&mut self, sid: &str, lines: &[Line], text: &mut String) -> anyhow::Result<()> {
        if self.rewrite(lines) {
            text.clear();
            return Ok(());
        }
        // Retain all queued captures if compaction fails. A synced tombstone is enough to
        // prevent resurrection on restart; a later successful purge removes the plaintext.
        text.push_str(&serde_json::to_string(&Line::Purge { sid: sid.to_owned() })?);
        text.push('\n');
        self.write(text)?;
        self.file()?.sync_all()?;
        crate::home_fs::sync_dir(&self.dir)?;
        text.clear();
        Ok(())
    }

    /// Replaces the file with `lines` through a temporary file and a rename: a crash leaves the
    /// old file or the new one, never part of either.
    fn rewrite(&mut self, lines: &[Line]) -> bool {
        // A rename can succeed even when syncing its directory fails: never retain an
        // append handle to the replaced inode for the fallback.
        self.file = None;
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
            .and_then(|()| crate::home_fs::rename(&tmp, &self.path).map_err(anyhow::Error::from))
            .and_then(|()| crate::home_fs::sync_dir(&self.dir).map_err(anyhow::Error::from));
        match written {
            Ok(()) => {
                self.file = None;
                true
            }
            Err(e) => {
                let _ = crate::home_fs::remove_file(&tmp);
                tracing::warn!("asks: rewrite failed: {e:#}");
                false
            }
        }
    }

    fn run(mut self, rx: Receiver<Work>) {
        if let Err(e) = self.run_until_error(rx) {
            // Fail closed: no subsequent record can join a partial suffix, and all pending
            // and future purge acknowledgments fail. Restart retries full recovery.
            tracing::error!("asks: writer stopped after disk failure: {e:#}");
        }
    }

    fn run_until_error(&mut self, rx: Receiver<Work>) -> anyhow::Result<()> {
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
                    Work::Purge { sid, lines, done } => {
                        let result = self.purge(&sid, &lines, &mut text);
                        let _ = done.send(result.as_ref().map(|()| ()).map_err(|e| {
                            format!("Ask ledger purge failed; chat was not deleted: {e:#}")
                        }));
                        result?;
                    }
                    #[cfg(test)]
                    Work::Flush(done) => {
                        self.write(&text)?;
                        text.clear();
                        let _ = done.send(());
                    }
                }
            }
            self.write(&text)?;
        }
        Ok(())
    }
}

/// A failed append may have written a prefix. Restore the previous complete boundary and
/// sync the rollback before returning the error; even a successful rollback stops the writer.
/// If rollback itself fails, fail-stop leaves recovery to cut the torn tail on restart.
fn append(
    file: &mut File,
    write: impl FnOnce(&mut File) -> std::io::Result<()>,
) -> std::io::Result<()> {
    let before = file.metadata()?.len();
    if let Err(error) = write(file) {
        if let Err(rollback) = file.set_len(before).and_then(|()| file.sync_all()) {
            return Err(std::io::Error::other(format!("{error}; rollback failed: {rollback}")));
        }
        return Err(error);
    }
    Ok(())
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hub::asks::{Ask, AskKind};

    fn ask(sid: &str) -> Ask {
        Ask {
            id: format!("ask-{sid}"),
            ts: 1,
            text: format!("words of {sid}"),
            harness: "codex".into(),
            session_id: sid.into(),
            host: "test".into(),
            message_id: "p1".into(),
            kind: AskKind::Ask,
        }
    }

    #[test]
    fn a_read_error_preserves_the_unread_suffix_and_discards_partial_state() {
        use std::io::Read;

        struct ReadFailure;
        impl Read for ReadFailure {
            fn read(&mut self, _: &mut [u8]) -> std::io::Result<usize> {
                Err(std::io::Error::other("injected ledger read failure"))
            }
        }

        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(FILE);
        let first = encode(&Line::Ask(ask("first"))).unwrap();
        let second = encode(&Line::Ask(ask("unread"))).unwrap();
        let original = format!("{first}{second}");
        std::fs::write(&path, &original).unwrap();
        // Fail both at a line boundary and after read_until has buffered a partial line.
        for prefix in [first.clone(), format!("{first}{{\"Ask\":")] {
            let input = std::io::Cursor::new(prefix.into_bytes()).chain(ReadFailure);
            let mut state = State::default();
            assert!(fold_reader(&path, BufReader::new(input), &mut state).is_err());
            assert_eq!(std::fs::read_to_string(&path).unwrap(), original);
            assert!(state.asks.is_empty(), "incomplete replay must not publish partial state");
        }
    }

    #[test]
    fn failed_tail_repair_does_not_publish_recovered_state() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(FILE);
        std::fs::create_dir(&path).unwrap();
        let input = format!("{}torn", encode(&Line::Ask(ask("first"))).unwrap());
        let mut state = State::default();
        assert!(fold_reader(&path, std::io::Cursor::new(input), &mut state).is_err());
        assert!(state.asks.is_empty());
        assert!(path.is_dir());
    }

    #[test]
    fn an_unreadable_store_never_starts_a_writer() {
        let dir = tempfile::tempdir().unwrap();
        // A directory is unreadable as a ledger even under root, unlike permission bits.
        std::fs::create_dir(dir.path().join(FILE)).unwrap();
        let ledger =
            crate::hub::asks::AskLedger::open_as(Some(dir.path().to_owned()), "test".into());
        assert!(ledger.writer.lock().unwrap().is_none());
        assert!(ledger.thread.lock().unwrap().is_none());
    }

    #[test]
    fn failed_rewrite_preserves_batched_purge_and_capture_across_restart() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(FILE);
        let gone = ask("gone");
        let kept = ask("kept");
        std::fs::write(&path, encode(&Line::Ask(gone.clone())).unwrap()).unwrap();

        // A directory at the temporary filename forces the rewrite to fail even as root,
        // while the original ledger remains writable for the append fallback.
        let tmp = dir.path().join(format!("{FILE}.tmp"));
        std::fs::create_dir(&tmp).unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        tx.send(Work::Line(Box::new(Line::Ask(kept.clone())))).unwrap();
        let (done, mut acknowledgment) = tokio::sync::oneshot::channel();
        tx.send(Work::Purge { sid: "gone".into(), lines: vec![Line::Ask(kept.clone())], done })
            .unwrap();
        drop(tx);
        // Prequeue the whole batch, so the test never depends on writer scheduling.
        Writer { dir: dir.path().to_owned(), path: path.clone(), file: None }.run(rx);
        assert_eq!(acknowledgment.try_recv().unwrap(), Ok(()));

        let mut restarted = State::default();
        fold(&path, &mut restarted).unwrap();
        assert!(!restarted.asks.contains_key(&gone.id), "a failed rewrite must not undo a purge");
        assert_eq!(restarted.asks.get(&kept.id), Some(&kept), "pending captures must survive");

        // Once the failure clears, compaction also removes the purged plaintext.
        std::fs::remove_dir(&tmp).unwrap();
        let mut writer = Writer { dir: dir.path().to_owned(), path: path.clone(), file: None };
        assert!(writer.rewrite(&crate::hub::asks::snapshot(&restarted)));
        assert!(!std::fs::read_to_string(&path).unwrap().contains(&gone.text));
        let mut compacted = State::default();
        fold(&path, &mut compacted).unwrap();
        assert_eq!(compacted.asks.get(&kept.id), Some(&kept));
        assert!(!compacted.asks.contains_key(&gone.id));
    }

    #[test]
    fn a_partial_append_rolls_back_before_another_writer_can_append() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(FILE);
        let first = encode(&Line::Ask(ask("first"))).unwrap();
        std::fs::write(&path, &first).unwrap();
        let mut file = crate::config::private_state_append(&path).unwrap();
        let failed = encode(&Line::Ask(ask("failed"))).unwrap();
        let result = append(&mut file, |file| {
            file.write_all(&failed.as_bytes()[..failed.len() / 2])?;
            Err(std::io::Error::other("injected partial append"))
        });
        assert!(result.is_err());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), first);
        drop(file);
        let mut writer = Writer { dir: dir.path().to_owned(), path: path.clone(), file: None };
        writer.write(&encode(&Line::Ask(ask("later"))).unwrap()).unwrap();
        let mut recovered = State::default();
        fold(&path, &mut recovered).unwrap();
        assert_eq!(recovered.asks.len(), 2);
        assert!(recovered.asks.contains_key("ask-first"));
        assert!(recovered.asks.contains_key("ask-later"));
        for line in std::fs::read_to_string(path).unwrap().lines() {
            serde_json::from_str::<Line>(line).unwrap();
        }
    }

    #[test]
    fn failed_rewrite_and_append_reject_purge_and_stop_the_writer() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(FILE);
        std::fs::create_dir(&path).unwrap();
        std::fs::create_dir(dir.path().join(format!("{FILE}.tmp"))).unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        let (done, mut acknowledgment) = tokio::sync::oneshot::channel();
        tx.send(Work::Purge { sid: "gone".into(), lines: vec![], done }).unwrap();
        let (later, mut later_ack) = tokio::sync::oneshot::channel();
        tx.send(Work::Purge { sid: "later".into(), lines: vec![], done: later }).unwrap();
        Writer { dir: dir.path().to_owned(), path: path.clone(), file: None }.run(rx);
        assert!(acknowledgment.try_recv().unwrap().is_err());
        assert_eq!(later_ack.try_recv(), Err(tokio::sync::oneshot::error::TryRecvError::Closed));
        assert!(tx.send(Work::Line(Box::new(Line::Ask(ask("later"))))).is_err());
        assert!(path.is_dir());
    }
}
