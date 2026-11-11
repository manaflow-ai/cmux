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

/// `id`'s forks hold its history themselves, and no fork references it until this is dropped:
/// held over a move that replaces the chat's folder, and over its delete ([`Store::release_history`]).
pub struct HistoryFence<'a> {
    store: &'a dyn Store,
    id: String,
}

impl Drop for HistoryFence<'_> {
    fn drop(&mut self) {
        self.store.end_release(&self.id);
    }
}

/// Takes a [`HistoryFence`] on `id`: an error, and no fence, when a fork could not take its history.
pub fn fence_history<'a>(store: &'a dyn Store, id: &str) -> Result<HistoryFence<'a>> {
    store.release_history(id)?;
    Ok(HistoryFence { store, id: id.to_owned() })
}

/// The chat's folder, for a move that replaces it whole, under a [`HistoryFence`]: none when the
/// chat has none on disk, and
/// an error when it has one the store would not give (a fork whose history could not be written
/// into it, `ForkView::session_dir`), since a move into it would add the incoming log to the old
/// one (review of #37020).
pub fn folder_to_replace(store: &dyn Store, id: &str) -> Result<Option<PathBuf>> {
    if let Some(dir) = store.session_dir(id) {
        return Ok(Some(dir));
    }
    if store.session_path(id).is_some_and(|path| std::fs::symlink_metadata(path).is_ok()) {
        anyhow::bail!("its history could not be written into its folder; try the move again");
    }
    Ok(None)
}

/// The store the hub reads and writes through: `inner`, with every fork that names a
/// [`HistoryRef`] shown with its chat's history ([module docs](self)).
pub struct ForkView {
    inner: Box<dyn Store>,
    /// What this view knows of the references ([`Refs`]).
    refs: RwLock<Refs>,
    /// Held exclusively by `materialize` for the whole write, so one fork's history is written
    /// once, by the delete and compaction of a chat, by a cold archive's commit, and by a save of
    /// a meta that names a reference, from its check to its write; shared by each read of a fork's
    /// history: a save that read the reference first cannot write it back after the drop (review
    /// of #37020: after a restart the fork named its deleted chat again; two writes of one fork's
    /// history raced).
    ///
    /// Lock order: the hub's `Session::append_lock` (a retention or cold archive commit takes it
    /// first, `hub/retention.rs`, `hub/cold_archive.rs`), then this, then the inner store's own
    /// locks (`LocalStore`'s writers', then its cold lock). This view takes no session lock under
    /// it, and nothing under the inner store's locks takes it.
    dropping: RwLock<()>,
}

thread_local! {
    /// Whether this thread holds `dropping` already: a fork of a fork reads its parent through
    /// this view again, and a write reads the history it writes, under the hold they started.
    static HELD: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

#[cfg(test)]
thread_local! {
    /// Tests: this thread says so, once, when it is about to wait for `dropping` held exclusively
    /// by another thread.
    pub(super) static NOTE_DROPPING_WAIT: super::log_sync::Note =
        const { std::cell::RefCell::new(None) };
}

/// A hold of [`ForkView`]'s `dropping`, or none when this thread holds it already.
enum Held<'a> {
    Shared(#[allow(dead_code)] std::sync::RwLockReadGuard<'a, ()>),
    Exclusive(#[allow(dead_code)] std::sync::RwLockWriteGuard<'a, ()>),
    Nested,
}

impl Drop for Held<'_> {
    fn drop(&mut self) {
        if !matches!(self, Held::Nested) {
            HELD.with(|h| h.set(false));
        }
    }
}

/// Every reference is read from a session's stored meta before it is used, and once dropped it
/// never comes back: a meta loaded before the drop and noted after it names it no more.
#[derive(Default)]
struct Refs {
    /// Each referencing fork's reference.
    by_fork: HashMap<String, HistoryRef>,
    /// The sessions whose meta this view has read: any other is read before its reference is
    /// asked for, so a fork of a fork opened before the store's full list reads through both
    /// (review of #37020).
    known: std::collections::HashSet<String>,
    /// Forks whose history was written into their logs, with the seq it was shown through.
    dropped: HashMap<String, u64>,
    /// Whether the whole store was listed: before then, `forks_of` lists it first.
    listed: bool,
    /// The chats under a [`HistoryFence`], with how many hold one: no fork references them.
    fenced: HashMap<String, usize>,
}

fn is_history(kind: &str) -> bool {
    HISTORY_KINDS.contains(&kind)
}

impl ForkView {
    pub fn new(inner: Box<dyn Store>) -> Self {
        Self { inner, refs: Default::default(), dropping: Default::default() }
    }

    /// Held by every read of a fork's history for its whole run: a write of that history and the
    /// delete or compaction of its chat wait for it, so a read never takes a reference and then
    /// reads a chat already gone (review of #37020: an export wrote a fork with no history).
    fn shared(&self) -> Held<'_> {
        if HELD.with(|h| h.replace(true)) {
            return Held::Nested;
        }
        Held::Shared(self.dropping.read().unwrap_or_else(|e| e.into_inner()))
    }

    fn exclusive(&self) -> Held<'_> {
        if HELD.with(|h| h.replace(true)) {
            return Held::Nested;
        }
        #[cfg(test)]
        if let Err(std::sync::TryLockError::WouldBlock) = self.dropping.try_write() {
            super::log_sync::note(&NOTE_DROPPING_WAIT, "waits");
        }
        Held::Exclusive(self.dropping.write().unwrap_or_else(|e| e.into_inner()))
    }

    /// The history `id` references, if any. A meta that cannot be read is an error, never taken
    /// for one that names none: a read of a fork of a fork would then show only that chat's own
    /// records, and a copy made from it (an export, a write of the history) would keep that for
    /// good (review of #37020). It is read again next time.
    fn reference(&self, id: &str) -> Result<Option<HistoryRef>> {
        {
            let refs = self.refs.read().unwrap_or_else(|e| e.into_inner());
            if refs.known.contains(id) {
                return Ok(refs.by_fork.get(id).cloned());
            }
        }
        match self.inner.load(id) {
            Ok(Some(meta)) => self.note(&meta),
            Ok(None) => {
                self.refs.write().unwrap_or_else(|e| e.into_inner()).known.insert(id.to_owned());
            }
            Err(e) => {
                return Err(e.context(format!("chat {id}: its history's source is unreadable")));
            }
        }
        Ok(self.refs.read().unwrap_or_else(|e| e.into_inner()).by_fork.get(id).cloned())
    }

    fn note(&self, meta: &SessionMeta) {
        let mut refs = self.refs.write().unwrap_or_else(|e| e.into_inner());
        refs.known.insert(meta.id.clone());
        match &meta.history_from {
            Some(r) if !refs.dropped.contains_key(&meta.id) => {
                refs.by_fork.insert(meta.id.clone(), r.clone())
            }
            _ => refs.by_fork.remove(&meta.id),
        };
    }

    /// Writes the history `id` references into its own log and drops the reference: before its
    /// chat goes, or before its files are read or moved as files. Nothing for a session that
    /// references none. A failure leaves the reference as it was.
    pub fn materialize(&self, id: &str) -> Result<()> {
        let _dropping = self.exclusive();
        self.materialize_locked(id)
    }

    /// [`ForkView::materialize`] under `dropping`.
    fn materialize_locked(&self, id: &str) -> Result<()> {
        // Read under the lock: a write that ran first left none.
        let Some(reference) = self.reference(id)? else { return Ok(()) };
        // A fork reserved and not saved yet has no meta to hold the history's end, and no folder
        // made with it: the history would go nowhere, or into a folder its meta's save then
        // takes as already there. Its first save comes under `dropping` too, so the chat waits
        // for that save (review of #37020).
        let Some(mut meta) = self.inner.load(id)? else {
            anyhow::bail!("a fork of this chat is still being made: try again");
        };
        let Some(mut writer) = self.inner.history_writer(id)? else {
            anyhow::bail!("this store cannot hold a fork's history");
        };
        let mut failed = None;
        // Strict, through every chat the reference passes: a line that does not read stops the
        // write, and the reference stays (review of #37020: a lenient read wrote what it could).
        self.scan_strict(&reference.session, 0, &mut |rec| {
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
        // The meta first: if its save fails, the reference stands on disk and here, and the next
        // write replaces segment `000000` whole (review of #37020: a failed save left the
        // reference on disk and none here, so the written history was never read).
        meta.history_from = None;
        meta.history_kept_through = Some(reference.through_seq);
        self.inner.save(&meta)?;
        // Durable before the chat may go: a journal store's save only queues its record, and a
        // crash before it is written would bring back the reference to a deleted chat, whose
        // fork then shows none of the history written here (review of #37020 at 82dd442, F1).
        self.inner.flush_session(id)?;
        let mut refs = self.refs.write().unwrap_or_else(|e| e.into_inner());
        refs.dropped.insert(id.to_owned(), reference.through_seq);
        refs.by_fork.remove(id);
        Ok(())
    }

    /// The forks that reference `id`'s history.
    fn forks_of(&self, id: &str) -> Result<Vec<String>> {
        if !self.refs.read().unwrap_or_else(|e| e.into_inner()).listed {
            self.list()?;
        }
        // A chat the list left out (its meta did not read) may be a fork of this one: read it
        // again, and refuse while it still does not read (review of #37020: the delete went on
        // without it, and it lost its history).
        for other in self.inner.unlisted() {
            match self.inner.load(&other) {
                Ok(Some(meta)) => self.note(&meta),
                Ok(None) => {}
                Err(e) => {
                    return Err(e.context(format!(
                        "chat {other}'s metadata does not read, and it may be a fork of {id}"
                    )));
                }
            }
        }
        let refs = self.refs.read().unwrap_or_else(|e| e.into_inner());
        Ok(refs.by_fork.iter().filter(|(_, r)| r.session == id).map(|(f, _)| f.clone()).collect())
    }
}

impl ForkView {
    /// `save` through `write`: a save that names no reference must not undo a materialize the
    /// hub's copy of the meta has not heard of, so once dropped, a reference never comes back.
    fn save_with(
        &self,
        meta: &SessionMeta,
        write: impl Fn(&SessionMeta) -> Result<()>,
    ) -> Result<()> {
        if meta.history_from.is_none() {
            write(meta)?;
            self.note(meta);
            return Ok(());
        }
        let _dropping = self.exclusive();
        let mut meta = meta.clone();
        let dropped =
            self.refs.read().unwrap_or_else(|e| e.into_inner()).dropped.get(&meta.id).copied();
        if let Some(through) = dropped {
            meta.history_from = None;
            meta.history_kept_through = Some(through);
        } else if let Some(stored) = self.inner.load(&meta.id)?
            && stored.history_from.is_none()
            && stored.history_kept_through.is_some()
        {
            // Written in by another process (an earlier daemon): its meta on disk says so.
            meta.history_from = None;
            meta.history_kept_through = stored.history_kept_through;
        }
        write(&meta)?;
        self.note(&meta);
        Ok(())
    }
}

impl Store for ForkView {
    fn list(&self) -> Result<Vec<SessionMeta>> {
        let metas = self.inner.list()?;
        metas.iter().for_each(|m| self.note(m));
        self.refs.write().unwrap_or_else(|e| e.into_inner()).listed = true;
        Ok(metas)
    }
    fn unlisted(&self) -> Vec<String> {
        self.inner.unlisted()
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
        self.save_with(meta, |meta| self.inner.save(meta))
    }
    /// A draft or a name (`ShowAfter::Written`): the inner store's own kept save, which waits for
    /// no sync (review of #37020: a draft through the default `save` waited one).
    fn save_kept(&self, meta: &SessionMeta) -> Result<()> {
        self.save_with(meta, |meta| self.inner.save_kept(meta))
    }
    fn append(&self, id: &str, record: &EventRecord) -> Result<()> {
        self.inner.append(id, record)
    }
    fn flush_session(&self, id: &str) -> Result<()> {
        self.inner.flush_session(id)
    }
    fn events(&self, id: &str, after: u64, limit: usize) -> Result<Vec<EventRecord>> {
        let _held = self.shared();
        let Some(r) = self.reference(id)? else { return self.inner.events(id, after, limit) };
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
        let _held = self.shared();
        let Some(r) = self.reference(id)? else { return self.inner.scan(id, after, visit) };
        if !self.prefix(&r, after, visit)? {
            return Ok(());
        }
        self.inner.scan(id, after.max(r.through_seq), visit)
    }
    fn scan_matching(
        &self,
        id: &str,
        after: u64,
        may_match: &dyn Fn(&[u8]) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        let _held = self.shared();
        let Some(r) = self.reference(id)? else {
            return self.inner.scan_matching(id, after, may_match, visit);
        };
        // The history a fork reads from its source is read whole, as `scan` reads it.
        if !self.prefix(&r, after, visit)? {
            return Ok(());
        }
        self.inner.scan_matching(id, after.max(r.through_seq), may_match, visit)
    }
    fn scan_strict(
        &self,
        id: &str,
        after: u64,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        let _held = self.shared();
        let Some(r) = self.reference(id)? else { return self.inner.scan_strict(id, after, visit) };
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
        self.back(id, after, before, skip, visit, false)
    }
    fn scan_back_indexed(
        &self,
        id: &str,
        after: u64,
        before: u64,
        skip: &dyn Fn(&[u8], &[u8]) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.back(id, after, before, skip, visit, true)
    }
    fn tail_after(&self, id: &str, after: u64) -> Result<(u64, u64)> {
        let _held = self.shared();
        let Some(r) = self.reference(id)? else { return self.inner.tail_after(id, after) };
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
        let _held = self.shared();
        let Some(r) = self.reference(id)? else { return self.inner.scan_kinds(id, kinds, visit) };
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
        let _held = self.shared();
        let Some(r) = self.reference(id)? else {
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
        let _held = self.shared();
        let Some(r) = self.reference(id)? else { return self.inner.scan_heads(id, visit) };
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
        let _held = self.shared();
        if self.reference(id)?.is_none() {
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
        let _dropping = self.exclusive();
        for fork in self.forks_of(id)? {
            self.materialize_locked(&fork)?;
        }
        self.inner.commit_compaction(id, staged)
    }
    fn stage_cold(&self, id: &str) -> Result<Option<StagedCold>> {
        self.inner.stage_cold(id)
    }
    /// A cold archive keeps every byte (`store/cold.rs`): a fork that shows the chat's records
    /// keeps its reference, and its read brings the chat's log back. Under `dropping`, as a
    /// compaction's commit is: a write of `id`'s own history (`materialize`, its chat's delete)
    /// rehydrates its log and then writes segment `000000` into `events/`, and a commit between
    /// the two moved `events/` into the archive, so the write made a new `events/` with the
    /// history alone and the fork's own turns stayed in an archive never read again (third review
    /// of #39141, F2). After a write, the commit finds the log changed and refuses.
    fn commit_cold(&self, id: &str, staged: StagedCold) -> Result<bool> {
        let _dropping = self.exclusive();
        self.inner.commit_cold(id, staged)
    }
    fn rehydrate(&self, id: &str) -> Result<bool> {
        self.inner.rehydrate(id)
    }
    fn is_cold(&self, id: &str) -> bool {
        self.inner.is_cold(id)
    }
    fn on_rehydrate(&self, hook: RehydrateHook) {
        self.inner.on_rehydrate(hook)
    }
    /// Under `dropping`, as a reservation is: one that came first is written in here (or, still
    /// being made, fails this), and one after is refused until `end_release`.
    fn release_history(&self, id: &str) -> Result<()> {
        let _dropping = self.exclusive();
        for fork in self.forks_of(id)? {
            self.materialize_locked(&fork)?;
        }
        *self
            .refs
            .write()
            .unwrap_or_else(|e| e.into_inner())
            .fenced
            .entry(id.to_owned())
            .or_default() += 1;
        Ok(())
    }
    fn end_release(&self, id: &str) {
        let mut refs = self.refs.write().unwrap_or_else(|e| e.into_inner());
        if let Some(held) = refs.fenced.get_mut(id) {
            *held -= 1;
            if *held == 0 {
                refs.fenced.remove(id);
            }
        }
    }
    /// A chat that forks reference goes only once each holds its history itself. Under
    /// `dropping`, as a reservation is: a fork being made is either known here or refused.
    fn delete(&self, id: &str) -> Result<()> {
        let _dropping = self.exclusive();
        for fork in self.forks_of(id)? {
            self.materialize_locked(&fork)?;
        }
        self.inner.delete(id)?;
        self.refs.write().unwrap_or_else(|e| e.into_inner()).by_fork.remove(id);
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
    /// Under `dropping`, as a delete or compaction of the chat is: one that came first is seen
    /// here (the chat is gone, or its records trimmed as a copy made now would read them), and
    /// one after writes the history into the fork first (review of #37020: the reference was
    /// known only once the fork's meta was saved, after a delete or compaction could pass it).
    fn reserve_reference(&self, fork: &str, reference: &HistoryRef) -> Result<()> {
        let _dropping = self.exclusive();
        anyhow::ensure!(self.inner.load(&reference.session)?.is_some(), "the chat is gone");
        let mut refs = self.refs.write().unwrap_or_else(|e| e.into_inner());
        // Its folder is being replaced or removed: a fork now would read what comes after.
        anyhow::ensure!(
            !refs.fenced.contains_key(&reference.session),
            "the chat is being moved or deleted: try again"
        );
        refs.known.insert(fork.to_owned());
        refs.by_fork.insert(fork.to_owned(), reference.clone());
        Ok(())
    }
    fn forget_reference(&self, fork: &str) {
        self.refs.write().unwrap_or_else(|e| e.into_inner()).by_fork.remove(fork);
    }
    fn history_writer(&self, id: &str) -> Result<Option<Box<dyn HistoryWriter + '_>>> {
        self.inner.history_writer(id)
    }
}

impl ForkView {
    /// The inner store's `scan_back` (`indexed`: its `scan_back_indexed`).
    fn inner_back(
        &self,
        indexed: bool,
        id: &str,
        after: u64,
        before: u64,
        skip: &dyn Fn(&[u8], &[u8]) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        if indexed {
            self.inner.scan_back_indexed(id, after, before, skip, visit)
        } else {
            self.inner.scan_back(id, after, before, skip, visit)
        }
    }

    /// `scan_back` (`indexed`: `scan_back_indexed`): the fork's own records, then its chat's
    /// history before the fork point.
    fn back(
        &self,
        id: &str,
        after: u64,
        before: u64,
        skip: &dyn Fn(&[u8], &[u8]) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
        indexed: bool,
    ) -> Result<()> {
        let _held = self.shared();

        let Some(r) = self.reference(id)? else {
            return self.inner_back(indexed, id, after, before, skip, visit);
        };
        let mut going = true;
        if before > r.through_seq + 1 {
            self.inner_back(indexed, id, after.max(r.through_seq), before, skip, &mut |rec| {
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
        self.back(
            &r.session,
            after,
            before.min(r.through_seq + 1),
            &skip_other,
            &mut |rec| !is_history(&rec.kind) || visit(rec),
            indexed,
        )
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
