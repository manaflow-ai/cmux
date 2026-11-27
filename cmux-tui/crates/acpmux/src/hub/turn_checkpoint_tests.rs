use super::*;

fn run(dir: &Path, args: &[&str]) -> String {
    git(dir, None, args).unwrap_or_else(|| panic!("git {args:?} failed"))
}

fn repo() -> (tempfile::TempDir, PathBuf) {
    let root = tempfile::tempdir().unwrap();
    let work = root.path().join("work");
    std::fs::create_dir_all(&work).unwrap();
    run(&work, &["init", "-q", "-b", "main"]);
    std::fs::write(work.join("a.txt"), "one\n").unwrap();
    run(&work, &["add", "a.txt"]);
    run(&work, &["commit", "-q", "-m", "first"]);
    (root, work)
}

fn commit_of(taken: &Taken) -> &str {
    match taken {
        Taken::Written { commit } | Taken::Same { commit } => commit,
        Taken::Skipped => panic!("skipped"),
    }
}

#[test]
fn a_turn_keeps_the_folder_uncommitted_and_untracked_without_touching_it() {
    let (_root, work) = repo();
    std::fs::write(work.join("a.txt"), "two\n").unwrap();
    std::fs::write(work.join("new.txt"), "new\n").unwrap();
    std::fs::write(work.join(".gitignore"), "secret\n").unwrap();
    std::fs::write(work.join("secret"), "no\n").unwrap();
    run(&work, &["add", "new.txt"]);
    let head = run(&work, &["rev-parse", "HEAD"]);
    let status = run(&work, &["status", "--porcelain"]);

    let taken = take_blocking(&work, "sess-1", "turn-1");
    let Taken::Written { commit } = &taken else { panic!("{taken:?}") };
    assert_eq!(run(&work, &["rev-parse", "refs/cmux-turns/sess-1/turn-1"]), *commit);
    assert_eq!(run(&work, &["show", &format!("{commit}:a.txt")]), "two");
    assert_eq!(run(&work, &["show", &format!("{commit}:new.txt")]), "new");
    assert!(git(&work, None, &["cat-file", "-e", &format!("{commit}:secret")]).is_none());
    assert_eq!(run(&work, &["rev-parse", &format!("{commit}^")]), head, "on top of HEAD");
    // The folder's branch, index and tree are as they were.
    assert_eq!(run(&work, &["rev-parse", "HEAD"]), head);
    assert_eq!(run(&work, &["status", "--porcelain"]), status);
    assert!(run(&work, &["for-each-ref", "refs/heads"]).lines().count() == 1);
}

#[test]
fn a_turn_that_changed_nothing_names_the_last_commit() {
    let (_root, work) = repo();
    std::fs::write(work.join("b.txt"), "b\n").unwrap();
    let first = take_blocking(&work, "s", "t1");
    let same = take_blocking(&work, "s", "t2");
    assert_eq!(same, Taken::Same { commit: commit_of(&first).to_owned() });
    std::fs::write(work.join("b.txt"), "c\n").unwrap();
    let third = take_blocking(&work, "s", "t3");
    assert!(matches!(third, Taken::Written { .. }));
    assert_ne!(commit_of(&third), commit_of(&first));
    // Each turn keeps its own: t1 still has the first contents.
    assert_eq!(run(&work, &["show", "refs/cmux-turns/s/t1:b.txt"]), "b");
    assert_eq!(run(&work, &["show", "refs/cmux-turns/s/t3:b.txt"]), "c");
}

#[test]
fn sessions_do_not_share_their_latest() {
    let (_root, work) = repo();
    let a = take_blocking(&work, "a", "t");
    let b = take_blocking(&work, "b", "t");
    assert!(matches!(a, Taken::Written { .. }));
    assert!(matches!(b, Taken::Written { .. }), "another session's first turn writes its own");
}

#[test]
fn not_a_repository_or_an_odd_id_is_skipped() {
    let plain = tempfile::tempdir().unwrap();
    assert_eq!(take_blocking(plain.path(), "s", "t"), Taken::Skipped);
    let (_root, work) = repo();
    assert_eq!(take_blocking(&work, "s", "../x"), Taken::Skipped);
    assert_eq!(take_blocking(&work, "", "t"), Taken::Skipped);
    assert!(ref_name("s", &"x".repeat(81)).is_none());
}

#[test]
fn only_the_newest_are_kept() {
    let (_root, work) = repo();
    let prefix = "refs/cmux-turns/s/";
    // Older states than any new checkpoint: the order is the state's commit time.
    let tree = run(&work, &["rev-parse", "HEAD^{tree}"]);
    let out = std::process::Command::new("git")
        .arg("-C")
        .arg(&work)
        .args([
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@example.com",
            "commit-tree",
            &tree,
            "-m",
            "old",
        ])
        .env("GIT_COMMITTER_DATE", "2001-01-01T00:00:00Z")
        .output()
        .unwrap();
    let old = String::from_utf8(out.stdout).unwrap().trim().to_owned();
    for i in 0..KEEP + 3 {
        let _ = git(&work, None, &["update-ref", &format!("{prefix}old-{i:04}"), &old]);
    }
    let _ = take_blocking(&work, "s", "new");
    let left = run(&work, &["for-each-ref", "--format=%(refname)", prefix]);
    assert!(left.lines().count() <= KEEP, "{}", left.lines().count());
    assert!(left.lines().any(|l| l == "refs/cmux-turns/s/new"));
}

#[test]
fn the_switch_is_off_unless_on() {
    assert!(!enabled_with(None, None));
    let on = serde_json::json!({"agents": {"harnessMagic": {"checkpoints": {"enabled": true}}}});
    let off = serde_json::json!({"agents": {"harnessMagic": {"checkpoints": {"enabled": false}}}});
    assert!(enabled_with(Some(&on), None));
    assert!(!enabled_with(Some(&off), None));
    assert!(!enabled_with(Some(&on), Some("0")));
    assert!(enabled_with(Some(&off), Some("1")));
    assert!(!enabled_with(None, Some("maybe")));
}

#[test]
fn the_turn_result_says_what_it_did_and_counts_it() {
    let written = field(Some(&Taken::Written { commit: "abc".into() }));
    assert_eq!(written["checkpoint"], serde_json::json!({"commit": "abc", "changed": true}));
    let same = field(Some(&Taken::Same { commit: "abc".into() }));
    assert_eq!(same["checkpoint"]["changed"], false);
    assert!(!field(Some(&Taken::Skipped)).contains_key("checkpoint"));
    assert!(!field(None).contains_key("checkpoint"));

    let mut msg = Value::Object(written);
    count(&mut msg);
    assert_eq!(msg.pointer("/harnessMagic/checkpoints/written"), Some(&serde_json::json!(1)));
    assert!(msg.get(STATE_KEY).is_none(), "the private key does not reach the log");
    let mut late = Value::Object(field(None));
    count(&mut late);
    assert_eq!(late.pointer("/harnessMagic/checkpoints/late"), Some(&serde_json::json!(1)));
    let mut untouched = serde_json::json!({"turnId": "t"});
    count(&mut untouched);
    assert!(untouched.get("harnessMagic").is_none(), "off: nothing added");
}

#[test]
fn a_sparse_checkout_keeps_the_files_it_does_not_check_out() {
    // Lane checkouts are sparse: a scratch index started empty would leave every file outside
    // the cone out of the checkpoint, and a rewind to it would delete them.
    let (_root, work) = repo();
    std::fs::create_dir_all(work.join("far")).unwrap();
    std::fs::write(work.join("far/kept.txt"), "kept\n").unwrap();
    run(&work, &["add", "far/kept.txt"]);
    run(&work, &["commit", "-q", "-m", "far"]);
    run(&work, &["sparse-checkout", "set", "--no-cone", "/a.txt"]);
    assert!(!work.join("far/kept.txt").exists(), "outside the sparse set");
    std::fs::write(work.join("a.txt"), "edited\n").unwrap();

    let taken = take_blocking(&work, "s", "t");
    let commit = commit_of(&taken);
    assert_eq!(run(&work, &["show", &format!("{commit}:far/kept.txt")]), "kept");
    assert_eq!(run(&work, &["show", &format!("{commit}:a.txt")]), "edited");
}
