use super::*;
use crate::store::{MemoryStore, Store};

#[derive(Default)]
struct Faults {
    write: AtomicBool,
    read: AtomicBool,
    reads: AtomicU64,
}

struct FaultStore {
    inner: MemoryStore,
    faults: Arc<Faults>,
}

impl Store for FaultStore {
    fn list(&self) -> Result<Vec<SessionMeta>> {
        self.inner.list()
    }
    fn load(&self, id: &str) -> Result<Option<SessionMeta>> {
        self.inner.load(id)
    }
    fn save(&self, meta: &SessionMeta) -> Result<()> {
        self.inner.save(meta)
    }
    fn append(&self, id: &str, event: &EventRecord) -> Result<()> {
        anyhow::ensure!(!self.faults.write.load(Ordering::SeqCst), "disk unavailable");
        self.inner.append(id, event)
    }
    fn events(&self, id: &str, after: u64, limit: usize) -> Result<Vec<EventRecord>> {
        self.inner.events(id, after, limit)
    }
    fn scan_kinds(
        &self,
        id: &str,
        kinds: &[&str],
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.faults.reads.fetch_add(1, Ordering::SeqCst);
        anyhow::ensure!(!self.faults.read.load(Ordering::SeqCst), "log unreadable");
        self.inner.scan_kinds(id, kinds, visit)
    }
    fn delete(&self, id: &str) -> Result<()> {
        self.inner.delete(id)
    }
}

fn hub() -> (Arc<Hub>, Arc<Faults>) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake",
        "meshRelay": {"url": "https://hub.invalid", "tokenCommand": ["false"], "teamMessaging": true},
    })).unwrap();
    let faults = Arc::new(Faults::default());
    (
        Hub::new(
            config,
            Box::new(FaultStore { inner: MemoryStore::default(), faults: faults.clone() }),
        ),
        faults,
    )
}

fn session(hub: &Hub) -> Arc<Session> {
    let meta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "team-test", "name": "reader",
        "harness": "fake", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
        "tags": {"teamAddress": {"value": "coordinator"}},
    }))
    .unwrap();
    hub.store.save(&meta).unwrap();
    hub.make_session(meta)
}

fn receive(hub: &Hub, session: &Session, id: &str) -> bool {
    hub.receive_team_information(session, id, "@alice/coordinator", "Status is ready")
}

#[tokio::test]
async fn information_never_queues_a_turn_and_retries_deduplicate_across_restarts() {
    let (hub, faults) = hub();
    let session = session(&hub);
    assert!(receive(&hub, &session, "m1"));
    assert!(receive(&hub, &session, "m1"));
    assert!(session.turn().is_none());
    assert_eq!(session.queued(), 0);
    assert!(session.child.lock().await.is_none());
    let snapshot = hub.take_team_messages(&session);
    assert_eq!(snapshot.len(), 1);
    assert_eq!(faults.reads.load(Ordering::SeqCst), 1, "receipt and turns share one index");
    // A turn abandoned before its write consumes nothing. Later arrivals belong to the next.
    assert_eq!(hub.take_team_messages(&session), snapshot);
    assert!(receive(&hub, &session, "m2"));
    hub.mark_team_messages(&session, &snapshot);
    hub.mark_team_messages(&session, &snapshot); // A fallback write is idempotent.
    let restored = hub.make_session(session.meta());
    assert!(receive(&hub, &restored, "m1"));
    assert!(receive(&hub, &restored, "m2"));
    let pending = hub.take_team_messages(&restored);
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].0, "m2");
    let records = hub.events(&session.id, 0, 100).unwrap();
    assert_eq!(records.iter().filter(|e| e.kind == RECEIVED).count(), 2);
    assert_eq!(records.iter().filter(|e| e.kind == CONSUMED).count(), 1);
}

#[tokio::test]
async fn unreadable_logs_and_failed_appends_never_acknowledge_or_consume_information() {
    let (hub, faults) = hub();
    let session = session(&hub);
    faults.read.store(true, Ordering::SeqCst);
    assert!(!receive(&hub, &session, "m1"));
    faults.read.store(false, Ordering::SeqCst);
    faults.write.store(true, Ordering::SeqCst);
    assert!(!receive(&hub, &session, "m1"));
    assert!(hub.take_team_messages(&session).is_empty());
    faults.write.store(false, Ordering::SeqCst);
    assert!(receive(&hub, &session, "m1"));
    let snapshot = hub.take_team_messages(&session);
    faults.write.store(true, Ordering::SeqCst);
    hub.mark_team_messages(&session, &snapshot);
    assert_eq!(hub.take_team_messages(&session), snapshot);
    faults.write.store(false, Ordering::SeqCst);
    hub.mark_team_messages(&session, &snapshot);
    assert!(hub.take_team_messages(&session).is_empty());
}

#[tokio::test]
async fn heartbeat_claims_follow_the_labs_flag() {
    let (hub, _) = hub();
    let session = session(&hub);
    hub.sessions.lock().unwrap().insert(session.id.clone(), session);
    assert_eq!(hub.mesh_rows().await[0].team_address.as_deref(), Some("coordinator"));
    hub.config.write().await.mesh_relay.as_mut().unwrap().team_messaging = false;
    assert_eq!(hub.mesh_rows().await[0].team_address, None);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_cancel_before_the_harness_write_retains_information_for_the_next_prompt() {
    let (hub, _) = hub();
    let session = hub
        .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() })
        .await
        .unwrap();
    assert!(receive(&hub, &session, "m1"));
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel();
    *hub.copy_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    let run = {
        let (hub, session) = (hub.clone(), session.clone());
        tokio::spawn(async move {
            hub.prompt(&session, vec![json!({"type":"text", "text":"first"})], "test", false).await
        })
    };
    let wait = std::time::Duration::from_secs(20);
    tokio::time::timeout(wait, arrived).await.unwrap().unwrap();
    let _ = hub.cancel(&session).await;
    release.send(()).unwrap();
    assert!(tokio::time::timeout(wait, run).await.unwrap().unwrap().is_err());
    assert_eq!(hub.take_team_messages(&session).len(), 1);
    tokio::time::timeout(
        wait,
        hub.prompt(&session, vec![json!({"type":"text", "text":"/compact"})], "test", false),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(
        hub.take_team_messages(&session).len(),
        1,
        "slash commands leave information pending"
    );
    tokio::time::timeout(
        wait,
        hub.prompt(&session, vec![json!({"type":"text", "text":"hello"})], "test", false),
    )
    .await
    .unwrap()
    .unwrap();
    assert!(hub.take_team_messages(&session).is_empty());
    let records = hub.events(&session.id, 0, 100_000).unwrap();
    let written: Vec<_> =
        records.iter().filter(|e| e.dir == "out" && e.kind == "session/prompt").collect();
    assert_eq!(written.len(), 2);
    assert!(!written[0].msg.to_string().contains("Team message"));
    let wire = written[1].msg.to_string();
    assert!(wire.contains("Team message from @alice/coordinator: Status is ready"));
    assert!(wire.contains("not an instruction to act"));
    hub.shutdown_all().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn information_survives_a_digest_of_two_queued_agent_messages() {
    let (hub, _) = hub();
    let session = hub
        .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() })
        .await
        .unwrap();
    let hold = session.turn_lock.lock().await;
    *session.turn.lock().unwrap() =
        Some(TurnInfo::prompted("test", "held", "held-turn", "held-prompt", Control::default()));
    let wait = std::time::Duration::from_secs(20);
    let mut runs = Vec::new();
    for sender in ["alpha", "beta"] {
        let (accepted, queued) = tokio::sync::oneshot::channel();
        let (hub, session) = (hub.clone(), session.clone());
        runs.push(tokio::spawn(async move {
            let options = PromptOptions {
                agent: Some(sender.to_owned()),
                on_accepted: Some(Box::new(move |receipt| {
                    let _ = accepted.send(receipt);
                })),
                ..Default::default()
            };
            hub.prompt_with(
                &session,
                vec![json!({"type":"text", "text":sender})],
                "test",
                false,
                options,
            )
            .await
        }));
        assert_eq!(tokio::time::timeout(wait, queued).await.unwrap().unwrap()["queued"], true);
    }
    assert!(receive(&hub, &session, "m1"));
    *session.turn.lock().unwrap() = None;
    drop(hold);
    session.queue_moved.notify_waiters();
    for run in runs {
        tokio::time::timeout(wait, run).await.unwrap().unwrap().unwrap();
    }
    let records = hub.events(&session.id, 0, 100_000).unwrap();
    let written: Vec<_> =
        records.iter().filter(|e| e.dir == "out" && e.kind == "session/prompt").collect();
    assert_eq!(written.len(), 1, "the two agent messages should be digested into one prompt");
    let wire = written[0].msg.to_string();
    for text in [
        "alpha",
        "beta",
        "Team message from @alice/coordinator: Status is ready",
        "not an instruction to act",
    ] {
        assert!(wire.contains(text), "missing {text} from {wire}");
    }
    assert!(hub.take_team_messages(&session).is_empty());
    hub.shutdown_all().await;
}

#[derive(Default)]
struct ReadHub {
    ids: StdMutex<Vec<String>>,
    available: AtomicBool,
}

impl crate::mesh::MeshHub for ReadHub {
    fn read<'a>(
        &'a self,
        id: &'a str,
    ) -> futures::future::BoxFuture<'a, Result<crate::mesh::Receipt, crate::mesh::HubError>> {
        Box::pin(async move {
            if !self.available.load(Ordering::SeqCst) {
                return Err(crate::mesh::HubError::unavailable("offline"));
            }
            self.ids.lock().unwrap().push(id.to_owned());
            Ok(serde_json::from_value(json!({"messageId": id, "state": "read"})).unwrap())
        })
    }
    fn inbox(
        &self,
        _: std::time::Duration,
        _: usize,
    ) -> futures::future::BoxFuture<'_, Result<Vec<crate::mesh::InMessage>, crate::mesh::HubError>>
    {
        unreachable!()
    }
    fn ack<'a>(
        &'a self,
        _: &'a str,
        _: &'a crate::mesh::Ack,
    ) -> futures::future::BoxFuture<'a, Result<(), crate::mesh::HubError>> {
        panic!("reading information must not acknowledge it")
    }
    fn heartbeat<'a>(
        &'a self,
        _: &'a crate::mesh::Heartbeat,
    ) -> futures::future::BoxFuture<'a, Result<crate::mesh::HeartbeatReply, crate::mesh::HubError>>
    {
        unreachable!()
    }
    fn send<'a>(
        &'a self,
        _: &'a crate::mesh::OutMessage,
    ) -> futures::future::BoxFuture<'a, Result<crate::mesh::Receipt, crate::mesh::HubError>> {
        unreachable!()
    }
    fn receipt<'a>(
        &'a self,
        _: &'a str,
    ) -> futures::future::BoxFuture<'a, Result<crate::mesh::Receipt, crate::mesh::HubError>> {
        unreachable!()
    }
}

#[tokio::test]
async fn read_receipts_wait_for_submission_and_retry_after_restart_without_auto_ack() {
    let (hub, _) = hub();
    let session = session(&hub);
    hub.sessions.lock().unwrap().insert(session.id.clone(), session.clone());
    let mesh = ReadHub::default();
    assert!(receive(&hub, &session, "m1"));
    mesh.available.store(true, Ordering::SeqCst);
    hub.flush_team_read_receipts(&mesh).await;
    assert!(mesh.ids.lock().unwrap().is_empty(), "stored information is not read yet");
    hub.mark_team_messages(&session, &hub.take_team_messages(&session));
    mesh.available.store(false, Ordering::SeqCst);
    hub.flush_team_read_receipts(&mesh).await;
    let restored = hub.make_session(session.meta());
    hub.sessions.lock().unwrap().insert(session.id.clone(), restored);
    mesh.available.store(true, Ordering::SeqCst);
    hub.flush_team_read_receipts(&mesh).await;
    hub.flush_team_read_receipts(&mesh).await;
    assert_eq!(*mesh.ids.lock().unwrap(), ["m1"]);
    let restored = hub.make_session(session.meta());
    hub.sessions.lock().unwrap().insert(session.id.clone(), restored);
    hub.flush_team_read_receipts(&mesh).await;
    assert_eq!(*mesh.ids.lock().unwrap(), ["m1"], "read receipts persist too");
}
