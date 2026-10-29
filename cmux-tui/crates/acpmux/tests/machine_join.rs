//! The installer's process contract: the secret is stdin-only, retries do not
//! redeem twice, and doctor never replaces the relay's session announcements.
#![cfg(unix)]

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::process::Stdio;
use std::time::Duration;
use tokio::io::AsyncWriteExt;
use tokio::process::Command;

const TOKEN: &str = "cmj_test_secret_never_print";
const CREDENTIAL: &str = "cmm_test_secret_never_print";

fn cli(home: &std::path::Path) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_acpmux"));
    command
        .env("ACPMUX_HOME", home)
        .env_remove("CMUX_JOIN")
        .env_remove("CMUX_PLATFORM_ORIGIN")
        .env_remove("ACPMUX_SOCKET")
        .env_remove("ACPMUX_DAEMON")
        .kill_on_drop(true)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    command
}

fn response_server(
    status: u16,
    respond: impl FnOnce(&str, &Value) -> Value + Send + 'static,
) -> (String, std::thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let thread = std::thread::spawn(move || {
        let (mut socket, _) = listener.accept().unwrap();
        socket.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let mut reader = BufReader::new(socket.try_clone().unwrap());
        let mut request = String::new();
        reader.read_line(&mut request).unwrap();
        assert!(!request.contains(TOKEN) && !request.contains(CREDENTIAL));
        let mut length = 0usize;
        loop {
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            if line == "\r\n" {
                break;
            }
            if let Some(value) = line.to_lowercase().strip_prefix("content-length:") {
                length = value.trim().parse().unwrap();
            }
        }
        let mut bytes = vec![0; length];
        reader.read_exact(&mut bytes).unwrap();
        let body =
            if bytes.is_empty() { Value::Null } else { serde_json::from_slice(&bytes).unwrap() };
        let response = respond(&request, &body).to_string();
        write!(socket, "HTTP/1.1 {status} response\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{response}", response.len()).unwrap();
    });
    (origin, thread)
}

#[tokio::test]
async fn join_redeems_once_and_rerun_repairs_config_without_reading_stdin() {
    let home = tempfile::tempdir().unwrap();
    std::fs::set_permissions(home.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
    let (origin, server) = response_server(200, |request, body| {
        assert!(request.starts_with("POST /v1/machines/join-tokens/redeem "));
        assert_eq!(body["token"], TOKEN);
        json!({"credential": CREDENTIAL, "machineId":"machine_test", "teamId":"team_test", "wgPublicKey":body["wgPublicKey"]})
    });
    let mut first = cli(home.path())
        .args(["host", "join", "--hub", &origin, "--name", "test", "--json"])
        .stdin(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = first.stdin.take().unwrap();
    input.write_all(format!("{TOKEN}\n").as_bytes()).await.unwrap();
    drop(input);
    let result = tokio::time::timeout(Duration::from_secs(10), first.wait_with_output())
        .await
        .unwrap()
        .unwrap();
    assert!(result.status.success(), "{}", String::from_utf8_lossy(&result.stderr));
    assert!(!String::from_utf8_lossy(&result.stdout).contains(TOKEN));
    assert!(!String::from_utf8_lossy(&result.stderr).contains(CREDENTIAL));
    server.join().unwrap();
    let credential = home.path().join("machine-credential.json");
    assert_eq!(std::fs::metadata(credential).unwrap().mode() & 0o777, 0o600);
    // Simulate config.save failing after the credential commit. The retry must
    // repair it, and return while stdin remains open with no bytes available.
    std::fs::remove_file(home.path().join("config.json")).unwrap();
    let mut second =
        cli(home.path()).args(["host", "join", "--json"]).stdin(Stdio::piped()).spawn().unwrap();
    let _still_open = second.stdin.take().unwrap();
    let result = tokio::time::timeout(Duration::from_secs(5), second.wait_with_output())
        .await
        .unwrap()
        .unwrap();
    assert!(result.status.success(), "{}", String::from_utf8_lossy(&result.stderr));
    let body: Value = serde_json::from_slice(&result.stdout).unwrap();
    assert_eq!(body["alreadyJoined"], true);
    let config: Value =
        serde_json::from_slice(&std::fs::read(home.path().join("config.json")).unwrap()).unwrap();
    assert_eq!(config["meshRelay"]["credential"], "join");
    assert_eq!(config["meshRelay"]["url"], origin);
    assert_ne!(config["transport"]["wireguard"], true);
}

#[tokio::test]
async fn status_is_read_only_and_persists_revocation() {
    let home = tempfile::tempdir().unwrap();
    let (origin, server) = response_server(401, |request, body| {
        assert!(request.starts_with("GET /v1/mesh/sessions "));
        assert_eq!(*body, Value::Null);
        json!({"code":"machine.revoked"})
    });
    let path = home.path().join("machine-credential.json");
    std::fs::write(&path, json!({"credential":CREDENTIAL,"machine_id":"machine_test","team_id":"team_test","name":"test","hub_origin":origin,"last_heartbeat":"1234","revoked":false,"wgPublicKey":"key"}).to_string()).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    let result = tokio::time::timeout(
        Duration::from_secs(10),
        cli(home.path()).args(["host", "join", "--status", "--json"]).output(),
    )
    .await
    .unwrap()
    .unwrap();
    assert!(result.status.success(), "{}", String::from_utf8_lossy(&result.stderr));
    let body: Value = serde_json::from_slice(&result.stdout).unwrap();
    assert_eq!(body["revoked"], true);
    assert_eq!(body["lastHeartbeat"], "1234");
    assert_eq!(body["daemonRunning"], false);
    let stored: Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    assert_eq!(stored["revoked"], true);
    server.join().unwrap();
}

#[tokio::test]
async fn cloud_argv_is_refused_even_with_status_and_hub() {
    let home = tempfile::tempdir().unwrap();
    for flags in [vec!["--status"], vec!["--hub", "https://example.com"], vec!["--replace"], vec![]]
    {
        let result =
            cli(home.path()).args(["host", "join", TOKEN]).args(flags).output().await.unwrap();
        assert_eq!(result.status.code(), Some(2));
        assert!(!String::from_utf8_lossy(&result.stderr).contains(TOKEN));
        assert!(!String::from_utf8_lossy(&result.stdout).contains(TOKEN));
    }
}

#[tokio::test]
async fn joined_machine_still_reads_legacy_ticket_from_stdin() {
    let home = tempfile::tempdir().unwrap();
    let path = home.path().join("machine-credential.json");
    std::fs::write(&path, json!({"credential":CREDENTIAL,"machine_id":"machine_test","team_id":"team_test","name":"test","hub_origin":"https://example.com","last_heartbeat":null,"revoked":false,"wgPublicKey":"key"}).to_string()).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    let ticket = acpmux::pairing::Ticket {
        url: "wss://example.com/acp".to_owned(),
        minter: "minter".to_owned(),
        role: acpmux::pairing::Role::Client,
        expires_ms: acpmux::store::now_ms() - 1000,
        secret: "ab".repeat(32),
    }
    .encode();
    let mut child = cli(home.path()).args(["host", "join"]).stdin(Stdio::piped()).spawn().unwrap();
    let mut input = child.stdin.take().unwrap();
    input.write_all(ticket.as_bytes()).await.unwrap();
    drop(input);
    let result = tokio::time::timeout(Duration::from_secs(8), child.wait_with_output())
        .await
        .unwrap()
        .unwrap();
    assert!(!result.status.success());
    assert!(String::from_utf8_lossy(&result.stderr).contains("this ticket expired"));
}

#[tokio::test]
async fn unfinished_pipe_cannot_hold_the_join_lock_forever() {
    let home = tempfile::tempdir().unwrap();
    let mut child = cli(home.path()).args(["host", "join"]).stdin(Stdio::piped()).spawn().unwrap();
    let mut input = child.stdin.take().unwrap();
    input.write_all(b"cmj_incomplete").await.unwrap();
    let result = tokio::time::timeout(Duration::from_secs(8), child.wait_with_output())
        .await
        .expect("join stdin must have a fixed deadline")
        .unwrap();
    assert_eq!(result.status.code(), Some(2));
    assert!(!String::from_utf8_lossy(&result.stderr).contains("cmj_incomplete"));
}

#[tokio::test]
async fn credential_write_failure_after_redeem_requires_a_fresh_token_without_secrets() {
    let home = tempfile::tempdir().unwrap();
    let target = home.path().join("machine-credential.json");
    let (origin, server) = response_server(200, move |_, body| {
        // Fail the actual credential commit only after the one-shot redeem.
        std::fs::create_dir(&target).unwrap();
        json!({"credential": CREDENTIAL, "machineId":"machine_test", "teamId":"team_test", "wgPublicKey":body["wgPublicKey"]})
    });
    let mut child = cli(home.path())
        .args(["host", "join", "--hub", &origin])
        .stdin(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    input.write_all(format!("{TOKEN}\n").as_bytes()).await.unwrap();
    drop(input);
    let result = child.wait_with_output().await.unwrap();
    server.join().unwrap();
    assert_eq!(result.status.code(), Some(5));
    let error = String::from_utf8_lossy(&result.stderr);
    assert!(error.contains("join token was used"), "{error}");
    assert!(error.contains("fix local storage"), "{error}");
    assert!(error.contains("revoke this machine in the machine list"), "{error}");
    assert!(error.contains("machine add again for a fresh token"), "{error}");
    for text in [&result.stderr, &result.stdout] {
        let text = String::from_utf8_lossy(text);
        assert!(!text.contains(TOKEN) && !text.contains(CREDENTIAL));
    }
}
