//! The git runs: reads through `cmux-git`'s confined runner, writes through
//! its checkpoint runner (an owner-made empty hooks folder, no filter, no
//! transport, an explicit temporary index), and the two runs that need the
//! user's own git: `ls-remote` (the network) and `submodule update`.

use std::ffi::OsStr;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::Duration;

use cmux_git::run::{GitFailure, Override, run_git_scratch_objects_within, run_git_within};
use cmux_git::write_run::{Bound, WriteGit};

/// The longest one read takes (`cmux-git`'s own ceiling).
pub(crate) const READ: Duration = Duration::from_secs(20);
/// Hashing a worktree's files into a temporary index.
pub(crate) const HASH: Duration = Duration::from_secs(300);
/// The most a read returns; more is a refusal, never a cut listing.
pub(crate) const MAX_OUTPUT: usize = 64 << 20;
/// Path bytes per `git add` run, well inside argument limits.
pub(crate) const MAX_ARGUMENT_BYTES: usize = 96 * 1024;

/// `git <args>` in `dir`, its whole output.
pub(crate) fn read(dir: &Path, overrides: &[Override], args: &[&str]) -> Result<Vec<u8>, String> {
    let output = run_git_within(dir, overrides, args, MAX_OUTPUT, READ).map_err(reason)?;
    if output.truncated {
        return Err(format!("git {} printed more than {MAX_OUTPUT} bytes", args.join(" ")));
    }
    Ok(output.stdout)
}

/// [`read`] whose new objects go to a scratch folder, removed after, and
/// never into `objects` (the repository's object folder, read as an
/// alternate): `git merge-tree --write-tree` must write the trees it
/// prints, and in the shared object folder they piled up as loose objects.
/// `Ok(None)` when git exited unsuccessfully and said nothing on stderr
/// (merge-tree's conflict, with `--no-messages`); an error when it could
/// not run or finish, or said why it failed (a missing object, a full
/// disk): no answer, so asked again next time.
pub(crate) fn read_scratch_objects(
    dir: &Path,
    overrides: &[Override],
    objects: &Path,
    args: &[&str],
) -> Result<Option<Vec<u8>>, String> {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let scratch =
        std::env::temp_dir().join(format!("cmux-care-objects-{}-{n}", std::process::id()));
    // A crashed run's folder under a reused pid starts empty again.
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).map_err(|e| format!("{}: {e}", scratch.display()))?;
    let output =
        run_git_scratch_objects_within(dir, overrides, args, MAX_OUTPUT, READ, objects, &scratch);
    let _ = std::fs::remove_dir_all(&scratch);
    let output = match output {
        Ok(output) => output,
        Err(GitFailure::Exit(stderr)) if stderr.is_empty() => return Ok(None),
        Err(failure) => return Err(reason(failure)),
    };
    if output.truncated {
        return Err(format!("git {} printed more than {MAX_OUTPUT} bytes", args.join(" ")));
    }
    Ok(Some(output.stdout))
}

/// [`read`] as one trimmed line.
pub(crate) fn line(dir: &Path, overrides: &[Override], args: &[&str]) -> Result<String, String> {
    read(dir, overrides, args).map(|out| String::from_utf8_lossy(&out).trim().to_string())
}

/// [`line`], `None` when git fails (a missing ref, an unset key).
pub(crate) fn try_line(dir: &Path, overrides: &[Override], args: &[&str]) -> Option<String> {
    line(dir, overrides, args).ok().filter(|value| !value.is_empty())
}

/// A write: `git <args>` with `index` as the index file when given.
pub(crate) fn write(
    git: &WriteGit<'_>,
    index: Option<&Path>,
    args: &[&OsStr],
    bound: Bound,
) -> Result<String, String> {
    let output = git.run(index, args, &[], bound, MAX_OUTPUT).map_err(reason)?;
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

/// [`write`] with string arguments.
pub(crate) fn write_str(
    git: &WriteGit<'_>,
    index: Option<&Path>,
    args: &[&str],
    bound: Bound,
) -> Result<String, String> {
    let args: Vec<&OsStr> = args.iter().map(OsStr::new).collect();
    write(git, index, &args, bound)
}

/// The user's git, for what must reach a remote: no prompt, nothing on
/// stdin, stopped after `limit`.
pub(crate) fn user_git(dir: &Path, args: &[&str], limit: Duration) -> Result<Vec<u8>, String> {
    let mut command = Command::new(cmux_git::run::PROGRAM);
    for (name, _) in std::env::vars_os() {
        if name.as_encoded_bytes().starts_with(b"GIT_") {
            command.env_remove(name);
        }
    }
    command
        .args(["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"])
        .args(args)
        .current_dir(dir)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_SSH_COMMAND", "ssh -o BatchMode=yes -o ConnectTimeout=10")
        .env("LC_ALL", "C");
    let output =
        run_within(command, limit).map_err(|error| format!("git {}: {error}", args.join(" ")))?;
    if output.status.success() {
        Ok(output.stdout)
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
    }
}

/// Runs `command`, killed when it has not finished within `limit`.
pub(crate) fn run_within(
    mut command: Command,
    limit: Duration,
) -> Result<std::process::Output, String> {
    let child = command.spawn().map_err(|error| format!("could not run: {error}"))?;
    cmux_git::run::lower_if_background(child.id());
    let (sender, receiver) = std::sync::mpsc::channel();
    let id = child.id();
    std::thread::spawn(move || {
        let _ = sender.send(child.wait_with_output());
    });
    match receiver.recv_timeout(limit) {
        Ok(Ok(output)) => Ok(output),
        Ok(Err(error)) => Err(format!("could not run: {error}")),
        Err(_) => {
            kill(id);
            Err(format!("did not finish within {} s", limit.as_secs()))
        }
    }
}

#[cfg(unix)]
fn kill(pid: u32) {
    if let Ok(pid) = libc::pid_t::try_from(pid) {
        // SAFETY: kill(2) with a pid this process started; a pid that has
        // exited meanwhile only makes it fail.
        unsafe {
            libc::kill(pid, libc::SIGKILL);
        }
    }
}

#[cfg(not(unix))]
fn kill(_pid: u32) {}

fn reason(failure: GitFailure) -> String {
    failure.reason()
}

/// Splits NUL-terminated records.
pub(crate) fn records(bytes: &[u8]) -> impl Iterator<Item = &[u8]> {
    bytes.split(|byte| *byte == 0).filter(|record| !record.is_empty())
}

/// Whether `value` is a full hexadecimal object id (SHA-1 or SHA-256).
pub(crate) fn is_object_id(value: &str) -> bool {
    (value.len() == 40 || value.len() == 64) && value.bytes().all(|b| b.is_ascii_hexdigit())
}
