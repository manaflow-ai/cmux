//! A cached projection of durable transfer events, never a second revocation authority.
//! Startup reads it once (including closed chats); info only reads the cached result.

use super::*;

impl Session {
    /// Whether durable transfer history denies opening this chat here. Unknown while its
    /// restored log is unread or unreadable; callers must not treat unknown as permission.
    pub fn transfer_blocked(&self) -> Option<bool> {
        self.transfer_authority
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .map(|(_, blocked)| blocked)
    }

    pub(super) fn note_transfer_event(&self, record: &EventRecord) {
        if let Some(blocked) = transfer_state(record) {
            self.note_transfer_authority(record.seq, blocked);
        }
    }

    fn note_transfer_authority(&self, seq: u64, blocked: bool) {
        let mut latest = self.transfer_authority.lock().unwrap_or_else(|e| e.into_inner());
        // A new append may race the startup scan. An older replay cannot revoke an abort
        // or undo a new move that was durably appended while the scan was running.
        if latest.is_none_or(|(seen, _)| seq >= seen) {
            *latest = Some((seq, blocked));
        }
    }
}

/// Only the daemon's own records decide: an agent's update (`dir: "in"`) may carry any kind.
fn transfer_state(record: &EventRecord) -> Option<bool> {
    if record.dir != "mux" {
        return None;
    }
    match record.kind.as_str() {
        "transfer_out" | "transferred" => Some(true),
        "transfer_aborted" | "imported" => Some(false),
        _ => None,
    }
}

impl Hub {
    /// The record kinds [`transfer_state`] reads.
    pub(crate) const TRANSFER_KINDS: &[&str] =
        &["transfer_out", "transferred", "transfer_aborted", "imported"];

    pub(super) fn restore_transfer_authority(&self, session: &Session) {
        let mut latest = (0, false);
        // Fail closed on an unreadable log. This runs only in load_session_log, never in
        // info, and does not hold the cache lock while reading disk.
        match self.store.scan_kinds_strict(&session.id, Self::TRANSFER_KINDS, &mut |record| {
            if let Some(blocked) = transfer_state(&record)
                && record.seq >= latest.0
            {
                latest = (record.seq, blocked);
            }
            true
        }) {
            Ok(()) => session.note_transfer_authority(latest.0, latest.1),
            Err(error) => {
                tracing::warn!(session = %session.id, "transfer authority unreadable: {error}")
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct CountingStore {
        inner: Box<dyn Store>,
        scans: Arc<AtomicU64>,
        fail: Arc<AtomicBool>,
        /// Event kinds whose appends fail while every other append is kept; `"events"` fails
        /// event reads (an export).
        refuse: &'static [&'static str],
    }

    impl Store for CountingStore {
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
            anyhow::ensure!(!self.fail.load(Ordering::SeqCst), "store failed");
            anyhow::ensure!(!self.refuse.contains(&record.kind.as_str()), "store refused");
            self.inner.append(id, record)
        }
        fn events(&self, id: &str, after: u64, limit: usize) -> anyhow::Result<Vec<EventRecord>> {
            anyhow::ensure!(!self.refuse.contains(&"events"), "store refused reads");
            self.inner.events(id, after, limit)
        }
        fn scan_strict(
            &self,
            id: &str,
            after: u64,
            visit: &mut dyn FnMut(EventRecord) -> bool,
        ) -> anyhow::Result<()> {
            self.scans.fetch_add(1, Ordering::SeqCst);
            anyhow::ensure!(!self.fail.load(Ordering::SeqCst), "store failed");
            self.inner.scan_strict(id, after, visit)
        }
        fn delete(&self, id: &str) -> anyhow::Result<()> {
            self.inner.delete(id)
        }
    }

    #[test]
    fn transfer_authority_is_cached_and_old_replay_cannot_undo_a_new_append() {
        let mut config = Config::default();
        config.store.mode = crate::config::StoreMode::Memory;
        let scans = Arc::new(AtomicU64::new(0));
        let fail = Arc::new(AtomicBool::new(false));
        let inner = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
        let hub = Hub::new(
            config,
            Box::new(CountingStore {
                inner,
                scans: scans.clone(),
                fail: fail.clone(),
                refuse: &[],
            }),
        );
        let meta: SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "transfer-cache", "name": "cache",
            "harness": "fake", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
        }))
        .unwrap();
        hub.store.save(&meta).unwrap();
        let session = hub.make_session(meta);
        assert_eq!(session.transfer_blocked(), Some(false));
        hub.append(&session, "mux", "transfer_out", json!({}));
        hub.append(&session, "mux", "transferred", json!({}));
        assert_eq!(hub.store.events(&session.id, 0, 10).unwrap().len(), 2);
        *session.transfer_authority.lock().unwrap() = None;
        assert_eq!(session.transfer_blocked(), None);
        hub.restore_transfer_authority(&session);
        assert_eq!(session.transfer_blocked(), Some(true));
        let scanned = scans.load(Ordering::SeqCst);
        // The log becomes unavailable after load: info reads the cached state without IO.
        fail.store(true, Ordering::SeqCst);
        for _ in 0..10 {
            assert_eq!(session.transfer_blocked(), Some(true));
        }
        assert_eq!(scans.load(Ordering::SeqCst), scanned);
        // An abort that did not reach the log cannot silently un-revoke.
        hub.append(&session, "mux", "transfer_aborted", json!({}));
        assert_eq!(session.transfer_blocked(), Some(true));
        fail.store(false, Ordering::SeqCst);
        hub.append(&session, "mux", "transfer_aborted", json!({}));
        assert_eq!(session.transfer_blocked(), Some(false));
        session.note_transfer_authority(2, true);
        assert_eq!(session.transfer_blocked(), Some(false), "older replay undid abort");
        hub.append(&session, "mux", "transfer_out", json!({}));
        hub.append(&session, "mux", "imported", json!({}));
        assert_eq!(session.transfer_blocked(), Some(false), "returned import stayed revoked");
        // Unreadable restored history remains unknown, never guessed to be local.
        *session.transfer_authority.lock().unwrap() = None;
        fail.store(true, Ordering::SeqCst);
        hub.restore_transfer_authority(&session);
        assert_eq!(session.transfer_blocked(), None);
    }

    /// A move whose `transfer_out` never reached the log does not begin: the cache would
    /// still read the chat as local while its bundle is out.
    #[tokio::test]
    async fn a_begin_whose_move_is_not_logged_fails() {
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let mut config: Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", fake]}},
            "defaultHarness": "fake",
        }))
        .unwrap();
        config.store.mode = crate::config::StoreMode::Memory;
        let inner = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
        let store = CountingStore {
            inner,
            scans: Arc::new(AtomicU64::new(0)),
            fail: Arc::new(AtomicBool::new(false)),
            refuse: &["transfer_out"],
        };
        let hub = Arc::new(Hub::new(config, Box::new(store)));
        let meta: SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "begin-unlogged", "name": "begin",
            "harness": "fake", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
        }))
        .unwrap();
        hub.store.save(&meta).unwrap();
        let session = hub.make_session(meta);
        hub.sessions.lock().unwrap().insert(session.id.clone(), session.clone());
        let begun =
            hub.transfer_request("_acpmux/transfer_begin", &json!({"sessionId": session.id})).await;
        if let Ok(manifest) = &begun
            && let Some(id) = manifest["transferId"].as_str()
        {
            let _ = std::fs::remove_dir_all(super::transfer_out::transfers_dir().join(id));
        }
        assert!(begun.is_err(), "a move began without its durable record: {begun:?}");
        assert_eq!(session.transfer_blocked(), Some(false));
        assert!(session.moving().is_none(), "the failed begin left the chat frozen");
    }

    /// Only the daemon's own records (`dir: "mux"`) decide: an agent's update may carry any
    /// kind, so one named `transfer_aborted` or `imported` never reopens a moving chat.
    #[test]
    fn an_agent_record_named_like_a_transfer_event_decides_nothing() {
        let mut config = Config::default();
        config.store.mode = crate::config::StoreMode::Memory;
        let store = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
        let hub = Hub::new(config, store);
        let meta: SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "agent-named", "name": "agent",
            "harness": "fake", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
        }))
        .unwrap();
        hub.store.save(&meta).unwrap();
        let session = hub.make_session(meta);
        hub.append(&session, "mux", "transfer_out", json!({"transferId": "xfer"}));
        for kind in ["transfer_aborted", "imported"] {
            hub.append(&session, "in", kind, json!({}));
        }
        assert_eq!(session.transfer_blocked(), Some(true), "an agent's record reopened it");
        *session.transfer_authority.lock().unwrap() = None;
        hub.restore_transfer_authority(&session);
        assert_eq!(session.transfer_blocked(), Some(true), "a restart read the agent's record");
    }

    /// Logs whether the chat was still moving when its `transfer_aborted` was appended.
    struct AbortOrderStore {
        inner: Box<dyn Store>,
        session: Arc<StdMutex<Option<Arc<Session>>>>,
        moving_at_abort: Arc<StdMutex<Option<bool>>>,
    }

    impl Store for AbortOrderStore {
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
            if record.kind == "transfer_aborted"
                && let Some(session) = self.session.lock().unwrap().as_ref()
            {
                *self.moving_at_abort.lock().unwrap() = Some(session.moving().is_some());
            }
            self.inner.append(id, record)
        }
        fn events(&self, id: &str, after: u64, limit: usize) -> anyhow::Result<Vec<EventRecord>> {
            self.inner.events(id, after, limit)
        }
        fn scan_strict(
            &self,
            id: &str,
            after: u64,
            visit: &mut dyn FnMut(EventRecord) -> bool,
        ) -> anyhow::Result<()> {
            self.inner.scan_strict(id, after, visit)
        }
        fn delete(&self, id: &str) -> anyhow::Result<()> {
            self.inner.delete(id)
        }
    }

    /// An abort logs `transfer_aborted` while the chat is still frozen: a new move can begin
    /// only after it, so a late abort record never follows (and so never undoes) its
    /// `transfer_out`.
    #[tokio::test]
    async fn an_abort_is_logged_before_the_chat_can_move_again() {
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let mut config: Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", fake]}},
            "defaultHarness": "fake",
        }))
        .unwrap();
        config.store.mode = crate::config::StoreMode::Memory;
        let inner = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
        let watched = Arc::new(StdMutex::new(None));
        let moving_at_abort = Arc::new(StdMutex::new(None));
        let store = AbortOrderStore {
            inner,
            session: watched.clone(),
            moving_at_abort: moving_at_abort.clone(),
        };
        let hub = Arc::new(Hub::new(config, Box::new(store)));
        let meta: SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "abort-order", "name": "abort",
            "harness": "fake", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
        }))
        .unwrap();
        hub.store.save(&meta).unwrap();
        let session = hub.make_session(meta);
        hub.sessions.lock().unwrap().insert(session.id.clone(), session.clone());
        *watched.lock().unwrap() = Some(session.clone());
        let begun = hub
            .transfer_request("_acpmux/transfer_begin", &json!({"sessionId": session.id}))
            .await
            .unwrap();
        let params = json!({"sessionId": session.id, "transferId": begun["transferId"]});
        hub.transfer_request("_acpmux/transfer_abort", &params).await.unwrap();
        assert_eq!(
            *moving_at_abort.lock().unwrap(),
            Some(true),
            "unfrozen before the abort logged"
        );
        assert_eq!(session.transfer_blocked(), Some(false));
        assert!(session.moving().is_none());
    }

    /// An agent's update named like a move decides neither the queue's freeze after a restart
    /// nor whether a closed chat moved away.
    #[test]
    fn an_agent_record_named_like_a_move_freezes_or_moves_nothing() {
        let mut config = Config::default();
        config.store.mode = crate::config::StoreMode::Memory;
        let store = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
        let hub = Hub::new(config, store);
        let chat = |id: &str| {
            let meta: SessionMeta = serde_json::from_value(json!({
                "schema": crate::store::META_SCHEMA, "id": id, "name": id,
                "harness": "fake", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
            }))
            .unwrap();
            hub.store.save(&meta).unwrap();
            hub.make_session(meta)
        };
        let frozen = chat("agent-unfreeze");
        hub.append(&frozen, "mux", "transfer_out", json!({"transferId": "xfer"}));
        hub.append(&frozen, "in", "transfer_aborted", json!({}));
        hub.restore_queue(&frozen);
        assert_eq!(frozen.moving().as_deref(), Some("xfer"), "an agent's record unfroze it");

        let closed = chat("agent-moved");
        hub.append(&closed, "in", "transferred", json!({}));
        closed.meta.lock().unwrap().status = SessionStatus::Closed;
        assert!(!hub.moved_away(&closed), "an agent's record moved it away");
        assert!(!hub.moved_on(&closed.id).unwrap(), "an agent's record moved its tasks on");
    }

    /// An abort whose record never reached the log leaves the chat frozen: it may not take
    /// prompts while its durable `transfer_out` says it is leaving.
    #[tokio::test]
    async fn an_abort_whose_record_is_not_logged_keeps_the_chat_frozen() {
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let mut config: Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", fake]}},
            "defaultHarness": "fake",
        }))
        .unwrap();
        config.store.mode = crate::config::StoreMode::Memory;
        let inner = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
        let store = CountingStore {
            inner,
            scans: Arc::new(AtomicU64::new(0)),
            fail: Arc::new(AtomicBool::new(false)),
            refuse: &["transfer_aborted"],
        };
        let hub = Arc::new(Hub::new(config, Box::new(store)));
        let meta: SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "abort-unlogged", "name": "abort",
            "harness": "fake", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
        }))
        .unwrap();
        hub.store.save(&meta).unwrap();
        let session = hub.make_session(meta);
        hub.sessions.lock().unwrap().insert(session.id.clone(), session.clone());
        let begun = hub
            .transfer_request("_acpmux/transfer_begin", &json!({"sessionId": session.id}))
            .await
            .unwrap();
        let transfer = begun["transferId"].as_str().unwrap().to_owned();
        let params = json!({"sessionId": session.id, "transferId": transfer});
        let aborted = hub.transfer_request("_acpmux/transfer_abort", &params).await;
        let _ = std::fs::remove_dir_all(super::transfer_out::transfers_dir().join(&transfer));
        assert!(aborted.is_err(), "an abort reported done without its record: {aborted:?}");
        assert_eq!(session.moving().as_deref(), Some(transfer.as_str()), "it unfroze");
        assert_eq!(session.transfer_blocked(), Some(true));
    }

    /// An import whose own `imported` receipt never reached the log fails and leaves no chat:
    /// otherwise its copied records would decide its transfer state after a restart.
    #[tokio::test]
    async fn an_import_whose_receipt_is_not_logged_fails() {
        let dir =
            std::env::temp_dir().join(format!("acpmux-import-receipt-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let hub_with = |refuse: &'static [&'static str]| {
            let mut config: Config = serde_json::from_value(json!({
                "harnesses": {"fake": {"argv": ["python3", fake]}},
                "defaultHarness": "fake",
            }))
            .unwrap();
            config.store.mode = crate::config::StoreMode::Memory;
            let inner = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
            let store = CountingStore {
                inner,
                scans: Arc::new(AtomicU64::new(0)),
                fail: Arc::new(AtomicBool::new(false)),
                refuse,
            };
            Hub::new(config, Box::new(store))
        };
        let source = hub_with(&[]);
        let meta: SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "import-receipt", "name": "receipt",
            "harness": "fake", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
        }))
        .unwrap();
        source.store.save(&meta).unwrap();
        let session = source.make_session(meta);
        source.append(&session, "mux", "transfer_aborted", json!({"transferId": "xfer"}));
        let bundle = source.export(&session, &dir).unwrap();

        let here = Arc::new(hub_with(&["imported"]));
        let imported = here.import(&bundle, None).await;
        let _ = std::fs::remove_dir_all(&dir);
        assert!(imported.is_err(), "an import stood without its receipt");
        assert!(here.resolve("import-receipt").is_err(), "the failed import left its chat");
    }

    /// A begin whose bundle fails ends its move only once that end is logged: otherwise the
    /// chat stays frozen, as its durable `transfer_out` says.
    #[tokio::test]
    async fn a_failed_bundle_whose_abort_is_not_logged_keeps_the_chat_frozen() {
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let mut config: Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", fake]}},
            "defaultHarness": "fake",
        }))
        .unwrap();
        config.store.mode = crate::config::StoreMode::Memory;
        let inner = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
        let store = CountingStore {
            inner,
            scans: Arc::new(AtomicU64::new(0)),
            fail: Arc::new(AtomicBool::new(false)),
            refuse: &["transfer_aborted", "events"],
        };
        let hub = Arc::new(Hub::new(config, Box::new(store)));
        let meta: SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "bundle-failed", "name": "bundle",
            "harness": "fake", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
        }))
        .unwrap();
        hub.store.save(&meta).unwrap();
        let session = hub.make_session(meta);
        hub.sessions.lock().unwrap().insert(session.id.clone(), session.clone());
        let begun =
            hub.transfer_request("_acpmux/transfer_begin", &json!({"sessionId": session.id})).await;
        assert!(begun.is_err(), "the bundle was made: {begun:?}");
        assert_eq!(session.transfer_blocked(), Some(true));
        assert!(session.moving().is_some(), "it unfroze without a logged abort");
    }
}
