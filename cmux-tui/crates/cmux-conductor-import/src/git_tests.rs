use super::*;

#[test]
fn porcelain_entries() {
    let listing = b"worktree /r\0HEAD 0123\0branch refs/heads/main\0\0worktree /w/a\0HEAD 4567\0branch refs/heads/feat\0\0worktree /w/gone\0HEAD 89ab\0detached\0prunable gitdir file points to non-existent location\0\0";
    let entries = parse_worktree_list(listing);
    assert_eq!(entries.len(), 3);
    assert_eq!(entries[1].branch.as_deref(), Some("feat"));
    assert!(entries[2].prunable && entries[2].branch.is_none());
}
