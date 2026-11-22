//! `git.worktree.create`: a chat's own worktree, so an agent works on a
//! branch of its own while the user's checkout stays as it is. The worktree
//! is `~/.cmux/worktrees/<project>/<name>` (with `agentPane.sessionWorktrees`
//! set to `project`, `<project>/.claude/worktrees/<name>`) on a new branch `cmux/<name>`,
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
use cmux_config::session_worktrees::{self, SessionWorktrees};
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
                let setting = cmux_config::Target::Key(session_worktrees::KEY.to_string());
                let place = mux.with_settings(|state| {
                    SessionWorktrees::parse(
                        state.get(&setting).row.and_then(|row| row.value).as_ref(),
                    )
                });
                // The folder is chosen once: a retry reads the root the journal kept.
                let folder = storage_folder(target.common_dir(), place)?;
                let attempt = plan(repository, &folder, &request.fields)?;
                journal.start(&fingerprint, &attempt)?;
                attempt
            }
        };
        match create(repository, &git, &attempt, target.common_dir()) {
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

/// The folder this project's worktrees go in: `~/.cmux/worktrees/<project>`,
/// or with `place` Project, `<project>/.claude/worktrees`, made with a
/// `.gitignore` of `*` so the main checkout's status never lists them (and
/// the ignore file ignores itself; the repository's own settings are never
/// edited).
fn storage_folder(common_dir: &Path, place: SessionWorktrees) -> Result<PathBuf, ResourceError> {
    if place.in_project() {
        let Some(main) = main_root(common_dir) else {
            let message = "this repository has no main checkout to keep worktrees in";
            return Err(refused(OPERATION, "no_project_folder", message, Value::Null));
        };
        let folder = session_worktrees::PROJECT_FOLDER
            .iter()
            .fold(main.to_path_buf(), |path, name| path.join(name));
        let fail = |error: std::io::Error| {
            let message = format!("cannot prepare {}: {error}", folder.display());
            refused(OPERATION, "no_worktree_root", message, Value::Null)
        };
        if let Some(parent) = folder.parent() {
            std::fs::create_dir_all(parent).map_err(fail)?;
        }
        match std::fs::create_dir(&folder) {
            Ok(()) => {
                use std::io::Write as _;
                std::fs::File::create_new(folder.join(".gitignore"))
                    .and_then(|mut file| file.write_all(b"*\n"))
                    .map_err(fail)?;
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                if !std::fs::symlink_metadata(&folder).map_err(fail)?.is_dir() {
                    return Err(fail(std::io::Error::other("not a folder")));
                }
            }
            Err(error) => return Err(fail(error)),
        }
        return Ok(folder);
    }
    let Some(home) = crate::platform::home_dir() else {
        let message = "the session host has no home folder for worktrees";
        return Err(refused(OPERATION, "no_home", message, Value::Null));
    };
    let root = cmux_git::worktree_root::worktree_root(&home).map_err(|error| {
        let message = format!("cannot prepare ~/.cmux/worktrees: {error}");
        refused(OPERATION, "no_worktree_root", message, Value::Null)
    })?;
    Ok(root.join(project(common_dir)))
}

/// The base, and the first free name in this project's worktree folder.
fn plan(
    repository: &Repository,
    folder: &Path,
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
/// reply's run already made it in the repository whose git folder is
/// `common_dir` ([`made`]). A success of `git worktree add` is not enough:
/// the folder is given only when this repository keeps it as its worktree
/// ([`kept`]), else the create is refused with `git_failed`. The folder and
/// the branch that git made stay, and the message names them.
fn create(
    repository: &Repository,
    git: &UserGit<'_>,
    attempt: &Attempt,
    common_dir: &Path,
) -> Result<(), ResourceError> {
    if let Some(why) = not_made(attempt, common_dir) {
        if attempt.root.exists() {
            // The reply names no cause; the session host's log has it.
            eprintln!(
                "cmux-tui: {}: not a finished worktree on {}: {why}",
                attempt.root.display(),
                attempt.branch
            );
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
        if !run.success && !made(attempt, common_dir) {
            let message = "git worktree add failed";
            return Err(refused(OPERATION, "git_failed", message, output_extra(&run.output())));
        }
        if run.success && !kept(attempt, common_dir) {
            let message = format!(
                "git worktree add ended, and {root} is not a worktree that this repository keeps; \
                 the folder and the branch {} stay",
                attempt.branch
            );
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

/// Starts the new worktree's setup from the project's recipe; what the
/// reply says of it. The ports of the worktree are in `common_dir`, the
/// repository's git folder. No setup starts and no port is given when the
/// folder that the worktree's `.git` file names is not the git folder that
/// this repository keeps for the worktree
/// ([`worktree_setup::Place::is_of`]): a line on stderr says so, or it gives
/// the kind of the error of the open when the place did not open that
/// folder. The check is of the folder that the place opened, and the setup
/// keeps that folder.
fn setup(mux: &Mux, attempt: &Attempt, common_dir: &Path) -> Value {
    let main = main_root(common_dir).map(Path::to_path_buf);
    let Some(git_dir) = admin_dir(&attempt.root) else { return json!({"state": "none"}) };
    let root = worktree_setup::resolved(&attempt.root);
    let place = worktree_setup::Place::new(root, main, &git_dir, common_dir);
    if !place.is_of(common_dir) {
        let why = match place.not_opened() {
            Some(kind) => format!("is not open ({kind})"),
            None => format!(
                "is not the git folder that {} keeps for this worktree",
                common_dir.display()
            ),
        };
        eprintln!(
            "cmux-tui: {}: no setup starts: the folder that the `.git` file names {why}",
            attempt.root.display()
        );
        return json!({"state": "none"});
    }
    let main = place.main_root.as_deref();
    let resolved = worktree_recipe::resolve(mux, main, main.unwrap_or(common_dir));
    worktree_setup::start(place, resolved.recipe)
}

/// A linked worktree's own git folder, from its `.git` file. The file is
/// read as a file that cmux keeps in a git folder is read
/// ([`worktree_setup::read_small`]): a regular file only, at most 1 MiB of
/// it, with no wait, and a link in its place is not followed.
pub(super) fn admin_dir(root: &Path) -> Option<PathBuf> {
    let link = String::from_utf8(worktree_setup::read_small(root, ".git")?).ok()?;
    let admin = link.trim().strip_prefix("gitdir:")?.trim();
    let admin = root.join(admin);
    admin.is_dir().then_some(admin)
}

/// The repository whose git folder is `common_dir` keeps the attempt's folder
/// as its worktree, by the check that the setup of the worktree has
/// ([`worktree_setup::keeps`]).
fn kept(attempt: &Attempt, common_dir: &Path) -> bool {
    admin_dir(&attempt.root)
        .is_some_and(|admin| worktree_setup::keeps(&admin, &attempt.root, common_dir))
}

/// The attempt's worktree exists on its branch and git finished making it:
/// its administrative folder is no longer locked (`git worktree add` locks
/// it while it checks the files out). The worktree is of the repository
/// whose git folder is `common_dir`, by the check that its setup has
/// ([`worktree_setup::keeps`]): a folder that is a worktree of a different
/// repository on the same branch is not the worktree of this create. The
/// check and the look for the lock are at one open of the administrative
/// folder ([`worktree_setup::kept`]). When a create finds a folder that is
/// not a made worktree, a line on stderr says which of these it is
/// ([`not_made`]).
fn made(attempt: &Attempt, common_dir: &Path) -> bool {
    not_made(attempt, common_dir).is_none()
}

/// Why the attempt's folder is not a made worktree ([`made`]); `None` for a
/// made worktree. The text is for a line on stderr, not for a reply.
fn not_made(attempt: &Attempt, common_dir: &Path) -> Option<String> {
    let Some(admin) = admin_dir(&attempt.root) else {
        return Some("it has no `.git` file that names a git folder".to_string());
    };
    let named = "the folder that its `.git` file names";
    let why = match worktree_setup::kept(&admin, &attempt.root, common_dir) {
        worktree_setup::Kept::Yes => None,
        worktree_setup::Kept::Locked => Some("git has its lock on the worktree".to_string()),
        worktree_setup::Kept::No => {
            let keeper = common_dir.display();
            Some(format!("{named} is not the git folder that {keeper} keeps for this worktree"))
        }
        worktree_setup::Kept::NotOpened(kind) => Some(format!("{named} is not open ({kind})")),
    };
    if why.is_some() {
        return why;
    }
    let arguments = ["symbolic-ref", "--quiet", "--short", "HEAD"];
    let on_branch = run_git(&attempt.root, &[], &arguments, MAX_SMALL_OUTPUT_BYTES)
        .is_ok_and(|output| String::from_utf8_lossy(&output.stdout).trim() == attempt.branch);
    (!on_branch).then(|| "its HEAD is not on the branch".to_string())
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

#[cfg(test)]
mod tests;
