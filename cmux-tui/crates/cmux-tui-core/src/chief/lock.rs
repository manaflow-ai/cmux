//! The `$MUX_HOME` host lock (plans/cmux-next/chief-mac.md section 2), the
//! same protocol as the TypeScript host (`mux/host/src/lock.ts`): one holder
//! at a time, enforced by an exclusive flock(2) on `state/host.lock` that the
//! holder keeps for its whole life. The kernel drops it when the holder ends,
//! however it ends. The file is never removed; its text
//! `<pid>\n<start ms>\nflock\n` is diagnostics only, and the `flock` mark line
//! tells a TypeScript host that a kernel-lock host wrote it.

use std::fs::{File, OpenOptions, TryLockError};
use std::io::{self, Read, Write};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

/// Marks a lock file written by a kernel-lock host.
const FLOCK_MARK: &str = "flock";
/// `ps` truncates start times to whole seconds; the TypeScript check uses the same slack.
const START_SLACK_MS: f64 = 1_000.0;

/// A held host lock. Dropping it closes the file, which drops the flock.
#[derive(Debug)]
pub struct HostLock {
    _file: File,
}

#[derive(Debug)]
pub enum LockError {
    /// Another open file holds the flock (a TypeScript or Rust host).
    Held,
    /// An older host holds the lock by file text only (upgrade check).
    OlderHost(u32),
    Io(io::Error),
}

impl std::fmt::Display for LockError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Held => formatter.write_str("another Chief host holds the lock"),
            Self::OlderHost(pid) => {
                write!(
                    formatter,
                    "an older Chief host (pid {pid}) holds the lock without a kernel lock"
                )
            }
            Self::Io(error) => write!(formatter, "host lock: {error}"),
        }
    }
}

impl std::error::Error for LockError {}

impl From<io::Error> for LockError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

/// Takes the lock at `path`. std opens files close-on-exec, so no child
/// (the acpmux hub outlives the host) inherits the descriptor.
pub fn take(path: &Path) -> Result<HostLock, LockError> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut file = open(path)?;
    match file.try_lock() {
        Ok(()) => {}
        Err(TryLockError::WouldBlock) => return Err(LockError::Held),
        Err(TryLockError::Error(error)) => return Err(LockError::Io(error)),
    }
    // The check reads the text the previous holder left; a failure refuses.
    if let Some(pid) = older_host(&mut file)? {
        return Err(LockError::OlderHost(pid));
    }
    // Diagnostics only: a failed write keeps the lock.
    let _ = write_text(&mut file);
    Ok(HostLock { _file: file })
}

#[cfg(unix)]
fn open(path: &Path) -> io::Result<File> {
    use std::os::unix::fs::OpenOptionsExt;
    OpenOptions::new().read(true).append(true).create(true).mode(0o644).open(path)
}

#[cfg(not(unix))]
fn open(path: &Path) -> io::Result<File> {
    OpenOptions::new().read(true).append(true).create(true).open(path)
}

fn write_text(file: &mut File) -> io::Result<()> {
    file.set_len(0)?;
    let started = own_start_ms();
    // Append mode writes at the end, which is offset 0 after the truncate.
    file.write_all(format!("{}\n{started}\n{FLOCK_MARK}\n", std::process::id()).as_bytes())
}

/// Upgrade check, REMOVE AFTER ONE RELEASE (chief-mac.md section 2). Older
/// hosts held this lock by text only (`<pid>` or `<pid>\n<start ms>`). When
/// the text has no `flock` mark and names a live process that started no
/// later than the recorded start (the file mtime for pid-only text) plus 1 s,
/// that older host still runs: its pid. An unknown start counts as running.
fn older_host(file: &mut File) -> io::Result<Option<u32>> {
    let mut text = String::new();
    if file.read_to_string(&mut text).is_err() {
        return Ok(None);
    }
    let lines: Vec<&str> = text.trim().split('\n').collect();
    if lines.contains(&FLOCK_MARK) {
        return Ok(None);
    }
    let Some(pid) = lines.first().and_then(|line| line.parse::<u32>().ok()) else {
        return Ok(None);
    };
    if pid == 0 || pid == std::process::id() || !is_alive(pid) {
        return Ok(None);
    }
    let recorded = match lines.get(1) {
        Some(line) => match line.parse::<f64>() {
            Ok(ms) if ms.is_finite() => ms,
            _ => return Ok(None),
        },
        None => mtime_ms(file)?,
    };
    Ok(match process_start_ms(pid) {
        Some(started) if started > recorded + START_SLACK_MS => None,
        _ => Some(pid),
    })
}

fn mtime_ms(file: &File) -> io::Result<f64> {
    let modified = file.metadata()?.modified()?;
    Ok(modified.duration_since(UNIX_EPOCH).map_or(0.0, |elapsed| elapsed.as_secs_f64() * 1_000.0))
}

fn own_start_ms() -> u64 {
    process_start_ms(std::process::id()).map_or_else(
        || {
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_or(0, |elapsed| elapsed.as_millis() as u64)
        },
        |ms| ms as u64,
    )
}

#[cfg(unix)]
fn is_alive(pid: u32) -> bool {
    let Ok(pid) = libc::pid_t::try_from(pid) else { return false };
    // SAFETY: signal 0 only checks that the process exists.
    let result = unsafe { libc::kill(pid, 0) };
    result == 0 || io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

#[cfg(not(unix))]
fn is_alive(_pid: u32) -> bool {
    false
}

/// The process's OS start time in ms since the epoch (macOS only).
#[cfg(target_os = "macos")]
fn process_start_ms(pid: u32) -> Option<f64> {
    let pid = libc::c_int::try_from(pid).ok()?;
    let mut info = std::mem::MaybeUninit::<libc::proc_bsdinfo>::zeroed();
    let size = libc::c_int::try_from(size_of::<libc::proc_bsdinfo>()).ok()?;
    // SAFETY: proc_pidinfo writes at most `size` bytes into `info`.
    let written = unsafe {
        libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, info.as_mut_ptr().cast(), size)
    };
    if written != size {
        return None;
    }
    // SAFETY: proc_pidinfo initialized the whole structure.
    let info = unsafe { info.assume_init() };
    Some(info.pbi_start_tvsec as f64 * 1_000.0 + info.pbi_start_tvusec as f64 / 1_000.0)
}

#[cfg(not(target_os = "macos"))]
fn process_start_ms(_pid: u32) -> Option<f64> {
    None
}
