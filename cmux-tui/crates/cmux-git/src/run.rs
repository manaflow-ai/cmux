//! Runs git for the git reads. The caller's own environment never redirects
//! git (every `GIT_*` variable is dropped), repository config never runs a
//! program (no fsmonitor, no hooks, no transport, so no lazy fetch in a
//! partial clone, and no `git diff` inside a submodule here; callers add
//! `--no-ext-diff`, `--no-textconv` and blank filter drivers through
//! `overrides`), pathspecs are literal, and each run has a deadline and
//! bounded output.

use std::io::{ErrorKind, Read};
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::Duration;

use wait_timeout::ChildExt;

/// The git every run starts, found on `PATH`. The diff sidecar starts the
/// same one, so the filter drivers a run blanks are the ones that git sees.
pub const PROGRAM: &str = "git";

/// The longest one run may take.
pub const DEADLINE: Duration = Duration::from_secs(20);
const MAX_STDERR_BYTES: usize = 16 * 1024;

pub struct GitOutput {
    pub stdout: Vec<u8>,
    /// Output past the caller's limit was read and dropped.
    pub truncated: bool,
}

#[derive(Debug)]
pub enum GitFailure {
    /// git ran and exited unsuccessfully; its stderr, trimmed.
    Exit(String),
    /// git could not be started or waited for.
    Unavailable(String),
    TimedOut,
}

impl GitFailure {
    pub fn reason(&self) -> String {
        match self {
            Self::Exit(stderr) if stderr.is_empty() => "git exited unsuccessfully".to_string(),
            Self::Exit(stderr) => stderr.clone(),
            Self::Unavailable(error) => format!("git could not run: {error}"),
            Self::TimedOut => format!("git did not finish within {} s", DEADLINE.as_secs()),
        }
    }
}

impl std::fmt::Display for GitFailure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.reason())
    }
}

impl std::error::Error for GitFailure {}

/// A config setting, as (key, value), that wins over every config file.
pub type Override = (String, String);

/// Runs `git <arguments>` in `directory` with `overrides` set.
pub fn run_git(
    directory: &Path,
    overrides: &[Override],
    arguments: &[&str],
    max_stdout: usize,
) -> Result<GitOutput, GitFailure> {
    run_git_within(directory, overrides, arguments, max_stdout, DEADLINE)
}

/// [`run_git`] that stops git after `deadline` (at most [`DEADLINE`]).
pub fn run_git_within(
    directory: &Path,
    overrides: &[Override],
    arguments: &[&str],
    max_stdout: usize,
    deadline: Duration,
) -> Result<GitOutput, GitFailure> {
    run(directory, overrides, arguments, max_stdout, deadline, None)
}

/// [`run_git_within`] for NUL-terminated output that keeps only the records
/// `keep` accepts, each still NUL-terminated. `max_kept` bounds the kept
/// records, so a long listing with few matches is never cut.
pub fn run_git_records_within(
    directory: &Path,
    overrides: &[Override],
    arguments: &[&str],
    max_kept: usize,
    deadline: Duration,
    keep: fn(&[u8]) -> bool,
) -> Result<GitOutput, GitFailure> {
    run(directory, overrides, arguments, max_kept, deadline, Some(keep))
}

fn run(
    directory: &Path,
    overrides: &[Override],
    arguments: &[&str],
    max_stdout: usize,
    deadline: Duration,
    keep: Option<fn(&[u8]) -> bool>,
) -> Result<GitOutput, GitFailure> {
    let deadline = deadline.min(DEADLINE);
    if deadline.is_zero() {
        return Err(GitFailure::TimedOut);
    }
    let mut command = Command::new(PROGRAM);
    confine_read(&mut command, overrides);
    command.args(["-c", "core.quotePath=false"]);
    command
        .args(arguments)
        .current_dir(directory)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
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
    // Both are piped above; a missing one is a spawn failure, not a panic.
    let (Some(stdout), Some(stderr)) = (child.stdout.take(), child.stderr.take()) else {
        stop(&mut child);
        return Err(GitFailure::Unavailable("git output pipes are missing".to_string()));
    };
    let stdout = thread::spawn(move || match keep {
        Some(keep) => drain_records(stdout, max_stdout, keep),
        None => drain(stdout, max_stdout),
    });
    let stderr = thread::spawn(move || drain(stderr, MAX_STDERR_BYTES));
    let status = match child.wait_timeout(deadline) {
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
        return Err(GitFailure::Exit(explained(String::from_utf8_lossy(&stderr).trim())));
    }
    Ok(GitOutput { stdout, truncated })
}

/// Confines `command`, a git that only reads, so neither the caller's
/// environment nor repository config makes it run a program or reach a
/// remote: every inherited `GIT_*` variable is dropped, fsmonitor, hooks,
/// signature checks and submodule inline diffs are off, the attributes and
/// order files are never read, `overrides` (blanked filter drivers, from
/// [`crate::Repository`]) are set, and every transport is refused. A diff
/// still needs `--no-ext-diff` and `--no-textconv`. Call it before adding
/// arguments: the settings are `-c` options, which precede the subcommand.
/// The diff sidecar confines its own git runs with it too.
pub fn confine_read(command: &mut Command, overrides: &[Override]) {
    for (name, _) in std::env::vars_os() {
        if name.as_encoded_bytes().starts_with(b"GIT_") {
            command.env_remove(name);
        }
    }
    // `log.showSignature` would print signature checks into parsed output
    // and run the signing program.
    command.args(["-c", "core.fsmonitor=false", "-c", "log.showSignature=false"]);
    // A diff or status that refreshes a stale index writes it, and each
    // write runs `post-index-change` from `.git/hooks` (no config needed)
    // or `core.hooksPath`. As a `-c` setting this reaches the git run inside
    // a submodule too.
    command.args(["-c", "core.hooksPath=/dev/null"]);
    // `diff.submodule=diff` would run `git diff` inside a submodule, with
    // the submodule's own diff drivers.
    command.args(["-c", "diff.submodule=short"]);
    // Files every diff or status reads to the end: `/dev/zero` would be read
    // until the deadline.
    command.args(["-c", "core.attributesFile=/dev/null", "-c", "diff.orderFile=/dev/null"]);
    set_overrides(command, overrides);
    deny_transports(command);
    command.env("GIT_TERMINAL_PROMPT", "0");
}

/// Sets `overrides` through `GIT_CONFIG_COUNT`, which keeps a key whole: a
/// `-c key=value` argument splits at the first `=`, so a filter driver named
/// `a=b` could never be blanked that way. git passes them on to the git it
/// runs inside a submodule. On the same key, a `-c` setting beats a pair
/// here, so the runners' fixed `-c` settings always win.
pub(crate) fn set_overrides(command: &mut Command, overrides: &[Override]) {
    command.env("GIT_CONFIG_COUNT", overrides.len().to_string());
    for (index, (key, value)) in overrides.iter().enumerate() {
        command.env(format!("GIT_CONFIG_KEY_{index}"), key);
        command.env(format!("GIT_CONFIG_VALUE_{index}"), value);
    }
}

/// No run reaches a remote: a missing object in a partial clone would be
/// fetched on demand through the repository's `core.sshCommand` or an
/// `ext::` URL. An empty `GIT_ALLOW_PROTOCOL` refuses every transport and
/// outranks `protocol.<name>.allow` in repository config, which
/// `protocol.allow=never` does not; `GIT_NO_LAZY_FETCH` (git 2.45 and later)
/// stops git before it tries.
pub(crate) fn deny_transports(command: &mut Command) {
    command.env("GIT_NO_LAZY_FETCH", "1").env("GIT_ALLOW_PROTOCOL", "");
}

/// git's stderr, with a partial clone's missing object said plainly: git
/// names a fetch that [`deny_transports`] never lets it make.
fn explained(stderr: &str) -> String {
    if stderr.contains("lazy fetching disabled") || stderr.contains("from promisor remote") {
        let detail = stderr.lines().last().unwrap_or_default();
        format!(
            "an object this read needs is not available locally in this partial clone, \
             and cmux never fetches it ({detail})"
        )
    } else {
        stderr.to_string()
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

/// The longest record [`drain_records`] looks at; a longer one is no path
/// and is dropped.
const MAX_RECORD_BYTES: usize = 64 * 1024;

/// Reads NUL-terminated records to the end, keeping those `keep` accepts up
/// to `limit` bytes.
fn drain_records(mut reader: impl Read, limit: usize, keep: fn(&[u8]) -> bool) -> (Vec<u8>, bool) {
    let mut kept = Vec::new();
    let mut truncated = false;
    let mut record = Vec::new();
    let mut oversized = false;
    let mut accept = |record: &[u8], kept: &mut Vec<u8>| {
        if !keep(record) {
            return;
        }
        if kept.len() + record.len() + 1 > limit {
            truncated = true;
        } else {
            kept.extend_from_slice(record);
            kept.push(0);
        }
    };
    let mut chunk = [0_u8; 16 * 1024];
    loop {
        match reader.read(&mut chunk) {
            Ok(0) => break,
            Ok(read) => {
                for &byte in &chunk[..read] {
                    if byte == 0 {
                        if !oversized {
                            accept(&record, &mut kept);
                        }
                        record.clear();
                        oversized = false;
                    } else if record.len() < MAX_RECORD_BYTES {
                        record.push(byte);
                    } else {
                        oversized = true;
                    }
                }
            }
            Err(error) if error.kind() == ErrorKind::Interrupted => {}
            Err(_) => break,
        }
    }
    if !record.is_empty() && !oversized {
        accept(&record, &mut kept);
    }
    (kept, truncated)
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
