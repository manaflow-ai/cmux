//! Exercise the VM receiver through real encrypted meshes and a real service
//! socket. The signing seed below is published test-vector material only.
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use cmux_host::cloud::wire::Env;
use cmux_link::keyset::Keyset;
use cmux_link::native_token::{NativePeer, ReceiverTime, receiver::Owner};
use ring::signature::Ed25519KeyPair;
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
use tokio::net::{TcpListener, TcpStream};

use super::*;

const NOW: u64 = 1_792_000_010_000;
const PRIVATE: [u8; 32] = [8; 32];
const CLIENT: [u8; 32] = [9; 32];

fn fixture() -> Value {
    serde_json::from_str(include_str!("../../../../../schemas/link-token/native.json")).unwrap()
}

fn public(private: [u8; 32]) -> [u8; 32] {
    *x25519_dalek::PublicKey::from(&x25519_dalek::StaticSecret::from(private)).as_bytes()
}

fn signing_key() -> Ed25519KeyPair {
    let keys: Value =
        serde_json::from_str(include_str!("../../../../../schemas/link-token/vectors.json"))
            .unwrap();
    let seed = URL_SAFE_NO_PAD.decode(keys["test_keys"]["test-k1"]["d"].as_str().unwrap()).unwrap();
    Ed25519KeyPair::from_seed_unchecked(&seed).unwrap()
}

fn token() -> String {
    let mut claims = fixture()["claims"].clone();
    claims["network"]["wg_public_key"] = STANDARD.encode(public(CLIENT)).into();
    let header = URL_SAFE_NO_PAD.encode(
        serde_json::to_vec(&json!({"alg":"EdDSA","typ":"cmux-link+jwt","kid":"test-k1"})).unwrap(),
    );
    let claims = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&claims).unwrap());
    let message = format!("{header}.{claims}");
    format!("{message}.{}", URL_SAFE_NO_PAD.encode(signing_key().sign(message.as_bytes()).as_ref()))
}

fn binding() -> ReceiverBinding {
    let f = fixture();
    ReceiverBinding {
        machine: "vm_00000000000000000002".into(),
        host: f["claims"]["aud"].as_str().unwrap().into(),
        epoch: 4,
        user: "user_00000000000000000002".into(),
        install: "inst_00000000000000000002".into(),
        team: f["claims"]["team"].as_str().unwrap().into(),
        env: Env::Dev,
        wg_public_key: STANDARD.encode(public(PRIVATE)),
        install_public_key: STANDARD.encode([4; 65]),
    }
}

fn publish(owner: &Owner, serial: u64) -> NativePolicy {
    publish_for(owner, serial, 30_000)
}

fn publish_for(owner: &Owner, serial: u64, lifetime: u64) -> NativePolicy {
    let f = fixture();
    let mut network = f["claims"]["network"].clone();
    network["wg_public_key"] = STANDARD.encode(public(CLIENT)).into();
    let refresh = owner.begin().unwrap();
    let policy = NativePolicy {
        issuer: f["claims"]["iss"].as_str().unwrap().into(),
        host: f["claims"]["aud"].as_str().unwrap().into(),
        epoch: 4,
        team: f["claims"]["team"].as_str().unwrap().into(),
        authority_version: "c".repeat(64),
        checked_at_ms: NOW + serial,
        expires_at_ms: NOW + serial + lifetime,
        request_started: refresh.started(),
        peers: vec![NativePeer {
            install: f["claims"]["sub"].as_str().unwrap().into(),
            binding: serde_json::from_value(network).unwrap(),
            services: vec![cmux_link::dial::Service::Ssh, cmux_link::dial::Service::Daemon],
        }],
    };
    let monotonic = Instant::now();
    let elapsed = monotonic.duration_since(refresh.started()).as_millis() as u64;
    let keys = keys();
    owner
        .install(
            refresh,
            keys,
            policy.clone(),
            ReceiverTime { unix_ms: policy.checked_at_ms + elapsed, monotonic },
        )
        .unwrap();
    policy
}

fn keys() -> Keyset {
    let f = fixture();
    Keyset {
        version: "0000000000000001".into(),
        keys: [(
            "test-k1".into(),
            URL_SAFE_NO_PAD.decode(f["public_key"].as_str().unwrap()).unwrap().try_into().unwrap(),
        )]
        .into(),
    }
}

async fn within<T>(future: impl Future<Output = T>) -> T {
    tokio::time::timeout(Duration::from_secs(10), future).await.expect("receiver within10s")
}

async fn setup(
    sshd: SocketAddr,
    wrong_source: bool,
) -> (NativeReceiver, WgMesh, Arc<Owner>, NativePolicy) {
    let owner = Arc::new(Owner::new(keys()).unwrap());
    let policy = publish(&owner, 0);
    let socket = UdpSocket::bind((Ipv6Addr::LOCALHOST, 0)).await.unwrap();
    let endpoint = socket.local_addr().unwrap();
    let directory = cmux_unix_socket::short_test_dir("receiver-mesh");
    let mut receiver = NativeReceiver::start(
        binding(),
        Zeroizing::new(PRIVATE),
        socket,
        directory.path().join("session.sock"),
        sshd,
        owner.verifier(),
    )
    .await
    .unwrap();
    receiver.reconcile(Some(&policy)).await.unwrap();
    let source =
        if wrong_source { &policy.peers[0].binding.host } else { &policy.peers[0].install };
    let client = WgMesh::start(
        WgMeshConfig {
            private_key: Zeroizing::new(CLIENT),
            addresses: vec![InterfaceAddress {
                address: IpAddr::V6(overlay_address(source)),
                prefix: 128,
            }],
            mtu: super::super::state::LINK_MTU,
        },
        UdpSocket::bind((Ipv6Addr::LOCALHOST, 0)).await.unwrap(),
    )
    .unwrap();
    client
        .add_peer(WgPeer {
            public_key: public(PRIVATE),
            preshared_key: None,
            allowed_ips: vec![
                IpNetwork::new(IpAddr::V6(overlay_address(&policy.host)), 128).unwrap(),
            ],
            route: Some(endpoint.into()),
            persistent_keepalive: None,
        })
        .await
        .unwrap();
    (receiver, client, owner, policy)
}

async fn drive<T>(receiver: &mut NativeReceiver, future: impl Future<Output = T>) -> T {
    within(async {
        tokio::select! {
            biased;
            completed = receiver.inflight.next() => panic!("service ended early: {completed:?}"),
            value = future => value,
        }
    })
    .await
}

async fn accepted(receiver: &mut NativeReceiver, client: &WgMesh) -> WgStream {
    let stream = within(client.connect(SocketAddr::new(
        IpAddr::V6(overlay_address(&receiver.binding.host)),
        cmux_link::LINK_PORT,
    )))
    .await
    .unwrap();
    let (incoming, key) = within(receiver.listener.accept()).await.unwrap();
    assert_eq!(key, public(CLIENT));
    receiver.accept(incoming, key);
    stream
}

async fn active(
    receiver: &mut NativeReceiver,
    client: &WgMesh,
    sshd: &TcpListener,
) -> (WgStream, TcpStream) {
    let mut stream = accepted(receiver, client).await;
    stream
        .write_all(
            format!("{}\nping\n", json!({"service":"ssh","epoch":4,"link_token":token()}))
                .as_bytes(),
        )
        .await
        .unwrap();
    let (mut backend, _) = drive(receiver, sshd.accept()).await.unwrap();
    let mut bytes = [0; 5];
    drive(receiver, backend.read_exact(&mut bytes)).await.unwrap();
    assert_eq!(&bytes, b"ping\n");
    (stream, backend)
}

#[tokio::test]
async fn native_receiver_runtime_original_handler_refuses_unsigned_hello() {
    let owner = Owner::new(keys()).unwrap();
    let policy = publish(&owner, 0);
    let (mut client, incoming) = tokio::io::duplex(4096);
    client.write_all(b"{\"service\":\"ssh\",\"epoch\":4}\n").await.unwrap();
    let session = PathBuf::from("/unused/session.sock");
    let me = HostIdentity {
        host: &policy.host,
        epoch: 4,
        session_socket: &session,
        sshd: "127.0.0.1:1".parse().unwrap(),
    };
    let source = SocketAddr::new(IpAddr::V6(overlay_address(&policy.peers[0].install)), 40000);
    assert_eq!(
        within(serve_host_inbound(incoming, public(CLIENT), source, &*owner.verifier(), &me)).await,
        Err(super::super::host_inbound::HostRefused::Token)
    );
}

#[tokio::test]
async fn native_receiver_runtime_signed_ssh_uses_host_address_and_role_stop_closes_backend() {
    let sshd = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let (mut receiver, client, _owner, _) = setup(sshd.local_addr().unwrap(), false).await;
    let (mut stream, mut backend) = active(&mut receiver, &client, &sshd).await;
    backend.write_all(b"pong\n").await.unwrap();
    let mut bytes = [0; 5];
    drive(&mut receiver, stream.read_exact(&mut bytes)).await.unwrap();
    assert_eq!(&bytes, b"pong\n");
    let (_policies, updates) = mpsc::channel(1);
    within(receiver.serve(updates, async {})).await.unwrap();
    assert_eq!(within(backend.read(&mut [0])).await.unwrap(), 0);
    client.shutdown().await;
}

#[tokio::test]
async fn native_receiver_runtime_drains_active_and_partial_hellos_before_peer_removal() {
    let sshd = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let (mut receiver, client, owner, _) = setup(sshd.local_addr().unwrap(), false).await;
    let (_active, mut backend) = active(&mut receiver, &client, &sshd).await;
    let mut partial = accepted(&mut receiver, &client).await;
    drive(&mut receiver, partial.write_all(b"{\"service\":")).await.unwrap();
    owner.invalidate();
    within(receiver.reconcile(None)).await.unwrap();
    assert_eq!(within(backend.read(&mut [0])).await.unwrap(), 0);
    assert!(receiver.services.is_empty() && receiver.inflight.is_empty());
    assert_eq!(receiver.mesh.peer_route(public(CLIENT)).await.unwrap(), None);
    let (_policies, updates) = mpsc::channel(1);
    within(receiver.serve(updates, async {})).await.unwrap();
    client.shutdown().await;
}

#[tokio::test]
async fn native_receiver_runtime_unchanged_policy_renews_a_live_encrypted_service() {
    let sshd = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let (mut receiver, client, owner, original) = setup(sshd.local_addr().unwrap(), false).await;
    let (mut stream, mut backend) = active(&mut receiver, &client, &sshd).await;
    let route = receiver.mesh.peer_route(public(CLIENT)).await.unwrap();
    let renewed = publish(&owner, 1);
    receiver.reconcile(Some(&renewed)).await.unwrap();
    // A queued older publication cannot park the current topology or its copy.
    receiver.reconcile(Some(&original)).await.unwrap();
    assert_eq!(receiver.mesh.peer_route(public(CLIENT)).await.unwrap(), route);
    backend.write_all(b"renewed\n").await.unwrap();
    let mut bytes = [0; 8];
    drive(&mut receiver, stream.read_exact(&mut bytes)).await.unwrap();
    assert_eq!(&bytes, b"renewed\n");
    let (_policies, updates) = mpsc::channel(1);
    within(receiver.serve(updates, async {})).await.unwrap();
    client.shutdown().await;
}

#[tokio::test]
async fn native_receiver_runtime_wireguard_refuses_a_source_host_address_instead_of_install() {
    let sshd = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let (receiver, client, _owner, _) = setup(sshd.local_addr().unwrap(), true).await;
    assert!(
        tokio::time::timeout(
            Duration::from_secs(1),
            client.connect(SocketAddr::new(
                IpAddr::V6(overlay_address(&receiver.binding.host)),
                cmux_link::LINK_PORT,
            ))
        )
        .await
        .is_err()
    );
    let (_policies, updates) = mpsc::channel(1);
    within(receiver.serve(updates, async {})).await.unwrap();
    client.shutdown().await;
}

#[tokio::test]
async fn native_receiver_runtime_expiry_closes_a_real_backend_without_a_policy_update() {
    let sshd = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let (mut receiver, client, owner, _) = setup(sshd.local_addr().unwrap(), false).await;
    let (_stream, mut backend) = active(&mut receiver, &client, &sshd).await;
    let short = publish_for(&owner, 10_000, 500);
    receiver.reconcile(Some(&short)).await.unwrap();
    let (_policies, updates) = mpsc::channel(1);
    let (stop, stopped) = oneshot::channel();
    let serve = receiver.serve(updates, async {
        let _ = stopped.await;
    });
    let check = async {
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(2), backend.read(&mut [0]))
                .await
                .expect("expired encrypted service remained open")
                .unwrap(),
            0
        );
        let _ = stop.send(());
    };
    let (result, ()) = within(async { tokio::join!(serve, check) }).await;
    result.unwrap();
    client.shutdown().await;
}
