//! A peer waiting to send its hello is already an open receiving connection.
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::Duration;

use cmux_link::keyset::Keyset;
use tokio::io::{AsyncReadExt, AsyncWriteExt, ReadBuf};

use super::native_token_tests::owned_receiver;
use super::*;

pub(super) struct Observed {
    pub(super) stream: tokio::io::DuplexStream,
    pub(super) first_read: Option<tokio::sync::oneshot::Sender<()>>,
}
impl AsyncRead for Observed {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        if let Some(send) = self.first_read.take() {
            let _ = send.send(());
        }
        Pin::new(&mut self.stream).poll_read(cx, buf)
    }
}
impl AsyncWrite for Observed {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        bytes: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        Pin::new(&mut self.stream).poll_write(cx, bytes)
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.stream).poll_flush(cx)
    }
    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.stream).poll_shutdown(cx)
    }
}

async fn pending_hello(case: &str) {
    let verifier = Arc::new(owned_receiver(if case == "expiry" { 500 } else { 30_000 }));
    let directory = cmux_unix_socket::short_test_dir("receiver-hello");
    let session = directory.path().join("s.sock");
    let me = HostIdentity {
        host: "host_00000000000000000002",
        epoch: 4,
        session_socket: &session,
        sshd: "127.0.0.1:1".parse().unwrap(),
    };
    let (mut client, stream) = tokio::io::duplex(65536);
    // A partial frame must be covered too; it is not a token admission.
    client.write_all(b"{\"service\":").await.unwrap();
    let (send, observed) = tokio::sync::oneshot::channel();
    let stream = Observed { stream, first_read: Some(send) };
    let source = SocketAddr::new(IpAddr::V6(overlay_address("inst_00000000000000000001")), 40000);
    let serve = serve_host_inbound(stream, [b'a'; 32], source, &*verifier, &me);
    let check = async {
        observed.await.unwrap();
        match case {
            "clear" => verifier.clear_authority(),
            "keys" => verifier
                .replace_keys(Keyset {
                    version: "0000000000000002".into(),
                    keys: [("replacement".into(), [7; 32])].into(),
                })
                .unwrap(),
            "expiry" => {}
            _ => unreachable!(),
        }
        let mut byte = [0];
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(2), client.read(&mut byte))
                .await
                .expect("the receiver retained a revoked or expired pre-auth connection")
                .unwrap(),
            0
        );
    };
    let (result, ()) = tokio::join!(serve, check);
    assert!(result.is_err());
}

#[tokio::test]
async fn receiver_handshake_partial_hello_closes_on_authority_invalidation() {
    pending_hello("clear").await;
}
#[tokio::test]
async fn receiver_handshake_partial_hello_closes_on_signing_key_change() {
    pending_hello("keys").await;
}
#[tokio::test]
async fn receiver_handshake_partial_hello_closes_at_policy_expiry() {
    pending_hello("expiry").await;
}

#[tokio::test]
async fn receiver_handshake_unsigned_complete_hello_still_fails() {
    let verifier = owned_receiver(30_000);
    let directory = cmux_unix_socket::short_test_dir("receiver-no-jws");
    let session = directory.path().join("s.sock");
    let me = HostIdentity {
        host: "host_00000000000000000002",
        epoch: 4,
        session_socket: &session,
        sshd: "127.0.0.1:1".parse().unwrap(),
    };
    let (mut client, stream) = tokio::io::duplex(65536);
    client.write_all(b"{\"service\":\"ssh\",\"epoch\":4}\n").await.unwrap();
    let source = SocketAddr::new(IpAddr::V6(overlay_address("inst_00000000000000000001")), 40000);
    assert_eq!(
        serve_host_inbound(stream, [b'a'; 32], source, &verifier, &me).await,
        Err(HostRefused::Token)
    );
}

#[tokio::test]
async fn receiver_handshake_repeated_failures_release_slots_before_signed_ssh_copy() {
    let fixture: serde_json::Value =
        serde_json::from_str(include_str!("../../../../../schemas/link-token/native.json"))
            .unwrap();
    let verifier = owned_receiver(30_000);
    let directory = cmux_unix_socket::short_test_dir("receiver-jws");
    let session = directory.path().join("s.sock");
    let sshd = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let me = HostIdentity {
        host: "host_00000000000000000002",
        epoch: 4,
        session_socket: &session,
        sshd: sshd.local_addr().unwrap(),
    };
    let source = SocketAddr::new(IpAddr::V6(overlay_address("inst_00000000000000000001")), 40000);
    // More than the verifier's simultaneous-stream capacity, within one policy
    // lease: failed hellos must not prevent a later authenticated connection.
    for attempt in 0..5_000 {
        let (line, expected) = match attempt % 3 {
            0 => ("not-json\n", HostRefused::Inbound(InboundRefused::BadHello)),
            1 => ("{\"service\":\"ssh\",\"epoch\":4}\n", HostRefused::Token),
            _ => (
                "{\"service\":\"ssh\",\"epoch\":4,\"link_token\":\"invalid\"}\n",
                HostRefused::Token,
            ),
        };
        let (mut client, stream) = tokio::io::duplex(1024);
        client.write_all(line.as_bytes()).await.unwrap();
        assert_eq!(
            serve_host_inbound(stream, [b'a'; 32], source, &verifier, &me).await,
            Err(expected),
            "handshake {attempt} retained a reservation or changed refusal behavior"
        );
    }
    let (mut client, stream) = tokio::io::duplex(65536);
    client
        .write_all(
            format!(
                "{}\nping",
                serde_json::json!({"service":"ssh","epoch":4,"link_token":fixture["token"]})
            )
            .as_bytes(),
        )
        .await
        .unwrap();
    let serve = serve_host_inbound(stream, [b'a'; 32], source, &verifier, &me);
    let check = async {
        let (mut ssh, _) = sshd.accept().await.unwrap();
        let mut bytes = [0; 4];
        ssh.read_exact(&mut bytes).await.unwrap();
        assert_eq!(&bytes, b"ping");
        ssh.write_all(b"pong").await.unwrap();
        client.read_exact(&mut bytes).await.unwrap();
        assert_eq!(&bytes, b"pong");
        drop(client);
    };
    let (result, ()) =
        tokio::time::timeout(Duration::from_secs(3), async { tokio::join!(serve, check) })
            .await
            .unwrap();
    assert_eq!(result, Ok(()));
}
