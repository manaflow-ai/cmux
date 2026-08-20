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
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

use cmux_tui_core::platform;

/// Set once the process's stderr (fd 2) points at the log file. From then on
/// `stderr_log!` skips its `eprintln!` echo (it would duplicate the record),
/// while panics and library writes to stderr still land in the log.
static STDERR_REDIRECTED: AtomicBool = AtomicBool::new(false);

/// Roll the active file after it passes this size. Two files are kept, so the
/// log never holds more than roughly twice this on disk.
const MAX_ACTIVE_BYTES: u64 = 2 * 1024 * 1024;

struct Sink {
    file: File,
    path: PathBuf,
}

static SINK: OnceLock<Option<Mutex<Sink>>> = OnceLock::new();

fn open_sink() -> Option<Mutex<Sink>> {
    let path = platform::client_log_path()?;
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).ok()?;
    }
    let file = OpenOptions::new().create(true).append(true).open(&path).ok()?;
    Some(Mutex::new(Sink { file, path }))
}

/// Hold an exclusive advisory lock on the log file for one write+rotate
/// critical section. Several cmux-tui processes share one log; without
/// cross-process exclusion two writers can rotate at the same time, losing
/// records or leaving one process appending to an unlinked file forever.
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

/// Reopen the active file after this or another process rotated it, keeping a
/// redirected stderr pointed at the ACTIVE file.
fn reopen(sink: &mut Sink) -> bool {
    match OpenOptions::new().create(true).append(true).open(&sink.path) {
        Ok(file) => {
            sink.file = file;
            if STDERR_REDIRECTED.load(Ordering::Acquire) {
                point_stderr_at(&sink.file);
            }
            true
        }
        Err(_) => false,
    }
}

fn rollover_path(path: &Path) -> PathBuf {
    let mut name = path.file_name().map(|n| n.to_os_string()).unwrap_or_default();
    name.push(".1");
    path.with_file_name(name)
}

fn rotate_if_needed(sink: &mut Sink) {
    // The size comes from the handle, so every process's appends count
    // toward the cap, not just this one's.
    let size = sink.file.metadata().map(|meta| meta.len()).unwrap_or(0);
    if size < MAX_ACTIVE_BYTES {
        return;
    }
    let _ = sink.file.flush();
    let _ = fs::rename(&sink.path, rollover_path(&sink.path));
    let _ = reopen(sink);
}

#[cfg(unix)]
fn point_stderr_at(file: &File) {
    use std::os::unix::io::AsRawFd;
    // SAFETY: dup2 onto fd 2 replaces stderr atomically; both fds are owned
    // by this process and remain open.
    unsafe {
        libc::dup2(file.as_raw_fd(), 2);
    }
}

#[cfg(not(unix))]
fn point_stderr_at(_file: &File) {}

/// The original stderr fd, saved before redirection so the terminal gets its
/// stderr back when the TUI exits. -1 when nothing is saved.
static SAVED_STDERR: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(-1);

/// Route the process's stderr into the client log. Called when the TUI takes
/// ownership of the terminal: from then on stray stderr writes (panics,
/// libraries, child inheritance) land in the log instead of corrupting the
/// raw-mode screen.
pub(crate) fn redirect_stderr_into_log() {
    let Some(sink) = SINK.get_or_init(open_sink).as_ref() else { return };
    let Ok(sink) = sink.lock() else { return };
    #[cfg(unix)]
    if SAVED_STDERR.load(Ordering::Acquire) < 0 {
        // SAFETY: dup of a live fd; the duplicate is retained for restore.
        let saved = unsafe { libc::dup(2) };
        SAVED_STDERR.store(saved, Ordering::Release);
    }
    point_stderr_at(&sink.file);
    STDERR_REDIRECTED.store(true, Ordering::Release);
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
            // SAFETY: restoring the saved terminal stderr onto fd 2.
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
pub(crate) fn log(level: &str, area: &str, message: &str) {
    let Some(sink) = SINK.get_or_init(open_sink).as_ref() else { return };
    let Ok(mut sink) = sink.lock() else { return };
    if !lock_exclusive(&sink.file) {
        return;
    }
    // Another process may have rotated the file since the last write; follow
    // the rotation before appending, and re-lock the fresh handle.
    if !handle_is_current(&sink.file, &sink.path) {
        let old = std::mem::replace(
            &mut sink.file,
            match OpenOptions::new().create(true).append(true).open(&sink.path) {
                Ok(file) => file,
                Err(_) => return,
            },
        );
        unlock(&old);
        if STDERR_REDIRECTED.load(Ordering::Acquire) {
            point_stderr_at(&sink.file);
        }
        if !lock_exclusive(&sink.file) {
            return;
        }
    }
    let line = format!("{} {:5} {}: {}\n", timestamp(), level, area, sanitize(message));
    if sink.file.write_all(line.as_bytes()).is_ok() {
        rotate_if_needed(&mut sink);
    }
    unlock(&sink.file);
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

    #[test]
    fn rollover_appends_suffix() {
        assert_eq!(
            rollover_path(&PathBuf::from("/x/client.log")),
            PathBuf::from("/x/client.log.1")
        );
    }
}
