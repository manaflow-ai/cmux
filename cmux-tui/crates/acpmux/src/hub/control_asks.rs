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
        let session = self.session_get(id)?;
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
#[path = "control_asks_tests.rs"]
mod tests;
