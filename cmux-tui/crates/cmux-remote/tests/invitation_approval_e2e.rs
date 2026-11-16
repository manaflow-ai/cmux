//! An invitation's welcome waits on a person's approval, which may take far longer than a link
//! attempt's deadline: the deadline on the daemon's link-ready (`authenticate_one`) starts once the
//! welcome is in, so a slow approval still enrolls. Every frame the client receives comes a moment
//! after the one before, so link-ready is never already waiting when the welcome is read.

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use bytes::Bytes;
use cmux_remote::connection::{ClientConnection, ClientConnectionConfig, ReconnectPolicy};
use cmux_remote::crypto::{ClientAuthMode, StaticIdentity};
use cmux_remote::daemon::{RemoteDaemon, serve_direct_websocket};
use cmux_remote::identity::AuthDatabase;
use cmux_remote::link::{FrameLink, LinkError};
use cmux_remote::provider::{
    CarrierEvidence, ConnectRequest, DirectWebSocketProvider, LinkGroup, LinkRequest,
    ProviderCapabilities, ProviderError, TransportProvider,
};
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
/// Between two frames the client receives.
const FRAME_GAP: Duration = Duration::from_millis(50);

/// A link whose every received frame comes `FRAME_GAP` after it arrived.
struct Spaced(Box<dyn FrameLink>);

#[async_trait]
impl FrameLink for Spaced {
    fn description(&self) -> &str {
        self.0.description()
    }
    fn maximum_frame_bytes(&self) -> usize {
        self.0.maximum_frame_bytes()
    }
    async fn send(&self, frame: Bytes) -> Result<(), LinkError> {
        self.0.send(frame).await
    }
    async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
        let frame = self.0.receive().await;
        tokio::time::sleep(FRAME_GAP).await;
        frame
    }
    async fn close(&self) -> Result<(), LinkError> {
        self.0.close().await
    }
}

struct SpacedGroup(Arc<dyn LinkGroup>);

#[async_trait]
impl LinkGroup for SpacedGroup {
    fn description(&self) -> &str {
        self.0.description()
    }
    fn capabilities(&self) -> ProviderCapabilities {
        self.0.capabilities()
    }
    fn evidence(&self) -> &CarrierEvidence {
        self.0.evidence()
    }
    async fn open(&self, request: LinkRequest) -> Result<Box<dyn FrameLink>, ProviderError> {
        Ok(Box::new(Spaced(self.0.open(request).await?)))
    }
    async fn close(&self) -> Result<(), ProviderError> {
        self.0.close().await
    }
}

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
            Arc::new(SpacedGroup(group)),
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

struct Enrollment {
    auth: Arc<AuthDatabase>,
    invitation: cmux_remote::identity::EnrollmentInvitation,
    endpoint: Url,
    _websocket: cmux_remote::daemon::DirectWebSocketServer,
    _state: tempfile::TempDir,
}

async fn enrollment(name: &str) -> Enrollment {
    let state = tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(state.path(), name, false).unwrap();
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
    Enrollment { auth, invitation, endpoint, _websocket: websocket, _state: state }
}

/// One first-connect attempt of `identity` presenting the invitation, as `remote connect
/// --invite-file` makes it.
async fn present_invitation(
    enrollment: &Enrollment,
    identity: StaticIdentity,
    device_name: &str,
    session: SessionId,
) -> Result<Arc<ClientConnection>, cmux_remote::connection::ConnectionError> {
    let group = DirectWebSocketProvider::new(MAXIMUM_FRAME_BYTES)
        .connect(ConnectRequest {
            endpoint: enrollment.endpoint.clone(),
            session,
            lane_policy: LanePolicy::Single,
            routing: Default::default(),
        })
        .await
        .unwrap();
    ClientConnection::connect(
        group,
        ClientConnectionConfig {
            identity,
            expected_daemon: Some(enrollment.auth.identity().public_key()),
            auth: ClientAuthMode::Invitation {
                id: enrollment.invitation.id.clone(),
                secret: Zeroizing::new(enrollment.invitation.secret_bytes().unwrap()),
            },
            device_name: device_name.into(),
            session,
            lane_policy: LanePolicy::Single,
            limits: SessionLimits::default(),
            reconnect: ReconnectPolicy { maximum_attempts: Some(1), ..ReconnectPolicy::default() },
        },
    )
    .await
}

/// Waits until the daemon lists a pending request from `device_name` for the invitation.
async fn pending_from(auth: &AuthDatabase, invitation_id: &str, device_name: &str) {
    loop {
        if auth
            .pending_enrollments()
            .await
            .iter()
            .any(|p| p.invitation_id == invitation_id && p.device_name == device_name)
        {
            return;
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
}

/// Rebake run 43419757535, size lg: `remote connect --invite-file` failed with "authorization
/// failed: invitation already has a pending enrollment". The client abandoned its first attempt
/// while it waited on the approval (a network change on the freshly resized machine drops the
/// attempt in flight, `LinkCell::dial`) and presented the invitation again at once; the daemon
/// still held the abandoned attempt's request and refused the device's own redial, which the
/// client takes as permanent. The same device presenting the invitation again takes over its
/// request, and the person's approval enrolls the link the device is on now.
#[tokio::test(flavor = "current_thread")]
async fn a_device_that_presents_its_invitation_again_while_pending_still_enrolls() {
    tokio::time::timeout(TEST_TIMEOUT, async {
        let enrollment = enrollment("invitation-represented-e2e").await;
        let id = enrollment.invitation.id.clone();
        let identity = StaticIdentity::generate().unwrap();
        let session = SessionId([0x2b; 16]);

        // The first attempt reaches the approval wait, then its client abandons it.
        let first = present_invitation(&enrollment, identity.clone(), "attempt-1", session);
        tokio::select! {
            result = first => panic!("the first attempt ended before its approval: {:?}", result.err()),
            () = pending_from(&enrollment.auth, &id, "attempt-1") => {}
        }

        // The redial presents the same invitation from the same device.
        let second = present_invitation(&enrollment, identity, "attempt-2", session);
        tokio::pin!(second);
        tokio::select! {
            result = &mut second => panic!(
                "the device's own redial was refused while its first request was pending: {:?}",
                result.err()
            ),
            () = pending_from(&enrollment.auth, &id, "attempt-2") => {}
        }
        assert_eq!(enrollment.auth.pending_enrollments().await.len(), 1);
        enrollment.auth.approve(&id).await.unwrap();
        let connection = second.await.expect("the approval enrolls the device's current link");
        connection.close().await.unwrap();
    })
    .await
    .expect("the enrollment finished");
}

/// The security rule stays: while one device's request is pending, another device presenting the
/// same invitation is refused and does not displace it.
#[tokio::test(flavor = "current_thread")]
async fn another_device_cannot_take_over_a_pending_invitation() {
    tokio::time::timeout(TEST_TIMEOUT, async {
        let enrollment = enrollment("invitation-other-device-e2e").await;
        let id = enrollment.invitation.id.clone();
        let session = SessionId([0x3c; 16]);

        let first =
            present_invitation(&enrollment, StaticIdentity::generate().unwrap(), "owner", session);
        tokio::pin!(first);
        tokio::select! {
            result = &mut first => panic!("the first attempt ended before its approval: {:?}", result.err()),
            () = pending_from(&enrollment.auth, &id, "owner") => {}
        }

        let error = match present_invitation(
            &enrollment,
            StaticIdentity::generate().unwrap(),
            "intruder",
            SessionId([0x4d; 16]),
        )
        .await
        {
            Ok(_) => panic!("another device took over a pending invitation"),
            Err(error) => error,
        };
        assert!(
            error.to_string().contains("invitation already has a pending enrollment"),
            "unexpected refusal: {error}"
        );
        let pending = enrollment.auth.pending_enrollments().await;
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].device_name, "owner");

        enrollment.auth.approve(&id).await.unwrap();
        let connection = first.await.expect("the first device still enrolls");
        connection.close().await.unwrap();
    })
    .await
    .expect("the enrollment finished");
}
