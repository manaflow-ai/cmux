use super::*;

#[test]
fn cloud_peer_uses_a_durable_chat_folder() {
    let home = std::env::temp_dir().join(format!("cmux-cloud-peer-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    // A Cloud machine's home folder exists; only `chats` and the chat's
    // folder are made here.
    std::fs::create_dir_all(&home).unwrap();
    let dir = cloud_chat_folder_under(&home, "chat-1").unwrap();
    assert_eq!(dir, home.join("chats/chat-1"));
    assert!(dir.is_dir());
    assert!(dir.join(crate::trust::AGENT_HOME_MARKER).is_file(), "marked as acpmux's");
    // A retry reuses the folder and keeps its marker.
    assert_eq!(cloud_chat_folder_under(&home, "chat-1").unwrap(), dir);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(home.join("chats")).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777, 0o700);
    }
    let _ = std::fs::remove_dir_all(home);
}

/// A lane host, 2026-11-28: `~/chats` was this user's folder at mode 775, and every start
/// with no folder was refused as "/home/cmux/chats is not a directory". acpmux makes its own
/// folder private and goes on; a fault it does not repair says what it is, as the host's fault.
#[cfg(unix)]
#[test]
fn a_group_writable_chats_folder_is_made_private_and_other_faults_say_what_they_are() {
    use std::os::unix::fs::PermissionsExt;
    let home = tempfile::tempdir().unwrap();
    let home = home.path();
    let chats = home.join("chats");
    std::fs::create_dir(&chats).unwrap();
    std::fs::set_permissions(&chats, std::fs::Permissions::from_mode(0o775)).unwrap();
    let dir = cloud_chat_folder_under(home, "chat-1").unwrap();
    assert_eq!(dir, chats.join("chat-1"));
    assert_eq!(std::fs::metadata(&chats).unwrap().permissions().mode() & 0o777, 0o755);
    // The chat's own folder too.
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o777)).unwrap();
    cloud_chat_folder_under(home, "chat-1").unwrap();
    assert_eq!(std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777, 0o755);

    let reason = |e: &RpcError| e.data.as_ref().and_then(|d| d.get("reason")).cloned();
    // A file where `chats` should be.
    let file_home = tempfile::tempdir().unwrap();
    std::fs::write(file_home.path().join("chats"), b"").unwrap();
    let e = cloud_chat_folder_under(file_home.path(), "chat-1").unwrap_err();
    assert!(e.message.ends_with("chats is not a directory"), "{}", e.message);
    assert_eq!(reason(&e), Some(serde_json::json!(CHAT_FOLDER_REASON)));
    // A symlink to a folder is refused as one, not followed or changed.
    let link_home = tempfile::tempdir().unwrap();
    let target = link_home.path().join("elsewhere");
    std::fs::create_dir(&target).unwrap();
    std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o777)).unwrap();
    std::os::unix::fs::symlink(&target, link_home.path().join("chats")).unwrap();
    let e = cloud_chat_folder_under(link_home.path(), "chat-1").unwrap_err();
    assert!(e.message.contains("is a symlink, not a directory"), "{}", e.message);
    assert_eq!(std::fs::metadata(&target).unwrap().permissions().mode() & 0o777, 0o777);
    assert!(!target.join("chat-1").exists());
}

#[cfg(unix)]
#[test]
fn each_chat_folder_fault_is_named() {
    let at = std::path::Path::new("/h/chats");
    assert_eq!(
        ChatFolderFault::Writable(0o40775).describe(at),
        "/h/chats is writable by its group or others (mode 775) and could not be made private"
    );
    assert_eq!(
        ChatFolderFault::NotOwned(0).describe(at),
        "/h/chats is owned by uid 0, not this user"
    );
    assert_eq!(ChatFolderFault::NotADirectory.describe(at), "/h/chats is not a directory");
}
