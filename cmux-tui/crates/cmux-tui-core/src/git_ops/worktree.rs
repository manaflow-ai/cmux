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
//!
//! Once git made it, the project's recipe sets it up without holding the
//! reply (`worktree_setup`): the `.worktreeinclude` files are copied from
//! the main checkout and the setup command runs; the reply's `setup` says
//! it started and which port the worktree keeps.

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
use super::{MAX_SMALL_OUTPUT_BYTES, Repository, worktree_recipe, worktree_setup};
use crate::Mux;
use crate::resource::ResourceError;
use crate::resource_router::ParsedResourceRequest;
use cmux_json::JsonSet as _;

pub(super) const OPERATION: &str = "git.worktree.create";
pub(super) const BRANCH_PREFIX: &str = "cmux/";
const MAX_NAME_CHARS: usize = 48;
/// Suffixes tried after a taken name: `name-2` up to this.
const MAX_SUFFIX: usize = 99;

/// A started create, as the journal keeps it.
#[derive(Debug, Serialize, Deserialize)]
pub(super) struct Attempt {
    pub(super) root: PathBuf,
    pub(super) branch: String,
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
        match create(repository, &git, &attempt, None) {
            Ok(()) => {
                let mut value = described(&attempt, target.common_dir());
                value.set("setup", setup(mux, &attempt, target.common_dir()));
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
pub(super) fn plan(
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
/// reply's run already made it. `review` (a pull request's address) checks
/// it out running none of the checked-out code: no git hook (`post-checkout`)
/// and no filter driver (a `smudge` or `process` command can name a script in
/// the checkout). Its branch records the pull request (`cmuxReview`) before
/// any file is written, so a checkout that fails halfway is still known as
/// a review's (no teardown runs in it), and only a worktree that records it
/// gets the review's files: another creation's worktree that took the name
/// first is refused, never reset.
pub(super) fn create(
    repository: &Repository,
    git: &UserGit<'_>,
    attempt: &Attempt,
    review: Option<&str>,
) -> Result<(), ResourceError> {
    let trusted = review.is_none();
    let marker = format!("branch.{}.cmuxReview", attempt.branch);
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
        let mut arguments: Vec<&str> = vec!["worktree", "add"];
        // Untrusted: made with no files, which come once its own
        // configuration is known (below).
        if !trusted {
            arguments.push("--no-checkout");
        }
        if branch_made {
            arguments.extend([root.as_ref(), attempt.branch.as_str()]);
        } else {
            let branch = attempt.branch.as_str();
            arguments.extend(["-b", branch, root.as_ref(), attempt.base_commit.as_str()]);
        }
        let environment = if trusted { Vec::new() } else { untrusted(&repository.root)? };
        let run = git
            .run_with(&arguments, &borrowed(&environment))
            .map_err(|failure| run_failed(OPERATION, &failure))?;
        if !run.success && !made(attempt) {
            let message = "git worktree add failed";
            return Err(refused(OPERATION, "git_failed", message, output_extra(&run.output())));
        }
        if let Some(url) = review.filter(|_| run.success) {
            // In the worktree's own admin folder too, which stays whatever its
            // HEAD becomes: a detached or switched checkout is still a review's.
            if let Some(admin) = admin_dir(&attempt.root)
                && let Err(error) = std::fs::write(admin.join(REVIEW_FILE), url)
            {
                let message = format!("{}: {error}", admin.display());
                return Err(refused(OPERATION, "git_failed", message, Value::Null));
            }
            let run = git
                .run(&["config", marker.as_str(), url])
                .map_err(|failure| run_failed(OPERATION, &failure))?;
            if !run.success {
                let message = "the worktree was made, but recording its pull request failed";
                return Err(refused(OPERATION, "git_failed", message, output_extra(&run.output())));
            }
        }
    }
    // An ordinary worktree never takes a review's checkout (the pull
    // request's code): its setup recipe would run there.
    if review.is_none() && reviewed(&attempt.root) {
        let message = format!(
            "{} is a pull request review's worktree on {}",
            attempt.root.display(),
            attempt.branch
        );
        return Err(refused(OPERATION, "path_exists", message, Value::Null));
    }
    if let Some(url) = review {
        let recorded = repository
            .run(&["config", "--get", marker.as_str()], 4096)
            .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_string())
            .unwrap_or_default();
        if !recorded.eq_ignore_ascii_case(url) {
            let message = format!(
                "{} is another worktree on {}, not this review's",
                attempt.root.display(),
                attempt.branch
            );
            return Err(refused(OPERATION, "path_exists", message, Value::Null));
        }
    }
    if !trusted {
        // The worktree's own configuration can turn on a filter driver the
        // main checkout's does not (`includeIf "onbranch:..."`): its files are
        // checked out with every driver it sees blanked. Again on a retry, so
        // a run stopped before this step still gets its files.
        let environment = untrusted(&attempt.root)?;
        let checkout = UserGit { root: &attempt.root, deadline: git.deadline };
        let run = checkout
            .run_with(&["reset", "--hard", "--quiet"], &borrowed(&environment))
            .map_err(|failure| run_failed(OPERATION, &failure))?;
        if !run.success {
            let message = "checking out the worktree's files failed";
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

/// The environment a git run in `root` needs to run none of the checked-out
/// code: no hook, no fsmonitor command, and every filter driver `root`'s
/// configuration names blanked. Set through `GIT_CONFIG_COUNT`, which keeps a
/// driver's name whole and wins over every configuration file.
pub(super) fn untrusted(root: &Path) -> Result<Vec<(String, String)>, ResourceError> {
    let mut settings = vec![
        ("core.hooksPath".to_string(), "/dev/null".to_string()),
        ("core.fsmonitor".to_string(), "false".to_string()),
    ];
    let filters =
        cmux_git::filter_overrides(root).map_err(|failure| run_failed(OPERATION, &failure))?;
    settings.extend(filters);
    let mut environment = vec![("GIT_CONFIG_COUNT".to_string(), settings.len().to_string())];
    for (index, (key, value)) in settings.into_iter().enumerate() {
        environment.push((format!("GIT_CONFIG_KEY_{index}"), key));
        environment.push((format!("GIT_CONFIG_VALUE_{index}"), value));
    }
    Ok(environment)
}

pub(super) fn borrowed(environment: &[(String, String)]) -> Vec<(&str, &str)> {
    environment.iter().map(|(name, value)| (name.as_str(), value.as_str())).collect()
}

/// Starts the new worktree's setup from the project's recipe; what the
/// reply says of it.
fn setup(mux: &Mux, attempt: &Attempt, common_dir: &Path) -> Value {
    let main = main_root(common_dir).map(Path::to_path_buf);
    let Some(git_dir) = admin_dir(&attempt.root) else { return json!({"state": "none"}) };
    let resolved =
        worktree_recipe::resolve(mux, main.as_deref(), main.as_deref().unwrap_or(common_dir));
    let root = worktree_setup::resolved(&attempt.root);
    let place = worktree_setup::Place { root, main_root: main, git_dir };
    worktree_setup::start(place, resolved.recipe)
}

/// A linked worktree's own git folder, from its `.git` file.
/// In a review worktree's admin folder: the pull request it checks out.
const REVIEW_FILE: &str = "cmux-review";

/// Whether the worktree at `root` was made for a pull request review
/// (`git.review.start`), whatever its HEAD is now.
pub(super) fn reviewed(root: &Path) -> bool {
    admin_dir(root).is_some_and(|admin| admin.join(REVIEW_FILE).is_file())
}

pub(super) fn admin_dir(root: &Path) -> Option<PathBuf> {
    let link = std::fs::read_to_string(root.join(".git")).ok()?;
    let admin = link.trim().strip_prefix("gitdir:")?.trim();
    let admin = root.join(admin);
    admin.is_dir().then_some(admin)
}

/// The attempt's worktree exists on its branch and git finished making it:
/// its administrative folder is no longer locked (`git worktree add` locks
/// it while it checks the files out).
fn made(attempt: &Attempt) -> bool {
    let Some(admin) = admin_dir(&attempt.root) else { return false };
    if admin.join("locked").exists() {
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
