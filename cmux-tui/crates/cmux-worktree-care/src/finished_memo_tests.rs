use super::*;

#[test]
fn oversized_and_corrupt_memos_are_ignored() {
    let dir = crate::store::care_tests::scratch("bounded-memo");
    let path = dir.join("memo.json");
    let file = std::fs::File::create(&path).unwrap();
    file.set_len(MAX_MEMO_BYTES + 1).unwrap();
    assert!(read_memo(&path).is_none());
    std::fs::write(&path, "invalid json").unwrap();
    assert!(read_memo(&path).is_none());
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn completed_answer_is_durable_without_a_pass_flush() {
    let dir = crate::store::care_tests::scratch("incremental-memo");
    let path = dir.join("memo.json");
    let memo = FinishedMemo::load(path.clone());
    let root = Path::new("/worktrees/a");
    let head = "1".repeat(40);
    let base = "2".repeat(40);
    memo.remember(root, &head, &base, None);
    let reader = FinishedMemo::load(path);
    assert_eq!(reader.remembered(root, &head, &base), Some(None));
    assert!(reader._writer.is_none(), "a second writer cannot overwrite progress");
    drop(reader);
    drop(memo);
    std::fs::remove_dir_all(dir).unwrap();
}

/// A memo that drops lets go of its writer lock, also while a child the daemon forked
/// meanwhile has the descriptor: else the next pass's memo gets no writer and never saves
/// its answers.
#[cfg(unix)]
#[test]
fn a_dropped_memo_frees_its_writer_lock_while_a_forked_child_keeps_its_descriptor() {
    let dir = crate::store::care_tests::scratch("forked-memo");
    let path = dir.join("memo.json");
    let memo = FinishedMemo::load(path.clone());
    assert!(memo._writer.is_some(), "the first memo writes");
    let keeper = crate::test_fork::Keeper::fork();
    drop(memo);
    let next = FinishedMemo::load(path);
    drop(keeper);
    assert!(next._writer.is_some(), "a dropped memo left its writer lock held");
    drop(next);
    std::fs::remove_dir_all(dir).unwrap();
}
