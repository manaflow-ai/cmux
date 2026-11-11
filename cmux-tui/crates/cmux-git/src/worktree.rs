//! The worktree rules cmux-tui and acpmux share, so a worktree made by one
//! is named, kept and removed the same way by the other:
//!
//! - cmux-tui-core's `git.worktree.create` and `git.worktree.remove` (`cmux
//!   git worktree create|remove`, `cmux workspace create --worktree`, `cmux
//!   workspace <ws> close --remove-worktree`);
//! - acpmux's `acpmux new --worktree` (`subsession_worktree.rs`) and `acpmux
//!   worktree remove`.
//!
//! Each tool still runs git its own way (cmux-tui in the user's environment
//! with their hooks, acpmux hardened against the repository's config); what
//! they share is here:
//!
//! - the branch: `cmux/<name>` unless the caller names one ([`branch_for`]),
//!   and the mark that cmux made it ([`created_key`]), which decides whether
//!   the branch goes with the worktree ([`branch_goes_with_worktree`]);
//! - the work a removal keeps unless told to discard it ([`work_kept`]):
//!   uncommitted changes, and commits on no other branch and no remote; its
//!   refusal names `--discard`;
//! - the paths ([`shown`], [`same_folder`], [`folder_spellings`]) and the
//!   empty project folder a project's last worktree leaves
//!   ([`remove_empty_project_folder`]).
//!
//! **The path rule.** cmux shows a folder as it was given or as cmux made
//! it: `~/.cmux/worktrees/<project>/<name>` (not the `worktrees.noindex`
//! folder that link resolves to on macOS) and `/tmp/x` (not `/private/tmp/x`).
//! It compares folders by their resolved form, so either spelling names the
//! same folder in every command that takes one.

use std::path::{Path, PathBuf};

use crate::run::GitFailure;
use crate::worktree_root::worktree_root_path;
use crate::{MAX_SMALL_OUTPUT_BYTES, Repository};

/// The prefix of the branch a worktree gets when the caller names none.
pub const BRANCH_PREFIX: &str = "cmux/";

/// The uncommitted paths a refusal lists.
pub const MAX_LISTED_FILES: usize = 20;

/// The most bytes of `git status` [`work_kept`] reads.
const MAX_STATUS_BYTES: usize = 256 * 1024;

/// The branch a new worktree named `name` (already a slug) is on:
/// `requested` when the caller names one (checked with
/// [`check_branch_name`]), else `cmux/<name>`.
pub fn branch_for(name: &str, requested: Option<&str>) -> Result<String, BadBranchName> {
    match requested {
        None => Ok(format!("{BRANCH_PREFIX}{name}")),
        Some(branch) => {
            check_branch_name(branch)?;
            Ok(branch.to_owned())
        }
    }
}

/// Why a branch name is refused ([`check_branch_name`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BranchProblem {
    /// The name is empty.
    Empty,
    /// It starts with `-`, so git would read it as an option.
    LeadingDash,
    /// `@` or `HEAD`, which git keeps for itself.
    Reserved,
    /// It starts or ends with `/`, or has an empty part (`//`).
    EmptyPart,
    /// It ends with `.`, or has `..` or `@{` in it.
    Dots,
    /// It has this character, which git refuses in a ref.
    Character(char),
    /// A part of it starts with `.` or ends with `.lock`.
    DotPart,
}

/// A branch name git would refuse, and why; `Display` is the English
/// message, [`BadBranchName::japanese`] the Japanese one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BadBranchName {
    /// The name as given.
    pub branch: String,
    /// Why it is refused.
    pub problem: BranchProblem,
}

impl std::fmt::Display for BadBranchName {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let why = match self.problem {
            BranchProblem::Empty => "it is empty".to_owned(),
            BranchProblem::LeadingDash => "it starts with -".to_owned(),
            BranchProblem::Reserved => "git keeps that name for itself".to_owned(),
            BranchProblem::EmptyPart => "it starts or ends with /, or has an empty part".to_owned(),
            BranchProblem::Dots => "it ends with ., or has .. or @{ in it".to_owned(),
            BranchProblem::Character(bad) => format!("it has {bad:?} in it"),
            BranchProblem::DotPart => "a part of it starts with . or ends with .lock".to_owned(),
        };
        write!(f, "{:?} is no branch name: {why}", self.branch)
    }
}

impl std::error::Error for BadBranchName {}

impl BadBranchName {
    /// The message in Japanese.
    pub fn japanese(&self) -> String {
        let why = match self.problem {
            BranchProblem::Empty => "空です".to_owned(),
            BranchProblem::LeadingDash => "- で始まっています".to_owned(),
            BranchProblem::Reserved => "git が自分用に使う名前です".to_owned(),
            BranchProblem::EmptyPart => "/ で始まるか終わっているか、空の部分があります".to_owned(),
            BranchProblem::Dots => ". で終わっているか、.. または @{ が入っています".to_owned(),
            BranchProblem::Character(bad) => format!("{bad:?} が入っています"),
            BranchProblem::DotPart => ". で始まるか .lock で終わる部分があります".to_owned(),
        };
        format!("{:?} はブランチ名に使えません: {why}", self.branch)
    }
}

/// Refuses a branch name git refuses (`git check-ref-format --branch`), or
/// one that reads as an option, without running git.
pub fn check_branch_name(branch: &str) -> Result<(), BadBranchName> {
    let refuse = |problem| Err(BadBranchName { branch: branch.to_owned(), problem });
    if branch.is_empty() {
        return refuse(BranchProblem::Empty);
    }
    if branch.starts_with('-') {
        return refuse(BranchProblem::LeadingDash);
    }
    if branch == "@" || branch == "HEAD" {
        return refuse(BranchProblem::Reserved);
    }
    if branch.starts_with('/') || branch.ends_with('/') || branch.contains("//") {
        return refuse(BranchProblem::EmptyPart);
    }
    if branch.ends_with('.') || branch.contains("..") || branch.contains("@{") {
        return refuse(BranchProblem::Dots);
    }
    if let Some(bad) = branch.chars().find(|c| {
        c.is_ascii_control() || matches!(*c, ' ' | '~' | '^' | ':' | '?' | '*' | '[' | '\\')
    }) {
        return refuse(BranchProblem::Character(bad));
    }
    if branch.split('/').any(|part| part.starts_with('.') || part.ends_with(".lock")) {
        return refuse(BranchProblem::DotPart);
    }
    Ok(())
}

/// The setting that marks `branch` as one cmux made with a worktree:
/// `branch.<branch>.cmuxCreated`.
pub fn created_key(branch: &str) -> String {
    format!("branch.{branch}.cmuxCreated")
}

/// The setting that records the revision `branch` was made from:
/// `branch.<branch>.cmuxBase`.
pub fn base_key(branch: &str) -> String {
    format!("branch.{branch}.cmuxBase")
}

/// Whether the branch goes with its worktree: cmux made it (the
/// [`created_key`] mark), or it is a `cmux/<name>` branch with a recorded
/// base (what cmux made before the mark). A branch that was there before its
/// worktree, `--branch` named or not, stays.
pub fn branch_goes_with_worktree(repository: &Repository, branch: &str) -> bool {
    let get = |key: String| {
        repository
            .run(&["config", "--get", key.as_str()], MAX_SMALL_OUTPUT_BYTES)
            .ok()
            .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_owned())
    };
    if get(created_key(branch)).as_deref() == Some("true") {
        return true;
    }
    branch.starts_with(BRANCH_PREFIX) && get(base_key(branch)).is_some()
}

/// Work a worktree's removal keeps unless told to discard it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KeptWork {
    /// Tracked or untracked files differ from HEAD: up to
    /// [`MAX_LISTED_FILES`] of them, and how many there are (`truncated`:
    /// more than git's status output cmux reads).
    Uncommitted { files: Vec<String>, count: usize, truncated: bool },
    /// `count` commits only the worktree's HEAD reaches: on the branch that
    /// goes with it, or on a detached HEAD (`branch` None).
    Unpushed { branch: Option<String>, count: u64 },
}

impl KeptWork {
    /// The machine reason: `uncommitted_changes` or `unpushed_commits`.
    pub fn reason(&self) -> &'static str {
        match self {
            Self::Uncommitted { .. } => "uncommitted_changes",
            Self::Unpushed { .. } => "unpushed_commits",
        }
    }

    /// [`KeptWork::message`] in Japanese.
    pub fn japanese(&self) -> String {
        match self {
            Self::Uncommitted { count, truncated, .. } => {
                let more = if *truncated { " 以上" } else { "" };
                format!(
                    "ワークツリーにコミットされていない変更があります ({count}{more} ファイル)。\
                     コミットまたはスタッシュするか、--discard で削除してください (変更は失われます)"
                )
            }
            Self::Unpushed { branch, count } => {
                let at = branch.as_deref().unwrap_or("切り離された HEAD");
                format!(
                    "{at} には、ほかのどのブランチにもリモートにもないコミットが {count} 個あります。\
                     プッシュまたはマージするか、--discard で削除してください (コミットは失われます)"
                )
            }
        }
    }

    /// What keeps the worktree and how to remove it anyway (`--discard`).
    pub fn message(&self) -> String {
        match self {
            Self::Uncommitted { count, truncated, .. } => {
                let more = if *truncated { " or more" } else { "" };
                format!(
                    "the worktree has uncommitted changes ({count}{more} files); commit or stash \
                     them, or remove it anyway with --discard (they are lost)"
                )
            }
            Self::Unpushed { branch, count } => {
                let at = branch.as_deref().unwrap_or("the detached HEAD");
                format!(
                    "{at} has {count} commits on no other branch or remote; push or merge them, \
                     or remove it anyway with --discard (they are lost)"
                )
            }
        }
    }
}

/// The work that keeps the worktree `repository` is: uncommitted changes
/// (tracked or untracked files, changed submodules too), else commits only
/// its HEAD reaches when the branch goes with it (`branch_goes`) or HEAD is
/// detached (`branch` None). None when nothing would be lost.
pub fn work_kept(
    repository: &Repository,
    branch: Option<&str>,
    branch_goes: bool,
) -> Result<Option<KeptWork>, GitFailure> {
    let arguments = [
        "status",
        "--porcelain",
        "-z",
        "--untracked-files=all",
        "--no-renames",
        "--ignore-submodules=none",
    ];
    // Submodules stay in the status (a changed one is work to keep, even one
    // `submodule.<name>.ignore` hides), so their own filter drivers are
    // blanked too.
    let output = repository
        .with_submodule_filters()
        .and_then(|repository| repository.run(&arguments, MAX_STATUS_BYTES))?;
    let files: Vec<String> = output
        .stdout
        .split(|byte| *byte == 0)
        .filter_map(|entry| entry.get(3..))
        .filter(|path| !path.is_empty())
        .map(|path| String::from_utf8_lossy(path).into_owned())
        .collect();
    if !files.is_empty() || output.truncated {
        let count = files.len();
        let files = files.into_iter().take(MAX_LISTED_FILES).collect();
        return Ok(Some(KeptWork::Uncommitted { files, count, truncated: output.truncated }));
    }
    unpushed(repository, branch, branch_goes)
}

/// The commits only the worktree's HEAD reaches, when they would be lost:
/// the branch goes with it (`branch_goes`) or HEAD is detached.
pub fn unpushed(
    repository: &Repository,
    branch: Option<&str>,
    branch_goes: bool,
) -> Result<Option<KeptWork>, GitFailure> {
    if branch.is_some() && !branch_goes {
        return Ok(None);
    }
    let count = commits_only_on(repository, "HEAD", branch)?;
    Ok((count > 0).then(|| KeptWork::Unpushed { branch: branch.map(str::to_owned), count }))
}

/// How many of `revision`'s commits are on no branch but `branch` and on no
/// remote.
pub fn commits_only_on(
    repository: &Repository,
    revision: &str,
    branch: Option<&str>,
) -> Result<u64, GitFailure> {
    let exclude = branch.map(|branch| format!("--exclude={branch}"));
    let mut arguments = vec!["rev-list", "--count", revision, "--not"];
    arguments.extend(exclude.as_deref());
    arguments.extend(["--branches", "--remotes"]);
    let output = repository.run(&arguments, MAX_SMALL_OUTPUT_BYTES)?;
    String::from_utf8_lossy(&output.stdout)
        .trim()
        .parse::<u64>()
        .map_err(|_| GitFailure::Exit("git rev-list --count answered no count".to_owned()))
}

/// `path` with links resolved, through its parent once it is gone.
pub fn resolved(path: &Path) -> PathBuf {
    if let Ok(path) = std::fs::canonicalize(path) {
        return path;
    }
    match (path.parent().and_then(|parent| std::fs::canonicalize(parent).ok()), path.file_name()) {
        (Some(parent), Some(name)) => parent.join(name),
        _ => path.to_path_buf(),
    }
}

/// Whether `a` and `b` name the same folder, links resolved.
pub fn same_folder(a: &Path, b: &Path) -> bool {
    a == b || resolved(a) == resolved(b)
}

/// `path` as cmux shows it: a folder in cmux's worktree root under the
/// `home/.cmux/worktrees` link it made (not the `worktrees.noindex` folder
/// git resolves it to), any other path as it is.
pub fn shown(home: &Path, path: &Path) -> PathBuf {
    let link = worktree_root_path(home);
    let Ok(real) = std::fs::canonicalize(&link) else { return path.to_path_buf() };
    match resolved(path).strip_prefix(&real) {
        Ok(rest) if rest.as_os_str().is_empty() => link,
        Ok(rest) => link.join(rest),
        Err(_) => path.to_path_buf(),
    }
}

/// `path` (as git gives it, links resolved) spelled the way the person gave
/// the folder `given`: a folder in cmux's worktree root under its link (as
/// [`shown`]), else under the deepest folder of `given` whose resolved form
/// holds it, else on macOS without the `/private` that `/tmp`, `/var` and
/// `/etc` resolve to. Compare paths with [`same_folder`]; print them with this.
///
/// ```
/// # use std::path::Path;
/// // Nothing is a link here, so the path stays as it is.
/// let path = cmux_git::worktree::as_given(Path::new("/nonexistent-home"), Path::new("/no/such/a"), Path::new("/no/such/b"));
/// assert_eq!(path, Path::new("/no/such/b"));
/// ```
pub fn as_given(home: &Path, given: &Path, path: &Path) -> PathBuf {
    let in_root = shown(home, path);
    if in_root != path {
        return in_root;
    }
    for folder in given.ancestors().filter(|folder| folder.parent().is_some()) {
        if let Ok(rest) = path.strip_prefix(resolved(folder)) {
            return if rest.as_os_str().is_empty() {
                folder.to_path_buf()
            } else {
                folder.join(rest)
            };
        }
    }
    for alias in ["tmp", "var", "etc"] {
        let short = Path::new("/").join(alias);
        let private = Path::new("/private").join(alias);
        if let Ok(rest) = path.strip_prefix(&private)
            && resolved(&short) == private
        {
            return short.join(rest);
        }
    }
    path.to_path_buf()
}

/// Every spelling of the folder `path` cmux records: as given, with links
/// resolved, under the worktree root link (`home`, when known), and on macOS
/// without the `/private` that `/tmp`, `/var` and `/etc` resolve to. A
/// filter that compares recorded folders as text matches any of them, so
/// `/tmp/x` finds a chat recorded in `/private/tmp/x` and back.
pub fn folder_spellings(path: &Path, home: Option<&Path>) -> Vec<PathBuf> {
    let real = resolved(path);
    let mut spellings = vec![path.to_path_buf(), real.clone()];
    if let Some(home) = home {
        spellings.push(shown(home, &real));
    }
    for alias in ["tmp", "var", "etc"] {
        let private = Path::new("/private").join(alias);
        if let Ok(rest) = real.strip_prefix(&private) {
            spellings.push(Path::new("/").join(alias).join(rest));
        }
    }
    let mut unique = Vec::new();
    for spelling in spellings {
        if !unique.contains(&spelling) {
            unique.push(spelling);
        }
    }
    unique
}

/// Removes the project folder that held the worktree at `root` once it is
/// empty, after the worktree went: only a folder directly in cmux's worktree
/// root (`home/.cmux/worktrees`), never the root itself, and never a folder
/// that still holds anything (`remove_dir` refuses those, so a worktree made
/// there meanwhile keeps it). Whether it went.
pub fn remove_empty_project_folder(home: &Path, root: &Path) -> bool {
    let Ok(real) = std::fs::canonicalize(worktree_root_path(home)) else { return false };
    let Some(project) = resolved(root).parent().map(Path::to_path_buf) else { return false };
    project.parent() == Some(real.as_path())
        && project != real
        && std::fs::remove_dir(&project).is_ok()
}

#[cfg(all(test, unix))]
#[path = "worktree_tests.rs"]
mod tests;
