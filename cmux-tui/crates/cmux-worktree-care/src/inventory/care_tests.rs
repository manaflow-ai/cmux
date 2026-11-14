use super::*;

#[test]
fn the_worktree_list_names_each_worktree_with_its_state() {
    let listing = b"worktree /r\0HEAD 1111111111111111111111111111111111111111\0branch refs/heads/main\0\0worktree /w/a\0HEAD 2222222222222222222222222222222222222222\0detached\0locked\0\0worktree /w/b\0HEAD 3333333333333333333333333333333333333333\0branch refs/heads/feat/x\0prunable gitdir file points to non-existent location\0\0";
    let entries = parse_worktree_list(listing);
    assert_eq!(entries.len(), 3);
    assert_eq!(entries[0].branch.as_deref(), Some("main"));
    assert!(entries[1].locked && entries[1].branch.is_none());
    assert!(entries[2].prunable);
    assert_eq!(entries[2].branch.as_deref(), Some("feat/x"));
}

#[test]
fn build_output_needs_its_name_and_its_marker() {
    let root = crate::store::care_tests::scratch("markers");
    std::fs::create_dir_all(root.join("webviews")).unwrap();
    std::fs::write(root.join("webviews/package.json"), "{}").unwrap();
    std::fs::create_dir_all(root.join("cmux-tui")).unwrap();
    std::fs::write(root.join("cmux-tui/Cargo.toml"), "").unwrap();
    assert!(is_build_output_at(&root, "webviews/node_modules/"));
    assert!(is_build_output_at(&root, "cmux-tui/target/"));
    assert!(is_build_output_at(&root, "cmux-tui/target/debug/x"));
    assert!(is_build_output_at(&root, "a/b/__pycache__/"));
    assert!(!is_build_output_at(&root, "node_modules/"), "no package.json beside it");
    assert!(!is_build_output_at(&root, "docs/target/"), "a target/ that is not cargo's");
    assert!(!is_build_output_at(&root, ".env"));
    assert!(!is_build_output_at(&root, "webviews/src/generated/"));
    assert!(!is_build_output_at(&root, "targets.txt"));
}

#[test]
fn the_reflog_time_is_the_last_entry_s() {
    let dir = crate::store::care_tests::scratch("reflog");
    let log = dir.join("HEAD");
    std::fs::write(
            &log,
            "0000 1111 A <a@b> 1700000000 +0000\tclone\n1111 2222 A <a@b> 1700000500 -0700\tcommit: x\n",
        )
        .unwrap();
    assert_eq!(reflog_time(&log), Some(1_700_000_500_000));
}

#[test]
fn persisted_finished_answers_survive_a_restart() {
    let path = crate::store::care_tests::scratch("finished-memo").join("answers.json");
    let memo = FinishedMemo::load(path.clone());
    let root = Path::new("/worktrees/a");
    memo.remember(
        root,
        "1111111111111111111111111111111111111111",
        "2222222222222222222222222222222222222222",
        Some(Finish::Squashed),
    );
    memo.flush();
    drop(memo);
    let restarted = FinishedMemo::load(path);
    assert_eq!(
        restarted.remembered(
            root,
            "1111111111111111111111111111111111111111",
            "2222222222222222222222222222222222222222"
        ),
        Some(Some(Finish::Squashed))
    );
}

#[test]
fn an_oversized_pair_skips_merge_tree() {
    assert!(within_squash_limit("128"));
    assert!(!within_squash_limit("129"));
    assert!(!within_squash_limit("not-a-count"));
}

/// A merge check lets go of the host's merge-tree lock, also while a child the daemon
/// forked meanwhile has the descriptor: else the next squash check reads "unknown".
#[cfg(unix)]
#[test]
fn a_dropped_merge_tree_claim_is_free_while_a_forked_child_keeps_its_descriptor() {
    let dir = crate::store::care_tests::scratch("forked-merge-tree");
    let claim = merge_tree_claim(Some(&dir)).expect("a free merge-tree lock");
    let keeper = crate::test_fork::Keeper::fork();
    drop(claim);
    let next = merge_tree_claim(Some(&dir));
    drop(keeper);
    assert!(next.is_some(), "a dropped merge-tree claim left the lock held");
    drop(next);
    std::fs::remove_dir_all(dir).unwrap();
}
