//! Runs git for checkpoint capture, the sibling of the read runner. Every
//! inherited `GIT_*` variable is dropped and only an explicit temporary
//! `GIT_INDEX_FILE` is set, so the user's index is never the one written.
//! Hooks are off (`core.hooksPath` names an empty directory the owner
//! created, which also silences `reference-transaction`), fsmonitor is off,
//! no filter runs (callers hash raw bytes with `--no-filters` and blank every
//! filter driver through `overrides`), and git takes its real locks.
//!
//! Hashing and other preparation have a deadline; a write-critical step
//! (update-index, write-tree, mktree, commit-tree, update-ref) is never killed
//! midway.

use std::io::{ErrorKind, Read, Write};
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::Duration;

use wait_timeout::ChildExt;

use super::run::{GitFailure, GitOutput};

const MAX_STDERR_BYTES: usize = 16 * 1024;

/// How long a write run may take.
#[derive(Debug, Clone, Copy)]
pub(super) enum Bound {
    /// Preparation that writes nothing a reader depends on (hashing,
    /// listing): stopped with its process group past the deadline.
    Deadline(Duration),
    /// A write-critical step: waited for, never killed.
    Unbounded,
}

/// A repository's top level, its filter overrides and the owner's empty
/// hooks directory.
pub(super) struct WriteGit<'a> {
    pub root: &'a Path,
    pub overrides: &'a [String],
    pub hooks: &'a Path,
}

impl WriteGit<'_> {
    /// Runs `git <arguments>` with `stdin` as its input. `index`, when given,
    /// is the temporary index file the run reads and writes.
    pub(super) fn run(
        &self,
        index: Option<&Path>,
        arguments: &[&std::ffi::OsStr],
        stdin: &[u8],
        bound: Bound,
        max_stdout: usize,
    ) -> Result<GitOutput, GitFailure> {
        let mut command = Command::new("git");
        for (name, _) in std::env::vars_os() {
            if name.as_encoded_bytes().starts_with(b"GIT_") {
                command.env_remove(name);
            }
        }
        let mut hooks = std::ffi::OsString::from("core.hooksPath=");
        hooks.push(self.hooks.as_os_str());
        command.args(["-c", "core.fsmonitor=false", "-c", "core.quotePath=false", "-c"]);
        command.arg(hooks);
        command.args(["-c", "commit.gpgSign=false", "-c", "gc.auto=0"]);
        command.args(["-c", "maintenance.auto=false"]);
        for setting in self.overrides {
            command.args(["-c", setting]);
        }
        command
            .args(arguments)
            .current_dir(self.root)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .env("GIT_OPTIONAL_LOCKS", "0")
            .env("GIT_TERMINAL_PROMPT", "0")
            .env("GIT_PAGER", "cat")
            .env("GIT_LITERAL_PATHSPECS", "1")
            .env("GIT_AUTHOR_NAME", "cmux")
            .env("GIT_AUTHOR_EMAIL", "cmux@localhost")
            .env("GIT_COMMITTER_NAME", "cmux")
            .env("GIT_COMMITTER_EMAIL", "cmux@localhost")
            .env("LC_ALL", "C");
        if let Some(index) = index {
            command.env("GIT_INDEX_FILE", index);
        }
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            command.process_group(0);
        }
        let mut child =
            command.spawn().map_err(|error| GitFailure::Unavailable(error.to_string()))?;
        let mut input = child.stdin.take().expect("git stdin is piped");
        let stdout = child.stdout.take().expect("git stdout is piped");
        let stderr = child.stderr.take().expect("git stderr is piped");
        let bytes = stdin.to_vec();
        let writer = thread::spawn(move || {
            let _ = input.write_all(&bytes);
        });
        let stdout = thread::spawn(move || drain(stdout, max_stdout));
        let stderr = thread::spawn(move || drain(stderr, MAX_STDERR_BYTES));
        let waited = match bound {
            Bound::Deadline(deadline) => child.wait_timeout(deadline),
            Bound::Unbounded => child.wait().map(Some),
        };
        let status = match waited {
            Ok(Some(status)) => status,
            Ok(None) => {
                stop(&mut child);
                let _ = (writer.join(), stdout.join(), stderr.join());
                let seconds = match bound {
                    Bound::Deadline(deadline) => deadline.as_secs(),
                    Bound::Unbounded => 0,
                };
                return Err(GitFailure::Unavailable(format!(
                    "git did not finish within {seconds} s"
                )));
            }
            Err(error) => {
                stop(&mut child);
                let _ = (writer.join(), stdout.join(), stderr.join());
                return Err(GitFailure::Unavailable(error.to_string()));
            }
        };
        let _ = writer.join();
        let (stdout, truncated) = stdout.join().unwrap_or_default();
        let (stderr, _) = stderr.join().unwrap_or_default();
        if !status.success() {
            return Err(GitFailure::Exit(String::from_utf8_lossy(&stderr).trim().to_string()));
        }
        Ok(GitOutput { stdout, truncated })
    }
}

/// Kills git and anything it started, so the output pipes close.
fn stop(child: &mut Child) {
    #[cfg(unix)]
    if let Ok(group) = libc::pid_t::try_from(child.id()) {
        // SAFETY: `kill` takes plain integers; the group is the one git leads.
        unsafe {
            libc::kill(-group, libc::SIGKILL);
        }
    }
    let _ = child.kill();
    let _ = child.wait();
}

/// Reads to the end, keeping at most `limit` bytes so git never blocks on a
/// full pipe.
fn drain(mut reader: impl Read, limit: usize) -> (Vec<u8>, bool) {
    let mut kept = Vec::new();
    let mut truncated = false;
    let mut chunk = [0_u8; 16 * 1024];
    loop {
        match reader.read(&mut chunk) {
            Ok(0) => break,
            Ok(read) => {
                let room = limit.saturating_sub(kept.len());
                if read > room {
                    truncated = true;
                }
                kept.extend_from_slice(&chunk[..read.min(room)]);
            }
            Err(error) if error.kind() == ErrorKind::Interrupted => {}
            Err(_) => break,
        }
    }
    (kept, truncated)
}
