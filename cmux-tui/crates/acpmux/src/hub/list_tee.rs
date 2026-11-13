//! One v1 list mark queue and one summary builder, until chat actors own rows.
mod summary;
use super::*;
use acpmux_book::index::{OriginState, ReadSide, RowKey, SortKey, Summary};
use acpmux_core::hub::Source;
use acpmux_core::life::V2;
use std::collections::{BTreeSet, HashMap, HashSet, VecDeque};
use summary::{summary_from_remote, summary_from_session};
use tokio::sync::Notify;

const BATCH: usize = 256;

pub(crate) struct TeeHandle {
    state: Arc<TeeState>,
}

impl TeeHandle {
    pub(super) fn mark(&self, id: &str) {
        self.state.mark(id);
    }

    pub(super) fn mark_all(&self) {
        self.state.all.store(true, Ordering::Release);
        self.state.notify.notify_one();
    }

    pub(super) fn mark_remote(&self, peer: &str, id: &str) {
        self.state.mark_remote(peer, id);
    }

    pub(super) fn origin(&self, id: &str, state: OriginState, since: u64) {
        self.state.origin(id, state, since);
    }
}

#[derive(Default)]
struct TeeState {
    pending: std::sync::Mutex<HashSet<String>>,
    remote: std::sync::Mutex<HashSet<(String, String)>>,
    origins: std::sync::Mutex<HashMap<String, VecDeque<(OriginState, u64)>>>,
    notify: Notify,
    marks: AtomicU64,
    all: AtomicBool,
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
        if state == OriginState::Removed
            || queue.back().is_some_and(|(state, _)| *state == OriginState::Removed)
        {
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
}

fn session_by_id(v1: &Hub, id: &str) -> Option<Arc<Session>> {
    v1.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(id).cloned()
}

fn submit_id(v1: &Hub, v2: &V2, expiries: &mut Expiries, id: &str) {
    let Some(session) = session_by_id(v1, id) else {
        expiries.set(id, None);
        let _ = v2.hub.remove("local", id);
        return;
    };
    let now = crate::store::now_ms();
    expiries.set(id, session.read_meta(|meta| super::views::next_tag_expiry(meta, now)));
    match summary_from_session(v1, &session) {
        Ok(summary) => {
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
        submit_remote_id(v1, v2, &peer, &id);
    }
}

fn submit_remote_id(v1: &Hub, v2: &V2, peer: &str, id: &str) {
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
    } else if let Err(error) = v2.hub.remove_from(Source::V1, peer, id) {
        tracing::warn!(peer, session_id = id, %error, "v2 list tee rejected a remote removal");
    }
}

async fn reconcile(v1: &Hub, v2: &V2, state: &TeeState) -> Expiries {
    v1.wait_store().await;
    let _ = v2.hub.wait_hydrated().await;
    let mut peer_names = HashSet::new();
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
    // Only ids survive a page. Each lookup uses the current session map,
    // so a purge drained between pages cannot be undone by an old handle.
    let mut unseen: HashSet<_> =
        v1.sessions.lock().unwrap_or_else(|e| e.into_inner()).keys().cloned().collect();
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
        for row in &page.rows {
            if row.origin == "local" {
                unseen.remove(&row.chat_id);
                submit_id(v1, v2, &mut expiries, &row.chat_id);
            } else if !remote_keys.contains(&(row.origin.clone(), row.chat_id.clone())) {
                state.mark_remote(&row.origin, &row.chat_id);
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
    expiries
}

pub(crate) fn start_v2_tee(
    v1: Arc<Hub>,
    v2: Arc<V2>,
) -> (Arc<TeeHandle>, impl std::future::Future<Output = ()> + Send + 'static) {
    let state = Arc::new(TeeState::default());
    let handle = Arc::new(TeeHandle { state: state.clone() });
    let task = async move {
        let mut expiries = reconcile(&v1, &v2, &state).await;
        let mut tick = tokio::time::interval(std::time::Duration::from_secs(1));
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            tokio::select! {
                biased;
                _ = tick.tick() => {},
                _ = state.notify.notified() => {},
                _ = std::future::ready(()), if state.has_pending() => {},
            }
            expiries.mark_due(&state, crate::store::now_ms());
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
        let row = rows
            .of_peer(&key.origin)
            .find(|row| row.1.receipt.mux_session_id.as_str() == key.chat_id.as_ref());
        row.map(|row| summary_from_remote(&key.origin, &row.1.summary).map(Arc::new).map(Some))
            .unwrap_or(Ok(None))
    }
}

#[cfg(all(test, target_os = "linux"))]
mod gates;
#[cfg(test)]
mod tests;
