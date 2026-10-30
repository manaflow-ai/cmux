//! The agent hook queues on disk: where they live, how their files are
//! opened, and the one definitive end of a session's queues.
//!
//! The hook helper keeps each agent's hook events in a queue,
//! `hook-spool/<socket>.<terminal>.jsonl` beside the session socket, until
//! the daemon answers them (cmux-tui `cmux-tui-hook/hook_spool.rs`). A queue
//! belongs to the session served on that socket:
//! - A daemon that stops (its owner removes the socket on every stop,
//!   upgrades and restarts included) or crashes (it leaves the socket) is no
//!   definitive answer: the session comes back on the same socket, and the
//!   next hook of any of its agents sends the queue to the new owner.
//! - `cmux session NAME reset-state` removes the session's saved state, so no
//!   owner can come back for its queues: it deletes them
//!   ([`drop_session_hook_queues`]) and adds their events to
//!   `reset-dropped-events`, which `server-stats` reports (`hook_queue`).
//!
//! The queues hold hook payloads (prompt text among them), so they live only
//! in a directory that this user owns and nobody else may write
//! ([`hook_spool_dir`]), and every file is opened without following a
//! symlink ([`open_spool_file`]). Where that does not hold, the helper sends
//! its event directly, with no queue.

use std::fs::File;
use std::io::{self, Read as _, Seek as _, SeekFrom, Write as _};
use std::path::{Path, PathBuf};

use serde::Serialize;

/// The directory of hook queues, beside the session socket.
pub const HOOK_SPOOL_DIR: &str = "hook-spool";
/// The count of hook events dropped by `reset-state`, in [`HOOK_SPOOL_DIR`].
pub const HOOK_SPOOL_DROPPED_EVENTS: &str = "reset-dropped-events";

/// `server-stats` `hook_queue`.
#[derive(Clone, Debug, Default, Serialize)]
pub struct HookQueueSnapshot {
    /// Hook event lines in this session's queues: events not yet answered,
    /// and answered ones a sender has not removed yet (it removes them when
    /// its queue is empty).
    pub queued_events: u64,
    /// Hook events of sessions whose saved state `reset-state` removed before
    /// a daemon answered them, for every session whose socket shares this
    /// one's directory.
    pub reset_dropped_events: u64,
}

impl HookQueueSnapshot {
    /// The counts beside `socket` (0 where there is no queue).
    pub fn beside(socket: &Path) -> Self {
        let Some(directory) = socket.parent().map(|parent| parent.join(HOOK_SPOOL_DIR)) else {
            return Self::default();
        };
        let prefix = format!("{}.", queue_prefix(socket));
        let queued_events = std::fs::read_dir(&directory)
            .map(|entries| {
                entries
                    .filter_map(Result::ok)
                    .filter(|entry| {
                        let name = entry.file_name().to_string_lossy().into_owned();
                        name.starts_with(&prefix) && name.ends_with(".jsonl")
                    })
                    .filter_map(|entry| open_for_reading(&entry.path()).ok())
                    .map(|mut file| count_lines(&mut file).unwrap_or(0))
                    .sum()
            })
            .unwrap_or(0);
        let reset_dropped_events = open_for_reading(&directory.join(HOOK_SPOOL_DROPPED_EVENTS))
            .ok()
            .and_then(|file| {
                file.lock_shared().ok()?;
                read_count(&file)
            })
            .unwrap_or(0);
        Self { queued_events, reset_dropped_events }
    }
}

/// The hook queue directory beside `socket`, made if missing, when it is
/// private: the socket's directory and the queue directory are owned by
/// this user and nobody else may write them. An error otherwise.
pub fn hook_spool_dir(socket: &Path) -> io::Result<PathBuf> {
    let parent =
        socket.parent().filter(|parent| !parent.as_os_str().is_empty()).ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "the session socket has no directory")
        })?;
    ensure_private(parent, 0o022)?;
    let directory = parent.join(HOOK_SPOOL_DIR);
    let mut builder = std::fs::DirBuilder::new();
    #[cfg(unix)]
    std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
    match builder.create(&directory) {
        Err(error) if error.kind() != io::ErrorKind::AlreadyExists => return Err(error),
        _ => {}
    }
    ensure_private(&directory, 0o077)?;
    Ok(directory)
}

/// `path` is a directory (not a symlink) this user owns, with none of the
/// `forbidden` permission bits.
#[cfg(unix)]
fn ensure_private(path: &Path, forbidden: u32) -> io::Result<()> {
    use std::os::unix::fs::MetadataExt as _;
    let metadata = std::fs::symlink_metadata(path)?;
    // SAFETY: geteuid has no preconditions.
    let me = unsafe { libc::geteuid() };
    if !metadata.file_type().is_dir() || metadata.uid() != me || metadata.mode() & forbidden != 0 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("{} is not a private directory of this user", path.display()),
        ));
    }
    Ok(())
}

#[cfg(not(unix))]
fn ensure_private(path: &Path, _forbidden: u32) -> io::Result<()> {
    if std::fs::symlink_metadata(path)?.file_type().is_dir() {
        Ok(())
    } else {
        Err(io::Error::new(io::ErrorKind::PermissionDenied, "not a directory"))
    }
}

/// Opens (and makes, mode 0600) a queue file for reading and writing, never
/// through a symlink.
pub fn open_spool_file(path: &Path) -> io::Result<File> {
    let mut options = std::fs::OpenOptions::new();
    options.read(true).write(true).create(true).truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    options.open(path)
}

/// Opens an existing queue file to read it, never through a symlink.
fn open_for_reading(path: &Path) -> io::Result<File> {
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.custom_flags(libc::O_NOFOLLOW);
    }
    options.open(path)
}

/// `socket`'s file name as queue file names write it.
pub fn queue_prefix(socket: &Path) -> String {
    socket
        .file_name()
        .map_or_else(|| "session".to_owned(), |name| spool_name_part(&name.to_string_lossy()))
}

/// `text` as a queue file name part: letters, digits, `-` and `_` only
/// (never the `.` that separates the parts), at most 64 characters.
pub fn spool_name_part(text: &str) -> String {
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

/// Deletes every hook queue of the session served on `socket` and adds their
/// events to `reset-dropped-events`. Only `reset-state` calls it: the session
/// has no saved state left, so no owner will ever answer them. Waits for a
/// sender still at work (it stops at once without a daemon). The count of
/// dropped events.
pub fn drop_session_hook_queues(socket: &Path) -> io::Result<u64> {
    let Some(directory) = socket.parent().map(|parent| parent.join(HOOK_SPOOL_DIR)) else {
        return Ok(0);
    };
    let entries = match std::fs::read_dir(&directory) {
        Ok(entries) => entries,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(0),
        Err(error) => return Err(error),
    };
    let prefix = format!("{}.", queue_prefix(socket));
    let mut dropped = 0_u64;
    for entry in entries {
        let name = entry?.file_name().to_string_lossy().into_owned();
        let Some(base) = name.strip_suffix(".jsonl").filter(|base| base.starts_with(&prefix))
        else {
            continue;
        };
        let lines_path = directory.join(&name);
        let drain_path = directory.join(format!("{base}.drain"));
        let drain = open_spool_file(&drain_path)?;
        drain.lock()?;
        let mut lines = open_spool_file(&lines_path)?;
        lines.lock()?;
        dropped = dropped.saturating_add(count_lines(&mut lines)?);
        // The drain lock first: a hook that queues after this finds a new
        // drain lock, so it sends its own line instead of waiting on this one.
        remove_if_present(&drain_path)?;
        remove_if_present(&lines_path)?;
    }
    if dropped > 0 {
        add_dropped_events(&directory, dropped)?;
    }
    Ok(dropped)
}

fn add_dropped_events(directory: &Path, events: u64) -> io::Result<()> {
    let mut file = open_spool_file(&directory.join(HOOK_SPOOL_DROPPED_EVENTS))?;
    file.lock()?;
    let total = read_count(&file).unwrap_or(0).saturating_add(events);
    file.set_len(0)?;
    file.seek(SeekFrom::Start(0))?;
    writeln!(file, "{total}")
}

fn read_count(mut file: &File) -> Option<u64> {
    let mut text = String::new();
    file.read_to_string(&mut text).ok()?;
    text.trim().parse().ok()
}

fn count_lines(file: &mut File) -> io::Result<u64> {
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)?;
    Ok(bytes.split(|byte| *byte == b'\n').filter(|line| !line.is_empty()).count() as u64)
}

fn remove_if_present(path: &Path) -> io::Result<()> {
    match std::fs::remove_file(path) {
        Err(error) if error.kind() != io::ErrorKind::NotFound => Err(error),
        _ => Ok(()),
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    fn private_dir() -> PathBuf {
        let mut bytes = [0_u8; 8];
        getrandom::fill(&mut bytes).unwrap();
        let suffix: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
        let directory = std::env::temp_dir().join(format!("cmux-hook-queue-test-{suffix}"));
        let mut builder = std::fs::DirBuilder::new();
        std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
        builder.create(&directory).unwrap();
        directory
    }

    /// `reset-state` is the definitive end of a session's hook queues: they
    /// are deleted and their events counted; another session's stay.
    #[test]
    fn reset_drops_and_counts_only_the_sessions_hook_queues() {
        let root = private_dir();
        let socket = root.join("work.sock");
        let spool = hook_spool_dir(&socket).unwrap();
        std::fs::write(spool.join("work_sock.terminal_a.jsonl"), "{}\n{}\n").unwrap();
        std::fs::write(spool.join("work_sock.terminal_b.jsonl"), "{}\n").unwrap();
        std::fs::write(spool.join("other_sock.terminal_c.jsonl"), "{}\n").unwrap();
        assert_eq!(HookQueueSnapshot::beside(&socket).queued_events, 3);

        assert_eq!(drop_session_hook_queues(&socket).unwrap(), 3);

        let mut left: Vec<_> = std::fs::read_dir(&spool)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        left.sort();
        assert_eq!(left, vec!["other_sock.terminal_c.jsonl", HOOK_SPOOL_DROPPED_EVENTS]);
        let snapshot = HookQueueSnapshot::beside(&socket);
        assert_eq!((snapshot.queued_events, snapshot.reset_dropped_events), (0, 3));
        assert_eq!(HookQueueSnapshot::beside(&root.join("other.sock")).queued_events, 1);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn a_shared_directory_gets_no_spool() {
        use std::os::unix::fs::PermissionsExt as _;
        let root = private_dir();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o777)).unwrap();
        assert!(hook_spool_dir(&root.join("s.sock")).is_err());
        assert!(!root.join(HOOK_SPOOL_DIR).exists());
        std::fs::remove_dir_all(root).unwrap();
    }
}
