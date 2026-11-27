use super::*;
use crate::store::care_tests::scratch;
use std::cell::RefCell;

#[test]
fn trim_checks_each_output_before_deleting_it() {
    let root = scratch("trim-preservation");
    for name in ["first", "protected"] {
        std::fs::create_dir_all(root.join(name)).unwrap();
        std::fs::write(root.join(name).join("keep.txt"), "local data").unwrap();
    }
    let facts =
        Facts { build_output: vec!["first/".into(), "protected/".into()], ..Facts::default() };
    let worktree = Worktree {
        path: root.clone(),
        branch: None,
        head: None,
        locked: false,
        prunable: false,
        facts: Ok(facts.clone()),
    };
    let checked = RefCell::new(Vec::new());
    let preserve = |path: &Path| {
        checked.borrow_mut().push(path.to_path_buf());
        assert!(path.join("keep.txt").exists());
        if path == root.join("protected") { Err("protected descendant".into()) } else { Ok(()) }
    };
    let error = trim_guarded(&worktree, &facts, &|| Ok(Vec::new()), &preserve).unwrap_err();
    assert!(error.contains("protected descendant"));
    assert_eq!(*checked.borrow(), vec![root.join("first"), root.join("protected")]);
    assert!(!root.join("first").exists());
    assert_eq!(std::fs::read_to_string(root.join("protected/keep.txt")).unwrap(), "local data");
}

fn git(root: &Path, args: &[&str]) -> String {
    let output = std::process::Command::new("git")
        .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"])
        .args(["-c", "core.hooksPath=/dev/null"])
        .args(args)
        .current_dir(root)
        .output()
        .unwrap();
    assert!(output.status.success(), "{args:?}: {}", String::from_utf8_lossy(&output.stderr));
    String::from_utf8_lossy(&output.stdout).trim().to_owned()
}

#[test]
fn preservation_refusal_after_archival_keeps_worktree_and_discards_archive() {
    let root = scratch("reclaim-preservation");
    let main = root.join("main");
    std::fs::create_dir_all(&main).unwrap();
    git(&main, &["init", "-q", "-b", "main"]);
    std::fs::write(main.join("data"), "original").unwrap();
    git(&main, &["add", "data"]);
    git(&main, &["commit", "-qm", "initial"]);
    let path = root.join("worktree");
    git(&main, &["worktree", "add", "-q", "-b", "local", path.to_str().unwrap()]);
    std::fs::write(path.join("data"), "uncommitted").unwrap();
    let store = Store::open(root.join("store")).unwrap();
    let memo = std::sync::Arc::new(crate::inventory::FinishedMemo::load(store.finished_path()));
    let repo = crate::inventory::scan_with_memo(&main.join(".git"), &[], memo).unwrap();
    let worktree = repo.worktrees.iter().find(|wt| wt.path == path).unwrap();
    let facts = worktree.facts.as_ref().unwrap();
    let preserve = |checked: &Path| {
        assert_eq!(checked, path);
        assert_eq!(store.list().len(), 1, "the final check must follow archival");
        Err("protected descendant".into())
    };
    let error = reclaim_guarded(
        &repo,
        worktree,
        facts,
        Action::Archive,
        "test",
        &store,
        &|| Ok(Vec::new()),
        &|_| Ok(None),
        None,
        &preserve,
    )
    .unwrap_err();
    assert!(error.contains("protected descendant"), "{error}");
    assert_eq!(std::fs::read_to_string(path.join("data")).unwrap(), "uncommitted");
    assert!(store.list().is_empty(), "refused removal must discard its manifest");
    assert!(git(&main, &["for-each-ref", "refs/cmux/archive/"]).is_empty());
}
