//! `git.commit`: records a commit in the target's repository as the user
//! would with `git commit` in a terminal. Their hooks run unless `no_verify`
//! (which, as in git, skips pre-commit and commit-msg only); their identity,
//! signing and config apply. The message is used as given apart from git's
//! whitespace cleanup, so a line starting with `#` stays.
//!
//! What it commits: with `paths`, exactly those paths as they are in the
//! working tree (they are staged first, so new files can be named, and
//! other staged changes stay staged and out of the commit); with `all`,
//! every tracked change, plus untracked files with `include_untracked`; with
//! neither, the index as it is. Paths are literal, never pathspec magic.
//!
//! `expected_head` refuses with `head_moved` when HEAD is no longer the
//! commit the caller saw. A lost reply is recovered through the commit
//! journal (`commit_journal`), never by guessing from the message.

use std::fs;
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;

use serde_json::{Map, Value, json};

use super::checkpoint::ledger;
use super::checkpoint::store::{mint, private_directory};
use super::commit_journal::{Attempt, Journal};
use super::mutation::{Target, active_hooks, key, output_extra, read_failed, refused, run_failed};
use super::user_run::{UserRun, run_user_git};
use super::{MAX_SMALL_OUTPUT_BYTES, Repository, clamp};
use crate::Mux;
use crate::resource::ResourceError;
use crate::resource_router::ParsedResourceRequest;

/// Test seams for failures a test cannot otherwise time.
#[cfg(test)]
pub(super) mod seams {
    use std::cell::Cell;

    thread_local! {
        /// Loses the reply after git committed and before the ledger, as a
        /// daemon that stopped there would.
        pub static LOSE_REPLY: Cell<bool> = const { Cell::new(false) };
    }
}

const OPERATION: &str = "git.commit";
const MAX_MESSAGE_BYTES: usize = 64 * 1024;
const MAX_PATHS: usize = 5000;
/// State files that make a plain commit the wrong action, and their names.
const IN_PROGRESS: [(&str, &str); 5] = [
    ("MERGE_HEAD", "merge"),
    ("rebase-merge", "rebase"),
    ("rebase-apply", "rebase"),
    ("CHERRY_PICK_HEAD", "cherry-pick"),
    ("REVERT_HEAD", "revert"),
];

struct Arguments {
    message: String,
    paths: Vec<String>,
    all: bool,
    include_untracked: bool,
    amend: bool,
    no_verify: bool,
    expected_head: Option<String>,
}

pub(super) fn dispatch(
    mux: &Arc<Mux>,
    request: &ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let key = key(request);
    let arguments = parse_arguments(&request.fields)?;
    let target = Target::resolve(mux, request, OPERATION)?;
    let fingerprint = target.fingerprint(request);
    target.exclusive(OPERATION, || {
        if let Some(replayed) = ledger::prior(mux, &key, OPERATION, &fingerprint)? {
            return Ok(replayed);
        }
        let repository = &target.repository;
        let journal = Journal::open(mux, &key, OPERATION)?;
        let head = repository.commit("HEAD");
        if let Some(journal) = &journal
            && let Some(attempt) = journal.attempt(&key, &fingerprint)
            && let Some(commit) = attempt.recovered(repository, head.as_deref())
        {
            let value = described(repository, &commit)?;
            let reply = ledger::commit(mux, &key, OPERATION, &fingerprint, &value, true)?;
            journal.finish();
            return Ok(reply);
        }
        if let Some(expected) = &arguments.expected_head
            && head.as_deref() != Some(expected.as_str())
        {
            let message = "HEAD moved since the caller read it";
            let extra = json!({"expected_head": expected, "head": head});
            return Err(refused(OPERATION, "head_moved", message, extra));
        }
        in_progress(target.git_dir())?;
        let parents = planned_parents(repository, head.as_deref(), arguments.amend)?;
        if let Some(journal) = &journal {
            journal.start(&Attempt::new(&key, &fingerprint, head, parents, &arguments.message))?;
        }
        // A run that did not finish (timed out) may have committed: its
        // attempt stays so a retry can recover it.
        let run = run_commit(repository, &arguments)?;
        if !run.success {
            if let Some(journal) = &journal {
                journal.finish();
            }
            return Err(classified(repository, &run, &arguments));
        }
        #[cfg(test)]
        if seams::LOSE_REPLY.with(|lose| lose.replace(false)) {
            return Err(refused(OPERATION, "store_failed", "simulated lost reply", Value::Null));
        }
        let Some(commit) = repository.commit("HEAD") else {
            let message = "git reported a commit, but HEAD names none";
            return Err(refused(OPERATION, "git_failed", message, Value::Null));
        };
        let value = described(repository, &commit)?;
        let reply = ledger::commit(mux, &key, OPERATION, &fingerprint, &value, false)?;
        if let Some(journal) = &journal {
            journal.finish();
        }
        Ok(reply)
    })
}

fn parse_arguments(fields: &Map<String, Value>) -> Result<Arguments, ResourceError> {
    let message = fields.get("message").and_then(Value::as_str).unwrap_or_default();
    if message.trim().is_empty() || message.len() > MAX_MESSAGE_BYTES || message.contains('\0') {
        return Err(ResourceError::validation_invalid(
            Some("message"),
            "a commit message has text, at most 64 KiB and no NUL",
        ));
    }
    let flag = |name: &str| fields.get(name).and_then(Value::as_bool).unwrap_or(false);
    let (all, include_untracked) = (flag("all"), flag("include_untracked"));
    let paths = match fields.get("paths") {
        Some(value) => relative_paths(value)?,
        None => Vec::new(),
    };
    if all && !paths.is_empty() {
        return Err(ResourceError::validation_invalid(Some("all"), "give paths or all, not both"));
    }
    if include_untracked && !all {
        return Err(ResourceError::validation_invalid(
            Some("include_untracked"),
            "include_untracked needs all",
        ));
    }
    Ok(Arguments {
        message: message.to_string(),
        paths,
        all,
        include_untracked,
        amend: flag("amend"),
        no_verify: flag("no_verify"),
        expected_head: fields.get("expected_head").and_then(Value::as_str).map(str::to_string),
    })
}

/// Repository-relative paths: not empty, no leading `/`, no NUL and no `.`,
/// `..` or `.git` component. A trailing `/` is dropped.
fn relative_paths(value: &Value) -> Result<Vec<String>, ResourceError> {
    let invalid = |path: &str| {
        ResourceError::validation_invalid(
            Some("paths"),
            format!("{path:?} is not a path relative to the repository root"),
        )
    };
    let given = value.as_array().map(Vec::as_slice).unwrap_or_default();
    if given.is_empty() || given.len() > MAX_PATHS {
        return Err(ResourceError::validation_invalid(
            Some("paths"),
            format!("paths names 1 to {MAX_PATHS} files"),
        ));
    }
    let mut paths = Vec::with_capacity(given.len());
    for path in given {
        let path = path.as_str().ok_or_else(|| invalid(&path.to_string()))?;
        let trimmed = path.strip_suffix('/').unwrap_or(path);
        let valid = !trimmed.is_empty()
            && !trimmed.contains('\0')
            && Path::new(trimmed).components().all(|part| match part {
                Component::Normal(name) => name != ".git",
                _ => false,
            })
            && trimmed.split('/').all(|part| !matches!(part, "" | "." | ".."));
        if !valid {
            return Err(invalid(path));
        }
        paths.push(trimmed.to_string());
    }
    Ok(paths)
}

/// Refuses while a merge, rebase, cherry-pick or revert is in progress: a
/// commit then would conclude or corrupt it.
fn in_progress(git_dir: &Path) -> Result<(), ResourceError> {
    if let Some((_, state)) = IN_PROGRESS.iter().find(|(file, _)| git_dir.join(file).exists()) {
        let message = format!("a {state} is in progress; finish or abort it first");
        return Err(refused(OPERATION, "merge_in_progress", message, json!({"state": state})));
    }
    Ok(())
}

/// The parents the new commit will have.
fn planned_parents(
    repository: &Repository,
    head: Option<&str>,
    amend: bool,
) -> Result<Vec<String>, ResourceError> {
    let Some(head) = head else { return Ok(Vec::new()) };
    if !amend {
        return Ok(vec![head.to_string()]);
    }
    let arguments = ["log", "-1", "--format=%P", "--end-of-options", head];
    let output = repository
        .run(&arguments, MAX_SMALL_OUTPUT_BYTES)
        .map_err(|failure| read_failed(OPERATION, &failure))?;
    Ok(String::from_utf8_lossy(&output.stdout).split_whitespace().map(str::to_string).collect())
}

/// Stages what the arguments name and runs `git commit`.
fn run_commit(repository: &Repository, arguments: &Arguments) -> Result<UserRun, ResourceError> {
    let scratch = Scratch::new().map_err(|error| {
        refused(OPERATION, "git_failed", format!("temporary files: {error}"), Value::Null)
    })?;
    let message = scratch.write("message", arguments.message.as_bytes())?;
    let root = &repository.root;
    let run = |command: &[&std::ffi::OsStr]| {
        run_user_git(root, command).map_err(|failure| run_failed(OPERATION, &failure))
    };
    let mut pathspec_flag = None;
    if !arguments.paths.is_empty() {
        let mut list = Vec::new();
        for path in &arguments.paths {
            list.extend_from_slice(b":(literal)");
            list.extend_from_slice(path.as_bytes());
            list.push(0);
        }
        let file = scratch.write("pathspecs", &list)?;
        let mut flag = std::ffi::OsString::from("--pathspec-from-file=");
        flag.push(&file);
        pathspec_flag = Some(flag);
    }
    let staging: Option<Vec<&std::ffi::OsStr>> = match &pathspec_flag {
        Some(flag) => Some(vec![
            "add".as_ref(),
            "-A".as_ref(),
            flag.as_os_str(),
            "--pathspec-file-nul".as_ref(),
        ]),
        None if arguments.include_untracked => Some(vec!["add".as_ref(), "-A".as_ref()]),
        None => None,
    };
    if let Some(staging) = staging {
        let staged = run(&staging)?;
        if !staged.success {
            return Ok(staged);
        }
    }
    let mut command: Vec<&std::ffi::OsStr> =
        vec!["commit".as_ref(), "--quiet".as_ref(), "--cleanup=whitespace".as_ref()];
    command.extend(["-F".as_ref(), message.as_os_str()]);
    if arguments.no_verify {
        command.push("--no-verify".as_ref());
    }
    if arguments.amend {
        command.push("--amend".as_ref());
    }
    if arguments.all && !arguments.include_untracked {
        command.push("--all".as_ref());
    }
    if let Some(flag) = &pathspec_flag {
        command.extend([flag.as_os_str(), "--pathspec-file-nul".as_ref()]);
    }
    run(&command)
}

/// The reply for `commit`: its branch, parent, summary and line counts.
fn described(repository: &Repository, commit: &str) -> Result<Value, ResourceError> {
    let run = |arguments: &[&str]| {
        repository
            .run(arguments, MAX_SMALL_OUTPUT_BYTES)
            .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_string())
            .map_err(|failure| read_failed(OPERATION, &failure))
    };
    let summary = run(&["log", "-1", "--format=%s", "--end-of-options", commit])?;
    let stat = run(&["diff-tree", "--root", "--no-commit-id", "--shortstat", commit])?;
    let (files_changed, additions, deletions) = shortstat(&stat);
    let mut value = json!({
        "root": repository.root.to_string_lossy(),
        "commit": commit,
        "summary": summary,
        "files_changed": clamp(files_changed),
        "additions": clamp(additions),
        "deletions": clamp(deletions),
    });
    if let Some(parent) = repository.commit(&format!("{commit}^")) {
        value["parent"] = json!(parent);
    }
    if let Ok(branch) = run(&["symbolic-ref", "--quiet", "--short", "HEAD"])
        && !branch.is_empty()
    {
        value["branch"] = json!(branch);
    }
    Ok(value)
}

/// `N files changed, X insertions(+), Y deletions(-)`; absent parts are 0.
fn shortstat(text: &str) -> (u64, u64, u64) {
    let mut counts = (0, 0, 0);
    for part in text.split(',') {
        let mut words = part.split_whitespace();
        let (Some(number), Some(word)) = (words.next(), words.next()) else { continue };
        let Ok(number) = number.parse() else { continue };
        if word.starts_with("file") {
            counts.0 = number;
        } else if word.starts_with("insertion") {
            counts.1 = number;
        } else if word.starts_with("deletion") {
            counts.2 = number;
        }
    }
    counts
}

/// A refused commit's machine reason, from what git printed and the hooks
/// that ran.
fn classified(repository: &Repository, run: &UserRun, arguments: &Arguments) -> ResourceError {
    let output = run.output();
    let (reason, message) = if output.contains("nothing to commit")
        || output.contains("no changes added to commit")
        || output.contains("nothing added to commit")
    {
        ("nothing_to_commit", "there is nothing to commit")
    } else if output.contains("Please tell me who you are")
        || output.contains("unable to auto-detect email address")
        || output.contains("empty ident name")
        || output.contains("no email was given")
        || output.contains("no name was given")
    {
        ("identity_missing", "git has no user.name or user.email for this repository")
    } else if output.contains("index.lock") {
        ("index_locked", "another git process holds the repository's index")
    } else if output.contains("did not match any file") {
        ("path_not_found", "a path matches no file in the working tree or the index")
    } else if !commit_hooks(repository, arguments.no_verify).is_empty() {
        ("hook_failed", "a commit hook refused the commit; its output says why")
    } else {
        ("git_failed", "git did not commit; its output says why")
    };
    refused(OPERATION, reason, message, output_extra(&output))
}

/// The commit hooks that run: `--no-verify` skips pre-commit and commit-msg.
fn commit_hooks(repository: &Repository, no_verify: bool) -> Vec<String> {
    let names: &[&str] = if no_verify {
        &["prepare-commit-msg"]
    } else {
        &["pre-commit", "prepare-commit-msg", "commit-msg"]
    };
    active_hooks(&repository.root, names)
}

/// A private temporary directory for the message and pathspec files,
/// removed when dropped.
struct Scratch {
    path: PathBuf,
}

impl Scratch {
    fn new() -> std::io::Result<Self> {
        let path = std::env::temp_dir().join(mint("cmux-git"));
        private_directory(&path)?;
        Ok(Self { path })
    }

    fn write(&self, name: &str, bytes: &[u8]) -> Result<PathBuf, ResourceError> {
        let path = self.path.join(name);
        let mut options = fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let written = options.open(&path).and_then(|mut file| {
            use std::io::Write;
            file.write_all(bytes)
        });
        written.map_err(|error| {
            refused(OPERATION, "git_failed", format!("temporary files: {error}"), Value::Null)
        })?;
        Ok(path)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}
