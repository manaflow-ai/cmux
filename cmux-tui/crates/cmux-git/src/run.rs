//! Runs git for the git reads. The caller's own environment never redirects
//! git (every `GIT_*` variable is dropped), repository config never runs a
//! program (no fsmonitor, no hooks, no transport, so no lazy fetch in a
//! partial clone, and no `git diff` inside a submodule here; callers add
//! `--no-ext-diff`, `--no-textconv` and blank filter drivers through
//! `overrides`), pathspecs are literal, and each run has a deadline and
//! bounded output.

use std::cell::Cell;
use std::ffi::OsStr;
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
    run(directory, overrides, arguments, max_stdout, deadline, None, &[])
}

/// [`run_git_within`] whose new objects go to `scratch`, an empty folder the
/// caller owns and removes, never into the repository: `objects` (the
/// repository's object folder) is only read, as an alternate. For a read
/// that has to write to answer, `git merge-tree --write-tree`: run on every
/// worktree of a big repository, its trees were thousands of loose objects
/// in the shared object folder, each one a file event for every watcher of
/// the repository.
pub fn run_git_scratch_objects_within(
    directory: &Path,
    overrides: &[Override],
    arguments: &[&str],
    max_stdout: usize,
    deadline: Duration,
    objects: &Path,
    scratch: &Path,
) -> Result<GitOutput, GitFailure> {
    let alternate = alternate_entry(objects);
    let env = [
        ("GIT_OBJECT_DIRECTORY", scratch.as_os_str()),
        ("GIT_ALTERNATE_OBJECT_DIRECTORIES", alternate.as_os_str()),
    ];
    run(directory, overrides, arguments, max_stdout, deadline, None, &env)
}

/// `path` as one entry of `GIT_ALTERNATE_OBJECT_DIRECTORIES`, a
/// colon-separated list: C-quoted (git's `unquote_c_style`) when a `:`, a
/// quote, a backslash or a control character would otherwise split or bend
/// it.
#[cfg(unix)]
pub(crate) fn alternate_entry(path: &Path) -> std::ffi::OsString {
    use std::os::unix::ffi::{OsStrExt, OsStringExt};
    let bytes = path.as_os_str().as_bytes();
    let plain = !bytes.starts_with(b"\"")
        && !bytes.iter().any(|b| matches!(b, b':' | b'\\') || *b < 0x20 || *b == 0x7f);
    if plain {
        return path.as_os_str().to_os_string();
    }
    let mut quoted = vec![b'"'];
    for &byte in bytes {
        match byte {
            b'"' | b'\\' => quoted.extend([b'\\', byte]),
            0..0x20 | 0x7f => quoted.extend(format!("\\{byte:03o}").into_bytes()),
            _ => quoted.push(byte),
        }
    }
    quoted.push(b'"');
    std::ffi::OsString::from_vec(quoted)
}

#[cfg(not(unix))]
pub(crate) fn alternate_entry(path: &Path) -> std::ffi::OsString {
    path.as_os_str().to_os_string()
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
    run(directory, overrides, arguments, max_kept, deadline, Some(keep), &[])
}

thread_local! {
    static BACKGROUND: Cell<bool> = const { Cell::new(false) };
}

/// While held, every git this thread starts runs as background work: on
/// macOS `PRIO_DARWIN_BG` (lowest CPU priority, throttled disk I/O), elsewhere
/// nice 19. For housekeeping (the worktree cleanup pass) that would
/// otherwise compete with the person at the machine; ends when dropped.
#[must_use = "background work ends when the guard is dropped"]
pub struct Background {
    previous: bool,
}

/// Marks this thread's git runs as background work until the guard drops.
pub fn background() -> Background {
    Background { previous: BACKGROUND.with(|flag| flag.replace(true)) }
}

impl Drop for Background {
    fn drop(&mut self) {
        let previous = self.previous;
        BACKGROUND.with(|flag| flag.set(previous));
    }
}

/// Whether this thread holds a [`background`] guard.
pub fn in_background() -> bool {
    BACKGROUND.with(Cell::get)
}

/// Lowers `pid` (a process this thread just started) to background priority
/// when this thread holds a [`background`] guard. Best effort: a process
/// that has already exited only makes it fail.
pub fn lower_if_background(pid: u32) {
    if in_background() {
        lower(pid);
    }
}

#[cfg(target_os = "macos")]
fn lower(pid: u32) {
    // <sys/resource.h>: PRIO_DARWIN_PROCESS and PRIO_DARWIN_BG.
    const PRIO_DARWIN_PROCESS: libc::c_int = 4;
    const PRIO_DARWIN_BG: libc::c_int = 0x1000;
    // SAFETY: setpriority(2) on a child this process started.
    unsafe {
        libc::setpriority(PRIO_DARWIN_PROCESS, pid as libc::id_t, PRIO_DARWIN_BG);
    }
}

#[cfg(all(unix, not(target_os = "macos")))]
fn lower(pid: u32) {
    // SAFETY: setpriority(2) on a child this process started.
    unsafe {
        libc::setpriority(libc::PRIO_PROCESS as _, pid as libc::id_t, 19);
    }
}

#[cfg(not(unix))]
fn lower(_pid: u32) {}

fn run(
    directory: &Path,
    overrides: &[Override],
    arguments: &[&str],
    max_stdout: usize,
    deadline: Duration,
    keep: Option<fn(&[u8]) -> bool>,
    env: &[(&str, &OsStr)],
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
    // After `confine_read`, which drops every inherited `GIT_*` variable.
    command.envs(env.iter().copied());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    let mut child = command.spawn().map_err(|error| GitFailure::Unavailable(error.to_string()))?;
    lower_if_background(child.id());
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

#[cfg(test)]
mod background_tests {
    use super::*;

    #[cfg(unix)]
    #[test]
    fn an_alternate_with_a_colon_or_quote_is_c_quoted() {
        assert_eq!(alternate_entry(Path::new("/r/.git/objects")), "/r/.git/objects");
        assert_eq!(alternate_entry(Path::new("/r:copy/objects")), "\"/r:copy/objects\"");
        assert_eq!(alternate_entry(Path::new("/a\"b\\c\nd")), "\"/a\\\"b\\\\c\\012d\"");
    }

    #[test]
    fn background_holds_for_the_guard_and_this_thread_only() {
        assert!(!in_background());
        {
            let _outer = background();
            assert!(in_background());
            {
                let _inner = background();
            }
            assert!(in_background(), "an inner guard restores the outer one's state");
            assert!(!thread::spawn(in_background).join().unwrap());
        }
        assert!(!in_background());
    }
}
