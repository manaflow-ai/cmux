use super::*;

#[test]
fn identity_socket_round_trip_and_fail_closed_reply() {
    let dir = tempfile::tempdir().unwrap();
    fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
    let socket = dir.path().join("identity.sock");
    let mut listener = Listener::bind(&socket, None).unwrap();
    let id = HostIdentity {
        machine: "m".into(),
        instance_id: "i".into(),
        guest_key: "sha256:abc".into(),
    };
    let mut client = connect(&socket).unwrap();
    // SAFETY: geteuid has no preconditions.
    assert_eq!(peer_uid(&client).unwrap(), unsafe { libc::geteuid() });
    listener.accept();
    listener.reply(Some(&id));
    assert_eq!(read_reply(&mut client, TIMEOUT).unwrap(), id);
    let mut client = connect(&socket).unwrap();
    listener.accept();
    listener.reply(None);
    assert!(read_reply(&mut client, TIMEOUT).is_err());
}

#[test]
fn identity_socket_refuses_oversized_and_dripping_replies() {
    let (mut client, mut server) = UnixStream::pair().unwrap();
    server.write_all(&vec![b'x'; MAX_REPLY + 1]).unwrap();
    assert!(read_reply(&mut client, TIMEOUT).is_err());
    let (mut client, mut server) = UnixStream::pair().unwrap();
    let sender = std::thread::spawn(move || {
        for _ in 0..100 {
            if server.write_all(b"x").is_err() {
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    });
    let start = Instant::now();
    assert!(read_reply(&mut client, Duration::from_millis(80)).is_err());
    assert!(start.elapsed() < Duration::from_secs(1));
    drop(client);
    sender.join().unwrap();
}

#[test]
fn identity_socket_rejects_an_untrusted_peer_before_reading() {
    let dir = tempfile::tempdir().unwrap();
    fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
    let socket = dir.path().join("identity.sock");
    let _listener = Listener::bind(&socket, None).unwrap();
    // SAFETY: geteuid has no preconditions. Use a different required uid.
    let other_uid = unsafe { libc::geteuid() }.wrapping_add(1);
    assert_eq!(query_at(&socket, other_uid).unwrap_err().kind(), io::ErrorKind::PermissionDenied);
}
