//! One agent's queue of hook events on disk: request lines in the order the
//! provider ran the hooks, kept until the daemon answered them
//! ([`super::journal_append`] sends them).
//!
//! Files, beside the session socket in its user-private runtime directory:
//! `hook-spool/<socket name>.<terminal>.jsonl` holds the lines, and
//! `<...>.drain` is the drain lock, held by the one child that sends the
//! queue. Both locks are `flock`-style file locks (`File::lock`), released
//! when the holder exits, so a child that dies never leaves a queue locked.
//!
//! The queue file's own lock guards every read and write of it; holders do
//! only local file work under it. Lines before the sender's offset were
//! answered; the sender empties the file when it reaches the end, and lets
//! go of the drain lock while it still holds the queue lock, so a line
//! appended after that finds the drain lock free and its child sends it.

use std::fs::{File, OpenOptions};
use std::io::{Seek, SeekFrom};

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
    pub(super) fn for_request(socket: &Path, encoded: &[u8]) -> io::Result<Self> {
        let directory = socket.parent().unwrap_or_else(|| Path::new(".")).join("hook-spool");
        create_private_dir(&directory)?;
        let socket_name = socket
            .file_name()
            .map_or_else(|| "session".to_owned(), |name| file_name_part(&name.to_string_lossy()));
        let base = format!("{socket_name}.{}", file_name_part(&terminal_of(encoded)));
        Ok(Self {
            lines: directory.join(format!("{base}.jsonl")),
            drain: directory.join(format!("{base}.drain")),
        })
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
        let file = open_private(&self.drain)?;
        match file.try_lock() {
            Ok(()) => Ok(Some(DrainLock { _held: file })),
            Err(std::fs::TryLockError::WouldBlock) => Ok(None),
            Err(std::fs::TryLockError::Error(error)) => Err(error),
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

    /// At the end of the queue (every line before `offset` answered): empties
    /// it and lets go of `lock`, unless lines came in since, which keep the
    /// sender (`Some`).
    pub(super) fn finish(&self, offset: u64, lock: DrainLock) -> io::Result<Option<DrainLock>> {
        let file = self.open_locked()?;
        if file.metadata()?.len() > offset {
            return Ok(Some(lock));
        }
        file.set_len(0)?;
        // Under the queue lock: a child that appends next finds the drain
        // lock free and sends its line itself.
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

    /// The queue file, opened and locked for this process until dropped.
    fn open_locked(&self) -> io::Result<File> {
        let file = open_private(&self.lines)?;
        file.lock()?;
        Ok(file)
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

/// `text` as a file name part: letters, digits, `-` and `_` only, at most
/// 64 characters.
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
