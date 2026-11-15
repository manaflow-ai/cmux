use super::*;

#[test]
fn only_a_host_whose_running_file_differs_from_its_launch_path_is_stale() {
    let stale = stale_hosts([
        ("moved".to_owned(), Some((1, 10)), Some((1, 20))),
        ("current".to_owned(), Some((1, 20)), Some((1, 20))),
        ("unreadable".to_owned(), None, Some((1, 20))),
        ("relative".to_owned(), Some((1, 10)), None),
    ]);
    assert_eq!(stale, BTreeSet::from(["moved".to_owned()]));
}

#[cfg(unix)]
#[test]
fn a_moved_file_is_stale_and_a_symlink_or_hard_link_to_it_is_not() {
    let dir = tempfile::tempdir().unwrap();
    let bin = dir.path().join("cmux");
    std::fs::write(&bin, b"old").unwrap();
    let link = dir.path().join("acpmux");
    std::os::unix::fs::symlink(&bin, &link).unwrap();
    let hard = dir.path().join("hard");
    std::fs::hard_link(&bin, &hard).unwrap();
    let running = file_id(&bin);
    assert_eq!(running, file_id(&link));
    assert_eq!(running, file_id(&hard));
    // The update: the old file moves away and a new one takes its path.
    std::fs::rename(&bin, dir.path().join("backup-cmux")).unwrap();
    std::fs::write(&bin, b"new").unwrap();
    assert_ne!(running, file_id(&link));
}

#[test]
fn this_process_is_not_stale() {
    let pid = std::process::id();
    if let (Some(running), Some(launched)) = (running_file(pid), launched_file(pid)) {
        assert_eq!(running, launched);
    }
}

#[tokio::test]
async fn a_daemon_with_no_running_agents_restarts_nothing() {
    let mut config: crate::config::Config =
        serde_json::from_value(serde_json::json!({"harnesses": {}})).unwrap();
    config.store.mode = crate::config::StoreMode::Memory;
    config.profile_sources = crate::config::ProfileSources::none();
    let store = crate::store::open(&config.store, Path::new("/unused")).unwrap();
    let out = Hub::new(config, store).respawn_stale_hosts().await;
    assert_eq!((out.now, out.after_turn, out.failed.len()), (0, 0, 0));
}
