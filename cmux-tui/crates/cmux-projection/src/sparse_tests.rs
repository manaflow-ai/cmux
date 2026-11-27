use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use super::*;
use crate::git::{
    Book, Layout, ObjectFormat, Projection, Worktree, index_bytes_sparse, link_texts, ls_tree,
};

fn git(dir: &Path, args: &[&str], stdin: Option<&str>) -> String {
    let mut child = Command::new("git")
        .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"])
        .args(args)
        .current_dir(dir)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    std::io::Write::write_all(&mut input, stdin.unwrap_or("").as_bytes()).unwrap();
    drop(input);
    let out = child.wait_with_output().unwrap();
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8(out.stdout).unwrap()
}

const PATHS: [&str; 14] = [
    "x",
    "README.md",
    "notes.md",
    "a/y",
    "a/README.md",
    "a/b/z",
    "a/b/keep",
    "a/b/c/deep",
    "c/z",
    "docs/w.md",
    "docs/sub/v.md",
    "d/docs/u",
    "crate/Cargo.lock",
    "crate/src/main.rs",
];

/// A repo holding [`PATHS`], with the worktree config the lane mirrors have.
fn repo() -> (tempfile::TempDir, PathBuf) {
    let dir = tempfile::tempdir().unwrap();
    let work = dir.path().join("work");
    for path in PATHS {
        let file = work.join(path);
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(&file, format!("{path}\n")).unwrap();
    }
    git(&work, &["init", "-q"], None);
    git(&work, &["config", "extensions.worktreeConfig", "true"], None);
    git(&work, &["add", "-A"], None);
    git(&work, &["commit", "-q", "-m", "one"], None);
    (dir, work)
}

/// The paths `git ls-files -t` marks skip-worktree (`S`) in `dir`.
fn skipped_by_git(dir: &Path) -> BTreeSet<String> {
    git(dir, &["ls-files", "-t"], None)
        .lines()
        .filter_map(|line| line.strip_prefix("S "))
        .map(str::to_owned)
        .collect()
}

/// Pattern sets: wt's own shape, negations inside an included folder, unanchored names, `**`,
/// comments and blank lines, a lone `!`, and folder-only patterns.
const CASES: [&str; 10] = [
    "/*\n!/*/\n/a/\n/crate/\n",
    "/*\n!/*/\n/a/\n!/a/b/\n/a/b/keep\n/crate/\n",
    "*.md\n!docs/*.md\n",
    "docs\n",
    "docs/\n",
    "**/z\n",
    "# a comment\n\n/a/b/\n/x\n",
    "a/*\n!a/b\n",
    "/*\n!/*/\n/a/**/deep\n/crate/src/\n",
    "/*\n!*.md\n/docs/sub/\n!/x\n",
];

#[test]
fn the_patterns_leave_out_what_git_sparse_checkout_leaves_out() {
    let (_dir, work) = repo();
    for patterns in CASES {
        git(&work, &["sparse-checkout", "set", "--no-cone", "--stdin"], Some(patterns));
        let by_git = skipped_by_git(&work);
        let sparse = Sparse::parse(patterns).unwrap();
        let ours: BTreeSet<String> = PATHS
            .iter()
            .filter(|path| !sparse.includes(path))
            .map(|path| (*path).to_owned())
            .collect();
        assert_eq!(ours, by_git, "patterns {patterns:?}");
    }
}

#[test]
fn no_pattern_keeps_nothing_and_a_missing_newline_is_added() {
    let sparse = Sparse::parse("/a/").unwrap();
    assert!(sparse.includes("a/y"));
    assert!(!sparse.includes("x"));
    assert_eq!(sparse.text(), "/a/\n");
    assert!(!Sparse::parse("").unwrap().includes("x"));
}

/// The projection's index under `patterns`, written into a worktree at `at` whose files on disk
/// are the projected ones, as the mount serves them.
#[test]
fn the_index_has_skip_worktree_on_exactly_the_left_out_paths_and_status_is_clean() {
    let (dir, work) = repo();
    let git_dir = work.join(".git");
    let commit = git(&work, &["rev-parse", "HEAD"], None).trim().to_owned();
    let patterns = CASES[1];
    git(&work, &["sparse-checkout", "set", "--no-cone", "--stdin"], Some(patterns));
    let by_git = skipped_by_git(&work);
    let git_list = git(&work, &["sparse-checkout", "list"], None);
    assert!(!by_git.is_empty());

    let sparse = Sparse::parse(patterns).unwrap();
    let items = ls_tree(&git_dir, &commit).unwrap();
    let (items, skipped) = Sparse::partition(Some(&sparse), items);
    let links = link_texts(&git_dir, &items).unwrap();
    let admin = git_dir.join("worktrees").join("projected");
    let real_root = dir.path().join("real");
    let layout = Layout {
        commit_ns: 1_000_000_000,
        now_ns: 5_000_000_000,
        gitfile: Some(Worktree::gitfile(&admin)),
        real_root: Some(&real_root),
        links: &links,
    };
    let projection = Projection::build(&commit, &items, &mut Book::default(), &layout).unwrap();
    for left_out in &by_git {
        assert!(projection.manifest.resolve(left_out).is_none(), "{left_out} is projected");
    }
    assert!(projection.manifest.resolve("a/b/keep").is_some());
    assert!(projection.manifest.resolve("a/b/z").is_none());
    assert!(projection.real_dirs.contains(&"crate/target".to_owned()));
    assert_eq!(projection.index.len() + skipped.len(), PATHS.len());
    assert_eq!(skipped.iter().map(|item| item.path.clone()).collect::<BTreeSet<_>>(), by_git);

    // On disk: the kept files and the `.git` file, the way the mount shows them.
    let at = dir.path().join("mnt");
    std::fs::create_dir_all(&at).unwrap();
    for path in PATHS.iter().filter(|path| !by_git.contains(**path)) {
        let file = at.join(path);
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(&file, format!("{path}\n")).unwrap();
    }
    std::fs::write(at.join(".git"), Worktree::gitfile(&admin)).unwrap();
    for real in &projection.real_dirs {
        std::os::unix::fs::symlink(real_root.join(real), at.join(real)).unwrap();
    }
    assert!(!Worktree::sparse_matches(&admin, Some(&sparse)));
    let index =
        index_bytes_sparse(&projection.index, &skipped, ObjectFormat::Sha1, 1000, 1000).unwrap();
    assert_eq!(index.get(4..8), Some(&3u32.to_be_bytes()[..]), "extended flags need version 3");
    Worktree::write(&git_dir, "projected", &at, &commit, &index, &projection.real_dirs)
        .unwrap()
        .set_sparse(&git_dir, Some(&sparse))
        .unwrap();
    assert!(Worktree::sparse_matches(&admin, Some(&sparse)));
    assert_eq!(skipped_by_git(&at), by_git, "git reads skip-worktree on exactly those paths");
    assert_eq!(git(&at, &["status", "--porcelain"], None), "");
    assert_eq!(git(&at, &["sparse-checkout", "list"], None), git_list);
    assert_eq!(git(&at, &["config", "core.sparseCheckout"], None), "true\n");
    assert_eq!(git(&at, &["config", "core.sparseCheckoutCone"], None), "false\n");

    // Without --sparse again: the patterns and the config go.
    Worktree::write(&git_dir, "projected", &at, &commit, &index, &projection.real_dirs)
        .unwrap()
        .set_sparse(&git_dir, None)
        .unwrap();
    assert!(Worktree::sparse_matches(&admin, None));
    assert!(!admin.join("info/sparse-checkout").exists());
    let config = std::fs::read_to_string(admin.join("config.worktree")).unwrap();
    assert!(!config.to_lowercase().contains("sparse"), "{config}");
}

#[test]
fn an_index_with_nothing_left_out_stays_version_2() {
    let (_dir, work) = repo();
    let git_dir = work.join(".git");
    let commit = git(&work, &["rev-parse", "HEAD"], None).trim().to_owned();
    let items = ls_tree(&git_dir, &commit).unwrap();
    let sparse = Sparse::parse("/*\n").unwrap();
    let (items, skipped) = Sparse::partition(Some(&sparse), items);
    let links = link_texts(&git_dir, &items).unwrap();
    let layout = Layout {
        commit_ns: 1_000_000_000,
        now_ns: 5_000_000_000,
        gitfile: None,
        real_root: Some(Path::new("/real")),
        links: &links,
    };
    let projection = Projection::build(&commit, &items, &mut Book::default(), &layout).unwrap();
    assert!(skipped.is_empty());
    let index =
        index_bytes_sparse(&projection.index, &skipped, ObjectFormat::Sha1, 1000, 1000).unwrap();
    assert_eq!(index.get(4..8), Some(&2u32.to_be_bytes()[..]));
}
