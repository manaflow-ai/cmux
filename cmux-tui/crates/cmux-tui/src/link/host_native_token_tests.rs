//! The actual inbound service path consumes backend-signed tokens and stamps their signed time.
use super::*;
use cmux_link::token::DenyAllTokens;
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};

fn receiver() -> Box<dyn TokenVerifier> {
    Box::new(DenyAllTokens)
}

#[tokio::test]
async fn native_token_receiver_daemon_stamps_backend_identity_and_signed_time() {
    let f: Value =
        serde_json::from_str(include_str!("../../../../../../schemas/link-token/native.json"))
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
    let source = std::net::SocketAddr::new(
        std::net::IpAddr::V6(overlay_address(f["claims"]["sub"].as_str().unwrap())),
        40000,
    );
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
        assert_eq!(stamp["check"], "link_token");
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
        serde_json::from_str(include_str!("../../../../../../schemas/link-token/native.json"))
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
    let source = std::net::SocketAddr::new(
        std::net::IpAddr::V6(overlay_address(f["claims"]["sub"].as_str().unwrap())),
        40000,
    );
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
