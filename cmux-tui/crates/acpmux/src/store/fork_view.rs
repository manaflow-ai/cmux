//! A fork's history by reference. Fork Conversation copied every transcript record of the chat
//! into the fork's log before it answered: a 531-turn chat's fork wrote ~250,000 records and the
//! app waited the whole time (Leo, 2026-11-06: "it's so SLOW"; "it shouldn't have duplicated all
//! chats right?"). A fork made now writes none: its meta names the chat and the seq it was forked
//! through ([`HistoryRef`]), its own log starts past that seq, and [`ForkView`], the store every
//! reader goes through, shows the chat's [`HISTORY_KINDS`] records through that seq before the
//! fork's own. The cost of a fork no longer grows with the chat.
//!
//! The chat's log is only appended to, and retention keeps every record's `seq`
//! (`store/compact.rs`), so the records a fork shows never change under it. The reference ends
//! when the chat it names goes, or when the fork's own files are read or moved as files (a
//! transfer to another machine): then the history is written into the fork's own log as segment
//! `000000` (a log's own segments start at `000001`, `LocalStore::open_writer`), and its meta
//! drops the reference ([`ForkView::materialize`]). Until the meta drops it, a read takes the
//! fork's own records past the seq only, so a segment `000000` written meanwhile is never read
//! twice. A fork of a fork names the fork, whose own view this one reads through.
//!
//! A store that cannot write segment `000000` ([`Store::history_writer`], the journal store's
//! log) gets copies as before (`hub/fork.rs`).

use super::*;
use std::sync::RwLock;

/// The records a fork shows of its chat: what attach replays as the chat's transcript.
pub const HISTORY_KINDS: &[&str] = &[
    "user_message",
    "agent_message_chunk",
    "agent_thought_chunk",
    "tool_call",
    "tool_call_update",
    "plan",
    "turn_started",
    "turn_result",
    "turn_end",
];

/// The chat a fork shows the history of, through `through_seq`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct HistoryRef {
    pub session: String,
    pub through_seq: u64,
}

/// Writes a fork's history as its log's first segment; nothing is in place until `commit`.
pub trait HistoryWriter {
    fn write(&mut self, record: &EventRecord) -> Result<()>;
    fn commit(self: Box<Self>) -> Result<()>;
}

/// The store the hub reads and writes through: `inner`, with every fork that names a
/// [`HistoryRef`] shown with its chat's history ([module docs](self)).
pub struct ForkView {
    inner: Box<dyn Store>,
    /// Each referencing fork's reference, from its meta as the store saved or listed it.
    refs: RwLock<HashMap<String, HistoryRef>>,
    /// Held by `materialize` while it drops a reference and by a save of a meta that names one,
    /// from its check to its write: a save that read the reference first cannot write it back
    /// after the drop (review of #37020: after a restart the fork named its deleted chat again).
    dropping: std::sync::Mutex<()>,
}

fn is_history(kind: &str) -> bool {
    HISTORY_KINDS.contains(&kind)
}

impl ForkView {
    pub fn new(inner: Box<dyn Store>) -> Self {
        Self { inner, refs: RwLock::new(HashMap::new()), dropping: Default::default() }
    }

    fn reference(&self, id: &str) -> Option<HistoryRef> {
        self.refs.read().unwrap_or_else(|e| e.into_inner()).get(id).cloned()
    }

    fn note(&self, meta: &SessionMeta) {
        let mut refs = self.refs.write().unwrap_or_else(|e| e.into_inner());
        match &meta.history_from {
            Some(r) => refs.insert(meta.id.clone(), r.clone()),
            None => refs.remove(&meta.id),
        };
    }

    /// Writes the history `id` references into its own log and drops the reference: before its
    /// chat goes, or before its files are read or moved as files. Nothing for a session that
    /// references none. A failure leaves the reference as it was.
    pub fn materialize(&self, id: &str) -> Result<()> {
        let Some(reference) = self.reference(id) else { return Ok(()) };
        let Some(mut writer) = self.inner.history_writer(id)? else {
            anyhow::bail!("this store cannot hold a fork's history");
        };
        let mut failed = None;
        self.scan(&reference.session, 0, &mut |rec| {
            if rec.seq > reference.through_seq {
                return false;
            }
            if is_history(&rec.kind)
                && let Err(e) = writer.write(&rec)
            {
                failed = Some(e);
                return false;
            }
            true
        })?;
        if let Some(e) = failed {
            return Err(e);
        }
        writer.commit()?;
        let _dropping = self.dropping.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(mut meta) = self.inner.load(id)? {
            meta.history_from = None;
            meta.history_kept_through = Some(reference.through_seq);
            self.inner.save(&meta)?;
        }
        self.refs.write().unwrap_or_else(|e| e.into_inner()).remove(id);
        Ok(())
    }

    /// The forks that reference `id`'s history.
    fn forks_of(&self, id: &str) -> Vec<String> {
        let refs = self.refs.read().unwrap_or_else(|e| e.into_inner());
        refs.iter().filter(|(_, r)| r.session == id).map(|(fork, _)| fork.clone()).collect()
    }
}

impl Store for ForkView {
    fn list(&self) -> Result<Vec<SessionMeta>> {
        let metas = self.inner.list()?;
        metas.iter().for_each(|m| self.note(m));
        Ok(metas)
    }
    fn load(&self, id: &str) -> Result<Option<SessionMeta>> {
        let meta = self.inner.load(id)?;
        if let Some(m) = &meta {
            self.note(m);
        }
        Ok(meta)
    }
    fn load_startup(&self, id: &str) -> Result<Option<SessionMeta>> {
        let meta = self.inner.load_startup(id)?;
        if let Some(m) = &meta {
            self.note(m);
        }
        Ok(meta)
    }
    fn save(&self, meta: &SessionMeta) -> Result<()> {
        // A save that names no reference must not undo a materialize the hub's copy of the meta
        // has not heard of: once dropped, a reference never comes back.
        if meta.history_from.is_none() {
            self.inner.save(meta)?;
            self.note(meta);
            return Ok(());
        }
        let _dropping = self.dropping.lock().unwrap_or_else(|e| e.into_inner());
        let mut meta = meta.clone();
        if self.reference(&meta.id).is_none()
            && let Some(stored) = self.inner.load(&meta.id)?
            && stored.history_from.is_none()
        {
            meta.history_from = None;
            meta.history_kept_through = stored.history_kept_through;
        }
        self.inner.save(&meta)?;
        self.note(&meta);
        Ok(())
    }
    fn append(&self, id: &str, record: &EventRecord) -> Result<()> {
        self.inner.append(id, record)
    }
    fn flush_session(&self, id: &str) -> Result<()> {
        self.inner.flush_session(id)
    }
    fn events(&self, id: &str, after: u64, limit: usize) -> Result<Vec<EventRecord>> {
        let Some(r) = self.reference(id) else { return self.inner.events(id, after, limit) };
        let mut out = Vec::new();
        if after < r.through_seq && limit > 0 {
            self.scan(&r.session, after, &mut |rec| {
                if rec.seq > r.through_seq {
                    return false;
                }
                if is_history(&rec.kind) {
                    out.push(rec);
                }
                out.len() < limit
            })?;
        }
        if out.len() < limit {
            out.extend(self.inner.events(id, after.max(r.through_seq), limit - out.len())?);
        }
        Ok(out)
    }
    fn scan(&self, id: &str, after: u64, visit: &mut dyn FnMut(EventRecord) -> bool) -> Result<()> {
        let Some(r) = self.reference(id) else { return self.inner.scan(id, after, visit) };
        if !self.prefix(&r, after, visit)? {
            return Ok(());
        }
        self.inner.scan(id, after.max(r.through_seq), visit)
    }
    fn scan_strict(
        &self,
        id: &str,
        after: u64,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        let Some(r) = self.reference(id) else { return self.inner.scan_strict(id, after, visit) };
        let mut going = true;
        if after < r.through_seq {
            self.scan_strict(&r.session, after, &mut |rec| {
                if rec.seq > r.through_seq {
                    return false;
                }
                if is_history(&rec.kind) {
                    going = visit(rec);
                }
                going
            })?;
        }
        if !going {
            return Ok(());
        }
        self.inner.scan_strict(id, after.max(r.through_seq), visit)
    }
    fn scan_back(
        &self,
        id: &str,
        after: u64,
        before: u64,
        skip: &dyn Fn(&[u8], &[u8]) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        let Some(r) = self.reference(id) else {
            return self.inner.scan_back(id, after, before, skip, visit);
        };
        let mut going = true;
        if before > r.through_seq + 1 {
            self.inner.scan_back(id, after.max(r.through_seq), before, skip, &mut |rec| {
                going = visit(rec);
                going
            })?;
        }
        if !going || after >= r.through_seq {
            return Ok(());
        }
        let skip_other = |dir: &[u8], kind: &[u8]| {
            skip(dir, kind) || !HISTORY_KINDS.iter().any(|k| k.as_bytes() == kind)
        };
        self.scan_back(&r.session, after, before.min(r.through_seq + 1), &skip_other, &mut |rec| {
            !is_history(&rec.kind) || visit(rec)
        })
    }
    fn tail_after(&self, id: &str, after: u64) -> Result<(u64, u64)> {
        let Some(r) = self.reference(id) else { return self.inner.tail_after(id, after) };
        let (mut count, mut last) = (0, after);
        self.prefix(&r, after, &mut |rec| {
            count += 1;
            last = last.max(rec.seq);
            true
        })?;
        let (own, own_last) = self.inner.tail_after(id, after.max(r.through_seq))?;
        Ok((count + own, if own > 0 { own_last } else { last }))
    }
    fn scan_kinds(
        &self,
        id: &str,
        kinds: &[&str],
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        let Some(r) = self.reference(id) else { return self.inner.scan_kinds(id, kinds, visit) };
        let shown: Vec<&str> = kinds.iter().copied().filter(|k| is_history(k)).collect();
        let mut going = true;
        if !shown.is_empty() {
            self.scan_kinds(&r.session, &shown, &mut |rec| {
                if rec.seq > r.through_seq {
                    return false;
                }
                going = visit(rec);
                going
            })?;
        }
        if !going {
            return Ok(());
        }
        self.inner.scan_kinds(id, kinds, &mut |rec| rec.seq <= r.through_seq || visit(rec))
    }
    fn scan_kinds_strict(
        &self,
        id: &str,
        kinds: &[&str],
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        let Some(r) = self.reference(id) else {
            return self.inner.scan_kinds_strict(id, kinds, visit);
        };
        let shown: Vec<&str> = kinds.iter().copied().filter(|k| is_history(k)).collect();
        let mut going = true;
        if !shown.is_empty() {
            self.scan_kinds_strict(&r.session, &shown, &mut |rec| {
                if rec.seq > r.through_seq {
                    return false;
                }
                going = visit(rec);
                going
            })?;
        }
        if !going {
            return Ok(());
        }
        self.inner.scan_kinds_strict(id, kinds, &mut |rec| rec.seq <= r.through_seq || visit(rec))
    }
    fn scan_heads(&self, id: &str, visit: &mut dyn FnMut(&RecordHead<'_>) -> bool) -> Result<()> {
        let Some(r) = self.reference(id) else { return self.inner.scan_heads(id, visit) };
        let mut going = true;
        self.scan_heads(&r.session, &mut |head| {
            if head.seq > r.through_seq {
                return false;
            }
            if is_history(head.kind) {
                going = visit(head);
            }
            going
        })?;
        if !going {
            return Ok(());
        }
        self.inner.scan_heads(id, &mut |head| head.seq <= r.through_seq || visit(head))
    }
    fn text_entries(
        &self,
        id: &str,
        visit: &mut dyn FnMut(crate::session_search::Entry),
    ) -> Result<()> {
        if self.reference(id).is_none() {
            return self.inner.text_entries(id, visit);
        }
        let mut projector = crate::session_search::Projector::default();
        self.scan_kinds(id, crate::session_search::KINDS, &mut |rec| {
            projector.feed(&rec);
            true
        })?;
        projector.entries.into_iter().for_each(visit);
        Ok(())
    }
    fn flush(&self) -> Result<()> {
        self.inner.flush()
    }
    fn wait_durable(&self, timeout: std::time::Duration) -> Result<bool> {
        self.inner.wait_durable(timeout)
    }
    fn durability(&self) -> Option<Durability> {
        self.inner.durability()
    }
    fn stop_reason(&self) -> Option<tokio::sync::watch::Receiver<Option<String>>> {
        self.inner.stop_reason()
    }
    fn seal(&self) {
        self.inner.seal()
    }
    fn close_log(&self, id: &str) {
        self.inner.close_log(id)
    }
    fn compacted_seq(&self, id: &str) -> Option<u64> {
        self.inner.compacted_seq(id)
    }
    fn log_written_at(&self, id: &str) -> Option<u64> {
        self.inner.log_written_at(id)
    }
    fn stage_compaction(&self, id: &str, mode: CompactMode) -> Result<Option<Staged>> {
        self.inner.stage_compaction(id, mode)
    }
    /// Retention trims a chat's records in place: the forks that show them get them first, as
    /// they were (review of #37020: a fork lost the long tool output a copy had kept).
    fn commit_compaction(&self, id: &str, staged: Staged) -> Result<bool> {
        for fork in self.forks_of(id) {
            self.materialize(&fork)?;
        }
        self.inner.commit_compaction(id, staged)
    }
    /// A chat that forks reference goes only once each holds its history itself.
    fn delete(&self, id: &str) -> Result<()> {
        for fork in self.forks_of(id) {
            self.materialize(&fork)?;
        }
        self.inner.delete(id)?;
        self.refs.write().unwrap_or_else(|e| e.into_inner()).remove(id);
        Ok(())
    }
    /// Its files as files: a fork's history is in them first. None when it cannot be written
    /// there: a caller that read, moved or removed the files would take a fork without its
    /// history, so it gets no files at all.
    fn session_dir(&self, id: &str) -> Option<PathBuf> {
        if let Err(e) = self.materialize(id) {
            tracing::warn!(session = %id, "fork history not written, so its files are not given: {e}");
            return None;
        }
        self.inner.session_dir(id)
    }
    fn session_path(&self, id: &str) -> Option<PathBuf> {
        self.inner.session_path(id)
    }
    fn handoff_dir(&self) -> Option<PathBuf> {
        self.inner.handoff_dir()
    }
    fn peer_cache_dir(&self) -> Option<PathBuf> {
        self.inner.peer_cache_dir()
    }
    fn briefs_path(&self) -> Option<PathBuf> {
        self.inner.briefs_path()
    }
    fn writes_history(&self) -> bool {
        self.inner.writes_history()
    }
    fn history_writer(&self, id: &str) -> Result<Option<Box<dyn HistoryWriter + '_>>> {
        self.inner.history_writer(id)
    }
}

impl ForkView {
    /// Visits the history `r` shows past `after`, oldest first; false when `visit` stopped.
    fn prefix(
        &self,
        r: &HistoryRef,
        after: u64,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<bool> {
        let mut going = true;
        if after < r.through_seq {
            self.scan(&r.session, after, &mut |rec| {
                if rec.seq > r.through_seq {
                    return false;
                }
                if is_history(&rec.kind) {
                    going = visit(rec);
                }
                going
            })?;
        }
        Ok(going)
    }
}

#[cfg(test)]
#[path = "fork_view_tests.rs"]
mod tests;
