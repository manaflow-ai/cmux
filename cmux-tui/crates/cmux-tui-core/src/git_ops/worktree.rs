//! `git.worktree.create`: a chat's own worktree, so an agent works on a
//! branch of its own while the user's checkout stays as it is. The worktree
//! is `~/.cmux/worktrees/<project>/<name>` on a new branch `cmux/<name>`,
//! made from `base` (default: the current branch, else HEAD's commit) with
//! `git worktree add` in the user's environment, so their post-checkout hook
//! and filters run as in a terminal. The base is recorded as
//! `branch.<branch>.cmuxBase` for the branch's later diff and apply.
//!
//! A name already taken by a folder or a branch gets the next free suffix
//! (`fix-login-2`). The journal keeps the chosen name and base commit, so a
//! retry after a lost reply or a timeout finds the worktree (or the branch)
//! it made instead of making a second. A post-checkout hook that fails does
//! not undo the worktree git made, so that is a made worktree too.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use cmux_git::main_root;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use super::checkpoint::ledger;
use super::journal::Journal;
use super::mutation::{Target, key, output_extra, refused, run_failed};
use super::push::current_branch;
use super::run::run_git;
use super::user_run::{UserGit, deadline};
use super::{MAX_SMALL_OUTPUT_BYTES, Repository};
use crate::Mux;
use crate::resource::ResourceError;
use crate::resource_router::ParsedResourceRequest;
use cmux_json::JsonSet as _;

const OPERATION: &str = "git.worktree.create";
pub(super) const BRANCH_PREFIX: &str = "cmux/";
const MAX_NAME_CHARS: usize = 48;
/// Suffixes tried after a taken name: `name-2` up to this.
const MAX_SUFFIX: usize = 99;

/// A started create, as the journal keeps it.
#[derive(Debug, Serialize, Deserialize)]
struct Attempt {
    root: PathBuf,
    branch: String,
    base: String,
    base_commit: String,
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
        let git = UserGit { root: &repository.root, deadline };
        let journal = Journal::open(mux, &target.identity(), &key, OPERATION)?;
        let attempt = match journal.attempt::<Attempt>(&fingerprint) {
            Some(attempt) => attempt,
            None => {
                let attempt = plan(repository, target.common_dir(), &request.fields)?;
                journal.start(&fingerprint, &attempt)?;
                attempt
            }
        };
        match create(repository, &git, &attempt) {
            Ok(()) => {
                let value = described(&attempt, target.common_dir());
                let reply = ledger::commit(
                    mux,
                    &key,
                    OPERATION,
                    &fingerprint,
                    &value,
                    false,
                    &request.actor,
                )?;
                journal.finish();
                Ok(reply)
            }
            Err(error) => {
                // A run stopped by the deadline may have made the worktree:
                // its retry finds it.
                if error.details["reason"] != "timed_out" {
                    journal.finish();
                }
                Err(error)
            }
        }
    })
}

/// The base, and the first free name in this project's worktree folder.
fn plan(
    repository: &Repository,
    common_dir: &Path,
    fields: &Map<String, Value>,
) -> Result<Attempt, ResourceError> {
    let base = match fields.get("base").and_then(Value::as_str) {
        Some(base) if base.starts_with('-') => {
            let message = format!("{base:?} is not a revision");
            return Err(ResourceError::validation_invalid(Some("base"), message));
        }
        Some(base) => base.to_string(),
        None => match current_branch(repository) {
            Some(branch) => branch,
            None => "HEAD".to_string(),
        },
    };
    let Some(base_commit) = repository.commit(&base) else {
        let message = format!("{base} names no commit to branch from");
        return Err(refused(OPERATION, "base_not_found", message, json!({"base": base})));
    };
    // A branch is recorded by name, so the later diff follows it; anything
    // else (`HEAD~1`, a tag that may move) by the commit it names now.
    let base = if repository.branch_ref(&base).is_some() { base } else { base_commit.clone() };
    let Some(home) = crate::platform::home_dir() else {
        let message = "the session host has no home folder for worktrees";
        return Err(refused(OPERATION, "no_home", message, Value::Null));
    };
    let root = cmux_git::worktree_root::worktree_root(&home).map_err(|error| {
        let message = format!("cannot prepare ~/.cmux/worktrees: {error}");
        refused(OPERATION, "no_worktree_root", message, Value::Null)
    })?;
    let folder = root.join(project(common_dir));
    let name = fields
        .get("name")
        .and_then(Value::as_str)
        .map(slug)
        .filter(|name| !name.is_empty())
        .unwrap_or_else(generated_name);
    let free = |candidate: &str| {
        let branch = format!("refs/heads/{BRANCH_PREFIX}{candidate}");
        !folder.join(candidate).exists() && repository.commit(&branch).is_none()
    };
    let chosen = std::iter::once(name.clone())
        .chain((2..=MAX_SUFFIX).map(|suffix| format!("{name}-{suffix}")))
        .find(|candidate| free(candidate));
    let Some(chosen) = chosen else {
        let message = format!("every worktree name from {name} to {name}-{MAX_SUFFIX} is taken");
        return Err(refused(OPERATION, "name_taken", message, json!({"name": name})));
    };
    Ok(Attempt {
        root: folder.join(&chosen),
        branch: format!("{BRANCH_PREFIX}{chosen}"),
        base,
        base_commit,
    })
}

/// Makes the attempt's worktree and records its base, unless a lost
/// reply's run already made it.
fn create(
    repository: &Repository,
    git: &UserGit<'_>,
    attempt: &Attempt,
) -> Result<(), ResourceError> {
    if !made(attempt) {
        if attempt.root.exists() {
            let message = format!(
                "{} exists and is not a finished worktree on {}",
                attempt.root.display(),
                attempt.branch
            );
            return Err(refused(OPERATION, "path_exists", message, Value::Null));
        }
        if let Some(parent) = attempt.root.parent()
            && let Err(error) = std::fs::create_dir_all(parent)
        {
            let message = format!("{}: {error}", parent.display());
            return Err(refused(OPERATION, "git_failed", message, Value::Null));
        }
        let root = attempt.root.to_string_lossy();
        // A first run stopped mid-checkout leaves the branch it made: the
        // retry checks that branch out instead of making it again.
        let branch_made = repository.commit(&format!("refs/heads/{}", attempt.branch)).is_some();
        let arguments: Vec<&str> = if branch_made {
            vec!["worktree", "add", root.as_ref(), attempt.branch.as_str()]
        } else {
            let branch = attempt.branch.as_str();
            vec!["worktree", "add", "-b", branch, root.as_ref(), attempt.base_commit.as_str()]
        };
        let run = git.run(&arguments).map_err(|failure| run_failed(OPERATION, &failure))?;
        if !run.success && !made(attempt) {
            let message = "git worktree add failed";
            return Err(refused(OPERATION, "git_failed", message, output_extra(&run.output())));
        }
    }
    let setting = format!("branch.{}.cmuxBase", attempt.branch);
    let run = git
        .run(&["config", setting.as_str(), attempt.base.as_str()])
        .map_err(|failure| run_failed(OPERATION, &failure))?;
    if !run.success {
        let message = "the worktree was made, but recording its base failed";
        return Err(refused(OPERATION, "git_failed", message, output_extra(&run.output())));
    }
    Ok(())
}

/// The attempt's worktree exists on its branch and git finished making it:
/// its administrative folder is no longer locked (`git worktree add` locks
/// it while it checks the files out).
fn made(attempt: &Attempt) -> bool {
    let Ok(link) = std::fs::read_to_string(attempt.root.join(".git")) else { return false };
    let Some(admin) = link.trim().strip_prefix("gitdir:").map(str::trim) else { return false };
    if Path::new(admin).join("locked").exists() {
        return false;
    }
    let arguments = ["symbolic-ref", "--quiet", "--short", "HEAD"];
    run_git(&attempt.root, &[], &arguments, MAX_SMALL_OUTPUT_BYTES)
        .is_ok_and(|output| String::from_utf8_lossy(&output.stdout).trim() == attempt.branch)
}

fn described(attempt: &Attempt, common_dir: &Path) -> Value {
    let mut value = json!({
        "root": attempt.root.to_string_lossy(),
        "branch": attempt.branch,
        "base": attempt.base,
        "base_commit": attempt.base_commit,
    });
    if let Some(main) = main_root(common_dir) {
        value.set("main_root", json!(main.to_string_lossy()));
    }
    value
}

/// The project's folder name under `~/.cmux/worktrees`: the main checkout's
/// name, or a bare repository's without `.git`.
fn project(common_dir: &Path) -> String {
    let name = match main_root(common_dir) {
        Some(main) => main.file_name(),
        None => common_dir.file_name(),
    };
    let name = name.map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
    let name = slug(name.strip_suffix(".git").unwrap_or(&name));
    if name.is_empty() { "repository".to_string() } else { name }
}

/// Lowercase ASCII letters and digits, every other run of characters one
/// `-`, at most 48 characters.
fn slug(text: &str) -> String {
    let mut slug = String::new();
    for character in text.chars() {
        if character.is_ascii_alphanumeric() {
            slug.push(character.to_ascii_lowercase());
        } else if !slug.is_empty() && !slug.ends_with('-') {
            slug.push('-');
        }
        if slug.len() >= MAX_NAME_CHARS {
            break;
        }
    }
    slug.trim_end_matches('-').to_string()
}

/// `chat-` and six random hex digits.
fn generated_name() -> String {
    let mut bytes = [0_u8; 3];
    if getrandom::fill(&mut bytes).is_err() {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.subsec_nanos());
        bytes.copy_from_slice(&nanos.to_le_bytes()[..3]);
    }
    format!("chat-{:02x}{:02x}{:02x}", bytes[0], bytes[1], bytes[2])
}
