//! A chat's inbox point: where its next inbox restore (`Hub::restore_inbox`) begins.
//!
//! Leo, 2026-11-19: "we need to be able to have infinite chats, infinitely long chats".
//!
//! A restart's first prompt into a chat restores its inbox (`Session::inbox`), and the restore
//! read every inbox record of the whole log: each segment's kind copy (`store/kind_index.rs`),
//! whose lines are every kind a log load reads, hashed whole after a restart. So the first send
//! after a restart grew with the chat (cmux#51494, `chat_size_sweep`: 3 ms at 1 MB, 85 ms at
//! 4 GB, 157 ms after the next restart).
//!
//! A restore saves the seq it read through (every record through it was in the journal) with the
//! records the inbox it made is built from: the `inbox` record of each message it holds, and the
//! `inbox_noticed`, `inbox_returned`, `inbox_read` and `inbox_answered` records that name one of
//! them or its notice, as the log ordered them. What it let go of is carried as ids (`removed`,
//! `trimmed`, `held_evicted`), and the surge counts as journaled. The next restore folds those
//! records, then the log past the seq: the same fold, over the records that decide what it holds
//! (`inbox_point_tests.rs` folds both ways). A message it let go of is read, noticed and answered
//! ([`super::trim`]), or withdrawn: no later record brings it back.
//!
//! A point is used when the record at its seq is the one it names (a log replaced since, by an
//! import, does not match) and its seq is not past the log's end. A fork's log joins its
//! parent's: it keeps none. A restore while records wait outside the journal saves none.

use super::surge::Counts;
use super::*;

/// The point's format. Another one is not read: the restore reads the whole log.
const VERSION: u32 = 1;

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct InboxPoint {
    pub(crate) v: u32,
    /// The last seq the restore that saved it read every inbox record through.
    pub(crate) seq: u64,
    /// That record's time and kind.
    pub(crate) at: u64,
    pub(crate) kind: String,
    pub(super) counts: Counts,
    /// The records the inbox's messages are built from, in log order.
    pub(crate) records: Vec<EventRecord>,
    pub(crate) removed: Vec<String>,
    pub(crate) trimmed: Vec<String>,
    pub(crate) held_evicted: Vec<String>,
}

impl InboxPoint {
    /// The point of `inbox`, restored from `seen` (every inbox record through `seq`, in order),
    /// with `counts` as the restore read them.
    pub(super) fn of(inbox: &Inbox, seq: u64, counts: Counts, mut seen: Vec<EventRecord>) -> Self {
        let held: std::collections::HashSet<&str> =
            inbox.items.iter().map(|i| i.prompt_id.as_str()).collect();
        let notices: std::collections::HashSet<&str> =
            inbox.items.iter().filter_map(|i| i.notice.as_deref()).collect();
        let names_held = |e: &EventRecord| {
            let ids = e.msg.get("promptIds").and_then(Value::as_array);
            ids.is_some_and(|ids| ids.iter().filter_map(Value::as_str).any(|id| held.contains(id)))
        };
        seen.retain(|e| match e.kind.as_str() {
            "inbox" => {
                e.msg.get("promptId").and_then(Value::as_str).is_some_and(|id| held.contains(id))
            }
            "inbox_noticed" | "inbox_returned" | "inbox_read" => names_held(e),
            "inbox_answered" => e
                .msg
                .get("noticePromptId")
                .and_then(Value::as_str)
                .is_some_and(|n| notices.contains(n)),
            // A withdrawal is carried as its id (`removed`), a triage as the counts.
            _ => false,
        });
        Self {
            v: VERSION,
            seq,
            at: 0,
            kind: String::new(),
            counts,
            records: seen,
            removed: inbox.removed.iter().cloned().collect(),
            trimmed: inbox.trimmed.iter().cloned().collect(),
            held_evicted: inbox.held_evicted.iter().cloned().collect(),
        }
    }
}

impl Hub {
    /// `session`'s inbox point, when it matches its log; none for a chat read whole.
    pub(super) fn read_inbox_point(&self, session: &Session) -> Option<InboxPoint> {
        if session.meta().fork_seq.is_some() {
            return None;
        }
        let bytes = self.store.inbox_point(&session.id)?;
        let point: InboxPoint = serde_json::from_slice(&bytes).ok()?;
        if point.v != VERSION || point.seq == 0 || point.seq > session.seq.load(Ordering::SeqCst) {
            return None;
        }
        let record = self.record_at(session, point.seq)?;
        (record.at == point.at && record.kind == point.kind).then_some(point)
    }

    /// Whether a restore of `session`'s inbox now may save a point: no fork, and no inbox
    /// record waits outside the journal (`kept_unstored`), past the seq the point would name.
    pub(super) fn inbox_point_saves(&self, session: &Session) -> bool {
        session.meta().fork_seq.is_none()
            && self.kept_unstored(session, Self::INBOX_KINDS).is_empty()
    }

    /// Saves `point` for `session`'s next restore, off the caller's thread when a runtime runs
    /// (the caller may be a send's first look at the inbox). A failed write leaves the last one,
    /// which is still right: the log past it is read.
    pub(super) fn save_inbox_point(&self, session: &Session, point: InboxPoint) {
        if point.seq == 0 {
            return;
        }
        let id = session.id.clone();
        let hub = session.hub_ref.get().and_then(std::sync::Weak::upgrade);
        match (hub, tokio::runtime::Handle::try_current()) {
            (Some(hub), Ok(runtime)) => {
                runtime.spawn_blocking(move || {
                    crate::qos::background(|| hub.write_inbox_point(&id, point));
                });
            }
            _ => self.write_inbox_point(&id, point),
        }
    }

    fn write_inbox_point(&self, id: &str, mut point: InboxPoint) {
        let Some(record) = self.record_in(id, point.seq) else { return };
        point.at = record.at;
        point.kind = record.kind;
        let Ok(bytes) = serde_json::to_vec(&point) else { return };
        if let Err(error) = self.store.save_inbox_point(id, &bytes) {
            tracing::debug!(session = %id, "inbox point not saved: {error:#}");
        }
    }
}

#[cfg(test)]
#[path = "inbox_point_tests.rs"]
mod tests;
