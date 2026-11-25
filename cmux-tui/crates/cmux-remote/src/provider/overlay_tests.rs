use super::*;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::net::UnixListener;

async fn fake_link(reply: &'static str) -> (cmux_unix_socket::TestDir, std::path::PathBuf) {
    let directory = cmux_unix_socket::short_test_dir("ovdial");
    let path = directory.path().join("link.sock");
    let listener = UnixListener::bind(&path).unwrap();
    tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (read, mut write) = stream.into_split();
        let mut lines = BufReader::new(read).lines();
        let request = lines.next_line().await.unwrap().unwrap();
        assert_eq!(request, r#"{"op":"link.dial","host":"inst_b","service":"daemon"}"#);
        write.write_all(reply.as_bytes()).await.unwrap();
        write.write_all(b"{\"ok\":true}\n").await.unwrap();
        let echoed = lines.next_line().await.unwrap().unwrap();
        write.write_all(format!("{echoed}\n").as_bytes()).await.unwrap();
    });
    (directory, path)
}

#[tokio::test]
async fn a_dial_returns_the_stream_after_the_reply_with_no_byte_lost() {
    let (_directory, path) =
        fake_link("{\"ok\":true,\"path_state\":\"direct\",\"relay_available\":false}\n").await;
    let dialed = dial_link(&path, "inst_b", Service::Daemon).await.unwrap();
    assert_eq!(dialed.path_state, PathState::Direct);
    assert!(!dialed.relay_available);
    let mut lines = BufReader::new(dialed.stream);
    let mut first = String::new();
    lines.read_line(&mut first).await.unwrap();
    assert_eq!(first, "{\"ok\":true}\n", "the first service byte stays in the stream");
    lines.get_mut().write_all(b"ping\n").await.unwrap();
    let mut echoed = String::new();
    lines.read_line(&mut echoed).await.unwrap();
    assert_eq!(echoed, "ping\n");
}

#[tokio::test]
async fn a_refused_dial_reports_the_link_error_and_no_relay() {
    let directory = cmux_unix_socket::short_test_dir("ovdial");
    let path = directory.path().join("link.sock");
    let listener = UnixListener::bind(&path).unwrap();
    tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        let mut request = [0u8; 64];
        let _ = stream.read(&mut request).await;
        let reply = "{\"ok\":false,\"path_state\":\"unreachable\",\"relay_available\":false,\"error_code\":\"unreachable\"}\n";
        stream.write_all(reply.as_bytes()).await.unwrap();
    });
    match dial_link(&path, "inst_b", Service::Daemon).await {
        Err(OverlayDialError::Refused { error, path_state, relay_available, .. }) => {
            assert_eq!(error, Some(DialError::Unreachable));
            assert_eq!(path_state, PathState::Unreachable);
            assert!(!relay_available);
        }
        other => panic!("expected a refusal, got {other:?}"),
    }
    let missing = directory.path().join("none.sock");
    assert!(matches!(
        dial_link(&missing, "inst_b", Service::Daemon).await,
        Err(OverlayDialError::LinkUnavailable(_))
    ));
}
