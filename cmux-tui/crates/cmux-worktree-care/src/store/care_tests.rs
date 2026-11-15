use super::*;

/// A fresh empty folder for one test.
pub(crate) fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "cmux-worktree-care-{name}-{}-{}",
        std::process::id(),
        crate::inventory::now_ms()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn an_id_is_safe_in_a_ref_name() {
    assert_eq!(new_id(5, Path::new("/w/fix login.x")), "5-fix-login-x");
    assert_eq!(new_id(5, Path::new("/")), "5");
}

#[test]
fn a_saved_manifest_is_found_by_folder_branch_or_id() {
    let store = Store::open(scratch("store")).unwrap();
    let manifest = Manifest {
        id: "1-a".into(),
        created_ms: 1,
        path: "/w/a".into(),
        common_dir: "/r/.git".into(),
        main_root: Some("/r".into()),
        branch: Some("feat/a".into()),
        head: None,
        archive_ref: None,
        archive_commit: None,
        bundle: None,
        sparse: None,
        submodules: vec![],
        dropped: vec![],
        reason: "test".into(),
        freed: 0,
        restored_ms: None,
    };
    store.save(&manifest).unwrap();
    assert_eq!(store.find("/w/a").as_ref(), Some(&manifest));
    assert_eq!(store.find("feat/a").as_ref(), Some(&manifest));
    assert_eq!(store.load("1-a").unwrap(), manifest);
    store.save(&Manifest { restored_ms: Some(2), ..manifest }).unwrap();
    assert!(store.find("1-a").is_none());
}
