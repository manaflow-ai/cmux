//! Persisted fork authority. Old imports retained parent IDs, so those IDs alone cannot grant
//! transcript access. Migrate a legacy link only when both journals record the local fork and
//! neither record came through a later import. Missing, malformed or over-budget logs refuse.

use super::{Hub, Session};
use crate::store::{SessionMeta, Store};
use std::sync::Arc;

pub(super) async fn verified_parent(
    hub: &Arc<Hub>,
    meta: &SessionMeta,
    parent: &Arc<Session>,
) -> bool {
    if let Some(verified) = meta.fork_parent_verified {
        return verified;
    }
    let Some(session) =
        hub.sessions.lock().ok().and_then(|sessions| sessions.get(&meta.id).cloned())
    else {
        return false;
    };
    let (hub, meta, parent) = (hub.clone(), meta.clone(), parent.meta());
    tokio::task::spawn_blocking(move || {
        let verified = legacy_link(&*hub.store, &meta, &parent);
        {
            let Ok(mut current) = session.meta.lock() else {
                return false;
            };
            if current.parent_id != meta.parent_id || current.fork_seq != meta.fork_seq {
                return false;
            }
            current.fork_parent_verified = Some(verified);
        }
        // A failed save only repeats this conservative migration after restart.
        hub.save_meta(&session);
        verified
    })
    .await
    .unwrap_or(false)
}

fn legacy_link(store: &dyn Store, meta: &SessionMeta, parent: &SessionMeta) -> bool {
    // This runs once on demand, off the async runtime, inside the transcript read semaphore.
    // Old very long logs fail closed rather than making inspection do unlimited replay work.
    const MAX_RECORDS: usize = 100_000;
    let mut records = 0;
    let mut matched = false;
    let mut imported = false;
    let mut next_seq = 1;
    let mut complete = true;
    let child_read = store.scan_strict(&meta.id, 0, &mut |event| {
        if event.seq != next_seq {
            complete = false;
            return false;
        }
        next_seq += 1;
        records += 1;
        if records > MAX_RECORDS {
            return false;
        }
        if event.dir == "mux" {
            if event.kind == "imported" {
                imported = true;
            } else if event.kind == "forked" {
                matched = event.msg.get("parentId").and_then(|v| v.as_str())
                    == Some(parent.id.as_str())
                    && event.msg.get("forkSeq").and_then(|v| v.as_u64()) == meta.fork_seq;
            }
        }
        !imported
    });
    if child_read.is_err()
        || !complete
        || next_seq <= meta.last_seq
        || records > MAX_RECORDS
        || imported
        || !matched
    {
        return false;
    }
    // The other half must be in the real parent's journal; a bundle cannot add a fork_child
    // record to an unrelated local chat. A parent's import invalidates all earlier records.
    matched = false;
    next_seq = 1;
    let parent_read = store.scan_strict(&parent.id, 0, &mut |event| {
        if event.seq != next_seq {
            complete = false;
            return false;
        }
        next_seq += 1;
        records += 1;
        if records > MAX_RECORDS {
            return false;
        }
        if event.dir == "mux" {
            if event.kind == "imported" {
                matched = false;
            } else if event.kind == "fork_child"
                && event.msg.get("childId").and_then(|v| v.as_str()) == Some(meta.id.as_str())
                && meta.fork_seq.is_some_and(|seq| event.seq > seq)
            {
                matched = true;
            }
        }
        true
    });
    parent_read.is_ok()
        && complete
        && next_seq > parent.last_seq
        && records <= MAX_RECORDS
        && matched
}
