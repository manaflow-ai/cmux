//! One agent's queue of hook events on disk: request lines in the order the
//! provider ran the hooks, kept until the daemon answered them
//! ([`super::journal_append`] sends them).
//!
//! Files, in `hook-spool/` beside the session socket: `<socket>.<terminal>.jsonl`
//! holds the lines, and `<...>.drain` is the drain lock, held by the one
//! child that sends the queue. Both locks are `flock`-style file locks
//! (`File::lock`), released when the holder exits, so a child that dies never
//! leaves a queue locked.
//!
//! Lifecycle (R6: every file has an owner and an end, no timer):
//! - The queue file's own lock guards every read and write of it; holders do
//!   only local file work under it.
//! - A sender that reaches the end of the queue deletes both files, the drain
//!   lock first, under both locks. A child that opened a path before it was
//!   deleted sees, once it holds the lock, that the path names another file
//!   or none, and opens the path again (`names_this_file`).
//! - A queue nobody sends (its sender died, its daemon stopped or crashed, or
//!   its agent ran no hook since) is sent by the session's next owner when it
//!   attaches (`resume`), and by the next hook child of any agent of the
//!   session ([`session_queues`]); other sessions' queues are theirs.
//! - The one definitive end is `cmux session NAME reset-state`
//!   (`cmux_tui_core::diagnostics::drop_session_hook_queues`).
//!
//! The directory must be private (`cmux_tui_core::diagnostics::hook_spool_dir`),
//! and no file is opened through a symlink: the lines hold hook payloads.

use std::fs::File;
use std::io::{Seek, SeekFrom};

use cmux_tui_core::diagnostics::{
    hook_spool_dir, names_this_file, open_spool_file, queue_prefix, spool_name_part,
};

use super::*;

/// The queue of the agent whose hook made one request.
pub(super) struct Spool {
    lines: PathBuf,
    drain: PathBuf,
}

/// The drain lock: while held, this child is the queue's one sender. The
/// lock is the open file's; it goes with the file.
pub(super) struct DrainLock {
    _held: File,
}

impl Spool {
    /// The queue for the request line `encoded` on `socket`: one per terminal
    /// (the event's terminal subject), so agents never wait on each other.
    /// An error when the socket's directory is not private.
    pub(super) fn for_request(socket: &Path, encoded: &[u8]) -> io::Result<Self> {
        let directory = hook_spool_dir(socket)?;
        Ok(Self::named(
            &directory,
            &format!("{}.{}", queue_prefix(socket), spool_name_part(&terminal_of(encoded))),
        ))
    }

    fn named(directory: &Path, base: &str) -> Self {
        Self {
            lines: directory.join(format!("{base}.jsonl")),
            drain: directory.join(format!("{base}.drain")),
        }
    }

    /// Appends `line` (one request ending in a newline).
    pub(super) fn append(&self, line: &[u8]) -> io::Result<()> {
        let mut file = self.open_locked()?;
        let length = file.seek(SeekFrom::End(0))?;
        if length > 0 && !ends_with_newline(&mut file, length)? {
            // A child died while it wrote: seal its torn line, so it is one
            // unreadable line the sender skips, not a prefix of this one.
            file.write_all(b"\n")?;
        }
        file.write_all(line)?;
        file.flush()
    }

    /// The drain lock, when no other child holds it.
    pub(super) fn try_drain(&self) -> io::Result<Option<DrainLock>> {
        loop {
            let file = open_spool_file(&self.drain)?;
            match file.try_lock() {
                Ok(()) => {}
                Err(std::fs::TryLockError::WouldBlock) => return Ok(None),
                Err(std::fs::TryLockError::Error(error)) => return Err(error),
            }
            if names_this_file(&self.drain, &file)? {
                return Ok(Some(DrainLock { _held: file }));
            }
            // A sender deleted the queue after this child opened the lock
            // file: lock the one the path names now.
        }
    }

    /// The line at byte `offset` and the offset after it; `None` at the end.
    /// A torn last line comes back as it is (the sender skips it).
    pub(super) fn line_at(&self, offset: u64) -> io::Result<Option<(Vec<u8>, u64)>> {
        let mut file = self.open_locked()?;
        file.seek(SeekFrom::Start(offset))?;
        let mut line = Vec::new();
        let read = BufReader::new(&mut file)
            .take((MAX_MESSAGE_BYTES as u64).saturating_add(1))
            .read_until(b'\n', &mut line)?;
        Ok((read > 0).then(|| (line, offset.saturating_add(read as u64))))
    }

    /// At the end of the queue (every line before `offset` answered): deletes
    /// it and lets go of `lock`, unless lines came in since, which keep the
    /// sender (`Some`).
    pub(super) fn finish(&self, offset: u64, lock: DrainLock) -> io::Result<Option<DrainLock>> {
        let file = self.open_locked()?;
        if file.metadata()?.len() > offset {
            return Ok(Some(lock));
        }
        self.remove_files()?;
        drop(lock);
        Ok(None)
    }

    /// Drops the lines before `offset` (answered), keeping the rest queued,
    /// when the sender stops early. The rest goes to a new file renamed over
    /// the queue, so a child that dies here leaves the old queue whole.
    pub(super) fn compact(&self, offset: u64) -> io::Result<()> {
        if offset == 0 {
            return Ok(());
        }
        let mut file = self.open_locked()?;
        file.seek(SeekFrom::Start(offset))?;
        let mut rest = Vec::new();
        file.read_to_end(&mut rest)?;
        let mut name = self.lines.file_name().unwrap_or_default().to_os_string();
        name.push(".compact");
        let staged = self.lines.with_file_name(name);
        let mut copy = open_spool_file(&staged)?;
        copy.set_len(0)?;
        copy.write_all(&rest)?;
        copy.sync_data()?;
        // Under the old file's lock: a child waiting on it reopens the path.
        std::fs::rename(&staged, &self.lines)
    }

    /// Unlinks both files; the caller holds both locks. The drain lock goes
    /// first: a child that queues after it finds a new drain lock and sends
    /// its own line. The other way round, a child in between appended to a
    /// new queue file, found the old drain lock held and left its line with
    /// no sender.
    fn remove_files(&self) -> io::Result<()> {
        remove_if_present(&self.drain)?;
        #[cfg(test)]
        run_between_unlinks(&self.lines);
        remove_if_present(&self.lines)
    }

    /// The queue file, opened and locked for this process until dropped.
    fn open_locked(&self) -> io::Result<File> {
        loop {
            let file = open_spool_file(&self.lines)?;
            file.lock()?;
            if names_this_file(&self.lines, &file)? {
                return Ok(file);
            }
        }
    }
}

/// The queues of `socket`'s session but `except` (none, and no directory
/// made, where no hook ever queued one).
pub(super) fn session_queues(socket: &Path, except: Option<&Spool>) -> io::Result<Vec<Spool>> {
    let queued_here = socket
        .parent()
        .is_some_and(|parent| parent.join(cmux_tui_core::diagnostics::HOOK_SPOOL_DIR).is_dir());
    if !queued_here {
        return Ok(Vec::new());
    }
    let directory = hook_spool_dir(socket)?;
    let directory = directory.as_path();
    let prefix = format!("{}.", queue_prefix(socket));
    let mut found = Vec::new();
    for entry in std::fs::read_dir(directory)? {
        let name = entry?.file_name().to_string_lossy().into_owned();
        let Some(base) = name.strip_suffix(".jsonl").filter(|base| base.starts_with(&prefix))
        else {
            continue;
        };
        let spool = Spool::named(directory, base);
        if except.is_none_or(|except| spool.lines != except.lines) {
            found.push(spool);
        }
    }
    Ok(found)
}

fn remove_if_present(path: &Path) -> io::Result<()> {
    match std::fs::remove_file(path) {
        Err(error) if error.kind() != io::ErrorKind::NotFound => Err(error),
        _ => Ok(()),
    }
}

/// Test seam: runs once, between the two unlinks of a queue of the terminal
/// `terminal_race` (tests run in parallel, so only that test's queue fires it).
#[cfg(test)]
type BetweenUnlinks = Box<dyn FnOnce() + Send>;

#[cfg(test)]
static BETWEEN_UNLINKS: std::sync::Mutex<Vec<BetweenUnlinks>> = std::sync::Mutex::new(Vec::new());

/// Runs `hook` between the two unlinks of the next finished `terminal_race`
/// queue. Only the Unix tests use it (there is no queue elsewhere).
#[cfg(all(test, unix))]
pub(super) fn between_unlinks_for_test(hook: Box<dyn FnOnce() + Send>) {
    // A test that panicked while it held the seam leaves the list whole; the
    // next test still queues its hook.
    BETWEEN_UNLINKS.lock().unwrap_or_else(std::sync::PoisonError::into_inner).push(hook);
}

#[cfg(test)]
fn run_between_unlinks(lines: &Path) {
    let racing = lines.file_name().is_some_and(|name| {
        name.to_string_lossy().contains(&format!(".{}.", spool_name_part("terminal_race")))
    });
    if !racing {
        return;
    }
    let hook = BETWEEN_UNLINKS.lock().unwrap_or_else(std::sync::PoisonError::into_inner).pop();
    if let Some(hook) = hook {
        hook();
    }
}

fn ends_with_newline(file: &mut File, length: u64) -> io::Result<bool> {
    file.seek(SeekFrom::Start(length.saturating_sub(1)))?;
    let mut last = [0_u8; 1];
    file.read_exact(&mut last)?;
    file.seek(SeekFrom::End(0))?;
    Ok(last == [b'\n'])
}

/// The terminal subject of a hook request line; `session` when it has none.
fn terminal_of(encoded: &[u8]) -> String {
    serde_json::from_slice::<Value>(encoded)
        .ok()
        .and_then(|request| {
            request
                .get("params")?
                .get("event")?
                .get("subjects")?
                .as_array()?
                .iter()
                .find(|subject| subject.get("kind").and_then(Value::as_str) == Some("terminal"))?
                .get("id")?
                .as_str()
                .map(str::to_owned)
        })
        .unwrap_or_else(|| "session".to_owned())
}
