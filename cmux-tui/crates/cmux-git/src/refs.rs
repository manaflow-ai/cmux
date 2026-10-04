//! Branch refs: the local and remote branches a picker offers, and the base a
//! branch diff should compare with.

use crate::MAX_SMALL_OUTPUT_BYTES;
use crate::Repository;
use crate::run::GitFailure;

/// `for-each-ref` output read per listing. A line is a ref name, a commit
/// and an upstream, so this holds tens of thousands of branches.
const MAX_LISTING_BYTES: usize = 8 * 1024 * 1024;

/// Where a branch lives.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BranchKind {
    /// `refs/heads/*`.
    Local,
    /// `refs/remotes/*`, without a remote's `HEAD` alias.
    Remote,
}

impl BranchKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Local => "local",
            Self::Remote => "remote",
        }
    }
}

/// One branch.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BranchRef {
    /// The short name: `main`, `origin/main`.
    pub name: String,
    /// The full ref: `refs/heads/main`, `refs/remotes/origin/main`.
    pub reference: String,
    pub kind: BranchKind,
    /// The object the ref names.
    pub commit: String,
    /// The branch HEAD is on.
    pub current: bool,
    /// A local branch's upstream, as a short name.
    pub upstream: Option<String>,
    /// The upstream is configured but its ref no longer exists.
    pub upstream_gone: bool,
    /// Commits on this branch and not on its upstream, and the reverse.
    /// `None` without a live upstream.
    pub ahead: Option<u32>,
    pub behind: Option<u32>,
    /// The tip's committer date, in seconds since the epoch; `None` when the
    /// ref names something other than a commit.
    pub committed_at: Option<i64>,
}

/// A repository's branches.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Branches {
    /// The branch HEAD is on (possibly unborn); `None` when detached.
    pub current: Option<String>,
    /// Local branches, then remote ones, each newest commit first.
    pub branches: Vec<BranchRef>,
    /// More branches exist than the limit allowed.
    pub truncated: bool,
}

/// At most `limit` branches: local ones first, then remote ones, each by
/// newest commit, then by name. A local branch carries its upstream and its
/// ahead and behind counts, which git computes per branch.
pub fn branches(repository: &Repository, limit: usize) -> Result<Branches, GitFailure> {
    let current = current_branch(repository)?;
    let (mut listed, mut truncated) = listing(repository, "refs/heads", limit)?;
    let room = limit.saturating_sub(listed.len());
    let (remotes, remotes_cut) = listing(repository, "refs/remotes", room)?;
    truncated |= remotes_cut;
    listed.extend(remotes);
    Ok(Branches { current, branches: listed, truncated })
}

/// The branch HEAD is on, or `None` when HEAD is detached.
fn current_branch(repository: &Repository) -> Result<Option<String>, GitFailure> {
    let arguments = ["symbolic-ref", "--quiet", "--short", "HEAD"];
    match repository.run(&arguments, MAX_SMALL_OUTPUT_BYTES) {
        Ok(output) => {
            let name = String::from_utf8_lossy(&output.stdout).trim().to_string();
            Ok((!name.is_empty()).then_some(name))
        }
        // `--quiet` exits 1 without a message when HEAD is detached.
        Err(GitFailure::Exit(stderr)) if stderr.is_empty() => Ok(None),
        Err(failure) => Err(failure),
    }
}

/// The fields of one `for-each-ref` line, NUL-separated.
const FORMAT: &str = "--format=%(refname)%00%(HEAD)%00%(objectname)%00%(upstream:short)%00\
                      %(upstream:track,nobracket)%00%(committerdate:unix)%00%(symref)";

/// Up to `limit` branches under `namespace`, and whether more exist.
fn listing(
    repository: &Repository,
    namespace: &str,
    limit: usize,
) -> Result<(Vec<BranchRef>, bool), GitFailure> {
    // One more than the limit tells whether any were left out.
    let count = format!("--count={}", limit.saturating_add(1));
    let arguments = [
        "for-each-ref",
        // The last key sorts first: newest commit, then name.
        "--sort=refname",
        "--sort=-committerdate",
        count.as_str(),
        FORMAT,
        namespace,
    ];
    let output = repository.run(&arguments, MAX_LISTING_BYTES)?;
    let text = String::from_utf8_lossy(&output.stdout);
    let mut lines: Vec<&str> = text.lines().collect();
    if output.truncated {
        // The last line may be cut short.
        lines.pop();
    }
    let mut branches: Vec<BranchRef> = lines.into_iter().filter_map(parse_line).collect();
    let more = output.truncated || branches.len() > limit;
    branches.truncate(limit);
    Ok((branches, more))
}

fn parse_line(line: &str) -> Option<BranchRef> {
    let mut fields = line.split('\0');
    let reference = fields.next()?.to_string();
    let head = fields.next()?;
    let commit = fields.next()?.to_string();
    let upstream = fields.next()?;
    let track = fields.next()?;
    let committed_at = fields.next()?;
    let symref = fields.next()?;
    // A remote's `HEAD` names its default branch, which is listed itself.
    if !symref.is_empty() {
        return None;
    }
    let (kind, name) = if let Some(name) = reference.strip_prefix("refs/heads/") {
        (BranchKind::Local, name.to_string())
    } else if let Some(name) = reference.strip_prefix("refs/remotes/") {
        (BranchKind::Remote, name.to_string())
    } else {
        return None;
    };
    let upstream = (!upstream.is_empty()).then(|| upstream.to_string());
    let upstream_gone = upstream.is_some() && track == "gone";
    let (ahead, behind) = if upstream.is_some() && !upstream_gone {
        let (ahead, behind) = parse_track(track);
        (Some(ahead), Some(behind))
    } else {
        (None, None)
    };
    Some(BranchRef {
        name,
        reference,
        kind,
        commit,
        current: head == "*",
        upstream,
        upstream_gone,
        ahead,
        behind,
        committed_at: committed_at.parse().ok(),
    })
}

/// `ahead 2, behind 1`, `ahead 2`, `behind 1`, or empty when in step.
fn parse_track(track: &str) -> (u32, u32) {
    let mut ahead = 0;
    let mut behind = 0;
    for part in track.split(", ") {
        if let Some(count) = part.strip_prefix("ahead ") {
            ahead = count.parse().unwrap_or(0);
        } else if let Some(count) = part.strip_prefix("behind ") {
            behind = count.parse().unwrap_or(0);
        }
    }
    (ahead, behind)
}

/// Why a branch is a base candidate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BaseReason {
    /// [`Repository::base_branch`]: origin's default branch, else
    /// origin/main, origin/master, main or master.
    DefaultBranch,
    /// The upstream HEAD's branch tracks.
    Upstream,
}

impl BaseReason {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::DefaultBranch => "default_branch",
            Self::Upstream => "upstream",
        }
    }
}

/// A branch a branch diff may compare with.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BaseCandidate {
    /// The short name: `origin/main`.
    pub name: String,
    /// The full ref: `refs/remotes/origin/main`.
    pub reference: String,
    pub reason: BaseReason,
}

/// The bases a branch diff may compare with, best first; the first is the
/// suggestion. Version 1 offers [`Repository::base_branch`], which the
/// `git.diff` branch scope uses, then the upstream of HEAD's branch when it is
/// a different, existing ref. Either may be missing; a run that fails counts
/// as missing.
pub fn suggested_base(repository: &Repository) -> Vec<BaseCandidate> {
    let mut candidates = Vec::new();
    if let Some((reference, name)) = repository.base_branch() {
        candidates.push(BaseCandidate { name, reference, reason: BaseReason::DefaultBranch });
    }
    if let Some(upstream) = upstream(repository)
        && candidates.iter().all(|candidate| candidate.reference != upstream.reference)
    {
        candidates.push(upstream);
    }
    candidates
}

/// The upstream of HEAD's branch, when it resolves to a commit.
fn upstream(repository: &Repository) -> Option<BaseCandidate> {
    let arguments = ["rev-parse", "--symbolic-full-name", "HEAD@{upstream}"];
    let output = repository.run(&arguments, MAX_SMALL_OUTPUT_BYTES).ok()?;
    let reference = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let name = reference
        .strip_prefix("refs/remotes/")
        .or_else(|| reference.strip_prefix("refs/heads/"))?
        .to_string();
    repository.commit(&reference)?;
    Some(BaseCandidate { name, reference, reason: BaseReason::Upstream })
}
