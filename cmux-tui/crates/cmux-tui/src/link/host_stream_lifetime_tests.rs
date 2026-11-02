//! An accepted token must not leave a live tunnel behind after its authority
//! disappears. Exercise the actual SSH copy and daemon handoff, not just verify().
use std::time::Duration;

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use cmux_link::keyset::Keyset;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};

use super::native_token_tests::owned_receiver;
use super::*;

fn fixture() -> Value {
    serde_json::from_str(include_str!("../../../../../schemas/link-token/native.json")).unwrap()
}

fn original_keys() -> Keyset {
    let f = fixture();
    Keyset {
        version: "0000000000000001".into(),
        keys: [(
            f["kid"].as_str().unwrap().into(),
            URL_SAFE_NO_PAD.decode(f["public_key"].as_str().unwrap()).unwrap().try_into().unwrap(),
        )]
        .into(),
    }
}

async fn ssh(case: &str) {
    let f = fixture();
    let verifier = owned_receiver(if case == "expiry" { 3000 } else { 30_000 });
    let sshd = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let directory = cmux_unix_socket::short_test_dir("stream-life");
    let session = directory.path().join("s.sock");
    let me = HostIdentity {
        host: f["claims"]["aud"].as_str().unwrap(),
        epoch: 4,
        session_socket: &session,
        sshd: sshd.local_addr().unwrap(),
    };
    let (mut caller, inbound) = tokio::io::duplex(65536);
    caller
        .write_all(
            format!("{}\nSSH-client\n", json!({"service":"ssh","epoch":4,"link_token":f["token"]}))
                .as_bytes(),
        )
        .await
        .unwrap();
    let source =
        SocketAddr::new(IpAddr::V6(overlay_address(f["claims"]["sub"].as_str().unwrap())), 40000);
    let serve = serve_host_inbound(inbound, [b'a'; 32], source, &verifier, &me);
    let check = async {
        let (stream, _) = sshd.accept().await.unwrap();
        let mut stream = BufReader::new(stream);
        let mut banner = String::new();
        stream.read_line(&mut banner).await.unwrap();
        assert_eq!(banner, "SSH-client\n", "the token must first establish a real stream");
        match case {
            "clear" => verifier.clear_authority(),
            "key_removed" => verifier
                .replace_keys(Keyset {
                    version: "0000000000000002".into(),
                    keys: [("replacement".into(), [7; 32])].into(),
                })
                .unwrap(),
            "same_keys" => {
                verifier.replace_keys(original_keys()).unwrap();
                stream.get_mut().write_all(b"still-live\n").await.unwrap();
                let mut bytes = [0u8; 11];
                caller.read_exact(&mut bytes).await.unwrap();
                assert_eq!(&bytes, b"still-live\n");
                drop(caller);
                return;
            }
            "expiry" => {}
            _ => unreachable!(),
        }
        let mut byte = [0u8; 1];
        let budget = if case == "expiry" { Duration::from_secs(4) } else { Duration::from_secs(1) };
        let closed = tokio::time::timeout(budget, caller.read(&mut byte))
            .await
            .expect("authority ended but the caller's SSH stream stayed open")
            .unwrap();
        assert_eq!(closed, 0, "unauthorized bytes reached the caller");
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(1), stream.read(&mut byte))
                .await
                .unwrap()
                .unwrap(),
            0,
            "sshd still has an authorized tunnel"
        );
    };
    let (result, ()) = tokio::join!(serve, check);
    if case == "same_keys" {
        assert_eq!(result, Ok(()));
    } else {
        assert!(result.is_err(), "the stream ended without an authority refusal");
    }
}

#[tokio::test]
async fn native_receiver_stream_ssh_closes_when_authority_is_cleared() {
    ssh("clear").await;
}
#[tokio::test]
async fn native_receiver_stream_ssh_closes_when_signing_key_is_removed() {
    ssh("key_removed").await;
}
#[tokio::test]
async fn native_receiver_stream_ssh_closes_at_policy_lease_expiry() {
    ssh("expiry").await;
}
#[tokio::test]
async fn native_receiver_stream_ssh_stays_open_when_keys_are_unchanged() {
    ssh("same_keys").await;
}

async fn daemon(readiness: bool) {
    let f = fixture();
    let verifier = owned_receiver(30_000);
    let directory = cmux_unix_socket::short_test_dir("stream-daemon");
    let session = directory.path().join("s.sock");
    let path = cmux_link::entry_path::remote_entry_socket_path(&session);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let entry = tokio::net::UnixListener::bind(&path).unwrap();
    let me = HostIdentity {
        host: f["claims"]["aud"].as_str().unwrap(),
        epoch: 4,
        session_socket: &session,
        sshd: "127.0.0.1:1".parse().unwrap(),
    };
    let (mut caller, inbound) = tokio::io::duplex(65536);
    caller
        .write_all(
            format!("{}\n", json!({"service":"daemon","epoch":4,"link_token":f["token"]}))
                .as_bytes(),
        )
        .await
        .unwrap();
    let source =
        SocketAddr::new(IpAddr::V6(overlay_address(f["claims"]["sub"].as_str().unwrap())), 40000);
    let serve = serve_host_inbound(inbound, [b'a'; 32], source, &verifier, &me);
    let check = async {
        let (stream, _) = entry.accept().await.unwrap();
        let mut stream = BufReader::new(stream);
        if readiness {
            stream.get_mut().write_all(b"{\"remote_entry\":1}\n").await.unwrap();
            let mut stamp = String::new();
            stream.read_line(&mut stamp).await.unwrap();
            assert!(
                stamp.contains("1792000000000"),
                "the original signed time must reach the daemon"
            );
        }
        verifier.clear_authority();
        let mut byte = [0u8; 1];
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(1), caller.read(&mut byte))
                .await
                .expect("revoked daemon handoff stayed open")
                .unwrap(),
            0
        );
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(1), stream.read(&mut byte))
                .await
                .unwrap()
                .unwrap(),
            0,
            "revoked handoff wrote a stamp or left the daemon connected"
        );
    };
    let (result, ()) = tokio::join!(serve, check);
    assert!(result.is_err());
}

#[tokio::test]
async fn native_receiver_stream_daemon_closes_when_authority_is_cleared() {
    daemon(true).await;
}
#[tokio::test]
async fn native_receiver_stream_daemon_cancels_before_entry_readiness() {
    daemon(false).await;
}
