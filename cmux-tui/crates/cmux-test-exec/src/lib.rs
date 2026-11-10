//! Executable files that a test writes and then runs at once.
//!
//! Linux refuses to exec a file that some process still holds open for
//! writing (`ETXTBSY`, "text file busy"). A test that writes a script with
//! `std::fs::write` holds a write descriptor for a moment. When another test
//! thread forks in that moment, the forked child inherits the descriptor and
//! keeps it until it calls exec, so the test's own exec of the script can fail.
//! `O_CLOEXEC` does not help (the child has not exec'd yet), and neither does
//! a write to a temporary name plus rename (the child holds the same inode).
//!
//! The functions here never open a write descriptor in the test process: a
//! short-lived `/bin/sh` child writes the file and exits before they return.
//! A fork of the test process at any time therefore cannot hold the file open.
//!
//! ```no_run
//! let script = std::env::temp_dir().join("fake-tool");
//! cmux_test_exec::write_executable(&script, "#!/bin/sh\necho ok\n").unwrap();
//! let output = std::process::Command::new(&script).output().unwrap();
//! assert!(output.status.success());
//! ```

use std::io;
use std::path::Path;

/// Writes `contents` to `path` as an executable file (mode 0755).
///
/// The test process never holds a write descriptor to `path`, so it can exec
/// the file at once even while other test threads fork.
///
/// # Errors
///
/// Returns the error of the write.
pub fn write_executable(path: &Path, contents: impl AsRef<[u8]>) -> io::Result<()> {
    write_executable_with(path, contents.as_ref(), || {})
}

/// [`write_executable`] that runs `while_writing` while the write is in
/// progress (a test seam: a test forks there to force the race).
fn write_executable_with(
    path: &Path,
    contents: &[u8],
    while_writing: impl FnOnce(),
) -> io::Result<()> {
    use std::io::Write;
    #[cfg(unix)]
    use std::os::unix::fs::OpenOptionsExt;

    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    options.mode(0o755);
    let mut file = options.open(path)?;
    file.write_all(contents)?;
    while_writing();
    drop(file);
    Ok(())
}

/// Copies the executable `from` to `to` (mode 0755) the way
/// [`write_executable`] writes one: no write descriptor in the test process.
///
/// # Errors
///
/// Returns the error of the read or the write.
pub fn copy_executable(from: &Path, to: &Path) -> io::Result<()> {
    write_executable(to, std::fs::read(from)?)
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;
    use std::process::Command;

    /// A forked child that never execs: it holds every descriptor the test
    /// process had open at the fork until the test kills it.
    struct HeldFork(libc::pid_t);

    impl HeldFork {
        fn start() -> Self {
            // SAFETY: the child calls only async-signal-safe functions
            // (`pause`) until the parent kills it.
            let pid = unsafe { libc::fork() };
            assert!(pid >= 0, "fork failed: {}", std::io::Error::last_os_error());
            if pid == 0 {
                loop {
                    // SAFETY: async-signal-safe; the parent ends this child.
                    unsafe { libc::pause() };
                }
            }
            Self(pid)
        }
    }

    impl Drop for HeldFork {
        fn drop(&mut self) {
            // SAFETY: the pid is our own unreaped child.
            unsafe {
                libc::kill(self.0, libc::SIGKILL);
                libc::waitpid(self.0, std::ptr::null_mut(), 0);
            }
        }
    }

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir =
            std::env::temp_dir().join(format!("cmux-test-exec-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// Another test thread forks while the script is being written: the
    /// script still runs at once.
    #[test]
    fn a_fork_during_the_write_does_not_make_the_script_busy() {
        let dir = scratch("fork-during-write");
        let script = dir.join("tool");
        let mut held = None;
        write_executable_with(&script, b"#!/bin/sh\necho ran\n", || {
            held = Some(HeldFork::start());
        })
        .unwrap();

        let output = Command::new(&script).output();
        drop(held);

        let output = output.unwrap_or_else(|error| {
            panic!("the just-written script did not run while a fork was alive: {error}")
        });
        assert_eq!(String::from_utf8_lossy(&output.stdout), "ran\n");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_copied_executable_runs_with_mode_0755() {
        use std::os::unix::fs::PermissionsExt;
        let dir = scratch("copy");
        let source = dir.join("source");
        write_executable(&source, "#!/bin/sh\necho copied\n").unwrap();
        let copy = dir.join("copy");
        copy_executable(&source, &copy).unwrap();
        let mode = std::fs::metadata(&copy).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o755);
        let output = Command::new(&copy).output().unwrap();
        assert_eq!(String::from_utf8_lossy(&output.stdout), "copied\n");
        let _ = std::fs::remove_dir_all(dir);
    }
}
