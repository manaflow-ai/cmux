//! The client against an in-process hub: signed requests, registration, the
//! User DO socket, and approvals verified by the asking machine itself.

mod support;

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use base64::Engine as _;
use cmux_device_hub_client::{
    ApprovalAsk, ApprovalOutcome, ApprovalRequest, ApprovalTarget, Assurance, Backoff, Decision,
    DeviceIdentity, DeviceKeys as _, ErrorCode, FileKeyStore, HubApprover, HubClient,
    HubClientConfig, HubError, KeyStore as _, NoHubApprover, PING_FRAME, PinnedApprover, Platform,
    RemoteApprover, SocketOptions, SoftwareKeys, StaticToken, UserSocket, VerifiedDecision,
    decision_message, key_fingerprint,
};
use serde_json::json;
use support::{MockHub, STACK_TOKEN};

fn now_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() as i64
}

/// Another device of the account, with its own keys: a signing key (deny)
/// and an approval key (Allow), as the hub's `signingKey` and `approvalKey`.
struct Device {
    id: String,
    keys: SoftwareKeys,
    approval: SoftwareKeys,
}

impl Device {
    fn new() -> Device {
        Device {
            id: uuid::Uuid::new_v4().to_string(),
            keys: SoftwareKeys::generate(Assurance::Hardware).unwrap(),
            approval: SoftwareKeys::generate(Assurance::Hardware).unwrap(),
        }
    }

    fn approval_key(&self) -> String {
        base64::engine::general_purpose::STANDARD.encode(self.approval.signing_public_key())
    }

    fn signing_key(&self) -> String {
        base64::engine::general_purpose::STANDARD.encode(self.keys.signing_public_key())
    }

    /// What the box owner pins for this device at setup.
    fn pin(&self) -> PinnedApprover {
        PinnedApprover {
            device_id: self.id.clone(),
            approval_key_fingerprint: key_fingerprint(&self.approval_key()).unwrap(),
        }
    }

    fn sign(&self, digest: &str, decision: Decision) -> String {
        // An Allow with the approval key, a deny with the signing key.
        let keys = if decision == Decision::Deny { &self.keys } else { &self.approval };
        let signature = keys.sign(decision_message(digest, decision).as_bytes()).unwrap();
        base64::engine::general_purpose::STANDARD.encode(signature)
    }
}

struct Rig {
    hub: MockHub,
    identity: DeviceIdentity,
    client: Arc<HubClient>,
    socket: Option<UserSocket>,
    approver: HubApprover,
    phone: Device,
    /// Pinned with the phone, but not on the hub until a test adds it.
    mac: Device,
    _dir: tempfile::TempDir,
}

fn options() -> SocketOptions {
    SocketOptions {
        ping_interval: Duration::from_millis(100),
        connect_timeout: Duration::from_secs(5),
        backoff: Backoff::new(Duration::from_millis(20), Duration::from_millis(100)),
        event_capacity: 64,
    }
}

impl Rig {
    /// A registered Linux machine with its socket open and an iPhone on the
    /// account; the owner pinned the iPhone and a Mac.
    async fn new() -> Rig {
        let phone = Device::new();
        let mac = Device::new();
        let pins = vec![phone.pin(), mac.pin()];
        Rig::pinned(phone, mac, pins).await
    }

    async fn pinned(phone: Device, mac: Device, pins: Vec<PinnedApprover>) -> Rig {
        let hub = MockHub::start().await;
        let dir = tempfile::tempdir().unwrap();
        let identity = FileKeyStore::new(dir.path(), Platform::Linux).load_or_create().unwrap();
        let mut config = HubClientConfig::new(
            hub.base_url(),
            identity.clone(),
            Arc::new(StaticToken(STACK_TOKEN.to_owned())),
        );
        config.allow_http = true;
        let client = Arc::new(HubClient::new(config).unwrap());
        client.register_device("build-box-7").await.unwrap();
        hub.add_approver(&phone.id, "ios", &phone.signing_key(), &phone.approval_key());
        let socket = UserSocket::spawn(Arc::clone(&client), options());
        let approver = HubApprover::new(Arc::clone(&client), socket.events(), pins);
        hub.wait_connections(1).await;
        Rig { hub, identity, client, socket: Some(socket), approver, phone, mac, _dir: dir }
    }

    fn me(&self) -> &str {
        self.identity.id()
    }

    fn request(&self, wait_ms: i64, answerable_ms: i64) -> ApprovalRequest {
        let now = now_ms();
        ApprovalRequest {
            v: 1,
            nonce: uuid::Uuid::new_v4().simple().to_string(),
            client: "com.cmuxterm.app.debug.cu1".into(),
            machine: "build-box-7".into(),
            session: "c-41".into(),
            agent: "Claude".into(),
            workspace: "api-server".into(),
            target: ApprovalTarget {
                bundle_id: None,
                executable: Some("/usr/bin/gedit".into()),
                name: "gedit".into(),
            },
            tool: "click".into(),
            risk: "R1".into(),
            created_ms: now,
            wait_until_ms: now + wait_ms,
            answerable_until_ms: now + answerable_ms,
            digest: String::new(),
        }
        .sealed()
        .unwrap()
    }

    /// Starts asking; returns the task and the hub's approval id.
    async fn ask(
        &self,
        request: &ApprovalRequest,
        allow_always: bool,
        on_late: Option<cmux_device_hub_client::LateDecisionHandler>,
    ) -> (tokio::task::JoinHandle<ApprovalOutcome>, String) {
        let approver = self.approver.clone();
        let ask = ApprovalAsk { request: request.clone(), allow_always, on_late };
        let task = tokio::spawn(async move { approver.ask(ask).await });
        let id = self.hub.next_approval().await;
        (task, id)
    }

    fn push_decided(&self, id: &str, decision: &str, digest: &str, decider: &str, sig: &str) {
        self.hub.push(
            self.me(),
            json!({"type": "approval.decided", "id": id, "decision": decision, "digest": digest,
                   "deciderId": decider, "sig": sig}),
        );
    }

    async fn stop(mut self) {
        if let Some(socket) = self.socket.take() {
            socket.shutdown().await;
        }
    }
}

fn decided(outcome: &ApprovalOutcome) -> &VerifiedDecision {
    match outcome {
        ApprovalOutcome::Decided(decision) => decision,
        other => panic!("expected a decision, got {other:?}"),
    }
}

async fn outcome(task: tokio::task::JoinHandle<ApprovalOutcome>) -> ApprovalOutcome {
    tokio::time::timeout(Duration::from_secs(10), task).await.expect("the ask ends").unwrap()
}

#[tokio::test]
async fn registration_is_signed_with_the_key_it_registers() {
    let rig = Rig::new().await;
    let registered = rig.hub.device(rig.me()).expect("registered");
    assert_eq!(registered["platform"], "linux");
    assert_eq!(registered["assurance"], "file");
    assert_eq!(registered["signingKey"], rig.identity.signing_key_base64());
    assert_eq!(registered["agreementKey"], rig.identity.agreement_key_base64());
    assert_ne!(registered["signingKey"], registered["agreementKey"]);
    let log = rig.hub.log();
    let registration =
        log.iter().find(|entry| entry.method == "POST" && entry.path == "/v1/devices").unwrap();
    assert_eq!(registration.device_id, rig.me());
    let me = rig.client.me().await.unwrap();
    assert_eq!(me.user_id, "proj:user");
    assert_eq!(me.device.unwrap().id, rig.me());
    assert!(rig.hub.refused().is_empty(), "{:?}", rig.hub.refused());
    rig.stop().await;
}

#[tokio::test]
async fn request_headers_match_the_hub_canonical_string() {
    let rig = Rig::new().await;
    let devices = rig.client.devices().await.unwrap();
    assert!(
        devices.iter().any(|device| device.id == rig.phone.id && device.platform == Platform::Ios)
    );
    let request = rig.request(60_000, 120_000);
    let approval = rig.client.create_approval(&request, false).await.unwrap();
    let log = rig.hub.log();
    let get = log
        .iter()
        .rev()
        .find(|entry| entry.method == "GET" && entry.path == "/v1/devices")
        .unwrap();
    let lines: Vec<&str> = get.canonical.split('\n').collect();
    assert_eq!(lines.len(), 4);
    assert_eq!((lines[0], lines[1], lines[3]), ("GET", "/v1/devices", ""));
    assert!((lines[2].parse::<i64>().unwrap() - now_ms() / 1000).abs() <= 5);
    let post =
        log.iter().find(|entry| entry.method == "POST" && entry.path == "/v1/approvals").unwrap();
    let lines: Vec<&str> = post.canonical.split('\n').collect();
    assert_eq!((lines[0], lines[1]), ("POST", "/v1/approvals"));
    assert_eq!(lines[3].len(), 64);
    let socket = log.iter().find(|entry| entry.path == "/v1/user/ws").unwrap();
    assert!(socket.canonical.starts_with("GET\n/v1/user/ws\n") && socket.canonical.ends_with('\n'));
    assert_eq!(rig.client.approval(&approval.id).await.unwrap().id, approval.id);
    assert!(rig.hub.refused().is_empty(), "{:?}", rig.hub.refused());
    rig.stop().await;
}

#[tokio::test]
async fn hub_errors_carry_their_code() {
    let rig = Rig::new().await;
    let mut request = rig.request(60_000, 120_000);
    request.tool = "type".into();
    match rig.client.create_approval(&request, false).await {
        Err(HubError::Server { status: 400, code: ErrorCode::DigestMismatch, .. }) => {}
        other => panic!("expected digest_mismatch, got {other:?}"),
    }
    let request = rig.request(60_000, 120_000);
    let approval = rig.client.create_approval(&request, false).await.unwrap();
    // A Linux machine is never an approver (and never of its own question).
    let sig = rig.phone.sign(&request.digest, Decision::Once);
    let error = rig
        .client
        .decide_approval(&approval.id, Decision::Once, &request.digest, &sig)
        .await
        .unwrap_err();
    assert_eq!(error.code(), Some(&ErrorCode::SelfApproval));
    rig.stop().await;
}

#[tokio::test]
async fn the_socket_pings_with_the_exact_frame() {
    let rig = Rig::new().await;
    let mut events = rig.socket.as_ref().unwrap().subscribe();
    // Two pings at 100 ms; the pongs are not reported as pushes.
    let deadline = Instant::now() + Duration::from_secs(5);
    while rig.hub.pings().len() < 2 && Instant::now() < deadline {
        let _ = tokio::time::timeout(Duration::from_millis(150), events.recv()).await;
    }
    let pings = rig.hub.pings();
    assert!(pings.len() >= 2, "{pings:?}");
    assert!(pings.iter().all(|ping| ping == PING_FRAME && ping == r#"{"type":"ping"}"#));
    rig.stop().await;
}

#[tokio::test]
async fn a_verified_decision_from_the_phone_applies() {
    let rig = Rig::new().await;
    for (decision, allow_always) in [
        (Decision::Once, false),
        (Decision::Session, false),
        (Decision::Deny, false),
        (Decision::Always, true),
    ] {
        let request = rig.request(5_000, 60_000);
        let (task, id) = rig.ask(&request, allow_always, None).await;
        let sig = rig.phone.sign(&request.digest, decision);
        rig.push_decided(&id, decision.as_str(), &request.digest, &rig.phone.id, &sig);
        let outcome = outcome(task).await;
        let verified = decided(&outcome);
        assert_eq!(verified.decision, decision);
        assert_eq!(verified.decider_id, rig.phone.id);
        assert_eq!(verified.approval_id, id);
        assert_eq!(verified.via(), "phone");
    }
    rig.stop().await;
}

/// Pushes `bad` evidence and expects the question to stay open until its
/// deadline: the call times out.
async fn refused(rig: &Rig, allow_always: bool, bad: impl FnOnce(&ApprovalRequest, &str)) {
    let request = rig.request(700, 60_000);
    let (task, id) = rig.ask(&request, allow_always, None).await;
    bad(&request, &id);
    let started = Instant::now();
    assert_eq!(outcome(task).await, ApprovalOutcome::Timeout);
    assert!(
        started.elapsed() >= Duration::from_millis(200),
        "ended early: the bad decision was acted on"
    );
}

#[tokio::test]
async fn self_approval_is_refused() {
    let rig = Rig::new().await;
    refused(&rig, false, |request, id| {
        let own = rig
            .identity
            .sign_base64(decision_message(&request.digest, Decision::Once).as_bytes())
            .unwrap();
        rig.push_decided(id, "once", &request.digest, rig.me(), &own);
    })
    .await;
    rig.stop().await;
}

#[tokio::test]
async fn an_unknown_decider_is_refused_after_a_refetch() {
    let rig = Rig::new().await;
    let before = rig.hub.count("GET", "/v1/devices");
    let stranger = Device::new();
    refused(&rig, false, |request, id| {
        let sig = stranger.sign(&request.digest, Decision::Once);
        rig.push_decided(id, "once", &request.digest, &stranger.id, &sig);
    })
    .await;
    // One fetch when asking, one more for the unknown decider.
    assert!(rig.hub.count("GET", "/v1/devices") >= before + 2);
    rig.stop().await;
}

#[tokio::test]
async fn a_decider_added_after_the_question_is_found_by_refetching() {
    let rig = Rig::new().await;
    let request = rig.request(5_000, 60_000);
    let (task, id) = rig.ask(&request, false, None).await;
    let mac = &rig.mac;
    rig.hub.add_approver(&mac.id, "macos", &mac.signing_key(), &mac.approval_key());
    let sig = mac.sign(&request.digest, Decision::Session);
    rig.push_decided(&id, "session", &request.digest, &mac.id, &sig);
    let outcome = outcome(task).await;
    assert_eq!(decided(&outcome).decision, Decision::Session);
    assert_eq!(decided(&outcome).via(), "mac");
    rig.stop().await;
}

/// A device registered on the hub with platform `ios` and a valid signature
/// (anyone with an account session can register one: a stolen token, another
/// box of the user, a compromised hub) is not an approver this machine's owner
/// pinned, so its decision never applies.
#[tokio::test]
async fn a_forged_ios_device_on_the_hub_cannot_approve() {
    let rig = Rig::new().await;
    let forged = Device::new();
    rig.hub.add_approver(&forged.id, "ios", &forged.signing_key(), &forged.approval_key());
    refused(&rig, true, |request, id| {
        let sig = forged.sign(&request.digest, Decision::Always);
        rig.push_decided(id, "always", &request.digest, &forged.id, &sig);
    })
    .await;
    rig.stop().await;
}

/// The hub lists the pinned iPhone with another key (a swapped or
/// re-registered key): its decisions no longer apply, even signed with the
/// key the hub now lists.
#[tokio::test]
async fn a_pinned_device_whose_hub_key_changed_is_refused() {
    let phone = Device::new();
    let impostor = Device::new();
    let pins = vec![PinnedApprover { device_id: phone.id.clone(), ..impostor.pin() }];
    let rig = Rig::pinned(phone, Device::new(), pins).await;
    let request = rig.request(5_000, 60_000);
    let outcome = rig.approver.ask(ApprovalAsk { request, allow_always: false, on_late: None }).await;
    assert!(matches!(outcome, ApprovalOutcome::Unavailable(_)), "{outcome:?}");
    rig.stop().await;
}

/// No approver pinned: nothing is asked, whatever devices the account has.
#[tokio::test]
async fn with_no_pinned_approver_nothing_is_asked() {
    let rig = Rig::pinned(Device::new(), Device::new(), vec![]).await;
    let request = rig.request(5_000, 60_000);
    let outcome = rig.approver.ask(ApprovalAsk { request, allow_always: false, on_late: None }).await;
    assert!(matches!(outcome, ApprovalOutcome::Unavailable(_)), "{outcome:?}");
    assert_eq!(rig.hub.count("POST", "/v1/approvals"), 0);
    rig.stop().await;
}

#[tokio::test]
async fn windows_and_linux_deciders_are_refused() {
    let rig = Rig::new().await;
    for platform in ["windows", "linux"] {
        let other = Device::new();
        rig.hub.add_device(&other.id, platform, &other.signing_key());
        refused(&rig, false, |request, id| {
            let sig = other.sign(&request.digest, Decision::Once);
            rig.push_decided(id, "once", &request.digest, &other.id, &sig);
        })
        .await;
    }
    rig.stop().await;
}

#[tokio::test]
async fn a_digest_mismatch_is_refused() {
    let rig = Rig::new().await;
    let other_digest = "0".repeat(64);
    // Another request's digest, correctly signed.
    refused(&rig, false, |_, id| {
        let sig = rig.phone.sign(&other_digest, Decision::Once);
        rig.push_decided(id, "once", &other_digest, &rig.phone.id, &sig);
    })
    .await;
    // This request's digest, but the signature covers another one.
    refused(&rig, false, |request, id| {
        let sig = rig.phone.sign(&other_digest, Decision::Once);
        rig.push_decided(id, "once", &request.digest, &rig.phone.id, &sig);
    })
    .await;
    rig.stop().await;
}

#[tokio::test]
async fn a_bad_signature_is_refused() {
    let rig = Rig::new().await;
    let impostor = Device::new();
    refused(&rig, false, |request, id| {
        let sig = impostor.sign(&request.digest, Decision::Once);
        rig.push_decided(id, "once", &request.digest, &rig.phone.id, &sig);
    })
    .await;
    // An Allow signed with the pinned phone's signing key, not its approval key.
    refused(&rig, false, |request, id| {
        let sig = rig
            .phone
            .keys
            .sign(decision_message(&request.digest, Decision::Session).as_bytes())
            .unwrap();
        let sig = base64::engine::general_purpose::STANDARD.encode(sig);
        rig.push_decided(id, "session", &request.digest, &rig.phone.id, &sig);
    })
    .await;
    // A signature for "deny" presented as "once".
    refused(&rig, false, |request, id| {
        let sig = rig.phone.sign(&request.digest, Decision::Deny);
        rig.push_decided(id, "once", &request.digest, &rig.phone.id, &sig);
    })
    .await;
    refused(&rig, false, |request, id| {
        rig.push_decided(id, "once", &request.digest, &rig.phone.id, "not base64!");
    })
    .await;
    rig.stop().await;
}

#[tokio::test]
async fn always_needs_allow_always() {
    let rig = Rig::new().await;
    refused(&rig, false, |request, id| {
        let sig = rig.phone.sign(&request.digest, Decision::Always);
        rig.push_decided(id, "always", &request.digest, &rig.phone.id, &sig);
    })
    .await;
    rig.stop().await;
}

#[tokio::test]
async fn no_decision_times_out_and_an_expiry_ends_it_early() {
    let rig = Rig::new().await;
    let request = rig.request(300, 60_000);
    let (task, _) = rig.ask(&request, false, None).await;
    assert_eq!(outcome(task).await, ApprovalOutcome::Timeout);

    let request = rig.request(30_000, 60_000);
    let (task, id) = rig.ask(&request, false, None).await;
    let started = Instant::now();
    rig.hub.push(
        rig.me(),
        json!({"type": "approval.closed", "id": id, "state": "expired", "decision": null}),
    );
    assert_eq!(outcome(task).await, ApprovalOutcome::Timeout);
    assert!(started.elapsed() < Duration::from_secs(10));
    rig.stop().await;
}

#[tokio::test]
async fn a_late_decision_is_surfaced_once_and_replays_are_ignored() {
    let rig = Rig::new().await;
    let late: Arc<Mutex<Vec<VerifiedDecision>>> = Arc::default();
    let (seen_tx, mut seen_rx) = tokio::sync::mpsc::unbounded_channel();
    let sink = Arc::clone(&late);
    let on_late: cmux_device_hub_client::LateDecisionHandler = Arc::new(move |decision| {
        sink.lock().unwrap().push(decision);
        let _ = seen_tx.send(());
    });
    let request = rig.request(300, 60_000);
    let (task, id) = rig.ask(&request, false, Some(on_late)).await;
    assert_eq!(outcome(task).await, ApprovalOutcome::Timeout);

    let sig = rig.phone.sign(&request.digest, Decision::Session);
    rig.push_decided(&id, "session", &request.digest, &rig.phone.id, &sig);
    tokio::time::timeout(Duration::from_secs(5), seen_rx.recv())
        .await
        .expect("late decision")
        .unwrap();
    // A replay of the same id (same or another valid decision) is not applied again.
    rig.push_decided(&id, "session", &request.digest, &rig.phone.id, &sig);
    let once = rig.phone.sign(&request.digest, Decision::Once);
    rig.push_decided(&id, "once", &request.digest, &rig.phone.id, &once);

    // The old approval's decision does not answer a new question either.
    let next = rig.request(700, 60_000);
    let (task, _) = rig.ask(&next, false, None).await;
    rig.push_decided(&id, "session", &request.digest, &rig.phone.id, &sig);
    assert_eq!(outcome(task).await, ApprovalOutcome::Timeout);
    assert!(seen_rx.try_recv().is_err());
    let late = late.lock().unwrap().clone();
    assert_eq!(late.len(), 1);
    assert_eq!(late[0].decision, Decision::Session);
    rig.stop().await;
}

#[tokio::test]
async fn a_decision_missed_while_disconnected_is_read_after_the_reconnect() {
    let rig = Rig::new().await;
    let request = rig.request(10_000, 60_000);
    let (task, id) = rig.ask(&request, false, None).await;
    let sig = rig.phone.sign(&request.digest, Decision::Once);
    rig.hub.decide_silently(&id, "once", &rig.phone.id, &sig);
    let reads = rig.hub.count("GET", &format!("/v1/approvals/{id}"));
    rig.hub.drop_socket(rig.me());
    rig.hub.wait_connections(2).await;
    let outcome = outcome(task).await;
    assert_eq!(decided(&outcome).decision, Decision::Once);
    assert!(rig.hub.count("GET", &format!("/v1/approvals/{id}")) > reads);
    rig.stop().await;
}

#[tokio::test]
async fn a_read_decision_is_verified_too() {
    let rig = Rig::new().await;
    let request = rig.request(700, 60_000);
    let (task, id) = rig.ask(&request, false, None).await;
    let own = rig
        .identity
        .sign_base64(decision_message(&request.digest, Decision::Once).as_bytes())
        .unwrap();
    rig.hub.decide_silently(&id, "once", rig.me(), &own);
    rig.hub.drop_socket(rig.me());
    rig.hub.wait_connections(2).await;
    assert_eq!(outcome(task).await, ApprovalOutcome::Timeout);
    rig.stop().await;
}

#[tokio::test]
async fn cancel_withdraws_the_question() {
    let rig = Rig::new().await;
    let request = rig.request(30_000, 60_000);
    let (task, id) = rig.ask(&request, false, None).await;
    // Whether the POST has answered yet or not, the approval is withdrawn.
    rig.approver.cancel(&request.nonce).await;
    assert_eq!(outcome(task).await, ApprovalOutcome::Cancelled);
    assert_eq!(rig.hub.approval(&id).unwrap()["state"], "cancelled");
    rig.stop().await;
}

#[tokio::test]
async fn unavailable_without_a_hub_or_an_approver() {
    let rig = Rig::new().await;
    let request = rig.request(5_000, 60_000);
    let ask = ApprovalAsk { request: request.clone(), allow_always: false, on_late: None };
    assert!(matches!(NoHubApprover.ask(ask.clone()).await, ApprovalOutcome::Unavailable(_)));

    // Only Linux and Windows devices on the account: nobody can answer.
    let hub = MockHub::start().await;
    let dir = tempfile::tempdir().unwrap();
    let identity = FileKeyStore::new(dir.path(), Platform::Linux).load_or_create().unwrap();
    let mut config = HubClientConfig::new(
        hub.base_url(),
        identity,
        Arc::new(StaticToken(STACK_TOKEN.to_owned())),
    );
    config.allow_http = true;
    let client = Arc::new(HubClient::new(config).unwrap());
    client.register_device("lonely").await.unwrap();
    let windows = Device::new();
    hub.add_device(&windows.id, "windows", &windows.signing_key());
    let (events, _) = tokio::sync::broadcast::channel(4);
    let approver = HubApprover::new(client, events, vec![windows.pin()]);
    assert!(matches!(approver.ask(ask.clone()).await, ApprovalOutcome::Unavailable(_)));

    // A hub that does not answer.
    let closed = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = closed.local_addr().unwrap();
    drop(closed);
    let identity =
        FileKeyStore::new(dir.path().join("b"), Platform::Linux).load_or_create().unwrap();
    let mut config = HubClientConfig::new(
        url::Url::parse(&format!("http://{address}")).unwrap(),
        identity,
        Arc::new(StaticToken(STACK_TOKEN.to_owned())),
    );
    config.allow_http = true;
    let (events, _) = tokio::sync::broadcast::channel(4);
    let approver =
        HubApprover::new(Arc::new(HubClient::new(config).unwrap()), events, vec![rig.phone.pin()]);
    assert!(matches!(approver.ask(ask).await, ApprovalOutcome::Unavailable(_)));

    // A request whose digest does not match its fields never leaves the machine.
    let mut tampered = request;
    tampered.tool = "type".into();
    let outcome = rig
        .approver
        .ask(ApprovalAsk { request: tampered, allow_always: false, on_late: None })
        .await;
    assert!(matches!(outcome, ApprovalOutcome::Error(_)));
    rig.stop().await;
}

#[tokio::test]
async fn http_is_refused_unless_allowed() {
    let dir = tempfile::tempdir().unwrap();
    let identity = FileKeyStore::new(dir.path(), Platform::Linux).load_or_create().unwrap();
    let config = HubClientConfig::new(
        url::Url::parse("http://127.0.0.1:1").unwrap(),
        identity,
        Arc::new(StaticToken(STACK_TOKEN.to_owned())),
    );
    assert!(matches!(HubClient::new(config), Err(HubError::NotConfigured(_))));
}
