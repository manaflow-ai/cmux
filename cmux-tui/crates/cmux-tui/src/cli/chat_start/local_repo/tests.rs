use std::path::Path;
use std::process::Command;

use super::{Ready, default_dir, ensure, is_commit, parse, same_remote};

fn git(dir: &Path, args: &[&str]) {
    let status = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main"])
        .args(args)
        .status()
        .expect("git");
    assert!(status.success(), "git {args:?}");
}

/// A repository with one commit on `main` and a `topic` branch, as a `file://` URL.
fn origin(root: &Path) -> String {
    let source = root.join("source");
    std::fs::create_dir_all(&source).unwrap();
    git(&source, &["init", "-q"]);
    std::fs::write(source.join("AGENTS.md"), "codeword\n").unwrap();
    git(&source, &["add", "."]);
    git(&source, &["commit", "-qm", "one"]);
    git(&source, &["branch", "topic"]);
    format!("file://{}", source.display())
}

#[test]
fn a_repo_is_cloned_once_and_then_reused() {
    let root = tempfile::tempdir().unwrap();
    let url = origin(root.path());
    let dir = root.path().join("cmux/repos/host/owner/name");
    assert_eq!(ensure(&url, None, &dir), Ok(Ready::Cloned));
    assert!(dir.join("AGENTS.md").is_file());
    // The person's work in the clone stays: the second chat reuses it without a fetch or checkout.
    std::fs::write(dir.join("notes.txt"), "mine").unwrap();
    assert_eq!(ensure(&url, Some("topic"), &dir), Ok(Ready::Reused));
    assert!(dir.join("notes.txt").is_file());
}

#[test]
fn a_ref_is_checked_out_and_a_missing_one_leaves_nothing_to_reuse() {
    let root = tempfile::tempdir().unwrap();
    let url = origin(root.path());
    let dir = root.path().join("topic");
    assert_eq!(ensure(&url, Some("topic"), &dir), Ok(Ready::Cloned));
    let head = Command::new("git").arg("-C").arg(&dir).args(["branch", "--show-current"]).output();
    assert_eq!(String::from_utf8_lossy(&head.unwrap().stdout).trim(), "topic");
    // A missing ref: no clone is left on the default branch for a retry to reuse.
    let missing = root.path().join("missing");
    let error = ensure(&url, Some("no-such-ref"), &missing).unwrap_err();
    assert_eq!(error["code"], "repo.clone_failed");
    assert!(error["message"].as_str().unwrap().contains("no-such-ref"));
    assert!(!missing.exists());
    // A folder that was there stays, empty, with its own permissions.
    let empty = root.path().join("empty");
    std::fs::create_dir(&empty).unwrap();
    std::fs::set_permissions(&empty, std::os::unix::fs::PermissionsExt::from_mode(0o700)).unwrap();
    assert!(ensure(&url, Some("no-such-ref"), &empty).is_err());
    assert_eq!(std::fs::read_dir(&empty).unwrap().count(), 0);
    let mode =
        std::os::unix::fs::PermissionsExt::mode(&std::fs::metadata(&empty).unwrap().permissions());
    assert_eq!(mode & 0o777, 0o700);
    // A tag works as a branch does.
    git(&root.path().join("source"), &["tag", "v1"]);
    assert_eq!(ensure(&url, Some("v1"), &root.path().join("tag")), Ok(Ready::Cloned));
}

#[test]
fn a_folder_holding_something_else_is_never_written_into() {
    let root = tempfile::tempdir().unwrap();
    let url = origin(root.path());
    let dir = root.path().join("taken");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("keep.txt"), "keep").unwrap();
    let error = ensure(&url, None, &dir).unwrap_err();
    assert_eq!(error["code"], "repo.dir_taken");
    assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 1);
    // An empty folder is the clone's.
    let empty = root.path().join("empty");
    std::fs::create_dir_all(&empty).unwrap();
    assert_eq!(ensure(&url, None, &empty), Ok(Ready::Cloned));
}

#[test]
fn a_clone_that_fails_says_what_git_said() {
    let root = tempfile::tempdir().unwrap();
    let missing = format!("file://{}", root.path().join("nothing").display());
    let error = ensure(&missing, None, &root.path().join("dir")).unwrap_err();
    assert_eq!(error["code"], "repo.clone_failed");
    assert!(error["message"].as_str().unwrap().contains("git clone"));
}

#[test]
fn github_and_other_hosts_get_their_own_folders() {
    let home = Path::new("/home/me");
    let github = parse("octocat/Hello-World").unwrap();
    assert_eq!(github.url(), "https://github.com/octocat/Hello-World.git");
    assert_eq!(default_dir(home, &github), home.join("cmux/repos/github.com/octocat/Hello-World"));
    let gitlab = parse("https://gitlab.com/gitlab-org/sub/gitlab-test").unwrap();
    assert_eq!(
        default_dir(home, &gitlab),
        home.join("cmux/repos/gitlab.com/gitlab-org/sub/gitlab-test")
    );
    assert_eq!(parse("https://github.com/o/n@v1").unwrap().r#ref.as_deref(), Some("v1"));
    assert!(parse("https://me:token@gitlab.com/g/n").unwrap_err().contains("login or token"));
    assert!(parse("not a repo").unwrap_err().contains("OWNER/NAME"));
}

#[test]
fn one_repository_under_several_spellings_is_the_same_remote() {
    assert!(same_remote("https://github.com/o/n.git", "https://github.com/o/n"));
    assert!(same_remote("git@github.com:o/n.git", "https://github.com/o/n.git"));
    assert!(same_remote("https://GitLab.com/g/n/", "https://gitlab.com/g/n.git"));
    assert!(!same_remote("https://github.com/o/n.git", "https://github.com/o/other.git"));
    assert!(same_remote("file:///tmp/x/", "file:///tmp/x.git"));
}

#[test]
fn a_folder_inside_another_repository_is_not_read_as_its_clone() {
    let root = tempfile::tempdir().unwrap();
    let url = origin(root.path());
    // A folder with files, inside the source repository: git would answer for the source.
    let inside = root.path().join("source").join("sub");
    std::fs::create_dir_all(&inside).unwrap();
    std::fs::write(inside.join("file"), "x").unwrap();
    assert_eq!(ensure(&url, None, &inside).unwrap_err()["code"], "repo.dir_taken");
}

#[test]
fn a_commit_is_checked_out_and_a_clone_mid_checkout_is_never_reused() {
    let root = tempfile::tempdir().unwrap();
    let url = origin(root.path());
    let source = root.path().join("source");
    let first = Command::new("git").arg("-C").arg(&source).args(["rev-parse", "HEAD"]).output();
    let first = String::from_utf8_lossy(&first.unwrap().stdout).trim().to_owned();
    std::fs::write(source.join("later.txt"), "later").unwrap();
    git(&source, &["add", "."]);
    git(&source, &["commit", "-qm", "later"]);
    assert!(is_commit(&first) && is_commit(&first[..7]) && !is_commit("topic"));
    let dir = root.path().join("at-commit");
    assert_eq!(ensure(&url, Some(&first[..12]), &dir), Ok(Ready::Cloned));
    assert!(dir.join("AGENTS.md").is_file() && !dir.join("later.txt").exists());
    // A missing commit: nothing is left for a retry to reuse.
    let missing = root.path().join("missing-commit");
    let error = ensure(&url, Some("0123456789abcdef"), &missing).unwrap_err();
    assert_eq!(error["code"], "repo.checkout_failed");
    assert!(!missing.exists());
    // A clone with no checkout yet (another start mid-way) is refused, never reused.
    let partial = root.path().join("partial");
    git(root.path(), &["clone", "-q", "--no-checkout", &url, partial.to_str().unwrap()]);
    let error = ensure(&url, None, &partial).unwrap_err();
    assert_eq!(
        (error["code"].as_str(), error["retryable"].as_bool()),
        (Some("repo.cloning"), Some(true))
    );
}
