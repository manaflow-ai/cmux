use super::*;

#[tokio::test]
async fn bind_preserves_an_existing_owner_controlled_directory() {
    let directory = tempfile::tempdir().unwrap();
    fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o755)).unwrap();
    let socket = directory.path().join("daemon.sock");

    let listener = OwnedUnixListener::bind(socket.clone()).await.unwrap();

    assert_eq!(fs::metadata(directory.path()).unwrap().permissions().mode() & 0o777, 0o755);
    assert_eq!(fs::metadata(&socket).unwrap().permissions().mode() & 0o777, 0o600);
    drop(listener);
}
