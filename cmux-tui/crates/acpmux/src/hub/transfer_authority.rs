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
        if let Some(blocked) = transfer_state(&record.kind) {
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

fn transfer_state(kind: &str) -> Option<bool> {
    match kind {
        "transfer_out" | "transferred" => Some(true),
        "transfer_aborted" | "imported" => Some(false),
        _ => None,
    }
}

impl Hub {
    pub(super) fn restore_transfer_authority(&self, session: &Session) {
        let mut latest = (0, false);
        // Fail closed on an unreadable log. This runs only in load_session_log, never in
        // info, and does not hold the cache lock while reading disk.
        match self.store.scan_strict(&session.id, 0, &mut |record| {
            if let Some(blocked) = transfer_state(&record.kind)
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
            Box::new(CountingStore { inner, scans: scans.clone(), fail: fail.clone() }),
        );
        let meta: SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "transfer-cache", "name": "cache",
            "harness": "fake", "cwd": "/tmp", "status": "closed", "createdAt": 1, "updatedAt": 1
        }))
        .unwrap();
        let session = hub.make_session(meta);
        assert_eq!(session.transfer_blocked(), Some(false));
        hub.append(&session, "mux", "transfer_out", json!({}));
        hub.append(&session, "mux", "transferred", json!({}));
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
}
