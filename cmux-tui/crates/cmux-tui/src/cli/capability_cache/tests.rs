use super::*;

fn cache(label: &str) -> (CapabilityCache, PathBuf) {
    let root = std::env::temp_dir().join(format!(
        "cxcap-{label}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    std::fs::create_dir_all(&root).unwrap();
    (CapabilityCache::at(root.join("caps")), root)
}

#[test]
fn an_entry_answers_only_for_the_same_socket_and_daemon_process() {
    let (cache, root) = cache("key");
    let socket = Path::new("/tmp/one.sock");
    let capabilities = vec!["launch-credential-v1".to_owned()];
    cache.store(socket, "token:10.1", &capabilities);
    assert_eq!(cache.load(socket, "token:10.1"), Some(capabilities));
    assert_eq!(cache.load(socket, "token:10.2"), None, "a re-exec'd daemon is asked again");
    assert_eq!(cache.load(Path::new("/tmp/two.sock"), "token:10.1"), None);
    let _ = std::fs::remove_dir_all(root);
}

#[cfg(unix)]
#[test]
fn a_directory_others_may_write_is_not_trusted() {
    use std::os::unix::fs::PermissionsExt;
    let (cache, root) = cache("perm");
    let socket = Path::new("/tmp/one.sock");
    cache.store(socket, "token:10.1", &["launch-credential-v1".to_owned()]);
    let directory = root.join("caps");
    std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o777)).unwrap();
    assert_eq!(cache.load(socket, "token:10.1"), None);
    let _ = std::fs::remove_dir_all(root);
}
