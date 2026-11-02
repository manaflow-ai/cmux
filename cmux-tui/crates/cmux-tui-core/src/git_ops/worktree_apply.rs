//! `git.worktree.apply`: a worktree chat's work, back in the main checkout.
//! Everything the worktree changed since its base (the merge base with the
//! branch `git.worktree.create` recorded) — its commits, its uncommitted
//! edits and the new files it never added — lands in the main checkout as
//! uncommitted changes, as Codex's apply does. HEAD and the index of both
//! checkouts stay as they are. Submodules are left out.
//!
//! The patch is read through a copy of the worktree's index, so its new
//! files count without being added, with fixed prefixes and whitespace rules
//! so the user's diff and apply settings change nothing. It is refused when
//! the main checkout has changes of its own at any path the patch touches
//! (an edit, a staged change, or a file git does not track there), or when
//! the patch does not apply there cleanly; a refusal changes nothing. The
//! journal keeps the patch, so a retry after a lost reply finds it applied
//! instead of applying it twice, and one stopped while writing says so.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::checkpoint::ledger;
use super::journal::Journal;
use super::mutation::{Target, key, output_extra, refused, run_failed};
use super::run::run_git;
use super::user_run::{UserGit, deadline};
use super::{MAX_SMALL_OUTPUT_BYTES, Repository};
use crate::Mux;
use crate::resource::ResourceError;
use crate::resource_router::ParsedResourceRequest;

const OPERATION: &str = "git.worktree.apply";
/// The most path list output read from the main checkout; past it the
/// apply is refused rather than checked against part of the list.
const MAX_PATH_LIST_BYTES: usize = 64 * 1024 * 1024;
/// `git apply` exactly as the patch says: no whitespace fixes or warnings,
/// no looser context matching, whatever the user's `apply.*` settings.
const APPLY: [&str; 6] =
    ["-c", "apply.ignoreWhitespace=no", "apply", "--binary", "--whitespace=nowarn", "-p1"];

/// A started apply, as the journal keeps it.
#[derive(Debug, Serialize, Deserialize)]
struct Attempt {
    main_root: PathBuf,
    patch: PathBuf,
    /// The patch's paths, NUL-separated as git wrote them.
    names: PathBuf,
    files: Vec<String>,
}

pub(super) fn dispatch(
    mux: &Arc<Mux>,
    request: &ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let key = key(request);
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
                let attempt = plan(repository, target.git_dir(), &key)?;
                journal.start(&fingerprint, &attempt)?;
                (attempt, false)
            }
        };
        let result = apply(&attempt, resumed);
        // A run stopped by the deadline may have applied: its retry looks.
        if !result.as_ref().is_err_and(|error| error.details["reason"] == "timed_out") {
            let _ = std::fs::remove_file(&attempt.patch);
            let _ = std::fs::remove_file(&attempt.names);
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

/// The main checkout, and the worktree's work since its recorded base as a
/// patch in the worktree's git directory.
fn plan(repository: &Repository, git_dir: &Path, key: &str) -> Result<Attempt, ResourceError> {
    let Some(main_root) = repository.main_checkout() else {
        let message = "this is no linked worktree: there is no main checkout to apply to";
        return Err(refused(OPERATION, "not_a_worktree", message, Value::Null));
    };
    let Some((reference, base)) = repository.recorded_base() else {
        let message = "the worktree's branch has no base recorded by git.worktree.create";
        return Err(refused(OPERATION, "no_base", message, Value::Null));
    };
    let unmerged = repository.run(&["ls-files", "--unmerged", "-z"], MAX_SMALL_OUTPUT_BYTES);
    if !unmerged.is_ok_and(|output| output.stdout.is_empty()) {
        let message = "the worktree is in the middle of a merge or rebase";
        return Err(refused(OPERATION, "unmerged", message, Value::Null));
    }
    let arguments = ["merge-base", "HEAD", reference.as_str()];
    let Ok(output) = repository.run(&arguments, MAX_SMALL_OUTPUT_BYTES) else {
        let message = format!("HEAD and {base} have no common commit");
        return Err(refused(OPERATION, "no_merge_base", message, json!({"base": base})));
    };
    let merge_base = String::from_utf8_lossy(&output.stdout).trim().to_string();

    let stamp = format!("cmux-apply-{:016x}", fnv(key));
    let index = git_dir.join(format!("{stamp}.index"));
    let patch = git_dir.join(format!("{stamp}.patch"));
    let names = git_dir.join(format!("{stamp}.names"));
    let scratch = [index.clone(), git_dir.join(format!("{stamp}.index.lock"))];
    let clear = |paths: &[&PathBuf]| {
        for path in paths {
            let _ = std::fs::remove_file(path);
        }
    };
    clear(&[&scratch[0], &scratch[1], &patch, &names]);
    let read = || -> Result<Vec<Vec<u8>>, ResourceError> {
        // A copy of the worktree's index, with every change added: new files
        // count, and the worktree's own index stays as the chat left it.
        let source = git_dir.join("index");
        if source.exists() && copy_keeping_time(&source, &index).is_err() {
            let message = format!("{}: could not copy the index", source.display());
            return Err(refused(OPERATION, "git_failed", message, Value::Null));
        }
        let Some(index_path) = index.to_str() else {
            let message = format!("{}: the git directory's path is not UTF-8", git_dir.display());
            return Err(refused(OPERATION, "git_failed", message, Value::Null));
        };
        let git = UserGit { root: &repository.root, deadline: deadline() };
        let environment = [("GIT_INDEX_FILE", index_path)];
        if !source.exists() {
            checked(&git, &["read-tree", "HEAD"], &environment)?;
        }
        checked(&git, &["add", "--all"], &environment)?;
        let patch_output = format!("--output={}", patch.display());
        let names_output = format!("--output={}", names.display());
        let mut diff = vec![
            "-c",
            "diff.relative=false",
            "diff",
            "--cached",
            "--no-renames",
            "--no-ext-diff",
            "--no-textconv",
            "--no-color",
            "--ignore-submodules=all",
        ];
        let mut listing = diff.clone();
        diff.extend([
            "--binary",
            "--full-index",
            "--src-prefix=a/",
            "--dst-prefix=b/",
            patch_output.as_str(),
            merge_base.as_str(),
        ]);
        checked(&git, &diff, &environment)?;
        listing.extend(["--name-only", "-z", names_output.as_str(), merge_base.as_str()]);
        checked(&git, &listing, &environment)?;
        let listed = std::fs::read(&names).map_err(|error| {
            let message = format!("{}: {error}", names.display());
            refused(OPERATION, "git_failed", message, Value::Null)
        })?;
        Ok(split_names(&listed))
    };
    let listed = read();
    clear(&[&scratch[0], &scratch[1]]);
    let listed = match listed {
        Ok(listed) if !listed.is_empty() => listed,
        outcome => {
            clear(&[&patch, &names]);
            outcome?;
            let message = format!("the worktree has no changes since {base}");
            return Err(refused(OPERATION, "nothing_to_apply", message, json!({"base": base})));
        }
    };
    let files = listed.iter().map(|name| String::from_utf8_lossy(name).into_owned()).collect();
    Ok(Attempt { main_root, patch, names, files })
}

/// Copies the index and gives the copy the index's modification time. Git
/// trusts an entry's stat data unless the entry is as new as the index file
/// ("racy git"), so a copy stamped now would let an edit of the same size,
/// made in the second the index was written, read as unchanged and be left
/// out of the patch. The time is read before the copy: an index written in
/// between only makes more entries count as racy, which is safe. The copy is
/// opened read-only to set the time: the copy has the index's mode, which may
/// lack the write bit (0444), and setting a file's times needs only that the
/// process owns it (futimens), not write access.
fn copy_keeping_time(source: &Path, copy: &Path) -> std::io::Result<()> {
    let modified = std::fs::metadata(source)?.modified()?;
    std::fs::copy(source, copy)?;
    std::fs::File::open(copy)?.set_modified(modified)
}

/// Applies the patch to the main checkout's files, unless a lost reply's run
/// already did.
fn apply(attempt: &Attempt, resumed: bool) -> Result<(), ResourceError> {
    let git = UserGit { root: &attempt.main_root, deadline: deadline() };
    let patch = attempt.patch.to_string_lossy();
    let check = |reverse: bool| -> Result<(bool, String), ResourceError> {
        let mut arguments = APPLY.to_vec();
        arguments.push("--check");
        if reverse {
            arguments.push("--reverse");
        }
        arguments.push(patch.as_ref());
        let run = git.run(&arguments).map_err(|failure| run_failed(OPERATION, &failure))?;
        Ok((run.success, run.output()))
    };
    let (applies, output) = check(false)?;
    if resumed && !applies {
        let (applied, _) = check(true)?;
        if applied {
            return Ok(());
        }
        let message = "an earlier run of this apply was stopped while writing: the main \
                       checkout may have part of it";
        return Err(refused(OPERATION, "interrupted", message, json!({"files": attempt.files})));
    }
    let names = std::fs::read(&attempt.names).map_err(|error| {
        let message = format!("{}: {error}", attempt.names.display());
        refused(OPERATION, "git_failed", message, Value::Null)
    })?;
    let changed = changed_in_main(&attempt.main_root, &split_names(&names))?;
    if !changed.is_empty() {
        let message = "the main checkout has changes of its own to files the worktree changed";
        return Err(refused(
            OPERATION,
            "main_checkout_changed",
            message,
            json!({"files": changed}),
        ));
    }
    if !applies {
        let message = "the worktree's changes do not apply cleanly to the main checkout";
        return Err(refused(OPERATION, "does_not_apply", message, output_extra(&output)));
    }
    let mut arguments = APPLY.to_vec();
    arguments.push(patch.as_ref());
    let run = git.run(&arguments).map_err(|failure| run_failed(OPERATION, &failure))?;
    if !run.success {
        let message = "git apply failed";
        return Err(refused(OPERATION, "git_failed", message, output_extra(&run.output())));
    }
    Ok(())
}

/// The patch's paths the main checkout has its own changes at: a staged or
/// unstaged change against HEAD, or a file there that git does not track
/// (untracked or ignored).
fn changed_in_main(main_root: &Path, names: &[Vec<u8>]) -> Result<Vec<String>, ResourceError> {
    // The main checkout can have filter drivers of its own (`config.worktree`).
    let overrides =
        cmux_git::filter_overrides(main_root).map_err(|failure| run_failed(OPERATION, &failure))?;
    let list = |arguments: &[&str]| -> Result<HashSet<Vec<u8>>, ResourceError> {
        match run_git(main_root, &overrides, arguments, MAX_PATH_LIST_BYTES) {
            Ok(output) if !output.truncated => {
                Ok(split_names(&output.stdout).into_iter().collect())
            }
            Ok(_) => {
                let message = "the main checkout lists too many files to check";
                Err(refused(OPERATION, "git_failed", message, Value::Null))
            }
            Err(failure) => Err(run_failed(OPERATION, &failure)),
        }
    };
    let tracked = list(&["ls-files", "-z"])?;
    let changed = list(&[
        "diff",
        "HEAD",
        "--name-only",
        "-z",
        "--no-renames",
        "--no-ext-diff",
        "--ignore-submodules=all",
    ])?;
    Ok(names
        .iter()
        .filter(|name| {
            changed.contains(*name)
                || (!tracked.contains(*name)
                    && main_root.join(path_of(name)).symlink_metadata().is_ok())
        })
        .map(|name| String::from_utf8_lossy(name).into_owned())
        .collect())
}

fn split_names(listed: &[u8]) -> Vec<Vec<u8>> {
    listed.split(|byte| *byte == 0).filter(|name| !name.is_empty()).map(<[u8]>::to_vec).collect()
}

/// A repository path as git wrote it (`/`-separated bytes).
fn path_of(name: &[u8]) -> PathBuf {
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;
        PathBuf::from(std::ffi::OsStr::from_bytes(name))
    }
    #[cfg(not(unix))]
    {
        PathBuf::from(String::from_utf8_lossy(name).into_owned())
    }
}

/// Runs `git <arguments>` in the worktree with `environment`; its stdout, or
/// a refusal with git's output.
fn checked(
    git: &UserGit<'_>,
    arguments: &[&str],
    environment: &[(&str, &str)],
) -> Result<(), ResourceError> {
    let run =
        git.run_with(arguments, environment).map_err(|failure| run_failed(OPERATION, &failure))?;
    if !run.success {
        let command = arguments.iter().find(|word| !word.starts_with('-') && !word.contains('='));
        let message = format!("git {} failed", command.unwrap_or(&"git"));
        return Err(refused(OPERATION, "git_failed", message, output_extra(&run.output())));
    }
    Ok(())
}

/// FNV-1a: a stable file name per idempotency key.
fn fnv(text: &str) -> u64 {
    text.bytes().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
        (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3)
    })
}
