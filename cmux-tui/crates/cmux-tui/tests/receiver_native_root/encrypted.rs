//! A signed request crosses the production root/daemon/receiver process chain.
use super::{Agent, Daemon, drive_until, frame, hosted_root, install_public_key, policy_reader};
use std::io::Write as _;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::time::Duration;

use base64::{
    Engine as _,
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
};
use cmux_host::cloud::{private_bootstrap::NativeBootstrap, receiver::ReceiverBinding};
use cmux_link::overlay_addr::overlay_address;
use cmux_link::root_bootstrap::{Host, StopReceipt};
use cmux_wg::{InterfaceAddress, IpNetwork, WgMesh, WgMeshConfig, WgPeer};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt as _, AsyncReadExt as _, AsyncWriteExt as _, BufReader};
use zeroize::Zeroizing;

fn now_ms() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as u64
}

fn vector() -> Value {
    serde_json::from_str(include_str!("../../../../../schemas/link-token/native.json")).unwrap()
}

fn token(public: [u8; 32], nonce: u8, generation: &str) -> String {
    // The signing seed is published contract-vector material, never a deployment key.
    let keys: Value =
        serde_json::from_str(include_str!("../../../../../schemas/link-token/vectors.json"))
            .unwrap();
    let seed = URL_SAFE_NO_PAD.decode(keys["test_keys"]["test-k1"]["d"].as_str().unwrap()).unwrap();
    let signer = ring::signature::Ed25519KeyPair::from_seed_unchecked(&seed).unwrap();
    let mut claims = vector()["claims"].clone();
    claims["iss"] = "cmux:cloud:development".into();
    let now = now_ms() / 1000;
    claims["iat"] = (now - 1).into();
    claims["exp"] = (now + 120).into();
    claims["jti"] = URL_SAFE_NO_PAD.encode([nonce; 16]).into();
    claims["receiver"] = json!({"version":2,"generation":generation});
    claims["network"]["wg_public_key"] = STANDARD.encode(public).into();
    let header = URL_SAFE_NO_PAD.encode(
        serde_json::to_vec(&json!({"alg":"EdDSA","typ":"cmux-native-link-v2+jwt","kid":"test-k1"}))
            .unwrap(),
    );
    let body = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&claims).unwrap());
    let signed = format!("{header}.{body}");
    format!("{signed}.{}", URL_SAFE_NO_PAD.encode(signer.sign(signed.as_bytes()).as_ref()))
}

fn public_reply(frame: &[u8], public: [u8; 32]) -> Vec<u8> {
    let bootstrap = NativeBootstrap::decode(frame).unwrap();
    let binding = bootstrap.binding();
    let header: Value = serde_json::from_slice(&frame[4..frame.len() - 32]).unwrap();
    let f = vector();
    let claims = &f["claims"];
    let network = &claims["network"];
    let checked = now_ms();
    let value = json!({"ok":true,"value":{
        "issuer":"cmux:cloud:development","issuer_time_ms":checked,"remaining_ms":30_000,
        "keyset":header["keyset"],
        "policy":{
            "schema_version":2,"receiver_generation":bootstrap.generation(),"machine":binding.machine,"host":binding.host,"epoch":binding.epoch,
            "user":binding.user,"install":binding.install,"team":binding.team,
            "origin":"https://native.example.com","tenant":network["tenant"],"mesh":network["mesh"],
            "vm":"vm_00000000000000000000000004","ipv4":"10.2.0.4",
            "wg_public_key":binding.wg_public_key,"install_public_key":binding.install_public_key,
            "authority_version":"c".repeat(64),"checked_at":checked,"expires_at":checked+30_000,
            "acl_version":network["acl_version"],"policy_digest":"b".repeat(64),
            "peers":[{"host":network["host"],"user":network["user"],"install":claims["sub"],
                "device":network["device"],"wg_public_key":STANDARD.encode(public),
                "install_public_key":install_public_key(),"authority_version":network["authority_version"],
                "services":["daemon","ssh"]}]
        }
    }});
    // Use the actual generated-policy decoder before offering this fixture.
    let bytes = serde_json::to_vec(&value).unwrap();
    let now = std::time::Instant::now();
    cmux_host::cloud::receiver::ReceiverSnapshot::from_public_reply(&bytes, binding, now, now)
        .unwrap();
    [bytes, b"\n".to_vec()].concat()
}

async fn within<T>(future: impl Future<Output = T>) -> T {
    tokio::time::timeout(Duration::from_secs(12), future)
        .await
        .expect("encrypted process chain completed")
}

async fn client_mesh(private: [u8; 32], binding: &ReceiverBinding) -> WgMesh {
    let f = vector();
    let install = f["claims"]["sub"].as_str().unwrap();
    let mesh = WgMesh::start(
        WgMeshConfig {
            private_key: Zeroizing::new(private),
            addresses: vec![InterfaceAddress {
                address: IpAddr::V6(overlay_address(install)),
                prefix: 128,
            }],
            mtu: 1280,
        },
        tokio::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap(),
    )
    .unwrap();
    let destination = overlay_address(&binding.host);
    mesh.add_peer(WgPeer {
        public_key: STANDARD.decode(&binding.wg_public_key).unwrap().try_into().unwrap(),
        preshared_key: None,
        allowed_ips: vec![IpNetwork::new(IpAddr::V6(destination), 128).unwrap()],
        route: Some(SocketAddr::from((Ipv4Addr::LOCALHOST, 4101)).into()),
        persistent_keepalive: None,
    })
    .await
    .unwrap();
    mesh
}

#[test]
#[ignore = "requires hosted Linux root; scripts/ci/verify-link-root-boundary.py"]
fn receiver_root_privileged_native_chain_carries_a_signed_encrypted_daemon_request() {
    hosted_root();
    let host = Host::new_native().unwrap();
    let agent = Agent::start();
    let daemon = Daemon::start(&host);
    let bytes = frame();
    let binding = NativeBootstrap::decode(&bytes).unwrap().binding().clone();
    let (private, public) = cmux_wg::testing::random_keypair();
    let source_frame = bytes.clone();
    let listener = agent.listener.try_clone().unwrap();
    let process = daemon.child.clone();
    let (reported, report) = std::sync::mpsc::sync_channel(1);
    let source = std::thread::spawn(move || {
        let (mut reader, pid) = policy_reader(&listener, &process);
        let reply = public_reply(&source_frame, public);
        reader.get_mut().write_all(&reply).unwrap();
        reported.send(pid).unwrap();
    });
    let ticket = host.new_ticket().unwrap();
    assert!(host.offer(&ticket));
    let request = host.prepare_native(&ticket).unwrap();
    assert!(host.publish_native(request, bytes.clone()));
    drive_until(&host, |sent| sent);
    let pid = report.recv_timeout(Duration::from_secs(15)).unwrap();
    source.join().unwrap();
    let runtime =
        tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().unwrap();
    runtime.block_on(async {
        let mesh = client_mesh(private, &binding).await;
        let destination = overlay_address(&binding.host);
        let address = SocketAddr::new(IpAddr::V6(destination), cmux_link::LINK_PORT);
        let hello = format!(
            "{}\n",
            json!({"service":"daemon","epoch":binding.epoch,"link_token":token(public, 1, "a".repeat(64).as_str())})
        );
        let mut stream = within(mesh.connect(address)).await.unwrap();
        stream.write_all(hello.as_bytes()).await.unwrap();
        stream.write_all(b"{\"id\":7,\"cmd\":\"identify\"}\n").await.unwrap();
        let mut stream = BufReader::new(stream);
        let mut line = String::new();
        assert!(within(stream.read_line(&mut line)).await.unwrap() > 0);
        let response: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(response["id"], 7);
        assert_eq!(
            response["error_code"], "remote_denied",
            "a command outside fs-v1 crossed the actual gate"
        );
        // A complete signed hello spends its token even when a later command
        // is refused. The same receiver must refuse a second use before entry.
        let mut replay = within(mesh.connect(address)).await.unwrap();
        replay.write_all(hello.as_bytes()).await.unwrap();
        let refused = within(replay.read(&mut [0])).await;
        assert!(matches!(refused, Ok(0) | Err(_)), "a spent token reached the daemon entry");
        // Refusing the replay must leave the original admitted connection
        // usable; whole-receiver failure is not evidence of replay protection.
        stream.get_mut().write_all(b"{\"id\":8,\"cmd\":\"identify\"}\n").await.unwrap();
        line.clear();
        assert!(within(stream.read_line(&mut line)).await.unwrap() > 0);
        let response: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(response["id"], 8);
        assert_eq!(response["error_code"], "remote_denied");
        assert_eq!(
            host.quiesce(std::time::Instant::now() + Duration::from_secs(8)).unwrap(),
            StopReceipt::Acknowledged
        );
        assert!(!std::path::Path::new(&format!("/proc/{pid}/stat")).exists());
        assert!(daemon.child.try_wait().unwrap().is_none());
        let ended = within(stream.read(&mut [0])).await;
        assert!(matches!(ended, Ok(0) | Err(_)), "stopped receiver retained its encrypted stream");
        mesh.shutdown().await;

        // Recreate the receiving child and dial-side mesh with their original
        // keys. A new client mesh forces a fresh WG handshake, so a transport
        // timeout cannot masquerade as a JWT replay refusal.
        let listener = agent.listener.try_clone().unwrap();
        let process = daemon.child.clone();
        let mut header: Value = serde_json::from_slice(&bytes[4..bytes.len() - 32]).unwrap();
        header["generation"] = "b".repeat(64).into();
        let encoded = serde_json::to_vec(&header).unwrap();
        let mut replacement_frame = Zeroizing::new((encoded.len() as u32).to_be_bytes().to_vec());
        replacement_frame.extend_from_slice(&encoded);
        replacement_frame.extend_from_slice(&bytes[bytes.len() - 32..]);
        let replacement = NativeBootstrap::decode(&replacement_frame).unwrap();
        assert_eq!(replacement.binding(), &binding, "replacement rotated the original identity");
        assert_eq!(replacement.keys(), NativeBootstrap::decode(&bytes).unwrap().keys());
        let source_frame = replacement_frame.clone();
        let (reported, report) = std::sync::mpsc::sync_channel(1);
        let source = std::thread::spawn(move || {
            let (mut reader, pid) = policy_reader(&listener, &process);
            reader.get_mut().write_all(&public_reply(&source_frame, public)).unwrap();
            reported.send(pid).unwrap();
        });
        let ticket = host.new_ticket().unwrap();
        assert!(host.offer(&ticket));
        assert!(host.publish_native(host.prepare_native(&ticket).unwrap(), replacement_frame));
        drive_until(&host, |sent| sent);
        let replacement_pid = report.recv_timeout(Duration::from_secs(15)).unwrap();
        source.join().unwrap();
        assert_ne!(replacement_pid, pid, "the receiving child was not replaced");
        let mesh = client_mesh(private, &binding).await;
        let fresh_hello = format!(
            "{}\n",
            json!({"service":"daemon","epoch":binding.epoch,"link_token":token(public, 2, "b".repeat(64).as_str())})
        );
        let mut fresh = within(mesh.connect(address)).await.unwrap();
        fresh.write_all(fresh_hello.as_bytes()).await.unwrap();
        fresh.write_all(b"{\"id\":9,\"cmd\":\"identify\"}\n").await.unwrap();
        let mut fresh = BufReader::new(fresh);
        line.clear();
        assert!(within(fresh.read_line(&mut line)).await.unwrap() > 0);
        let response: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(response["id"], 9);
        assert_eq!(response["error_code"], "remote_denied");

        let mut replay = within(mesh.connect(address)).await.unwrap();
        let delivered = replay
            .write_all(format!("{hello}{{\"id\":10,\"cmd\":\"identify\"}}\n").as_bytes())
            .await;
        let refused =
            delivered.is_err() || matches!(within(replay.read(&mut [0])).await, Ok(0) | Err(_));
        // The current token remains usable after the saved JWT is refused.
        fresh.get_mut().write_all(b"{\"id\":11,\"cmd\":\"identify\"}\n").await.unwrap();
        line.clear();
        assert!(within(fresh.read_line(&mut line)).await.unwrap() > 0);
        let response: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(response["id"], 11);
        assert_eq!(response["error_code"], "remote_denied");
        assert_eq!(
            host.quiesce(std::time::Instant::now() + Duration::from_secs(8)).unwrap(),
            StopReceipt::Acknowledged
        );
        assert!(!std::path::Path::new(&format!("/proc/{replacement_pid}/stat")).exists());
        assert!(daemon.child.try_wait().unwrap().is_none());
        let ended = within(fresh.read(&mut [0])).await;
        assert!(matches!(ended, Ok(0) | Err(_)));
        mesh.shutdown().await;
        assert!(refused, "saved signed token reached the replacement receiver's daemon entry");
    });
    assert!(!cmux_link::entry_path::remote_entry_socket_path(&daemon.session).exists());
    println!("ROOT_BOUNDARY_EXECUTED native_encrypted_daemon_chain");
}
