//! An invitation's welcome waits on a person's approval, which may take far longer than a link
//! attempt's deadline: the deadline on the daemon's link-ready (`authenticate_one`) starts once the
//! welcome is in, so a slow approval still enrolls.

use std::time::Duration;

use cmux_remote::connection::{ClientConnection, ClientConnectionConfig, ReconnectPolicy};
use cmux_remote::crypto::{ClientAuthMode, StaticIdentity};
use cmux_remote::daemon::{RemoteDaemon, serve_direct_websocket};
use cmux_remote::identity::AuthDatabase;
use cmux_remote::provider::{ConnectRequest, DirectWebSocketProvider, TransportProvider};
use cmux_remote::session::SessionLimits;
use cmux_remote_protocol::{LanePolicy, SessionId};
use tempfile::tempdir;
use url::Url;
use zeroize::Zeroizing;

const MAXIMUM_FRAME_BYTES: usize = 65_535;
const TEST_TIMEOUT: Duration = Duration::from_secs(30);
/// Each link attempt's deadline, well under the approval's delay.
const ATTEMPT_TIMEOUT: Duration = Duration::from_millis(300);
const APPROVAL_DELAY: Duration = Duration::from_millis(1_500);

#[tokio::test(flavor = "current_thread")]
async fn an_invitation_approved_after_the_attempt_deadline_still_enrolls() {
    tokio::time::timeout(TEST_TIMEOUT, async {
        let auth_state = tempdir().unwrap();
        let auth =
            AuthDatabase::load_or_create(auth_state.path(), "invitation-approval-e2e", false)
                .unwrap();
        let (daemon, _accepted) = RemoteDaemon::new(auth.clone(), SessionLimits::default());
        let websocket = serve_direct_websocket(
            daemon.clone(),
            "127.0.0.1:0".parse().unwrap(),
            MAXIMUM_FRAME_BYTES,
            false,
        )
        .await
        .unwrap();
        let endpoint = Url::parse(&format!("ws://{}/v1/link", websocket.local_addr())).unwrap();
        let invitation = auth.create_invitation(Duration::from_secs(60), Vec::new()).await.unwrap();

        // The person approves well after the attempt's deadline.
        let approval = tokio::spawn({
            let auth = auth.clone();
            let id = invitation.id.clone();
            async move {
                loop {
                    if auth.pending_enrollments().await.iter().any(|p| p.invitation_id == id) {
                        break;
                    }
                    tokio::time::sleep(Duration::from_millis(5)).await;
                }
                tokio::time::sleep(APPROVAL_DELAY).await;
                auth.approve(&id).await.unwrap()
            }
        });

        let session = SessionId([0x1a; 16]);
        let group = DirectWebSocketProvider::new(MAXIMUM_FRAME_BYTES)
            .connect(ConnectRequest {
                endpoint,
                session,
                lane_policy: LanePolicy::Single,
                routing: Default::default(),
            })
            .await
            .unwrap();
        let connection = ClientConnection::connect(
            group,
            ClientConnectionConfig {
                identity: StaticIdentity::generate().unwrap(),
                expected_daemon: Some(auth.identity().public_key()),
                auth: ClientAuthMode::Invitation {
                    id: invitation.id.clone(),
                    secret: Zeroizing::new(invitation.secret_bytes().unwrap()),
                },
                device_name: "invitation-approval".into(),
                session,
                lane_policy: LanePolicy::Single,
                limits: SessionLimits::default(),
                reconnect: ReconnectPolicy {
                    attempt_timeout: ATTEMPT_TIMEOUT,
                    maximum_attempts: Some(1),
                    ..ReconnectPolicy::default()
                },
            },
        )
        .await
        .expect("a slow approval enrolls: the link-ready deadline starts after the welcome");
        approval.await.unwrap();
        connection.close().await.unwrap();
    })
    .await
    .expect("the enrollment finished");
}
