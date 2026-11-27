//! Part of `Hub`; see `hub/mod.rs`. The closed rows' cached bytes, kept between lists (Leo
//! 2026-11-04: "never ... acceptable ... linear time growth degradation").
//!
//! A closed row is serialized once and rebuilt only when its stamp moves (`SummaryStamp`) or a
//! tag it reads expires. A list page picks its rows from their keys first (`page_first.rs`) and
//! copies a closed row's bytes as they are kept ([`Hub::own_row_text`]): one chat's change costs
//! its own row's rebuild, and a page parses none of the others.

use super::*;

/// One serialized form of a closed session's row.
#[derive(Default)]
struct Form {
    stamp: SummaryStamp,
    /// When the first tag it read expires (0: none).
    next_expiry: u64,
    bytes: Arc<str>,
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
    fn form(&self, with_tools: bool) -> &Form {
        if with_tools { &self.full } else { &self.list }
    }

    fn form_mut(&mut self, with_tools: bool) -> &mut Form {
        if with_tools { &mut self.full } else { &mut self.list }
    }
}

/// Every closed session's cached rows.
#[derive(Default)]
pub(crate) struct ClosedRows {
    entries: HashMap<String, Entry>,
}

impl ClosedRows {
    #[cfg(test)]
    pub(super) fn contains_key(&self, id: &str) -> bool {
        self.entries.contains_key(id)
    }

    /// Session `id`'s cached bytes in `with_tools`'s form, when built at `stamp` and no tag they
    /// read expired by `now`.
    fn current(
        &self,
        id: &str,
        with_tools: bool,
        stamp: SummaryStamp,
        now: u64,
    ) -> Option<Arc<str>> {
        let cached = self.entries.get(id)?.form(with_tools);
        cached.current(stamp, now).then(|| cached.bytes.clone())
    }

    /// Keeps `row` as session `id`'s `with_tools` form, built at `stamp`.
    fn store(
        &mut self,
        id: String,
        with_tools: bool,
        (stamp, next_expiry): (SummaryStamp, u64),
        row: &Value,
    ) {
        let cached = self.entries.entry(id).or_default().form_mut(with_tools);
        cached.stamp = stamp;
        cached.next_expiry = next_expiry;
        cached.bytes = serde_json::to_string(row).unwrap_or_default().into();
    }

    fn remove(&mut self, id: &str) {
        self.entries.remove(id);
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
    /// parsed; any other built now.
    pub(crate) fn own_row_text(&self, session: &Session, with_tools: bool) -> Arc<str> {
        if let Some(bytes) = self.closed_row_bytes(session, with_tools) {
            return bytes;
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
        let cache = self.closed_summary_cache.lock().unwrap_or_else(|e| e.into_inner());
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
    }
}
