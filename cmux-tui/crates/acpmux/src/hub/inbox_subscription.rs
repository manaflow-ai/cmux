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
    /// Resolve a subscription owner to a stable local id or host-qualified remote id.
    ///
    /// Remote display names are deliberately not accepted as durable identities: the peer row
    /// may be renamed or replaced after a grant.  A remote binding therefore must name the
    /// session UUID under its peer name (`HOST/UUID`), which is the same address the outbox pins.
    pub(crate) fn inbox_subscription_owner_key(&self, key: &str) -> Result<String, RpcError> {
        if let Ok(owner) = self.resolve(key) {
            return Ok(owner.id.clone());
        }
        let Some((host, remote_id)) = key.split_once('/') else {
            return Err(RpcError::invalid_params(format!("no session: {key}")));
        };
        if host.is_empty() || uuid::Uuid::try_parse(remote_id).is_err() {
            return Err(RpcError::invalid_params(
                "ownerSessionId must be a host-qualified session UUID",
            )
            .with_data(json!({"reason": "inbox_subscription.owner_identity_unstable"})));
        }
        let Some((peer, resolved_id, _)) = self.resolve_remote(key) else {
            return Err(RpcError::invalid_params(format!("no session: {key}")));
        };
        if peer.name != host || resolved_id != remote_id {
            return Err(RpcError::invalid_params(
                "ownerSessionId must be a host-qualified session UUID",
            )
            .with_data(json!({"reason": "inbox_subscription.owner_identity_unstable"})));
        }
        Ok(format!("{host}/{remote_id}"))
    }

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

    /// Grant the recipient's `thread` to a distinct session that first subscribed to it itself.
    /// The canonical owner id comes from the resolved session, never from a journal record or
    /// a caller-controlled label.
    pub(crate) fn grant_inbox_subscription(
        &self,
        recipient: &Session,
        thread: &str,
        owner: &Session,
    ) -> Result<Value, RpcError> {
        self.grant_inbox_subscription_key(recipient, thread, &owner.id)
    }

    /// Grant a recipient's thread to a canonical local or remote owner key.
    pub(crate) fn grant_inbox_subscription_key(
        &self,
        recipient: &Session,
        thread: &str,
        owner_key: &str,
    ) -> Result<Value, RpcError> {
        let thread = thread_id(thread)?;
        if recipient.id == owner_key {
            return Err(RpcError::invalid_params(
                "inbox_subscription.owner_must_differ: grant a distinct subscriber",
            )
            .with_data(json!({"reason": "inbox_subscription.owner_must_differ"})));
        }
        let owner_id = if let Ok(owner) = self.resolve(owner_key) {
            if !self.inbox_subscription_bindings(&owner)?.contains_key(thread) {
                return Err(RpcError::invalid_params(
                    "inbox_subscription.owner_not_subscribed: owner must subscribe first",
                )
                .with_data(json!({"reason": "inbox_subscription.owner_not_subscribed"})));
            }
            owner.id.clone()
        } else {
            // Remote owners are checked by their authenticated peer address and pinned by UUID.
            // The remote daemon's self-subscription is the authority for its own journal; this
            // recipient grant records the explicit cross-daemon authorization locally.
            self.inbox_subscription_owner_key(owner_key)?
        };
        if owner_id == recipient.id {
            return Err(RpcError::invalid_params(
                "inbox_subscription.owner_must_differ: grant a distinct subscriber",
            )
            .with_data(json!({"reason": "inbox_subscription.owner_must_differ"})));
        }
        let (_, stored) = self.append_logged(
            recipient,
            "mux",
            crate::surge_triage::GRANT_KIND,
            json!({"threadId": thread, "ownerSessionId": owner_id, "active": true}),
            None,
        );
        if !stored {
            return Err(RpcError::internal("could not persist inbox subscription grant"));
        }
        Ok(json!({
            "sessionId": recipient.id,
            "threadId": thread,
            "ownerSessionId": owner_id,
            "granted": true,
        }))
    }

    /// Revoke a recipient's grant. The owner may have unsubscribed since the grant was made;
    /// resolving it still prevents stale or arbitrary ids from entering the journal.
    pub(crate) fn revoke_inbox_subscription(
        &self,
        recipient: &Session,
        thread: &str,
        owner: &Session,
    ) -> Result<Value, RpcError> {
        self.revoke_inbox_subscription_key(recipient, thread, &owner.id)
    }

    /// Revoke a recipient's grant for a canonical local or remote owner key.
    pub(crate) fn revoke_inbox_subscription_key(
        &self,
        recipient: &Session,
        thread: &str,
        owner_key: &str,
    ) -> Result<Value, RpcError> {
        let thread = thread_id(thread)?;
        let owner_id = if let Ok(owner) = self.resolve(owner_key) {
            owner.id.clone()
        } else {
            self.inbox_subscription_owner_key(owner_key)?
        };
        if recipient.id == owner_id {
            return Err(RpcError::invalid_params(
                "inbox_subscription.owner_must_differ: revoke a distinct subscriber",
            )
            .with_data(json!({"reason": "inbox_subscription.owner_must_differ"})));
        }
        let (_, stored) = self.append_logged(
            recipient,
            "mux",
            crate::surge_triage::GRANT_KIND,
            json!({"threadId": thread, "ownerSessionId": owner_id, "active": false}),
            None,
        );
        if !stored {
            return Err(RpcError::internal("could not persist inbox subscription revoke"));
        }
        Ok(json!({
            "sessionId": recipient.id,
            "threadId": thread,
            "ownerSessionId": owner_id,
            "granted": false,
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

    #[test]
    fn remote_owner_keys_require_the_authenticated_peer_and_uuid() {
        let mut config = crate::config::Config::default();
        config.store.mode = crate::config::StoreMode::Memory;
        let store =
            crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(config, store);
        let (tx, _rx) = tokio::sync::mpsc::channel(8);
        let peer = crate::peer::Peer::new("remote", "ws://127.0.0.1:9", None, None, tx);
        hub.peers.lock().unwrap().insert(peer.name.clone(), peer.clone());
        let id = "11111111-1111-4111-8111-111111111111";
        hub.apply_peer_notice(
            &peer.name,
            peer.generation,
            crate::peer::PeerNotice::sessions_from_values(vec![json!({
                "sessionId": id,
                "name": "owner-display-name",
                "status": "ready"
            })]),
        );

        assert_eq!(
            hub.inbox_subscription_owner_key(&format!("remote/{id}")).unwrap(),
            format!("remote/{id}")
        );
        let display = hub.inbox_subscription_owner_key("remote/owner-display-name").unwrap_err();
        assert_eq!(
            display.data.as_ref().and_then(|v| v.get("reason")).and_then(Value::as_str),
            Some("inbox_subscription.owner_identity_unstable")
        );
        let bare = hub.inbox_subscription_owner_key(id).unwrap_err();
        assert_eq!(bare.message, format!("no session: {id}"));
        peer.stop();
    }
}
