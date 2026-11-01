//! The actual inbound service path consumes backend-signed tokens and stamps their signed time.
use super::*;
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};

fn receiver() -> Box<dyn TokenVerifier> {
    Box::new(owned_receiver(30_000))
}

pub(super) fn owned_receiver(lease_ms: u64) -> cmux_link::native_token::NativeTokenVerifier {
    use cmux_link::native_token::*;
    let now = ReceiverTime { unix_ms: 1_792_000_010_000, monotonic: std::time::Instant::now() };
    let (keys, policy) = owned_policy(lease_ms, now.monotonic);
    let verifier = NativeTokenVerifier::new(keys, move || Some(now), 16).unwrap();
    verifier.replace_authority(policy).unwrap();
    verifier
}

pub(super) fn owned_policy(
    lease_ms: u64,
    active: std::time::Instant,
) -> (cmux_link::keyset::Keyset, cmux_link::native_token::NativePolicy) {
    use cmux_link::native_token::*;
    let f: Value =
        serde_json::from_str(include_str!("../../../../../schemas/link-token/native.json"))
            .unwrap();
    let now = ReceiverTime { unix_ms: 1_792_000_010_000, monotonic: active };
    let keys = cmux_link::keyset::Keyset {
        version: "0000000000000001".into(),
        keys: [(
            f["kid"].as_str().unwrap().into(),
            URL_SAFE_NO_PAD.decode(f["public_key"].as_str().unwrap()).unwrap().try_into().unwrap(),
        )]
        .into(),
    };
    (
        keys,
        NativePolicy {
            issuer: f["claims"]["iss"].as_str().unwrap().into(),
            host: f["claims"]["aud"].as_str().unwrap().into(),
            epoch: 4,
            team: f["claims"]["team"].as_str().unwrap().into(),
            authority_version: "c".repeat(64),
            checked_at_ms: now.unix_ms,
            expires_at_ms: now.unix_ms + lease_ms,
            request_started: now.monotonic,
            peers: vec![NativePeer {
                install: f["claims"]["sub"].as_str().unwrap().into(),
                binding: serde_json::from_value(f["claims"]["network"].clone()).unwrap(),
                services: vec![Service::Daemon, Service::Ssh],
            }],
        },
    )
}

#[tokio::test]
async fn native_token_receiver_inbound_refuses_another_key_address_or_host_epoch() {
    let f: Value =
        serde_json::from_str(include_str!("../../../../../schemas/link-token/native.json"))
            .unwrap();
    let directory = cmux_unix_socket::short_test_dir("nativejwtdeny");
    let session = directory.path().join("s.sock");
    for case in ["key", "address", "host", "epoch"] {
        let (mut client, inbound) = tokio::io::duplex(16 * 1024);
        client
            .write_all(
                format!(
                    "{}\n",
                    serde_json::json!({"service":"daemon", "epoch":4, "link_token":f["token"]})
                )
                .as_bytes(),
            )
            .await
            .unwrap();
        let me = HostIdentity {
            host: if case == "host" {
                "host_00000000000000000003"
            } else {
                f["claims"]["aud"].as_str().unwrap()
            },
            epoch: if case == "epoch" { 5 } else { 4 },
            session_socket: &session,
            sshd: "127.0.0.1:1".parse().unwrap(),
        };
        let install = if case == "address" {
            "inst_00000000000000000003"
        } else {
            f["claims"]["sub"].as_str().unwrap()
        };
        let source = SocketAddr::new(IpAddr::V6(overlay_address(install)), 40000);
        let key = if case == "key" { [5; 32] } else { [b'a'; 32] };
        let verifier = receiver();
        let result = serve_host_inbound(inbound, key, source, &*verifier, &me).await;
        let expected = match case {
            "address" => HostRefused::AddressMismatch,
            // The receiver's own host/epoch pin is now checked before reading
            // the hello, so a mismatched policy cannot start a handshake.
            "epoch" => HostRefused::Token,
            _ => HostRefused::Token,
        };
        assert_eq!(result, Err(expected), "{case}");
    }
}

#[tokio::test]
async fn native_token_receiver_daemon_stamps_backend_identity_and_signed_time() {
    let f: Value =
        serde_json::from_str(include_str!("../../../../../schemas/link-token/native.json"))
            .unwrap();
    let directory = cmux_unix_socket::short_test_dir("nativejwt");
    let session = directory.path().join("s.sock");
    let path = cmux_link::entry_path::remote_entry_socket_path(&session);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let entry = tokio::net::UnixListener::bind(path).unwrap();
    let (mut client, inbound) = tokio::io::duplex(16 * 1024);
    client
        .write_all(
            format!(
                "{}\n",
                serde_json::json!({"service":"daemon", "epoch":4, "link_token":f["token"]})
            )
            .as_bytes(),
        )
        .await
        .unwrap();
    let me = HostIdentity {
        host: f["claims"]["aud"].as_str().unwrap(),
        epoch: 4,
        session_socket: &session,
        sshd: "127.0.0.1:1".parse().unwrap(),
    };
    let verifier = receiver();
    let source =
        SocketAddr::new(IpAddr::V6(overlay_address(f["claims"]["sub"].as_str().unwrap())), 40000);
    let serve = async {
        serve_host_inbound(inbound, [b'a'; 32], source, &*verifier, &me)
            .await
            .map_err(|e| format!("receiver refused: {e:?}"))
    };
    let check = async {
        let (mut stream, _) = entry.accept().await.unwrap();
        stream.write_all(b"{\"remote_entry\":1}\n").await.unwrap();
        let mut line = String::new();
        BufReader::new(&mut stream).read_line(&mut line).await.unwrap();
        let stamp: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(stamp["link_peer"]["install"], f["claims"]["sub"]);
        assert_eq!(stamp["link_peer"]["user"], f["claims"]["network"]["user"]);
        assert_eq!(stamp["link_peer"]["team"], f["claims"]["team"]);
        assert_eq!(stamp["check"], "native_link_token");
        assert!(stamp.get("native_vm_kind").is_none());
        assert_eq!(stamp["check_issued_at_ms"], 1_792_000_000_000u64);
        drop(client);
        Ok::<_, String>(())
    };
    tokio::time::timeout(std::time::Duration::from_secs(5), async {
        tokio::try_join!(serve, check)
    })
    .await
    .expect("inbound must finish")
    .expect("signed token must reach daemon entry");
}

#[tokio::test]
async fn native_token_receiver_ssh_reaches_only_the_loopback_service() {
    let f: Value =
        serde_json::from_str(include_str!("../../../../../schemas/link-token/native.json"))
            .unwrap();
    let sshd = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let directory = cmux_unix_socket::short_test_dir("nativejwtssh");
    let session = directory.path().join("s.sock");
    let me = HostIdentity {
        host: f["claims"]["aud"].as_str().unwrap(),
        epoch: 4,
        session_socket: &session,
        sshd: sshd.local_addr().unwrap(),
    };
    let (mut client, inbound) = tokio::io::duplex(16 * 1024);
    client
        .write_all(
            format!(
                "{}\nSSH-2.0-client\n",
                serde_json::json!({"service":"ssh", "epoch":4, "link_token":f["token"]})
            )
            .as_bytes(),
        )
        .await
        .unwrap();
    let verifier = receiver();
    let source =
        SocketAddr::new(IpAddr::V6(overlay_address(f["claims"]["sub"].as_str().unwrap())), 40000);
    let serve = async {
        serve_host_inbound(inbound, [b'a'; 32], source, &*verifier, &me)
            .await
            .map_err(|e| format!("receiver refused: {e:?}"))
    };
    let check = async {
        let (stream, _) = sshd.accept().await.unwrap();
        let mut stream = BufReader::new(stream);
        let mut line = String::new();
        stream.read_line(&mut line).await.unwrap();
        assert_eq!(line, "SSH-2.0-client\n");
        stream.get_mut().write_all(b"SSH-2.0-server\n").await.unwrap();
        let mut reply = [0; 15];
        client.read_exact(&mut reply).await.unwrap();
        assert_eq!(&reply, b"SSH-2.0-server\n");
        drop(client);
        Ok::<_, String>(())
    };
    tokio::time::timeout(std::time::Duration::from_secs(5), async {
        tokio::try_join!(serve, check)
    })
    .await
    .expect("inbound must finish")
    .expect("signed token must reach sshd");
}
