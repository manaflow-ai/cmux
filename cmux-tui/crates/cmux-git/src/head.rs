//! What a checkout's HEAD is on: the branch, its commit, its upstream and how
//! far the two are apart, without a look at the work tree.
//!
//! `git status --porcelain=v2 --branch` prints these as its branch headers,
//! but it also reads the index and looks at each tracked file, which grows
//! with the checkout, and it is a run that can read file content. A view
//! that shows a branch asks for them often and a person waits for the
//! answer, so a [`Checkout`] reads them from the refs:
//!
//! - `symbolic-ref HEAD` names the branch;
//! - one `for-each-ref` of that branch gives its commit, its upstream and
//!   the counts. git fills `%(upstream:short)` and `%(upstream:track)` with
//!   the functions that fill the status headers (`branch_get_upstream`,
//!   `stat_tracking_info`, `shorten_unambiguous_ref`). `--points-at=HEAD`
//!   keeps the line only when its commit is the one that git resolves HEAD
//!   to: the ref list has the names as they are stored, and on a file
//!   system that ignores case git can resolve HEAD through a file that has
//!   another name than the listed one.
//!
//! The refs answer for a HEAD that is on a branch that has a commit. In each
//! other form only the status run says what its headers hold: with no commit
//! `for-each-ref` has no line for the branch, though it may have an
//! upstream; a detached HEAD gets the upstream of the branch that has the
//! name of the place HEAD was detached at; a branch name that is not UTF-8
//! cannot go back to git as an argument. For those the status run stays,
//! limited to the path `.git`, which no tracked file has, so git looks at no
//! tracked file (each run of this crate sets `GIT_OPTIONAL_LOCKS=0`; with no
//! such setting the status run looks at each of them to refresh the index);
//! and because it is a run that can read content, the filter drivers are
//! blanked for it, as [`Repository::open`] does.

use std::path::{Path, PathBuf};

use crate::parse::{self, BranchHeaders};
use crate::run::GitFailure;
use crate::{MAX_SMALL_OUTPUT_BYTES, OpenError, Repository};

/// The fields of the `for-each-ref` line of HEAD's branch, NUL-separated.
const BRANCH_FORMAT: &str =
    "--format=%(refname)%00%(objectname)%00%(upstream:short)%00%(upstream:track,nobracket)";

/// The status run's output kept: the branch headers come first and the one
/// path it is limited to has at most one entry.
const MAX_HEADER_BYTES: usize = 256 * 1024;

/// A checkout opened for reads of its refs, its config values and its own
/// paths. Its runs carry no blanked filter driver, so it has no run that can
/// read file content but the one of [`Checkout::head`], which blanks them
/// itself.
#[derive(Debug, Clone)]
pub struct Checkout {
    refs: Repository,
}

impl Checkout {
    /// The checkout `directory` is in.
    pub fn open(directory: &Path) -> Result<Self, OpenError> {
        Repository::open_unfiltered(directory, None).map(|refs| Self { refs })
    }

    /// The checkout's top level.
    pub fn root(&self) -> &Path {
        &self.refs.root
    }

    /// What HEAD is on, as the branch headers of `git status --porcelain=v2
    /// --branch` give it.
    pub fn head(&self) -> Result<BranchHeaders, GitFailure> {
        match self.branch_from_refs()? {
            Some(headers) => Ok(headers),
            None => self.headers_from_status(),
        }
    }

    /// The branch the branch scope compares with ([`Repository::base_branch`]).
    pub fn base_branch(&self) -> Option<(String, String)> {
        self.refs.base_branch()
    }

    /// The main checkout of a linked worktree ([`Repository::main_checkout`]).
    pub fn main_checkout(&self) -> Option<PathBuf> {
        self.refs.main_checkout()
    }

    /// The headers of a HEAD that is on a branch that has a commit; `None`
    /// in each other form, which the refs do not answer.
    fn branch_from_refs(&self) -> Result<Option<BranchHeaders>, GitFailure> {
        let arguments = ["symbolic-ref", "--quiet", "HEAD"];
        let head = match self.refs.run(&arguments, MAX_SMALL_OUTPUT_BYTES) {
            // A part of a name is another name.
            Ok(output) if output.truncated => return Ok(None),
            Ok(output) => output,
            // Detached (`--quiet` exits 1 with no message), or a HEAD that
            // git cannot read: the status run says which.
            Err(GitFailure::Exit(_)) => return Ok(None),
            Err(failure) => return Err(failure),
        };
        // The name goes back to git as an argument, so it must be the bytes
        // that git printed: a loose read (lossy, or one that cuts more than
        // the line feed) can name a second branch. A name that is not UTF-8
        // cannot be an argument here; the status run answers for it.
        let Ok(reference) = std::str::from_utf8(&head.stdout) else { return Ok(None) };
        let reference = reference.trim_end_matches('\n');
        let Some(branch) = reference.strip_prefix("refs/heads/") else { return Ok(None) };
        // The status headers shorten the upstream's name with the loose
        // rule; `for-each-ref` takes the strict one from this setting, and
        // then prints `heads/origin` for a local upstream named as a remote.
        let arguments = [
            "-c",
            "core.warnAmbiguousRefs=false",
            "for-each-ref",
            "--points-at=HEAD",
            BRANCH_FORMAT,
            reference,
        ];
        let output = match self.refs.run(&arguments, MAX_SMALL_OUTPUT_BYTES) {
            Ok(output) if output.truncated => return Ok(None),
            Ok(output) => output,
            Err(GitFailure::Exit(_)) => return Ok(None),
            Err(failure) => return Err(failure),
        };
        let text = String::from_utf8_lossy(&output.stdout);
        Ok(text.lines().find_map(|line| branch_line(line, reference, branch)))
    }

    /// The branch headers of the status run, limited to the path `.git`.
    fn headers_from_status(&self) -> Result<BranchHeaders, GitFailure> {
        let arguments = [
            "status",
            "--porcelain=v2",
            "--branch",
            "-z",
            "--untracked-files=no",
            "--ignore-submodules=all",
            // A literal path (every run sets `GIT_LITERAL_PATHSPECS`), from
            // the top level, where each run works.
            "--",
            ".git",
        ];
        let output = self.refs.filtered()?.run(&arguments, MAX_HEADER_BYTES)?;
        Ok(parse::branch_headers(&output.stdout))
    }
}

/// The headers in one `for-each-ref` line, when it is the line of
/// `reference`. The pattern also matches the branches below a name
/// (`refs/heads/a/b` for `refs/heads/a`), which are other branches.
fn branch_line(line: &str, reference: &str, branch: &str) -> Option<BranchHeaders> {
    let mut fields = line.split('\0');
    if fields.next()? != reference {
        return None;
    }
    let head = fields.next().filter(|head| !head.is_empty())?;
    let upstream = fields.next()?;
    let (ahead, behind) = tracking(fields.next()?);
    Some(BranchHeaders {
        head: Some(head.to_string()),
        branch: Some(branch.to_string()),
        upstream: (!upstream.is_empty()).then(|| upstream.to_string()),
        ahead,
        behind,
    })
}

/// The counts in `%(upstream:track,nobracket)`: `ahead 1`, `behind 2`,
/// `ahead 1, behind 2`, nothing when the two are equal or the branch has no
/// upstream, and `gone` when the upstream names no commit. The status
/// headers have no counts for the last, which reads as zero.
fn tracking(track: &str) -> (u64, u64) {
    let mut counts = (0, 0);
    for part in track.split(", ") {
        if let Some(ahead) = part.strip_prefix("ahead ") {
            counts.0 = ahead.parse().unwrap_or(0);
        } else if let Some(behind) = part.strip_prefix("behind ") {
            counts.1 = behind.parse().unwrap_or(0);
        }
    }
    counts
}

#[cfg(test)]
mod tests {
    use super::{BranchHeaders, branch_line, tracking};

    #[test]
    fn head_tracking_reads_each_form_that_git_prints() {
        assert_eq!(tracking(""), (0, 0));
        assert_eq!(tracking("gone"), (0, 0));
        assert_eq!(tracking("ahead 3"), (3, 0));
        assert_eq!(tracking("behind 12"), (0, 12));
        assert_eq!(tracking("ahead 3, behind 12"), (3, 12));
    }

    #[test]
    fn head_branch_line_takes_only_the_line_of_the_branch() {
        let line = "refs/heads/a\0abc\0origin/a\0ahead 1, behind 2";
        let headers = BranchHeaders {
            head: Some("abc".to_string()),
            branch: Some("a".to_string()),
            upstream: Some("origin/a".to_string()),
            ahead: 1,
            behind: 2,
        };
        assert_eq!(branch_line(line, "refs/heads/a", "a"), Some(headers));
        // A branch below the name is another branch.
        assert_eq!(branch_line("refs/heads/a/b\0abc\0\0", "refs/heads/a", "a"), None);
        // No upstream.
        let alone = branch_line("refs/heads/a\0abc\0\0", "refs/heads/a", "a").unwrap();
        assert_eq!((alone.upstream, alone.ahead, alone.behind), (None, 0, 0));
        // A line that a cut output left short.
        assert_eq!(branch_line("refs/heads/a\0abc", "refs/heads/a", "a"), None);
    }
}
