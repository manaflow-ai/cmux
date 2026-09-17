//! Real QUIC/libp2p streams. These exercise admission and continuously enforced
//! authorization under backpressure; they do not establish real NAT traversal.
use bytes::Bytes;
use cmux_v3_grants::{
    AuthorityKeys, Grant, GrantSigner, LeasePolicy, OfflineAccess, Revocations, Scope,
};
use cmux_v3_transport::{
    peer,
    session::{self, Context, Error, Lane, LaneKind, Session},
};
use ed25519_dalek::SigningKey;
use futures::{AsyncWriteExt, StreamExt};
use libp2p::{identity, multiaddr::Protocol, swarm::SwarmEvent, PeerId};
use std::{
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::sync::watch;

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
}
fn lane() -> Lane {
    Lane {
        kind: LaneKind::Control,
        resource: Some("test-terminal".into()),
        cursor: Some(0),
    }
}
struct Pair {
    source: PeerId,
    destination: PeerId,
    client: Context,
    server: Context,
    control: libp2p_stream::Control,
    inbound: libp2p_stream::IncomingStreams,
    revoke: watch::Sender<Arc<Revocations>>,
    signer: GrantSigner,
    tasks: Vec<tokio::task::JoinHandle<()>>,
}
impl Drop for Pair {
    fn drop(&mut self) {
        for task in &self.tasks {
            task.abort();
        }
    }
}
impl Pair {
    async fn new(maximum: usize) -> Self {
        let mut a = peer(identity::Keypair::generate_ed25519()).await.unwrap();
        let mut b = peer(identity::Keypair::generate_ed25519()).await.unwrap();
        let source = *a.local_peer_id();
        let destination = *b.local_peer_id();
        let control = a.behaviour().streams.new_control();
        let inbound = b
            .behaviour()
            .streams
            .new_control()
            .accept(session::PROTOCOL)
            .unwrap();
        b.listen_on("/ip4/127.0.0.1/udp/0/quic-v1".parse().unwrap())
            .unwrap();
        let address = loop {
            if let SwarmEvent::NewListenAddr { address, .. } = b.select_next_some().await {
                break address;
            }
        };
        a.dial(address.with(Protocol::P2p(destination))).unwrap();
        let tasks = [a, b]
            .into_iter()
            .map(|mut swarm| tokio::spawn(async move { while swarm.next().await.is_some() {} }))
            .collect();
        let key = SigningKey::from_bytes(&[67; 32]);
        let mut keys = AuthorityKeys::default();
        keys.insert("test".into(), key.verifying_key());
        let keys = Arc::new(keys);
        let (revoke, updates) = watch::channel(Arc::new(Revocations::default()));
        // The initiator has no online revocation feed, as on a partitioned LAN.
        // The receiving endpoint must enforce its own server updates independently.
        let (_, client_updates) = watch::channel(Arc::new(Revocations::default()));
        let client =
            Context::new("team".into(), source, keys.clone(), client_updates, maximum).unwrap();
        let server = Context::new("team".into(), destination, keys, updates, maximum).unwrap();
        Self {
            source,
            destination,
            control,
            inbound,
            tasks,
            client,
            server,
            revoke,
            signer: GrantSigner::new("test".into(), &key).unwrap(),
        }
    }
    fn grant(&self, seconds: Option<u32>, revision: u64) -> String {
        self.grant_action(seconds, revision, "connect")
    }
    fn grant_action(&self, seconds: Option<u32>, revision: u64, action: &str) -> String {
        let grant = Grant::new(
            Scope {
                team: "team",
                source: self.source,
                destination: self.destination,
                action,
            },
            revision,
            LeasePolicy {
                offline: seconds.map_or(OfflineAccess::UntilRevoked {}, |seconds| {
                    OfflineAccess::Bounded { seconds }
                }),
                renew_every_seconds: 1,
            },
            now(),
            now(),
        )
        .unwrap();
        self.signer.sign(&grant, now()).unwrap()
    }
    async fn open(&mut self, token: String) -> (Session, Session) {
        self.open_lane(token, lane()).await
    }
    async fn open_lane(&mut self, token: String, lane: Lane) -> (Session, Session) {
        let accept = async {
            let (source, stream) = self.inbound.next().await.unwrap();
            assert_eq!(source, self.source);
            self.server.accept(source, stream).await.unwrap()
        };
        let (client, (descriptor, server)) = tokio::join!(
            self.client
                .open(&mut self.control, self.destination, token, lane.clone()),
            accept
        );
        assert_eq!(descriptor, lane);
        (client.unwrap(), server)
    }
}

#[tokio::test]
async fn acknowledged_renewal_keeps_stream_alive_past_original_expiry() {
    tokio::time::timeout(Duration::from_secs(15), async {
        let mut pair = Pair::new(8).await;
        let old = pair.grant(Some(4), 1);
        let (mut a, mut b) = pair.open(old.clone()).await;
        let expires = now() + 5;
        a.send(Bytes::from_static(b"before")).await.unwrap();
        assert_eq!(b.receive().await.unwrap(), b"before"[..]);
        a.renew(pair.grant(Some(60), 2)).await.unwrap();
        assert_eq!(a.renew(old).await, Err(Error::Denied));
        while now() < expires {
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        b.send(Bytes::from_static(b"after")).await.unwrap();
        assert_eq!(a.receive().await.unwrap(), b"after"[..]);
        assert_eq!(b.renew(pair.grant(Some(60), 2)).await, Err(Error::Denied));
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn expiry_cancels_idle_reads_and_full_buffers_and_releases_capacity() {
    tokio::time::timeout(Duration::from_secs(12), async {
        let mut pair = Pair::new(1).await;
        let (a, mut b) = pair.open(pair.grant(Some(3), 1)).await;
        let token = pair.grant(Some(60), 1);
        assert!(matches!(
            pair.client
                .open(&mut pair.control, pair.destination, token, lane())
                .await,
            Err(Error::Capacity)
        ));
        let payload = Bytes::from(vec![7; session::MAX_DATA]);
        let sender = async {
            loop {
                if let Err(error) = a.send(payload.clone()).await {
                    return error;
                }
            }
        };
        let (send_error, close_error) = tokio::join!(sender, b.closed());
        assert!(matches!(
            send_error,
            Error::Expired | Error::Transport | Error::Closed
        ));
        assert_eq!(close_error, Error::Expired);
        assert_eq!(b.receive().await, Err(Error::Expired));
        // Capacity belongs to the running session, even if callers still hold closed handles.
        let token = pair.grant(Some(60), 1);
        let (a2, mut b2) = pair.open(token).await;
        a2.send(Bytes::from_static(b"new")).await.unwrap();
        assert_eq!(b2.receive().await.unwrap(), b"new"[..]);
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn unlimited_permission_is_revoked_on_live_stream_with_buffered_data() {
    tokio::time::timeout(Duration::from_secs(8), async {
        let mut pair = Pair::new(4).await;
        let (a, mut b) = pair.open(pair.grant(None, 1)).await;
        a.send(Bytes::from_static(b"must not be returned after revoke"))
            .await
            .unwrap();
        let mut revoked = Revocations::default();
        revoked.revoke_device("team".into(), pair.source);
        pair.revoke.send_replace(Arc::new(revoked));
        assert_eq!(b.closed().await, Error::Revoked);
        assert_eq!(b.receive().await, Err(Error::Revoked));
        assert!(matches!(a.closed().await, Error::Closed | Error::Transport));
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn malformed_oversized_or_forged_headers_never_admit_a_lane() {
    tokio::time::timeout(Duration::from_secs(10), async {
        let mut pair = Pair::new(1).await;
        for bytes in [(u32::MAX).to_be_bytes().to_vec(), {
            let body =
                br#"{"grant":"forged","lane":{"kind":"terminal","resource":null,"cursor":null}}"#;
            let mut frame = (body.len() as u32).to_be_bytes().to_vec();
            frame.extend(body);
            frame
        }] {
            let mut raw = pair
                .control
                .open_stream(pair.destination, session::PROTOCOL)
                .await
                .unwrap();
            raw.write_all(&bytes).await.unwrap();
            let (source, incoming) = pair.inbound.next().await.unwrap();
            assert!(pair.server.accept(source, incoming).await.is_err());
        }
        // Rejected headers release their slots; legitimate traffic still works.
        let (a, mut b) = pair.open(pair.grant(Some(60), 1)).await;
        a.send(Bytes::from_static(b"accepted")).await.unwrap();
        assert_eq!(b.receive().await.unwrap(), b"accepted"[..]);
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn read_permission_cannot_open_or_send_terminal_input() {
    tokio::time::timeout(Duration::from_secs(10), async {
        let mut pair = Pair::new(4).await;
        let token = pair.grant_action(Some(60), 1, "terminal_read");
        let read_lane = Lane {
            kind: LaneKind::Terminal,
            ..lane()
        };
        let (mut a, b) = pair.open_lane(token.clone(), read_lane).await;
        b.send(Bytes::from_static(b"terminal output"))
            .await
            .unwrap();
        assert_eq!(a.receive().await.unwrap(), b"terminal output"[..]);
        assert_eq!(
            a.send(Bytes::from_static(b"injected input")).await,
            Err(Error::Denied)
        );
        assert_eq!(a.renew(pair.grant(Some(60), 1)).await, Err(Error::Denied));

        // Bypass the initiating library to exercise the receiver's actual check.
        let mut raw = pair
            .control
            .open_stream(pair.destination, session::PROTOCOL)
            .await
            .unwrap();
        let body = serde_json::to_vec(&serde_json::json!({"grant":token,
            "lane":{"kind":"terminal_input","resource":"test-terminal","cursor":null}}))
        .unwrap();
        raw.write_all(&(body.len() as u32).to_be_bytes())
            .await
            .unwrap();
        raw.write_all(&body).await.unwrap();
        let (source, incoming) = pair.inbound.next().await.unwrap();
        assert!(matches!(
            pair.server.accept(source, incoming).await,
            Err(Error::Denied)
        ));
    })
    .await
    .unwrap();
}
