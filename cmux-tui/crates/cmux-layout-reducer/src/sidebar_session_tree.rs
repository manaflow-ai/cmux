//! The sidebar's session tree (`sidebar.sessionTree`, Claude desktop's Code
//! tab): which workspace's agent started each workspace's agent (acpmux's
//! `spawnedBy`), the folds the person keeps on those parents, which
//! agent-started rows the list hides, and each row's pull request badge.
//!
//! Moved from cmux-next macOS `SidebarSessionTree.swift`
//! (`SidebarSessionTreeState`, `SidebarSessionTree.toggle`/`reveal`/`save`,
//! `SidebarPullRequestBadge`, `SidebarPullRequestItem`). The app keeps its
//! observable store and its revisions; the rules are these. The app reaches
//! them through `cmux_layout_reducer_json` (`sidebar_session_tree`).
//!
//! A "list" is one list of the sidebar's rows (a section's loose rows or a
//! group's members); a workspace may be listed in several. Each rule that
//! reads lists takes each one as the set of the workspaces it holds; only the
//! ancestors of the row asked about matter, so a caller may pass only those.

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use unicode_normalization::UnicodeNormalization;

/// A workspace id.
pub type Id = String;

/// Child workspace to the workspace whose session started it.
pub type Parents = BTreeMap<Id, Id>;

// MARK: Pull request badge

/// Where a row's pull requests stand, as the badge's one color says it.
/// Ordered: a later status wins when several combine.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum BadgeStatus {
    /// Every one merged: purple.
    Merged,
    /// Open, and its checks pass or still run: green.
    Passing,
    /// A draft or a conflict: orange.
    Attention,
    /// A failed check: red. It wins over the others.
    Failing,
}

/// Where one pull request stands, as the hover card's pill says it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PullRequestState {
    Conflict,
    Failing,
    Passing,
    Draft,
    Merged,
    Closed,
}

impl PullRequestState {
    /// Its part in the row's badge; None for a closed one, which the badge leaves out.
    pub fn badge_status(self) -> Option<BadgeStatus> {
        match self {
            Self::Conflict | Self::Draft => Some(BadgeStatus::Attention),
            Self::Failing => Some(BadgeStatus::Failing),
            Self::Passing => Some(BadgeStatus::Passing),
            Self::Merged => Some(BadgeStatus::Merged),
            Self::Closed => None,
        }
    }
}

/// One pull request in the badge's hover card.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PullRequestItem {
    pub url: String,
    #[serde(default)]
    pub repository: String,
    #[serde(default)]
    pub number: i64,
    #[serde(default)]
    pub title: String,
    pub state: PullRequestState,
    #[serde(default)]
    pub additions: i64,
    #[serde(default)]
    pub deletions: i64,
    /// GitHub's ISO 8601 text, which sorts by time; empty when unknown.
    #[serde(default)]
    pub created_at: String,
}

/// A row's pull request badge: how many, the most urgent color, and each item newest first.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Badge {
    pub count: usize,
    pub status: BadgeStatus,
    pub items: Vec<PullRequestItem>,
}

/// One badge for several pull requests: their count, in the most urgent one's color.
pub fn combine_statuses(statuses: &[BadgeStatus]) -> Option<Badge> {
    let worst = statuses.iter().max()?;
    Some(Badge { count: statuses.len(), status: *worst, items: Vec::new() })
}

/// Swift's `String` order: by the canonical (NFC) form's scalars.
fn swift_order(a: &str, b: &str) -> std::cmp::Ordering {
    if a.is_ascii() && b.is_ascii() {
        return a.cmp(b);
    }
    a.nfc().cmp(b.nfc())
}

/// One badge for `items`: the open and merged ones' count and most urgent
/// color, and every item newest first (closed ones too); None when none is
/// open or merged and the card would be empty.
pub fn combine_items(items: &[PullRequestItem]) -> Option<Badge> {
    let statuses: Vec<BadgeStatus> =
        items.iter().filter_map(|item| item.state.badge_status()).collect();
    let mut badge = combine_statuses(&statuses)?;
    let mut sorted = items.to_vec();
    // Newest first: (createdAt, number, url) descending.
    sorted.sort_by(|a, b| {
        swift_order(&b.created_at, &a.created_at)
            .then(b.number.cmp(&a.number))
            .then_with(|| swift_order(&b.url, &a.url))
    });
    badge.items = sorted;
    Some(badge)
}

/// Decodes `%XX` escapes; None for a malformed escape or bytes that are not UTF-8
/// (`URLComponents` refuses those).
fn percent_decoded(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            let hex = bytes.get(index + 1..index + 3)?;
            let hex = std::str::from_utf8(hex).ok()?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            index += 3;
        } else {
            out.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// A pull request page the card may open: `https://github.com/<owner>/<repo>/pull/<n>`,
/// or the same on `enterprise_host` (the user's `GH_HOST`). No user, password,
/// port, query or fragment. Anything else a summary carried is never opened.
pub fn is_openable(url: &str, enterprise_host: Option<&str>) -> bool {
    let Some(rest) = url.strip_prefix("https://") else { return false };
    if url.contains(['?', '#']) || !url.is_ascii() || url.contains(char::is_whitespace) {
        return false;
    }
    let (authority, path) = match rest.find('/') {
        Some(slash) => (&rest[..slash], &rest[slash..]),
        None => (rest, ""),
    };
    if authority.contains('@') {
        return false; // a user (and maybe a password)
    }
    let host = match authority.rsplit_once(':') {
        // An empty port is no port; any other is one (or no URL at all).
        Some((host, port)) => {
            if !port.is_empty() {
                return false;
            }
            host
        }
        None => authority,
    };
    let Some(host) = percent_decoded(host) else { return false };
    let host = host.to_lowercase();
    if host.is_empty() {
        return false;
    }
    let enterprise = enterprise_host.is_some_and(|e| !e.is_empty() && host == e.to_lowercase());
    if host != "github.com" && !enterprise {
        return false;
    }
    let Some(path) = percent_decoded(path) else { return false };
    let parts: Vec<&str> = path.split('/').collect();
    let plain = |s: &str| {
        !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c))
    };
    parts.len() == 5
        && parts[0].is_empty()
        && plain(parts[1])
        && plain(parts[2])
        && parts[3] == "pull"
        && !parts[4].is_empty()
        && parts[4].chars().all(|c| c.is_ascii_digit())
}

/// `owner/repo` of a `https://<host>/owner/repo/pull/N` URL; empty for another.
pub fn repository_of(url: &str) -> String {
    let parts: Vec<&str> = url.split('/').filter(|part| !part.is_empty()).collect();
    if parts.len() < 6 || parts[0] != "https:" || parts[4] != "pull" {
        return String::new();
    }
    format!("{}/{}", parts[2], parts[3])
}

// MARK: Tree

/// The tree's lineage and folds as one list draws them.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Tree {
    pub parents: Parents,
    /// Parents whose subtree the person folded.
    pub collapsed: BTreeSet<Id>,
    /// Parents below the top level the person opened (`folds_deep` folds the others).
    pub opened: BTreeSet<Id>,
    /// A parent drawn below the top level starts folded.
    pub folds_deep: bool,
    /// Agent-started sessions stay out of the list but for those that need the person or are kept.
    pub hides_started: bool,
    /// The agent-started sessions that draw while `hides_started` hides the rest: the selected ones.
    pub keeps: BTreeSet<Id>,
}

impl Tree {
    /// Whether the parent `id`, drawn at `depth`, folds its subtree: the person
    /// folded it, or it is below the top level (`folds_deep`) and not opened.
    pub fn is_folded(&self, id: &str, depth: usize) -> bool {
        self.collapsed.contains(id) || (self.folds_deep && depth > 0 && !self.opened.contains(id))
    }

    /// The agent-started sessions `hides_started` leaves out of one list, as
    /// indices into `ids` (None: a group or an item); none while it is off.
    /// `needs_person` reads whether a row waits on the person, by index. A kept
    /// row (it needs the person, or `keeps` holds it) keeps every agent-started
    /// ancestor of it too, so it draws under them.
    pub fn hidden_started(
        &self,
        ids: &[Option<Id>],
        needs_person: impl Fn(usize) -> bool,
    ) -> BTreeSet<usize> {
        if !self.hides_started || self.parents.is_empty() {
            return BTreeSet::new();
        }
        let mut kept: BTreeSet<&str> = BTreeSet::new();
        for (index, id) in ids.iter().enumerate() {
            let Some(id) = id else { continue };
            if !self.parents.contains_key(id) || !(self.keeps.contains(id) || needs_person(index)) {
                continue;
            }
            let mut current = Some(id.as_str());
            while let Some(next) = current {
                let Some(parent) = self.parents.get(next) else { break };
                if !kept.insert(next) {
                    break;
                }
                current = Some(parent.as_str());
            }
        }
        ids.iter()
            .enumerate()
            .filter(|(_, id)| {
                id.as_ref()
                    .is_some_and(|id| self.parents.contains_key(id) && !kept.contains(id.as_str()))
            })
            .map(|(index, _)| index)
            .collect()
    }

    /// Whether a folded ancestor hides `id` (its roll-up counts it) in one of
    /// `lists`. No folds while agent-started rows hide.
    pub fn hides_in_fold(&self, id: &str, lists: &[BTreeSet<Id>]) -> bool {
        if self.hides_started || (self.collapsed.is_empty() && !self.folds_deep) {
            return false;
        }
        lists.iter().any(|list| {
            let ancestors = drawn_ancestors(&self.parents, id, |other| list.contains(other));
            // The last ancestor is the root (depth 0); each one before it is one deeper.
            let count = ancestors.len();
            ancestors
                .iter()
                .enumerate()
                .any(|(offset, parent)| self.is_folded(parent, count - 1 - offset))
        })
    }
}

/// The ancestors `id` draws under in one list, nearest first: the chain of
/// parents `in_list` holds; a parent outside the list ends it (that row is a
/// root there). A chain that runs into a cycle draws no nesting at all: empty.
pub fn drawn_ancestors(parents: &Parents, id: &str, in_list: impl Fn(&str) -> bool) -> Vec<Id> {
    let mut seen: BTreeSet<&str> = BTreeSet::from([id]);
    let mut ancestors = Vec::new();
    let mut current = id;
    while let Some(parent) = parents.get(current) {
        if !in_list(parent) {
            break;
        }
        if !seen.insert(parent.as_str()) {
            return Vec::new(); // a cycle: every row of it is a root
        }
        ancestors.push(parent.clone());
        current = parent;
    }
    ancestors
}

/// The person's folds, as the app keeps them across launches.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Folds {
    pub collapsed: BTreeSet<Id>,
    pub opened: BTreeSet<Id>,
}

impl Folds {
    /// Drops each fold that is no longer a parent in the live tree (a closed
    /// workspace, or one whose sub-sessions ended), so the saved folds never
    /// outgrow the tree; `keeping` stays (parents of subagents). Nothing is
    /// dropped before the first pass (`parents` None or empty).
    pub fn pruned(mut self, parents: Option<&Parents>, keeping: &BTreeSet<Id>) -> Self {
        if let Some(parents) = parents.filter(|parents| !parents.is_empty()) {
            let live: BTreeSet<&str> = parents
                .values()
                .map(String::as_str)
                .chain(keeping.iter().map(String::as_str))
                .collect();
            self.collapsed.retain(|id| live.contains(id.as_str()));
            self.opened.retain(|id| live.contains(id.as_str()));
        }
        self
    }

    /// Folds or opens the subtree under `id`, then prunes. `folded`: whether
    /// its row draws it folded now (a parent below the top level starts
    /// folded); None reads the person's own fold.
    pub fn toggled(
        mut self,
        id: &str,
        folded: Option<bool>,
        parents: Option<&Parents>,
        keeping: &BTreeSet<Id>,
    ) -> Self {
        if folded.unwrap_or_else(|| self.collapsed.contains(id)) {
            self.collapsed.remove(id);
            self.opened.insert(id.to_owned());
        } else {
            self.collapsed.insert(id.to_owned());
            self.opened.remove(id);
        }
        self.pruned(parents, keeping)
    }

    /// Opens every fold above `id` in each of `lists`: only the parents it
    /// draws under there, so a parent in another list, or a cycle, opens
    /// nothing. None when nothing changes (no tree, or every fold already open).
    /// Never prunes (it runs for the restored selection while lanes load).
    pub fn revealed(&self, id: &str, parents: &Parents, lists: &[BTreeSet<Id>]) -> Option<Self> {
        let mut next = self.clone();
        for list in lists {
            let ancestors = drawn_ancestors(parents, id, |other| list.contains(other));
            let count = ancestors.len();
            for (n, parent) in ancestors.into_iter().enumerate() {
                next.collapsed.remove(&parent);
                if n < count - 1 {
                    next.opened.insert(parent); // a parent below the top level
                }
            }
        }
        (next != *self).then_some(next)
    }
}

// MARK: Wire

/// One `sidebar_session_tree` request: `op` names the rule.
#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Request {
    /// `{count, status, items}` or null.
    Badge { items: Vec<PullRequestItem> },
    /// `{count, status, items: []}` or null.
    BadgeStatuses { statuses: Vec<BadgeStatus> },
    /// `{openable}`.
    Openable {
        url: String,
        #[serde(default, rename = "enterpriseHost")]
        enterprise_host: Option<String>,
    },
    /// `{repository}`.
    Repository { url: String },
    /// `{hidden: [index]}`.
    HiddenStarted {
        #[serde(flatten)]
        tree: Tree,
        ids: Vec<Option<Id>>,
        /// Whether each row of `ids` waits on the person.
        #[serde(default, rename = "needsPerson")]
        needs_person: Vec<bool>,
    },
    /// `{ancestors: [id]}`.
    DrawnAncestors {
        #[serde(default)]
        parents: Parents,
        id: Id,
        list: BTreeSet<Id>,
    },
    /// `{folded}`.
    IsFolded {
        #[serde(flatten)]
        tree: Tree,
        id: Id,
        depth: usize,
    },
    /// `{hides}`.
    HidesInFold {
        #[serde(flatten)]
        tree: Tree,
        id: Id,
        lists: Vec<BTreeSet<Id>>,
    },
    /// `{collapsed, opened}`.
    Toggle {
        #[serde(flatten)]
        folds: Folds,
        id: Id,
        #[serde(default)]
        folded: Option<bool>,
        /// The live tree's parents; null before the first pass.
        #[serde(default)]
        parents: Option<Parents>,
        #[serde(default)]
        keeping: BTreeSet<Id>,
    },
    /// `{collapsed, opened}` or null (nothing changes).
    Reveal {
        #[serde(flatten)]
        folds: Folds,
        id: Id,
        #[serde(default)]
        parents: Parents,
        lists: Vec<BTreeSet<Id>>,
    },
    /// `{collapsed, opened}`.
    Prune {
        #[serde(flatten)]
        folds: Folds,
        #[serde(default)]
        parents: Option<Parents>,
        #[serde(default)]
        keeping: BTreeSet<Id>,
    },
}

/// Answers one request.
pub fn respond(request: Request) -> serde_json::Value {
    use serde_json::json;
    match request {
        Request::Badge { items } => json!(combine_items(&items)),
        Request::BadgeStatuses { statuses } => json!(combine_statuses(&statuses)),
        Request::Openable { url, enterprise_host } => {
            json!({ "openable": is_openable(&url, enterprise_host.as_deref()) })
        }
        Request::Repository { url } => json!({ "repository": repository_of(&url) }),
        Request::HiddenStarted { tree, ids, needs_person } => {
            let hidden = tree
                .hidden_started(&ids, |index| needs_person.get(index).copied().unwrap_or(false));
            json!({ "hidden": hidden })
        }
        Request::DrawnAncestors { parents, id, list } => {
            json!({ "ancestors": drawn_ancestors(&parents, &id, |other| list.contains(other)) })
        }
        Request::IsFolded { tree, id, depth } => json!({ "folded": tree.is_folded(&id, depth) }),
        Request::HidesInFold { tree, id, lists } => {
            json!({ "hides": tree.hides_in_fold(&id, &lists) })
        }
        Request::Toggle { folds, id, folded, parents, keeping } => {
            json!(folds.toggled(&id, folded, parents.as_ref(), &keeping))
        }
        Request::Reveal { folds, id, parents, lists } => {
            json!(folds.revealed(&id, &parents, &lists))
        }
        Request::Prune { folds, parents, keeping } => {
            json!(folds.pruned(parents.as_ref(), &keeping))
        }
    }
}

#[cfg(test)]
#[path = "sidebar_session_tree_tests.rs"]
mod tests;
