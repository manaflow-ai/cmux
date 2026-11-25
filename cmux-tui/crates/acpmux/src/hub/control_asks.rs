//! The owner's pending asks, projected without walking closed rows or copying a session row.
use super::*;
use std::collections::VecDeque;

impl Hub {
    pub(crate) fn control_sessions(&self) -> VecDeque<Arc<Session>> {
        self.live_session_handles().into_iter().filter(|s| s.has_pending_permissions()).collect()
    }

    /// A bounded page of this session's current asks. New keys behind `after` reach the live
    /// subscription, which starts before the first page. No proof is reconstructed from a row.
    pub(crate) fn control_ask_page(
        &self,
        session: &Session,
        after: Option<&str>,
        budget: usize,
    ) -> Result<(Vec<Value>, Option<String>), RpcError> {
        let permissions = session.permissions.lock().unwrap_or_else(|e| e.into_inner());
        let meta = session.meta();
        let mut keys: Vec<_> = permissions
            .pending
            .keys()
            .filter(|key| after.is_none_or(|after| key.as_str() > after))
            .collect();
        keys.sort_unstable();
        let mut entries = Vec::new();
        let mut bytes = 0;
        let mut last = None;
        for key in keys {
            let Some(ask) = permissions.pending.get(key) else { continue };
            let value = self.control_ask_value(&meta, key, ask);
            let size = value.to_string().len() + 1;
            if size > budget && entries.is_empty() {
                return Err(RpcError::too_large(size));
            }
            if bytes + size > budget {
                return Ok((entries, last));
            }
            bytes += size;
            last = Some(key.clone());
            entries.push(value);
        }
        Ok((entries, None))
    }

    pub(crate) fn control_ask(&self, id: &str, permission: &str) -> Option<Value> {
        let session = self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(id).cloned()?;
        let permissions = session.permissions.lock().unwrap_or_else(|e| e.into_inner());
        let ask = permissions.pending.get(permission)?;
        Some(self.control_ask_value(&session.meta(), permission, ask))
    }

    fn control_ask_value(&self, meta: &SessionMeta, id: &str, ask: &PendingPermission) -> Value {
        json!({"kind": "asks", "key": [meta.id, id], "value": {
            "sessionId": meta.id, "permissionId": id, "request": ask.request,
            "personInstance": self.person.instance(), "decisionNonce": ask.decision_nonce,
            "parent": meta.subsession.as_ref().map(|s| &s.started_by).or(meta.parent_id.as_ref()),
            "handle": meta.subsession.as_ref().map(|s| &s.short_name).unwrap_or(&meta.name),
            "label": crate::secret_scan::mask(meta.title.as_deref().unwrap_or(&meta.name)),
        }})
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (Arc<Hub>, Arc<Session>) {
        let mut config = crate::config::Config::default();
        config.store.mode = crate::config::StoreMode::Memory;
        let store =
            crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(config, store);
        let session = hub.insert_test_session(serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "chat", "name": "worker", "harness": "fake",
            "cwd": "/tmp", "status": "waiting", "createdAt": 1, "updatedAt": 1, "title": "A label"
        })).unwrap());
        for i in 0..30 {
            let (reply, _rx) = tokio::sync::oneshot::channel();
            session.permissions.lock().unwrap().pending.insert(
                format!("ask-{i:03}"),
                PendingPermission {
                    request: json!({"text": "x".repeat(5000)}),
                    reply,
                    decision_nonce: format!("nonce-{i}"),
                    ancestor_may_answer: false,
                    prev_status: SessionStatus::Idle,
                    agent_request: None,
                    agent_host_incarnation: None,
                },
            );
        }
        (hub, session)
    }

    #[tokio::test]
    async fn controls_ask_pages_keep_nonce_run_and_labels_without_session_rows() {
        let (hub, session) = fixture();
        let before = hub.summaries_built.load(Ordering::SeqCst);
        let mut after = None;
        let mut keys = HashSet::new();
        let mut pages = 0;
        loop {
            let (entries, next) =
                hub.control_ask_page(&session, after.as_deref(), 16 << 10).unwrap();
            assert!(
                entries.to_vec().iter().map(|e| e.to_string().len() + 1).sum::<usize>() <= 16 << 10
            );
            for entry in entries {
                assert_eq!(entry["value"]["personInstance"], hub.person.instance());
                assert!(entry["value"]["decisionNonce"].as_str().unwrap().starts_with("nonce-"));
                assert_eq!(entry["value"]["label"], "A label");
                assert_eq!(entry["value"]["handle"], "worker");
                assert!(keys.insert(entry["key"][1].as_str().unwrap().to_owned()));
            }
            pages += 1;
            let Some(next) = next else { break };
            after = Some(next);
        }
        assert_eq!(keys.len(), 30);
        assert!(pages > 1);
        assert_eq!(hub.summaries_built.load(Ordering::SeqCst), before);
        session.permissions.lock().unwrap().pending.remove("ask-000");
        assert!(hub.control_ask("chat", "ask-000").is_none(), "an old event cannot resurrect it");
    }

    #[tokio::test]
    async fn controls_oversized_ask_is_an_explicit_error() {
        let (hub, session) = fixture();
        assert!(hub.control_ask_page(&session, None, 1024).is_err());
    }
}
