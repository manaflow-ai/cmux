use super::*;

#[test]
fn a_gone_folder_matches_through_a_linked_parent() {
    let dir = std::env::temp_dir().join(format!("cmux-care-resolved-{}", std::process::id()));
    let real = dir.join("worktrees.noindex");
    std::fs::create_dir_all(real.join("app")).unwrap();
    let link = dir.join("worktrees");
    let _ = std::fs::remove_file(&link);
    std::os::unix::fs::symlink("worktrees.noindex", &link).unwrap();
    // git recorded the real path; the session kept the linked one; the folder is gone
    let recorded = real.join("app/fix-retry");
    let cwd = link.join("app/fix-retry");
    assert!(same_folder(&recorded, &cwd));
    assert!(inside_folder(&cwd.join("sub"), &recorded));
    assert!(!same_folder(&recorded, &link.join("app/other")));
    // A live session registered with the linked cwd still holds the worktree git lists by
    // its real path, so a cleanup pass keeps it.
    std::fs::create_dir_all(&recorded).unwrap();
    let session = [crate::procs::Process { pid: u32::MAX, cwd: cwd.join("src") }];
    assert!(crate::procs::inside(&session, &recorded).is_some());
    assert!(crate::procs::inside(&session, &real.join("app/other")).is_none());
    let _ = std::fs::remove_dir_all(&dir);
}
