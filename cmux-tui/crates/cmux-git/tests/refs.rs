//! `refs::branches` and `refs::suggested_base` against real repositories.

mod support;

use cmux_git::Repository;
use cmux_git::refs::{self, BaseReason, BranchKind};
use support::{Folder, clone_of_origin, commit, git, init};

/// A clone on `feat` (one commit ahead of origin/main), with `main`
/// tracking origin/main, `old` without an upstream and `gone-up` whose
/// upstream no longer exists.
fn feature_clone(folder: &Folder) -> std::path::PathBuf {
    let work = clone_of_origin(folder.path());
    git(&work, &["branch", "old"]);
    git(&work, &["checkout", "-q", "-b", "feat", "--track", "origin/main"]);
    commit(&work, "feature", 3_000);
    git(&work, &["branch", "gone-up"]);
    git(&work, &["config", "branch.gone-up.remote", "origin"]);
    git(&work, &["config", "branch.gone-up.merge", "refs/heads/nope"]);
    work
}

fn names(listing: &refs::Branches) -> Vec<&str> {
    listing.branches.iter().map(|branch| branch.name.as_str()).collect()
}

#[test]
fn branches_lists_local_then_remote_newest_first() {
    let folder = Folder::new("branches");
    let work = feature_clone(&folder);
    let repository = Repository::open(&work).unwrap();
    let listing = refs::branches(&repository, 50).unwrap();

    assert_eq!(listing.current.as_deref(), Some("feat"));
    assert!(!listing.truncated);
    // origin/HEAD is an alias of origin/main and is not listed.
    assert_eq!(names(&listing), ["feat", "gone-up", "main", "old", "origin/main"]);

    let feat = &listing.branches[0];
    assert_eq!(feat.reference, "refs/heads/feat");
    assert_eq!(feat.kind, BranchKind::Local);
    assert!(feat.current);
    assert_eq!(feat.commit, git(&work, &["rev-parse", "feat"]));
    assert_eq!(feat.upstream.as_deref(), Some("origin/main"));
    assert_eq!((feat.ahead, feat.behind), (Some(1), Some(0)));
    assert_eq!(feat.committed_at, Some(3_000));

    let gone = &listing.branches[1];
    assert!(!gone.current);
    assert_eq!(gone.upstream.as_deref(), Some("origin/nope"));
    assert!(gone.upstream_gone);
    assert_eq!((gone.ahead, gone.behind), (None, None));

    let main = &listing.branches[2];
    assert_eq!(main.upstream.as_deref(), Some("origin/main"));
    assert_eq!((main.ahead, main.behind), (Some(0), Some(0)));

    let old = &listing.branches[3];
    assert_eq!(old.upstream, None);
    assert!(!old.upstream_gone);
    assert_eq!((old.ahead, old.behind), (None, None));

    let remote = &listing.branches[4];
    assert_eq!(remote.reference, "refs/remotes/origin/main");
    assert_eq!(remote.kind, BranchKind::Remote);
    assert_eq!(remote.upstream, None);
    assert_eq!(remote.committed_at, Some(1_000));
}

#[test]
fn branches_stops_at_the_limit_and_says_so() {
    let folder = Folder::new("limit");
    let work = feature_clone(&folder);
    let repository = Repository::open(&work).unwrap();

    let two = refs::branches(&repository, 2).unwrap();
    assert_eq!(names(&two), ["feat", "gone-up"]);
    assert!(two.truncated);

    // Every local branch fits; the remote one does not.
    let four = refs::branches(&repository, 4).unwrap();
    assert_eq!(names(&four), ["feat", "gone-up", "main", "old"]);
    assert!(four.truncated);

    let five = refs::branches(&repository, 5).unwrap();
    assert_eq!(five.branches.len(), 5);
    assert!(!five.truncated);

    let none = refs::branches(&repository, 0).unwrap();
    assert!(none.branches.is_empty());
    assert!(none.truncated);
}

#[test]
fn branches_on_a_detached_head_has_no_current_branch() {
    let folder = Folder::new("detached");
    let work = feature_clone(&folder);
    git(&work, &["checkout", "-q", "--detach"]);
    let repository = Repository::open(&work).unwrap();
    let listing = refs::branches(&repository, 50).unwrap();
    assert_eq!(listing.current, None);
    assert!(listing.branches.iter().all(|branch| !branch.current));
}

#[test]
fn branches_before_the_first_commit_names_the_unborn_branch() {
    let folder = Folder::new("unborn");
    init(folder.path());
    let repository = Repository::open(folder.path()).unwrap();
    let listing = refs::branches(&repository, 50).unwrap();
    assert_eq!(listing.current.as_deref(), Some("main"));
    assert!(listing.branches.is_empty());
    assert!(!listing.truncated);
    assert!(refs::suggested_base(&repository).is_empty());
}

#[test]
fn suggested_base_is_the_default_branch_then_a_different_upstream() {
    let folder = Folder::new("suggested");
    let work = feature_clone(&folder);
    let repository = Repository::open(&work).unwrap();

    // feat tracks origin/main, which is also the default branch.
    let same = refs::suggested_base(&repository);
    assert_eq!(same.len(), 1);
    assert_eq!(same[0].name, "origin/main");
    assert_eq!(same[0].reference, "refs/remotes/origin/main");
    assert_eq!(same[0].reason, BaseReason::DefaultBranch);
    assert_eq!(
        Some((same[0].reference.clone(), same[0].name.clone())),
        repository.base_branch(),
        "the suggestion is the base git.diff's branch scope uses"
    );

    git(&folder.path().join("origin"), &["branch", "release"]);
    git(&work, &["fetch", "-q", "origin"]);
    git(&work, &["branch", "--set-upstream-to=origin/release", "feat"]);
    let both = refs::suggested_base(&repository);
    let rows: Vec<_> = both.iter().map(|base| (base.name.as_str(), base.reason)).collect();
    assert_eq!(
        rows,
        [("origin/main", BaseReason::DefaultBranch), ("origin/release", BaseReason::Upstream)]
    );

    // A gone upstream is not offered.
    git(&work, &["checkout", "-q", "gone-up"]);
    let gone = refs::suggested_base(&repository);
    assert_eq!(gone.len(), 1);
    assert_eq!(gone[0].reason, BaseReason::DefaultBranch);
}

#[test]
fn suggested_base_offers_a_local_upstream_without_a_default_branch() {
    let folder = Folder::new("local-upstream");
    init(folder.path());
    let work = folder.path();
    git(work, &["checkout", "-q", "-b", "trunk"]);
    commit(work, "root", 1_000);
    git(work, &["checkout", "-q", "-b", "topic", "--track", "trunk"]);
    let repository = Repository::open(work).unwrap();
    let candidates = refs::suggested_base(&repository);
    assert_eq!(candidates.len(), 1);
    assert_eq!(candidates[0].name, "trunk");
    assert_eq!(candidates[0].reference, "refs/heads/trunk");
    assert_eq!(candidates[0].reason, BaseReason::Upstream);
}
