//! A child of a test whose program name the system cuts inside a character
//! (tests only, Linux).
//!
//! The system keeps 15 bytes of a program's name. A name of 8 characters of
//! 2 bytes each is cut in the middle of the last one, so the line
//! `/proc/<pid>/stat` of this child is not UTF-8.

use std::io;
use std::path::{Path, PathBuf};

use cmux_process::{Child, Command};

/// The child. When this value drops, the child ends, is reaped and loses its
/// folder.
#[derive(Debug)]
pub struct CutNameChild {
    child: Child,
    dir: PathBuf,
}

impl CutNameChild {
    /// Starts the child in a process group of its own. `label` names the
    /// test in the name of the folder.
    ///
    /// # Errors
    ///
    /// When the folder, the link or the child cannot be made, or when the
    /// system did not cut the name of the child inside a character.
    pub fn start(label: &str) -> io::Result<Self> {
        let dir =
            std::env::temp_dir().join(format!("cmux-cut-name-{label}-{}", std::process::id()));
        // An earlier process with this id can have left its folder.
        let _ = std::fs::remove_dir_all(&dir);
        match spawn_in(&dir) {
            Ok(child) => {
                let started = Self { child, dir };
                // The name that the system keeps ends in a part of a character.
                let name =
                    crate::process_identity::identity(started.id()).map(|process| process.name);
                if name.is_some_and(|name| name.ends_with(char::REPLACEMENT_CHARACTER)) {
                    Ok(started)
                } else {
                    Err(io::Error::other("the name of the child was not cut inside a character"))
                }
            }
            Err(error) => {
                let _ = std::fs::remove_dir_all(&dir);
                Err(error)
            }
        }
    }

    /// The process id of the child.
    pub fn id(&self) -> u32 {
        self.child.id()
    }

    /// Ends the child and waits for its end with no reap: the child stays in
    /// the process table as an ended process until this value drops.
    ///
    /// # Errors
    ///
    /// When the signal or the wait fails.
    pub fn end_unreaped(&mut self) -> io::Result<()> {
        self.child.kill()?;
        let mut info = std::mem::MaybeUninit::<libc::siginfo_t>::zeroed();
        // SAFETY: waitid writes one siginfo_t for this child, which this
        // process started and did not reap.
        let waited = unsafe {
            libc::waitid(libc::P_PID, self.id(), info.as_mut_ptr(), libc::WEXITED | libc::WNOWAIT)
        };
        if waited == 0 { Ok(()) } else { Err(io::Error::last_os_error()) }
    }
}

impl Drop for CutNameChild {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// Makes the folder and the link in it, and starts the program by the link.
fn spawn_in(dir: &Path) -> io::Result<Child> {
    std::fs::create_dir_all(dir)?;
    // 8 characters of 2 bytes: byte 15 is the first half of the last one.
    let program = dir.join("\u{e9}".repeat(8));
    std::os::unix::fs::symlink("/bin/sleep", &program)?;
    Command::new(&program).arg0("sleep").arg("30").process_group(0).spawn()
}
