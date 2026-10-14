//! The TUI's read model of the daemon's sidebar document (`sidebar-doc-v1`).
//!
//! The daemon owns one document of ordered sections that hold ordered items
//! (plans: the sidebar rewrite, CONTRACT.md "Wire"). A frontend reads it with
//! `sidebar.get`, then follows the `sidebar_item` / `sidebar_section` /
//! `sidebar_doc` changes of each `session.events` batch. A batch whose
//! `previous_revision` is not the held revision is a gap: the frontend
//! refetches. Every write is a daemon op (`sidebar.move`, `sidebar.pin`,
//! `sidebar.unpin`); this model never changes on its own.
//!
//! The TUI draws one flat workspace list, so it reads only the display order
//! of the workspaces the document places: sections in region and key order
//! (Pinned is a top-region section, so its items come first), items in key
//! order, a group's members right after the group. This is the same order
//! as the reducer's `Doc::normalize`.

use std::collections::HashMap;

use serde_json::Value;

/// Daemon capability: the sidebar document and its `sidebar.*` ops.
pub(crate) const SIDEBAR_DOC_CAPABILITY: &str = "sidebar-doc-v1";
pub(crate) const PINNED_SECTION_ID: &str = "sec_pinned";
const ITEM_RESOURCE: &str = "sidebar_item";
const SECTION_RESOURCE: &str = "sidebar_section";
const DOC_RESOURCE: &str = "sidebar_doc";

#[derive(Debug, Clone)]
struct SectionRow {
    region: u8,
    order: String,
}

#[derive(Debug, Clone)]
pub(crate) struct ItemRow {
    pub id: String,
    pub section: String,
    pub parent: Option<String>,
    order: String,
    /// The workspace public id of a workspace item.
    workspace: Option<String>,
}

/// What one `session.events` batch did to the model.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum BatchOutcome {
    /// No sidebar change, or one the model already holds.
    Unchanged,
    /// The model applied the change.
    Changed,
    /// A gap or a model that is not loaded: refetch with `sidebar.get`.
    Stale,
}

#[derive(Debug, Default)]
pub(crate) struct SidebarDocModel {
    revision: Option<u64>,
    sections: HashMap<String, SectionRow>,
    items: HashMap<String, ItemRow>,
}

fn decimal(value: &Value) -> Option<u64> {
    match value {
        Value::String(text) => text.parse().ok(),
        Value::Number(number) => number.as_u64(),
        _ => None,
    }
}

fn region_rank(value: Option<&Value>) -> u8 {
    match value.and_then(Value::as_str).unwrap_or("middle") {
        "top" => 0,
        "middle" => 1,
        "bottom" => 2,
        _ => 3,
    }
}

fn parse_section(value: &Value) -> Option<(String, SectionRow)> {
    let id = value.get("id")?.as_str()?.to_string();
    let row = SectionRow {
        region: region_rank(value.get("region")),
        order: value.get("order").and_then(Value::as_str).unwrap_or_default().to_string(),
    };
    Some((id, row))
}

fn parse_item(value: &Value) -> Option<ItemRow> {
    let body = value.get("body");
    let workspace = (body.and_then(|body| body.get("type")).and_then(Value::as_str)
        == Some("workspace"))
    .then(|| {
        body.and_then(|body| body.get("ref"))
            .and_then(|reference| reference.get("workspace_id"))
            .and_then(Value::as_str)
            .map(str::to_string)
    })
    .flatten();
    Some(ItemRow {
        id: value.get("id")?.as_str()?.to_string(),
        section: value.get("section")?.as_str()?.to_string(),
        parent: value.get("parent").and_then(Value::as_str).map(str::to_string),
        order: value.get("order").and_then(Value::as_str).unwrap_or_default().to_string(),
        workspace,
    })
}

impl SidebarDocModel {
    pub(crate) fn is_loaded(&self) -> bool {
        self.revision.is_some()
    }

    /// Install a `sidebar.get` result; true when it is a new revision. The
    /// held revision again, or an older one (a refetch that raced a newer
    /// batch), is dropped.
    pub(crate) fn load(&mut self, doc: &Value) -> anyhow::Result<bool> {
        let revision = doc
            .get("revision")
            .and_then(decimal)
            .ok_or_else(|| anyhow::anyhow!("sidebar.get answered without a revision"))?;
        if self.revision.is_some_and(|held| held >= revision) {
            return Ok(false);
        }
        let sections = doc
            .get("sections")
            .and_then(Value::as_array)
            .map(|sections| sections.iter().filter_map(parse_section).collect())
            .unwrap_or_default();
        let items = doc
            .get("items")
            .and_then(Value::as_array)
            .map(|items| {
                items.iter().filter_map(parse_item).map(|item| (item.id.clone(), item)).collect()
            })
            .unwrap_or_default();
        self.revision = Some(revision);
        self.sections = sections;
        self.items = items;
        Ok(true)
    }

    /// Apply the sidebar changes of one `session.events` delta batch.
    pub(crate) fn apply_batch(&mut self, changes: &[Value]) -> BatchOutcome {
        let sidebar = changes
            .iter()
            .filter(|change| {
                matches!(
                    change.get("resource").and_then(Value::as_str),
                    Some(ITEM_RESOURCE | SECTION_RESOURCE | DOC_RESOURCE)
                )
            })
            .collect::<Vec<_>>();
        if sidebar.is_empty() {
            return BatchOutcome::Unchanged;
        }
        let Some(held) = self.revision else { return BatchOutcome::Stale };
        // One batch can carry several revisions (an old write folded in
        // before the op): it spans the lowest previous to the highest.
        let mut span: Option<(u64, u64)> = None;
        for marker in sidebar
            .iter()
            .filter(|change| change.get("resource").and_then(Value::as_str) == Some(DOC_RESOURCE))
            .filter_map(|change| change.get("value"))
        {
            let (Some(revision), Some(previous)) = (
                marker.get("revision").and_then(decimal),
                marker.get("previous_revision").and_then(decimal),
            ) else {
                return BatchOutcome::Stale;
            };
            span = Some(match span {
                Some((low, high)) => (low.min(previous), high.max(revision)),
                None => (previous, revision),
            });
        }
        // Item rows without the revision marker cannot be placed in the
        // revision order: read the whole document again.
        let Some((previous, revision)) = span else { return BatchOutcome::Stale };
        if revision <= held {
            return BatchOutcome::Unchanged;
        }
        if previous != held {
            return BatchOutcome::Stale;
        }
        for change in sidebar {
            let resource = change.get("resource").and_then(Value::as_str);
            let id = change.get("id").and_then(Value::as_str).unwrap_or_default();
            match (change.get("kind").and_then(Value::as_str), resource) {
                (Some("state_upsert"), Some(ITEM_RESOURCE)) => {
                    if let Some(item) = change.get("value").and_then(parse_item) {
                        self.items.insert(item.id.clone(), item);
                    }
                }
                (Some("state_delete"), Some(ITEM_RESOURCE)) => {
                    self.items.remove(id);
                }
                (Some("state_upsert"), Some(SECTION_RESOURCE)) => {
                    if let Some((id, section)) = change.get("value").and_then(parse_section) {
                        self.sections.insert(id, section);
                    }
                }
                (Some("state_delete"), Some(SECTION_RESOURCE)) => {
                    self.sections.remove(id);
                }
                _ => {}
            }
        }
        self.revision = Some(revision);
        BatchOutcome::Changed
    }

    /// The display rank of each workspace the document places, keyed by
    /// workspace public id.
    pub(crate) fn workspace_ranks(&self) -> HashMap<String, usize> {
        if !self.is_loaded() {
            return HashMap::new();
        }
        let section_rank = |id: &str| -> (u8, String) {
            self.sections
                .get(id)
                .map(|section| (section.region, section.order.clone()))
                .unwrap_or((u8::MAX, String::new()))
        };
        let mut items = self.items.values().collect::<Vec<_>>();
        items.sort_by_cached_key(|item| {
            let (top, group) = match item.parent.as_deref() {
                Some(parent) => (
                    self.items.get(parent).map(|group| group.order.clone()).unwrap_or_default(),
                    parent.to_string(),
                ),
                None => (item.order.clone(), item.id.clone()),
            };
            let (region, section_order) = section_rank(&item.section);
            (
                region,
                section_order,
                item.section.clone(),
                top,
                group,
                usize::from(item.parent.is_some()),
                item.order.clone(),
                item.id.clone(),
            )
        });
        items
            .into_iter()
            .filter_map(|item| item.workspace.clone())
            .enumerate()
            .map(|(rank, workspace)| (workspace, rank))
            .collect()
    }

    /// The item that places workspace `workspace_id`.
    pub(crate) fn workspace_item(&self, workspace_id: &str) -> Option<&ItemRow> {
        self.items.values().find(|item| item.workspace.as_deref() == Some(workspace_id))
    }
}
