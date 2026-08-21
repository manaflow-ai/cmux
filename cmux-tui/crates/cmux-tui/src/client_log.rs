//! Bounded rolling client log.
//!
//! Every user-visible warning (status messages, toasts, durable provider
//! notices) and every client stderr diagnostic is appended here so problems
//! seen in the TUI survive the session and can be diagnosed later. The file
//! is size-bounded: when the active file passes [`MAX_ACTIVE_BYTES`] it is
//! renamed to `<name>.1` (replacing the previous rollover), so disk usage
//! never exceeds two files.
//!
//! Location: `platform::client_log_path()` — the cmux-tui state root, or the
//! `CMUX_TUI_LOG_FILE` override. Logging is best-effort and silent: a client
//! must never fail or spam the terminal because its log file is unavailable.

use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{SyncSender, sync_channel};
use std::time::{SystemTime, UNIX_EPOCH};

use cmux_tui_core::platform;

/// Set once the process's stderr (fd 2) feeds the log pump. From then on
/// `stderr_log!` skips its `eprintln!` echo (the pump would duplicate the
/// record). Only set when a redirect actually happened.
static STDERR_REDIRECTED: AtomicBool = AtomicBool::new(false);

/// Roll the active file after it passes this size. Two files are kept, so the
/// log never holds more than roughly twice this on disk.
const MAX_ACTIVE_BYTES: u64 = 2 * 1024 * 1024;

/// Bounded queue between callers (UI/render threads) and the writer thread.
/// Callers never touch the filesystem or any lock a disk stall can hold.
const QUEUE_CAPACITY: usize = 512;

struct Record {
    stamp: String,
    level: &'static str,
    area: String,
    message: String,
}

/// Cap on one record's message, so 512 queued records from unbounded input
/// (provider notices, remote status strings) hold kilobytes, not megabytes.
/// The stderr pump has its own per-line cap; this covers direct callers.
const MAX_MESSAGE_BYTES: usize = 4096;

/// Records dropped because the queue was full; the writer reports the count
/// when it next drains.
static DROPPED: AtomicU64 = AtomicU64::new(0);

enum Message {
    Record(Record),
    /// Ask the writer to confirm everything queued before this marker is on
    /// disk. The writer acks after draining; senders wait with a deadline.
    Flush(SyncSender<()>),
}

static QUEUE: OnceLock<Option<SyncSender<Message>>> = OnceLock::new();

fn queue() -> Option<&'static SyncSender<Message>> {
    QUEUE
        .get_or_init(|| {
            let mut sink = open_sink()?;
            let (sender, receiver) = sync_channel::<Message>(QUEUE_CAPACITY);
            std::thread::Builder::new()
                .name("client-log".into())
                .spawn(move || {
                    while let Ok(message) = receiver.recv() {
                        let record = match message {
                            Message::Record(record) => record,
                            Message::Flush(ack) => {
                                let _ = sink.file.flush();
                                let _ = ack.try_send(());
                                continue;
                            }
                        };
                        let dropped = DROPPED.swap(0, Ordering::AcqRel);
                        if dropped > 0 {
                            write_record(
                                &mut sink,
                                &Record {
                                    stamp: timestamp(),
                                    level: "WARN",
                                    area: "log".into(),
                                    message: format!("{dropped} records dropped (queue full)"),
                                },
                            );
                        }
                        write_record(&mut sink, &record);
                    }
                })
                .ok()?;
            // `std::process::exit` (usage errors, startup failures) skips
            // destructors but runs atexit handlers, so queued diagnostics
            // still reach disk on the paths this log exists for.
            #[cfg(unix)]
            unsafe {
                libc::atexit(flush_at_exit);
            }
            Some(sender)
        })
        .as_ref()
}

/// Drain the queue to disk, waiting at most `deadline`. Safe to call from
/// any thread, including the exiting one; never blocks unbounded.
#[cfg_attr(not(unix), allow(dead_code))]
fn flush_with_deadline(deadline: std::time::Duration) {
    let Some(sender) = QUEUE.get().and_then(|queue| queue.as_ref()) else {
        return;
    };
    let started = std::time::Instant::now();
    let (ack, done) = sync_channel::<()>(1);
    // A full queue means the writer is behind; give it the deadline to make
    // space rather than dropping the flush marker immediately.
    let mut marker = Message::Flush(ack);
    loop {
        match sender.try_send(marker) {
            Ok(()) => break,
            Err(std::sync::mpsc::TrySendError::Full(returned)) => {
                if started.elapsed() >= deadline {
                    return;
                }
                marker = returned;
                std::thread::sleep(std::time::Duration::from_millis(5));
            }
            Err(std::sync::mpsc::TrySendError::Disconnected(_)) => return,
        }
    }
    let remaining = deadline.saturating_sub(started.elapsed());
    let _ = done.recv_timeout(remaining);
}

#[cfg(unix)]
extern "C" fn flush_at_exit() {
    flush_with_deadline(std::time::Duration::from_millis(500));
}

struct Sink {
    file: File,
    path: PathBuf,
}

/// Append-mode open options for the log file. The log captures raw stderr
/// (panics, provider child output), which can carry credentials, so the file
/// is created owner-only on Unix.
fn append_options() -> OpenOptions {
    let mut options = OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options
}

fn open_sink() -> Option<Sink> {
    let path = platform::client_log_path()?;
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).ok()?;
    }
    let file = append_options().open(&path).ok()?;
    // Files created by older builds may be group/world readable; tighten them.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&path, fs::Permissions::from_mode(0o600));
    }
    Some(Sink { file, path })
}

/// Hold an exclusive advisory lock on the log file for one write+rotate
/// critical section. Several cmux-tui processes share one log; without
/// cross-process exclusion two writers can rotate at the same time, losing
/// records or leaving one process appending to an unlinked file forever.
/// Runs only on the writer thread, never on UI paths.
///
/// Unix only (flock). Off Unix there is no cross-process exclusion: the
/// no-op below makes logging single-process best-effort there - concurrent
/// processes may interleave or lose records, though the size bound still
/// holds because rotation falls back to truncating in place.
#[cfg(unix)]
fn lock_exclusive(file: &File) -> bool {
    use std::os::unix::io::AsRawFd;
    // SAFETY: flock on an owned, open descriptor.
    unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) == 0 }
}

#[cfg(unix)]
fn unlock(file: &File) {
    use std::os::unix::io::AsRawFd;
    // SAFETY: flock on an owned, open descriptor.
    unsafe {
        libc::flock(file.as_raw_fd(), libc::LOCK_UN);
    }
}

#[cfg(not(unix))]
fn lock_exclusive(_file: &File) -> bool {
    true
}

#[cfg(not(unix))]
fn unlock(_file: &File) {}

/// True when `file` is still the file at `path`. Another process rotating the
/// log renames the path away; a writer holding the old handle must reopen or
/// it appends to the rolled (eventually unlinked) file.
#[cfg(unix)]
fn handle_is_current(file: &File, path: &Path) -> bool {
    use std::os::unix::fs::MetadataExt;
    match (file.metadata(), fs::metadata(path)) {
        (Ok(open), Ok(on_disk)) => open.ino() == on_disk.ino() && open.dev() == on_disk.dev(),
        _ => false,
    }
}

#[cfg(not(unix))]
fn handle_is_current(_file: &File, path: &Path) -> bool {
    path.exists()
}

fn rollover_path(path: &Path) -> PathBuf {
    let mut name = path.file_name().map(|n| n.to_os_string()).unwrap_or_default();
    name.push(".1");
    path.with_file_name(name)
}

/// One record through the full multiprocess-safe path: lock, follow foreign
/// rotations, append, rotate past the cap, unlock. Writer-thread only.
fn write_record(sink: &mut Sink, record: &Record) {
    if !lock_exclusive(&sink.file) {
        return;
    }
    // Follow foreign rotations: reopen until the handle we hold locked IS the
    // file at the active path. Another process can rotate between our reopen
    // and relock, so revalidate under every new lock. Bounded retries - a
    // foreign rotation needs MAX_ACTIVE_BYTES of writes, so losing this race
    // repeatedly means something is wrong and the record is best dropped.
    let mut follows = 0;
    while !handle_is_current(&sink.file, &sink.path) {
        follows += 1;
        if follows > 5 {
            unlock(&sink.file);
            return;
        }
        let Ok(fresh) = append_options().open(&sink.path) else {
            unlock(&sink.file);
            return;
        };
        let old = std::mem::replace(&mut sink.file, fresh);
        unlock(&old);
        if !lock_exclusive(&sink.file) {
            return;
        }
    }
    let line = format!(
        "{} {:5} {}: {}\n",
        record.stamp,
        record.level,
        record.area,
        sanitize(&record.message)
    );
    if sink.file.write_all(line.as_bytes()).is_ok() {
        // The size comes from the handle, so every process's appends count
        // toward the cap, not just this one's.
        let size = sink.file.metadata().map(|meta| meta.len()).unwrap_or(0);
        if size >= MAX_ACTIVE_BYTES {
            let _ = sink.file.flush();
            let rolled = rollover_path(&sink.path);
            let mut rotated = fs::rename(&sink.path, &rolled).is_ok();
            if !rotated {
                // Windows refuses to replace an existing destination.
                let _ = fs::remove_file(&rolled);
                rotated = fs::rename(&sink.path, &rolled).is_ok();
            }
            if rotated {
                if let Ok(file) = append_options().open(&sink.path) {
                    let old = std::mem::replace(&mut sink.file, file);
                    unlock(&old);
                    return;
                }
            } else {
                // Keep the size bound even where rename keeps failing:
                // drop the old content in place.
                let _ = sink.file.set_len(0);
            }
        }
    }
    unlock(&sink.file);
}

/// The original stderr fd, saved before redirection so the terminal gets its
/// stderr back when the TUI exits. -1 when nothing is saved.
#[cfg(unix)]
static SAVED_STDERR: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(-1);

/// Route the process's stderr into the client log. Called when the TUI takes
/// ownership of the terminal: stray stderr writes (panics, libraries, child
/// processes) land in the log instead of corrupting the raw-mode screen.
///
/// fd 2 becomes the write end of a PIPE whose pump thread feeds each line
/// through the normal record path - so child-process output is sanitized and
/// counts toward the size cap instead of bypassing it, and rotation never
/// strands a writer on a rolled inode. No-op off Unix (the flag stays false,
/// so diagnostics keep echoing to stderr there).
pub(crate) fn redirect_stderr_into_log() {
    #[cfg(unix)]
    {
        use std::io::Read;
        use std::os::unix::io::FromRawFd;
        if STDERR_REDIRECTED.load(Ordering::Acquire) {
            return;
        }
        if queue().is_none() {
            return;
        }
        let mut fds = [0i32; 2];
        // SAFETY: plain pipe(2); both ends are owned below.
        if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
            return;
        }
        let (read_fd, write_fd) = (fds[0], fds[1]);
        if SAVED_STDERR.load(Ordering::Acquire) < 0 {
            // SAFETY: dup of a live fd; the duplicate is retained for restore.
            let saved = unsafe { libc::dup(2) };
            SAVED_STDERR.store(saved, Ordering::Release);
        }
        // SAFETY: dup2 onto fd 2 replaces stderr atomically; close the now
        // duplicated write end.
        unsafe {
            libc::dup2(write_fd, 2);
            libc::close(write_fd);
        }
        // SAFETY: read_fd is owned by this File from here on.
        let mut reader = unsafe { File::from_raw_fd(read_fd) };
        let spawned = std::thread::Builder::new()
            .name("stderr-pump".into())
            .spawn(move || {
                let mut buffer = [0u8; 4096];
                let mut pending = Vec::new();
                loop {
                    match reader.read(&mut buffer) {
                        Ok(0) | Err(_) => break,
                        Ok(read) => {
                            pending.extend_from_slice(&buffer[..read]);
                            while let Some(newline) = pending.iter().position(|byte| *byte == b'\n')
                            {
                                let line: Vec<u8> = pending.drain(..=newline).collect();
                                let text = String::from_utf8_lossy(&line);
                                let text = text.trim_end();
                                if !text.is_empty() {
                                    log("WARN", "stderr", text);
                                }
                            }
                            // Cap partial-line buffering; a binary stream must
                            // not grow this without bound.
                            if pending.len() > 64 * 1024 {
                                log("WARN", "stderr", &String::from_utf8_lossy(&pending));
                                pending.clear();
                            }
                        }
                    }
                }
            })
            .is_ok();
        if spawned {
            STDERR_REDIRECTED.store(true, Ordering::Release);
        } else {
            // Undo: put the terminal stderr back.
            let saved = SAVED_STDERR.load(Ordering::Acquire);
            if saved >= 0 {
                // SAFETY: restoring the saved fd onto 2.
                unsafe {
                    libc::dup2(saved, 2);
                }
            }
        }
    }
}

/// Undo `redirect_stderr_into_log` when the terminal is restored to the user.
pub(crate) fn restore_stderr_from_log() {
    if !STDERR_REDIRECTED.swap(false, Ordering::AcqRel) {
        return;
    }
    #[cfg(unix)]
    {
        let saved = SAVED_STDERR.load(Ordering::Acquire);
        if saved >= 0 {
            // SAFETY: restoring the saved terminal stderr onto fd 2. The pipe
            // write end this replaces was fd 2's only copy in this process,
            // so the pump sees EOF once children sharing it exit.
            unsafe {
                libc::dup2(saved, 2);
            }
        }
    }
}

/// Whether `stderr_log!` should still echo to stderr.
pub(crate) fn echo_to_stderr() -> bool {
    !STDERR_REDIRECTED.load(Ordering::Acquire)
}

/// UTC `YYYY-MM-DDTHH:MM:SSZ` from the system clock, no external crates.
fn timestamp() -> String {
    let secs = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    let days = (secs / 86_400) as i64;
    let tod = secs % 86_400;
    // Howard Hinnant's civil-from-days algorithm.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let year = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if month <= 2 { year + 1 } else { year };
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        tod / 3600,
        (tod % 3600) / 60,
        tod % 60
    )
}

/// One-line-per-record: control characters in the message collapse to spaces.
fn sanitize(message: &str) -> String {
    message
        .chars()
        .map(|c| if c.is_control() && c != '\t' { ' ' } else { c })
        .collect::<String>()
        .trim()
        .to_string()
}

/// Append one record. `area` names the subsystem ("status", "machine",
/// "startup", "provider", ...). Best-effort: errors are swallowed.
pub(crate) fn log(level: &'static str, area: &str, message: &str) {
    let Some(sender) = queue() else { return };
    let message = if message.len() > MAX_MESSAGE_BYTES {
        let mut end = MAX_MESSAGE_BYTES;
        while !message.is_char_boundary(end) {
            end -= 1;
        }
        format!("{} [truncated {} bytes]", &message[..end], message.len() - end)
    } else {
        message.to_string()
    };
    let record = Record { stamp: timestamp(), level, area: area.to_string(), message };
    // Never block a caller (status rendering runs on the UI thread): a full
    // queue drops the record and the writer reports the count.
    if sender.try_send(Message::Record(record)).is_err() {
        DROPPED.fetch_add(1, Ordering::AcqRel);
    }
}

pub(crate) fn warn(area: &str, message: &str) {
    log("WARN", area, message);
}

pub(crate) fn error(area: &str, message: &str) {
    log("ERROR", area, message);
}

pub(crate) fn info(area: &str, message: &str) {
    log("INFO", area, message);
}

/// Mirror a diagnostic to stderr and the client log. Use instead of bare
/// `eprintln!` in client code: while the TUI owns the terminal, stderr lines
/// corrupt the screen and vanish, but the log file keeps them.
macro_rules! stderr_log {
    ($area:expr, $($arg:tt)*) => {{
        let message = format!($($arg)*);
        if $crate::client_log::echo_to_stderr() {
            eprintln!("{message}");
        }
        $crate::client_log::warn($area, &message);
    }};
}
pub(crate) use stderr_log;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timestamps_are_iso_utc() {
        let stamp = timestamp();
        assert_eq!(stamp.len(), 20, "{stamp}");
        assert!(stamp.ends_with('Z'));
        assert_eq!(&stamp[4..5], "-");
        assert_eq!(&stamp[10..11], "T");
    }

    #[test]
    fn sanitize_collapses_control_characters() {
        assert_eq!(sanitize("a\nb\x1b[31mc\t d "), "a b [31mc\t d");
    }

    #[cfg(unix)]
    #[test]
    fn log_file_is_created_owner_only() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("cmux-tui-log-mode-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("client.log");
        let _ = fs::remove_file(&path);
        drop(append_options().open(&path).unwrap());
        let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        fs::remove_file(&path).unwrap();
        let _ = fs::remove_dir(&dir);
        assert_eq!(mode, 0o600, "log must not be readable by other users");
    }

    #[test]
    fn oversized_messages_are_truncated_before_enqueue() {
        // Mirrors the cap logic in `log` (which needs a live queue): the
        // boundary walk must never split a multi-byte character.
        // One ASCII byte then 4-byte chars, so byte 4096 is mid-character
        // and the walk must step back to the previous boundary.
        let message = format!("a{}", "\u{1F600}".repeat(2000));
        let mut end = MAX_MESSAGE_BYTES;
        while !message.is_char_boundary(end) {
            end -= 1;
        }
        assert_eq!(end, 4093);
        assert!(message.is_char_boundary(end));
    }

    #[test]
    fn rollover_appends_suffix() {
        assert_eq!(
            rollover_path(&PathBuf::from("/x/client.log")),
            PathBuf::from("/x/client.log.1")
        );
    }
}
