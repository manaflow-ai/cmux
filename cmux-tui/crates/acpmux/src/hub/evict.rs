//! Part of `Hub`; see `hub/mod.rs`. An idle chat is a row, not a session in memory (Leo
//! 2026-11-14: "memory and cpu staying flat on infinite chats ... the dream of never ever
//! needing to close a tab or workspace or anything").
//!
//! A chat with no agent (hibernated, `idle.rs`, or closed), no client attached, no turn, nothing
//! queued, asked or running below it, nothing unwritten, and no use for `ACPMUX_EVICT_IDLE_SECS`
//! leaves the session map: its `Session` (channels, locks, the meta writer's saved copy, the
//! context snapshot) is dropped, and the tier keeps an [`Evicted`] row: its metadata, for the
//! whole-set reads (names, adoption, keys), and its list row's bytes in both forms, for a list
//! page. Anything that reads it by id goes through [`Hub::session_get`], which reads its
//! metadata from the store and makes the session again as a daemon start does
//! (`install_stored_session`); its log is read when a reader asks for it, as after a start.
//!
//! A chat leaves only when the map's entry is the one handle anybody holds (checked under the map
//! lock after the list order lets go of its own), so no request that already holds it can change
//! a copy nobody sees again. Off unless `ACPMUX_EVICT_IDLE_SECS` is set (0: off).

use super::*;

/// The env var that turns eviction on: seconds of no use after which an idle chat leaves memory.
pub(crate) const EVICT_IDLE_ENV: &str = "ACPMUX_EVICT_IDLE_SECS";

/// How many chats one pass evicts at most, so a pass after a long sleep stays short.
const EVICT_AT_ONCE: usize = 256;

/// One evicted chat: what the whole-set reads and a list page need without its session, about
/// 1 kB. Its whole metadata stays in the store: a chat's is ~11 kB (most of it the cmux guidance
/// every chat carries), and kept here it cost about what the session it replaced did (dhat,
/// n=1,000: 27 kB a row against 30 kB a session).
pub(crate) struct Evicted {
    pub(super) keys: EvictedKeys,
    /// Its list row (no tools) and full row (with tools), serialized when it left.
    list: PackedRow,
    full: PackedRow,
}

/// What a whole-set read or a create's check matches an evicted chat by: the fields of its
/// metadata they read, nothing else.
pub(crate) struct EvictedKeys {
    pub(super) id: String,
    pub(super) name: String,
    pub(super) status: SessionStatus,
    pub(super) updated_at: u64,
    /// Its `session.alias` tag's value.
    pub(super) alias: Option<String>,
    pub(super) handle: Option<String>,
    pub(super) former_names: Vec<String>,
    pub(super) create_key: Option<String>,
    pub(super) agent_session_id: Option<String>,
}

impl EvictedKeys {
    pub(super) fn of(m: &SessionMeta) -> Self {
        Self {
            id: m.id.clone(),
            name: m.name.clone(),
            status: m.status,
            updated_at: m.updated_at,
            alias: m.tags.get("session.alias").map(|tag| tag.value.clone()),
            handle: m.handle.clone(),
            former_names: m.former_names.clone(),
            create_key: m.create_key.clone(),
            agent_session_id: m.agent_session_id.clone(),
        }
    }
}

/// A list row's bytes, packed against the tier's shared row ([`Tier::row_dict`]): rows have the
/// same keys and mostly the same values, so each keeps little more than what differs (a 3.5 kB
/// row is a few hundred bytes). Unpacked when a list page reads it.
enum PackedRow {
    Packed {
        dict: Arc<RowDict>,
        len: u32,
        bytes: Box<[u8]>,
    },
    /// Kept as it is when packing failed, or did not make it smaller.
    Plain(Arc<str>),
}

/// The zstd level rows are packed at: an eviction packs two rows, a list page unpacks them.
const ROW_LEVEL: i32 = 3;

/// The shared row, prepared once for packing and for unpacking: a list page unpacks every
/// evicted row it shows, and loading the raw row into each unpack cost more than the unpack.
pub(crate) struct RowDict {
    pack: zstd::dict::EncoderDictionary<'static>,
    unpack: zstd::dict::DecoderDictionary<'static>,
}

impl RowDict {
    fn new(row: &[u8]) -> Self {
        Self {
            pack: zstd::dict::EncoderDictionary::copy(row, ROW_LEVEL),
            unpack: zstd::dict::DecoderDictionary::copy(row),
        }
    }
}

impl PackedRow {
    fn pack(text: Arc<str>, dict: &Arc<RowDict>) -> Self {
        let packed = u32::try_from(text.len()).ok().and_then(|len| {
            let mut packer = zstd::bulk::Compressor::with_prepared_dictionary(&dict.pack).ok()?;
            let bytes = packer.compress(text.as_bytes()).ok()?;
            (bytes.len() < text.len()).then_some((len, bytes))
        });
        match packed {
            Some((len, bytes)) => {
                Self::Packed { dict: dict.clone(), len, bytes: bytes.into_boxed_slice() }
            }
            None => Self::Plain(text),
        }
    }

    fn text(&self) -> Arc<str> {
        match self {
            Self::Plain(text) => text.clone(),
            Self::Packed { dict, len, bytes } => {
                let unpacked = zstd::bulk::Decompressor::with_prepared_dictionary(&dict.unpack)
                    .and_then(|mut d| d.decompress(bytes, *len as usize))
                    .ok()
                    .and_then(|raw| String::from_utf8(raw).ok());
                // It packed bytes that were a string; nothing else can come back.
                unpacked.map(Into::into).unwrap_or_else(|| "null".into())
            }
        }
    }

    /// Bytes it holds besides the shared row.
    #[cfg(test)]
    fn held(&self) -> usize {
        match self {
            Self::Plain(text) => text.len(),
            Self::Packed { bytes, .. } => bytes.len(),
        }
    }
}

impl Evicted {
    pub(super) fn id(&self) -> &str {
        &self.keys.id
    }

    pub(super) fn updated_at(&self) -> u64 {
        self.keys.updated_at
    }

    pub(super) fn status(&self) -> SessionStatus {
        self.keys.status
    }

    pub(super) fn row_text(&self, with_tools: bool) -> Arc<str> {
        if with_tools { self.full.text() } else { self.list.text() }
    }

    /// Bytes its rows hold besides the shared row.
    #[cfg(test)]
    pub(super) fn rows_held(&self) -> usize {
        self.list.held() + self.full.held()
    }
}

/// The evicted chats, by id.
pub(crate) struct Tier {
    rows: StdMutex<HashMap<String, Arc<Evicted>>>,
    /// Idle period after which a chat leaves, in hub clock nanoseconds; 0: never.
    after_ns: AtomicU64,
    pub(super) evictions: AtomicU64,
    pub(super) rehydrations: AtomicU64,
    /// The last pass stopped at [`EVICT_AT_ONCE`]: due chats remain that nothing kept.
    pub(super) more_due: AtomicBool,
    /// The row every evicted row is packed against ([`PackedRow`]): the first one evicted.
    row_dict: StdMutex<Option<Arc<RowDict>>>,
}

impl Default for Tier {
    fn default() -> Self {
        let secs = std::env::var(EVICT_IDLE_ENV).ok().and_then(|v| v.trim().parse::<u64>().ok());
        Self {
            rows: Default::default(),
            after_ns: AtomicU64::new(secs.unwrap_or(0).saturating_mul(1_000_000_000)),
            evictions: AtomicU64::new(0),
            rehydrations: AtomicU64::new(0),
            more_due: AtomicBool::new(false),
            row_dict: StdMutex::new(None),
        }
    }
}

impl Tier {
    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, Arc<Evicted>>> {
        self.rows.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub(super) fn after(&self) -> Option<std::time::Duration> {
        let ns = self.after_ns.load(Ordering::Relaxed);
        (ns != 0).then(|| std::time::Duration::from_nanos(ns))
    }

    #[cfg(test)]
    pub(crate) fn set_after(&self, after: Option<std::time::Duration>) {
        let ns = after.map_or(0, |d| u64::try_from(d.as_nanos()).unwrap_or(u64::MAX).max(1));
        self.after_ns.store(ns, Ordering::Relaxed);
    }

    pub(super) fn len(&self) -> usize {
        self.lock().len()
    }

    /// The shared row rows are packed against, `first` when there is none yet.
    fn row_dict(&self, first: &str) -> Arc<RowDict> {
        let mut dict = self.row_dict.lock().unwrap_or_else(|e| e.into_inner());
        dict.get_or_insert_with(|| Arc::new(RowDict::new(first.as_bytes()))).clone()
    }

    /// `session`'s row for this tier: its keys and both list rows, packed.
    fn row_of(&self, meta: &SessionMeta, list: Arc<str>, full: Arc<str>) -> Evicted {
        let dict = self.row_dict(&list);
        Evicted {
            keys: EvictedKeys::of(meta),
            list: PackedRow::pack(list, &dict),
            full: PackedRow::pack(full, &dict),
        }
    }

    /// How many evicted chats are not closed: they count as live, as they did in memory.
    pub(super) fn live_len(&self) -> usize {
        self.lock().values().filter(|row| row.keys.status != SessionStatus::Closed).count()
    }

    pub(super) fn contains(&self, id: &str) -> bool {
        self.lock().contains_key(id)
    }

    pub(super) fn get(&self, id: &str) -> Option<Arc<Evicted>> {
        self.lock().get(id).cloned()
    }

    /// Every evicted row, in no order.
    pub(super) fn rows(&self) -> Vec<Arc<Evicted>> {
        self.lock().values().cloned().collect()
    }

    /// Whether any evicted chat's keys answer `pred`: the whole-set reads' other half.
    pub(super) fn any_keys(&self, mut pred: impl FnMut(&EvictedKeys) -> bool) -> bool {
        self.lock().values().any(|row| pred(&row.keys))
    }

    /// Every evicted chat's name: the taken names a new chat's name avoids.
    pub(super) fn names(&self) -> Vec<String> {
        self.lock().values().map(|row| row.keys.name.clone()).collect()
    }

    /// The ids of the evicted chats whose keys answer `pred`.
    pub(super) fn ids_where(&self, mut pred: impl FnMut(&EvictedKeys) -> bool) -> Vec<String> {
        self.lock().values().filter(|row| pred(&row.keys)).map(|row| row.keys.id.clone()).collect()
    }
}

impl Hub {
    /// Session `id`, from the map or, when it was evicted, made again from the store: every read
    /// by id that may meet an evicted chat goes through here.
    pub(crate) fn session_get(&self, id: &str) -> Option<Arc<Session>> {
        if let Some(session) = self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(id) {
            return Some(session.clone());
        }
        self.rehydrate(id)
    }

    /// Makes evicted chat `id` a session in the map again, from its stored metadata. None when it
    /// is not evicted (or the store no longer has it).
    pub(super) fn rehydrate(&self, id: &str) -> Option<Arc<Session>> {
        if !self.evicted.contains(id) {
            return None;
        }
        let began = std::time::Instant::now();
        // One rehydrate per chat at once: the map lock is held from the check to the insert by
        // `install_stored_session`, and the tier row goes only after the session is in the map,
        // so a reader between them finds one or the other.
        let meta = match self.store.load_startup(id) {
            Ok(Some(meta)) if meta.id == id => meta,
            other => {
                tracing::warn!(session = %id, ok = other.is_ok(), "evicted chat not in the store");
                return None;
            }
        };
        self.install_stored_session_quiet(meta);
        let session = self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(id).cloned();
        if session.is_some() && self.evicted.lock().remove(id).is_some() {
            self.evicted.rehydrations.fetch_add(1, Ordering::Relaxed);
            tracing::debug!(session = %id, took_us = began.elapsed().as_micros() as u64, "rehydrated");
        }
        session
    }

    /// Brings back every evicted chat `key` may name (its id or qualified id, whole name, alias,
    /// last name segments, or a prefix of id, name or alias), so a resolve by key picks among the
    /// same chats it did before any left memory (`Hub::resolve_here` and the other name reads).
    pub(super) fn rehydrate_named(&self, key: &str) {
        if key.is_empty() || self.evicted.len() == 0 {
            return;
        }
        let qualified = SessionReceipt::split_qualified_id(key)
            .filter(|(host, _)| *host == LOCAL_HOST_ID)
            .map(|(_, id)| id);
        let bare = !key.contains('/');
        let ids = self.evicted.ids_where(|m| {
            let alias = m.alias.as_deref();
            qualified == Some(m.id.as_str())
                || m.id.starts_with(key)
                || m.name.starts_with(key)
                || alias.is_some_and(|alias| alias.starts_with(key))
                || m.handle.as_deref().is_some_and(|h| h.starts_with(key))
                || m.former_names.iter().any(|n| n.starts_with(key))
                || (bare && crate::session_name::ends_with_segments(&m.name, key))
        });
        for id in ids {
            self.rehydrate(&id);
        }
    }

    /// Brings back every evicted chat whose keys answer `pred` (a create's id, key, name or
    /// adopted session: the checks that pick or refuse it read the map).
    pub(super) fn rehydrate_where(&self, pred: impl FnMut(&EvictedKeys) -> bool) {
        if self.evicted.len() == 0 {
            return;
        }
        for id in self.evicted.ids_where(pred) {
            self.rehydrate(&id);
        }
    }

    /// Whether `session` may leave memory now (`now`: hub clock, `after`: its idle period).
    fn evictable(&self, session: &Session, now: u64, after: u64) -> bool {
        self.kept_because(session, now, after).is_none()
    }

    /// Why `session` stays in memory now, or None when it may leave.
    pub(super) fn kept_because(
        &self,
        session: &Session,
        now: u64,
        after: u64,
    ) -> Option<&'static str> {
        let checks: [(&'static str, &dyn Fn() -> bool); 24] = [
            ("recently active", &|| {
                session.last_active.load(Ordering::SeqCst).saturating_add(after) > now
            }),
            ("awake", &|| {
                let status = session.status();
                !(status == SessionStatus::Closed
                    || (status == SessionStatus::Idle
                        && session.hibernated_at.load(Ordering::SeqCst) != 0))
            }),
            ("hub stopping", &|| self.stopping.load(Ordering::SeqCst)),
            ("has an agent", &|| !session.child.try_lock().is_ok_and(|c| c.is_none())),
            ("attached", &|| session.attached.load(Ordering::SeqCst) != 0),
            ("in a turn", &|| session.turn().is_some()),
            ("harness turn", &|| session.harness_turn.load(Ordering::SeqCst)),
            ("queued", &|| session.queued() != 0),
            // Its inbound loop holds it only weakly between items: an item queued, or a sender
            // beside its own (an agent, a reader), still has work for it.
            // A chat that never made its channel has nothing inbound (read, not made, here).
            ("inbound", &|| {
                session.inbound.get().is_some_and(|ch| {
                    ch.tx.strong_count() > 1 || ch.tx.capacity() < ch.tx.max_capacity()
                })
            }),
            ("asks in flight", &|| session.asks_in_flight.load(Ordering::SeqCst) != 0),
            ("agent requests", &|| session.agent_requests.load(Ordering::SeqCst) != 0),
            ("permissions pending", &|| !session.pending_permissions().is_empty()),
            ("secret wait", &|| self.secrets.waiting_in(&session.id)),
            ("work below", &|| self.holds_work_below_read(session)),
            ("continuation", &|| self.continuation_pending(session)),
            ("moving", &|| !session.moving.lock().is_ok_and(|m| m.is_none())),
            ("loading", &|| session.loading.load(Ordering::SeqCst)),
            ("restoring", &|| session.restoring.load(Ordering::SeqCst)),
            ("closing", &|| session.closing.load(Ordering::SeqCst)),
            ("purging", &|| session.purging.load(Ordering::SeqCst)),
            ("unflushed", &|| !session.unflushed.lock().is_ok_and(|u| u.is_empty())),
            ("parked", &|| !session.parked.lock().is_ok_and(|p| p.is_none())),
            ("watching", &|| session.read_meta(|m| m.watching.is_some())),
            ("tag expiry", &|| {
                session.read_meta(|m| views::next_tag_expiry(m, crate::store::now_ms()).is_some())
            }),
        ];
        checks.iter().find(|(_, kept)| kept()).map(|(why, _)| *why)
    }

    /// When the first resident chat's eviction falls due, on the hub clock (the idle reaper sleeps
    /// until then). None when eviction is off or no chat is a candidate.
    ///
    /// A chat already past its deadline that is still here was kept (`kept_because`, another
    /// holder, a failed barrier): it is tried again one `after` later, not now, or the reaper wakes
    /// at once, finds it kept and sleeps until the same past deadline, in a loop (98% CPU and 330
    /// wakeups/s idle in the n=100 bench). Only when the last pass stopped at [`EVICT_AT_ONCE`] do
    /// past deadlines wake it at once.
    pub(super) fn next_evict_deadline(&self) -> Option<std::time::Duration> {
        let after = self.evicted.after()?;
        let now = std::time::Duration::from_nanos(self.clock_now());
        let retry = if self.evicted.more_due.load(Ordering::Relaxed) { now } else { now + after };
        self.session_handles()
            .iter()
            .filter(|s| s.child.try_lock().is_ok_and(|c| c.is_none()))
            .filter(|s| s.attached.load(Ordering::Relaxed) == 0)
            .map(|s| {
                let since = s.last_active.load(Ordering::Relaxed);
                std::time::Duration::from_nanos(since.max(s.evict_tried_at.load(Ordering::Relaxed)))
                    + after
            })
            .map(|due| if due > now { due } else { retry })
            .min()
    }

    /// One pass of the idle reaper: every chat due leaves memory (at most [`EVICT_AT_ONCE`]).
    pub(super) fn evict_idle_chats(&self) -> usize {
        let Some(after) = self.evicted.after() else { return 0 };
        let after = u64::try_from(after.as_nanos()).unwrap_or(u64::MAX);
        let now = self.clock_now();
        // A chat this reaper tried within the last idle period and could not evict waits out that
        // period: else the same kept chats fill every batch, `more_due` stays set and the reaper
        // runs pass after pass at once (98.8% CPU, 374 wakeups/s idle at n=1,000).
        let mut due: Vec<Arc<Session>> = self
            .session_handles()
            .into_iter()
            .filter(|s| s.evict_tried_at.load(Ordering::Relaxed).saturating_add(after) <= now)
            .filter(|s| self.evictable(s, now, after))
            .collect();
        // The least recently tried go first (never tried: 0), so more than a batch of kept
        // chats cannot take every batch from the chats behind them in the map's order.
        if due.len() > EVICT_AT_ONCE {
            due.select_nth_unstable_by_key(EVICT_AT_ONCE, |s| {
                s.evict_tried_at.load(Ordering::Relaxed)
            });
            due.truncate(EVICT_AT_ONCE);
        }
        let full = due.len() == EVICT_AT_ONCE;
        // Each handle moves into `evict`: a clone kept here would count as a third holder. Each
        // is marked tried first; one that leaves takes the mark with it.
        let evicted = due
            .into_iter()
            .map(|s| {
                s.evict_tried_at.store(now, Ordering::Relaxed);
                let id = s.id.clone();
                self.evict(s, now, after)
                    .inspect_err(|why| tracing::debug!(session = %id, %why, "kept in memory"))
            })
            .filter(Result::is_ok)
            .count();
        // More are due at once only when this pass was full and every chat in it left.
        self.evicted.more_due.store(full && evicted == EVICT_AT_ONCE, Ordering::Relaxed);
        evicted
    }

    /// `session` leaves the map for a tier row, when nothing else holds it.
    pub(super) fn evict(&self, session: Arc<Session>, now: u64, after: u64) -> Result<(), String> {
        // Everything it changed is on disk first: its rehydrate reads the store.
        self.meta_barrier(&session).map_err(|e| format!("meta barrier: {}", e.message))?;
        let list = self.own_row_text(&session, false);
        let full = self.own_row_text(&session, true);
        let row = Arc::new(session.read_meta(|m| self.evicted.row_of(m, list, full)));
        let id = session.id.clone();
        // The other long-lived handles let go first: the chat activity's (rebuilt on its next read).
        self.chat_activity_cache.drop_built();
        let mut order = self.list_order_lock();
        let mut sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
        // Read again under the map lock: a request may have used it meanwhile.
        let held = sessions.get(&id).is_some_and(|s| Arc::ptr_eq(s, &session));
        if !held {
            return Err("not the map's session".into());
        }
        if let Some(why) = self.kept_because(&session, now, after) {
            return Err(why.into());
        }
        let in_order = Self::order_evict(&mut order, &id, &row);
        // The map's handle and this one: nobody else may still write to it.
        let count = Arc::strong_count(&session);
        if count != 2 {
            if in_order {
                Self::order_restore(&mut order, &id, &session);
            }
            return Err(format!("held elsewhere ({} handles)", count));
        }
        self.evicted.lock().insert(id.clone(), row);
        sessions.remove(&id);
        drop(sessions);
        drop(order);
        self.live_session_ids.lock().unwrap_or_else(|e| e.into_inner()).remove(&id);
        self.chat_activity_cache.invalidate();
        self.evicted.evictions.fetch_add(1, Ordering::Relaxed);
        tracing::debug!(session = %id, "evicted: an idle chat is a row");
        Ok(())
    }

    /// Why chat `id` would not leave memory now (None when it would, and then it has left): what
    /// a test reads when an eviction it expects does not happen.
    #[cfg(test)]
    pub(crate) fn evict_now_for_test(&self, id: &str) -> Option<String> {
        let after = u64::try_from(self.evicted.after()?.as_nanos()).unwrap_or(u64::MAX);
        let session = self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(id).cloned()?;
        self.evict(session, self.clock_now(), after).err()
    }

    /// How many chats are evicted now, and how many were evicted and rehydrated since the start.
    pub(crate) fn eviction_counts(&self) -> (usize, u64, u64) {
        (
            self.evicted.len(),
            self.evicted.evictions.load(Ordering::Relaxed),
            self.evicted.rehydrations.load(Ordering::Relaxed),
        )
    }
}

#[cfg(test)]
#[path = "evict_tests.rs"]
mod tests;
