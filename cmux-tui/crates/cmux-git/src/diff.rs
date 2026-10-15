//! A diff scope as the revisions `git diff` compares, and the argument lists
//! that read it. Field validation, file reads and reply shaping belong to the
//! caller.

use crate::MAX_SMALL_OUTPUT_BYTES;
use crate::Repository;
use crate::run::GitFailure;

/// What a scope compares.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Comparison {
    /// The `git diff` revisions; `None` when there is nothing tracked to
    /// compare (committed, before the first commit).
    pub revisions: Option<Vec<String>>,
    pub cached: bool,
    pub untracked: bool,
    pub head: Option<String>,
    pub base: Option<String>,
}

/// Why a scope has no comparison.
#[derive(Debug)]
pub enum ScopeError {
    /// The scope is not one of `uncommitted`, `unstaged`, `staged`,
    /// `committed` or `branch`.
    UnknownScope(String),
    /// The branch scope found no base branch.
    NoBaseBranch,
    /// HEAD and the base branch (its short name) share no commit.
    NoMergeBase {
        base: String,
    },
    Git(GitFailure),
}

impl std::fmt::Display for ScopeError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::UnknownScope(scope) => write!(formatter, "unknown scope {scope:?}"),
            Self::NoBaseBranch => formatter.write_str(
                "no base branch: origin's default branch, main and master are all missing",
            ),
            Self::NoMergeBase { base } => {
                write!(formatter, "HEAD and {base} have no common commit")
            }
            Self::Git(failure) => formatter.write_str(&failure.reason()),
        }
    }
}

impl std::error::Error for ScopeError {}

/// The comparison a scope names: `uncommitted` (HEAD, or the empty tree,
/// against the working tree plus untracked files), `unstaged`, `staged`,
/// `committed` (HEAD against its first parent) or `branch` (the merge base
/// with [`Repository::base_branch`] against the working tree plus untracked
/// files).
pub fn comparison(repository: &Repository, scope: &str) -> Result<Comparison, ScopeError> {
    let head = repository.commit("HEAD");
    let empty_tree = || repository.empty_tree().map_err(ScopeError::Git);
    let compare = |revisions: Vec<String>, cached: bool, untracked: bool, base: Option<String>| {
        Comparison { revisions: Some(revisions), cached, untracked, head: head.clone(), base }
    };
    Ok(match scope {
        "uncommitted" => {
            let tree = match &head {
                Some(head) => head.clone(),
                None => empty_tree()?,
            };
            compare(vec![tree], false, true, None)
        }
        "unstaged" => compare(Vec::new(), false, true, None),
        "staged" => compare(Vec::new(), true, false, None),
        "committed" => match &head {
            None => Comparison {
                revisions: None,
                cached: false,
                untracked: false,
                head: None,
                base: None,
            },
            Some(commit) => {
                let parent = repository.commit(&format!("{commit}^1"));
                let from = match &parent {
                    Some(parent) => parent.clone(),
                    None => empty_tree()?,
                };
                compare(vec![from, commit.clone()], false, false, parent)
            }
        },
        "branch" => {
            let merge_base = merge_base(repository)?;
            compare(vec![merge_base.clone()], false, true, Some(merge_base))
        }
        other => return Err(ScopeError::UnknownScope(other.to_string())),
    })
}

/// One tree against another, with nothing untracked.
pub fn between(repository: &Repository, from: String, to: String) -> Comparison {
    Comparison {
        revisions: Some(vec![from, to]),
        cached: false,
        untracked: false,
        head: repository.commit("HEAD"),
        base: None,
    }
}

/// The merge base of HEAD and [`Repository::base_branch`].
pub fn merge_base(repository: &Repository) -> Result<String, ScopeError> {
    let Some((reference, short)) = repository.base_branch() else {
        return Err(ScopeError::NoBaseBranch);
    };
    let arguments = ["merge-base", "HEAD", reference.as_str()];
    match repository.run(&arguments, MAX_SMALL_OUTPUT_BYTES) {
        Ok(output) => Ok(String::from_utf8_lossy(&output.stdout).trim().to_string()),
        Err(GitFailure::Exit(_)) => Err(ScopeError::NoMergeBase { base: short }),
        Err(failure) => Err(ScopeError::Git(failure)),
    }
}

/// `git diff` for a comparison in one output `mode` (`--name-status -z`,
/// `--numstat -z`, `--patch`), limited to `paths`. External diff and textconv
/// programs are off, paths are root-relative and use the `a/` and `b/`
/// prefixes [`crate::parse::patches`] expects.
pub fn diff_args<'a>(
    comparison: &'a Comparison,
    mode: &[&'a str],
    paths: &'a [String],
) -> Vec<&'a str> {
    let mut args = vec![
        "diff",
        "--no-color",
        "--no-ext-diff",
        "--no-textconv",
        "--no-relative",
        "--ignore-submodules=dirty",
        "-M",
        "--src-prefix=a/",
        "--dst-prefix=b/",
    ];
    args.extend_from_slice(mode);
    if comparison.cached {
        args.push("--cached");
    }
    if let Some(revisions) = &comparison.revisions {
        args.extend(revisions.iter().map(String::as_str));
    }
    args.push("--");
    args.extend(paths.iter().map(String::as_str));
    args
}

/// Untracked files that are not ignored, NUL-separated, limited to `paths`.
pub fn untracked_args(paths: &[String]) -> Vec<&str> {
    let mut args = vec!["ls-files", "--others", "--exclude-standard", "-z", "--"];
    args.extend(paths.iter().map(String::as_str));
    args
}
