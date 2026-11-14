//! v2's book tee (agent service v2, row 3b; the design doc's "Migration" step 1 and "The chat
//! actor"), behind `books`: each chat v1 appends to gets a book, read by the chat's actor from
//! v1's event log (`v1_source.rs`). Nothing is served from a book here: v1 serves every chat.
//!
//! - **The hook is a mark** ([`BookTee::mark`]). After v1's store took a line, for every line it
//!   takes whatever the append's `notify` says, the hook stores the seq in the chat's hint and
//!   marks the chat's id in a set. It carries no line, does no I/O, takes no lock another task
//!   holds across I/O, starts no actor and encodes nothing. It never waits. With no tee
//!   installed (`books` off, a store in memory) v1's append is as it was.
//! - **One task drains the set** ([`start_book_tee`]), 256 ids at a time, and tells each chat's
//!   actor through the registry (`wake`), hydrating one that is cold. A full mailbox drops the
//!   notice and loses nothing: the hint is in the source, and the actor reads up to it. A failed
//!   chat's notice is dropped and puts nothing in its mailbox.
//! - **The background pass** ([`pass`]) catches up the chats nobody opens, newest first. It holds
//!   at most two actors it started and closes each when it is `ready`. It passes over a chat
//!   whose log is in v1's cold archive, which a read would bring back to disk. It never waits on
//!   v1 and v1 never waits on it.
//! - **A purge** forgets the chat's actor ([`BookTee::forget`]) before v1 removes the chat's
//!   directory, and [`BookTee::unforget`] once the chat is gone: no actor writes into a directory
//!   a purge removed, and no book outlives its chat.
//! - **One path from raw to rows.** A live line, a catch-up and a replay after a kill are the
//!   actor's one loop: the tee only says that the source grew.

use super::v1_source::V1Log;
use super::*;
use acpmux_book::translate::Harness;
use acpmux_core::chat::{ChatConfig, ChatHandle};
use acpmux_core::registry::Registry;
use std::collections::HashSet;
use tokio::sync::Notify;

const BATCH: usize = 256;

/// How many actors the pass starts and holds at once.
pub(crate) const PASS_ACTORS: usize = 2;

/// The book's folder in a chat's directory.
pub(crate) const BOOK: &str = "book";

/// v1's store, as a v1 source reads it: through the hub that holds it.
#[derive(Clone)]
pub(crate) struct HubStore(Arc<Hub>);

impl AsRef<dyn Store> for HubStore {
    fn as_ref(&self) -> &(dyn Store + 'static) {
        self.0.store.as_ref()
    }
}

/// What the tee and its pass counted, for tests and gates.
#[derive(Default, Debug)]
pub(crate) struct Counters {
    pub marks: AtomicU64,
    /// Notices given to a mailbox.
    pub told: AtomicU64,
    /// Notices dropped: a full mailbox, a failed chat, a closed actor.
    pub dropped: AtomicU64,
    /// Actors the pass started, live now and the most at once.
    pub pass_live: AtomicU64,
    pub pass_live_max: AtomicU64,
    /// Chats the pass caught up and closed, and those it passed over in the cold archive.
    pub pass_closed: AtomicU64,
    pub pass_cold: AtomicU64,
    pub pass_done: AtomicBool,
}

pub(crate) struct BookTee {
    pending: std::sync::Mutex<HashSet<String>>,
    notify: Notify,
    registry: Registry,
    pub(crate) counters: Counters,
    /// What every v1 source the tee made counted, shared between them.
    pub(crate) sources: Arc<super::v1_source::Counters>,
}

impl BookTee {
    pub(crate) fn new(registry: Registry) -> Self {
        Self {
            pending: Default::default(),
            notify: Notify::new(),
            registry,
            counters: Counters::default(),
            sources: Arc::default(),
        }
    }

    #[cfg(test)]
    pub(crate) fn registry(&self) -> &Registry {
        &self.registry
    }

    /// The hook at v1's append, once the store took the line `seq` of `session`.
    pub(super) fn mark(&self, session: &Session, seq: u64) {
        session.book_hint.fetch_max(seq, Ordering::Release);
        self.counters.marks.fetch_add(1, Ordering::Relaxed);
        // The drain is woken only when the set was empty: one that holds ids has a wake given
        // since the drain last took from it, so a burst of lines wakes it once.
        let wake = {
            let mut pending = self.pending.lock().unwrap_or_else(|e| e.into_inner());
            let wake = pending.is_empty();
            if !pending.contains(&session.id) {
                pending.insert(session.id.clone());
            }
            wake
        };
        if wake {
            self.notify.notify_one();
        }
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
    pub(crate) fn pending(&self) -> usize {
        self.pending.lock().unwrap_or_else(|e| e.into_inner()).len()
    }

    /// A purge's first step, before the chat's directory is removed: closes and joins its actor,
    /// and keeps it cold. Blocking: run off the runtime's workers.
    pub(super) fn forget(&self, id: &str) {
        self.registry.forget(id);
    }

    /// A purge's last step, once the chat is gone from v1.
    pub(super) fn unforget(&self, id: &str) {
        self.registry.unforget(id);
    }

    /// The chat's actor, hydrated when cold; None for a chat v1 no longer has, one being purged,
    /// or one with no directory.
    fn actor(&self, v1: &Arc<Hub>, id: &str) -> Option<(ChatHandle, bool)> {
        if let Some(handle) = self.registry.get(id) {
            return Some((handle, false));
        }
        let session = v1.session_by_id(id)?;
        if session.purged.load(Ordering::SeqCst) {
            return None;
        }
        self.registry.start(config(v1, self, &session)?)
    }

    /// Tells chat `id`'s actor that its source grew.
    fn tell(&self, v1: &Arc<Hub>, id: &str) {
        let Some((handle, _)) = self.actor(v1, id) else { return };
        match handle.wake() {
            Ok(()) => {
                self.counters.told.fetch_add(1, Ordering::Relaxed);
            }
            // A full mailbox, a failed chat, a closed actor: the hint holds what it told of.
            Err(_) => {
                self.counters.dropped.fetch_add(1, Ordering::Relaxed);
            }
        }
    }
}

/// The book of chat `session`, read from v1's log: `<chat dir>/book`.
pub(crate) fn config(v1: &Arc<Hub>, tee: &BookTee, session: &Session) -> Option<ChatConfig> {
    let dir = v1.store.session_path(&session.id)?;
    let hint = session.book_hint.clone();
    let mut log = V1Log::new(
        HubStore(v1.clone()),
        &session.id,
        session.found_at_start,
        Arc::new(move || hint.load(Ordering::Acquire)),
    );
    log.opened = session.book_opened.clone();
    log.counters = tee.sources.clone();
    Some(
        ChatConfig::new(&session.id, dir.join(BOOK), Harness::V1)
            .with_source_factory(log.factory()),
    )
}

/// The tee and its task: the drain and, once v1 has loaded its chats, the background pass.
pub(crate) fn start_book_tee(
    v1: Arc<Hub>,
    registry: Registry,
) -> (Arc<BookTee>, impl std::future::Future<Output = ()> + Send + 'static) {
    let tee = Arc::new(BookTee::new(registry));
    let state = tee.clone();
    // One task: the pass ends when every chat is caught up, the drain never does.
    let task = async move {
        tokio::join!(pass(v1.clone(), state.clone()), drain(&v1, &state));
    };
    (tee, task)
}

/// The one task that drains the set. Never returns.
pub(crate) async fn drain(v1: &Arc<Hub>, tee: &BookTee) {
    loop {
        let ids = tee.take();
        if ids.is_empty() {
            tee.notify.notified().await;
            continue;
        }
        for id in ids {
            tee.tell(v1, &id);
        }
        tokio::task::yield_now().await;
    }
}

/// The background pass: every chat v1 has, newest first, caught up by an actor it starts and
/// closes at `ready`, at most [`PASS_ACTORS`] at once.
pub(crate) async fn pass(v1: Arc<Hub>, tee: Arc<BookTee>) {
    let mut loaded = v1.store_load.ready.subscribe();
    while !*loaded.borrow_and_update() {
        if loaded.changed().await.is_err() {
            return;
        }
    }
    let mut chats: Vec<(u64, String)> = v1
        .session_handles()
        .into_iter()
        .map(|session| (session.read_meta(|meta| meta.updated_at), session.id.clone()))
        .collect();
    chats.sort_unstable_by(|a, b| b.cmp(a));
    let mut running = tokio::task::JoinSet::new();
    for (_, id) in chats {
        while running.len() >= PASS_ACTORS {
            running.join_next().await;
        }
        if tee.registry.get(&id).is_some() {
            continue;
        }
        let Some(session) = v1.session_by_id(&id) else { continue };
        if session.purged.load(Ordering::SeqCst) {
            continue;
        }
        // Looked at off the runtime's workers: it reads the chat's folder.
        let hub = v1.clone();
        let look = id.clone();
        let cold = tokio::task::spawn_blocking(move || hub.store.is_cold(&look)).await;
        if cold.unwrap_or(true) {
            tee.counters.pass_cold.fetch_add(1, Ordering::Relaxed);
            continue;
        }
        let Some(config) = config(&v1, &tee, &session) else { continue };
        let Some((handle, true)) = tee.registry.start(config) else { continue };
        let live = tee.counters.pass_live.fetch_add(1, Ordering::SeqCst) + 1;
        tee.counters.pass_live_max.fetch_max(live, Ordering::SeqCst);
        let tee = tee.clone();
        running.spawn(async move {
            handle.wait_ready().await;
            let registry = tee.registry.clone();
            let _ = tokio::task::spawn_blocking(move || registry.evict(&id)).await;
            tee.counters.pass_live.fetch_sub(1, Ordering::SeqCst);
            tee.counters.pass_closed.fetch_add(1, Ordering::Relaxed);
        });
    }
    while running.join_next().await.is_some() {}
    tee.counters.pass_done.store(true, Ordering::SeqCst);
}

/// The hook's time inside `write_record_locked`, for the gate.
#[cfg(test)]
pub(crate) static HOOK_NS: std::sync::Mutex<Vec<u64>> = std::sync::Mutex::new(Vec::new());

#[cfg(test)]
pub(super) fn note_hook(took: std::time::Duration) {
    let mut samples = HOOK_NS.lock().unwrap_or_else(|e| e.into_inner());
    if samples.len() < 1 << 20 {
        samples.push(u64::try_from(took.as_nanos()).unwrap_or(u64::MAX));
    }
}

impl Hub {
    /// Connects v2's book tee: from here each line v1's store takes marks its chat.
    pub(crate) fn install_book_tee(&self, tee: Arc<BookTee>) {
        let _ = self.book_tee.set(tee);
    }

    pub(crate) fn book_tee(&self) -> Option<&Arc<BookTee>> {
        self.book_tee.get()
    }
}

#[cfg(all(test, target_os = "linux"))]
mod gates;
#[cfg(test)]
mod tests;
