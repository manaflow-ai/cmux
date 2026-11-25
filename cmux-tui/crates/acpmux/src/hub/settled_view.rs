//! Part of `Hub`; see `hub/mod.rs`. A chat's settled view (cmuxterm-hq#9655 stage 1): what the
//! pane draws for it at rest, written beside its log at each turn end and answered first by a
//! `settled` `_acpmux/attach` (`server/requests/settled_attach.rs`).
//!
//! Leo, 2026-11-11: "where is the better architecture the chat literally ... only ... works 1% of
//! the time now if you consider the appearance". A cold open drew from five sources in turn (a
//! kept tail, a partial newest page, the queue restored later from the log): empty, then full,
//! then partial, then full again, and the pending count went 23 then 26. The settled view is one
//! source: the newest page the pane opens with (its own `kinds`, `limit` and `maxBytes`), the
//! queue, the pending asks, the seqs a turn can be forked through and the log's `lastSeq`, all
//! read at one moment. An open answers it, then only the records logged since (`afterSeq`).
//!
//! The page shape is the pane's, never this daemon's guess: a `settled` attach names it
//! ([`SettledKey`]), and it is kept in the view's file, so a turn end after a restart writes the
//! same shape. A chat no pane opened with `settled` has no view and writes none. A memory store
//! keeps no file, and so no view.
//!
//! The file is `<session>/settled-view.json`, written whole (`config::write_atomic`) off the
//! executor; a view never replaces a newer one. It holds at most one open page (`MAX_RECORDS`,
//! the pane's `maxBytes`), so a turn end writes at most that much.

use super::*;

/// The settled view's file, beside the chat's log.
pub(crate) const FILE: &str = "settled-view.json";
/// Its layout; a view of another one is not read.
pub(crate) const SCHEMA: u64 = 1;
/// The most records a view holds: the pane's open page (`direct.ts` `sendAttach`).
pub(crate) const MAX_RECORDS: usize = 400;

/// The page shape a `settled` attach asked: the view is written for it, and answers only an
/// attach that asks the same one.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SettledKey {
    /// The `kinds` as asked, in their order (null: every kind).
    pub kinds: Value,
    pub limit: usize,
    pub max_bytes: usize,
}

impl SettledKey {
    /// The shape of `params`, an `_acpmux/attach` for the newest page; none for a page of older
    /// or newer records, or one with more than `MAX_RECORDS`.
    pub(crate) fn of_attach(params: &Value) -> Option<Self> {
        if params.get("afterSeq").is_some_and(|v| !v.is_null())
            || params.get("beforeSeq").is_some_and(|v| !v.is_null())
        {
            return None;
        }
        let limit = params.get("limit").and_then(Value::as_u64).unwrap_or(2000) as usize;
        if limit == 0 || limit > MAX_RECORDS {
            return None;
        }
        Some(Self {
            kinds: params.get("kinds").cloned().unwrap_or(Value::Null),
            limit,
            max_bytes: page_bytes(params),
        })
    }

    pub(crate) fn filter(&self) -> Result<EventFilter, RpcError> {
        Ok(EventFilter::parse(Some(&self.kinds))?.omitting_superseded(true))
    }
}

/// One settled view, as saved.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SettledView {
    pub schema: u64,
    pub session_id: String,
    /// The chat's `createdAt`: a chat made again under the same id is another chat.
    pub created_at: u64,
    pub key: SettledKey,
    /// The log's `lastSeq` when it was read: `records` hold every record of the key's kinds up to
    /// it, back to the page's start.
    pub last_seq: u64,
    pub written_at: u64,
    pub records: Vec<EventRecord>,
    /// Older records of the key's kinds exist before `records`.
    pub has_more: bool,
    /// The queue as the chat's summary lists it (`QueuedPromptSummary` values).
    pub queue: Value,
    pub queued: u64,
    /// The asks waiting on the person (`session_detail`'s `pending`).
    pub pending: Value,
    /// The seqs of the page's ended turns (their `turn_result`), which Fork from Here takes.
    pub fork_seqs: Vec<u64>,
    /// The chat's status when it was read.
    pub status: Value,
}

impl SettledView {
    /// Whether it may stand for `session` now: the same chat, nothing in it the log no longer
    /// holds, and asked with `key`.
    pub(crate) fn answers(&self, session: &Session, key: &SettledKey) -> bool {
        let m = session.meta();
        self.schema == SCHEMA
            && self.session_id == session.id
            && self.created_at == m.created_at
            && self.last_seq <= m.last_seq
            && &self.key == key
    }

    /// The JSON an attach answers it as (`settled` in its reply); `records` go as the page's
    /// `events`, made by the caller.
    pub(crate) fn reply_fields(&self) -> Value {
        json!({
            "schema": self.schema,
            "lastSeq": self.last_seq,
            "writtenAt": self.written_at,
            "hasMore": self.has_more,
            "pageThrough": self.last_seq,
            "queue": self.queue,
            "queued": self.queued,
            "pending": self.pending,
            "forkSeqs": self.fork_seqs,
            "status": self.status,
        })
    }
}

/// The seqs of the ended turns in `records`: each completed or cancelled `turn_result`.
pub(crate) fn fork_seqs(records: &[EventRecord]) -> Vec<u64> {
    records
        .iter()
        .filter(|r| r.dir == "mux" && r.kind == "turn_result")
        .filter(|r| r.msg.get("status").and_then(Value::as_str) != Some("failed"))
        .map(|r| r.seq)
        .collect()
}

/// One writer per file at a time, so an older view never lands over a newer one.
static WRITING: std::sync::LazyLock<std::sync::Mutex<std::collections::HashSet<PathBuf>>> =
    std::sync::LazyLock::new(|| std::sync::Mutex::new(std::collections::HashSet::new()));

impl Hub {
    /// Its own file in the chat's folder: the path only (`Store::session_path`), since
    /// `session_dir` writes the chat's metadata first, which no turn end or open should pay for.
    fn settled_view_path(&self, session: &Session) -> Option<PathBuf> {
        self.store.session_path(&session.id).map(|dir| dir.join(FILE))
    }

    /// The chat's saved view, if it has one this daemon can read.
    pub(crate) fn settled_view(&self, session: &Session) -> Option<SettledView> {
        let bytes = std::fs::read(self.settled_view_path(session)?).ok()?;
        let view: SettledView = serde_json::from_slice(&bytes).ok()?;
        (view.schema == SCHEMA && view.session_id == session.id).then_some(view)
    }

    /// Reads the chat's settled view for `key` now and saves it, unless the saved one is as new.
    /// Blocking: a page read and a file write. Returns whether it wrote.
    pub(crate) fn write_settled_view(&self, session: &Session, key: &SettledKey) -> bool {
        let Some(path) = self.settled_view_path(session) else { return false };
        {
            let mut writing = WRITING.lock().unwrap_or_else(|e| e.into_inner());
            if !writing.insert(path.clone()) {
                // Another writer has it; the next turn end writes again.
                return false;
            }
        }
        let wrote = self.write_settled_view_unclaimed(session, key, &path);
        WRITING.lock().unwrap_or_else(|e| e.into_inner()).remove(&path);
        wrote
    }

    fn write_settled_view_unclaimed(
        &self,
        session: &Session,
        key: &SettledKey,
        path: &Path,
    ) -> bool {
        let Ok(filter) = key.filter() else { return false };
        // Read before the page, as an attach does: the page then holds every record up to it.
        let m = session.meta();
        if let Some(saved) = self.settled_view(session)
            && saved.key == *key
            && saved.created_at == m.created_at
            && saved.last_seq >= m.last_seq
        {
            return false;
        }
        let page = match self.events_page(
            &session.id,
            0,
            None,
            key.limit,
            Some(key.max_bytes),
            true,
            &filter,
        ) {
            Ok(page) => page,
            Err(e) => {
                tracing::debug!(session = %session.id, "settled view not read: {e}");
                return false;
            }
        };
        // A record logged between the meta read and the page (the store takes it before
        // `last_seq` moves) is past this view: the delta after `last_seq` serves it, once.
        let mut records = page.events;
        records.retain(|r| r.seq <= m.last_seq);
        let detail = self.session_summary(session);
        let mut pending =
            session.permissions.lock().unwrap_or_else(|e| e.into_inner()).pending_records();
        for p in &mut pending {
            p["personInstance"] = Value::String(self.person.instance().to_owned());
        }
        let view = SettledView {
            schema: SCHEMA,
            session_id: session.id.clone(),
            created_at: m.created_at,
            key: key.clone(),
            last_seq: m.last_seq,
            written_at: crate::store::now_ms(),
            fork_seqs: fork_seqs(&records),
            records,
            has_more: page.has_more,
            queue: detail.get("queue").cloned().unwrap_or(Value::Array(Vec::new())),
            queued: detail.get("queued").and_then(Value::as_u64).unwrap_or(0),
            pending: Value::Array(pending),
            status: detail.get("status").cloned().unwrap_or(Value::Null),
        };
        let bytes = match serde_json::to_vec(&view) {
            Ok(bytes) => bytes,
            Err(_) => return false,
        };
        match crate::config::write_atomic(path, &bytes) {
            Ok(()) => true,
            Err(e) => {
                // The chat opens as before; the next turn end writes again.
                tracing::debug!(session = %session.id, "settled view not saved: {e}");
                false
            }
        }
    }

    /// At a turn's end (`turns.rs`): the chat's view is written again for the shape its pane
    /// opens with, off the executor. A chat no pane opened with `settled` writes none.
    pub(super) fn settle_view_at_turn_end(self: &Arc<Self>, session: &Arc<Session>) {
        if self.settled_view_path(session).is_none() {
            return;
        }
        let hub = self.clone();
        let session = session.clone();
        let write = move || {
            if let Some(key) = hub.settled_view(&session).map(|v| v.key) {
                hub.write_settled_view(&session, &key);
            }
        };
        match tokio::runtime::Handle::try_current() {
            Ok(rt) => {
                rt.spawn_blocking(write);
            }
            Err(_) => write(),
        }
    }

    /// An open that found no view it could answer with: one is written now for its shape, so
    /// the chat's next open has it.
    /// After the chat's log is read (the queue a restart restores is in it), off the executor.
    pub(crate) fn settle_view_for_open(self: &Arc<Self>, session: &Arc<Session>, key: SettledKey) {
        if self.settled_view_path(session).is_none() {
            return;
        }
        let Ok(rt) = tokio::runtime::Handle::try_current() else {
            self.write_settled_view(session, &key);
            return;
        };
        let hub = self.clone();
        let session = session.clone();
        rt.spawn(async move {
            hub.session_log(&session).await;
            let _ =
                tokio::task::spawn_blocking(move || hub.write_settled_view(&session, &key)).await;
        });
    }
}

#[cfg(test)]
impl Hub {
    /// As a restart leaves a chat: its log not read yet (`log_load.rs`), and not counted by a
    /// finished pass over every log (`session_log_loaded`).
    pub(crate) fn mark_log_unread_for_test(&self, session: &Session) {
        session.log_loaded.store(false, Ordering::SeqCst);
        session.log_skipped.store(true, Ordering::SeqCst);
    }
}

#[cfg(test)]
#[path = "settled_view_tests.rs"]
mod tests;
