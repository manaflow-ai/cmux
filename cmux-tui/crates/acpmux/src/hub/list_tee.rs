//! One v1 list mark queue and one summary builder, until chat actors own rows.
mod summary;
use super::*;
#[cfg(test)]
use acpmux_book::index::IndexPage;
use acpmux_book::index::{OriginState, ReadSide, RowKey, SortKey, Summary};
use acpmux_core::hub::Source;
use acpmux_core::life::V2;
use std::collections::{BTreeSet, HashMap, HashSet, VecDeque};
use summary::{summary_from_remote, summary_from_session};
use tokio::sync::Notify;

const BATCH: usize = 256;
/// Accounting used by the walk-memory gate: the hash set owns one `String`
/// slot and one control byte per bucket, in addition to each id's allocation.
#[cfg(test)]
pub(crate) const WALK_ID_STATE_BYTES: usize = std::mem::size_of::<String>() + 1;

#[cfg(test)]
const WALK_HASH_GROUP_BYTES: usize = std::mem::size_of::<[usize; 2]>();

pub(crate) struct TeeHandle {
    state: Arc<TeeState>,
}

impl TeeHandle {
    pub(super) fn damaged_snapshot_frames(&self) -> u64 {
        self.state.hub.upgrade().map_or(0, |hub| hub.damaged_snapshot_frames())
    }

    pub(super) fn mark(&self, id: &str) {
        self.state.mark(id);
    }

    pub(super) fn mark_all(&self) {
        #[cfg(test)]
        let started = std::time::Instant::now();
        self.state.all.store(true, Ordering::Release);
        self.state.notify.notify_one();
        #[cfg(test)]
        self.state.mark_all_ns.store(started.elapsed().as_nanos() as u64, Ordering::Relaxed);
    }

    pub(super) fn mark_remote(&self, peer: &str, id: &str) {
        self.state.mark_remote(peer, id);
    }

    pub(super) fn origin(&self, id: &str, state: OriginState, since: u64) {
        self.state.origin(id, state, since);
    }

    pub(super) fn remote_ready(&self) {
        self.state.remote_ready();
    }
}

#[derive(Default)]
struct TeeState {
    hub: std::sync::Weak<acpmux_core::hub::Hub>,
    pending: std::sync::Mutex<HashSet<String>>,
    remote: std::sync::Mutex<HashSet<(String, String)>>,
    origins: std::sync::Mutex<HashMap<String, VecDeque<(OriginState, u64)>>>,
    remote_ready: AtomicBool,
    notify: Notify,
    marks: AtomicU64,
    all: AtomicBool,
    #[cfg(test)]
    walk_peak_page_bytes: AtomicU64,
    #[cfg(test)]
    walk_peak_cold_bytes: AtomicU64,
    #[cfg(test)]
    walk_peak_page_total_bytes: AtomicU64,
    #[cfg(test)]
    walk_peak_id_bytes: AtomicU64,
    #[cfg(test)]
    store_load_ns: AtomicU64,
    #[cfg(test)]
    mark_all_ns: AtomicU64,
    #[cfg(test)]
    walk_done: AtomicBool,
}

impl TeeState {
    fn mark(&self, id: &str) {
        self.marks.fetch_add(1, Ordering::Relaxed);
        self.pending.lock().unwrap_or_else(|e| e.into_inner()).insert(id.to_owned());
        self.notify.notify_one();
    }

    fn mark_remote(&self, peer: &str, id: &str) {
        self.marks.fetch_add(1, Ordering::Relaxed);
        self.remote
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert((peer.to_owned(), id.to_owned()));
        self.notify.notify_one();
    }

    fn origin(&self, id: &str, state: OriginState, since: u64) {
        let mut origins = self.origins.lock().unwrap_or_else(|e| e.into_inner());
        let queue = origins.entry(id.to_owned()).or_default();
        if state == OriginState::Removed {
            queue.clear();
            queue.push_back((state, since));
        } else if queue.back().is_some_and(|(state, _)| *state == OriginState::Removed) {
            // `removed` is a lifecycle cut. Preserve it ahead of the latest
            // record so a rapid remove/reconnect cannot collapse the cut.
            queue.push_back((state, since));
        } else if let Some(last) = queue.back_mut() {
            *last = (state, since);
        } else {
            queue.push_back((state, since));
        }
        self.notify.notify_one();
    }

    fn remote_ready(&self) {
        self.remote_ready.store(true, Ordering::Release);
        self.notify.notify_one();
    }

    fn has_pending(&self) -> bool {
        self.all.load(Ordering::Acquire)
            || !self.pending.lock().unwrap_or_else(|e| e.into_inner()).is_empty()
            || !self.remote.lock().unwrap_or_else(|e| e.into_inner()).is_empty()
            || !self.origins.lock().unwrap_or_else(|e| e.into_inner()).is_empty()
    }

    fn take(&self) -> Vec<String> {
        let mut pending = self.pending.lock().unwrap_or_else(|e| e.into_inner());
        let ids: Vec<_> = pending.iter().take(BATCH).cloned().collect();
        for id in &ids {
            pending.remove(id);
        }
        ids
    }

    #[cfg(test)]
    fn record_walk_id_memory(&self, ids: &HashSet<String>) {
        // `HashSet` uses hashbrown's power-of-two bucket table. `capacity()`
        // is the number of elements admitted before a resize, not its bucket
        // count, so round it up and include the control-group tail. `String`
        // capacities are the owned heap bytes; lengths undercount reused
        // allocations. This is a structural upper bound, not serialized data.
        let buckets = ids
            .capacity()
            .checked_next_power_of_two()
            .unwrap_or(ids.capacity())
            .max(if ids.is_empty() { 0 } else { 8 });
        let id_bytes = ids.iter().map(|id| id.capacity()).sum::<usize>().saturating_add(
            buckets.saturating_mul(WALK_ID_STATE_BYTES).saturating_add(WALK_HASH_GROUP_BYTES),
        );
        self.walk_peak_id_bytes.fetch_max(id_bytes as u64, Ordering::Relaxed);
    }

    #[cfg(test)]
    fn record_walk_page_memory(&self, page_bytes: usize, cold_bytes: usize) {
        self.walk_peak_page_bytes.fetch_max(page_bytes as u64, Ordering::Relaxed);
        self.walk_peak_cold_bytes.fetch_max(cold_bytes as u64, Ordering::Relaxed);
        self.walk_peak_page_total_bytes
            .fetch_max(page_bytes.saturating_add(cold_bytes) as u64, Ordering::Relaxed);
    }

    #[cfg(test)]
    fn summary_owned_bytes(row: &Summary) -> usize {
        let string_bytes = row.chat_id.capacity()
            + row.title.capacity()
            + row.harness.capacity()
            + row.state.capacity()
            + row.origin.capacity()
            + row.workspace.as_ref().map_or(0, String::capacity)
            + row.folder.as_ref().map_or(0, String::capacity);
        let key_bytes =
            |key: &RowKey| std::mem::size_of::<RowKey>() + key.origin.len() + key.chat_id.len();
        let parent_bytes = row.parent.as_ref().map_or(0, key_bytes);
        let fork_bytes = row.fork_of.as_ref().map_or(0, |fork| key_bytes(&fork.key));
        let raw_bytes =
            row.extra.get().len() + row.peer_form.as_ref().map_or(0, |peer| peer.get().len());
        // The Arc header and the Summary's owned fields are allocated with the
        // decoded cold row. Hot rows only charge their Arc slot in the page.
        std::mem::size_of::<Summary>()
            + 2 * std::mem::size_of::<usize>()
            + string_bytes
            + parent_bytes
            + fork_bytes
            + raw_bytes
    }

    #[cfg(test)]
    fn walk_page_owned_bytes(page: &IndexPage) -> (usize, usize) {
        let slots = page.rows.capacity().saturating_mul(std::mem::size_of::<Arc<Summary>>());
        let cold_rows = if page.bytes_read > 0 {
            page.rows.iter().map(|row| Self::summary_owned_bytes(row)).sum()
        } else {
            0
        };
        (slots, cold_rows)
    }

    #[cfg(test)]
    pub(crate) fn walk_peak_memory(&self) -> (u64, u64, u64, u64) {
        (
            self.walk_peak_page_bytes.load(Ordering::Relaxed),
            self.walk_peak_cold_bytes.load(Ordering::Relaxed),
            self.walk_peak_page_total_bytes.load(Ordering::Relaxed),
            self.walk_peak_id_bytes.load(Ordering::Relaxed),
        )
    }

    #[cfg(test)]
    pub(crate) fn load_and_mark_all_ns(&self) -> (u64, u64) {
        (self.store_load_ns.load(Ordering::Relaxed), self.mark_all_ns.load(Ordering::Relaxed))
    }

    #[cfg(test)]
    pub(crate) fn walk_finished(&self) -> bool {
        self.walk_done.load(Ordering::Acquire)
    }

    fn take_remote(&self, limit: usize) -> Vec<(String, String)> {
        let mut pending = self.remote.lock().unwrap_or_else(|e| e.into_inner());
        let ids: Vec<_> = pending.iter().take(limit).cloned().collect();
        for id in &ids {
            pending.remove(id);
        }
        ids
    }

    fn take_origins(&self, limit: usize) -> Vec<(String, OriginState, u64)> {
        let mut pending = self.origins.lock().unwrap_or_else(|e| e.into_inner());
        let ids: Vec<_> = pending.keys().cloned().collect();
        let mut taken = Vec::new();
        for id in ids {
            while taken.len() < limit {
                let next = pending.get_mut(&id).and_then(VecDeque::pop_front);
                let Some((state, since)) = next else { break };
                taken.push((id.clone(), state, since));
            }
            if pending.get(&id).is_some_and(VecDeque::is_empty) {
                pending.remove(&id);
            }
            if taken.len() >= limit {
                break;
            }
        }
        taken
    }
}

/// One scheduled deadline per chat. A tag update replaces its old deadline;
/// expiry work costs the due chats, never a sweep of every session per second.
#[derive(Default)]
struct Expiries {
    by_id: HashMap<String, u64>,
    ordered: BTreeSet<(u64, String)>,
    stalled_by_id: HashMap<String, u64>,
    stalled_ordered: BTreeSet<(u64, String)>,
    stalled_fired: HashMap<String, u64>,
    stalled_fired_ordered: BTreeSet<(u64, String)>,
    stalled_fired_cursor: Option<(u64, String)>,
}

impl Expiries {
    fn set(&mut self, id: &str, next: Option<u64>) {
        if let Some(old) = self.by_id.remove(id) {
            self.ordered.remove(&(old, id.to_owned()));
        }
        if let Some(next) = next {
            self.by_id.insert(id.to_owned(), next);
            self.ordered.insert((next, id.to_owned()));
        }
    }

    fn set_stalled(&mut self, id: &str, next: Option<u64>) {
        if let Some(old) = self.stalled_by_id.remove(id) {
            self.stalled_ordered.remove(&(old, id.to_owned()));
        }
        if let Some(old) = self.stalled_fired.get(id).copied()
            && next != Some(old)
        {
            self.stalled_fired.remove(id);
            self.stalled_fired_ordered.remove(&(old, id.to_owned()));
        }
        match next {
            Some(next) if self.stalled_fired.get(id).copied() != Some(next) => {
                self.stalled_by_id.insert(id.to_owned(), next);
                self.stalled_ordered.insert((next, id.to_owned()));
            }
            Some(_) => {}
            None => {
                self.stalled_fired.remove(id);
            }
        }
    }

    fn retry_stalled(&mut self, id: &str, now: u64) {
        // A config writer is temporary, not a disabled deadline. Retry on the
        // next clock tick without an immediately-due timer spinning on the lock.
        self.set_stalled(id, Some(now.saturating_add(1_000)));
    }

    fn has_due(&self, now: u64) -> bool {
        self.ordered.first().is_some_and(|(at, _)| *at <= now)
            || self.stalled_ordered.first().is_some_and(|(at, _)| *at <= now)
    }

    fn mark_due(&mut self, state: &TeeState, now: u64) {
        for _ in 0..BATCH {
            if self.ordered.first().is_none_or(|(at, _)| *at > now) {
                break;
            }
            let Some((_, id)) = self.ordered.pop_first() else { break };
            self.by_id.remove(&id);
            state.mark(&id);
        }
    }

    fn take_stalled_due(&mut self, now: u64) -> Vec<(u64, String)> {
        let mut due = Vec::new();
        for _ in 0..BATCH {
            if self.stalled_ordered.first().is_none_or(|(at, _)| *at > now) {
                break;
            }
            let Some((at, id)) = self.stalled_ordered.pop_first() else { break };
            self.stalled_by_id.remove(&id);
            self.stalled_fired.insert(id.clone(), at);
            self.stalled_fired_ordered.insert((at, id.clone()));
            due.push((at, id));
        }
        due
    }

    fn fired_for_recheck(&mut self) -> Vec<(u64, String)> {
        let mut due = Vec::with_capacity(BATCH);
        if let Some(cursor) = self.stalled_fired_cursor.as_ref() {
            due.extend(
                self.stalled_fired_ordered
                    .range((std::ops::Bound::Excluded(cursor.clone()), std::ops::Bound::Unbounded))
                    .take(BATCH)
                    .cloned(),
            );
            if due.len() < BATCH {
                due.extend(self.stalled_fired_ordered.iter().take(BATCH - due.len()).cloned());
            }
        } else {
            due.extend(self.stalled_fired_ordered.iter().take(BATCH).cloned());
        }
        self.stalled_fired_cursor = due.last().cloned();
        due
    }

    fn clear_fired(&mut self, at: u64, id: &str) {
        if self.stalled_fired.get(id).copied() == Some(at) {
            self.stalled_fired.remove(id);
            self.stalled_fired_ordered.remove(&(at, id.to_owned()));
        }
    }

    #[cfg(test)]
    fn mark_stalled_due(&mut self, state: &TeeState, now: u64) {
        for (_, id) in self.take_stalled_due(now) {
            state.mark(&id);
        }
    }
}

fn session_by_id(v1: &Hub, id: &str) -> Option<Arc<Session>> {
    v1.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(id).cloned()
}

fn stalled_deadline(
    v1: &Hub,
    session: &Session,
    live: bool,
) -> Result<Option<u64>, tokio::sync::TryLockError> {
    if !live {
        return Ok(None);
    }
    let after = v1.config.try_read()?.stalled_turn();
    Ok(session.turn().and_then(|turn| {
        after.map(|after| {
            let heard = session.last_model_at.load(Ordering::Relaxed);
            turn.started_at.max(heard).saturating_add(after)
        })
    }))
}

fn submit_id(v1: &Hub, v2: &V2, expiries: &mut Expiries, id: &str) {
    let Some(session) = session_by_id(v1, id) else {
        expiries.set(id, None);
        expiries.set_stalled(id, None);
        let _ = v2.hub.remove("local", id);
        return;
    };
    let now = crate::store::now_ms();
    expiries.set(id, session.read_meta(|meta| super::views::next_tag_expiry(meta, now)));
    match summary_from_session(v1, &session) {
        Ok(summary) => {
            match stalled_deadline(v1, &session, summary.is_live()) {
                Ok(deadline) => expiries.set_stalled(id, deadline),
                Err(_) => expiries.retry_stalled(id, now),
            }
            if let Err(error) = v2.hub.submit(summary) {
                tracing::warn!(session_id = id, %error, "v2 list tee rejected a summary");
            }
        }
        Err(error) => {
            tracing::warn!(session_id = id, %error, "v2 list tee could not build a summary")
        }
    }
}

fn drain_marks(v1: &Hub, v2: &V2, state: &TeeState, expiries: &mut Expiries) {
    if state.all.swap(false, Ordering::AcqRel) {
        let ids: Vec<_> =
            v1.sessions.lock().unwrap_or_else(|e| e.into_inner()).keys().cloned().collect();
        state.pending.lock().unwrap_or_else(|e| e.into_inner()).extend(ids);
    }
    for (id, origin_state, since) in state.take_origins(BATCH) {
        if let Err(error) = v2.hub.origin(&id, origin_state, since) {
            tracing::warn!(origin = %id, %error, "v2 list tee rejected an origin state");
        }
    }
    let mut used = 0usize;
    for id in state.take() {
        submit_id(v1, v2, expiries, &id);
        used += 1;
        if used >= BATCH {
            return;
        }
    }
    for (peer, id) in state.take_remote(BATCH.saturating_sub(used)) {
        submit_remote_id(v1, v2, &peer, &id, state.remote_ready.load(Ordering::Acquire));
    }
}

fn submit_remote_id(v1: &Hub, v2: &V2, peer: &str, id: &str, remote_ready: bool) {
    if v2.hub.source(peer) == Some(Source::Mirror) {
        return;
    }
    let rows = v1.remote_sessions.snapshot();
    if let Some(row) = rows.find_live_mux(peer, id) {
        match summary_from_remote(peer, &row.summary) {
            Ok(summary) => {
                if let Err(error) = v2.hub.submit_from(Source::V1, summary) {
                    tracing::warn!(peer, session_id = id, %error, "v2 list tee rejected a remote summary");
                }
            }
            Err(error) => {
                tracing::warn!(peer, session_id = id, %error, "v2 list tee could not build a remote summary")
            }
        }
    } else if remote_ready && let Err(error) = v2.hub.remove_from(Source::V1, peer, id) {
        tracing::warn!(peer, session_id = id, %error, "v2 list tee rejected a remote removal");
    }
}

async fn reconcile(v1: &Hub, v2: &V2, state: &TeeState) -> Expiries {
    #[cfg(test)]
    let started = std::time::Instant::now();
    v1.wait_store().await;
    #[cfg(test)]
    state.store_load_ns.store(started.elapsed().as_nanos() as u64, Ordering::Relaxed);
    let _ = v2.hub.wait_hydrated().await;
    // Only ids survive a page. Each lookup uses the current session map,
    // so a purge drained between pages cannot be undone by an old handle.
    let mut unseen: HashSet<_> =
        v1.sessions.lock().unwrap_or_else(|e| e.into_inner()).keys().cloned().collect();
    #[cfg(test)]
    state.record_walk_id_memory(&unseen);
    let mut expiries = Expiries::default();
    let mut anchor: Option<SortKey> = None;
    loop {
        let page = match v2.hub.snapshot().read_page(
            anchor.as_ref(),
            ReadSide::After,
            false,
            BATCH,
            256 * 1024,
            None,
        ) {
            Ok(page) => page,
            Err(error) => {
                tracing::warn!(%error, "v2 list reconciliation page failed");
                break;
            }
        };
        #[cfg(test)]
        let (page_slots, cold_rows) = TeeState::walk_page_owned_bytes(&page);
        #[cfg(test)]
        state.record_walk_page_memory(page_slots, cold_rows);
        for row in &page.rows {
            if row.origin == "local" {
                unseen.remove(&row.chat_id);
                submit_id(v1, v2, &mut expiries, &row.chat_id);
            }
        }
        drain_marks(v1, v2, state, &mut expiries);
        if !page.has_after {
            break;
        }
        let Some(next) = page.after_key else { break };
        anchor = Some(next);
        tokio::task::yield_now().await;
    }
    for (n, id) in unseen.into_iter().enumerate() {
        submit_id(v1, v2, &mut expiries, &id);
        if (n + 1) % BATCH == 0 {
            drain_marks(v1, v2, state, &mut expiries);
            tokio::task::yield_now().await;
        }
    }
    #[cfg(test)]
    state.walk_done.store(true, Ordering::Release);
    expiries
}

async fn reconcile_remote(v1: &Hub, v2: &V2, state: &TeeState) {
    let mut peer_names: HashSet<String> = v1.config.read().await.peers.keys().cloned().collect();
    for peer in v1.peers() {
        let Some(name) = peer.get("name").and_then(Value::as_str) else { continue };
        let Some(handle) = v1.peer_by_name(name) else { continue };
        peer_names.insert(name.to_owned());
        let origin_state = match handle.state() {
            crate::peer_link::PeerState::Connected | crate::peer_link::PeerState::Degraded => {
                OriginState::Connected
            }
            _ => OriginState::Down,
        };
        state.origin(name, origin_state, crate::store::now_ms());
    }
    let remote_rows = v1.remote_sessions.snapshot();
    let remote_keys: HashSet<(String, String)> = remote_rows
        .values()
        .filter_map(|row| row.summary.session_id().map(|id| (row.peer.clone(), id.to_owned())))
        .collect();
    for row in remote_rows.values() {
        if let Some(id) = row.summary.session_id() {
            state.mark_remote(&row.peer, id);
        }
    }
    for origin in v2.hub.snapshot().origins() {
        if !peer_names.contains(&origin.id) {
            state.origin(&origin.id, OriginState::Removed, crate::store::now_ms());
        }
    }
    let mut anchor: Option<SortKey> = None;
    loop {
        let page = match v2.hub.snapshot().read_page(
            anchor.as_ref(),
            ReadSide::After,
            false,
            BATCH,
            256 * 1024,
            None,
        ) {
            Ok(page) => page,
            Err(error) => {
                tracing::warn!(%error, "v2 remote reconciliation page failed");
                break;
            }
        };
        for row in &page.rows {
            if row.origin != "local"
                && !remote_keys.contains(&(row.origin.clone(), row.chat_id.clone()))
            {
                state.mark_remote(&row.origin, &row.chat_id);
            }
        }
        if !page.has_after {
            break;
        }
        let Some(next) = page.after_key else { break };
        anchor = Some(next);
        tokio::task::yield_now().await;
    }
}

pub(crate) fn start_v2_tee(
    v1: Arc<Hub>,
    v2: Arc<V2>,
) -> (Arc<TeeHandle>, impl std::future::Future<Output = ()> + Send + 'static) {
    let state = Arc::new(TeeState { hub: Arc::downgrade(&v2.hub), ..TeeState::default() });
    let handle = Arc::new(TeeHandle { state: state.clone() });
    let task = async move {
        let mut expiries = reconcile(&v1, &v2, &state).await;
        if v1.config.read().await.peers.is_empty() {
            state.remote_ready();
        }
        let mut tick = tokio::time::interval(std::time::Duration::from_secs(1));
        let mut remote_reconciled = false;
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            if state.remote_ready.load(Ordering::Acquire) && !remote_reconciled {
                reconcile_remote(&v1, &v2, &state).await;
                remote_reconciled = true;
            }
            let clock_tick = tokio::select! {
                biased;
                _ = tick.tick() => true,
                _ = state.notify.notified() => false,
                _ = std::future::ready(()), if state.has_pending()
                    || expiries.has_due(crate::store::now_ms()) => false,
            };
            let now = crate::store::now_ms();
            expiries.mark_due(&state, now);
            for (scheduled, id) in expiries.take_stalled_due(now) {
                let Some(session) = session_by_id(&v1, &id) else {
                    expiries.set_stalled(&id, None);
                    continue;
                };
                let live =
                    session.read_meta(|meta| meta.status != crate::store::SessionStatus::Closed);
                let Ok(current) = stalled_deadline(&v1, &session, live) else {
                    expiries.retry_stalled(&id, now);
                    continue;
                };
                if current == Some(scheduled) {
                    state.mark(&id);
                } else {
                    // A model sign may have arrived on an unmarked chunk. Move
                    // the crossing forward without emitting a row operation.
                    expiries.set_stalled(&id, current);
                }
            }
            // A fired turn remains tracked without a full-list scan. An
            // unmarked model chunk can advance its deadline; only that fired
            // ID is rechecked and rescheduled, while an unchanged deadline
            // stays quiet until a later marked event is needed.
            // Rechecking quiet live turns belongs to the clock, not to each
            // marked change. A large set of stalled turns must not multiply
            // the work of draining a single row's mark.
            let mut fired_left = if clock_tick { expiries.stalled_fired.len() } else { 0 };
            while fired_left > 0 {
                let batch = expiries.fired_for_recheck();
                if batch.is_empty() {
                    break;
                }
                fired_left = fired_left.saturating_sub(batch.len());
                for (fired, id) in batch {
                    let Some(session) = session_by_id(&v1, &id) else {
                        expiries.clear_fired(fired, &id);
                        continue;
                    };
                    let live = session
                        .read_meta(|meta| meta.status != crate::store::SessionStatus::Closed);
                    let Ok(current) = stalled_deadline(&v1, &session, live) else {
                        // Keep the fired turn tracked for the next tick.
                        continue;
                    };
                    if current != Some(fired) {
                        expiries.clear_fired(fired, &id);
                        expiries.set_stalled(&id, current);
                    }
                }
                if fired_left > 0 {
                    tokio::task::yield_now().await;
                }
            }
            drain_marks(&v1, &v2, &state, &mut expiries);
            tokio::task::yield_now().await;
        }
    };
    (handle, task)
}

pub(crate) struct V1PageProvider {
    hub: Arc<Hub>,
}

impl V1PageProvider {
    pub(crate) fn new(hub: Arc<Hub>) -> Self {
        Self { hub }
    }
}

impl acpmux_core::hub::PageProvider for V1PageProvider {
    fn row(&self, key: &RowKey) -> std::io::Result<Option<Arc<Summary>>> {
        if key.origin.as_ref() == "local" {
            return match session_by_id(&self.hub, &key.chat_id) {
                Some(session) => summary_from_session(&self.hub, &session).map(Arc::new).map(Some),
                None if !self.hub.store_loaded() => Err(std::io::Error::new(
                    std::io::ErrorKind::WouldBlock,
                    "session store is still loading; retry the keyed page",
                )),
                None => Ok(None),
            };
        }
        let rows = self.hub.remote_sessions.snapshot();
        rows.find_live_mux(&key.origin, &key.chat_id)
            .map(|row| summary_from_remote(&key.origin, &row.summary).map(Arc::new).map(Some))
            .unwrap_or(Ok(None))
    }
}

#[cfg(all(test, target_os = "linux"))]
mod gates;
#[cfg(test)]
mod roundtrip_tests;
#[cfg(test)]
mod snapshot_tests;
#[cfg(test)]
mod tests;
