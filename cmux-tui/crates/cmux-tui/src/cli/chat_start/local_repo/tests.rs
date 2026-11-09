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
    assert_eq!(ensure(&url, Some("topic"), &dir), Ok(Ready::Reused));
    assert!(dir.join("notes.txt").is_file());
}

#[test]
fn a_ref_is_checked_out_and_a_missing_one_says_so() {
    let root = tempfile::tempdir().unwrap();
    let url = origin(root.path());
    let dir = root.path().join("topic");
    assert_eq!(ensure(&url, Some("topic"), &dir), Ok(Ready::Cloned));
    let head = Command::new("git").arg("-C").arg(&dir).args(["branch", "--show-current"]).output();
    assert_eq!(String::from_utf8_lossy(&head.unwrap().stdout).trim(), "topic");
    let missing = root.path().join("missing");
    let error = ensure(&url, Some("no-such-ref"), &missing).unwrap_err();
    assert_eq!(error["code"], "repo.checkout_failed");
    // No clone is left on the default branch for a retry to reuse.
    assert!(!missing.exists());
    let empty = root.path().join("empty");
    std::fs::create_dir(&empty).unwrap();
    std::fs::set_permissions(&empty, std::os::unix::fs::PermissionsExt::from_mode(0o700)).unwrap();
    assert!(ensure(&url, Some("no-such-ref"), &empty).is_err());
    assert_eq!(std::fs::read_dir(&empty).unwrap().count(), 0);
    // The folder that was there stays, with its own permissions.
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
fn a_folder_another_start_is_cloning_is_left_to_it() {
    let root = tempfile::tempdir().unwrap();
    let url = origin(root.path());
    let dir = root.path().join("dir");
    std::fs::create_dir_all(dir.join(super::CLAIM)).unwrap();
    std::fs::write(dir.join("half"), "x").unwrap();
    let error = ensure(&url, None, &dir).unwrap_err();
    assert_eq!(
        (error["code"].as_str(), error["retryable"].as_bool()),
        (Some("repo.cloning"), Some(true))
    );
    // Through a symlink to the folder too: the claim is inside it.
    let alias = root.path().join("alias");
    std::os::unix::fs::symlink(&dir, &alias).unwrap();
    assert_eq!(ensure(&url, None, &alias).unwrap_err()["code"], "repo.cloning");
    assert!(dir.join("half").is_file());
}

#[test]
fn reusing_a_clone_writes_nothing_beside_it() {
    let root = tempfile::tempdir().unwrap();
    let url = origin(root.path());
    let parent = root.path().join("parent");
    let dir = parent.join("dir");
    assert_eq!(ensure(&url, None, &dir), Ok(Ready::Cloned));
    let names = |path: &Path| {
        let mut names: Vec<_> =
            std::fs::read_dir(path).unwrap().flatten().map(|entry| entry.file_name()).collect();
        names.sort();
        names
    };
    // No claim is left, and nothing was made beside the clone.
    assert!(!dir.join(super::CLAIM).exists());
    assert_eq!(names(&parent), vec![std::ffi::OsString::from("dir")]);
    let before = names(&dir);
    assert_eq!(ensure(&url, None, &dir), Ok(Ready::Reused));
    assert_eq!(names(&dir), before);
    assert_eq!(names(&parent), vec![std::ffi::OsString::from("dir")]);
}

#[test]
fn a_repository_that_tracks_a_cmux_clone_clones_and_is_reused() {
    let root = tempfile::tempdir().unwrap();
    let url = origin(root.path());
    let source = root.path().join("source");
    std::fs::create_dir_all(source.join(super::CLAIM)).unwrap();
    std::fs::write(source.join(super::CLAIM).join("tracked"), "mine").unwrap();
    git(&source, &["add", "."]);
    git(&source, &["commit", "-qm", "two"]);
    let dir = root.path().join("dir");
    assert_eq!(ensure(&url, None, &dir), Ok(Ready::Cloned));
    assert_eq!(std::fs::read_to_string(dir.join(super::CLAIM).join("tracked")).unwrap(), "mine");
    assert!(dir.join("AGENTS.md").is_file());
    // Nothing of the claim is left beside it.
    let names: Vec<_> = std::fs::read_dir(&dir).unwrap().flatten().map(|e| e.file_name()).collect();
    assert_eq!(names.len(), 3, "{names:?}");
    assert_eq!(ensure(&url, None, &dir), Ok(Ready::Reused));
}

#[test]
fn a_clone_that_appears_while_claiming_is_reused_not_written_over() {
    let root = tempfile::tempdir().unwrap();
    let url = origin(root.path());
    let dir = root.path().join("dir");
    assert_eq!(ensure(&url, None, &dir), Ok(Ready::Cloned));
    std::fs::write(dir.join("AGENTS.md"), "edited").unwrap();
    // Another start's clone is there, but no `.git` is in view yet when this start looks: the
    // check under the claim finds the files and leaves them.
    let git_dir = dir.join(".git");
    let hidden = root.path().join("hidden-git");
    std::fs::rename(&git_dir, &hidden).unwrap();
    std::fs::create_dir(dir.join(super::CLAIM)).unwrap();
    assert!(!super::only_claim(&dir));
    std::fs::remove_dir(dir.join(super::CLAIM)).unwrap();
    std::fs::rename(&hidden, &git_dir).unwrap();
    assert_eq!(ensure(&url, None, &dir), Ok(Ready::Reused));
    assert_eq!(std::fs::read_to_string(dir.join("AGENTS.md")).unwrap(), "edited");
}

#[test]
fn a_move_into_place_never_replaces_what_is_there() {
    let root = tempfile::tempdir().unwrap();
    let (from, to) = (root.path().join("from"), root.path().join("to"));
    std::fs::write(&from, "clone").unwrap();
    // What another process wrote at the destination between any check and the move stays.
    std::fs::write(&to, "theirs").unwrap();
    let err = super::rename_no_replace(&from, &to).unwrap_err();
    assert_eq!(err.kind(), std::io::ErrorKind::AlreadyExists);
    assert_eq!(std::fs::read_to_string(&to).unwrap(), "theirs");
    assert!(from.is_file());
    // A folder too, onto an empty folder (which a plain rename replaces).
    let (dir_from, dir_to) = (root.path().join("dir-from"), root.path().join("dir-to"));
    std::fs::create_dir(&dir_from).unwrap();
    std::fs::create_dir(&dir_to).unwrap();
    assert!(super::rename_no_replace(&dir_from, &dir_to).is_err());
    std::fs::remove_dir(&dir_to).unwrap();
    super::rename_no_replace(&dir_from, &dir_to).unwrap();
    assert!(dir_to.is_dir() && !dir_from.exists());
}
