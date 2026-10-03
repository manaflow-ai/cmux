//! `git.commit`: records a commit in the target's repository as the user
//! would with `git commit` in a terminal. Their hooks run unless `no_verify`
//! (which, as in git, skips pre-commit and commit-msg only); their identity,
//! signing and config apply. The message is used as given apart from git's
//! whitespace cleanup, so a line starting with `#` stays.
//!
//! What it commits: with `paths`, exactly those paths as they are in the
//! working tree (they are staged first, so new files can be named; other
//! staged changes stay staged and out of the commit, and the named paths
//! stay staged when the commit is refused); with `all`, every tracked
//! change, plus untracked files with `include_untracked`; with neither, the
//! index as it is. Paths are literal, never pathspec magic.
//!
//! `expected_head` refuses with `head_moved` when HEAD is no longer the
//! commit the caller saw. A lost reply is recovered through the attempt
//! journal: git commits with a reflog message that names the attempt, and a
//! retry reports HEAD only when HEAD's newest reflog entry names it.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::checkpoint::ledger;
use super::checkpoint::store::{mint, private_directory};
use super::commit_args::{Arguments, parse};
use super::journal::Journal;
use super::mutation::{Target, active_hooks, key, output_extra, read_failed, refused, run_failed};
use super::run::GitFailure;
use super::user_run::{UserGit, UserRun, deadline};
use super::{MAX_SMALL_OUTPUT_BYTES, Repository, clamp};
use crate::Mux;
use crate::resource::ResourceError;
use crate::resource_router::ParsedResourceRequest;

const OPERATION: &str = "git.commit";
/// State files that make a plain commit the wrong action, and their names.
const IN_PROGRESS: [(&str, &str); 5] = [
    ("MERGE_HEAD", "merge"),
    ("rebase-merge", "rebase"),
    ("rebase-apply", "rebase"),
    ("CHERRY_PICK_HEAD", "cherry-pick"),
    ("REVERT_HEAD", "revert"),
];

/// A started commit, as the journal keeps it.
#[derive(Debug, Serialize, Deserialize)]
struct Attempt {
    /// Named in the commit's reflog message.
    attempt_id: String,
    /// HEAD before the commit; `None` on an unborn branch.
    head: Option<String>,
    /// The parents the new commit gets: HEAD, or HEAD's own with amend.
    parents: Vec<String>,
}

impl Attempt {
    fn reflog_action(&self) -> String {
        format!("commit (cmux {})", self.attempt_id)
    }

    /// HEAD, when HEAD's newest reflog entry is this attempt's commit.
    fn recovered(&self, repository: &Repository, head: Option<&str>) -> Option<String> {
        let head = head?;
        if Some(head) == self.head.as_deref() {
            return None;
        }
        let reflog = ["log", "-g", "-1", "--format=%H%n%gs%n%P", "HEAD", "--"];
        let output = repository.run(&reflog, MAX_SMALL_OUTPUT_BYTES).ok()?;
        let text = String::from_utf8_lossy(&output.stdout).into_owned();
        let mut lines = text.lines();
        let (commit, subject, parents) = (lines.next()?, lines.next()?, lines.next().unwrap_or(""));
        let parents: Vec<String> = parents.split_whitespace().map(str::to_string).collect();
        let ours = commit == head
            && subject.starts_with(&format!("{}:", self.reflog_action()))
            && parents == self.parents;
        ours.then(|| head.to_string())
    }
}

/// The step of a commit that git refused.
enum Step {
    Stage,
    Commit,
}

pub(super) fn dispatch(
    mux: &Arc<Mux>,
    request: &ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let key = key(request);
    let deadline = deadline();
    let target = Target::resolve(mux, request, OPERATION)?;
    let arguments = parse(&request.fields, &target.repository.root)?;
    let fingerprint = target.fingerprint(request);
    target.exclusive(OPERATION, || {
        if let Some(replayed) = ledger::prior(mux, &key, OPERATION, &fingerprint)? {
            return Ok(replayed);
        }
        let repository = &target.repository;
        let git = UserGit { root: &repository.root, deadline };
        let journal = Journal::open(mux, &target.identity(), &key, OPERATION)?;
        let head = repository.commit("HEAD");
        if let Some(attempt) = journal.attempt::<Attempt>(&fingerprint)
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
        let attempt = Attempt { attempt_id: mint("attempt"), head, parents };
        journal.start(&fingerprint, &attempt)?;
        // A run that did not finish may have committed: the attempt stays,
        // so a retry with the same key reports that commit.
        let (step, run) =
            run_commit(&git, &arguments, &attempt).map_err(|failure| match failure {
                GitFailure::TimedOut => refused(
                    OPERATION,
                    "timed_out",
                    "git did not finish in time and was stopped; a commit may have been made, \
                 and a retry with the same key reports it",
                    Value::Null,
                ),
                other => run_failed(OPERATION, &other),
            })?;
        if !run.success {
            let error = classified(&git, &step, &run, &arguments);
            // An index lock means another git may still commit; a moved HEAD
            // may be this attempt's commit. Both keep the attempt.
            let locked = error.details["reason"] == "index_locked";
            if !locked && repository.commit("HEAD") == attempt.head {
                journal.finish();
            }
            return Err(error);
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
        journal.finish();
        Ok(reply)
    })
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

/// Stages what the arguments name and runs `git commit`; the step that
/// ran last and its result.
fn run_commit(
    git: &UserGit<'_>,
    arguments: &Arguments,
    attempt: &Attempt,
) -> Result<(Step, UserRun), GitFailure> {
    let scratch = Scratch::new().map_err(|error| GitFailure::Unavailable(error.to_string()))?;
    let message = scratch.write("message", arguments.message.as_bytes())?;
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
        let staged = git.run(&staging)?;
        if !staged.success {
            return Ok((Step::Stage, staged));
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
    let action = attempt.reflog_action();
    Ok((Step::Commit, git.run_with(&command, &[("GIT_REFLOG_ACTION", action.as_str())])?))
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

/// A refused commit's machine reason, from the step that failed, what git
/// printed and the hooks that ran. A failed staging step is never a hook.
fn classified(
    git: &UserGit<'_>,
    step: &Step,
    run: &UserRun,
    arguments: &Arguments,
) -> ResourceError {
    let output = run.output();
    let (reason, message) = if output.contains("index.lock") {
        ("index_locked", "another git process holds the repository's index")
    } else if matches!(step, Step::Stage) {
        if output.contains("did not match any file") {
            ("path_not_found", "a path matches no file in the working tree or the index")
        } else {
            ("git_failed", "git could not stage the paths; its output says why")
        }
    } else if output.contains("nothing to commit")
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
    } else if output.contains("did not match any file") {
        ("path_not_found", "a path matches no file in the working tree or the index")
    } else if !commit_hooks(git, arguments.no_verify).is_empty() {
        ("hook_failed", "a commit hook refused the commit; its output says why")
    } else {
        ("git_failed", "git did not commit; its output says why")
    };
    refused(OPERATION, reason, message, output_extra(&output))
}

/// The commit hooks that run: `--no-verify` skips pre-commit and commit-msg.
fn commit_hooks(git: &UserGit<'_>, no_verify: bool) -> Vec<String> {
    let names: &[&str] = if no_verify {
        &["prepare-commit-msg"]
    } else {
        &["pre-commit", "prepare-commit-msg", "commit-msg"]
    };
    active_hooks(git, names)
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

    fn write(&self, name: &str, bytes: &[u8]) -> Result<PathBuf, GitFailure> {
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
        written.map_err(|error| GitFailure::Unavailable(format!("temporary files: {error}")))?;
        Ok(path)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

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
