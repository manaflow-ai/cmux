//! Durable surge thread ownership bindings.
//!
//! A binding is deliberately owned by the recipient session.  The caller may only set or
//! remove a binding for the session it is running, or as the person; the owner id is always
//! taken from the resolved target rather than accepted from request parameters.  Records live in
//! that session's journal, so triage can resolve the owner after a restart without trusting a
//! sender supplied label.

use super::*;
use std::collections::BTreeMap;

pub(crate) const RECORD_KIND: &str = "inbox_subscription";

fn thread_id(thread: &str) -> Result<&str, RpcError> {
    let thread = thread.trim();
    if thread.is_empty() {
        Err(RpcError::invalid_params("threadId must not be empty"))
    } else {
        Ok(thread)
    }
}

/// Replay the latest active binding for each thread.  The owner is checked against the target
/// session even though the RPC never accepts an owner id, so old or hand-written records cannot
/// make one session claim another's thread.
fn replay(
    target_id: &str,
    records: impl IntoIterator<Item = crate::store::EventRecord>,
) -> BTreeMap<String, String> {
    let mut bindings = BTreeMap::new();
    for record in records {
        if record.kind != RECORD_KIND {
            continue;
        }
        let Some(thread) =
            record.msg.get("threadId").and_then(Value::as_str).filter(|v| !v.is_empty())
        else {
            continue;
        };
        let Some(owner) = record.msg.get("ownerSessionId").and_then(Value::as_str) else {
            continue;
        };
        if owner != target_id {
            continue;
        }
        if record.msg.get("active").and_then(Value::as_bool).unwrap_or(true) {
            bindings.insert(thread.to_owned(), owner.to_owned());
        } else {
            bindings.remove(thread);
        }
    }
    bindings
}

impl Hub {
    fn inbox_subscription_bindings(
        &self,
        session: &Session,
    ) -> Result<BTreeMap<String, String>, RpcError> {
        let mut records = Vec::new();
        self.scan_for_rebuild(session, &[RECORD_KIND], &mut |record| {
            records.push(record);
            true
        })
        .map_err(|e| RpcError::internal(format!("read inbox subscriptions: {e}")))?;
        Ok(replay(&session.id, records))
    }

    /// Set the target session's own durable binding for `thread`.
    pub(crate) fn set_inbox_subscription(
        &self,
        session: &Session,
        thread: &str,
    ) -> Result<Value, RpcError> {
        let thread = thread_id(thread)?;
        let owner = session.id.as_str();
        let (_, stored) = self.append_logged(
            session,
            "mux",
            RECORD_KIND,
            json!({"threadId": thread, "ownerSessionId": owner, "active": true}),
            None,
        );
        if !stored {
            return Err(RpcError::internal("could not persist inbox subscription"));
        }
        self.note_inbox_subscription(owner, thread, true);
        Ok(json!({
            "sessionId": owner,
            "threadId": thread,
            "ownerSessionId": owner,
            "subscribed": true,
        }))
    }

    /// Remove the target session's durable binding for `thread`.
    pub(crate) fn remove_inbox_subscription(
        &self,
        session: &Session,
        thread: &str,
    ) -> Result<Value, RpcError> {
        let thread = thread_id(thread)?;
        let owner = session.id.as_str();
        let (_, stored) = self.append_logged(
            session,
            "mux",
            RECORD_KIND,
            json!({"threadId": thread, "ownerSessionId": owner, "active": false}),
            None,
        );
        if !stored {
            return Err(RpcError::internal("could not persist inbox subscription removal"));
        }
        self.note_inbox_subscription(owner, thread, false);
        Ok(json!({
            "sessionId": owner,
            "threadId": thread,
            "ownerSessionId": owner,
            "subscribed": false,
        }))
    }

    /// List the target session's active durable thread bindings.
    pub(crate) fn inbox_subscriptions(&self, session: &Session) -> Result<Value, RpcError> {
        let subscriptions = self
            .inbox_subscription_bindings(session)?
            .into_iter()
            .map(|(thread, owner)| json!({"threadId": thread, "ownerSessionId": owner}))
            .collect::<Vec<_>>();
        Ok(json!({"sessionId": session.id, "subscriptions": subscriptions}))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn replay_keeps_latest_self_binding_and_survives_remove() {
        let records = vec![
            crate::store::EventRecord {
                seq: 1,
                at: 1,
                dir: "mux".into(),
                kind: RECORD_KIND.into(),
                msg: json!({"threadId":"pr:1","ownerSessionId":"owner","active":true}),
                host_seq: None,
            },
            crate::store::EventRecord {
                seq: 2,
                at: 2,
                dir: "mux".into(),
                kind: RECORD_KIND.into(),
                msg: json!({"threadId":"pr:2","ownerSessionId":"other","active":true}),
                host_seq: None,
            },
            crate::store::EventRecord {
                seq: 3,
                at: 3,
                dir: "mux".into(),
                kind: RECORD_KIND.into(),
                msg: json!({"threadId":"pr:1","ownerSessionId":"owner","active":false}),
                host_seq: None,
            },
        ];
        assert!(replay("owner", records).is_empty());

        let active = vec![crate::store::EventRecord {
            seq: 4,
            at: 4,
            dir: "mux".into(),
            kind: RECORD_KIND.into(),
            msg: json!({"threadId":"pr:3","ownerSessionId":"owner","active":true}),
            host_seq: None,
        }];
        assert_eq!(replay("owner", active).keys().next().map(String::as_str), Some("pr:3"));
    }
}
