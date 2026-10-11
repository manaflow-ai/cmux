//! Runs git for the git reads. The daemon's own environment never redirects
//! git (every `GIT_*` variable is dropped), repository config never runs a
//! program (no fsmonitor here; callers add `--no-ext-diff`, `--no-textconv`
//! and blank filter drivers through `overrides`), pathspecs are literal, and
//! each run has a deadline and bounded output.

use std::io::{ErrorKind, Read};
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::Duration;

use wait_timeout::ChildExt;

const DEADLINE: Duration = Duration::from_secs(20);
const MAX_STDERR_BYTES: usize = 16 * 1024;

pub(super) struct GitOutput {
    pub stdout: Vec<u8>,
    /// Output past the caller's limit was read and dropped.
    pub truncated: bool,
}

#[derive(Debug)]
pub(super) enum GitFailure {
    /// git ran and exited unsuccessfully; its stderr, trimmed.
    Exit(String),
    /// git could not be started or waited for.
    Unavailable(String),
    TimedOut,
}

impl GitFailure {
    pub(super) fn reason(&self) -> String {
        match self {
            Self::Exit(stderr) if stderr.is_empty() => "git exited unsuccessfully".to_string(),
            Self::Exit(stderr) => stderr.clone(),
            Self::Unavailable(error) => format!("git could not run: {error}"),
            Self::TimedOut => format!("git did not finish within {} s", DEADLINE.as_secs()),
        }
    }
}

/// Runs `git -c <override>... <arguments>` in `directory`; `overrides` are
/// `key=value` config settings that win over every config file.
pub(super) fn run_git(
    directory: &Path,
    overrides: &[String],
    arguments: &[&str],
    max_stdout: usize,
) -> Result<GitOutput, GitFailure> {
    let mut command = Command::new("git");
    for (name, _) in std::env::vars_os() {
        if name.as_encoded_bytes().starts_with(b"GIT_") {
            command.env_remove(name);
        }
    }
    command.args(["-c", "core.fsmonitor=false", "-c", "core.quotePath=false"]);
    for setting in overrides {
        command.args(["-c", setting]);
    }
    command
        .args(arguments)
        .current_dir(directory)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("GIT_PAGER", "cat")
        // Client paths are file names, never pathspec magic such as `:(top)`.
        .env("GIT_LITERAL_PATHSPECS", "1")
        .env("LC_ALL", "C");
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    let mut child = command.spawn().map_err(|error| GitFailure::Unavailable(error.to_string()))?;
    let stdout = child.stdout.take().expect("git stdout is piped");
    let stderr = child.stderr.take().expect("git stderr is piped");
    let stdout = thread::spawn(move || drain(stdout, max_stdout));
    let stderr = thread::spawn(move || drain(stderr, MAX_STDERR_BYTES));
    let status = match child.wait_timeout(DEADLINE) {
        Ok(Some(status)) => status,
        Ok(None) => {
            stop(&mut child);
            let _ = stdout.join();
            let _ = stderr.join();
            return Err(GitFailure::TimedOut);
        }
        Err(error) => {
            stop(&mut child);
            let _ = stdout.join();
            let _ = stderr.join();
            return Err(GitFailure::Unavailable(error.to_string()));
        }
    };
    let (stdout, truncated) = stdout.join().unwrap_or_default();
    let (stderr, _) = stderr.join().unwrap_or_default();
    if !status.success() {
        return Err(GitFailure::Exit(String::from_utf8_lossy(&stderr).trim().to_string()));
    }
    Ok(GitOutput { stdout, truncated })
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
