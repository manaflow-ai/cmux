//! The `cmux link dial` contract: one JSON line on stderr for every outcome,
//! and a distinct exit code per failure.

use std::path::PathBuf;

use tokio::io::{AsyncReadExt, AsyncWriteExt};

use super::*;

fn args(list: &[&str]) -> Vec<String> {
    list.iter().map(|value| (*value).to_string()).collect()
}

#[tokio::test]
async fn a_refusal_from_the_link_keeps_its_code_and_a_success_names_the_path() {
    let directory = cmux_unix_socket::short_test_dir("dialcli");
    let path = directory.path().join("link.sock");
    let listener = tokio::net::UnixListener::bind(&path).unwrap();
    let replies = [
        "{\"ok\":false,\"path_state\":\"unreachable\",\"relay_available\":false,\"error_code\":\"host_paused\"}\n",
        "{\"relay_available\":false,\"ok\":true,\"path_state\":\"tunnel\"}\n",
    ];
    let server = tokio::spawn(async move {
        for reply in replies {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut request = [0u8; 256];
            let _ = stream.read(&mut request).await.unwrap();
            stream.write_all(reply.as_bytes()).await.unwrap();
        }
    });
    let refused = connect(&path, "host_a", Service::Ssh).await.unwrap_err();
    assert_eq!(refused.exit_code(), 4);
    let connected = connect(&path, "host_a", Service::Ssh).await.unwrap();
    let value: serde_json::Value = serde_json::from_str(&connected_line(&connected)).unwrap();
    assert_eq!(value["ok"], true);
    assert_eq!(value["path_state"], "tunnel");
    server.await.unwrap();
}

/// RED: `--socket` names exactly the link to dial: it must be absolute
/// (else bad usage, 64), must be a socket (else 64), and a missing path is
/// a link that is not running (link_unavailable, 6).
#[tokio::test]
async fn an_explicit_socket_is_dialed_exactly_and_checked() {
    assert_eq!(
        parse(&args(&["--host", "host_a", "--socket", "/tmp/l/link.sock"])).map(|dial| dial.socket),
        Ok(Some(PathBuf::from("/tmp/l/link.sock")))
    );
    assert_eq!(
        parse(&args(&["--host", "host_a", "--socket", "relative/link.sock"])),
        Err(Failure::BadUsage)
    );
    let directory = cmux_unix_socket::short_test_dir("dialsock");
    let file = directory.path().join("not-a-socket");
    std::fs::write(&file, b"x").unwrap();
    assert_eq!(chosen_socket(Some(&file)), Err(Failure::BadUsage));
    assert_eq!(Failure::BadUsage.exit_code(), 64);
    let missing = directory.path().join("gone.sock");
    assert_eq!(chosen_socket(Some(&missing)), Err(Failure::LinkUnavailable));
    // A link at a non-default socket answers the dial.
    let path = directory.path().join("tagged-link.sock");
    let listener = tokio::net::UnixListener::bind(&path).unwrap();
    let server = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        let mut request = [0u8; 256];
        let _ = stream.read(&mut request).await.unwrap();
        let reply = "{\"ok\":true,\"path_state\":\"direct\",\"relay_available\":false}\n";
        stream.write_all(reply.as_bytes()).await.unwrap();
    });
    let chosen = chosen_socket(Some(&path)).unwrap();
    assert_eq!(chosen, path);
    connect(&chosen, "host_a", Service::Daemon).await.unwrap();
    server.await.unwrap();
}
