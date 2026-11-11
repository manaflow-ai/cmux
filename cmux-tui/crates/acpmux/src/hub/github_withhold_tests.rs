//! A Web client's or a paired device's request that ends a chat's GitHub lending
//! (`github_owner.rs`, `Hub::refuse_at_vm_boundary`): the cleared mark is durably in the store
//! before the request is served, and a request whose clear could not be saved is refused, so a
//! crash loses at most that request, never the mark.

use super::super::*;
use crate::server::ConnAuth;
use crate::store::{MemoryStore, Store};

/// A store that keeps `github_lendable` of each meta it saves, and fails a save on demand.
#[derive(Clone, Default)]
struct Gate {
    inner: Arc<MemoryStore>,
    fail: Arc<AtomicBool>,
    saved: Arc<StdMutex<Vec<bool>>>,
}

impl Store for Gate {
    fn list(&self) -> Result<Vec<SessionMeta>> {
        self.inner.list()
    }
    fn load(&self, id: &str) -> Result<Option<SessionMeta>> {
        self.inner.load(id)
    }
    fn save(&self, meta: &SessionMeta) -> Result<()> {
        if self.fail.load(Ordering::SeqCst) {
            anyhow::bail!("the disk is full");
        }
        self.saved.lock().unwrap_or_else(|e| e.into_inner()).push(meta.github_lendable);
        self.inner.save(meta)
    }
    fn append(&self, id: &str, event: &EventRecord) -> Result<()> {
        self.inner.append(id, event)
    }
    fn events(&self, id: &str, after: u64, limit: usize) -> Result<Vec<EventRecord>> {
        self.inner.events(id, after, limit)
    }
    fn delete(&self, id: &str) -> Result<()> {
        self.inner.delete(id)
    }
}

/// A lent remote chain in a hub on `gate`.
fn lent(gate: &Gate) -> (Arc<Hub>, Arc<Session>) {
    let config = serde_json::from_value(json!({})).unwrap_or_else(|e| panic!("config: {e}"));
    let hub = Hub::new(config, Box::new(gate.clone()));
    let meta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "lent-chain", "name": "lent",
        "harness": "fake", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
        "remoteOrigin": true, "githubLendable": true,
    }))
    .unwrap_or_else(|e| panic!("meta: {e}"));
    (hub.clone(), hub.insert_test_session(meta))
}

fn web_prompt(hub: &Hub, session: &Session) -> Result<(), RpcError> {
    let mut params = json!({"sessionId": session.id, "prompt": []});
    hub.refuse_at_vm_boundary(ConnAuth::ListenerToken, Control::Web, "session/prompt", &mut params)
}

/// When the Web request is let through, the store already holds the cleared mark.
#[tokio::test]
async fn the_cleared_mark_is_saved_before_the_web_request_is_served() {
    let gate = Gate::default();
    let (hub, session) = lent(&gate);
    gate.saved.lock().unwrap_or_else(|e| e.into_inner()).clear();
    web_prompt(&hub, &session).expect("a prompt off the VM boundary runs");
    assert!(!session.meta().github_lendable);
    assert_eq!(gate.saved.lock().unwrap_or_else(|e| e.into_inner()).last(), Some(&false));
    assert_eq!(gate.inner.load(&session.id).unwrap().map(|m| m.github_lendable), Some(false));
}

/// A clear that could not be saved refuses the request, and the chat stays withheld; the next
/// such request saves it and runs.
#[tokio::test]
async fn a_web_request_whose_clear_is_not_saved_is_refused() {
    let gate = Gate::default();
    let (hub, session) = lent(&gate);
    gate.fail.store(true, Ordering::SeqCst);
    let e = web_prompt(&hub, &session).expect_err("refused when the clear is not on disk");
    assert_eq!(e.data.as_ref().map(|d| d["reason"].clone()), Some(json!("store.save_failed")));
    assert!(!session.meta().github_lendable, "withheld here all the same");
    gate.fail.store(false, Ordering::SeqCst);
    web_prompt(&hub, &session).expect("saved now, so served");
    assert_eq!(gate.inner.load(&session.id).unwrap().map(|m| m.github_lendable), Some(false));
}
