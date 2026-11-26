use super::*;

#[cfg(any(target_os = "linux", target_os = "macos"))]
#[test]
fn the_record_is_this_users_and_dropping_its_guard_removes_it() {
    let home = tempfile::tempdir().unwrap();
    let written = write(home.path(), "127.0.0.1:52341".parse().unwrap()).unwrap();
    let record = read(home.path()).unwrap();
    assert_eq!(record.pid, std::process::id());
    assert_eq!(unhex(&record.key).unwrap().len(), SECRET_BYTES);
    use std::os::unix::fs::PermissionsExt as _;
    let mode = std::fs::metadata(home.path().join(FILE_NAME)).unwrap().permissions().mode();
    assert_eq!(mode & 0o777, 0o600);
    drop(written);
    assert!(!home.path().join(FILE_NAME).exists());
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
#[test]
fn a_lost_home_refuses_the_write() {
    let home = tempfile::tempdir().unwrap();
    let refused = write_fenced(home.path(), "127.0.0.1:52341".parse().unwrap(), |_| {
        Err(io::Error::other("the acpmux home is gone"))
    });
    assert!(refused.is_err());
    assert!(!home.path().join(FILE_NAME).exists());
    assert_eq!(std::fs::read_dir(home.path()).unwrap().count(), 0, "nothing written");
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
#[test]
fn a_startup_error_after_the_write_leaves_no_record() {
    fn start(home: &Path) -> io::Result<()> {
        let _record = write(home, "127.0.0.1:52341".parse().unwrap())?;
        assert!(home.join(FILE_NAME).exists());
        // A later startup step fails (`Mailbox::open`, the WireGuard transport): `?` returns.
        Err(io::Error::other("mailbox"))?;
        Ok(())
    }
    let home = tempfile::tempdir().unwrap();
    assert!(start(home.path()).is_err());
    assert!(!home.path().join(FILE_NAME).exists());
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
#[test]
fn a_wildcard_bind_is_recorded_as_loopback() {
    for (bound, recorded) in [
        ("0.0.0.0:52341", "127.0.0.1:52341"),
        ("[::]:52341", "[::1]:52341"),
        ("127.0.0.1:52341", "127.0.0.1:52341"),
        ("[::1]:52341", "[::1]:52341"),
    ] {
        let home = tempfile::tempdir().unwrap();
        let _written = write(home.path(), bound.parse().unwrap()).unwrap();
        assert_eq!(read(home.path()).unwrap().listen, recorded.parse().unwrap(), "{bound}");
    }
}

/// A listener on `bound` that answers one probe with `answer` (what it computes or replays).
async fn answering(
    listener: tokio::net::TcpListener,
    answer: impl FnOnce(&[u8]) -> String + Send + 'static,
) {
    tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        let mut head = Vec::new();
        while !head.ends_with(b"\r\n\r\n") {
            head.push(stream.read_u8().await.unwrap());
        }
        stream.write_all(answer(&head).as_bytes()).await.unwrap();
        let _ = stream.read_u8().await;
    });
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
#[tokio::test]
async fn a_wildcard_listener_is_reached_and_proven_through_its_record() {
    let listener = tokio::net::TcpListener::bind("0.0.0.0:0").await.unwrap();
    let bound = listener.local_addr().unwrap();
    answering(listener, |head| probe_answer(head).unwrap()).await;
    let home = tempfile::tempdir().unwrap();
    let _written = write(home.path(), bound).unwrap();
    assert!(connect_live(home.path(), Duration::from_secs(5)).await.is_ok());
}

/// The shutdown order: the record goes while the port is still held, so the link stops
/// sending peers here before any other process could bind the port.
#[cfg(any(target_os = "linux", target_os = "macos"))]
#[tokio::test]
async fn the_record_is_gone_before_the_port_closes() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let bound = listener.local_addr().unwrap();
    let home = tempfile::tempdir().unwrap();
    let written = write(home.path(), bound).unwrap();
    drop(written);
    assert!(!home.path().join(FILE_NAME).exists());
    // The port is still this daemon's and still accepts, yet the link no longer dials it.
    let raw = TcpStream::connect(bound).await.unwrap();
    let (_held, _) = listener.accept().await.unwrap();
    assert!(matches!(
        connect_live(home.path(), Duration::from_secs(5)).await,
        Err(NotLive::NoRecord)
    ));
    drop(raw);
    drop(listener);
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
#[tokio::test]
async fn an_answer_seen_before_does_not_pass_a_new_challenge() {
    // A process that watched one probe and its answer, then binds the port itself.
    let first = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let bound = first.local_addr().unwrap();
    let (seen_tx, seen_rx) = tokio::sync::oneshot::channel();
    answering(first, move |head| {
        let answer = probe_answer(head).unwrap();
        let _ = seen_tx.send(answer.clone());
        answer
    })
    .await;
    let home = tempfile::tempdir().unwrap();
    let _written = write(home.path(), bound).unwrap();
    assert!(connect_live(home.path(), Duration::from_secs(5)).await.is_ok());
    let seen = seen_rx.await.unwrap();
    // The first listener closes once its connection ends; then the port is free to take.
    let mut replayer = None;
    for _ in 0..100 {
        if let Ok(listener) = tokio::net::TcpListener::bind(bound).await {
            replayer = Some(listener);
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let replayer = replayer.expect("the port frees");
    answering(replayer, move |_| seen).await;
    assert_eq!(
        connect_live(home.path(), Duration::from_secs(5)).await.err(),
        Some(NotLive::WrongListener)
    );
}

#[test]
fn only_a_whole_probe_head_is_answered() {
    let challenge = hex(&[7u8; SECRET_BYTES]);
    let probe = format!("ACPMUX-LINK/2 {challenge}\r\n\r\n");
    assert!(probe_answer(probe.as_bytes()).is_some());
    assert!(probe_answer(format!("{probe}GET").as_bytes()).is_none());
    assert!(probe_answer(b"ACPMUX-LINK/2 00\r\n\r\n").is_none());
    assert!(probe_answer(b"GET / HTTP/1.1\r\n\r\n").is_none());
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
#[test]
fn another_daemons_record_is_left_alone() {
    let home = tempfile::tempdir().unwrap();
    let other = format!(
        r#"{{"version":2,"listen":"127.0.0.1:1","pid":1,"key":"{}"}}"#,
        hex(&[1u8; SECRET_BYTES])
    );
    std::fs::write(home.path().join(FILE_NAME), other).unwrap();
    assert!(read(home.path()).is_some(), "a well-formed record");
    remove_if_owned(home.path());
    assert!(home.path().join(FILE_NAME).exists());
}

/// A daemon that crashed left its record; a live listener now at that address (here: one
/// that answers with this process's key, as a newer daemon would) fails its challenge.
#[cfg(any(target_os = "linux", target_os = "macos"))]
#[tokio::test]
async fn a_dead_daemons_record_fails_the_challenge() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let bound = listener.local_addr().unwrap();
    answering(listener, |head| probe_answer(head).unwrap()).await;
    let home = tempfile::tempdir().unwrap();
    let dead = format!(
        r#"{{"version":2,"listen":"{bound}","pid":1,"key":"{}"}}"#,
        hex(&[1u8; SECRET_BYTES])
    );
    std::fs::write(home.path().join(FILE_NAME), dead).unwrap();
    assert!(matches!(
        connect_live(home.path(), Duration::from_secs(5)).await,
        Err(NotLive::WrongListener)
    ));
}
