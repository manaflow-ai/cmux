//! Exercises the actual server binary, authenticated libp2p peers and management HTTP.
use cmux_v3_grants::{
    AuthorityKeys, Grant, GrantSigner, LeasePolicy, OfflineAccess, Revocations, Scope,
};
use cmux_v3_transport::{peer, relay_auth, session, PeerBehaviour, PeerBehaviourEvent};
use ed25519_dalek::SigningKey;
use futures::StreamExt;
use libp2p::{
    identity, multiaddr::Protocol, relay, request_response, swarm::SwarmEvent, Multiaddr, PeerId,
    Swarm,
};
use std::{
    fs::OpenOptions,
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    os::unix::fs::OpenOptionsExt,
    process::{Child, Command, Stdio},
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

struct Server {
    child: Child,
    _files: tempfile::TempDir,
    http: u16,
    relay: Multiaddr,
    peer: PeerId,
    signer: GrantSigner,
    keys: Arc<AuthorityKeys>,
}
impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}
fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
}
fn http(port: u16, path: &str, token: Option<&str>) -> (u16, String) {
    let mut socket = TcpStream::connect_timeout(
        &format!("127.0.0.1:{port}").parse().unwrap(),
        Duration::from_millis(200),
    )
    .unwrap();
    socket
        .set_read_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    let method = if path == "/drain" { "POST" } else { "GET" };
    let auth = token
        .map(|s| format!("Authorization: Bearer {s}\r\n"))
        .unwrap_or_default();
    write!(socket, "{method} {path} HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n{auth}Connection: close\r\n\r\n").unwrap();
    let mut response = String::new();
    socket.read_to_string(&mut response).unwrap();
    let (head, body) = response.split_once("\r\n\r\n").unwrap();
    (
        head.split_whitespace().nth(1).unwrap().parse().unwrap(),
        body.into(),
    )
}

impl Server {
    async fn start() -> Self {
        let files = tempfile::tempdir().unwrap();
        for (name, bytes) in [("identity", [11; 32]), ("drain", [33; 32])] {
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(files.path().join(name))
                .unwrap();
            file.write_all(&bytes).unwrap();
        }
        let signing = SigningKey::from_bytes(&[12; 32]);
        std::fs::write(
            files.path().join("keys.json"),
            serde_json::to_vec(
                &serde_json::json!({"test": hex::encode(signing.verifying_key().as_bytes())}),
            )
            .unwrap(),
        )
        .unwrap();
        let peer = identity::Keypair::ed25519_from_bytes([11; 32])
            .unwrap()
            .public()
            .to_peer_id();
        let http_port = port();
        let tcp = port();
        let ws = port();
        let udp = port();
        let relay: Multiaddr = format!("/ip4/127.0.0.1/tcp/{tcp}/p2p/{peer}")
            .parse()
            .unwrap();
        let child = Command::new(env!("CARGO_BIN_EXE_cmux-v3-relay-server"))
            .args([
                "--http",
                &format!("127.0.0.1:{http_port}"),
                "--tcp",
                &format!("/ip4/127.0.0.1/tcp/{tcp}"),
                "--quic",
                &format!("/ip4/127.0.0.1/udp/{udp}/quic-v1"),
                "--websocket",
                &format!("/ip4/127.0.0.1/tcp/{ws}/ws"),
                "--advertise",
                &relay.to_string(),
                "--drain-min-seconds",
                "0",
            ])
            .arg("--identity-file")
            .arg(files.path().join("identity"))
            .arg("--authority-keys")
            .arg(files.path().join("keys.json"))
            .arg("--drain-token-file")
            .arg(files.path().join("drain"))
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let mut keys = AuthorityKeys::default();
        keys.insert("test".into(), signing.verifying_key());
        let mut server = Self {
            child,
            _files: files,
            http: http_port,
            relay,
            peer,
            signer: GrantSigner::new("test".into(), &signing).unwrap(),
            keys: Arc::new(keys),
        };
        tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                assert!(
                    server.child.try_wait().unwrap().is_none(),
                    "relay exited before readiness"
                );
                if TcpStream::connect(format!("127.0.0.1:{http_port}")).is_ok()
                    && http(http_port, "/readyz", None).0 == 200
                {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await
        .unwrap();
        server
    }
    fn grant(&self, source: PeerId, destination: PeerId, action: &str) -> String {
        self.grant_with_lifetime(source, destination, action, 300)
    }
    fn grant_with_lifetime(
        &self,
        source: PeerId,
        destination: PeerId,
        action: &str,
        seconds: u32,
    ) -> String {
        let grant = Grant::new(
            Scope {
                team: "a",
                source,
                destination,
                action,
            },
            1,
            LeasePolicy {
                offline: OfflineAccess::Bounded { seconds },
                renew_every_seconds: 1,
            },
            now(),
            now(),
        )
        .unwrap();
        self.signer.sign(&grant, now()).unwrap()
    }
}

async fn authorize(
    client: &mut Swarm<PeerBehaviour>,
    server: &Server,
    request: relay_auth::Request,
) -> relay_auth::Response {
    client.dial(server.relay.clone()).unwrap();
    client
        .behaviour_mut()
        .relay_auth
        .send_request(&server.peer, request);
    loop {
        match client.select_next_some().await {
            SwarmEvent::Behaviour(PeerBehaviourEvent::RelayAuth(
                request_response::Event::Message {
                    message: request_response::Message::Response { response, .. },
                    ..
                },
            )) => return response,
            SwarmEvent::Behaviour(PeerBehaviourEvent::RelayAuth(
                request_response::Event::OutboundFailure { error, .. },
            )) => panic!("auth request failed: {error}"),
            _ => {}
        }
    }
}

async fn pump<T>(
    a: &mut Swarm<PeerBehaviour>,
    b: &mut Swarm<PeerBehaviour>,
    future: impl std::future::Future<Output = T>,
) -> T {
    tokio::pin!(future);
    loop {
        tokio::select! {
            result = &mut future => return result,
            _ = a.select_next_some() => {},
            _ = b.select_next_some() => {},
        }
    }
}

async fn exchange(a: &session::Session, b: &mut session::Session) {
    a.send(b"alive"[..].into()).await.unwrap();
    assert_eq!(b.receive().await.unwrap(), b"alive"[..]);
}

#[tokio::test]
async fn real_server_authenticates_and_drains_without_cutting_an_existing_circuit() {
    tokio::time::timeout(Duration::from_secs(30), async {
        let mut server = Server::start().await;
        assert_eq!(http(server.http, "/drain", None).0, 401);
        let mut host = peer(identity::Keypair::generate_ed25519()).await.unwrap();
        let mut client = peer(identity::Keypair::generate_ed25519()).await.unwrap();
        let destination = *host.local_peer_id();
        let source = *client.local_peer_id();
        assert_eq!(
            authorize(
                &mut host,
                &server,
                relay_auth::Request::Reserve {
                    team: "a".into(),
                    grant: "forged".into()
                }
            )
            .await,
            relay_auth::Response::Denied
        );
        let reserve = server.grant_with_lifetime(destination, server.peer, "relay_reserve", 5);
        assert_eq!(
            authorize(
                &mut host,
                &server,
                relay_auth::Request::Reserve {
                    team: "a".into(),
                    grant: reserve
                }
            )
            .await,
            relay_auth::Response::Accepted
        );
        let reservation = server.relay.clone().with(Protocol::P2pCircuit);
        host.listen_on(reservation.clone()).unwrap();
        loop {
            if matches!(
                host.select_next_some().await,
                SwarmEvent::Behaviour(PeerBehaviourEvent::Relay(
                    relay::client::Event::ReservationReqAccepted { .. }
                ))
            ) {
                break;
            }
        }
        let grant = server.grant_with_lifetime(source, destination, "connect", 5);
        let original_expired_at = now() + 6;
        assert_eq!(
            authorize(
                &mut client,
                &server,
                relay_auth::Request::Connect {
                    team: "a".into(),
                    destination: destination.to_string(),
                    grant: grant.clone()
                }
            )
            .await,
            relay_auth::Response::Accepted
        );
        client
            .dial(reservation.with(Protocol::P2p(destination)))
            .unwrap();
        let (_, updates) = tokio::sync::watch::channel(Arc::new(Revocations::default()));
        let client_context =
            session::Context::new("a".into(), source, server.keys.clone(), updates.clone(), 4)
                .unwrap();
        let host_context =
            session::Context::new("a".into(), destination, server.keys.clone(), updates, 4)
                .unwrap();
        let mut control = client.behaviour().streams.new_control();
        let mut incoming = host
            .behaviour()
            .streams
            .new_control()
            .accept(session::PROTOCOL)
            .unwrap();
        let lane = session::Lane {
            kind: session::LaneKind::Control,
            resource: None,
            cursor: None,
        };
        let (client_stream, mut host_stream) = pump(&mut client, &mut host, async {
            let accept = async {
                let (peer, stream) = incoming.next().await.unwrap();
                assert_eq!(peer, source);
                host_context.accept(peer, stream).await.unwrap().1
            };
            let (client, host) = tokio::join!(
                client_context.open(&mut control, destination, grant.clone(), lane),
                accept
            );
            (client.unwrap(), host)
        })
        .await;
        pump(
            &mut client,
            &mut host,
            exchange(&client_stream, &mut host_stream),
        )
        .await;
        let (_, body) = http(server.http, "/metrics", None);
        assert!(body.contains("cmux_v3_circuits 1"));
        assert!(body.ends_with("# EOF\n"));
        assert_eq!(
            http(server.http, "/drain", Some(&hex::encode([33; 32]))).0,
            202
        );
        assert_eq!(http(server.http, "/readyz", None).0, 503);
        // Renewal must work after drain starts, while new circuits remain denied.
        assert_eq!(
            authorize(
                &mut host,
                &server,
                relay_auth::Request::Reserve {
                    team: "a".into(),
                    grant: server.grant(destination, server.peer, "relay_reserve"),
                }
            )
            .await,
            relay_auth::Response::Accepted
        );
        let grant = server.grant(source, destination, "connect");
        assert_eq!(
            authorize(
                &mut client,
                &server,
                relay_auth::Request::Connect {
                    team: "a".into(),
                    destination: destination.to_string(),
                    grant: grant.clone(),
                }
            )
            .await,
            relay_auth::Response::Accepted
        );
        pump(&mut client, &mut host, client_stream.renew(grant))
            .await
            .unwrap();
        while now() <= original_expired_at {
            tokio::select! {
                _ = client.select_next_some() => {},
                _ = host.select_next_some() => {},
                _ = tokio::time::sleep(Duration::from_millis(50)) => {},
            }
        }
        pump(
            &mut client,
            &mut host,
            exchange(&client_stream, &mut host_stream),
        )
        .await;
        assert!(server.child.try_wait().unwrap().is_none());
        client.disconnect_peer_id(destination).unwrap();
        loop {
            if let Some(status) = server.child.try_wait().unwrap() {
                assert!(status.success());
                break;
            }
            tokio::select! {
                _ = client.select_next_some() => {}, _ = host.select_next_some() => {},
                _ = tokio::time::sleep(Duration::from_millis(20)) => {}
            }
        }
    })
    .await
    .unwrap();
}
