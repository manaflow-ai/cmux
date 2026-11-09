//! Part of `Hub`; see `hub/mod.rs`. The closed rows' cached bytes, kept in list order between
//! lists (Leo 2026-11-04: "never ... acceptable ... linear time growth degradation").
//!
//! A closed row is serialized once and rebuilt only when its stamp moves (`SummaryStamp`) or a
//! tag it reads expires. Each form (the list's, and the full one with tools) keeps its rows
//! sorted as a list sends them, so one chat's change costs its own row's removal and insert: a
//! list copies the rows' bytes in that order (`list_guard::Rows::finish_with`) and parses and
//! sorts none of them. Before, each list parsed every closed row back and sorted every row:
//! 38 ms after one chat's record at 3,000 sessions.

use super::list_guard::RowKey;
use super::*;
use std::cmp::Reverse;
use std::collections::BTreeSet;

/// Where a closed row sorts: as `list_guard::Rows::finish` sorts (newest first, then by
/// `sessionId`, then by peer), then by the session's id, so no two rows tie.
type RowOrder = (Reverse<u64>, String, Option<String>, String);

/// A closed row as a list copies it: its bytes and its paging keys.
pub(crate) struct ClosedRow {
    pub(crate) bytes: Arc<str>,
    pub(crate) key: Arc<RowKey>,
}

/// One serialized form of a closed session's row.
#[derive(Default)]
struct Form {
    stamp: SummaryStamp,
    /// When the first tag it read expires (0: none).
    next_expiry: u64,
    bytes: Arc<str>,
    key: Arc<RowKey>,
    /// Where it is in its form's order.
    order: Option<RowOrder>,
    /// The last walk (`Hub::own_rows_in_order`) that found it current.
    seen: u64,
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

/// Every closed session's cached rows, and each form's rows in list order.
#[derive(Default)]
pub(crate) struct ClosedRows {
    entries: HashMap<String, Entry>,
    list_order: BTreeSet<RowOrder>,
    full_order: BTreeSet<RowOrder>,
    walks: u64,
}

impl ClosedRows {
    #[cfg(test)]
    pub(super) fn contains_key(&self, id: &str) -> bool {
        self.entries.contains_key(id)
    }

    /// Session `id`'s cached bytes in `with_tools`'s form, when built at `stamp` and no tag they
    /// read expired by `now`; the walk `seen` found them current, if one did.
    fn current(
        &mut self,
        id: &str,
        with_tools: bool,
        stamp: SummaryStamp,
        now: u64,
        seen: Option<u64>,
    ) -> Option<Arc<str>> {
        let cached = self.entries.get_mut(id)?.form_mut(with_tools);
        if !cached.current(stamp, now) {
            return None;
        }
        if let Some(seen) = seen {
            cached.seen = seen;
        }
        Some(cached.bytes.clone())
    }

    /// Keeps `row` as session `id`'s `with_tools` form, built at `stamp`, and moves it to its
    /// place in that form's order: one removal and one insert.
    fn store(
        &mut self,
        id: String,
        with_tools: bool,
        (stamp, next_expiry): (SummaryStamp, u64),
        row: &Value,
        seen: Option<u64>,
    ) {
        let key = RowKey::of(row, 0);
        let order = (
            Reverse(key.updated_at),
            key.session_id.clone().unwrap_or_default(),
            key.peer.clone(),
            id.clone(),
        );
        let cached = self.entries.entry(id).or_default().form_mut(with_tools);
        let sorted = if with_tools { &mut self.full_order } else { &mut self.list_order };
        if cached.order.as_ref() != Some(&order) {
            if let Some(old) = cached.order.take() {
                sorted.remove(&old);
            }
            sorted.insert(order.clone());
            cached.order = Some(order);
        }
        cached.stamp = stamp;
        cached.next_expiry = next_expiry;
        cached.bytes = serde_json::to_string(row).unwrap_or_default().into();
        cached.key = Arc::new(key);
        // A row stored between a walk and its copy is still that walk's: kept, not unseen.
        if let Some(seen) = seen {
            cached.seen = seen;
        }
    }

    fn remove(&mut self, id: &str) {
        if let Some(entry) = self.entries.remove(id) {
            if let Some(order) = entry.list.order {
                self.list_order.remove(&order);
            }
            if let Some(order) = entry.full.order {
                self.full_order.remove(&order);
            }
        }
    }

    /// The rows of `with_tools`'s form walk `walk` found current, in list order, save those of
    /// `listed` (the sessions the walk listed live): a session listed once, as it is now.
    fn in_order(&self, with_tools: bool, walk: u64, listed: &HashSet<String>) -> Vec<ClosedRow> {
        let sorted = if with_tools { &self.full_order } else { &self.list_order };
        sorted
            .iter()
            .filter_map(|(.., id)| {
                let cached = self.entries.get(id)?.form(with_tools);
                (cached.seen == walk && !listed.contains(id))
                    .then(|| ClosedRow { bytes: cached.bytes.clone(), key: cached.key.clone() })
            })
            .collect()
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
        self.closed_summary_seen(session, with_tools, None).0
    }

    /// [`Self::cached_closed_summary`], and whether the row is a closed one now cached; the walk
    /// `seen` (`own_rows_in_order`) marks it so.
    fn closed_summary_seen(
        &self,
        session: &Session,
        with_tools: bool,
        seen: Option<u64>,
    ) -> (Value, bool) {
        let id = session.id.clone();
        let now = now_ms();
        // Read before the row is built: a change while it builds leaves the cached bytes stale.
        let stamp = self.summary_stamp(session);
        if session.status() == SessionStatus::Closed
            && let Some(bytes) = self
                .closed_summary_cache
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .current(&id, with_tools, stamp, now, seen)
            && let Ok(row) = self.parse_cached_row(&bytes)
        {
            return (row, true);
        }
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
            return (row, false);
        }
        #[cfg(test)]
        self.closed_summary_builds.fetch_add(1, Ordering::SeqCst);
        let mut cache = self.closed_summary_cache.lock().unwrap_or_else(|e| e.into_inner());
        // A summary may have been built while purge was unregistering the session. Recheck
        // the tombstone while holding the cache lock so a late reader cannot recreate it.
        if session.purged.load(Ordering::SeqCst) {
            return (row, false);
        }
        cache.store(id, with_tools, (stamp, next_expiry), &row, seen);
        (row, true)
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

    /// This daemon's own sessions for a list, in `with_tools`'s form: each live one's row to
    /// `live` (built now, unsorted), and the closed ones' cached rows, returned in list order.
    /// Only a closed row whose stamp moved is built again; none is parsed or sorted.
    pub(crate) fn own_rows_in_order(
        &self,
        with_tools: bool,
        mut live: impl FnMut(Value),
    ) -> Vec<ClosedRow> {
        // One walk at a time: each marks the rows it found current, and copies those.
        let _one = self.closed_rows_walk.lock().unwrap_or_else(|e| e.into_inner());
        let now = now_ms();
        let sessions: Vec<(Arc<Session>, Option<SummaryStamp>)> = self
            .sessions()
            .into_iter()
            .map(|session| {
                let closed = session.status() == SessionStatus::Closed;
                let stamp = closed.then(|| self.summary_stamp(&session));
                (session, stamp)
            })
            .collect();
        let mut rebuild = Vec::new();
        let walk = {
            let mut cache = self.closed_summary_cache.lock().unwrap_or_else(|e| e.into_inner());
            cache.walks += 1;
            let walk = cache.walks;
            for (session, stamp) in sessions {
                let current = stamp.is_some_and(|stamp| {
                    cache.current(&session.id, with_tools, stamp, now, Some(walk)).is_some()
                });
                if !current {
                    rebuild.push(session);
                }
            }
            walk
        };
        let mut listed = HashSet::new();
        for session in rebuild {
            // A live row, or a closed one that is cached and marked by this walk now. A session
            // that went live meanwhile is listed with the row just built, and its cached row,
            // whatever marked it, is not (review: a reopen during a list listed it twice).
            let (row, cached) = self.closed_summary_seen(&session, with_tools, Some(walk));
            if !cached {
                live(row);
                listed.insert(session.id.clone());
            }
        }
        let cache = self.closed_summary_cache.lock().unwrap_or_else(|e| e.into_inner());
        cache.in_order(with_tools, walk, &listed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A session the walk listed live is never listed again from a cached row the same walk
    /// marked (review: a chat reopened between the walk's status read and its rebuild was
    /// listed twice in one list).
    #[test]
    fn a_session_listed_live_is_not_listed_again_from_its_cached_row() {
        let mut rows = ClosedRows::default();
        let row = |id: &str, at: u64| json!({"sessionId": id, "updatedAt": at, "status": "closed"});
        for (id, at) in [("a", 2), ("b", 1)] {
            rows.store(id.into(), false, (SummaryStamp::default(), 0), &row(id, at), Some(7));
        }
        let ids = |listed: &[&str]| -> Vec<Option<String>> {
            let listed = listed.iter().map(|id| (*id).to_owned()).collect();
            rows.in_order(false, 7, &listed).iter().map(|r| r.key.session_id.clone()).collect()
        };
        assert_eq!(ids(&[]), [Some("a".to_owned()), Some("b".to_owned())]);
        assert_eq!(ids(&["a"]), [Some("b".to_owned())]);
    }
}
