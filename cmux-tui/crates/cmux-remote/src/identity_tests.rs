#[test]
fn identity_refusals_name_the_command_that_lists_the_ids() {
    assert!(IdentityError::UnknownPending("x".into()).to_string().contains("enroll pending"));
    assert!(IdentityError::UnknownDevice("x".into()).to_string().contains("enroll devices"));
    assert!(IdentityError::InvitationExpired("x".into()).to_string().contains("enroll create"));
}

use super::*;
use crate::crypto::NetworkPeer;
use cmux_remote_protocol::{Lane, SessionId};

/// Long enough that only an approval wait reaches it; a bound claim
/// answers at once.
const BOUND_CLAIM_DEADLINE: Duration = Duration::from_secs(10);

fn invitation_request(
    invitation_id: &str,
    device: &StaticIdentity,
    device_name: &str,
) -> AuthRequest {
    AuthRequest {
        mode: AuthKind::Invitation,
        invitation_id: Some(invitation_id.into()),
        grant: None,
        connection_attempt: ConnectionAttemptId([7; 16]),
        device_public_key: device.public_key(),
        device_name: device_name.into(),
        session: SessionId([9; 16]),
        lane: Lane::Interactive,
        lanes: vec![Lane::Interactive],
        generation: 0,
        inbound: InboundAuthEvidence::Network(NetworkPeer::Tcp),
    }
}

async fn bound_invitation(
    auth: &AuthDatabase,
    device: &StaticIdentity,
    name: Option<&str>,
) -> EnrollmentInvitation {
    let bound =
        BoundDevice::parse(&encode_key(&device.public_key()), name.map(Into::into)).unwrap();
    auth.create_invitation_for_device(Duration::from_secs(60), Vec::new(), Vec::new(), Some(bound))
        .await
        .unwrap()
}

async fn claim(auth: &Arc<AuthDatabase>, request: AuthRequest) -> Result<AuthGrant, String> {
    let auth = Arc::clone(auth);
    tokio::time::timeout(BOUND_CLAIM_DEADLINE, async move { auth.authorize(request).await })
        .await
        .expect("a bound invitation answers at once, never waiting for an approval")
}

#[tokio::test]
async fn a_bound_invitation_refuses_another_device_and_queues_nothing() {
    let directory = tempfile::tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(directory.path(), "bound", false).unwrap();
    let bound = StaticIdentity::generate().unwrap();
    let stranger = StaticIdentity::generate().unwrap();
    let invitation = bound_invitation(&auth, &bound, None).await;
    assert!(!invitation.approval_required);

    let error =
        claim(&auth, invitation_request(&invitation.id, &stranger, "stranger")).await.unwrap_err();

    assert_eq!(error, "invitation is bound to another device");
    assert!(auth.pending_enrollments().await.is_empty());
    assert!(matches!(
        auth.wait_for_pending(Duration::from_millis(50)).await,
        Err(IdentityError::Timeout)
    ));
    assert!(auth.list_devices().await.is_empty());
    // The refusal leaves the invitation to its device.
    let grant = claim(&auth, invitation_request(&invitation.id, &bound, "bound")).await;
    assert_eq!(grant.unwrap().device_id, bound.fingerprint());
}

#[tokio::test]
async fn a_bound_invitation_enrolls_its_device_with_no_approval() {
    let directory = tempfile::tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(directory.path(), "bound", false).unwrap();
    let device = StaticIdentity::generate().unwrap();
    let invitation = bound_invitation(&auth, &device, Some("agent-vm")).await;

    let grant =
        claim(&auth, invitation_request(&invitation.id, &device, "client-name")).await.unwrap();

    assert_eq!(grant.device_id, device.fingerprint());
    assert!(auth.grant_is_current(&grant).await);
    assert!(auth.pending_enrollments().await.is_empty());
    let devices = auth.list_devices().await;
    assert_eq!(devices.len(), 1);
    assert_eq!(devices[0].fingerprint, device.fingerprint());
    assert_eq!(devices[0].public_key, encode_key(&device.public_key()));
    // The owner's name for the device wins over the one the client sends.
    assert_eq!(devices[0].name, "agent-vm");
    {
        let state = auth.state.lock().await;
        let record = &state.invitations[&invitation.id];
        assert_eq!(record.claimed_by.as_deref(), Some(device.fingerprint().as_str()));
    }
    // The same device may present the invitation again within its retry grace.
    let again =
        claim(&auth, invitation_request(&invitation.id, &device, "client-name")).await.unwrap();
    assert_eq!(again.device_id, device.fingerprint());
    // Once enrolled, the device needs no invitation at all.
    let mut enrolled = invitation_request(&invitation.id, &device, "client-name");
    enrolled.mode = AuthKind::Enrolled;
    enrolled.invitation_id = None;
    assert_eq!(auth.authorize(enrolled).await.unwrap().device_id, device.fingerprint());
}

#[tokio::test]
async fn a_bound_invitation_survives_a_daemon_restart() {
    let directory = tempfile::tempdir().unwrap();
    let device = StaticIdentity::generate().unwrap();
    let stranger = StaticIdentity::generate().unwrap();
    let invitation = {
        let auth = AuthDatabase::load_or_create(directory.path(), "bound", false).unwrap();
        let invitation = bound_invitation(&auth, &device, Some("agent-vm")).await;
        auth.shutdown().await.unwrap();
        invitation
    };
    let persisted = fs::read_to_string(directory.path().join("devices.json")).unwrap();
    assert!(persisted.contains(&encode_key(&device.public_key())), "{persisted}");

    let auth = AuthDatabase::load_or_create(directory.path(), "bound", false).unwrap();
    let error =
        claim(&auth, invitation_request(&invitation.id, &stranger, "stranger")).await.unwrap_err();
    assert_eq!(error, "invitation is bound to another device");
    let grant = claim(&auth, invitation_request(&invitation.id, &device, "client")).await.unwrap();
    assert_eq!(grant.device_id, device.fingerprint());
    assert_eq!(auth.list_devices().await[0].name, "agent-vm");
}

#[tokio::test]
async fn revoking_a_device_enrolled_by_a_bound_invitation_cuts_it_off() {
    let directory = tempfile::tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(directory.path(), "bound", false).unwrap();
    let device = StaticIdentity::generate().unwrap();
    let invitation = bound_invitation(&auth, &device, None).await;
    let grant = claim(&auth, invitation_request(&invitation.id, &device, "agent")).await.unwrap();

    let revoked = auth.revoke(&grant.device_id).await.unwrap();

    // The reply names the device, so `enroll revoke` can say which one.
    assert_eq!(revoked.id, grant.device_id);
    assert_eq!(revoked.fingerprint, device.fingerprint());
    assert!(revoked.revoked_at_unix.is_some());
    assert!(!auth.grant_is_current(&grant).await);
    assert!(!auth.device_is_active(&grant.device_id).await);
    let error =
        claim(&auth, invitation_request(&invitation.id, &device, "agent")).await.unwrap_err();
    assert_eq!(error, "device enrollment is no longer active");
}

/// Review finding P1-F1: a second, unused invitation bound to the same
/// key must not re-enroll a device the owner revoked.
#[tokio::test]
async fn revoking_a_device_voids_its_unused_bound_invitations() {
    let directory = tempfile::tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(directory.path(), "bound", false).unwrap();
    let device = StaticIdentity::generate().unwrap();
    let other = StaticIdentity::generate().unwrap();
    let first = bound_invitation(&auth, &device, None).await;
    let spare = bound_invitation(&auth, &device, None).await;
    let others = bound_invitation(&auth, &other, None).await;
    let grant = claim(&auth, invitation_request(&first.id, &device, "agent")).await.unwrap();

    auth.revoke(&grant.device_id).await.unwrap();

    let error = claim(&auth, invitation_request(&spare.id, &device, "agent")).await.unwrap_err();
    assert_eq!(error, "invitation is unknown or expired");
    assert!(!auth.device_is_active(&grant.device_id).await);
    // Voided durably: a restarted daemon has no such invitation either.
    auth.shutdown().await.unwrap();
    drop(auth);
    let auth = AuthDatabase::load_or_create(directory.path(), "bound", false).unwrap();
    let error = claim(&auth, invitation_request(&spare.id, &device, "agent")).await.unwrap_err();
    assert_eq!(error, "invitation is unknown or expired");
    assert!(!auth.device_is_active(&grant.device_id).await);
    // Another device's bound invitation is untouched.
    assert!(claim(&auth, invitation_request(&others.id, &other, "other")).await.is_ok());
    // The owner can still re-enroll the device on purpose, with a new invitation.
    let fresh = bound_invitation(&auth, &device, None).await;
    let regrant = claim(&auth, invitation_request(&fresh.id, &device, "agent")).await;
    assert!(auth.device_is_active(&regrant.unwrap().device_id).await);
}

#[tokio::test]
async fn an_expired_bound_invitation_is_refused() {
    let directory = tempfile::tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(directory.path(), "bound", false).unwrap();
    let device = StaticIdentity::generate().unwrap();
    let invitation = bound_invitation(&auth, &device, None).await;
    auth.state.lock().await.invitations.get_mut(&invitation.id).unwrap().expires_at_unix =
        unix_time().unwrap() - 1;

    let error =
        claim(&auth, invitation_request(&invitation.id, &device, "agent")).await.unwrap_err();

    assert_eq!(error, "invitation is expired");
    assert!(auth.list_devices().await.is_empty());
}

#[tokio::test]
async fn bound_invitations_keep_the_live_invitation_limit() {
    let directory = tempfile::tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(directory.path(), "bound", false).unwrap();
    let device = StaticIdentity::generate().unwrap();
    for _ in 0..MAX_LIVE_INVITATIONS {
        bound_invitation(&auth, &device, None).await;
    }
    let bound = BoundDevice::parse(&encode_key(&device.public_key()), None).unwrap();
    let error = auth
        .create_invitation_for_device(Duration::from_secs(60), Vec::new(), Vec::new(), Some(bound))
        .await
        .unwrap_err();
    assert!(error.to_string().contains("maximum invitation count"), "{error}");
}

#[test]
fn a_bound_device_needs_a_32_byte_key_and_a_plain_name() {
    let key = encode_key(&[7; 32]);
    assert!(BoundDevice::parse(&key, None).is_ok());
    assert_eq!(BoundDevice::parse(&key, Some(" vm ".into())).unwrap().name.unwrap(), "vm");
    assert!(BoundDevice::parse(&encode_key(&[7; 32])[..20], None).is_err());
    assert!(BoundDevice::parse("not base64!", None).is_err());
    assert!(BoundDevice::parse(&key, Some("  ".into())).is_err());
    assert!(BoundDevice::parse(&key, Some("a\nb".into())).is_err());
    assert!(BoundDevice::parse(&key, Some("x".repeat(129))).is_err());
}

#[tokio::test]
async fn state_written_before_bound_invitations_loads_them_unbound() {
    let directory = tempfile::tempdir().unwrap();
    let expires_at_unix = unix_time().unwrap() + 120;
    let old_state = serde_json::json!({
        "version": AUTH_STATE_VERSION,
        "revision": 3,
        "revocation_generation": 0,
        "devices": [],
        "invitations": [{
            "id": "old-invitation",
            "secret": encode_key(&[5; 32]),
            "expires_at_unix": expires_at_unix,
            "route_hints": [],
            "claimed_by": null,
        }],
    });
    fs::write(directory.path().join("devices.json"), old_state.to_string()).unwrap();

    let auth = AuthDatabase::load_or_create(directory.path(), "old", false).unwrap();

    {
        let state = auth.state.lock().await;
        let invitation = &state.invitations["old-invitation"];
        assert!(invitation.bound_device.is_none());
        assert_eq!(invitation.expires_at_unix, expires_at_unix);
    }
    // An unbound invitation still waits for the owner's approval.
    let device = StaticIdentity::generate().unwrap();
    let request = invitation_request("old-invitation", &device, "old-client");
    let attempt = tokio::spawn({
        let auth = Arc::clone(&auth);
        async move { auth.authorize(request).await }
    });
    let pending = auth.wait_for_pending(BOUND_CLAIM_DEADLINE).await.unwrap();
    assert_eq!(pending[0].device_fingerprint, device.fingerprint());
    auth.approve("old-invitation").await.unwrap();
    assert_eq!(attempt.await.unwrap().unwrap().device_id, device.fingerprint());
}

#[tokio::test]
async fn a_binding_that_does_not_decode_drops_its_invitation() {
    let directory = tempfile::tempdir().unwrap();
    let state = serde_json::json!({
        "version": AUTH_STATE_VERSION,
        "invitations": [{
            "id": "damaged",
            "secret": encode_key(&[5; 32]),
            "expires_at_unix": unix_time().unwrap() + 120,
            "route_hints": [],
            "bound_device": "not-a-key",
        }],
    });
    fs::write(directory.path().join("devices.json"), state.to_string()).unwrap();

    let auth = AuthDatabase::load_or_create(directory.path(), "damaged", false).unwrap();

    assert!(auth.state.lock().await.invitations.is_empty());
}

#[test]
fn credential_free_routes_preserve_only_reconnect_material() {
    assert_eq!(credential_free_daemon_name("daemon:dev".into()), "daemon:dev");

    let websocket = url::Url::parse(
        &credential_free_route_hint(
            "wss://user:password@example.test/private?ticket=secret#fragment",
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(websocket.as_str(), "wss://example.test/");

    let ssh = url::Url::parse(
        &credential_free_route_hint(
            "ssh://alice:password@example.test:2222/private?ticket=secret#fragment",
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(ssh.username(), "alice");
    assert_eq!(ssh.password(), None);
    assert_eq!(ssh.host_str(), Some("example.test"));
    assert_eq!(ssh.port(), Some(2222));
    assert!(matches!(ssh.path(), "" | "/"));
    assert!(ssh.query().is_none());
    assert!(ssh.fragment().is_none());

    let unix = url::Url::parse(
        &credential_free_route_hint("unix:///tmp/cmux-remote.sock?ticket=secret#fragment").unwrap(),
    )
    .unwrap();
    assert_eq!(unix.path(), "/tmp/cmux-remote.sock");
    assert!(unix.query().is_none());
    assert!(unix.fragment().is_none());

    let iroh = url::Url::parse(
        &credential_free_route_hint(
            "iroh://node-id?direct=127.0.0.1%3A7777&relay=\
                 https%3A%2F%2Fuser%3Apassword%40relay.test%2Fprivate%3Fticket%3Dsecret&\
                 ticket=drop-me",
        )
        .unwrap(),
    )
    .unwrap();
    let routing = iroh.query_pairs().into_owned().collect::<HashMap<_, _>>();
    assert_eq!(routing["direct"], "127.0.0.1:7777");
    assert_eq!(routing["relay"], "https://relay.test/");
    assert!(!routing.contains_key("ticket"));
}
