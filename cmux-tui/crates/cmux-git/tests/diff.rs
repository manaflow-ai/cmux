//! `Repository::open` and `diff::comparison` against real repositories.

mod support;

use cmux_git::diff::{self, ScopeError};
use cmux_git::{OpenError, Repository};
use support::{Folder, clone_of_origin, commit, git, init};

#[test]
fn open_finds_the_top_level_and_refuses_a_plain_folder() {
    let folder = Folder::new("open");
    init(folder.path());
    let nested = folder.path().join("a/b");
    std::fs::create_dir_all(&nested).unwrap();
    let repository = Repository::open(&nested).unwrap();
    assert_eq!(repository.root, folder.path());

    let plain = Folder::new("plain");
    assert!(matches!(Repository::open(plain.path()), Err(OpenError::NotARepository)));
}

#[test]
fn open_blanks_every_filter_driver() {
    let folder = Folder::new("filters");
    init(folder.path());
    git(folder.path(), &["config", "filter.lfs.clean", "git-lfs clean -- %f"]);
    git(folder.path(), &["config", "filter.lfs.required", "true"]);
    let repository = Repository::open(folder.path()).unwrap();
    assert_eq!(
        repository.overrides,
        [
            "filter.lfs.clean=",
            "filter.lfs.smudge=",
            "filter.lfs.process=",
            "filter.lfs.required=false"
        ]
    );
}

#[test]
fn branch_scope_compares_with_the_merge_base_of_the_default_branch() {
    let folder = Folder::new("branch-scope");
    let work = clone_of_origin(folder.path());
    let root = git(&work, &["rev-parse", "HEAD"]);
    git(&work, &["checkout", "-q", "-b", "feat"]);
    let tip = commit(&work, "feature", 2_000);
    let repository = Repository::open(&work).unwrap();

    let comparison = diff::comparison(&repository, "branch").unwrap();
    assert_eq!(comparison.revisions, Some(vec![root.clone()]));
    assert_eq!(comparison.base.as_deref(), Some(root.as_str()));
    assert_eq!(comparison.head.as_deref(), Some(tip.as_str()));
    assert!(comparison.untracked);
    assert!(!comparison.cached);

    let paths = vec!["src".to_string()];
    assert_eq!(
        diff::diff_args(&comparison, &["--numstat", "-z"], &paths),
        [
            "diff",
            "--no-color",
            "--no-ext-diff",
            "--no-textconv",
            "--no-relative",
            "--ignore-submodules=dirty",
            "-M",
            "--src-prefix=a/",
            "--dst-prefix=b/",
            "--numstat",
            "-z",
            root.as_str(),
            "--",
            "src"
        ]
    );
}

#[test]
fn scopes_without_a_base_or_a_name_are_errors() {
    let folder = Folder::new("scope-errors");
    init(folder.path());
    git(folder.path(), &["checkout", "-q", "-b", "trunk"]);
    let first = commit(folder.path(), "root", 1_000);
    let repository = Repository::open(folder.path()).unwrap();

    assert!(matches!(diff::comparison(&repository, "branch"), Err(ScopeError::NoBaseBranch)));
    match diff::comparison(&repository, "everything") {
        Err(error @ ScopeError::UnknownScope(_)) => {
            assert_eq!(error.to_string(), "unknown scope \"everything\"");
        }
        other => panic!("expected an unknown scope, got {other:?}"),
    }

    // `committed` before a parent compares with the empty tree.
    let committed = diff::comparison(&repository, "committed").unwrap();
    let empty_tree = repository.empty_tree().unwrap();
    assert_eq!(committed.revisions, Some(vec![empty_tree, first]));
    assert_eq!(committed.base, None);
}

#[test]
fn unrelated_histories_have_no_merge_base() {
    let folder = Folder::new("no-merge-base");
    init(folder.path());
    commit(folder.path(), "main root", 1_000);
    git(folder.path(), &["checkout", "-q", "--orphan", "island"]);
    commit(folder.path(), "island root", 2_000);
    let repository = Repository::open(folder.path()).unwrap();
    match diff::merge_base(&repository) {
        Err(ScopeError::NoMergeBase { base }) => assert_eq!(base, "main"),
        other => panic!("expected no merge base, got {other:?}"),
    }
}
