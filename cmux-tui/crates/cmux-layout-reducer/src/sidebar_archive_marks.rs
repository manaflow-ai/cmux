//! What auto-archive and the bulk archive rows read off the sidebar document's records, moved from
//! Swift's `AutoArchiveCoordinator` (`groups(of:in:)`, `archivableItems`, `archivedWorkspaces`, the
//! candidate marks `plan` sets) and `SidebarDocRecords` (`isArchived`, `isPinned`,
//! `isPinned(group:)`). The planner itself is [`crate::auto_archive`]; the ledger, the clock and the
//! sends stay the coordinator's.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet};

/// The document's Pinned section (`SidebarDocStore.pinnedSection`).
pub const PINNED_SECTION: &str = "sec_pinned";
/// How deep `groups_of` walks: the document's nesting limit, and a stop for a cycle.
pub const MAX_DEPTH: usize = 16;

/// The fields of an item record these rules read.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Record {
    #[serde(default)]
    pub section: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<String>,
    #[serde(default)]
    pub archived: bool,
    #[serde(default)]
    pub pinned_in_group: bool,
    /// A group item.
    #[serde(default)]
    pub group: bool,
    /// A group's `autoArchive` rule as the planner takes it (`"never"` or whole hours).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auto_archive: Option<Value>,
}

pub type Records = BTreeMap<String, Record>;

/// The item is archived by itself.
pub fn is_archived(records: &Records, id: &str) -> bool {
    records.get(id).is_some_and(|item| item.archived)
}

/// Pinned in its group, or a top-level row of Pinned.
pub fn is_pinned(records: &Records, id: &str) -> bool {
    records.get(id).is_some_and(|item| {
        item.pinned_in_group || (item.parent.is_none() && item.section == PINNED_SECTION)
    })
}

/// A group of the Pinned section.
pub fn is_pinned_group(records: &Records, id: &str) -> bool {
    records.get(id).is_some_and(|item| item.group && item.section == PINNED_SECTION)
}

/// The group items above `item`, nearest first, at most [`MAX_DEPTH`], stopping at a repeat.
pub fn groups_of(records: &Records, item: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut parent = records.get(item).and_then(|item| item.parent.clone());
    while let Some(id) = parent {
        if out.len() >= MAX_DEPTH || out.contains(&id) {
            break;
        }
        parent = records.get(&id).and_then(|item| item.parent.clone());
        out.push(id);
    }
    out
}

/// Archived by itself or under an archived group.
pub fn is_archived_or_under(records: &Records, item: &str) -> bool {
    is_archived(records, item) || groups_of(records, item).iter().any(|g| is_archived(records, g))
}

/// The items (each named workspace's, `None` when it has none) that Archive Other Workspaces,
/// Above or Below archive, in order, once each: placed, not pinned, not archived (nor under an
/// archived group).
pub fn archivable(records: &Records, items: &[Option<String>]) -> Vec<String> {
    let mut seen = BTreeSet::new();
    items
        .iter()
        .flatten()
        .filter(|item| {
            records.contains_key(*item)
                && seen.insert((*item).clone())
                && !is_pinned(records, item)
                && !is_archived(records, item)
                && !groups_of(records, item).iter().any(|g| is_archived(records, g))
        })
        .cloned()
        .collect()
}

/// A candidate's marks as the host sends them.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Candidate {
    pub item: String,
    pub workspace: String,
    #[serde(default)]
    pub shown: bool,
    #[serde(default)]
    pub archived: bool,
    #[serde(default)]
    pub pinned: bool,
}

/// A candidate's marks with the document's and the windows' laid over.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Marked {
    pub shown: bool,
    pub archived: bool,
    pub pinned: bool,
    pub groups: Vec<String>,
}

/// The marks `plan` gives each candidate: shown in a window, archived or pinned in the document,
/// and its groups, nearest first.
pub fn marks(records: &Records, candidates: &[Candidate], shown: &BTreeSet<String>) -> Vec<Marked> {
    candidates
        .iter()
        .map(|candidate| Marked {
            shown: candidate.shown || shown.contains(&candidate.workspace),
            archived: candidate.archived || is_archived(records, &candidate.item),
            pinned: candidate.pinned || is_pinned(records, &candidate.item),
            groups: groups_of(records, &candidate.item),
        })
        .collect()
}

/// Every group's auto-archive rule, by item.
pub fn rules(records: &Records) -> BTreeMap<String, Value> {
    records
        .iter()
        .filter(|(_, item)| item.group)
        .filter_map(|(id, item)| item.auto_archive.clone().map(|rule| (id.clone(), rule)))
        .collect()
}

/// A candidate of the Archived page: its item, and its last use and last sight (seconds).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Used {
    pub item: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_active: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seen: Option<f64>,
}

/// One row of the Archived page: the candidate's index and its last use, the later of the two.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ArchivedRow {
    pub index: usize,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_active: Option<f64>,
}

/// The Archived page's rows: every candidate archived by itself or under an archived group, last
/// used first (never used last; ties keep the host's order).
pub fn archived(records: &Records, candidates: &[Used]) -> Vec<ArchivedRow> {
    let mut rows: Vec<ArchivedRow> = candidates
        .iter()
        .enumerate()
        .filter(|(_, candidate)| is_archived_or_under(records, &candidate.item))
        .map(|(index, candidate)| ArchivedRow {
            index,
            last_active: match (candidate.last_active, candidate.seen) {
                (Some(a), Some(b)) => Some(a.max(b)),
                (a, b) => a.or(b),
            },
        })
        .collect();
    let key = |row: &ArchivedRow| row.last_active.unwrap_or(f64::NEG_INFINITY);
    rows.sort_by(|a, b| key(b).partial_cmp(&key(a)).unwrap_or(Ordering::Equal));
    rows
}

/// A request to the `sidebar_archive_marks` FFI op. Every one carries the records.
#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Request {
    /// `{archivable}`.
    Archivable {
        #[serde(default)]
        records: Records,
        items: Vec<Option<String>>,
    },
    /// `{marks, rules}`.
    Marks {
        #[serde(default)]
        records: Records,
        candidates: Vec<Candidate>,
        #[serde(default)]
        shown: BTreeSet<String>,
    },
    /// `{rows}`.
    Archived {
        #[serde(default)]
        records: Records,
        candidates: Vec<Used>,
    },
    /// `{archived, pinned, pinned_group, groups}` of one item.
    Item {
        #[serde(default)]
        records: Records,
        id: String,
    },
}

/// The answer to one request.
pub fn respond(request: Request) -> Value {
    match request {
        Request::Archivable { records, items } => {
            json!({"archivable": archivable(&records, &items)})
        }
        Request::Marks { records, candidates, shown } => {
            json!({"marks": marks(&records, &candidates, &shown), "rules": rules(&records)})
        }
        Request::Archived { records, candidates } => {
            json!({"rows": archived(&records, &candidates)})
        }
        Request::Item { records, id } => json!({
            "archived": is_archived(&records, &id),
            "pinned": is_pinned(&records, &id),
            "pinned_group": is_pinned_group(&records, &id),
            "groups": groups_of(&records, &id),
        }),
    }
}

#[cfg(test)]
#[path = "sidebar_archive_marks_tests.rs"]
mod tests;
