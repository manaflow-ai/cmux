//! The executable terminal hosts run from (cx-0tgl LF).
//!
//! A terminal host is a long-lived process; the app bundle it came from is
//! not. Tooling that owns a bundle (reload scripts, cleanup and age reapers,
//! `pkill -f "<app>.app"`, an agent's `pgrep -f <tag>`) used to match every
//! host by its executable path, and a rebuild that overwrote the bundle's
//! binary in place got hosts killed by code signing on the next page-in. On
//! macOS a host therefore runs from a content-addressed copy of the daemon's
//! executable in a per-user directory that names no tag and no bundle:
//! `~/Library/Application Support/cmux-tui/host-exe/<sha256>/cmux-tui`
//! (`CMUX_TUI_HOST_EXE_DIR` overrides the root). Linux hosts already exec
//! `/proc/self/exe` (no path in their argv, and a running binary cannot be
//! written), so this module only returns that there.
//!
//! Safety of the copy: the root and each `<sha256>` directory are `0700` and
//! owned by the user, or the copy is not used; the copy is written to a
//! temporary file (an APFS `clonefile`, else a plain copy, never a hard
//! link), made read-only, hashed, then renamed into place. Before every exec
//! the copy's identity (device, inode, size, times, mode, owner, link count)
//! must equal the one whose SHA-256 was verified; any change re-hashes it,
//! and a mismatch refuses the copy (the daemon's own executable is used and
//! the copy reinstalled).
//!
//! Lifetime: every daemon and host holds a shared `flock` on its copy's
//! `in-use.lock` for its whole life. A daemon that installs its copy deletes
//! the other copies whose lock it can take exclusively (no daemon or host
//! uses them), except the two newest. Deleting a file never stops a process
//! that runs it; a later daemon of that build installs it again.

use std::io;
use std::path::PathBuf;

/// The executable for a new terminal host: the verified copy on macOS, else
/// (or when the copy cannot be used) the daemon's own executable.
pub(crate) fn terminal_host_executable() -> io::Result<PathBuf> {
    imp::terminal_host_executable()
}

/// Hold the shared in-use lock of the copy this process runs from, if it
/// runs from one. A terminal host calls it once at start.
pub(crate) fn hold_in_use_lock() {
    imp::hold_in_use_lock();
}

/// Spawn a terminal host from [`terminal_host_executable`]. Its command line
/// is `cmux-tui __terminal-host ...` with no path, also when the daemon's own
/// executable is used. A spawn that fails from the copy is retried once from
/// the daemon's own executable, and the copy is not used again.
pub(crate) fn spawn_host(
    configure: impl Fn(&mut std::process::Command),
) -> io::Result<std::process::Child> {
    use std::os::unix::process::CommandExt;
    let binary = terminal_host_executable()?;
    let spawn = |binary: &std::path::Path| {
        let mut command = std::process::Command::new(binary);
        command.arg0("cmux-tui");
        configure(&mut command);
        command.spawn()
    };
    match spawn(&binary) {
        Err(error) if binary != crate::platform::self_exe_for_spawn()? => {
            imp::copy_failed(&binary);
            eprintln!("cmux-tui: a terminal host did not start from {}: {error}", binary.display());
            spawn(&crate::platform::self_exe_for_spawn()?)
        }
        result => result,
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    use std::io;
    use std::path::PathBuf;

    pub(super) fn terminal_host_executable() -> io::Result<PathBuf> {
        crate::platform::self_exe_for_spawn()
    }

    pub(super) fn hold_in_use_lock() {}

    pub(super) fn copy_failed(_path: &std::path::Path) {}
}

#[cfg(target_os = "macos")]
#[path = "host_exe/macos.rs"]
mod imp;
