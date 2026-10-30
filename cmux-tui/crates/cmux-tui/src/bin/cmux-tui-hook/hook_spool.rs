//! One agent's queue of hook events on disk: request lines in the order the
//! provider ran the hooks, kept until the daemon answered them
//! ([`super::journal_append`] sends them).
//!
//! Files, in `hook-spool/` beside the session socket (its user-private
//! runtime directory): `<socket>.<terminal>.jsonl` holds the lines, and
//! `<...>.drain` is the drain lock, held by the one child that sends the
//! queue. Both locks are `flock`-style file locks (`File::lock`), released
//! when the holder exits, so a child that dies never leaves a queue locked.
//!
//! Lifecycle (R6: every file has an owner and an end, no timer):
//! - The queue file's own lock guards every read and write of it; holders do
//!   only local file work under it.
//! - A sender that reaches the end of the queue deletes both files, under both
//!   locks. A child that opened a path before it was deleted sees, once it
//!   holds the lock, that the path names another file or none, and opens the
//!   path again ([`open_current`]).
//! - A queue nobody sends (its sender died, or its agent ran no hook since)
//!   is sent by the next hook child of any agent of the session
//!   ([`orphans`]).
//! - The daemon removes its socket file only when its session ends. A queue
//!   whose session socket is gone is deleted by the next hook child of any
//!   session in the directory, and its events are added to
//!   `ended-session-events` ([`HOOK_SPOOL_ENDED_EVENTS`]), which the daemon's
//!   `server-stats` reports (`hook_queue`).

use std::fs::{File, OpenOptions};
use std::io::{Seek, SeekFrom};

use cmux_tui_core::diagnostics::{HOOK_SPOOL_DIR, HOOK_SPOOL_ENDED_EVENTS};

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

/// A queue file of the directory that this child may act on.
pub(super) enum Found {
    /// A queue of `socket`'s own session.
    Live(Spool),
    /// A queue of a session whose socket is gone.
    Ended(Spool),
}

impl Spool {
    /// The queue for the request line `encoded` on `socket`: one per terminal
    /// (the event's terminal subject), so agents never wait on each other.
    pub(super) fn for_request(socket: &Path, encoded: &[u8]) -> io::Result<Self> {
        let directory = spool_dir(socket);
        create_private_dir(&directory)?;
        Ok(Self::named(
            &directory,
            &format!("{}.{}", socket_part(socket), file_name_part(&terminal_of(encoded))),
        ))
    }

    fn named(directory: &Path, base: &str) -> Self {
        Self {
            lines: directory.join(format!("{base}.jsonl")),
            drain: directory.join(format!("{base}.drain")),
        }
    }

    /// Appends `line` (one request ending in a newline). True when lines were
    /// queued before it: it then waits behind them.
    pub(super) fn append(&self, line: &[u8]) -> io::Result<bool> {
        let mut file = self.open_locked()?;
        let length = file.seek(SeekFrom::End(0))?;
        if length > 0 && !ends_with_newline(&mut file, length)? {
            // A child died while it wrote: seal its torn line, so it is one
            // unreadable line the sender skips, not a prefix of this one.
            file.write_all(b"\n")?;
        }
        file.write_all(line)?;
        file.flush()?;
        Ok(length > 0)
    }

    /// The drain lock, when no other child holds it.
    pub(super) fn try_drain(&self) -> io::Result<Option<DrainLock>> {
        loop {
            let file = open_private(&self.drain)?;
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
            .take(MAX_MESSAGE_BYTES as u64 + 1)
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
    /// when the sender stops early.
    pub(super) fn compact(&self, offset: u64) -> io::Result<()> {
        if offset == 0 {
            return Ok(());
        }
        let mut file = self.open_locked()?;
        file.seek(SeekFrom::Start(offset))?;
        let mut rest = Vec::new();
        file.read_to_end(&mut rest)?;
        file.set_len(0)?;
        file.seek(SeekFrom::Start(0))?;
        file.write_all(&rest)
    }

    /// The session is gone: deletes the queue from `offset` on, lets go of
    /// `lock` and counts the dropped events in `ended-session-events`.
    pub(super) fn discard(&self, offset: u64, lock: DrainLock) -> io::Result<u64> {
        let dropped = {
            let mut file = self.open_locked()?;
            file.seek(SeekFrom::Start(offset))?;
            let mut rest = Vec::new();
            file.read_to_end(&mut rest)?;
            self.remove_files()?;
            rest.split(|byte| *byte == b'\n').filter(|line| !line.is_empty()).count() as u64
        };
        drop(lock);
        if dropped > 0
            && let Some(directory) = self.lines.parent()
        {
            add_ended_session_events(directory, dropped)?;
        }
        Ok(dropped)
    }

    /// Unlinks both files; the caller holds both locks.
    fn remove_files(&self) -> io::Result<()> {
        for path in [&self.lines, &self.drain] {
            match std::fs::remove_file(path) {
                Err(error) if error.kind() != io::ErrorKind::NotFound => return Err(error),
                _ => {}
            }
        }
        Ok(())
    }

    /// The queue file, opened and locked for this process until dropped.
    fn open_locked(&self) -> io::Result<File> {
        loop {
            let file = open_private(&self.lines)?;
            file.lock()?;
            if names_this_file(&self.lines, &file)? {
                return Ok(file);
            }
        }
    }
}

/// The other queues of the directory beside `socket` that this child may act
/// on: those of its own session, and those of sessions whose socket is gone.
pub(super) fn orphans(socket: &Path, except: Option<&Spool>) -> io::Result<Vec<Found>> {
    let directory = spool_dir(socket);
    let entries = match std::fs::read_dir(&directory) {
        Ok(entries) => entries,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error),
    };
    let own = socket_part(socket);
    let mut sockets = None;
    let mut found = Vec::new();
    for entry in entries {
        let name = entry?.file_name().to_string_lossy().into_owned();
        let Some(base) = name.strip_suffix(".jsonl") else { continue };
        let spool = Spool::named(&directory, base);
        if except.is_some_and(|except| except.lines == spool.lines) {
            continue;
        }
        let Some((socket_name, _terminal)) = base.split_once('.') else { continue };
        if socket_name == own {
            found.push(Found::Live(spool));
            continue;
        }
        // Read the socket directory once, and only when another session's
        // queue is here.
        let sockets = match &sockets {
            Some(sockets) => sockets,
            None => sockets.insert(socket_parts(socket)?),
        };
        if !sockets.contains(socket_name) {
            found.push(Found::Ended(spool));
        }
    }
    Ok(found)
}

fn spool_dir(socket: &Path) -> PathBuf {
    socket.parent().unwrap_or_else(|| Path::new(".")).join(HOOK_SPOOL_DIR)
}

/// `socket`'s file name as the queue file names write it.
fn socket_part(socket: &Path) -> String {
    socket
        .file_name()
        .map_or_else(|| "session".to_owned(), |name| file_name_part(&name.to_string_lossy()))
}

/// Every name in `socket`'s directory, as queue file names write a socket's.
fn socket_parts(socket: &Path) -> io::Result<std::collections::HashSet<String>> {
    let directory = socket.parent().unwrap_or_else(|| Path::new("."));
    std::fs::read_dir(directory)?
        .map(|entry| Ok(file_name_part(&entry?.file_name().to_string_lossy())))
        .collect()
}

/// Adds `events` to the directory's count of hook events dropped with their
/// session.
fn add_ended_session_events(directory: &Path, events: u64) -> io::Result<()> {
    let mut file = open_private(&directory.join(HOOK_SPOOL_ENDED_EVENTS))?;
    file.lock()?;
    let mut text = String::new();
    file.read_to_string(&mut text)?;
    let total = text.trim().parse::<u64>().unwrap_or(0).saturating_add(events);
    file.set_len(0)?;
    file.seek(SeekFrom::Start(0))?;
    writeln!(file, "{total}")
}

/// Whether `path` still names the open `file` (a deleter may have unlinked
/// it before this child took its lock).
#[cfg(unix)]
fn names_this_file(path: &Path, file: &File) -> io::Result<bool> {
    use std::os::unix::fs::MetadataExt as _;
    let open = file.metadata()?;
    match std::fs::metadata(path) {
        Ok(named) => Ok(named.dev() == open.dev() && named.ino() == open.ino()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error),
    }
}

/// Windows refuses to delete an open file, so the path still names it.
#[cfg(not(unix))]
fn names_this_file(_path: &Path, _file: &File) -> io::Result<bool> {
    Ok(true)
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

/// `text` as a file name part: letters, digits, `-` and `_` only (never the
/// `.` that separates the parts), at most 64 characters.
fn file_name_part(text: &str) -> String {
    let part: String = text
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || character == '-' || character == '_' {
                character
            } else {
                '_'
            }
        })
        .take(64)
        .collect();
    if part.is_empty() { "_".to_owned() } else { part }
}

fn open_private(path: &Path) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options.read(true).write(true).create(true).truncate(false);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    options.open(path)
}

fn create_private_dir(directory: &Path) -> io::Result<()> {
    let mut builder = std::fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
    builder.create(directory)
}
