//! Branch refs: the local and remote branches a picker offers, and the base a
//! branch diff should compare with.

use std::collections::HashSet;
use std::time::{Duration, Instant};

use crate::MAX_SMALL_OUTPUT_BYTES;
use crate::Repository;
use crate::run::GitFailure;

/// `for-each-ref` output read per listing. A line is a ref name, a commit
/// and an upstream, so this holds tens of thousands of branches; past it the
/// listing is marked truncated.
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
    /// `None` without a live upstream, or when the listing's count budget
    /// ran out before this branch.
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

/// Local branches whose ahead and behind counts one listing computes; the
/// rest are listed without them.
const MAX_TRACKED_BRANCHES: usize = 200;

/// The time one listing spends counting ahead and behind, across branches.
/// Past it the remaining branches are listed without counts.
const TRACK_BUDGET: Duration = Duration::from_secs(5);

/// At most `limit` branches: local ones first, then remote ones, each by
/// newest commit, then by name. A returned local branch carries its upstream
/// and, while [`MAX_TRACKED_BRANCHES`] and [`TRACK_BUDGET`] allow, its ahead
/// and behind counts. Counting runs only for the branches returned, so old
/// branches past `limit` cost nothing.
pub fn branches(repository: &Repository, limit: usize) -> Result<Branches, GitFailure> {
    let current = current_branch(repository)?;
    let (locals, mut truncated) = listing(repository, "refs/heads", limit)?;
    let mut listed = track(repository, locals);
    let room = limit.saturating_sub(listed.len());
    let (remotes, remotes_cut) = listing(repository, "refs/remotes", room)?;
    truncated |= remotes_cut;
    listed.extend(remotes.into_iter().map(|(branch, _)| branch));
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

/// The fields of one `for-each-ref` line, NUL-separated. No `upstream:track`:
/// git would count ahead and behind for every branch in the namespace.
const FORMAT: &str = "--format=%(refname)%00%(HEAD)%00%(objectname)%00%(upstream:short)%00\
                      %(upstream)%00%(committerdate:unix)%00%(symref)";

/// A listed branch and its upstream's full ref.
type Listed = (BranchRef, Option<String>);

/// Up to `limit` branches under `namespace`, and whether more exist. The
/// listing is read whole and cut here: `--count` would count the `HEAD`
/// aliases this drops.
fn listing(
    repository: &Repository,
    namespace: &str,
    limit: usize,
) -> Result<(Vec<Listed>, bool), GitFailure> {
    let arguments = [
        "for-each-ref",
        // The last key sorts first: newest commit, then name.
        "--sort=refname",
        "--sort=-committerdate",
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
    let mut branches: Vec<Listed> = lines.into_iter().filter_map(parse_line).collect();
    let more = output.truncated || branches.len() > limit;
    branches.truncate(limit);
    Ok((branches, more))
}

fn parse_line(line: &str) -> Option<Listed> {
    let mut fields = line.split('\0');
    let reference = fields.next()?.to_string();
    let head = fields.next()?;
    let commit = fields.next()?.to_string();
    let upstream = fields.next()?;
    let upstream_ref = fields.next()?;
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
    let upstream_ref =
        (upstream.is_some() && !upstream_ref.is_empty()).then(|| upstream_ref.to_string());
    let branch = BranchRef {
        name,
        reference,
        kind,
        commit,
        current: head == "*",
        upstream,
        upstream_gone: false,
        ahead: None,
        behind: None,
        committed_at: committed_at.parse().ok(),
    };
    Some((branch, upstream_ref))
}

/// Marks the branches whose upstream ref is gone and counts ahead and behind
/// for the others, one bounded `rev-list` per branch. A failed run leaves the
/// facts it would have found out, never the listing.
fn track(repository: &Repository, listed: Vec<Listed>) -> Vec<BranchRef> {
    let upstreams: Vec<&str> =
        listed.iter().filter_map(|(_, upstream)| upstream.as_deref()).collect();
    let live = live_refs(repository, &upstreams);
    let budget = repository.within(Instant::now() + TRACK_BUDGET);
    let mut counted = 0;
    let mut counting = true;
    listed
        .into_iter()
        .map(|(mut branch, upstream)| {
            let (Some(upstream), Some(live)) = (upstream, &live) else { return branch };
            if !live.contains(&upstream) {
                branch.upstream_gone = true;
                return branch;
            }
            if counting && counted < MAX_TRACKED_BRANCHES {
                counted += 1;
                match ahead_behind(&budget, &branch.reference, &upstream) {
                    Some((ahead, behind)) => {
                        branch.ahead = Some(ahead);
                        branch.behind = Some(behind);
                    }
                    // Out of time, or git failed: the rest go uncounted.
                    None => counting = false,
                }
            }
            branch
        })
        .collect()
}

/// Which of `references` exist, in one run; `None` when the run fails.
fn live_refs(repository: &Repository, references: &[&str]) -> Option<HashSet<String>> {
    if references.is_empty() {
        return Some(HashSet::new());
    }
    let mut arguments = vec!["for-each-ref", "--format=%(refname)"];
    arguments.extend_from_slice(references);
    let output = repository.run(&arguments, MAX_LISTING_BYTES).ok()?;
    if output.truncated {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).lines().map(str::to_string).collect())
}

/// Commits on `branch` and not on `upstream`, and the reverse.
fn ahead_behind(repository: &Repository, branch: &str, upstream: &str) -> Option<(u32, u32)> {
    let range = format!("{branch}...{upstream}");
    let arguments = ["rev-list", "--left-right", "--count", range.as_str(), "--"];
    let output = repository.run(&arguments, MAX_SMALL_OUTPUT_BYTES).ok()?;
    let text = String::from_utf8_lossy(&output.stdout);
    let mut counts = text.split_whitespace().map(|count| count.parse::<u64>().ok());
    let ahead = counts.next()??;
    let behind = counts.next()??;
    let clamp = |count: u64| u32::try_from(count).unwrap_or(u32::MAX);
    Some((clamp(ahead), clamp(behind)))
}

/// Why a branch is a base candidate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BaseReason {
    /// [`Repository::recorded_base`]: the base `git.worktree.create` recorded
    /// for HEAD's branch (`branch.<b>.cmuxBase`).
    RecordedBase,
    /// [`Repository::default_branch`]: origin's default branch, else
    /// origin/main, origin/master, main or master.
    DefaultBranch,
    /// The upstream HEAD's branch tracks.
    Upstream,
}

impl BaseReason {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::RecordedBase => "recorded_base",
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
/// suggestion, the base the `git.diff` branch scope uses
/// ([`Repository::base_branch`]). The candidates are HEAD's recorded base,
/// the default branch, then the upstream of HEAD's branch, each only when it
/// exists and differs from the ones before it. Any may be missing; a run
/// that fails counts as missing.
pub fn suggested_base(repository: &Repository) -> Vec<BaseCandidate> {
    let mut candidates: Vec<BaseCandidate> = Vec::new();
    let recorded = repository.recorded_base().map(|(reference, name)| BaseCandidate {
        name,
        reference,
        reason: BaseReason::RecordedBase,
    });
    let default = repository.default_branch().map(|(reference, name)| BaseCandidate {
        name,
        reference,
        reason: BaseReason::DefaultBranch,
    });
    for candidate in [recorded, default, upstream(repository)].into_iter().flatten() {
        if candidates.iter().all(|listed| listed.reference != candidate.reference) {
            candidates.push(candidate);
        }
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
