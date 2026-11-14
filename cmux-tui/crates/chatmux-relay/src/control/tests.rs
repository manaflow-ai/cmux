use super::*;
use serde_json::json;
use tokio::io::{AsyncBufReadExt as _, AsyncWriteExt as _};
use tokio::net::UnixListener;
use tokio::sync::oneshot;

#[tokio::test]
async fn writer_queue_preserves_complete_fifo_lines() {
    let socket_path =
        std::env::temp_dir().join(format!("chatmux-relay-control-{}.sock", std::process::id()));
    let _ = std::fs::remove_file(&socket_path);
    let listener = UnixListener::bind(&socket_path).expect("bind control test socket");
    let (accepted_tx, accepted_rx) = oneshot::channel();
    let (release_tx, release_rx) = oneshot::channel();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.expect("accept control test socket");
        let (read_half, mut write_half) = stream.into_split();
        accepted_tx.send(()).expect("tell client that socket is accepted");
        // Hold the reader while the client queues several large lines.
        // This exercises the writer's backpressure path without relying
        // on a platform-specific socket buffer size.
        release_rx.await.expect("release control test reader");
        let mut reader = tokio::io::BufReader::new(read_half);
        let mut lines = Vec::new();
        for _ in 0..9 {
            let mut line = String::new();
            reader.read_line(&mut line).await.expect("read control line");
            lines.push(line);
        }
        let request: Value =
            serde_json::from_str(lines[8].trim_end()).expect("decode request line");
        let id = request.get("id").and_then(Value::as_u64).expect("request id");
        let response = format!("{{\"id\":{id},\"ok\":true}}\n");
        write_half.write_all(response.as_bytes()).await.expect("write response line");
        lines
    });

    let control = connect_control(&socket_path, 3_000).await.expect("connect control test socket");
    accepted_rx.await.expect("wait for control test server");
    let payload = "x".repeat(128 * 1024);
    for index in 0..8 {
        control.send("send", json!({ "index": index, "payload": payload.clone() }));
    }
    release_tx.send(()).expect("release control test reader");
    let response = control.request("probe", json!({})).await;
    assert_eq!(response.and_then(|value| value.get("ok").and_then(Value::as_bool)), Some(true));

    let lines = server.await.expect("join control test server");
    assert!(lines.iter().all(|line| line.ends_with('\n')));
    for (index, line) in lines.iter().take(8).enumerate() {
        let value: Value = serde_json::from_str(line.trim_end()).expect("decode send line");
        assert_eq!(value.get("cmd").and_then(Value::as_str), Some("send"));
        assert_eq!(value.get("index").and_then(Value::as_u64), Some(index as u64));
        assert_eq!(value.get("payload").and_then(Value::as_str).map(str::len), Some(128 * 1024));
    }
    let request: Value = serde_json::from_str(lines[8].trim_end()).expect("decode probe line");
    assert_eq!(request.get("cmd").and_then(Value::as_str), Some("probe"));

    control.end();
    let _ = std::fs::remove_file(socket_path);
}

/// Whether any process still holds a descriptor of the other end of
/// `socket`: macOS answers the other end's pid until its last descriptor
/// closes. A shutdown alone does not change the answer.
#[cfg(target_os = "macos")]
fn other_end_open(socket: &std::os::unix::net::UnixStream) -> bool {
    use std::os::fd::AsRawFd as _;
    let mut pid: libc::pid_t = 0;
    let mut len = size_of::<libc::pid_t>() as libc::socklen_t;
    // SAFETY: `socket` is open for this call; `pid` and `len` describe a
    // live buffer of the size that getsockopt may write.
    let status = unsafe {
        libc::getsockopt(
            socket.as_raw_fd(),
            libc::SOL_LOCAL,
            libc::LOCAL_PEERPID,
            (&raw mut pid).cast(),
            &raw mut len,
        )
    };
    status == 0
}

/// `end()` closes every relay descriptor of the control socket while the
/// handle lives on (the pty session keeps it): the daemon reads each
/// client in a blocking read, and on macOS that read can miss the wake of
/// the relay's shutdown while the relay keeps a descriptor, so the daemon
/// would keep a ghost client until the session ends.
#[cfg(target_os = "macos")]
#[tokio::test]
async fn ending_a_control_closes_its_socket_while_the_handle_lives_on() {
    let socket_path =
        std::env::temp_dir().join(format!("chatmux-relay-control-end-{}.sock", std::process::id()));
    let _ = std::fs::remove_file(&socket_path);
    let listener = UnixListener::bind(&socket_path).expect("bind control test socket");
    let control = connect_control(&socket_path, 3_000).await.expect("connect control test socket");
    let (daemon, _) = listener.accept().await.expect("accept control test socket");
    let daemon = daemon.into_std().expect("the daemon end as a std socket");

    control.end();

    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while other_end_open(&daemon) && std::time::Instant::now() < deadline {
        tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    }
    assert!(!other_end_open(&daemon), "the ended control's socket is still open in the relay");
    drop(control);
    let _ = std::fs::remove_file(socket_path);
}
