//! The client heartbeat on a real `ClientConnection` to an in-process daemon
//! over in-memory links, under a paused clock. `heartbeat_probes` counts the
//! HEARTBEAT_REQUEST frames the client put on the wire.

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use bytes::Bytes;
use cmux_remote_protocol::{FrameFlags, Lane, LanePolicy, SessionId};
use tempfile::TempDir;

use super::{ClientConnection, ClientConnectionConfig, ReconnectPolicy};
use crate::crypto::{ClientAuthMode, InboundAuthEvidence, StaticIdentity};
use crate::daemon::{InboundLink, RemoteDaemon, ServerConnection};
use crate::identity::AuthDatabase;
use crate::link::FrameLink;
use crate::observability::ConnectionState;
use crate::provider::{
    CarrierEvidence, LengthDelimitedLink, LinkGroup, LinkRequest, ProviderCapabilities,
    ProviderError,
};
use crate::session::SessionLimits;

const INTERVAL: Duration = Duration::from_secs(15);
const MAXIMUM_FRAME_BYTES: usize = 65_535;

/// Each `open` is one in-memory link whose daemon end the daemon accepts as a
/// same-owner kernel peer (carrier authentication, as over a Unix socket).
struct MemoryLinkGroup {
    daemon: Arc<RemoteDaemon>,
    evidence: CarrierEvidence,
}

#[async_trait]
impl LinkGroup for MemoryLinkGroup {
    fn description(&self) -> &str {
        "memory"
    }

    fn capabilities(&self) -> ProviderCapabilities {
        ProviderCapabilities::STREAM
    }

    fn evidence(&self) -> &CarrierEvidence {
        &self.evidence
    }

    async fn open(&self, _request: LinkRequest) -> Result<Box<dyn FrameLink>, ProviderError> {
        let (client, daemon_end) = tokio::io::duplex(4 * MAXIMUM_FRAME_BYTES);
        let (client_read, client_write) = tokio::io::split(client);
        let (daemon_read, daemon_write) = tokio::io::split(daemon_end);
        let inbound = InboundLink::new(
            Box::new(LengthDelimitedLink::new(
                "memory-daemon",
                MAXIMUM_FRAME_BYTES,
                daemon_read,
                daemon_write,
            )),
            InboundAuthEvidence::verified_same_owner_kernel_peer(0, 0)
                .expect("the same uid is the same owner"),
        );
        let daemon = self.daemon.clone();
        tokio::spawn(async move {
            let _ = daemon.accept(inbound).await;
        });
        Ok(Box::new(LengthDelimitedLink::new(
            "memory-client",
            MAXIMUM_FRAME_BYTES,
            client_read,
            client_write,
        )))
    }

    async fn close(&self) -> Result<(), ProviderError> {
        Ok(())
    }
}

struct Pair {
    client: Arc<ClientConnection>,
    daemon_client: Arc<ServerConnection>,
    _daemon: Arc<RemoteDaemon>,
    _state: TempDir,
}

async fn connect_pair() -> Pair {
    let state = tempfile::tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(state.path(), "heartbeat-test", true).unwrap();
    let (daemon, mut accepted) = RemoteDaemon::new(auth, SessionLimits::default());
    let group = Arc::new(MemoryLinkGroup {
        daemon: daemon.clone(),
        evidence: CarrierEvidence::LocalPeer { uid: Some(0), pid: None },
    });
    let client = ClientConnection::connect(
        group,
        ClientConnectionConfig {
            identity: StaticIdentity::generate().unwrap(),
            expected_daemon: None,
            auth: ClientAuthMode::Carrier,
            device_name: "heartbeat-client".into(),
            session: SessionId([77; 16]),
            lane_policy: LanePolicy::Single,
            limits: SessionLimits::default(),
            reconnect: ReconnectPolicy { maximum_attempts: Some(1), ..ReconnectPolicy::default() },
        },
    )
    .await
    .expect("the in-memory carrier dial failed");
    let daemon_client = accepted.recv().await.expect("the daemon published no client");
    // The daemon answers HEARTBEAT_REQUEST inside its receive loop.
    let serving = daemon_client.clone();
    tokio::spawn(async move { while let Ok(Some(_)) = serving.receive().await {} });
    Pair { client, daemon_client, _daemon: daemon, _state: state }
}

#[test]
fn the_default_policy_probes_after_fifteen_seconds_of_silence() {
    let policy = ReconnectPolicy::default();
    assert_eq!(policy.heartbeat_interval, Some(INTERVAL));
    assert!(policy.heartbeat_timeout < INTERVAL);
}

#[tokio::test(start_paused = true)]
async fn a_peer_frame_every_five_seconds_puts_no_probe_on_the_wire() {
    let pair = connect_pair().await;
    let reader = pair.client.clone();
    let received = tokio::spawn(async move {
        let mut frames = 0_u32;
        while let Ok(Some(_)) = reader.receive().await {
            frames += 1;
        }
        frames
    });
    for _ in 0..12 {
        tokio::time::sleep(Duration::from_secs(5)).await;
        pair.daemon_client
            .send(Lane::Bulk, 1, Bytes::from_static(b"output"), FrameFlags::empty())
            .await
            .unwrap();
    }
    tokio::time::sleep(Duration::from_secs(1)).await;
    let snapshot = pair.client.snapshot().await;
    assert_eq!(snapshot.heartbeat_probes, 0, "a busy connection was probed");
    assert_eq!(snapshot.state, ConnectionState::Connected);
    pair.client.close().await.unwrap();
    assert_eq!(received.await.unwrap(), 12);
}

#[tokio::test(start_paused = true)]
async fn silence_puts_one_probe_on_the_wire_per_interval() {
    let pair = connect_pair().await;
    tokio::time::sleep(INTERVAL - Duration::from_secs(1)).await;
    assert_eq!(pair.client.snapshot().await.heartbeat_probes, 0, "probed before the interval");
    // Now at 4 intervals and 1 s: probes at 15, 30, 45 and 60 s.
    tokio::time::sleep(3 * INTERVAL + Duration::from_secs(2)).await;
    let snapshot = pair.client.snapshot().await;
    assert_eq!(snapshot.heartbeat_probes, 4, "one probe per {INTERVAL:?} of silence");
    assert_eq!(snapshot.state, ConnectionState::Connected, "an answered probe reconnected");
    pair.client.close().await.unwrap();
}
