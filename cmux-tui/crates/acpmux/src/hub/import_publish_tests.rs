//! An imported chat takes no prompt before its own `imported` receipt is logged
//! (`transfer.rs` `import_into`).

use super::*;
use std::sync::Weak;

/// A memory store that notes, when an `imported` receipt is appended, whether its chat could
/// already take a prompt (published and not frozen).
struct ReceiptWatch {
    inner: Box<dyn Store>,
    hub: Arc<StdMutex<Weak<Hub>>>,
    open_at_receipt: Arc<StdMutex<Option<bool>>>,
}

impl Store for ReceiptWatch {
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
        if record.kind == "imported"
            && let Some(hub) = self.hub.lock().unwrap().upgrade()
        {
            let published = hub.sessions.lock().unwrap().get(id).cloned();
            let open = published.is_some_and(|s| s.moving().is_none());
            *self.open_at_receipt.lock().unwrap() = Some(open);
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

/// HQ#5075: until its own receipt is durable the chat is not this daemon's (a failed receipt
/// removes it), so no prompt may start on it: it is published frozen and freed after.
#[tokio::test]
async fn an_imported_chat_takes_no_prompt_before_its_receipt_is_logged() {
    let dir = std::env::temp_dir().join(format!("acpmux-import-publish-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let config = || {
        let mut config: Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", fake]}},
            "defaultHarness": "fake",
        }))
        .unwrap();
        config.store.mode = crate::config::StoreMode::Memory;
        config
    };
    let source_config = config();
    let source = Hub::new(
        source_config.clone(),
        crate::store::open(&source_config.store, std::path::Path::new("/unused")).unwrap(),
    );
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "import-publish", "name": "publish",
        "harness": "fake", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    source.store.save(&meta).unwrap();
    let session = source.make_session(meta);
    source.append(&session, "mux", "created", json!({"harness": "fake"}));
    let bundle = source.export(&session, &dir).unwrap();

    let here_config = config();
    let weak = Arc::new(StdMutex::new(Weak::new()));
    let open_at_receipt = Arc::new(StdMutex::new(None));
    let store = ReceiptWatch {
        inner: crate::store::open(&here_config.store, std::path::Path::new("/unused")).unwrap(),
        hub: weak.clone(),
        open_at_receipt: open_at_receipt.clone(),
    };
    let here = Arc::new(Hub::new(here_config, Box::new(store)));
    *weak.lock().unwrap() = Arc::downgrade(&here);
    let imported = here.import(&bundle, None).await;
    let _ = std::fs::remove_dir_all(&dir);
    let imported = imported.unwrap();
    assert_eq!(
        *open_at_receipt.lock().unwrap(),
        Some(false),
        "the chat could take a prompt before its receipt was logged"
    );
    assert!(imported.moving().is_none(), "the logged import left the chat frozen");
    // No abort, commit or watchdog takes the import's mark for a move.
    assert!(!transfer_out::names_a_move(transfer_out::IMPORTING));
}
