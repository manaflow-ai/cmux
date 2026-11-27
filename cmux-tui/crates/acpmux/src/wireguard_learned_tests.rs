use super::*;
use tokio::net::TcpListener;

const BOUND: Duration = Duration::from_secs(15);

fn runtime() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .thread_stack_size(32 << 20)
        .enable_all()
        .build()
        .unwrap()
}

/// One machine's transport with no configured peer, at service address `10.78.0.N:4100`.
async fn machine(home: &Path, n: u8, target: SocketAddr) -> Arc<Transport> {
    machine_with(home, n, target, &BTreeMap::new()).await
}

async fn machine_with(
    home: &Path,
    n: u8,
    target: SocketAddr,
    configured: &BTreeMap<String, crate::config::PeerConfig>,
) -> Arc<Transport> {
    let socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    machine_on(home, n, target, configured, socket).await
}

async fn machine_on(
    home: &Path,
    n: u8,
    target: SocketAddr,
    configured: &BTreeMap<String, crate::config::PeerConfig>,
    socket: UdpSocket,
) -> Arc<Transport> {
    let settings = StaticConfig {
        listen: socket.local_addr().unwrap(),
        address: format!("10.78.0.{n}:4100").parse().unwrap(),
    };
    let lock = KeyHolder::acquire(home).unwrap();
    Transport::from_socket(&settings, configured, home, target, socket, lock).await.unwrap()
}

/// What `peer_wg_learn.rs` does with `b`'s `node.wireguard`: `b` admits `a`, `a` learns `b`.
async fn learn(a: &Transport, b: &Transport) -> SocketAddr {
    let ad = a.advert();
    let key = ad["publicKey"].as_str().unwrap();
    let address = ad["address"].as_str().unwrap().parse().unwrap();
    b.admit(key, address).await.unwrap();
    // After a restart this admission may already be persisted; either answer must leave
    // the origin admitted at its current address.
    assert_eq!(load(&b.state_dir).admitted.get(key), Some(&address));
    let bd = b.advert();
    let route = StaticPeer {
        public_key: bd["publicKey"].as_str().unwrap().to_owned(),
        endpoint: format!("127.0.0.1:{}", bd["port"]),
        address: bd["address"].as_str().unwrap().parse().unwrap(),
    };
    a.learn("b", route).await.unwrap()
}

async fn carries(a: &Transport, address: SocketAddr, target: &TcpListener) {
    use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
    let mut stream = tokio::time::timeout(BOUND, a.connect(address)).await.unwrap().unwrap();
    let (mut accepted, _) = tokio::time::timeout(BOUND, target.accept()).await.unwrap().unwrap();
    stream.write_all(b"ping").await.unwrap();
    let mut got = [0u8; 4];
    tokio::time::timeout(BOUND, accepted.read_exact(&mut got)).await.unwrap().unwrap();
    assert_eq!(&got, b"ping");
}

#[test]
fn a_learned_route_carries_with_no_configured_peer_and_survives_a_restart() {
    runtime().block_on(async {
        let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let to = target.local_addr().unwrap();
        let homes = [tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap()];
        let a = machine(homes[0].path(), 1, to).await;
        let b = machine(homes[1].path(), 2, to).await;
        assert!(a.learned_route("b").is_none());
        let address = learn(&a, &b).await;
        assert_eq!(address, "10.78.0.2:4100".parse().unwrap());
        carries(&a, address, &target).await;

        // Asked again (the next host_health): nothing changes.
        let ad = a.advert();
        let again = b
            .admit(ad["publicKey"].as_str().unwrap(), "10.78.0.1:4100".parse().unwrap())
            .await
            .unwrap();
        assert!(!again, "a second admit at the same address changes nothing");

        // Both restart: the kept lists come back, and the cold dial goes over WireGuard with
        // no admit and no learn (no ssh, no host_health).
        let ports = [a.local_addr(), b.local_addr()];
        a.shutdown(tokio::time::Instant::now()).await;
        b.shutdown(tokio::time::Instant::now()).await;
        drop((a, b));
        // A cold dial reuses the configured listen ports; a changed endpoint requires
        // another health reply, covered separately below.
        let a =
            machine_on(homes[0].path(), 1, to, &BTreeMap::new(), rebind(ports[0]).await.unwrap())
                .await;
        let b =
            machine_on(homes[1].path(), 2, to, &BTreeMap::new(), rebind(ports[1]).await.unwrap())
                .await;
        let kept = a.learned_route("b").expect("the route is kept across a restart");
        assert_eq!(kept.address, address);
        carries(&a, address, &target).await;
        a.shutdown(tokio::time::Instant::now()).await;
        b.shutdown(tokio::time::Instant::now()).await;
    });
}

#[test]
fn a_configured_peer_wins_over_anything_learned() {
    runtime().block_on(async {
        let to: SocketAddr = "127.0.0.1:1".parse().unwrap();
        let homes = [tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap()];
        let b = machine(homes[1].path(), 2, to).await;
        let bd = b.advert();
        let route = StaticPeer {
            public_key: bd["publicKey"].as_str().unwrap().to_owned(),
            endpoint: format!("127.0.0.1:{}", bd["port"]),
            address: bd["address"].as_str().unwrap().parse().unwrap(),
        };
        let configured = BTreeMap::from([(
            "b".to_owned(),
            crate::config::PeerConfig {
                link_host: None,
                url: "ws://127.0.0.1:1".into(),
                wireguard: Some(route.clone()),
                token: None,
                peer_token: None,
                vm_boundary: false,
                github_broker: false,
                group: None,
            },
        )]);
        let a = machine_with(homes[0].path(), 1, to, &configured).await;
        let refused = a.learn("b", route.clone()).await.unwrap_err();
        assert!(refused.to_string().contains("configured"), "{refused}");
        let refused = a.learn("other-name", route.clone()).await.unwrap_err();
        assert!(refused.to_string().contains("configured"), "{refused}");
        // A configured key is never admitted as an inbound-only peer either.
        assert!(!a.admit(&route.public_key, route.address).await.unwrap());
        assert!(load(homes[0].path()).routes.is_empty());
        a.shutdown(tokio::time::Instant::now()).await;
        b.shutdown(tokio::time::Instant::now()).await;
    });
}

#[test]
fn an_admit_with_a_bad_key_or_this_machines_address_is_refused() {
    runtime().block_on(async {
        let home = tempfile::tempdir().unwrap();
        let a = machine(home.path(), 1, "127.0.0.1:1".parse().unwrap()).await;
        let key = base64::engine::general_purpose::STANDARD.encode([9; 32]);
        assert!(a.admit("not base64", "10.78.0.9:4100".parse().unwrap()).await.is_err());
        // Its own service address is not a peer's.
        assert!(a.admit(&key, "10.78.0.1:4100".parse().unwrap()).await.is_err());
        assert!(a.admit(&key, "10.78.0.9:4100".parse().unwrap()).await.unwrap());
        assert_eq!(load(home.path()).admitted.len(), 1);
        a.shutdown(tokio::time::Instant::now()).await;
    });
}

#[test]
fn an_unreadable_learned_file_is_ignored() {
    let home = tempfile::tempdir().unwrap();
    std::fs::write(home.path().join(FILE), b"{not json").unwrap();
    assert_eq!(load(home.path()), Saved::default());
    std::fs::write(home.path().join(FILE), vec![b' '; (MAX_FILE_BYTES + 1) as usize]).unwrap();
    assert_eq!(load(home.path()), Saved::default());
}

#[test]
fn a_learned_route_refreshes_after_the_remote_endpoint_and_address_change() {
    runtime().block_on(async {
        let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let to = target.local_addr().unwrap();
        let homes = [tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap()];
        let a = machine(homes[0].path(), 1, to).await;
        let b = machine(homes[1].path(), 2, to).await;
        let address = learn(&a, &b).await;
        carries(&a, address, &target).await;
        let old_port = b.local_addr();
        b.shutdown(tokio::time::Instant::now()).await;
        drop(b);
        // Reserve the old endpoint so the OS cannot accidentally give it to the new daemon.
        let _old_endpoint = rebind(old_port).await.unwrap();
        let b = machine(homes[1].path(), 3, to).await;
        assert_ne!(b.local_addr(), old_port);
        let refreshed = learn(&a, &b).await;
        assert_ne!(refreshed, address);
        assert_eq!(load(homes[0].path()).routes["b"].address, refreshed);
        carries(&a, refreshed, &target).await;
        a.shutdown(tokio::time::Instant::now()).await;
        b.shutdown(tokio::time::Instant::now()).await;
    });
}
