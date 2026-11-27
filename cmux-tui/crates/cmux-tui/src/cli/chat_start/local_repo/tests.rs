use std::path::Path;
use std::process::Command;

use super::{Ready, default_dir, ensure, parse, same_remote};

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
    assert_eq!(ensure(&url, None, &dir), Ok(Ready::Reused));
    assert!(dir.join("notes.txt").is_file());
}

#[test]
fn a_ref_is_checked_out_and_a_clone_at_another_is_never_reused_for_it() {
    let root = tempfile::tempdir().unwrap();
    let url = origin(root.path());
    let source = root.path().join("source");
    git(&source, &["tag", "v1"]);
    let dir = root.path().join("topic");
    assert_eq!(ensure(&url, Some("topic"), &dir), Ok(Ready::Cloned));
    let head = Command::new("git").arg("-C").arg(&dir).args(["branch", "--show-current"]).output();
    assert_eq!(String::from_utf8_lossy(&head.unwrap().stdout).trim(), "topic");
    assert_eq!(ensure(&url, Some("topic"), &dir), Ok(Ready::Reused));
    // Tags, full tag refs and commit ids, as git checkout takes them.
    assert_eq!(ensure(&url, Some("refs/tags/v1"), &root.path().join("tag")), Ok(Ready::Cloned));
    let first = Command::new("git").arg("-C").arg(&source).args(["rev-parse", "HEAD"]).output();
    let first = String::from_utf8_lossy(&first.unwrap().stdout).trim().to_owned();
    std::fs::write(source.join("later.txt"), "later").unwrap();
    git(&source, &["add", "."]);
    git(&source, &["commit", "-qm", "later"]);
    let at = root.path().join("at-commit");
    assert_eq!(ensure(&url, Some(&first[..6]), &at), Ok(Ready::Cloned));
    assert!(!at.join("later.txt").exists());
    // A missing ref: the clone stays on its default branch, and a retry at that ref is refused
    // instead of starting there.
    let missing = root.path().join("missing");
    let error = ensure(&url, Some("no-such-ref"), &missing).unwrap_err();
    assert_eq!(error["code"], "repo.checkout_failed");
    assert!(missing.join(".git").exists());
    assert_eq!(
        ensure(&url, Some("no-such-ref"), &missing).unwrap_err()["code"],
        "repo.ref_mismatch"
    );
    assert_eq!(ensure(&url, Some("topic"), &missing).unwrap_err()["code"], "repo.ref_mismatch");
}

#[test]
fn an_empty_folder_keeps_its_permissions_and_a_symlink_to_it_works() {
    let root = tempfile::tempdir().unwrap();
    let url = origin(root.path());
    let empty = root.path().join("empty");
    std::fs::create_dir(&empty).unwrap();
    std::fs::set_permissions(&empty, std::os::unix::fs::PermissionsExt::from_mode(0o700)).unwrap();
    let alias = root.path().join("alias");
    std::os::unix::fs::symlink(&empty, &alias).unwrap();
    assert_eq!(ensure(&url, None, &alias), Ok(Ready::Cloned));
    assert!(empty.join("AGENTS.md").is_file());
    let mode =
        std::os::unix::fs::PermissionsExt::mode(&std::fs::metadata(&empty).unwrap().permissions());
    assert_eq!(mode & 0o777, 0o700);
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
fn a_linked_worktree_and_an_empty_repository_are_reused() {
    let root = tempfile::tempdir().unwrap();
    let url = origin(root.path());
    let dir = root.path().join("dir");
    assert_eq!(ensure(&url, None, &dir), Ok(Ready::Cloned));
    // A linked worktree: `.git` is a file and the index lives elsewhere.
    let tree = root.path().join("tree");
    git(&dir, &["worktree", "add", "-q", tree.to_str().unwrap(), "topic"]);
    assert_eq!(ensure(&url, None, &tree), Ok(Ready::Reused));
    // A clone of a repository with no commits has no index.
    let bare = root.path().join("empty.git");
    git(root.path(), &["init", "-q", "--bare", bare.to_str().unwrap()]);
    let empty_url = format!("file://{}", bare.display());
    let empty = root.path().join("empty");
    assert_eq!(ensure(&empty_url, None, &empty), Ok(Ready::Cloned));
    assert_eq!(ensure(&empty_url, None, &empty), Ok(Ready::Reused));
}

#[test]
fn a_ref_is_read_the_way_git_checkout_reads_it() {
    let root = tempfile::tempdir().unwrap();
    let url = origin(root.path());
    let dir = root.path().join("dir");
    assert_eq!(ensure(&url, None, &dir), Ok(Ready::Cloned));
    // HEAD is main at the same commit as origin/topic: the chat's commits would go to main, not
    // topic, so it is refused. A clone on topic is reused.
    assert_eq!(ensure(&url, Some("topic"), &dir).unwrap_err()["code"], "repo.ref_mismatch");
    git(&dir, &["checkout", "-q", "topic"]);
    assert_eq!(ensure(&url, Some("topic"), &dir), Ok(Ready::Reused));
    // A tag or commit names no branch: the commit alone decides.
    git(&root.path().join("source"), &["tag", "t1"]);
    git(&dir, &["fetch", "-q", "--tags"]);
    assert_eq!(ensure(&url, Some("t1"), &dir), Ok(Ready::Reused));
    // A local branch wins over a tag of the same name, as checkout picks it.
    let pick = |names: &[(&str, &str)], reference: &str| {
        super::checkout_target(reference, |name| {
            names.iter().find(|(n, _)| *n == name).map(|(_, c)| (*c).to_owned())
        })
        .map(|target| (target.commit, target.branch))
    };
    let both = [("refs/heads/v1^{commit}", "branch"), ("v1^{commit}", "tag")];
    assert_eq!(pick(&both, "v1"), Some(("branch".to_owned(), true)));
    let remote = [("refs/remotes/origin/topic^{commit}", "remote")];
    assert_eq!(pick(&remote, "topic"), Some(("remote".to_owned(), true)));
    // A tag shadowing origin's branch: checkout takes the tag, detached.
    let shadow = [("t^{commit}", "tag"), ("refs/remotes/origin/t^{commit}", "remote")];
    assert_eq!(pick(&shadow, "t"), Some(("tag".to_owned(), false)));
}

#[test]
fn a_branch_and_a_tag_of_one_name_reuse_what_checkout_picked() {
    let root = tempfile::tempdir().unwrap();
    let url = origin(root.path());
    let source = root.path().join("source");
    // `same` is both a branch and a tag in the origin.
    git(&source, &["branch", "same"]);
    git(&source, &["tag", "same"]);
    let dir = root.path().join("dir");
    assert_eq!(ensure(&url, Some("same"), &dir), Ok(Ready::Cloned));
    // Whatever checkout picked (git shortens HEAD to `heads/same` here), a retry reuses it.
    assert_eq!(ensure(&url, Some("same"), &dir), Ok(Ready::Reused));
    // A tag of the name only, beside origin's branch of it: checkout detaches at the tag.
    git(&source, &["tag", "shadow"]);
    git(&source, &["branch", "-q", "shadow"]);
    let other = root.path().join("other");
    git(root.path(), &["clone", "-q", &url, other.to_str().unwrap()]);
    git(&other, &["checkout", "-q", "shadow"]);
    assert_eq!(ensure(&url, Some("shadow"), &other), Ok(Ready::Reused));
}
