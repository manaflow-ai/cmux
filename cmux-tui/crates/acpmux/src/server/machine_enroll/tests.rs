//! A local connection that did not prove the person (a shell, the CLI, an agent) is refused
//! both RPCs before anything runs: no hub request, no join or leave on disk. And what a join
//! starts on this daemon (the relay, the hub client sends use, the carrier) a leave stops,
//! a later enroll replaces, and a start with a leave pending holds until the leave, as does
//! every enroll or leave asked meanwhile.
use super::BoxFuture;
use crate::cli::cloud_join::{EnrollOutcome, LeaveOutcome};
use crate::config::{Config, StoreMode};
use crate::mesh_http::MeshRelayConfig;
use crate::rpc::{Message, method};
use serde_json::{Value, json};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::mpsc;

async fn refused(m: &str, params: Value) -> Value {
    let hub = memory_hub();
    let (input, incoming) = mpsc::channel(8);
    let (out, mut output) = mpsc::channel(64);
    // task-owner: the test's one connection; ends when `input` drops at the test's end.
    tokio::spawn(crate::server::serve_connection(hub, incoming, out));
    let init = Message::request(1, method::INITIALIZE, json!({"protocolVersion": 1}));
    input.send(init.to_line()).await.unwrap();
    input.send(Message::request(2, m, params).to_line()).await.unwrap();
    tokio::time::timeout(Duration::from_secs(30), async {
        loop {
            let reply: Value = serde_json::from_str(&output.recv().await.unwrap()).unwrap();
            if reply["id"] == 2 {
                return reply;
            }
        }
    })
    .await
    .expect("the reply comes")
}

#[tokio::test]
async fn enroll_from_a_local_connection_that_is_not_the_person_is_refused() {
    let reply = refused(
            method::MUX_MACHINE_ENROLL,
            json!({"accessToken": "chosen-token", "userId": "someone-else", "hub": "http://127.0.0.1:9"}),
        )
        .await;
    assert!(reply.get("result").is_none(), "{reply}");
    assert_eq!(reply["error"]["data"]["reason"], crate::hub::person::REASON, "{reply}");
}

#[tokio::test]
async fn leave_if_auto_from_a_local_connection_that_is_not_the_person_is_refused() {
    let reply = refused(method::MUX_MACHINE_LEAVE_IF_AUTO, json!({})).await;
    assert!(reply.get("result").is_none(), "{reply}");
    assert_eq!(reply["error"]["data"]["reason"], crate::hub::person::REASON, "{reply}");
}

fn memory_hub() -> Arc<crate::hub::Hub> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    crate::hub::Hub::new(config, store)
}

/// A loopback hub that answers every request 400 and keeps each request's first line.
async fn recording_hub() -> (crate::mesh_http::MeshRelayConfig, Arc<Mutex<Vec<String>>>) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let config = crate::mesh_http::MeshRelayConfig {
        url: format!("http://{}", listener.local_addr().unwrap()),
        token_command: ["sh", "-c", "printf test-token"].map(str::to_owned).to_vec(),
        team_messaging: true,
        credential: None,
        control_from: Vec::new(),
    };
    let seen = Arc::new(Mutex::new(Vec::new()));
    let log = Arc::clone(&seen);
    // task-owner: the test's fake hub; the runtime ends it with the test.
    tokio::spawn(async move {
        while let Ok((mut stream, _)) = listener.accept().await {
            let log = Arc::clone(&log);
            // task-owner: one request's answer.
            tokio::spawn(async move {
                let mut bytes = Vec::new();
                let mut chunk = [0; 4096];
                while !bytes.windows(4).any(|w| w == b"\r\n\r\n") {
                    match stream.read(&mut chunk).await {
                        Ok(0) | Err(_) => return,
                        Ok(n) => bytes.extend_from_slice(chunk.get(..n).unwrap_or_default()),
                    }
                }
                let line = String::from_utf8_lossy(&bytes).lines().next().unwrap_or("").to_owned();
                log.lock().unwrap().push(line);
                let body = r#"{"error":"test"}"#;
                let answer = format!(
                    "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = stream.write_all(answer.as_bytes()).await;
            });
        }
    });
    (config, seen)
}

fn sends(seen: &Mutex<Vec<String>>) -> usize {
    seen.lock().unwrap().iter().filter(|line| line.starts_with("POST /v1/mesh/messages ")).count()
}

async fn send_one(hub: &crate::hub::Hub) {
    let message: crate::mesh::OutMessage = serde_json::from_value(json!({
        "to": {"teamAddress": "@user_receiver/coordinator", "sessionId": "receiver"},
        "from": {"teamAddress": "@user_sender/coordinator"},
        "kind": "prompt", "body": "hello", "mode": "turn-end", "idempotencyKey": "k1",
    }))
    .unwrap();
    let mesh = hub.mesh.get().expect("a relay runs, so sends have a hub");
    let _ = mesh.send(&message).await;
}

/// A sign-out that kept the person's relay in config.json leaves it running, and sends keep
/// going through it; one that removed the join's relay stops it.
#[tokio::test]
async fn a_sign_out_that_keeps_the_persons_relay_leaves_it_running() {
    let hub = memory_hub();
    let (own, seen) = recording_hub().await;
    let mut slot = hub.mesh_relay.lock().await;
    assert_eq!(super::start_relay_with(&hub, &mut slot, own).await, "started");
    drop(slot);
    let kept = LeaveOutcome { left: true, kept: None, hub: Some("revoked"), relay_removed: false };
    super::after_leave(&hub, &kept).await;
    assert!(hub.mesh_relay.lock().await.as_ref().is_some_and(|relay| !relay.is_finished()));
    assert!(hub.config.read().await.mesh_relay.is_some());
    assert!(hub.mesh.get().is_some(), "sends keep the person's relay's hub");
    send_one(&hub).await;
    assert_eq!(sends(&seen), 1);

    let removed = LeaveOutcome { relay_removed: true, ..kept };
    super::after_leave(&hub, &removed).await;
    assert!(hub.mesh_relay.lock().await.is_none());
    assert!(hub.mesh.get().is_none());
}

/// A stand-in for config.json's `meshRelay`, as the transitions read it.
type Disk = Arc<Mutex<Option<MeshRelayConfig>>>;

fn read(
    disk: &Disk,
) -> impl FnOnce() -> std::future::Ready<Option<MeshRelayConfig>> + Send + 'static {
    let disk = Arc::clone(disk);
    move || std::future::ready(disk.lock().unwrap().clone())
}

async fn relay_runs(hub: &crate::hub::Hub) -> bool {
    hub.mesh_relay.lock().await.as_ref().is_some_and(|relay| !relay.is_finished())
}

/// Lets every task that can run, run.
async fn settle() {
    for _ in 0..20 {
        tokio::task::yield_now().await;
    }
}

/// A sign-in asked while the start finishes a leave waits for it, then starts the relay its
/// join wrote: the start's stop never lands after it.
#[tokio::test]
async fn a_sign_in_during_the_start_leave_ends_with_the_relay_running() {
    let hub = memory_hub();
    let (relay, _seen) = recording_hub().await;
    let disk: Disk = Arc::new(Mutex::new(None));
    let (release, gate) = tokio::sync::oneshot::channel::<()>();
    let join = Arc::clone(&hub.join_transition).lock_owned().await;
    let start = super::at_start(
        &hub,
        join,
        true,
        async move {
            let _ = gate.await;
            Some(LeaveOutcome { left: true, kept: None, hub: Some("revoked"), relay_removed: true })
        },
        read(&disk),
        carrier_mark(&Arc::new(AtomicBool::new(false))),
    )
    .await
    .expect("a pending leave runs in a task");
    let sign_in = {
        let (hub, disk, written) = (Arc::clone(&hub), Arc::clone(&disk), read(&disk));
        // task-owner: the test's sign-in; awaited below.
        tokio::spawn(async move {
            let enroll = async move {
                *disk.lock().unwrap() = Some(relay);
                EnrollOutcome::Joined
            };
            super::enroll_transition(&hub, enroll, written).await
        })
    };
    settle().await;
    assert!(!sign_in.is_finished(), "the enroll waits for the start's leave");
    assert!(disk.lock().unwrap().is_none());
    let _ = release.send(());
    start.await.unwrap();
    assert_eq!(sign_in.await.unwrap(), (EnrollOutcome::Joined, Some("started")));
    assert!(relay_runs(&hub).await, "the new join's relay runs");
    assert!(hub.mesh.get().is_some());
    super::stop_joined(&hub).await;
}

/// An enroll that replaced the join (another account's leave finished inside it) restarts a
/// running relay on the new config: a daemon the last join's `controlFrom` allowed, which the
/// new config no longer names, holds no grant in the relay that runs after. One on the same
/// config and join keeps running.
#[tokio::test]
async fn a_replaced_join_restarts_the_relay_without_the_last_joins_grants() {
    let hub = memory_hub();
    let (fresh, _seen) = recording_hub().await;
    let mut old = fresh.clone();
    old.control_from = vec![crate::mesh_http::MeshControlFrom {
        daemon_id: "daemon_allowed_before".into(),
        ..Default::default()
    }];
    let mut slot = hub.mesh_relay.lock().await;
    assert_eq!(super::start_relay_with(&hub, &mut slot, old.clone()).await, "started");
    drop(slot);
    // The same join, its config unchanged: kept.
    let disk: Disk = Arc::new(Mutex::new(Some(old.clone())));
    let kept =
        super::enroll_transition(&hub, async { EnrollOutcome::AlreadyJoined }, read(&disk)).await;
    assert_eq!(kept, (EnrollOutcome::AlreadyJoined, Some("running")));
    // A new join whose config no longer names that daemon: started again on it.
    *disk.lock().unwrap() = Some(fresh.clone());
    let joined = super::enroll_transition(&hub, async { EnrollOutcome::Joined }, read(&disk)).await;
    assert_eq!(joined, (EnrollOutcome::Joined, Some("started")));
    assert!(relay_runs(&hub).await);
    let running = hub.config.read().await.mesh_relay.clone().unwrap();
    assert!(running.control_from.is_empty(), "no grant of the last join's: {running:?}");
    // A new join on the very same config still restarts (the join under it changed).
    let again = super::enroll_transition(&hub, async { EnrollOutcome::Joined }, read(&disk)).await;
    assert_eq!(again, (EnrollOutcome::Joined, Some("started")));
    // The same join with a changed config (a grant removed on disk) restarts too.
    *disk.lock().unwrap() = Some(old);
    super::enroll_transition(&hub, async { EnrollOutcome::AlreadyJoined }, read(&disk)).await;
    *disk.lock().unwrap() = Some(fresh);
    let changed =
        super::enroll_transition(&hub, async { EnrollOutcome::AlreadyJoined }, read(&disk)).await;
    assert_eq!(changed, (EnrollOutcome::AlreadyJoined, Some("started")));
    super::stop_joined(&hub).await;
}

/// A sign-out asked while the start brings up the relay waits for it, then stops it: the
/// start's relay never comes back after the sign-out.
#[tokio::test]
async fn a_sign_out_during_the_start_ends_with_no_relay() {
    let hub = memory_hub();
    let (relay, _seen) = recording_hub().await;
    let disk: Disk = Arc::new(Mutex::new(Some(relay)));
    let (release, gate) = tokio::sync::oneshot::channel::<()>();
    let join = Arc::clone(&hub.join_transition).lock_owned().await;
    let start = super::at_start(
        &hub,
        join,
        true,
        async move {
            let _ = gate.await;
            Some(LeaveOutcome {
                left: false,
                kept: Some("signedIn"),
                hub: None,
                relay_removed: false,
            })
        },
        read(&disk),
        carrier_mark(&Arc::new(AtomicBool::new(false))),
    )
    .await
    .expect("a pending leave runs in a task");
    let sign_out = {
        let (hub, disk) = (Arc::clone(&hub), Arc::clone(&disk));
        // task-owner: the test's sign-out; awaited below.
        tokio::spawn(async move {
            let leave = async move {
                *disk.lock().unwrap() = None;
                LeaveOutcome { left: true, kept: None, hub: Some("revoked"), relay_removed: true }
            };
            super::leave_transition(&hub, leave).await
        })
    };
    settle().await;
    assert!(!sign_out.is_finished(), "the leave waits for the start");
    assert!(disk.lock().unwrap().is_some());
    let _ = release.send(());
    start.await.unwrap();
    assert!(sign_out.await.unwrap().left);
    assert!(!relay_runs(&hub).await, "no relay after the sign-out");
    assert!(hub.mesh_relay.lock().await.is_none());
    assert!(hub.mesh.get().is_none());
    assert!(hub.config.read().await.mesh_relay.is_none());
}

/// #38319 review F2: one account's leave finishes inside another account's enroll, and the
/// new join's relay does not start. The old relay's hub client, which holds the left join's
/// credential, is gone with it: outbox and team requests (`Hub::mesh`) are refused, and the
/// old hub sees no send.
#[tokio::test]
async fn a_replaced_join_whose_relay_fails_to_start_sends_nothing_with_the_old_credential() {
    let hub = memory_hub();
    let (old, old_seen) = recording_hub().await;
    let mut slot = hub.mesh_relay.lock().await;
    assert_eq!(super::start_relay_with(&hub, &mut slot, old.clone()).await, "started");
    drop(slot);
    send_one(&hub).await;
    assert_eq!(sends(&old_seen), 1);
    // The new join's config names a hub no client can be made for: its relay does not start.
    let broken = MeshRelayConfig { url: "not a hub origin".into(), ..old };
    let disk: Disk = Arc::new(Mutex::new(Some(broken)));
    let joined = super::enroll_transition(&hub, async { EnrollOutcome::Joined }, read(&disk)).await;
    assert_eq!(joined, (EnrollOutcome::Joined, Some("off")));
    assert!(!relay_runs(&hub).await);
    assert!(hub.mesh.get().is_none(), "sends are refused, not sent through the left join's");
    if let Some(mesh) = hub.mesh.get() {
        let message: crate::mesh::OutMessage = serde_json::from_value(json!({
            "to": {"teamAddress": "@user_receiver/coordinator", "sessionId": "receiver"},
            "from": {"teamAddress": "@user_sender/coordinator"},
            "kind": "prompt", "body": "late", "mode": "turn-end", "idempotencyKey": "k2",
        }))
        .unwrap();
        let _ = mesh.send(&message).await;
    }
    settle().await;
    assert_eq!(sends(&old_seen), 1, "no send went out with the old credential");
}

/// A leave clears the hub client sends go through, and a later enroll on another hub's origin
/// sets that hub's: sends go to the new hub, never the left one.
#[tokio::test]
async fn after_a_leave_and_an_enroll_on_another_hub_sends_go_to_the_new_hub() {
    let hub = memory_hub();
    let (first, first_seen) = recording_hub().await;
    let (second, second_seen) = recording_hub().await;
    assert_ne!(first.url, second.url);

    let mut slot = hub.mesh_relay.lock().await;
    assert_eq!(super::start_relay_with(&hub, &mut slot, first).await, "started");
    drop(slot);
    send_one(&hub).await;
    assert_eq!(sends(&first_seen), 1);

    super::stop_joined(&hub).await;
    assert!(hub.mesh.get().is_none(), "a machine that left sends through no hub");
    assert!(hub.mesh_relay.lock().await.is_none());

    let mut slot = hub.mesh_relay.lock().await;
    assert_eq!(super::start_relay_with(&hub, &mut slot, second).await, "started");
    drop(slot);
    send_one(&hub).await;
    assert_eq!(sends(&second_seen), 1, "the send goes to the hub enrolled last");
    assert_eq!(sends(&first_seen), 1, "nothing more goes to the hub it left");
    super::stop_joined(&hub).await;
}

/// A carrier start that only says it ran.
fn carrier_mark(
    started: &Arc<AtomicBool>,
) -> impl FnOnce(Arc<crate::hub::Hub>) -> BoxFuture<'static, ()> + Send + 'static {
    let mark = Arc::clone(started);
    move |_| -> BoxFuture<'static, ()> {
        Box::pin(async move {
            mark.store(true, Ordering::SeqCst);
        })
    }
}

/// The start with a leave pending that ends as `outcome` once `gate` opens, config.json's
/// relay then being `disk`'s; whether it started the carrier.
async fn start_after_leave(
    hub: &Arc<crate::hub::Hub>,
    outcome: LeaveOutcome,
    disk: &Disk,
    gate: tokio::sync::oneshot::Receiver<()>,
) -> (tokio::task::JoinHandle<()>, Arc<AtomicBool>) {
    let carrier = Arc::new(AtomicBool::new(false));
    let join = Arc::clone(&hub.join_transition).lock_owned().await;
    let task = super::at_start(
        hub,
        join,
        true,
        async move {
            let _ = gate.await;
            Some(outcome)
        },
        read(disk),
        carrier_mark(&carrier),
    )
    .await
    .expect("a pending leave runs in a task");
    (task, carrier)
}

/// A leave the last run did not finish holds the start: the relay and carrier start only
/// after it, and neither when the machine left with the join's relay.
#[tokio::test]
async fn a_pending_leave_that_leaves_starts_nothing_at_start() {
    let hub = memory_hub();
    let disk: Disk = Arc::new(Mutex::new(None));
    let (release, gate) = tokio::sync::oneshot::channel::<()>();
    let left = LeaveOutcome { left: true, kept: None, hub: Some("revoked"), relay_removed: true };
    let (task, carrier) = start_after_leave(&hub, left, &disk, gate).await;
    settle().await;
    assert!(!carrier.load(Ordering::SeqCst), "nothing starts before the leave");
    let _ = release.send(());
    task.await.unwrap();
    assert!(!carrier.load(Ordering::SeqCst), "a machine that left starts no carrier");
    assert!(!relay_runs(&hub).await, "nor a relay");
}

/// The same order when the leave kept the join (a sign-in since): both start after it.
#[tokio::test]
async fn a_pending_leave_that_keeps_the_join_starts_it_after() {
    let hub = memory_hub();
    let (relay, _seen) = recording_hub().await;
    let disk: Disk = Arc::new(Mutex::new(Some(relay)));
    let (release, gate) = tokio::sync::oneshot::channel::<()>();
    let kept =
        LeaveOutcome { left: false, kept: Some("signedIn"), hub: None, relay_removed: false };
    let (task, carrier) = start_after_leave(&hub, kept, &disk, gate).await;
    let _ = release.send(());
    task.await.unwrap();
    assert!(carrier.load(Ordering::SeqCst));
    assert!(relay_runs(&hub).await);
    super::stop_joined(&hub).await;
}

/// A leave at start that left the join but kept the person's relay in config.json starts
/// that relay after it, and never the carrier: the machine is no longer joined.
#[tokio::test]
async fn a_pending_leave_that_keeps_the_persons_relay_starts_it_without_the_carrier() {
    let hub = memory_hub();
    let (relay, _seen) = recording_hub().await;
    let disk: Disk = Arc::new(Mutex::new(Some(relay)));
    let (release, gate) = tokio::sync::oneshot::channel::<()>();
    let left = LeaveOutcome { left: true, kept: None, hub: Some("revoked"), relay_removed: false };
    let (task, carrier) = start_after_leave(&hub, left, &disk, gate).await;
    let _ = release.send(());
    task.await.unwrap();
    assert!(relay_runs(&hub).await, "the person's relay starts");
    assert!(!carrier.load(Ordering::SeqCst), "the carrier does not");
    super::stop_joined(&hub).await;
}

/// #38319 review F2, swept to the carrier: a carrier the last join started holds tickets from
/// that join's hub and credential. A leave, and a join that replaced it (another account's
/// leave inside this enroll) whose relay does not start, take it from the daemon's slot, so
/// no peer's dial asks the old hub for a ticket; with the old relay gone, no client is left.
#[cfg(feature = "hub-carrier")]
#[tokio::test]
async fn a_stopped_or_replaced_join_leaves_no_carrier_to_dial_with_the_old_credential() {
    struct Counting(Arc<std::sync::atomic::AtomicUsize>);
    #[async_trait::async_trait]
    impl crate::hub_carrier::Tickets for Counting {
        async fn register(&self) -> Result<crate::hub_carrier::CarrierAnswer, String> {
            self.0.fetch_add(1, Ordering::SeqCst);
            Err("test".into())
        }
        async fn connect(&self, _: &str) -> Result<crate::hub_carrier::CarrierAnswer, String> {
            self.0.fetch_add(1, Ordering::SeqCst);
            Err("test".into())
        }
    }
    let asked = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let carrier = || {
        crate::hub_carrier::HubCarrier::new(
            Arc::new(Counting(Arc::clone(&asked))),
            [7; 32],
            crate::hub_carrier::Timings::default(),
        )
    };
    let dial = |hub: &crate::hub::Hub| hub.hub_carrier.get();
    // A leave.
    let hub = memory_hub();
    hub.hub_carrier.set(carrier());
    let left = LeaveOutcome { left: true, kept: None, hub: None, relay_removed: true };
    super::after_leave(&hub, &left).await;
    assert!(dial(&hub).is_none(), "a peer finds no carrier after the leave");
    // A replaced join whose relay does not start.
    let hub = memory_hub();
    let (old, _seen) = recording_hub().await;
    let mut slot = hub.mesh_relay.lock().await;
    assert_eq!(super::start_relay_with(&hub, &mut slot, old.clone()).await, "started");
    drop(slot);
    hub.hub_carrier.set(carrier());
    let broken = MeshRelayConfig { url: "not a hub origin".into(), ..old };
    let disk: Disk = Arc::new(Mutex::new(Some(broken)));
    let joined = super::enroll_transition(&hub, async { EnrollOutcome::Joined }, read(&disk)).await;
    assert_eq!(joined, (EnrollOutcome::Joined, Some("off")));
    assert!(dial(&hub).is_none(), "no carrier of the last join's");
    assert!(hub.mesh.get().is_none(), "no hub client of the last join's");
    // And at shutdown.
    let hub = memory_hub();
    hub.hub_carrier.set(carrier());
    super::stop_at_shutdown(&hub).await;
    assert!(dial(&hub).is_none());
    assert_eq!(asked.load(Ordering::SeqCst), 0, "no ticket was asked of the old hub");
}

/// A leave's cleanup (sign-out, or a leave finished at start) stops the hub carrier the
/// start ran: its registration is dropped, which unregisters this machine's relay slot.
#[cfg(feature = "hub-carrier")]
#[tokio::test]
async fn the_leaves_cleanup_stops_a_running_hub_carrier() {
    struct Dropped(Arc<AtomicBool>);
    impl Drop for Dropped {
        fn drop(&mut self) {
            self.0.store(true, Ordering::SeqCst);
        }
    }
    let hub = memory_hub();
    let unregistered = Arc::new(AtomicBool::new(false));
    let guard = Dropped(Arc::clone(&unregistered));
    // task-owner: the stand-in registration; aborted by the cleanup under test.
    let serving = tokio::spawn(async move {
        let _guard = guard;
        std::future::pending::<()>().await;
    });
    *hub.hub_carrier_serve.lock().unwrap() = Some(crate::hub_carrier::HubServe::of_task(serving));
    // A sign-out that kept the person's relay still stops the carrier: the join went.
    let kept = LeaveOutcome { left: true, kept: None, hub: None, relay_removed: false };
    super::after_leave(&hub, &kept).await;
    assert!(hub.hub_carrier_serve.lock().unwrap().is_none());
    tokio::time::timeout(Duration::from_secs(5), async {
        while !unregistered.load(Ordering::SeqCst) {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("the carrier's registration ends");
}
