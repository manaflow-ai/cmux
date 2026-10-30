//! The agent hook queues on disk: where they live, how their files are
//! named and opened, and the one definitive end of a session's queues.
//!
//! The hook helper keeps each agent's hook events in a queue,
//! `hook-spool/<socket>.<terminal>.jsonl` beside the session socket (each
//! part a digest of the name, [`queue_prefix`]), until
//! the daemon answers them (cmux-tui `cmux-tui-hook/hook_spool.rs`). A queue
//! belongs to the session served on that socket:
//! - A daemon that stops (its owner removes the socket on every stop,
//!   upgrades and restarts included) or crashes (it leaves the socket) is no
//!   definitive answer: the session comes back on the same socket. Its next
//!   owner sends the queues when it attaches (cmux-tui main), and so does
//!   the next hook of any of its agents.
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
use std::io::{self, BufRead as _, Read as _, Seek as _, SeekFrom, Write as _};
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::Serialize;
use sha2::{Digest as _, Sha256};

/// The longest a daemon holds a journal append (its durable wait, at most the
/// clamp of `CMUX_TUI_JOURNAL_DURABLE_WAIT_MS`) before it answers, an error
/// included. A hook sender waits past this for a receipt (R-L5: the client's
/// deadline is at least the server's own wait).
pub const JOURNAL_APPEND_LONGEST_WAIT: Duration = Duration::from_secs(5 * 60);

/// The directory of hook queues, beside the session socket.
pub const HOOK_SPOOL_DIR: &str = "hook-spool";
/// The count of hook events dropped by `reset-state`, in [`HOOK_SPOOL_DIR`].
pub const HOOK_SPOOL_DROPPED_EVENTS: &str = "reset-dropped-events";
/// The count of hook events a live daemon took but never answered, so their
/// sender gave them up (`cmux-tui-hook` `journal_append`), in
/// [`HOOK_SPOOL_DIR`].
pub const HOOK_SPOOL_UNDELIVERABLE_EVENTS: &str = "undeliverable-events";

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
    /// Hook events a live daemon took several times in a row and never
    /// answered (it closed on them, or did not reply within its own longest
    /// wait), so their senders gave them up, for every session whose socket
    /// shares this one's directory.
    pub undeliverable_events: u64,
}

impl HookQueueSnapshot {
    /// The counts beside `socket` (0 where there is no queue).
    pub fn beside(socket: &Path) -> Self {
        let Ok(Some(directory)) = existing_hook_spool_dir(socket) else {
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
                    .map(|file| count_lines(&file).unwrap_or(0))
                    .sum()
            })
            .unwrap_or(0);
        let count = |name: &str| {
            open_for_reading(&directory.join(name))
                .ok()
                .and_then(|file| {
                    // Never wait on a request thread: a writer holds this
                    // lock for microseconds, and a busy moment reports 0.
                    file.try_lock_shared().ok()?;
                    read_count(&file)
                })
                .unwrap_or(0)
        };
        Self {
            queued_events,
            reset_dropped_events: count(HOOK_SPOOL_DROPPED_EVENTS),
            undeliverable_events: count(HOOK_SPOOL_UNDELIVERABLE_EVENTS),
        }
    }
}

/// The hook queue directory beside `socket`, made if missing, when it is
/// private: the socket's directory and the queue directory are owned by
/// this user and nobody else may write them. An error otherwise.
pub fn hook_spool_dir(socket: &Path) -> io::Result<PathBuf> {
    require_file_identity()?;
    let parent =
        socket.parent().filter(|parent| !parent.as_os_str().is_empty()).ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "the session socket has no directory")
        })?;
    ensure_private(parent, 0o022)?;
    let directory = parent.join(HOOK_SPOOL_DIR);
    let builder = private_dir_builder();
    match builder.create(&directory) {
        Err(error) if error.kind() != io::ErrorKind::AlreadyExists => return Err(error),
        _ => {}
    }
    ensure_private(&directory, 0o077)?;
    Ok(directory)
}

/// The hook queue directory beside `socket` when one exists and it is
/// private (as [`hook_spool_dir`] requires); `None` when there is none. It
/// makes nothing: reset-state and server-stats read and delete only in a
/// directory that this user owns.
fn existing_hook_spool_dir(socket: &Path) -> io::Result<Option<PathBuf>> {
    if require_file_identity().is_err() {
        return Ok(None);
    }
    let Some(parent) = socket.parent().filter(|parent| !parent.as_os_str().is_empty()) else {
        return Ok(None);
    };
    let directory = parent.join(HOOK_SPOOL_DIR);
    if std::fs::symlink_metadata(&directory).is_err() {
        return Ok(None);
    }
    ensure_private(parent, 0o022)?;
    ensure_private(&directory, 0o077)?;
    Ok(Some(directory))
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

/// `socket`'s part of its queue file names: a digest of the socket's file
/// name, so two sockets never share a queue (an escaped or shortened name
/// could: `a.b.sock` and `a_b.sock`).
pub fn queue_prefix(socket: &Path) -> String {
    spool_name_part(&socket.file_name().map(|name| name.to_string_lossy()).unwrap_or_default())
}

/// `text` as a queue file name part: the first 128 bits of its SHA-256, in
/// hex (never the `.` that separates the parts; the same length for any
/// text).
pub fn spool_name_part(text: &str) -> String {
    Sha256::digest(text.as_bytes()).iter().take(16).map(|byte| format!("{byte:02x}")).collect()
}

/// Deletes every hook queue of the session served on `socket` and adds their
/// events to `reset-dropped-events`. Only `reset-state` calls it: the session
/// has no saved state left, so no owner will ever answer them. Waits for a
/// sender still at work (it stops at once without a daemon). The count of
/// dropped events.
pub fn drop_session_hook_queues(socket: &Path) -> io::Result<u64> {
    let Some(directory) = existing_hook_spool_dir(socket)? else {
        return Ok(0);
    };
    let entries = std::fs::read_dir(&directory)?;
    let prefix = format!("{}.", queue_prefix(socket));
    let mut dropped = 0_u64;
    let mut first_error = None;
    for entry in entries.filter_map(Result::ok) {
        let name = entry.file_name().to_string_lossy().into_owned();
        let Some(base) = name.strip_suffix(".jsonl").filter(|base| base.starts_with(&prefix))
        else {
            continue;
        };
        // One queue that cannot be dropped (a planted link, say) does not
        // keep the others.
        match drop_queue(&directory, base) {
            Ok(events) => dropped = dropped.saturating_add(events),
            Err(error) => {
                first_error.get_or_insert(error);
            }
        }
    }
    if dropped > 0 {
        add_dropped_events(&directory, dropped)?;
    }
    first_error.map_or(Ok(dropped), Err)
}

/// Drops one queue: under its drain lock and its lines lock, both checked to
/// be the files their paths name now (a sender may have just replaced them),
/// unlinks the drain lock, the lines and a compaction a dead sender left.
fn drop_queue(directory: &Path, base: &str) -> io::Result<u64> {
    let lines_path = directory.join(format!("{base}.jsonl"));
    let drain_path = directory.join(format!("{base}.drain"));
    let _drain = lock_current(&drain_path)?;
    let lines = lock_current(&lines_path)?;
    let events = count_lines(&lines)?;
    remove_if_present(&drain_path)?;
    remove_if_present(&lines_path)?;
    remove_if_present(&directory.join(format!("{base}.jsonl.compact")))?;
    Ok(events)
}

/// The file at `path`, locked, and still the file the path names.
fn lock_current(path: &Path) -> io::Result<File> {
    loop {
        let file = open_spool_file(path)?;
        file.lock()?;
        if names_this_file(path, &file)? {
            return Ok(file);
        }
    }
}

/// Whether `path` still names the open `file`.
#[cfg(unix)]
pub fn names_this_file(path: &Path, file: &File) -> io::Result<bool> {
    use std::os::unix::fs::MetadataExt as _;
    let open = file.metadata()?;
    match std::fs::symlink_metadata(path) {
        Ok(named) => Ok(named.dev() == open.dev() && named.ino() == open.ino()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error),
    }
}

/// Elsewhere there is no inode to tell a deleted queue file from its
/// replacement, and there is no queue ([`require_file_identity`]): the
/// answer only matters to callers that got a queue directory.
#[cfg(not(unix))]
pub fn names_this_file(_path: &Path, _file: &File) -> io::Result<bool> {
    Err(io::Error::from(io::ErrorKind::Unsupported))
}

/// The queue needs file identity (`names_this_file`): a hook could otherwise
/// append to a queue file a sender just unlinked, after its provider was
/// released. Windows has a session socket and hooks, but this check only
/// on Unix, so its hooks send directly (the busy-line retry still applies).
fn require_file_identity() -> io::Result<()> {
    if cfg!(unix) {
        Ok(())
    } else {
        Err(io::Error::new(io::ErrorKind::Unsupported, "the hook queue needs file identity"))
    }
}

/// A directory builder that makes a 0700 directory where modes exist.
fn private_dir_builder() -> std::fs::DirBuilder {
    #[cfg_attr(not(unix), allow(unused_mut))]
    let mut builder = std::fs::DirBuilder::new();
    #[cfg(unix)]
    std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
    builder
}

/// Counts `events` hook events of the session on `socket` that a live
/// daemon would not answer, so their sender gave them up. Errors when there
/// is no private queue directory beside `socket`.
pub fn add_undeliverable_hook_events(socket: &Path, events: u64) -> io::Result<()> {
    let directory =
        existing_hook_spool_dir(socket)?.ok_or_else(|| io::Error::from(io::ErrorKind::NotFound))?;
    add_count(&directory.join(HOOK_SPOOL_UNDELIVERABLE_EVENTS), events)
}

fn add_dropped_events(directory: &Path, events: u64) -> io::Result<()> {
    add_count(&directory.join(HOOK_SPOOL_DROPPED_EVENTS), events)
}

fn add_count(path: &Path, events: u64) -> io::Result<()> {
    let mut file = open_spool_file(path)?;
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

/// The newlines in `file`, read in chunks (one line can be megabytes).
fn count_lines(file: &File) -> io::Result<u64> {
    let mut reader = io::BufReader::new(file);
    let mut count = 0_u64;
    loop {
        let chunk = reader.fill_buf()?;
        if chunk.is_empty() {
            return Ok(count);
        }
        count = count.saturating_add(chunk.iter().filter(|byte| **byte == b'\n').count() as u64);
        let consumed = chunk.len();
        reader.consume(consumed);
    }
}

fn remove_if_present(path: &Path) -> io::Result<()> {
    match std::fs::remove_file(path) {
        Err(error) if error.kind() != io::ErrorKind::NotFound => Err(error),
        _ => Ok(()),
    }
}

/// Without an inode to tell a deleted queue file from its replacement, a
/// hook could append to a file a sender just unlinked, after the provider
/// was told its event is safe: there is no queue, and hooks send directly.
#[cfg(all(test, not(unix)))]
mod platform_tests {
    use super::*;

    #[test]
    fn no_hook_queue_without_file_identity() {
        let root = std::env::temp_dir().join("cmux-hook-queue-no-identity");
        let error = hook_spool_dir(&root.join("s.sock")).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::Unsupported);
        assert!(existing_hook_spool_dir(&root.join("s.sock")).unwrap().is_none());
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
        let queue = |socket: &str, terminal: &str| {
            spool.join(format!(
                "{}.{}.jsonl",
                queue_prefix(&root.join(socket)),
                spool_name_part(terminal)
            ))
        };
        std::fs::write(queue("work.sock", "terminal_a"), "{}\n{}\n").unwrap();
        std::fs::write(queue("work.sock", "terminal_b"), "{}\n").unwrap();
        std::fs::write(queue("other.sock", "terminal_c"), "{}\n").unwrap();
        // A collision of escaped names: it must stay another session's queue.
        std::fs::write(queue("work_sock", "terminal_d"), "{}\n").unwrap();
        assert_eq!(HookQueueSnapshot::beside(&socket).queued_events, 3);

        assert_eq!(drop_session_hook_queues(&socket).unwrap(), 3);

        let mut left: Vec<_> = std::fs::read_dir(&spool)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        left.sort();
        let mut kept = vec![
            queue("other.sock", "terminal_c").file_name().unwrap().to_string_lossy().into_owned(),
            queue("work_sock", "terminal_d").file_name().unwrap().to_string_lossy().into_owned(),
            HOOK_SPOOL_DROPPED_EVENTS.to_owned(),
        ];
        kept.sort();
        assert_eq!(left, kept);
        let snapshot = HookQueueSnapshot::beside(&socket);
        assert_eq!((snapshot.queued_events, snapshot.reset_dropped_events), (0, 3));
        assert_eq!(HookQueueSnapshot::beside(&root.join("other.sock")).queued_events, 1);
        std::fs::remove_dir_all(root).unwrap();
    }

    /// reset-state and server-stats never read or delete in a queue
    /// directory that another user could have made or written.
    #[test]
    fn reset_and_stats_leave_a_shared_directory_alone() {
        use std::os::unix::fs::PermissionsExt as _;
        let root = private_dir();
        let socket = root.join("work.sock");
        let spool = root.join(HOOK_SPOOL_DIR);
        std::fs::create_dir(&spool).unwrap();
        let planted = spool.join(format!(
            "{}.{}.jsonl",
            queue_prefix(&socket),
            spool_name_part("terminal_a")
        ));
        std::fs::write(&planted, "{}\n").unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o777)).unwrap();

        assert!(drop_session_hook_queues(&socket).is_err());
        assert!(planted.exists(), "reset deleted a file in a shared directory");
        assert_eq!(HookQueueSnapshot::beside(&socket).queued_events, 0);
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
