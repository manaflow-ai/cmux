//! Every git call of the seed plan. Each one turns off fsmonitor, refuses
//! implicit bare repositories, reads no system config, runs no hook, starts
//! no background gc, signs nothing and reads nothing from stdin. Caller
//! environment that would point git at another repository, index or object
//! store is dropped; the plan sets its own where it needs one.

use std::path::Path;
use std::process::{Command, Stdio};

/// git with the plan's fixed settings and no `-C` or `--git-dir` yet.
fn base() -> Command {
    let mut command = Command::new("git");
    command.args([
        "-c",
        "core.fsmonitor=false",
        "-c",
        "safe.bareRepository=explicit",
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "gc.auto=0",
        "-c",
        "maintenance.auto=false",
        "-c",
        "commit.gpgSign=false",
        "-c",
        "core.splitIndex=false",
        "-c",
        "i18n.commitEncoding=UTF-8",
    ]);
    command
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_TERMINAL_PROMPT", "0")
        // `status` and friends never refresh the person's index.
        .env("GIT_OPTIONAL_LOCKS", "0")
        // A partial clone never fetches a missing blob from here.
        .env("GIT_NO_LAZY_FETCH", "1")
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_COMMON_DIR")
        .env_remove("GIT_INDEX_FILE")
        .env_remove("GIT_OBJECT_DIRECTORY")
        .env_remove("GIT_ALTERNATE_OBJECT_DIRECTORIES")
        .env_remove("GIT_NAMESPACE")
        .env_remove("GIT_LITERAL_PATHSPECS")
        .env_remove("GIT_GLOB_PATHSPECS")
        .env_remove("GIT_NOGLOB_PATHSPECS")
        .env_remove("GIT_ICASE_PATHSPECS")
        .stdin(Stdio::null());
    command
}

/// git in the working copy (or any folder) at `folder`.
pub(super) fn at(folder: &Path) -> Command {
    let mut command = base();
    command.arg("-C").arg(folder);
    command
}

/// git in the bare repository at `git_dir`.
pub(super) fn bare(git_dir: &Path) -> Command {
    let mut command = base();
    command.arg("--git-dir").arg(git_dir);
    command
}

/// stdout of a successful run, else git's stderr (or why it did not run).
pub(super) fn output(command: &mut Command) -> Result<Vec<u8>, String> {
    let out = command.output().map_err(|error| format!("cannot run git: {error}"))?;
    if out.status.success() {
        Ok(out.stdout)
    } else {
        let stderr = String::from_utf8_lossy(&out.stderr).trim().to_string();
        Err(if stderr.is_empty() { format!("git exited with {}", out.status) } else { stderr })
    }
}

/// stdout of a successful run as text, without its trailing newline.
pub(super) fn text(command: &mut Command) -> Result<String, String> {
    let bytes = output(command)?;
    let text = String::from_utf8_lossy(&bytes);
    Ok(text.trim_end_matches(['\n', '\r']).to_string())
}

/// stdout of a successful run with any output; None on failure or nothing.
pub(super) fn optional(command: &mut Command) -> Option<String> {
    text(command).ok().filter(|line| !line.is_empty())
}
