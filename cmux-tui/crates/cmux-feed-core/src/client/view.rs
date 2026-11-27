//! `feed.view.read`'s answer (plans/cmux-next/feed-page.md section 2): the
//! layouts of Swift `FeedListSections` and `FeedInboxGroups`, read from the
//! mirror's ordered list (no sort per read), with each item's row content,
//! pending mark and GitHub detail.

use serde::Deserialize;
use serde_json::{Value, json};

use super::filter::{Filter, Matcher};
use super::github::{self, GitHubSync};
use super::item::FeedItem;
use super::mirror::Mirror;
use super::row::{Place, Row};

/// `feed.view.read` answers at most this many entries.
pub const MAX_VIEW_ENTRIES: usize = 2000;
const DAY_MS: i64 = 86_400_000;

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

impl ViewContext<'_> {
    /// One item as the page reads it: its wire JSON, `pending`, `row`, and
    /// for a GitHub item `github` and `github_actions`.
    pub fn item(&self, item: &FeedItem) -> Value {
        let mut value = item.to_value();
        let place = (self.place)(item);
        let detail = self.github.and_then(|github| github.detail(item));
        if let Some(object) = value.as_object_mut() {
            object.insert("pending".to_owned(), json!(self.mirror.is_pending(&item.id)));
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

    /// The whole view.
    pub fn view(&self, request: &ViewRequest) -> Value {
        let matcher = Matcher::new(request.filter.clone().unwrap_or_default());
        let limit = request.limit.unwrap_or(MAX_VIEW_ENTRIES).min(MAX_VIEW_ENTRIES);
        let kept = || self.mirror.list().filter(|item| matcher.keeps(item));
        let mut groups: Vec<(&str, Vec<Entry<'_>>)> = Vec::new();
        let requests = || kept().filter(|item| item.is_open_request()).map(Entry::single);
        match request.layout {
            Layout::List => {
                groups.push(("requests", requests().collect()));
                let rest = kept().filter(|item| !item.is_open_request()).map(Entry::single);
                groups.push(("rest", rest.collect()));
            }
            Layout::NeedsYou => groups.push(("needs_you", requests().collect())),
            Layout::Inbox => {
                let offset = i64::from(request.tz_offset_min.unwrap_or(0)).saturating_mul(60_000);
                let day = |ms: i64| ms.saturating_add(offset).div_euclid(DAY_MS);
                let today = day(self.now);
                let (mut recent, mut older) = (Vec::new(), Vec::new());
                for item in kept().filter(|item| !item.is_open_request()) {
                    if day(item.created_at) == today { recent.push(item) } else { older.push(item) }
                }
                groups.push(("needs_you", requests().collect()));
                groups.push(("today", threads(recent)));
                groups.push(("earlier", threads(older)));
            }
        }
        let total: usize = groups.iter().map(|(_, entries)| entries.len()).sum();
        let mut left = limit;
        let groups: Vec<Value> = groups
            .into_iter()
            .map(|(id, entries)| {
                let shown = entries.len().min(left);
                left = left.saturating_sub(shown);
                let entries: Vec<Value> =
                    entries.iter().take(shown).map(|entry| entry.to_value(self)).collect();
                json!({"id": id, "entries": entries})
            })
            .collect();
        let counts = self.mirror.counts();
        let connection = self.mirror.connection();
        let connection_value = match connection.reason() {
            Some(reason) => json!({"state": connection.state(), "reason": reason}),
            None => json!({"state": connection.state()}),
        };
        json!({
            "revision": self.mirror.revision(),
            "loaded": self.mirror.loaded(),
            "account": self.account.map(|account| json!({"id": account.id, "user": account.user})),
            "connection": connection_value,
            "counts": {
                "open_requests": counts.open_requests,
                "unread_notices": counts.unread_notices,
                "badge": counts.badge(),
                "unread": counts.unread,
            },
            "github": {"enabled": self.github_enabled},
            "reports": {"available": self.reports_available},
            "groups": groups,
            "total": total,
        })
    }
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
        json!({
            "id": id,
            "item": context.item(head),
            "members": members,
            "unread": std::iter::once(head).chain(self.members.iter().copied()).filter(|item| item.is_unread()).count(),
        })
    }
}

/// Collapses items that share a thread; `items` are newest first, so each
/// entry's head is its newest item and entries stay newest first.
fn threads(items: Vec<&FeedItem>) -> Vec<Entry<'_>> {
    let mut entries: Vec<Entry<'_>> = Vec::new();
    let mut index: std::collections::HashMap<&str, usize> = std::collections::HashMap::new();
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
