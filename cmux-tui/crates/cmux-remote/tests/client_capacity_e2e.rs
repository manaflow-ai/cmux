//! A daemon serving its limit of logical client sessions refuses one more
//! with a typed, retryable "too many connected clients" before link-ready,
//! instead of accepting it and closing it so its redial reads as an expired
//! session. The links of one session share one slot, and a slot frees when a
//! session ends.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;

use cmux_remote::connection::{
    ClientConnection, ClientConnectionConfig, ConnectionError, ReconnectPolicy,
};
use cmux_remote::crypto::{ClientAuthMode, StaticIdentity};
use cmux_remote::daemon::{DaemonSessionPolicy, RemoteDaemon, serve_direct_websocket};
use cmux_remote::identity::AuthDatabase;
use cmux_remote::provider::{ConnectRequest, DirectWebSocketProvider, TransportProvider};
use cmux_remote::session::SessionLimits;
use cmux_remote_protocol::{LanePolicy, SessionId};
use tempfile::tempdir;
use url::Url;
use zeroize::Zeroizing;

const MAXIMUM_FRAME_BYTES: usize = 65_535;
const CLIENT_LIMIT: usize = 2;
const STEP_TIMEOUT: Duration = Duration::from_secs(10);

struct Dialer {
    provider: DirectWebSocketProvider,
    endpoint: Url,
    daemon_public_key: [u8; 32],
    identity: StaticIdentity,
}

impl Dialer {
    async fn connect(
        &self,
        auth: ClientAuthMode,
        session: SessionId,
    ) -> Result<Arc<ClientConnection>, ConnectionError> {
        let group = self
            .provider
            .connect(ConnectRequest {
                endpoint: self.endpoint.clone(),
                session,
                // Several physical links per session where the transport
                // allows it: they must share the session's one slot.
                lane_policy: LanePolicy::Auto,
                routing: BTreeMap::new(),
            })
            .await
            .unwrap();
        tokio::time::timeout(
            STEP_TIMEOUT,
            ClientConnection::connect(
                group,
                ClientConnectionConfig {
                    identity: self.identity.clone(),
                    expected_daemon: Some(self.daemon_public_key),
                    auth,
                    device_name: "client-capacity-e2e".into(),
                    session,
                    lane_policy: LanePolicy::Auto,
                    limits: SessionLimits::default(),
                    reconnect: ReconnectPolicy {
                        maximum_attempts: Some(1),
                        ..ReconnectPolicy::default()
                    },
                },
            ),
        )
        .await
        .expect("connect did not settle")
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_full_daemon_refuses_a_new_session_as_too_many_clients_until_a_slot_frees() {
    let state = tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(state.path(), "client-capacity-e2e", false).unwrap();
    let (daemon, mut accepted) = RemoteDaemon::with_client_limit(
        auth.clone(),
        SessionLimits::default(),
        DaemonSessionPolicy::default(),
        CLIENT_LIMIT,
    )
    .unwrap();
    assert_eq!(daemon.client_limit(), CLIENT_LIMIT);
    // Keep the daemon's accepted-client queue drained.
    let drain = tokio::spawn(async move {
        let mut kept = Vec::new();
        while let Some(connection) = accepted.recv().await {
            kept.push(connection);
        }
    });
    let websocket = serve_direct_websocket(
        daemon.clone(),
        "127.0.0.1:0".parse().unwrap(),
        MAXIMUM_FRAME_BYTES,
        false,
    )
    .await
    .unwrap();
    let dialer = Dialer {
        provider: DirectWebSocketProvider::new(MAXIMUM_FRAME_BYTES),
        endpoint: Url::parse(&format!("ws://{}/v1/link", websocket.local_addr())).unwrap(),
        daemon_public_key: auth.identity().public_key(),
        identity: StaticIdentity::generate().unwrap(),
    };

    // Enroll the device with the first session, then fill the daemon.
    let invitation = auth.create_invitation(Duration::from_secs(60), Vec::new()).await.unwrap();
    let approver = tokio::spawn({
        let auth = auth.clone();
        async move {
            let pending = auth.wait_for_pending(STEP_TIMEOUT).await.unwrap();
            auth.approve(&pending[0].invitation_id).await.unwrap()
        }
    });
    let first_session = SessionId([0xc1; 16]);
    let first = dialer
        .connect(
            ClientAuthMode::Invitation {
                id: invitation.id.clone(),
                secret: Zeroizing::new(invitation.secret_bytes().unwrap()),
            },
            first_session,
        )
        .await
        .expect("the first session fits");
    let device = approver.await.unwrap();
    let second = dialer
        .connect(ClientAuthMode::Enrolled, SessionId([0xc2; 16]))
        .await
        .expect("the second session fits: each session's links share one slot");

    // One more is refused with the reason, not as an expired session.
    let third_session = SessionId([0xc3; 16]);
    match dialer.connect(ClientAuthMode::Enrolled, third_session).await {
        Err(error @ ConnectionError::DaemonAtCapacity { limit }) => {
            assert_eq!(limit, Some(CLIENT_LIMIT));
            assert!(error.is_retryable_carrier_failure());
            let message = error.to_string();
            assert!(message.contains("too many connected clients"), "{message}");
            assert!(!message.contains("expired"), "{message}");
        }
        Err(error) => panic!("a full daemon refused with the wrong error: {error}"),
        Ok(_) => panic!("a full daemon admitted a session past its limit"),
    }
    // The connected sessions are untouched by the refusal.
    assert_eq!(daemon.connections().await.len(), CLIENT_LIMIT);

    // Ending a session frees its slot; a retry then gets in.
    assert!(daemon.disconnect(&device.id, first_session).await.unwrap());
    let _ = first.close().await;
    let deadline = tokio::time::Instant::now() + STEP_TIMEOUT;
    let third = loop {
        match dialer.connect(ClientAuthMode::Enrolled, third_session).await {
            Ok(connection) => break connection,
            Err(ConnectionError::DaemonAtCapacity { .. })
                if tokio::time::Instant::now() < deadline =>
            {
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
            Err(error) => panic!("the retry after a slot freed failed: {error}"),
        }
    };
    assert_eq!(daemon.connections().await.len(), CLIENT_LIMIT);

    let _ = second.close().await;
    let _ = third.close().await;
    websocket.shutdown().await.unwrap();
    drain.abort();
}
