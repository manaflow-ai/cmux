//! Part of `Hub`; see `hub/mod.rs`. The closed rows' cached bytes, kept between lists (Leo
//! 2026-11-04: "never ... acceptable ... linear time growth degradation").
//!
//! A closed row is serialized once and rebuilt only when its stamp moves (`SummaryStamp`) or a
//! tag it reads expires. A list page picks its rows from their keys first (`page_first.rs`) and
//! copies a closed row's bytes as they are kept ([`Hub::own_row_text`]): one chat's change costs
//! its own row's rebuild, and a page parses none of the others.
//!
//! The bytes kept are bounded ([`KEPT_BYTES`]), the least recently read form going first: a full
//! form carries the chat's time breakdown and tools, and with eviction off (`evict.rs`) every
//! closed chat's stayed. A fleet lane VM's daemon held 1,612 closed chats and about 2,100 rows'
//! `timeBreakdown` text in a 4 GB heap (2026-11-26). A form let go is built again at its next read,
//! as a moved stamp's is. `gauges.memory.closedRows` counts them.

use super::*;

/// What every closed row's cached bytes hold together, at most. Past it the least recently read
/// forms go ([`ClosedRows::evict`]).
const KEPT_BYTES: usize = 64 << 20;

/// One serialized form of a closed session's row.
#[derive(Default)]
struct Form {
    stamp: SummaryStamp,
    /// When the first tag it read expires (0: none).
    next_expiry: u64,
    bytes: Arc<str>,
    /// When it was last stored or read ([`ClosedRows::tick`]): the oldest goes first.
    used: u64,
}

impl Form {
    fn current(&self, stamp: SummaryStamp, now: u64) -> bool {
        self.stamp == stamp
            && (self.next_expiry == 0 || now < self.next_expiry)
            && !self.bytes.is_empty()
    }
}

/// The list form and the full one (with tools).
#[derive(Default)]
struct Entry {
    list: Form,
    full: Form,
}

impl Entry {
    fn form_mut(&mut self, with_tools: bool) -> &mut Form {
        if with_tools { &mut self.full } else { &mut self.list }
    }
}

/// Every closed session's cached rows, at most [`KEPT_BYTES`] of them.
pub(crate) struct ClosedRows {
    entries: HashMap<String, Entry>,
    /// Its bound: [`KEPT_BYTES`], less in a test of it.
    cap: usize,
    /// Every form's bytes together.
    bytes: usize,
    /// Forms kept (a session's list form and full form count apart).
    forms: usize,
    /// A clock of stores and reads, for which form was read longest ago.
    tick: u64,
}

impl Default for ClosedRows {
    fn default() -> Self {
        Self::with_cap(KEPT_BYTES)
    }
}

impl ClosedRows {
    fn with_cap(cap: usize) -> Self {
        Self { entries: HashMap::new(), cap, bytes: 0, forms: 0, tick: 0 }
    }

    #[cfg(test)]
    pub(super) fn contains_key(&self, id: &str) -> bool {
        self.entries.contains_key(id)
    }

    /// Session `id`'s cached bytes in `with_tools`'s form, when built at `stamp` and no tag they
    /// read expired by `now`.
    fn current(
        &mut self,
        id: &str,
        with_tools: bool,
        stamp: SummaryStamp,
        now: u64,
    ) -> Option<Arc<str>> {
        self.tick += 1;
        let cached = self.entries.get_mut(id)?.form_mut(with_tools);
        if !cached.current(stamp, now) {
            return None;
        }
        cached.used = self.tick;
        Some(cached.bytes.clone())
    }

    /// Keeps `row` as session `id`'s `with_tools` form, built at `stamp`.
    fn store(
        &mut self,
        id: String,
        with_tools: bool,
        (stamp, next_expiry): (SummaryStamp, u64),
        row: &Value,
    ) {
        self.tick += 1;
        let bytes: Arc<str> = serde_json::to_string(row).unwrap_or_default().into();
        let cached = self.entries.entry(id.clone()).or_default().form_mut(with_tools);
        let (old, new) = (cached.bytes.len(), bytes.len());
        self.forms = self.forms + usize::from(new > 0) - usize::from(old > 0);
        self.bytes = self.bytes + new - old;
        *cached = Form { stamp, next_expiry, bytes, used: self.tick };
        if self.bytes > self.cap {
            self.evict(&id, with_tools);
        }
        self.publish();
    }

    fn remove(&mut self, id: &str) {
        if let Some(entry) = self.entries.remove(id) {
            for form in [entry.list, entry.full] {
                self.bytes -= form.bytes.len();
                self.forms -= usize::from(!form.bytes.is_empty());
            }
            self.publish();
        }
    }

    /// Lets the least recently read forms go, but `keep`'s (the one just stored), until
    /// three quarters of the bound is left, so a store over it evicts once a quarter of it, not
    /// once a row.
    fn evict(&mut self, keep: &str, keep_tools: bool) {
        let mut oldest: Vec<(u64, String, bool)> = self
            .entries
            .iter()
            .flat_map(|(id, entry)| {
                [(false, &entry.list), (true, &entry.full)]
                    .into_iter()
                    .filter(|(_, form)| !form.bytes.is_empty())
                    .map(move |(tools, form)| (form.used, id.clone(), tools))
            })
            .filter(|(_, id, tools)| !(id == keep && *tools == keep_tools))
            .collect();
        oldest.sort_unstable_by_key(|(used, _, _)| *used);
        let mut evicted = 0u64;
        for (_, id, tools) in oldest {
            if self.bytes <= self.cap / 4 * 3 {
                break;
            }
            let Some(entry) = self.entries.get_mut(&id) else { continue };
            let form = std::mem::take(entry.form_mut(tools));
            self.bytes -= form.bytes.len();
            self.forms -= 1;
            evicted += 1;
            if entry.list.bytes.is_empty() && entry.full.bytes.is_empty() {
                self.entries.remove(&id);
            }
        }
        crate::gauges::closed_rows().evicted(evicted);
    }

    /// Its size, to `gauges.memory.closedRows`.
    fn publish(&self) {
        crate::gauges::closed_rows().set(self.forms, self.bytes, self.cap);
    }

    #[cfg(test)]
    pub(super) fn kept(&self) -> (usize, usize) {
        (self.forms, self.bytes)
    }
}

impl Hub {
    /// What `session`'s cached closed row must have been built at to be current.
    fn summary_stamp(&self, session: &Session) -> SummaryStamp {
        SummaryStamp {
            all: self.events.summary_generation.load(Ordering::SeqCst),
            own: session.summary_gen.load(Ordering::SeqCst),
            children: self.subsessions.generation(&session.id),
        }
    }

    pub(super) fn cached_closed_summary(&self, session: &Session, with_tools: bool) -> Value {
        if let Some(bytes) = self.closed_row_bytes(session, with_tools)
            && let Ok(row) = self.parse_cached_row(&bytes)
        {
            return row;
        }
        self.build_closed_summary(session, with_tools)
    }

    /// `session`'s row as a list page sends it, serialized: a closed one's cached bytes, not
    /// parsed; a live one's kept bytes while its inputs are unchanged (`live_rows.rs`).
    pub(crate) fn own_row_text(&self, session: &Session, with_tools: bool) -> Arc<str> {
        if let Some(bytes) = self.closed_row_bytes(session, with_tools) {
            return bytes;
        }
        if session.status() != SessionStatus::Closed {
            return self.live_row_text(session, with_tools);
        }
        let row = self.build_closed_summary(session, with_tools);
        serde_json::to_string(&row).unwrap_or_default().into()
    }

    /// A closed `session`'s cached bytes in `with_tools`'s form, when they are current.
    fn closed_row_bytes(&self, session: &Session, with_tools: bool) -> Option<Arc<str>> {
        if session.status() != SessionStatus::Closed {
            return None;
        }
        let stamp = self.summary_stamp(session);
        let mut cache = self.closed_summary_cache.lock().unwrap_or_else(|e| e.into_inner());
        cache.current(&session.id, with_tools, stamp, now_ms())
    }

    /// `session`'s row built now, and kept when it is closed.
    fn build_closed_summary(&self, session: &Session, with_tools: bool) -> Value {
        let id = session.id.clone();
        let now = now_ms();
        // Read before the row is built: a change while it builds leaves the cached bytes stale.
        let stamp = self.summary_stamp(session);
        // Its own tags' and its parent's (whether the row folds under it, `Hub::spawned_by`):
        // a tag that expires changes the row with no event.
        let (own_expiry, parent) = session.read_meta(|m| {
            let parent = super::views::activity_parent_id(m).map(str::to_owned);
            (super::views::next_tag_expiry(m, now), parent)
        });
        let parent_expiry = parent
            .filter(|parent| *parent != id)
            .and_then(|parent| self.session_by_id(&parent))
            .and_then(|parent| parent.read_meta(|m| super::views::next_tag_expiry(m, now)));
        let next_expiry = match (own_expiry, parent_expiry) {
            (Some(a), Some(b)) => a.min(b),
            (a, b) => a.or(b).unwrap_or(0),
        };
        let row = if with_tools {
            self.session_summary(session)
        } else {
            self.session_list_summary(session)
        };
        if session.status() != SessionStatus::Closed {
            return row;
        }
        #[cfg(test)]
        self.closed_summary_builds.fetch_add(1, Ordering::SeqCst);
        // Closed now: its live row is no longer read (`live_rows.rs`).
        self.remove_live_row(&id);
        let mut cache = self.closed_summary_cache.lock().unwrap_or_else(|e| e.into_inner());
        // A summary may have been built while purge was unregistering the session. Recheck
        // the tombstone while holding the cache lock so a late reader cannot recreate it.
        if session.purged.load(Ordering::SeqCst) {
            return row;
        }
        cache.store(id, with_tools, (stamp, next_expiry), &row);
        row
    }

    /// A closed row parsed back from its cached bytes.
    fn parse_cached_row(&self, bytes: &str) -> serde_json::Result<Value> {
        #[cfg(test)]
        self.closed_summary_parses.fetch_add(1, Ordering::SeqCst);
        serde_json::from_str(bytes)
    }

    pub(super) fn remove_cached_closed_summary(&self, id: &str) {
        self.closed_summary_cache.lock().unwrap_or_else(|e| e.into_inner()).remove(id);
        self.remove_live_row(id);
    }
}

#[cfg(test)]
mod bound_tests {
    use super::*;

    fn row(i: usize) -> Value {
        json!({"sessionId": format!("s{i}"), "timeBreakdown": {"spans": "x".repeat(900)}})
    }

    /// However many closed chats are read, the bytes kept stay under the bound, the
    /// one just stored and the ones read since stay, and a form let go reads as not current.
    #[test]
    fn closed_rows_keep_at_most_their_bound() {
        const CAP: usize = 64 << 10;
        let mut rows = ClosedRows::with_cap(CAP);
        let stamp = (SummaryStamp::default(), 0);
        for i in 0..5_000 {
            rows.store(format!("s{i}"), i % 2 == 0, stamp, &row(i));
            if i >= 1 {
                // A chat read now and then stays kept however many go by.
                assert!(rows.current("s1", false, stamp.0, 0).is_some(), "s1 at {i}");
            }
            let (forms, bytes) = rows.kept();
            assert!(bytes <= CAP, "{bytes} kept at {i}");
            assert!(forms <= CAP / 900, "{forms} forms at {i}");
            assert!(rows.current(&format!("s{i}"), i % 2 == 0, stamp.0, 0).is_some());
        }
        assert!(rows.current("s3", false, stamp.0, 0).is_none(), "an old form is let go");
        assert!(rows.entries.len() < 5_000 / 10, "{} entries", rows.entries.len());
        for i in 0..5_000 {
            rows.remove(&format!("s{i}"));
        }
        assert_eq!(rows.kept(), (0, 0));
        assert!(rows.entries.is_empty());
    }
}
