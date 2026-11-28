//! Part of `Hub`; see `hub/mod.rs`. A deleted chat is kept for a grace before it goes (RFD 0163
//! row 24: "No destructive default ... deletes are soft with a grace period"), as Cloud machines
//! (cmux-platform#1984) and snapshots (cmux-platform#1962) are.
//!
//! A delete that asks for the grace (`_acpmux/kill {purge: true, grace: true}`, or
//! `session/delete {grace: true}`) stops the chat as `session stop` does and marks it deleted:
//! tags [`DELETED_TAG`] (when, Unix ms) and [`DELETED_UNTIL_TAG`] (until when, [`GRACE`] later),
//! saved on its metadata. It then leaves the session map as a purge does, with the same `purged`
//! notice (`deleted: true`, `restorableUntil`), so every list, watcher and peer drops its row. Its
//! log, folder, uploads, cost entry and audit entries stay on disk. The reply is
//! `{deleted: true, restorableUntil}`.
//!
//! `_acpmux/undelete {sessionId}` brings it back inside the grace: read from the store again as a
//! daemon start reads a chat, its two tags removed, closed, with its whole log; under another name
//! (`NAME-2`) when a chat took its name meanwhile. `_acpmux/deleted` lists the deleted chats.
//!
//! Once the grace ends, the retention worker (`retention.rs`) purges it through the existing
//! delete (`Hub::kill` with `purge`). A daemon restart keeps the deleted chats out of the map
//! ([`Hub::hold_deleted`]), so none comes back by a restart.
//!
//! A delete that does not ask for the grace is today's delete, at once: every older client, and
//! the daemon's own purges (a side chat, a cancelled fork, a failed start). An older daemon
//! ignores `grace` and deletes at once, so a new client never keeps a chat it meant to delete.

use super::*;

/// The tag a deleted chat carries: when it was deleted (Unix ms).
pub(crate) const DELETED_TAG: &str = "deleted";
/// The tag a deleted chat carries: until when it may be restored (Unix ms).
pub(crate) const DELETED_UNTIL_TAG: &str = "deletedUntil";
/// How long a deleted chat may be restored: 7 days, as a Cloud machine
/// (`machine_delete_grace_days`, cmux-platform#1984).
pub(crate) const GRACE: std::time::Duration = std::time::Duration::from_secs(7 * 86_400);
/// The capability a daemon that keeps deleted chats lists (`capabilities.rs`).
pub(crate) const FEATURE: &str = "chat-soft-delete-v1";

/// Until when `meta`'s chat may be restored, when it is deleted.
pub(crate) fn deleted_until(meta: &SessionMeta) -> Option<u64> {
    meta.tags.get(DELETED_UNTIL_TAG)?.value.parse().ok()
}

/// Whether the request asks for the grace (`grace: true`).
pub(crate) fn asks_grace(params: &Value) -> bool {
    params.get("grace").and_then(Value::as_bool) == Some(true)
}

/// The deleted chats this daemon keeps, by id: each one's metadata as it left the map.
#[derive(Default)]
pub(crate) struct Deleted(StdMutex<HashMap<String, SessionMeta>>);

impl Deleted {
    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, SessionMeta>> {
        self.0.lock().unwrap_or_else(|e| e.into_inner())
    }
}

/// The row `_acpmux/deleted` lists for a deleted chat.
fn deleted_row(meta: &SessionMeta) -> Value {
    let at = meta.tags.get(DELETED_TAG).and_then(|t| t.value.parse::<u64>().ok());
    json!({
        "sessionId": meta.id,
        "name": meta.name,
        "title": meta.title,
        "deletedAt": at,
        "restorableUntil": deleted_until(meta),
    })
}

impl Hub {
    /// Deletes `session` with the grace (module docs): stopped as `stop_why` stops it (and only
    /// when `condition` holds), marked, saved, and out of the map. The reply.
    pub(crate) async fn soft_delete(
        &self,
        session: &Arc<Session>,
        condition: super::stop_if_idle::StopCondition,
        why: crate::close_why::CloseWhy,
    ) -> Result<Value, RpcError> {
        self.stop_why(session, false, condition, why).await?;
        let at = now_ms();
        let until = at.saturating_add(u64::try_from(GRACE.as_millis()).unwrap_or(u64::MAX));
        let mut set = serde_json::Map::new();
        set.insert(DELETED_TAG.into(), Value::String(at.to_string()));
        set.insert(DELETED_UNTIL_TAG.into(), Value::String(until.to_string()));
        self.set_tags_answered(session, Some(&set), &[], None)?;
        // On disk before it leaves: a restore and a restart read it from the store.
        self.meta_barrier(session)?;
        let mut sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
        if !sessions.get(&session.id).is_some_and(|current| Arc::ptr_eq(current, session)) {
            return Err(RpcError::invalid_params("the chat changed while it was deleted")
                .with_data(json!({"reason": "session.replaced"})));
        }
        sessions.remove(&session.id);
        self.remove_live_session_index(&session.id);
        self.deleted.lock().insert(session.id.clone(), session.meta());
        // The purge's own notice, so every list drops the row as it drops a purged one.
        let _ = self.events.send(HubEvent {
            session_id: session.id.clone(),
            record: Arc::new(EventRecord {
                seq: session.meta().last_seq + 1,
                at: now_ms(),
                dir: "mux".into(),
                kind: "purged".into(),
                msg: json!({"sessionId": session.id, "deleted": true, "restorableUntil": until}),
                host_seq: None,
            }),
            remote: None,
            update_line: Default::default(),
            row: Default::default(),
            list_seq: 0,
            peer_batch: false,
            event_params: Default::default(),
        });
        drop(sessions);
        self.note_rows_reading(session);
        tracing::info!(session = %session.id, until, "deleted; restorable until the grace ends");
        Ok(json!({
            "sessionId": session.id,
            "purged": false,
            "deleted": true,
            "deletedAt": at,
            "restorableUntil": until,
        }))
    }

    /// The deleted chats `metas` names leave it for the deleted set: a start installs the rest.
    pub(super) fn hold_deleted(&self, metas: &mut Vec<SessionMeta>) {
        let mut deleted = self.deleted.lock();
        metas.retain(|meta| {
            if deleted_until(meta).is_none() {
                return true;
            }
            deleted.insert(meta.id.clone(), meta.clone());
            false
        });
    }

    /// `_acpmux/deleted`: the deleted chats, soonest purged first.
    pub(crate) fn deleted_chats(&self) -> Value {
        let mut rows: Vec<&SessionMeta> = Vec::new();
        let deleted = self.deleted.lock();
        rows.extend(deleted.values());
        rows.sort_by_key(|m| (deleted_until(m), m.id.clone()));
        json!({"sessions": rows.into_iter().map(deleted_row).collect::<Vec<_>>()})
    }

    /// `_acpmux/undelete`: deleted chat `key` (its id, or its name when one deleted chat has it)
    /// back in the map inside the grace, closed, with its whole log. Its summary.
    pub(crate) fn undelete(&self, key: &str) -> Result<Value, RpcError> {
        let not_deleted = || {
            RpcError::invalid_params(format!("no deleted chat is named {key:?}"))
                .with_data(json!({"reason": "session.not_deleted"}))
        };
        let id = {
            let deleted = self.deleted.lock();
            if deleted.contains_key(key) {
                key.to_owned()
            } else {
                let named: Vec<&String> =
                    deleted.values().filter(|m| m.name == key).map(|m| &m.id).collect();
                match named.as_slice() {
                    [id] => (*id).clone(),
                    [] => return Err(not_deleted()),
                    _ => {
                        return Err(RpcError::invalid_params(format!(
                            "more than one deleted chat is named {key:?}: name its id"
                        ))
                        .with_data(json!({"reason": "session.ambiguous"})));
                    }
                }
            }
        };
        let Some(kept) = self.deleted.lock().remove(&id) else { return Err(not_deleted()) };
        if deleted_until(&kept).is_some_and(|until| until <= now_ms()) {
            // Past its grace: the next pass purges it.
            self.deleted.lock().insert(id.clone(), kept);
            return Err(RpcError::invalid_params("its grace ended: it is being deleted")
                .with_data(json!({"reason": "session.restore_expired"})));
        }
        let restore_failed = |e: RpcError, kept: SessionMeta| {
            self.deleted.lock().insert(kept.id.clone(), kept);
            e
        };
        let mut meta = match self.store.load_startup(&id) {
            Ok(Some(meta)) if meta.id == id => meta,
            Ok(_) => {
                return Err(restore_failed(
                    RpcError::internal("its record is no longer in the store"),
                    kept,
                ));
            }
            Err(e) => return Err(restore_failed(RpcError::internal(e.to_string()), kept)),
        };
        {
            let sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
            if sessions.contains_key(&id) {
                drop(sessions);
                return Err(restore_failed(
                    RpcError::invalid_params("another chat has its id now")
                        .with_data(json!({"reason": "session.replaced"})),
                    kept,
                ));
            }
            // A chat that took its name meanwhile keeps it: this one comes back as `NAME-2`.
            meta.name = super::new_request::suffixed_name_among(
                &sessions,
                &self.evicted.names(),
                &meta.name,
            );
        }
        self.install_stored_session(meta, false, false, false);
        let Some(session) =
            self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(&id).cloned()
        else {
            return Err(restore_failed(RpcError::internal("it was not installed"), kept));
        };
        let remove = [DELETED_TAG.to_owned(), DELETED_UNTIL_TAG.to_owned()];
        self.set_tags_answered(&session, None, &remove, None)?;
        tracing::info!(session = %id, "restored inside its grace");
        let mut summary = self.session_summary(&session);
        if let Some(obj) = summary.as_object_mut() {
            obj.insert("undeleted".into(), Value::Bool(true));
        }
        Ok(summary)
    }

    /// The retention worker's pass (`retention.rs`): every deleted chat whose grace ended is
    /// purged through the existing delete.
    pub(super) async fn purge_deleted_chats(&self) -> usize {
        self.purge_deleted_chats_at(now_ms()).await
    }

    /// [`Self::purge_deleted_chats`] as of `now` (Unix ms): how many it purged.
    pub(super) async fn purge_deleted_chats_at(&self, now: u64) -> usize {
        let due: Vec<String> = self
            .deleted
            .lock()
            .values()
            .filter(|m| deleted_until(m).is_some_and(|until| until <= now))
            .map(|m| m.id.clone())
            .collect();
        let mut purged = 0;
        for id in due {
            let Some(kept) = self.deleted.lock().remove(&id) else { continue };
            // Another chat took its id (an import under a fixed id): that chat stays.
            if self.sessions.lock().unwrap_or_else(|e| e.into_inner()).contains_key(&id) {
                continue;
            }
            let meta = match self.store.load_startup(&id) {
                Ok(Some(meta)) if meta.id == id => meta,
                Ok(_) => continue,
                Err(e) => {
                    tracing::warn!(session = %id, "deleted chat not read for its purge: {e}");
                    self.deleted.lock().insert(id, kept);
                    continue;
                }
            };
            // In the map again, with no notice (its row went at the delete), for the delete to
            // take it as it takes any chat.
            let _ = self.install_stored(meta, false, false, true);
            let Some(session) =
                self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(&id).cloned()
            else {
                continue;
            };
            let why = crate::close_why::CloseWhy::by("daemon", "deleted; its grace ended");
            match self.kill_why(&session, true, why).await {
                Ok(()) => purged += 1,
                Err(e) => {
                    tracing::warn!(session = %id, "deleted chat not purged: {}", e.message);
                    let mut sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
                    if sessions.get(&id).is_some_and(|current| Arc::ptr_eq(current, &session)) {
                        sessions.remove(&id);
                    }
                    drop(sessions);
                    self.remove_live_session_index(&id);
                    self.deleted.lock().insert(id, kept);
                }
            }
        }
        purged
    }
}

#[cfg(test)]
#[path = "soft_delete_tests.rs"]
mod tests;
