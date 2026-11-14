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
