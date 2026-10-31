//! Pending prompt identities outlive the bounded cache of completed outcomes.

use super::*;
use acpmux::store::{EventRecord, SessionMeta, Store};
use std::sync::{Condvar, Mutex};

#[derive(Default)]
struct RemovalAppendGate {
    entered: tokio::sync::Notify,
    released: Mutex<bool>,
    changed: Condvar,
}

impl RemovalAppendGate {
    fn release(&self) {
        *self.released.lock().unwrap() = true;
        self.changed.notify_all();
    }
}

struct ReleaseRemovalGate(Arc<RemovalAppendGate>);

impl Drop for ReleaseRemovalGate {
    fn drop(&mut self) {
        self.0.release();
    }
}

struct GatedRemovalStore {
    inner: Box<dyn Store>,
    gate: Arc<RemovalAppendGate>,
    fail: bool,
}

impl Store for GatedRemovalStore {
    fn list(&self) -> anyhow::Result<Vec<SessionMeta>> {
        self.inner.list()
    }

    fn load(&self, id: &str) -> anyhow::Result<Option<SessionMeta>> {
        self.inner.load(id)
    }

    fn save(&self, meta: &SessionMeta) -> anyhow::Result<()> {
        self.inner.save(meta)
    }

    fn append(&self, id: &str, record: &EventRecord) -> anyhow::Result<()> {
        if record.kind == "queue_removed" && record.msg["promptId"] == "p-restored-0" {
            self.gate.entered.notify_one();
            let mut released = self.gate.released.lock().unwrap();
            while !*released {
                released = self.gate.changed.wait(released).unwrap();
            }
            if self.fail {
                anyhow::bail!("injected queue_removed append failure");
            }
        }
        self.inner.append(id, record)
    }

    fn events(&self, id: &str, after: u64, limit: usize) -> anyhow::Result<Vec<EventRecord>> {
        self.inner.events(id, after, limit)
    }

    fn delete(&self, id: &str) -> anyhow::Result<()> {
        self.inner.delete(id)
    }
}

#[cfg(unix)]
async fn retry_behind_a_full_queue(resend: bool) {
    let gate = std::env::temp_dir().join(format!("acpmux-ledger-gate-{}", uuid::Uuid::now_v7()));
    assert!(std::process::Command::new("mkfifo").arg(&gate).status().unwrap().success());
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "ledger-pressure").await;
    c.send(
        method::SESSION_PROMPT,
        prompt_with_id(&id, &format!("gate: {}", gate.display()), "p-gate", false),
    )
    .await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-gate").await;

    // The oldest queued identity must survive even with more than 64 pending prompts.
    let mut first_turn = Value::Null;
    for i in 0..65 {
        let prompt_id = format!("p-queued-{i}");
        c.send(method::SESSION_PROMPT, prompt_with_id(&id, "hi", &prompt_id, false)).await;
        let accepted =
            c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == prompt_id).await;
        assert_eq!(accepted["queued"], true);
        if i == 0 {
            first_turn = accepted["turnId"].clone();
        }
    }

    let mut retry = connect(&hub).await;
    let request =
        retry.send(method::SESSION_PROMPT, prompt_with_id(&id, "hi", "p-queued-0", resend)).await;
    let accepted =
        retry.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-queued-0").await;
    let early = tokio::time::timeout(Duration::from_millis(50), retry.response(request)).await.ok();

    // Open the gate before asserting, so even a failing regression shuts the fake agent down.
    let gate_write = gate.clone();
    tokio::task::spawn_blocking(move || std::fs::write(gate_write, b"open"))
        .await
        .unwrap()
        .unwrap();
    let replied_early = early.is_some();
    let reply = match early {
        Some((reply, _)) => reply.unwrap(),
        None => retry.response(request).await.0.unwrap(),
    };
    // A final turn drains the original queue and any accidental retry queued behind it.
    c.request(method::SESSION_PROMPT, prompt_with_id(&id, "hi", "p-drained", false)).await.unwrap();
    let records = hub.events(&id, 0, 10_000).unwrap();
    let runs = records
        .iter()
        .filter(|e| e.kind == "user_message" && e.msg["promptId"] == "p-queued-0")
        .count();
    hub.shutdown_all().await;
    let _ = std::fs::remove_file(gate);

    assert_eq!(accepted["duplicate"], true, "retry acquired another queue entry: {accepted}");
    assert!(!replied_early, "a pending prompt was reported as finished: {reply}");
    assert_eq!(reply["stopReason"], "end_turn", "{reply}");
    assert_eq!(reply["_meta"]["acpmux"]["duplicate"], true, "{reply}");
    assert_eq!(reply["_meta"]["acpmux"]["turnId"], first_turn, "{reply}");
    assert_eq!(runs, 1, "retry ran the oldest queued prompt more than once");
}

#[cfg(unix)]
#[tokio::test]
async fn prompt_ledger_keeps_live_pending_identity_without_resend() {
    retry_behind_a_full_queue(false).await;
}

#[cfg(unix)]
#[tokio::test]
async fn prompt_ledger_keeps_live_pending_identity_with_resend() {
    retry_behind_a_full_queue(true).await;
}

async fn recovered_queue(
    count: u64,
    gate: Option<(Arc<RemovalAppendGate>, bool)>,
) -> (Arc<Hub>, String, std::path::PathBuf) {
    let dir = std::env::temp_dir().join(format!("acpmux-ledger-restart-{}", uuid::Uuid::now_v7()));
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Local;
    let hub = Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, &dir).unwrap());
    let mut c = connect(&hub).await;
    let id = new_session(&mut c, "ledger-restart").await;
    let last = hub.session_summary(&hub.resolve(&id).unwrap())["lastSeq"].as_u64().unwrap();
    hub.shutdown_all().await;
    drop(c);
    drop(hub);

    // A stopped daemon's durable log has accepted, not yet dispatched prompts.
    let store = acpmux::store::open(&cfg.store, &dir).unwrap();
    for i in 0..count {
        store
            .append(
                &id,
                &EventRecord {
                    seq: last + i + 1,
                    at: 0,
                    dir: "mux".into(),
                    kind: "queued".into(),
                    msg: json!({"promptId": format!("p-restored-{i}"), "turnId": format!("t-restored-{i}"),
                        "client": "test", "text": "hi", "prompt": [{"type": "text", "text": "hi"}]}),
                    host_seq: None,
                },
            )
            .unwrap();
    }
    let store: Box<dyn Store> = match gate {
        Some((gate, fail)) => Box::new(GatedRemovalStore { inner: store, gate, fail }),
        None => store,
    };
    (Hub::new(cfg, store), id, dir)
}

#[tokio::test]
async fn prompt_ledger_keeps_recovered_pending_identity_until_withdrawn() {
    let (hub, id, dir) = recovered_queue(65, None).await;
    let session = hub.resolve(&id).unwrap();
    assert_eq!(hub.session_summary(&session)["queued"], 65);
    let mut retry = connect(&hub).await;
    let request =
        retry.send(method::SESSION_PROMPT, prompt_with_id(&id, "hi", "p-restored-0", true)).await;
    retry.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-restored-0").await;
    assert!(hub.remove_queued(&session, "p-restored-0"));
    let reply = retry.response(request).await.0.unwrap();
    let records = hub.events(&id, 0, 10_000).unwrap();
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(dir);

    assert_eq!(reply["stopReason"], "cancelled", "{reply}");
    assert_eq!(reply["_meta"]["acpmux"]["withdrawn"], true, "{reply}");
    assert_eq!(reply["_meta"]["acpmux"]["duplicate"], true, "{reply}");
    assert_eq!(reply["_meta"]["acpmux"]["turnId"], "t-restored-0", "{reply}");
    assert!(records.iter().all(|e| e.kind != "user_message"), "a restored retry ran a turn");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn prompt_ledger_pins_withdrawal_until_its_log_append_finishes() {
    let gate = Arc::new(RemovalAppendGate::default());
    let _release = ReleaseRemovalGate(gate.clone());
    let (hub, id, dir) = recovered_queue(65, Some((gate.clone(), false))).await;
    let session = hub.resolve(&id).unwrap();
    for i in 1..65 {
        assert!(hub.remove_queued(&session, &format!("p-restored-{i}")));
    }

    // Settling the oldest identity would evict it: 64 newer outcomes are already cached.
    let removing = {
        let hub = hub.clone();
        let session = session.clone();
        tokio::task::spawn_blocking(move || hub.remove_queued(&session, "p-restored-0"))
    };
    tokio::time::timeout(Duration::from_secs(20), gate.entered.notified())
        .await
        .expect("the removal never reached the gated append");
    let mut client = connect(&hub).await;
    let (started, retry_started) = tokio::sync::oneshot::channel();
    let mut retry = tokio::spawn(async move {
        started.send(()).unwrap();
        client
            .request(method::SESSION_PROMPT, prompt_with_id(&id, "hi", "p-restored-0", true))
            .await
    });
    retry_started.await.unwrap();
    let early = tokio::time::timeout(Duration::from_secs(1), &mut retry).await.ok();
    gate.release();
    let removed = removing.await.unwrap();
    let replied_early = early.is_some();
    let reply = match early {
        Some(reply) => reply.unwrap().unwrap(),
        None => retry.await.unwrap().unwrap(),
    };
    let records = hub.events(&session.id, 0, 10_000).unwrap();
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(dir);

    assert!(removed);
    assert!(!replied_early, "retry escaped the in-progress withdrawal append: {reply}");
    assert_eq!(reply["_meta"]["acpmux"]["status"], "withdrawn", "{reply}");
    assert_eq!(reply["_meta"]["acpmux"]["turnId"], "t-restored-0", "{reply}");
    assert_eq!(reply["_meta"]["acpmux"]["duplicate"], true, "{reply}");
    assert!(records.iter().all(|e| e.kind != "user_message"), "a withdrawal retry ran a turn");
}

#[tokio::test]
async fn prompt_ledger_failed_withdrawal_append_remains_best_effort() {
    let gate = Arc::new(RemovalAppendGate::default());
    gate.release();
    let (hub, id, dir) = recovered_queue(1, Some((gate, true))).await;
    let session = hub.resolve(&id).unwrap();
    assert!(hub.remove_queued(&session, "p-restored-0"));
    let mut retry = connect(&hub).await;
    let reply = retry
        .request(method::SESSION_PROMPT, prompt_with_id(&id, "hi", "p-restored-0", true))
        .await
        .unwrap();
    let summary = hub.session_summary(&session);
    let records = hub.events(&id, 0, 10_000).unwrap();
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(dir);

    // Existing append semantics: memory settles, but a failed journal write stays absent.
    // This establishes no durable withdrawal after restart or completed-cache eviction.
    assert_eq!(summary["queued"], 0);
    assert_eq!(reply["_meta"]["acpmux"]["withdrawn"], true, "{reply}");
    assert!(records.iter().all(|e| e.kind != "queue_removed"), "the failed append was stored");
}
