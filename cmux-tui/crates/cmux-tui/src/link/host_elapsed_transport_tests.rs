//! Advance elapsed time with active uptime frozen, then make an actual stream
//! ready. The independent service task must refuse bytes before copying them.
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_link::elapsed::Elapsed;
use cmux_link::native_token::{ReceiverTime, receiver::Owner};
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};

use super::handshake_lifetime_tests::Observed;
use super::native_token_tests::owned_policy;
use super::*;

type ClockValue = Arc<Mutex<Option<Duration>>>;

fn owner() -> (Owner, ClockValue) {
    let active = Instant::now();
    let value = Arc::new(Mutex::new(Some(Duration::from_secs(10))));
    let clock = value.clone();
    let elapsed = Elapsed::capture(move || *clock.lock().unwrap()).unwrap();
    let (keys, policy) = owned_policy(30_000, active);
    let owner = Owner::with_elapsed_clock(keys.clone(), move || Some(active), elapsed).unwrap();
    owner
        .install(
            owner.begin().unwrap(),
            keys,
            policy,
            ReceiverTime { unix_ms: 1_792_000_010_000, monotonic: active },
        )
        .unwrap();
    (owner, value)
}

fn address() -> SocketAddr {
    SocketAddr::new(IpAddr::V6(overlay_address("inst_00000000000000000001")), 40000)
}

async fn ssh(outgoing: bool) {
    let (owner, clock) = owner();
    let verifier = owner.verifier();
    let sshd = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let target = sshd.local_addr().unwrap();
    let directory = cmux_unix_socket::short_test_dir("elapsed-ssh");
    let session = directory.path().join("s.sock");
    let (mut caller, inbound) = tokio::io::duplex(65536);
    let fixture: Value =
        serde_json::from_str(include_str!("../../../../../schemas/link-token/native.json"))
            .unwrap();
    caller
        .write_all(
            format!("{}\nping", json!({"service":"ssh","epoch":4,"link_token":fixture["token"]}))
                .as_bytes(),
        )
        .await
        .unwrap();
    let serving = tokio::spawn(async move {
        let me = HostIdentity {
            host: "host_00000000000000000002",
            epoch: 4,
            session_socket: &session,
            sshd: target,
        };
        serve_host_inbound(inbound, [b'a'; 32], address(), &*verifier, &me).await
    });
    let (mut server, _) =
        tokio::time::timeout(Duration::from_secs(3), sshd.accept()).await.unwrap().unwrap();
    let mut bytes = [0; 4];
    server.read_exact(&mut bytes).await.unwrap();
    assert_eq!(&bytes, b"ping");
    server.write_all(b"pong").await.unwrap();
    caller.read_exact(&mut bytes).await.unwrap();
    assert_eq!(&bytes, b"pong", "both copy directions must be live before expiry");
    *clock.lock().unwrap() = Some(Duration::from_secs(40));
    let read = if outgoing {
        server.write_all(b"late").await.unwrap();
        tokio::time::timeout(Duration::from_secs(3), caller.read(&mut bytes)).await
    } else {
        caller.write_all(b"late").await.unwrap();
        tokio::time::timeout(Duration::from_secs(3), server.read(&mut bytes)).await
    };
    let received = read.expect("expired service task did not close").unwrap();
    if received != 0 {
        serving.abort();
        let _ = serving.await;
        assert_eq!(received, 0, "expired authority copied post-suspend bytes");
        return;
    }
    assert_eq!(
        tokio::time::timeout(Duration::from_secs(3), serving).await.unwrap().unwrap(),
        Err(HostRefused::Authority)
    );
    assert!(owner.verifier().begin_handshake("host_00000000000000000002", 4, &[b'a'; 32]).is_err());
}

#[tokio::test]
async fn receiver_elapsed_transport_refuses_late_bytes_toward_sshd() {
    tokio::time::timeout(Duration::from_secs(10), ssh(false)).await.unwrap();
}

#[tokio::test]
async fn receiver_elapsed_transport_refuses_late_bytes_toward_the_caller() {
    tokio::time::timeout(Duration::from_secs(10), ssh(true)).await.unwrap();
}

#[tokio::test]
async fn receiver_elapsed_transport_partial_hello_expires_before_parsing_ready_input() {
    let (owner, clock) = owner();
    let verifier = owner.verifier();
    let directory = cmux_unix_socket::short_test_dir("elapsed-hello");
    let session = directory.path().join("s.sock");
    let (mut caller, stream) = tokio::io::duplex(65536);
    caller.write_all(b"{\"service\":").await.unwrap();
    let (first_read, observed) = tokio::sync::oneshot::channel();
    let inbound = Observed { stream, first_read: Some(first_read) };
    let serving = tokio::spawn(async move {
        let me = HostIdentity {
            host: "host_00000000000000000002",
            epoch: 4,
            session_socket: &session,
            sshd: "127.0.0.1:1".parse().unwrap(),
        };
        serve_host_inbound(inbound, [b'a'; 32], address(), &*verifier, &me).await
    });
    tokio::time::timeout(Duration::from_secs(3), observed).await.unwrap().unwrap();
    *clock.lock().unwrap() = Some(Duration::from_secs(40));
    caller.write_all(b"\"ssh\"}\n").await.unwrap();
    let result = tokio::time::timeout(Duration::from_secs(3), serving).await.unwrap().unwrap();
    assert_eq!(
        result,
        Err(HostRefused::Authority),
        "input was parsed after its pre-auth budget ended"
    );
    let mut bytes = [0];
    assert_eq!(caller.read(&mut bytes).await.unwrap(), 0);
    drop(owner);
}
