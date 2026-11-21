//! `feed.view.read`'s answer (plans/cmux-next/feed-page.md section 2): the
//! layouts of Swift `FeedListSections` and `FeedInboxGroups`, read from the
//! ledger's orders and filter index (no sort or scan per read), with each
//! item's row content, pending mark and GitHub detail.
//!
//! A filter without a search query reads its slice of the index
//! (`client/index.rs`): a page costs what it shows, and the totals are
//! counts. A search query scans the panel list.

use std::cell::Cell;
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use serde::Deserialize;
use serde_json::{Map, Value, json};

use super::filter::{Category, Filter, Matcher};
use super::github::{self, GitHubSync};
use super::index::{Slice, TimeKey};
use super::item::FeedItem;
use super::mirror::Mirror;
use super::row::{Place, Row};

/// `feed.view.read` answers at most this many entries.
pub const MAX_VIEW_ENTRIES: usize = 2000;
const DAY_MS: i64 = 86_400_000;

thread_local! {
    static VISITED: Cell<u64> = const { Cell::new(0) };
}

/// Items the views read on this thread so far (each item a view looks at,
/// shown or not): the work count the stress tests compare across feed sizes.
#[doc(hidden)]
pub fn items_visited() -> u64 {
    VISITED.with(Cell::get)
}

fn visit() {
    VISITED.with(|count| count.set(count.get().wrapping_add(1)));
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Layout {
    /// Open requests pinned on top (by priority, then newest), the rest
    /// below, newest first.
    #[default]
    List,
    /// Needs you, Today and Earlier; thread members collapse under the newest.
    Inbox,
    /// The open requests only.
    NeedsYou,
}

/// `feed.view.read` params.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ViewRequest {
    #[serde(default)]
    pub layout: Layout,
    #[serde(default)]
    pub filter: Option<Filter>,
    /// The reader's offset from UTC in minutes (Today is its calendar day).
    #[serde(default)]
    pub tz_offset_min: Option<i32>,
    #[serde(default)]
    pub limit: Option<usize>,
}

/// The account a view is for: the cloud lease's person (`id`, the lease
/// identity, which names the project or server too; `user`, the person's user
/// id). A reader that keeps anything from a view keys it by `id`, so another
/// account's view never inherits it, even before its first snapshot.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ViewAccount<'a> {
    pub id: &'a str,
    pub user: Option<&'a str>,
}

/// What a view reads besides the mirror.
pub struct ViewContext<'a> {
    pub mirror: &'a Mirror,
    /// The lease's person; `None` signed out (no lease, or a chief token's).
    pub account: Option<ViewAccount<'a>>,
    pub now: i64,
    pub github: Option<&'a GitHubSync>,
    pub github_enabled: bool,
    pub reports_available: bool,
    /// Names an item's agent, workspace and tab from the daemon's store.
    pub place: &'a dyn Fn(&FeedItem) -> Option<Place>,
}

/// Each group: its id, the entries built (at least the shown ones), and how
/// many entries it has in all.
type Group<'a> = (&'a str, Vec<Entry<'a>>, usize);

/// The reader's day as Unix ms `[from, to)`: the items `day(created_at) ==
/// day(now)` keeps. `None` when the bounds do not fit (an offset or a clock
/// at the edge of the range), which the scan handles.
fn day_bounds(now: i64, offset: i64) -> Option<(i64, i64)> {
    let today = now.checked_add(offset)?.div_euclid(DAY_MS);
    let from = today.checked_mul(DAY_MS)?.checked_sub(offset)?;
    let to = today.checked_add(1)?.checked_mul(DAY_MS)?.checked_sub(offset)?;
    // Any `created_at` outside `[from, to)` must fall on another day even
    // where `created_at + offset` saturates.
    let edge = i64::MAX.div_euclid(DAY_MS);
    (today > i64::MIN.div_euclid(DAY_MS) && today < edge && offset % 60_000 == 0)
        .then_some((from, to))
}

impl ViewContext<'_> {
    /// One item as the page reads it: its wire JSON, `pending`, `row`, and
    /// for a GitHub item `github` and `github_actions`.
    pub fn item(&self, item: &FeedItem) -> Value {
        let mut value = item.to_value();
        let place = (self.place)(item);
        let detail = self.github.and_then(|github| github.detail(item));
        if let Some(object) = value.as_object_mut() {
            object.insert("pending".to_owned(), Value::Bool(self.mirror.is_pending(&item.id)));
            object.insert("row".to_owned(), json!(Row::of(item, place.as_ref())));
            if let Some(detail) = detail {
                object.insert("github".to_owned(), detail.to_value());
            }
            if let Some(actions) = github::actions(item, detail) {
                object.insert("github_actions".to_owned(), json!(actions));
            }
        }
        value
    }

    /// A visible item, counted as read by this view.
    fn read(&self, id: &str) -> Option<&FeedItem> {
        visit();
        self.mirror.ledger().visible.get(id)
    }

    /// The whole view.
    pub fn view(&self, request: &ViewRequest) -> Value {
        let filter = request.filter.clone().unwrap_or_default();
        let limit = request.limit.unwrap_or(MAX_VIEW_ENTRIES).min(MAX_VIEW_ENTRIES);
        let offset = i64::from(request.tz_offset_min.unwrap_or(0)).saturating_mul(60_000);
        let searched = filter.query.as_deref().is_some_and(|query| !query.trim().is_empty());
        let day = day_bounds(self.now, offset);
        let slice = self.mirror.ledger().index.slice(filter.connection, filter.category);
        let groups = match slice {
            Some(slice) if !searched && (request.layout != Layout::Inbox || day.is_some()) => {
                self.indexed(slice, request.layout, filter.category, limit, day)
            }
            _ => self.scanned(Matcher::new(filter), request.layout, offset),
        };
        self.answer(groups, limit)
    }

    /// The groups from a slice of the index: only the shown entries are
    /// built; totals are counts.
    fn indexed<'a>(
        &'a self,
        slice: &'a Slice,
        layout: Layout,
        category: Category,
        limit: usize,
        day: Option<(i64, i64)>,
    ) -> Vec<Group<'a>> {
        let mut left = limit;
        let open_total = slice.open_len();
        let open: Vec<Entry<'a>> =
            slice.open().take(left).filter_map(|id| self.read(id)).map(Entry::single).collect();
        left = left.saturating_sub(open.len());
        // Needs you keeps the open requests only.
        let rest_total = if category == Category::NeedsYou { 0 } else { slice.rest_len() };
        match layout {
            Layout::List => {
                let rest: Vec<Entry<'a>> = slice
                    .rest()
                    .take(if rest_total == 0 { 0 } else { left })
                    .filter_map(|id| self.read(id))
                    .map(Entry::single)
                    .collect();
                vec![("requests", open, open_total), ("rest", rest, rest_total)]
            }
            Layout::NeedsYou => vec![("needs_you", open, open_total)],
            Layout::Inbox => {
                let (mut today, mut earlier) = (Vec::new(), Vec::new());
                let (mut today_total, mut earlier_total) = (0, 0);
                if let (Some((from, to)), true) = (day, rest_total > 0) {
                    let future = slice.future_threads(from, to, |id| {
                        self.read(id).and_then(|item| item.thread.as_deref()).map(Arc::from)
                    });
                    (today_total, earlier_total) = slice.day_totals(from, to, &future);
                    today = self.day_entries(slice, (from, to), left, true);
                    left = left.saturating_sub(today.len());
                    earlier = self.day_entries(slice, (from, to), left, false);
                }
                vec![
                    ("needs_you", open, open_total),
                    ("today", today, today_total),
                    ("earlier", earlier, earlier_total),
                ]
            }
        }
    }

    /// Today's (`today`) or Earlier's first `budget` entries: each thread
    /// collapsed under its newest item in the group, members fetched from
    /// the thread's own order. The walk reads only shown heads and the
    /// members of shown entries.
    fn day_entries<'a>(
        &'a self,
        slice: &'a Slice,
        (from, to): (i64, i64),
        budget: usize,
        today: bool,
    ) -> Vec<Entry<'a>> {
        let mut entries = Vec::new();
        if budget == 0 {
            return entries;
        }
        let heads: Box<dyn Iterator<Item = &TimeKey>> = if today {
            Box::new(slice.rest_between(Some(from), Some(to)))
        } else {
            // Later days first (newest first), then the days before.
            Box::new(slice.rest_between(Some(to), None).chain(slice.rest_between(None, Some(from))))
        };
        let mut seen: HashSet<&str> = HashSet::new();
        for key in heads {
            if entries.len() >= budget {
                break;
            }
            let Some(head) = self.read(&key.id) else { continue };
            let Some(thread) = head.thread.as_deref() else {
                entries.push(Entry::single(head));
                continue;
            };
            if !seen.insert(thread) {
                continue;
            }
            let members: Vec<&FeedItem> = if today {
                slice
                    .thread_after(thread, key, Some(from))
                    .filter_map(|m| self.read(&m.id))
                    .collect()
            } else if key.time() >= to {
                slice
                    .thread_after(thread, key, Some(to))
                    .chain(slice.thread_before(thread, from))
                    .filter_map(|m| self.read(&m.id))
                    .collect()
            } else {
                slice.thread_after(thread, key, None).filter_map(|m| self.read(&m.id)).collect()
            };
            entries.push(Entry { head, members });
        }
        entries
    }

    /// The groups of a search: every kept item of the panel list is read.
    fn scanned(&self, matcher: Matcher, layout: Layout, offset: i64) -> Vec<Group<'_>> {
        let kept = || self.mirror.list().inspect(|_| visit()).filter(|item| matcher.keeps(item));
        let requests = || kept().filter(|item| item.is_open_request()).map(Entry::single);
        match layout {
            Layout::List => {
                let rest = kept().filter(|item| !item.is_open_request()).map(Entry::single);
                vec![whole("requests", requests().collect()), whole("rest", rest.collect())]
            }
            Layout::NeedsYou => vec![whole("needs_you", requests().collect())],
            Layout::Inbox => {
                let day = |ms: i64| ms.saturating_add(offset).div_euclid(DAY_MS);
                let today = day(self.now);
                let (mut recent, mut older) = (Vec::new(), Vec::new());
                for item in kept().filter(|item| !item.is_open_request()) {
                    if day(item.created_at) == today { recent.push(item) } else { older.push(item) }
                }
                vec![
                    whole("needs_you", requests().collect()),
                    whole("today", threads(recent)),
                    whole("earlier", threads(older)),
                ]
            }
        }
    }

    /// The answer around the groups: the first `limit` entries across them.
    fn answer(&self, groups: Vec<Group<'_>>, limit: usize) -> Value {
        let total: usize = groups.iter().map(|(_, _, len)| len).sum();
        let mut left = limit;
        let groups: Vec<Value> = groups
            .into_iter()
            .map(|(id, entries, _)| {
                let shown = entries.len().min(left);
                left = left.saturating_sub(shown);
                let entries: Vec<Value> =
                    entries.iter().take(shown).map(|entry| entry.to_value(self)).collect();
                object([("id", Value::from(id)), ("entries", Value::Array(entries))])
            })
            .collect();
        let counts = self.mirror.counts();
        let connection = self.mirror.connection();
        let connection_value = match connection.reason() {
            Some(reason) => json!({"state": connection.state(), "reason": reason}),
            None => json!({"state": connection.state()}),
        };
        // Built by moving each part in: `json!` would copy every entry again.
        object([
            ("revision", json!(self.mirror.revision())),
            ("loaded", Value::Bool(self.mirror.loaded())),
            (
                "account",
                self.account
                    .map_or(Value::Null, |account| json!({"id": account.id, "user": account.user})),
            ),
            ("connection", connection_value),
            (
                "counts",
                json!({
                    "open_requests": counts.open_requests,
                    "unread_notices": counts.unread_notices,
                    "badge": counts.badge(),
                    "unread": counts.unread,
                }),
            ),
            ("github", json!({"enabled": self.github_enabled})),
            ("reports", json!({"available": self.reports_available})),
            ("groups", Value::Array(groups)),
            ("total", json!(total)),
        ])
    }
}

/// An object of moved members (no copy of any value).
fn object<const N: usize>(members: [(&str, Value); N]) -> Value {
    let mut map = Map::new();
    for (key, value) in members {
        map.insert(key.to_owned(), value);
    }
    Value::Object(map)
}

/// One row: an item, or a collapsed thread headed by its newest item.
struct Entry<'a> {
    /// The newest item.
    head: &'a FeedItem,
    /// The thread's older items, newest first.
    members: Vec<&'a FeedItem>,
}

impl<'a> Entry<'a> {
    fn single(item: &'a FeedItem) -> Self {
        Self { head: item, members: Vec::new() }
    }

    fn to_value(&self, context: &ViewContext<'_>) -> Value {
        let head = self.head;
        // Unique across groups: a thread can head an entry in Today and
        // another in Earlier, and open requests of one thread stay apart.
        let id = match &head.thread {
            Some(thread) => format!("thread:{thread}:{}", head.id),
            None => head.id.clone(),
        };
        let members: Vec<Value> = self.members.iter().map(|item| context.item(item)).collect();
        let unread = std::iter::once(head)
            .chain(self.members.iter().copied())
            .filter(|item| item.is_unread())
            .count();
        object([
            ("id", Value::String(id)),
            ("item", context.item(head)),
            ("members", Value::Array(members)),
            ("unread", json!(unread)),
        ])
    }
}

/// Collapses items that share a thread; `items` are newest first, so each
/// entry's head is its newest item and entries stay newest first.
fn threads(items: Vec<&FeedItem>) -> Vec<Entry<'_>> {
    let mut entries: Vec<Entry<'_>> = Vec::new();
    let mut index: HashMap<&str, usize> = HashMap::new();
    for item in items {
        match &item.thread {
            Some(thread) => match index.get(thread.as_str()) {
                Some(&at) => {
                    if let Some(entry) = entries.get_mut(at) {
                        entry.members.push(item);
                    }
                }
                None => {
                    index.insert(thread.as_str(), entries.len());
                    entries.push(Entry::single(item));
                }
            },
            None => entries.push(Entry::single(item)),
        }
    }
    entries
}

/// A group whose entries are all built: its id, entries and their count.
fn whole<'a>(id: &'a str, entries: Vec<Entry<'a>>) -> Group<'a> {
    let len = entries.len();
    (id, entries, len)
}
