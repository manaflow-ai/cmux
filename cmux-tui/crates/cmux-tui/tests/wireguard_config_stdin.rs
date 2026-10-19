#![cfg(unix)]

use std::io::Write;
use std::process::{Command, Stdio};

#[test]
fn wg_hub_stdin_config_reaches_the_parser_without_a_secret_file() {
    let directory = tempfile::tempdir().unwrap();
    let marker = "private-material-must-never-appear-in-errors";
    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["wg", "hub", "--config", "-", "--socket"])
        .arg(directory.path().join("hub.sock"))
        .env("LANG", "en_US.UTF-8")
        .env("LC_ALL", "en_US.UTF-8")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(format!("[Interface]\nPrivateKey = {marker}\n").as_bytes())
        .unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(!output.status.success());
    let error = String::from_utf8_lossy(&output.stderr);
    assert!(
        error.contains("not a valid wg-quick file"),
        "stdin must reach the config parser: {error}"
    );
    assert!(!error.contains(marker));
    assert!(output.stdout.is_empty());
    assert!(!directory.path().join("hub.sock").exists());
}

#[tokio::test]
async fn wg_hub_stdin_config_connects_through_a_real_loopback_tunnel() {
    use base64::Engine;
    use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
    use tokio::net::UnixStream;
    use tokio::time::{Duration, timeout};

    let pair = cmux_wg::testing::loopback_pair().await.unwrap();
    let config = format!(
        "[Interface]\nPrivateKey = {}\nAddress = {}/32\nMTU = 1200\n[Peer]\nPublicKey = {}\nAllowedIPs = 10.200.0.0/24\nEndpoint = {}\nPersistentKeepalive = 5\n",
        base64::engine::general_purpose::STANDARD.encode(*pair.client.private_key),
        pair.client_v4,
        base64::engine::general_purpose::STANDARD.encode(pair.client.peer_public_key),
        pair.client.endpoint.as_ref().unwrap(),
    );
    let server = cmux_wg::WgNet::start(pair.server, pair.server_socket).await.unwrap();
    let mut listener = server.listen(31337).await.unwrap();
    let directory = tempfile::tempdir().unwrap();
    let socket = directory.path().join("hub.sock");
    let mut child = tokio::process::Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["wg", "hub", "--config", "-", "--socket"])
        .arg(&socket)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    input.write_all(config.as_bytes()).await.unwrap();
    drop(input);
    let mut ready = String::new();
    timeout(
        Duration::from_secs(15),
        BufReader::new(child.stdout.take().unwrap()).read_line(&mut ready),
    )
    .await
    .unwrap()
    .unwrap();
    let ready: serde_json::Value =
        serde_json::from_str(&ready).expect("hub must become ready from stdin");
    assert_eq!(ready["event"], "hub-ready");
    assert_eq!(ready["socket"], socket.to_string_lossy().as_ref());
    let mut dial = UnixStream::connect(&socket).await.unwrap();
    dial.write_all(&[5, 1, 0]).await.unwrap();
    let mut method = [0; 2];
    dial.read_exact(&mut method).await.unwrap();
    assert_eq!(method, [5, 0]);
    let port = 31337_u16.to_be_bytes();
    dial.write_all(&[5, 1, 0, 1, 10, 200, 0, 2, port[0], port[1]]).await.unwrap();
    let mut reply = [0; 10];
    timeout(Duration::from_secs(5), dial.read_exact(&mut reply)).await.unwrap().unwrap();
    assert_eq!(reply[1], 0, "the configured route must remain dialable");
    let mut accepted = timeout(Duration::from_secs(5), listener.accept()).await.unwrap().unwrap();
    dial.write_all(b"hello").await.unwrap();
    let mut payload = [0; 5];
    timeout(Duration::from_secs(5), accepted.read_exact(&mut payload)).await.unwrap().unwrap();
    assert_eq!(&payload, b"hello");
    // Only this test-owned helper is terminated; its normal shutdown removes its socket.
    unsafe {
        libc::kill(child.id().unwrap() as i32, libc::SIGTERM);
    }
    assert!(timeout(Duration::from_secs(5), child.wait()).await.unwrap().unwrap().success());
    assert!(!socket.exists());
    // The stable lock inode is intentionally retained across socket owners.
    // It is the only file allowed here and must contain no configuration.
    let files: Vec<_> =
        std::fs::read_dir(directory.path()).unwrap().map(|entry| entry.unwrap().path()).collect();
    let lock = directory.path().join("hub.sock.lock");
    assert_eq!(files, vec![lock.clone()]);
    assert!(std::fs::read(lock).unwrap().is_empty());
}
