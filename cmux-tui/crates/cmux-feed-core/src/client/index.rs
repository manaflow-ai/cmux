//! The ledger's per-filter index, so the Inbox and a filtered page read
//! O(page) however many items the feed holds. One [`Slice`] per filter the
//! page offers without a search query (connection x category; Needs you is
//! the open requests of the All slice). Each holds its active items in the
//! panel list's order, every thread's items, and minute buckets of the
//! unthreaded items and of each thread's newest and oldest item: the Inbox's
//! Today and Earlier totals are sums over one day of buckets (at most 1440),
//! whatever the reader's time zone. `Ledger::update` keeps every slice
//! current, per changed item, the same way it keeps the list.
//!
//! Nothing here is persisted: the mirror is rebuilt from the owners'
//! snapshot, and the index with it.

use std::cmp::Reverse;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::ops::Bound;
use std::sync::Arc;

use super::filter::{Category, Connection, is_github};
use super::item::FeedItem;

const MINUTE_MS: i64 = 60_000;

/// An open request's place in the list: by priority, then newest; ids
/// break ties (the list's request section).
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct OpenKey {
    rank: Reverse<i8>,
    time: Reverse<i64>,
    pub(crate) id: Arc<str>,
}

/// Newest first; ids break ties (the list's rest section).
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct TimeKey {
    time: Reverse<i64>,
    pub(crate) id: Arc<str>,
}

impl TimeKey {
    pub(crate) fn time(&self) -> i64 {
        self.time.0
    }

    /// The first key at or below `time` (the newest item no newer than it).
    fn at_or_before(time: i64) -> Self {
        Self { time: Reverse(time), id: Arc::from("") }
    }
}

/// How many items fall in each minute (Unix minute -> count).
#[derive(Default)]
struct Buckets(BTreeMap<i64, usize>);

impl Buckets {
    fn add(&mut self, time: i64) {
        *self.0.entry(time.div_euclid(MINUTE_MS)).or_default() += 1;
    }

    fn sub(&mut self, time: i64) {
        let minute = time.div_euclid(MINUTE_MS);
        if let Some(count) = self.0.get_mut(&minute) {
            *count = count.saturating_sub(1);
            if *count == 0 {
                self.0.remove(&minute);
            }
        }
    }

    /// Items in the whole minutes of `[from, to)`, both minute-aligned.
    fn sum(&self, from: i64, to: i64) -> usize {
        let (from, to) = (from.div_euclid(MINUTE_MS), to.div_euclid(MINUTE_MS));
        if from >= to {
            return 0;
        }
        self.0.range(from..to).map(|(_, count)| count).sum()
    }
}

/// Which slice an item can be in: a filter without a search query.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct SliceKey {
    pub(crate) connection: Connection,
    /// `All`, `Unread` or `Notices` (Needs you reads the All slice's open
    /// requests).
    pub(crate) category: Category,
}

const SLICES: [SliceKey; 6] = [
    SliceKey { connection: Connection::Feed, category: Category::All },
    SliceKey { connection: Connection::Feed, category: Category::Unread },
    SliceKey { connection: Connection::Feed, category: Category::Notices },
    SliceKey { connection: Connection::Github, category: Category::All },
    SliceKey { connection: Connection::Github, category: Category::Unread },
    SliceKey { connection: Connection::Github, category: Category::Notices },
];

impl SliceKey {
    fn keeps(self, item: &FeedItem) -> bool {
        if self.connection == Connection::Github && !is_github(item) {
            return false;
        }
        match self.category {
            Category::All | Category::NeedsYou => true,
            Category::Unread => item.is_unread(),
            Category::Notices => !item.is_request(),
        }
    }
}

/// The active items one filter keeps.
#[derive(Default)]
pub(crate) struct Slice {
    /// Open requests, in list order.
    open: BTreeSet<OpenKey>,
    /// Everything else, newest first.
    rest: BTreeSet<TimeKey>,
    /// `rest`'s threaded items, by thread, newest first.
    threads: HashMap<Arc<str>, BTreeSet<TimeKey>>,
    /// `rest`'s unthreaded items.
    unthreaded: Buckets,
    unthreaded_len: usize,
    /// Each thread's newest and oldest item.
    newest: Buckets,
    oldest: Buckets,
}

impl Slice {
    fn insert(&mut self, item: &FeedItem, id: &Arc<str>) {
        if item.is_open_request() {
            self.open.insert(OpenKey {
                rank: Reverse(item.priority.rank()),
                time: Reverse(item.created_at),
                id: id.clone(),
            });
            return;
        }
        let key = TimeKey { time: Reverse(item.created_at), id: id.clone() };
        self.rest.insert(key.clone());
        match item.thread.as_deref() {
            None => {
                self.unthreaded.add(item.created_at);
                self.unthreaded_len = self.unthreaded_len.saturating_add(1);
            }
            Some(thread) => {
                let set = match self.threads.get_mut(thread) {
                    Some(set) => set,
                    None => self.threads.entry(Arc::from(thread)).or_default(),
                };
                let ends = ends_of(set);
                set.insert(key);
                let now = ends_of(set);
                move_ends(&mut self.newest, &mut self.oldest, ends, now);
            }
        }
    }

    fn remove(&mut self, item: &FeedItem, id: &Arc<str>) {
        if item.is_open_request() {
            self.open.remove(&OpenKey {
                rank: Reverse(item.priority.rank()),
                time: Reverse(item.created_at),
                id: id.clone(),
            });
            return;
        }
        let key = TimeKey { time: Reverse(item.created_at), id: id.clone() };
        if !self.rest.remove(&key) {
            return;
        }
        match item.thread.as_deref() {
            None => {
                self.unthreaded.sub(item.created_at);
                self.unthreaded_len = self.unthreaded_len.saturating_sub(1);
            }
            Some(thread) => {
                let Some(set) = self.threads.get_mut(thread) else { return };
                let ends = ends_of(set);
                set.remove(&key);
                let now = ends_of(set);
                if set.is_empty() {
                    self.threads.remove(thread);
                }
                move_ends(&mut self.newest, &mut self.oldest, ends, now);
            }
        }
    }

    /// Open requests, in list order.
    pub(crate) fn open(&self) -> impl Iterator<Item = &str> {
        self.open.iter().map(|key| &*key.id)
    }

    pub(crate) fn open_len(&self) -> usize {
        self.open.len()
    }

    /// Everything but open requests, newest first.
    pub(crate) fn rest(&self) -> impl Iterator<Item = &str> {
        self.rest.iter().map(|key| &*key.id)
    }

    pub(crate) fn rest_len(&self) -> usize {
        self.rest.len()
    }

    /// The rest's items in `[from, to)` (`to` exclusive; `None` unbounded),
    /// newest first.
    pub(crate) fn rest_between(
        &self,
        from: Option<i64>,
        to: Option<i64>,
    ) -> impl Iterator<Item = &TimeKey> {
        let start = match to {
            // Newest first: the first key older than `to`.
            Some(to) => match to.checked_sub(1) {
                Some(last) => Bound::Included(TimeKey::at_or_before(last)),
                None => Bound::Excluded(TimeKey::at_or_before(i64::MIN)),
            },
            None => Bound::Unbounded,
        };
        let empty = to.zip(from).is_some_and(|(to, from)| to <= from) || to == Some(i64::MIN);
        self.rest
            .range((start, Bound::Unbounded))
            .take_while(move |key| !empty && from.is_none_or(|from| key.time() >= from))
    }

    /// A thread's items older than `after` (exclusive) and at least `from`
    /// (`None`: no floor), newest first.
    pub(crate) fn thread_after<'a>(
        &'a self,
        thread: &str,
        after: &TimeKey,
        from: Option<i64>,
    ) -> impl Iterator<Item = &'a TimeKey> {
        self.threads
            .get(thread)
            .into_iter()
            .flat_map(move |set| set.range((Bound::Excluded(after.clone()), Bound::Unbounded)))
            .take_while(move |key| from.is_none_or(|from| key.time() >= from))
    }

    /// A thread's items older than `before` (exclusive), newest first.
    pub(crate) fn thread_before<'a>(
        &'a self,
        thread: &str,
        before: i64,
    ) -> impl Iterator<Item = &'a TimeKey> {
        let start = match before.checked_sub(1) {
            Some(last) => Bound::Included(TimeKey::at_or_before(last)),
            None => Bound::Excluded(TimeKey::at_or_before(i64::MIN)),
        };
        let none = before == i64::MIN;
        self.threads
            .get(thread)
            .into_iter()
            .flat_map(move |set| set.range((start.clone(), Bound::Unbounded)))
            .take_while(move |_| !none)
    }

    /// The Inbox's entry totals for the day `[from, to)` (both
    /// minute-aligned): Today's (unthreaded items plus threads with an item
    /// that day) and Earlier's (everything else, a thread once). `future`
    /// are the threads with an item at or after `to`, with whether they have
    /// an item in the day and whether their oldest item is in it.
    pub(crate) fn day_totals(&self, from: i64, to: i64, future: &[FutureThread]) -> (usize, usize) {
        let unthreaded_today = self.unthreaded.sum(from, to);
        let touched_future = future.iter().filter(|thread| thread.in_day).count();
        let today = unthreaded_today
            .saturating_add(self.newest.sum(from, to))
            .saturating_add(touched_future);
        // A thread only in the day: its oldest item is in it and its newest
        // is before `to`.
        let oldest_in_day_future = future.iter().filter(|thread| thread.oldest_in_day).count();
        let only_today = self.oldest.sum(from, to).saturating_sub(oldest_in_day_future);
        let earlier = self
            .unthreaded_len
            .saturating_sub(unthreaded_today)
            .saturating_add(self.threads.len().saturating_sub(only_today));
        (today, earlier)
    }

    /// The threads with an item at or after `to`, for [`Self::day_totals`].
    pub(crate) fn future_threads(
        &self,
        from: i64,
        to: i64,
        thread_of: impl Fn(&str) -> Option<Arc<str>>,
    ) -> Vec<FutureThread> {
        let mut seen: HashSet<Arc<str>> = HashSet::new();
        let mut out = Vec::new();
        for key in self.rest_between(Some(to), None) {
            let Some(thread) = thread_of(&key.id) else { continue };
            if !seen.insert(thread.clone()) {
                continue;
            }
            let Some(set) = self.threads.get(&*thread) else { continue };
            let in_day = set
                .range(TimeKey::at_or_before(to.saturating_sub(1))..)
                .next()
                .is_some_and(|key| key.time() >= from && key.time() < to);
            let oldest = set.last().map_or(i64::MIN, TimeKey::time);
            out.push(FutureThread { in_day, oldest_in_day: oldest >= from && oldest < to });
        }
        out
    }
}

/// One thread with an item at or after the end of the reader's day.
pub(crate) struct FutureThread {
    in_day: bool,
    oldest_in_day: bool,
}

/// A thread's newest and oldest time.
fn ends_of(set: &BTreeSet<TimeKey>) -> Option<(i64, i64)> {
    Some((set.first()?.time(), set.last()?.time()))
}

fn move_ends(
    newest: &mut Buckets,
    oldest: &mut Buckets,
    was: Option<(i64, i64)>,
    now: Option<(i64, i64)>,
) {
    if was == now {
        return;
    }
    if let Some((new, old)) = was {
        newest.sub(new);
        oldest.sub(old);
    }
    if let Some((new, old)) = now {
        newest.add(new);
        oldest.add(old);
    }
}

/// Every slice.
#[derive(Default)]
pub(crate) struct Index {
    slices: [Slice; 6],
}

impl Index {
    /// `item` became active (or changed while active).
    pub(crate) fn insert(&mut self, item: &FeedItem, id: &Arc<str>) {
        for (key, slice) in SLICES.iter().zip(self.slices.iter_mut()) {
            if key.keeps(item) {
                slice.insert(item, id);
            }
        }
    }

    /// `item` (as indexed) left the active items, or is about to change.
    pub(crate) fn remove(&mut self, item: &FeedItem, id: &Arc<str>) {
        for (key, slice) in SLICES.iter().zip(self.slices.iter_mut()) {
            if key.keeps(item) {
                slice.remove(item, id);
            }
        }
    }

    /// The slice of a filter without a query (`NeedsYou` reads its
    /// connection's All slice).
    pub(crate) fn slice(&self, connection: Connection, category: Category) -> Option<&Slice> {
        let category = if category == Category::NeedsYou { Category::All } else { category };
        SLICES
            .iter()
            .position(|key| key.connection == connection && key.category == category)
            .and_then(|at| self.slices.get(at))
    }
}
