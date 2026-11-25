//! A daemon under a service manager keeps its own bounded `daemon.log` too.
//!
//! Started by the CLI, the daemon's stdout is `<home>/daemon.log`. Under systemd it is the
//! journal (neither the unit acpmux writes nor a hand-written one names `StandardOutput`), so the
//! home's `daemon.log` stopped at the day a host moved to a unit, and a daemon that hung left its
//! evidence only where journald kept it: journald rate-limits a unit that logs fast and rotates by
//! the whole system's volume (2026-11-20: a supervised home's `daemon.log` last written
//! 2026-10-14, its daemon then grown to 4.4 GB and silent).
//!
//! Now, when systemd started the daemon (`INVOCATION_ID`) and its stdout is not that file, each
//! line also goes to `daemon.log` in its home ([`Kept`]): at [`CAP`] bytes the file moves to
//! `daemon.log.1` (replacing the one before) and a new one starts, so the home holds at most twice
//! [`CAP`]. Lines are written on the log writer thread (`log_sink.rs`), never where they are
//! logged, and a write that fails drops the file's copy of the line, never the stdout one.

use std::io::Write;
use std::path::{Path, PathBuf};

/// The size past which the kept log moves aside.
pub const CAP: u64 = 16 << 20;

/// `daemon.log` in `home`, written beside stdout: [`Kept::open`] when the daemon runs under
/// systemd and its stdout is not that file.
pub struct Kept {
    path: PathBuf,
    file: Option<std::fs::File>,
    len: u64,
    cap: u64,
}

impl Kept {
    /// The kept log for a daemon of `home`, when it runs under a service manager whose output is
    /// elsewhere; `None` when its stdout is the log already, or it runs under none.
    pub fn for_service(home: &Path) -> Option<Self> {
        std::env::var_os("INVOCATION_ID")?;
        let path = home.join("daemon.log");
        if stdout_is(&path) {
            return None;
        }
        Some(Self::open(path, CAP))
    }

    /// The log at `path`, moved aside past `cap` bytes.
    pub fn open(path: PathBuf, cap: u64) -> Self {
        let mut kept = Self { path, file: None, len: 0, cap };
        kept.reopen();
        kept
    }

    fn reopen(&mut self) {
        self.file = crate::config::private_state_append(&self.path).ok();
        self.len = self.file.as_ref().and_then(|f| f.metadata().ok()).map_or(0, |m| m.len());
    }

    fn rotate(&mut self) {
        self.file = None;
        let _ = crate::home_fs::rename(&self.path, self.path.with_extension("log.1"));
        self.reopen();
    }
}

impl Write for Kept {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        if self.file.is_none() {
            // A write or open failed before: try the file again.
            self.reopen();
        } else if self.len > 0 && self.len.saturating_add(buf.len() as u64) > self.cap {
            self.rotate();
        }
        if let Some(file) = self.file.as_mut() {
            match file.write_all(buf) {
                Ok(()) => self.len += buf.len() as u64,
                Err(_) => self.file = None,
            }
        }
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// Stdout, then the kept log when there is one: the log writer thread's output.
pub struct Tee<W> {
    pub out: W,
    pub kept: Option<Kept>,
}

impl<W: Write> Write for Tee<W> {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let n = self.out.write(buf)?;
        if let Some(kept) = self.kept.as_mut() {
            let _ = kept.write_all(&buf[..n]);
        }
        Ok(n)
    }

    fn write_all(&mut self, buf: &[u8]) -> std::io::Result<()> {
        // The kept copy is written even when stdout fails (a journal that went away).
        let out = self.out.write_all(buf);
        if let Some(kept) = self.kept.as_mut() {
            let _ = kept.write_all(buf);
        }
        out
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.out.flush()
    }
}

/// Whether this process's stdout is the file at `path`.
#[cfg(unix)]
fn stdout_is(path: &Path) -> bool {
    use std::os::unix::fs::MetadataExt;
    let Ok(meta) = std::fs::metadata(path) else { return false };
    // SAFETY: `fstat` writes into the zeroed struct it is given and only reads fd 1.
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    (unsafe { libc::fstat(libc::STDOUT_FILENO, &mut st) } == 0)
        && st.st_dev as u64 == meta.dev()
        && st.st_ino as u64 == meta.ino()
}

#[cfg(not(unix))]
fn stdout_is(_path: &Path) -> bool {
    false
}

#[cfg(test)]
#[path = "log_keep_tests.rs"]
mod tests;
