use super::*;

fn run(dir: &Path, args: &[&str]) -> String {
    git(dir, None, args).unwrap_or_else(|| panic!("git {args:?} failed"))
}

#[test]
fn work_is_kept_under_a_ref_outside_heads_and_pushed() {
    let root = tempfile::tempdir().unwrap();
    let remote = root.path().join("remote.git");
    let work = root.path().join("work");
    std::fs::create_dir_all(&work).unwrap();
    run(root.path(), &["init", "-q", "--bare", remote.to_str().unwrap()]);
    run(&work, &["init", "-q", "-b", "main"]);
    run(&work, &["remote", "add", "origin", remote.to_str().unwrap()]);
    std::fs::write(work.join("a.txt"), "one\n").unwrap();
    run(&work, &["add", "a.txt"]);
    run(&work, &["commit", "-q", "-m", "first"]);
    // Uncommitted, untracked and ignored.
    std::fs::write(work.join("a.txt"), "two\n").unwrap();
    std::fs::write(work.join("new.txt"), "new\n").unwrap();
    std::fs::write(work.join(".gitignore"), "secret\n").unwrap();
    std::fs::write(work.join("secret"), "no\n").unwrap();
    let head = run(&work, &["rev-parse", "HEAD"]);

    let saved = save_blocking(&work, "sess-1");
    let Saved::Written { commit, pushed } = saved else { panic!("{saved:?}") };
    assert!(pushed);
    assert_eq!(run(&remote, &["rev-parse", "refs/cmux-wip/sess-1"]), commit);
    assert_eq!(run(&remote, &["show", &format!("{commit}:new.txt")]), "new");
    assert_eq!(run(&remote, &["show", &format!("{commit}:a.txt")]), "two");
    assert!(git(&remote, None, &["cat-file", "-e", &format!("{commit}:secret")]).is_none());
    // Nothing the person sees changed: no branch pushed, HEAD, index and files as they were.
    assert_eq!(run(&remote, &["for-each-ref", "refs/heads"]), "");
    assert_eq!(run(&work, &["rev-parse", "HEAD"]), head);
    assert_eq!(run(&work, &["diff", "--cached", "--name-only"]), "");
    assert_eq!(std::fs::read_to_string(work.join("a.txt")).unwrap(), "two\n");
    // Unchanged work writes nothing more.
    assert_eq!(save_blocking(&work, "sess-1"), Saved::Unchanged);
    std::fs::write(work.join("new.txt"), "newer\n").unwrap();
    assert!(matches!(save_blocking(&work, "sess-1"), Saved::Written { pushed: true, .. }));
}

#[test]
fn a_repository_with_no_origin_and_no_commit_is_a_plain_folder() {
    let dir = tempfile::tempdir().unwrap();
    run(dir.path(), &["init", "-q"]);
    std::fs::write(dir.path().join("notes.txt"), "work\n").unwrap();
    assert_eq!(save_blocking(dir.path(), "sess-1"), Saved::Skipped);
    // No ref and no objects were written for it.
    assert_eq!(run(dir.path(), &["for-each-ref"]), "");
    assert_eq!(run(dir.path(), &["count-objects"]), "0 objects, 0 kilobytes");
    // With an origin, an unborn repository's work is still saved (the push has a place to go).
    let remote = dir.path().join("remote.git");
    run(dir.path(), &["init", "-q", "--bare", remote.to_str().unwrap()]);
    run(dir.path(), &["remote", "add", "origin", remote.to_str().unwrap()]);
    std::fs::write(dir.path().join(".gitignore"), "remote.git/\n").unwrap();
    assert!(matches!(save_blocking(dir.path(), "sess-1"), Saved::Written { pushed: true, .. }));
}

#[test]
fn a_folder_without_git_or_a_plain_id_is_skipped() {
    let dir = tempfile::tempdir().unwrap();
    assert_eq!(save_blocking(dir.path(), "sess-1"), Saved::Skipped);
    assert_eq!(save_blocking(dir.path(), "../x"), Saved::Skipped);
}
