//! `git.worktree.apply`: a worktree chat's work, back in the main checkout.
//! Everything the worktree changed since its base (the merge base with the
//! branch `git.worktree.create` recorded) — its commits, its uncommitted
//! edits and the new files it never added — lands in the main checkout as
//! uncommitted changes, as Codex's apply does. HEAD and the index of both
//! checkouts stay as they are.
//!
//! The patch is read through a copy of the worktree's index, so its new
//! files count without being added. It is refused when the main checkout has
//! changes of its own to any file the patch touches, or when the patch does
//! not apply there cleanly; a refusal changes nothing. The journal keeps the
//! patch, so a retry after a lost reply finds it applied instead of applying
//! it twice.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::checkpoint::ledger;
use super::journal::Journal;
use super::mutation::{Target, key, output_extra, refused, run_failed};
use super::user_run::{UserGit, deadline};
use super::{MAX_SMALL_OUTPUT_BYTES, Repository};
use crate::Mux;
use crate::resource::ResourceError;
use crate::resource_router::ParsedResourceRequest;

const OPERATION: &str = "git.worktree.apply";

/// A started apply, as the journal keeps it.
#[derive(Debug, Serialize, Deserialize)]
struct Attempt {
    main_root: PathBuf,
    patch: PathBuf,
    files: Vec<String>,
}

pub(super) fn dispatch(
    mux: &Arc<Mux>,
    request: &ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let key = key(request);
    let deadline = deadline();
    let target = Target::resolve(mux, request, OPERATION)?;
    let fingerprint = target.fingerprint(request);
    target.exclusive(OPERATION, || {
        if let Some(replayed) = ledger::prior(mux, &key, OPERATION, &fingerprint)? {
            return Ok(replayed);
        }
        let repository = &target.repository;
        let journal = Journal::open(mux, &target.identity(), &key, OPERATION)?;
        let (attempt, resumed) = match journal.attempt::<Attempt>(&fingerprint) {
            Some(attempt) => (attempt, true),
            None => {
                let attempt = plan(repository, target.git_dir(), &key, deadline)?;
                journal.start(&fingerprint, &attempt)?;
                (attempt, false)
            }
        };
        let main = UserGit { root: &attempt.main_root, deadline };
        let result = apply(&main, &attempt, resumed);
        // A run stopped by the deadline may have applied: its retry looks.
        if !result.as_ref().is_err_and(|error| error.details["reason"] == "timed_out") {
            let _ = std::fs::remove_file(&attempt.patch);
            journal.finish();
        }
        result?;
        let value = json!({
            "main_root": attempt.main_root.to_string_lossy(),
            "files": attempt.files,
        });
        ledger::commit(mux, &key, OPERATION, &fingerprint, &value, false, &request.actor)
    })
}

/// The main checkout, and the worktree's work since its base as a patch in
/// the worktree's git directory.
fn plan(
    repository: &Repository,
    git_dir: &Path,
    key: &str,
    deadline: std::time::Instant,
) -> Result<Attempt, ResourceError> {
    let Some(main_root) = repository.main_checkout() else {
        let message = "this is no linked worktree: there is no main checkout to apply to";
        return Err(refused(OPERATION, "not_a_worktree", message, Value::Null));
    };
    let Some((reference, base)) = repository.base_branch() else {
        let message = "the worktree has no base branch to compare with";
        return Err(refused(OPERATION, "no_base", message, Value::Null));
    };
    let arguments = ["merge-base", "HEAD", reference.as_str()];
    let Ok(output) = repository.run(&arguments, MAX_SMALL_OUTPUT_BYTES) else {
        let message = format!("HEAD and {base} have no common commit");
        return Err(refused(OPERATION, "no_merge_base", message, json!({"base": base})));
    };
    let merge_base = String::from_utf8_lossy(&output.stdout).trim().to_string();

    // A copy of the worktree's index, with every change added: new files
    // count, and the worktree's own index stays as the chat left it.
    let stamp = format!("{:016x}", fnv(key));
    let index = git_dir.join(format!("cmux-apply-{stamp}.index"));
    let patch = git_dir.join(format!("cmux-apply-{stamp}.patch"));
    let source = git_dir.join("index");
    if source.exists() && std::fs::copy(&source, &index).is_err() {
        let message = format!("{}: could not copy the index", source.display());
        return Err(refused(OPERATION, "git_failed", message, Value::Null));
    }
    let Some(index_path) = index.to_str() else {
        let _ = std::fs::remove_file(&index);
        let message = format!("{}: the git directory's path is not UTF-8", git_dir.display());
        return Err(refused(OPERATION, "git_failed", message, Value::Null));
    };
    let git = UserGit { root: &repository.root, deadline };
    let environment = [("GIT_INDEX_FILE", index_path)];
    let read = || -> Result<Vec<String>, ResourceError> {
        if !source.exists() {
            checked(&git, &["read-tree", "HEAD"], &environment)?;
        }
        checked(&git, &["add", "--all"], &environment)?;
        let output = format!("--output={}", patch.display());
        let diff = [
            "diff",
            "--cached",
            "--binary",
            "--full-index",
            "--no-renames",
            "--no-ext-diff",
            "--no-textconv",
            "--no-color",
            output.as_str(),
            merge_base.as_str(),
        ];
        checked(&git, &diff, &environment)?;
        let names = ["diff", "--cached", "--name-only", "-z", "--no-renames", merge_base.as_str()];
        let listed = checked(&git, &names, &environment)?;
        Ok(listed.split('\0').filter(|name| !name.is_empty()).map(str::to_string).collect())
    };
    let files = read();
    let _ = std::fs::remove_file(&index);
    let files = files?;
    if files.is_empty() {
        let _ = std::fs::remove_file(&patch);
        let message = format!("the worktree has no changes since {base}");
        return Err(refused(OPERATION, "nothing_to_apply", message, json!({"base": base})));
    }
    Ok(Attempt { main_root, patch, files })
}

/// Applies the patch to the main checkout's files, unless a lost reply's run
/// already did.
fn apply(main: &UserGit<'_>, attempt: &Attempt, resumed: bool) -> Result<(), ResourceError> {
    let patch = attempt.patch.to_string_lossy();
    let check = ["apply", "--check", "--binary", patch.as_ref()];
    if resumed {
        let reverse = ["apply", "--check", "--reverse", "--binary", patch.as_ref()];
        let run = main.run(&reverse).map_err(|failure| run_failed(OPERATION, &failure))?;
        if run.success && !main.run(&check).is_ok_and(|run| run.success) {
            return Ok(());
        }
    }
    let paths: Vec<String> = attempt.files.iter().map(|file| format!(":(literal){file}")).collect();
    let mut status =
        vec!["status", "--porcelain", "-z", "--no-renames", "--untracked-files=all", "--"];
    status.extend(paths.iter().map(String::as_str));
    let run = main.run(&status).map_err(|failure| run_failed(OPERATION, &failure))?;
    let changed: Vec<String> = String::from_utf8_lossy(&run.stdout)
        .split('\0')
        .filter_map(|entry| entry.get(3..))
        .filter(|path| !path.is_empty())
        .map(str::to_string)
        .collect();
    if !run.success || !changed.is_empty() {
        let message = "the main checkout has changes of its own to files the worktree changed";
        return Err(refused(
            OPERATION,
            "main_checkout_changed",
            message,
            json!({"files": changed}),
        ));
    }
    let run = main.run(&check).map_err(|failure| run_failed(OPERATION, &failure))?;
    if !run.success {
        let message = "the worktree's changes do not apply cleanly to the main checkout";
        return Err(refused(OPERATION, "does_not_apply", message, output_extra(&run.output())));
    }
    let run = main
        .run(&["apply", "--binary", patch.as_ref()])
        .map_err(|failure| run_failed(OPERATION, &failure))?;
    if !run.success {
        let message = "git apply failed";
        return Err(refused(OPERATION, "git_failed", message, output_extra(&run.output())));
    }
    Ok(())
}

/// Runs `git <arguments>` in the worktree with `environment`; its stdout, or
/// a refusal with git's output.
fn checked(
    git: &UserGit<'_>,
    arguments: &[&str],
    environment: &[(&str, &str)],
) -> Result<String, ResourceError> {
    let run =
        git.run_with(arguments, environment).map_err(|failure| run_failed(OPERATION, &failure))?;
    if !run.success {
        let message = format!("git {} failed", arguments[0]);
        return Err(refused(OPERATION, "git_failed", message, output_extra(&run.output())));
    }
    Ok(String::from_utf8_lossy(&run.stdout).into_owned())
}

/// FNV-1a: a stable file name per idempotency key.
fn fnv(text: &str) -> u64 {
    text.bytes().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
        (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3)
    })
}
