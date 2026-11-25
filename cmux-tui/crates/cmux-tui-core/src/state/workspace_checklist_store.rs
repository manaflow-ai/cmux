//! Per-workspace checklists (`workspace-checklist-v1`): ordered items with
//! text, a state (todo, in progress, done), who created them, and image
//! attachments named by absolute path. Rows are shared state of the
//! workspace's home session, keyed by the public workspace id, and removed
//! when the workspace closes. The tables are additive: an older binary that
//! opens the store ignores them.

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// Items one workspace may hold.
pub(crate) const MAX_CHECKLIST_ITEMS: usize = 50;
/// Longest accepted item text, in characters, after trimming.
pub(crate) const MAX_ITEM_TEXT_CHARS: usize = 500;
/// Attachments one item may hold.
pub(crate) const MAX_ITEM_ATTACHMENTS: usize = 20;
/// Longest accepted attachment path, in bytes.
pub(crate) const MAX_ATTACHMENT_PATH_BYTES: usize = 4096;
/// Longest accepted attachment display name, in characters.
pub(crate) const MAX_ATTACHMENT_NAME_CHARS: usize = 256;

/// The states of an item, in the order a click cycles through them.
pub(crate) const ITEM_STATES: [&str; 3] = ["todo", "in_progress", "done"];
/// Who created an item.
pub(crate) const ITEM_ORIGINS: [&str; 2] = ["user", "agent"];

fn bad_request(message: impl Into<String>) -> anyhow::Error {
    anyhow::anyhow!("bad request: {}", message.into())
}

pub(crate) fn create_checklist_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS workspace_checklist_items (
           workspace_id TEXT NOT NULL,
           item_id TEXT NOT NULL,
           text TEXT NOT NULL,
           state TEXT NOT NULL CHECK(state IN ('todo','in_progress','done')),
           origin TEXT NOT NULL CHECK(origin IN ('user','agent')),
           attachments_json TEXT NOT NULL DEFAULT '[]',
           position INTEGER NOT NULL,
           created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
           updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0),
           PRIMARY KEY(workspace_id, item_id)
         );",
    )?;
    Ok(())
}

/// One image attached to an item, named by an absolute file path.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct ChecklistAttachment {
    pub(crate) id: String,
    pub(crate) path: String,
    pub(crate) name: String,
}

/// An attachment as a request names it: a kept one carries its id.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct ChecklistAttachmentInput {
    #[serde(default)]
    pub(crate) id: Option<String>,
    pub(crate) path: String,
    #[serde(default)]
    pub(crate) name: Option<String>,
}

/// The trimmed text, or a refusal of an empty, too long or control-character text.
pub(crate) fn normalized_text(text: &str) -> anyhow::Result<String> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Err(bad_request("checklist item text cannot be empty"));
    }
    if trimmed.chars().count() > MAX_ITEM_TEXT_CHARS {
        return Err(bad_request(format!(
            "checklist item text exceeds {MAX_ITEM_TEXT_CHARS} characters"
        )));
    }
    if trimmed.chars().any(|ch| ch.is_control() && ch != '\t' && ch != '\n') {
        return Err(bad_request("checklist item text contains a control character"));
    }
    Ok(trimmed.to_string())
}

fn validate_state(state: &str) -> anyhow::Result<()> {
    if !ITEM_STATES.contains(&state) {
        return Err(bad_request(format!("state must be one of {}", ITEM_STATES.join(", "))));
    }
    Ok(())
}

fn validate_origin(origin: &str) -> anyhow::Result<()> {
    if !ITEM_ORIGINS.contains(&origin) {
        return Err(bad_request(format!("origin must be one of {}", ITEM_ORIGINS.join(", "))));
    }
    Ok(())
}

fn new_id(prefix: &str) -> String {
    format!("{prefix}_{}", crate::workspace_registry::new_uuid_v4().replace('-', ""))
}

/// The attachments `inputs` name: a kept id stays, a new one gets an id, and a
/// missing name is the path's file name.
pub(crate) fn resolve_attachments(
    inputs: &[ChecklistAttachmentInput],
) -> anyhow::Result<Vec<ChecklistAttachment>> {
    if inputs.len() > MAX_ITEM_ATTACHMENTS {
        return Err(bad_request(format!(
            "a checklist item holds at most {MAX_ITEM_ATTACHMENTS} attachments"
        )));
    }
    let mut seen = std::collections::HashSet::new();
    inputs
        .iter()
        .map(|input| {
            let path = input.path.trim();
            if !path.starts_with('/') {
                return Err(bad_request("attachment path must be absolute"));
            }
            if path.len() > MAX_ATTACHMENT_PATH_BYTES || path.chars().any(char::is_control) {
                return Err(bad_request("attachment path is too long or has a control character"));
            }
            let fallback = path.rsplit('/').next().filter(|name| !name.is_empty()).unwrap_or(path);
            let name = input
                .name
                .as_deref()
                .map(str::trim)
                .filter(|name| !name.is_empty())
                .unwrap_or(fallback);
            if name.chars().count() > MAX_ATTACHMENT_NAME_CHARS
                || name.chars().any(char::is_control)
            {
                return Err(bad_request("attachment name is too long or has a control character"));
            }
            let id = match &input.id {
                Some(id) if is_attachment_id(id) => id.clone(),
                Some(_) => return Err(bad_request("attachment id must be att_ and 32 hex digits")),
                None => new_id("att"),
            };
            if !seen.insert(id.clone()) {
                return Err(bad_request("an attachment id is listed twice"));
            }
            Ok(ChecklistAttachment { id, path: path.to_string(), name: name.to_string() })
        })
        .collect()
}

fn is_attachment_id(id: &str) -> bool {
    id.strip_prefix("att_")
        .is_some_and(|hex| hex.len() == 32 && hex.bytes().all(|byte| byte.is_ascii_hexdigit()))
}

fn item_ids(transaction: &Connection, workspace_id: &str) -> anyhow::Result<Vec<String>> {
    let mut statement = transaction.prepare(
        "SELECT item_id FROM workspace_checklist_items WHERE workspace_id = ?1
         ORDER BY position ASC, created_at_ms ASC, item_id ASC",
    )?;
    let ids =
        statement.query_map([workspace_id], |row| row.get(0))?.collect::<Result<Vec<_>, _>>()?;
    Ok(ids)
}

/// Rewrite every position of the workspace's items as `order` lists them.
fn write_order(
    transaction: &Transaction<'_>,
    workspace_id: &str,
    order: &[String],
) -> anyhow::Result<()> {
    for (position, id) in order.iter().enumerate() {
        transaction.execute(
            "UPDATE workspace_checklist_items SET position = ?3
             WHERE workspace_id = ?1 AND item_id = ?2",
            params![workspace_id, id, i64::try_from(position)?],
        )?;
    }
    Ok(())
}

/// Move `id` to `index` (clamped) in the workspace's order.
fn place(
    transaction: &Transaction<'_>,
    workspace_id: &str,
    id: &str,
    index: Option<usize>,
) -> anyhow::Result<()> {
    let mut order = item_ids(transaction, workspace_id)?;
    order.retain(|other| other != id);
    let index = index.unwrap_or(order.len()).min(order.len());
    order.insert(index, id.to_string());
    write_order(transaction, workspace_id, &order)
}

/// Add one item at `index` (default: last) and return its id.
pub(crate) fn add_item(
    transaction: &Transaction<'_>,
    workspace_id: &str,
    text: &str,
    state: Option<&str>,
    origin: &str,
    index: Option<usize>,
    now_ms: u64,
) -> anyhow::Result<String> {
    let text = normalized_text(text)?;
    let state = state.unwrap_or("todo");
    validate_state(state)?;
    validate_origin(origin)?;
    let count = item_ids(transaction, workspace_id)?.len();
    if count >= MAX_CHECKLIST_ITEMS {
        return Err(bad_request(format!(
            "a workspace checklist holds at most {MAX_CHECKLIST_ITEMS} items"
        )));
    }
    let id = new_id("chk");
    let now = i64::try_from(now_ms)?;
    transaction.execute(
        "INSERT INTO workspace_checklist_items(
           workspace_id, item_id, text, state, origin, attachments_json, position,
           created_at_ms, updated_at_ms
         ) VALUES(?1, ?2, ?3, ?4, ?5, '[]', ?6, ?7, ?7)",
        params![workspace_id, id, text, state, origin, i64::try_from(count)?, now],
    )?;
    place(transaction, workspace_id, &id, index)?;
    Ok(id)
}

/// What one update changes; `None` keeps a field.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub(crate) struct ChecklistItemUpdate {
    pub(crate) text: Option<String>,
    pub(crate) state: Option<String>,
    pub(crate) index: Option<usize>,
    pub(crate) attachments: Option<Vec<ChecklistAttachmentInput>>,
}

impl ChecklistItemUpdate {
    pub(crate) fn is_empty(&self) -> bool {
        self.text.is_none()
            && self.state.is_none()
            && self.index.is_none()
            && self.attachments.is_none()
    }
}

fn require_item(transaction: &Connection, workspace_id: &str, item: &str) -> anyhow::Result<()> {
    let exists = transaction
        .query_row(
            "SELECT 1 FROM workspace_checklist_items WHERE workspace_id = ?1 AND item_id = ?2",
            params![workspace_id, item],
            |_| Ok(()),
        )
        .optional()?
        .is_some();
    if !exists {
        return Err(bad_request(format!("unknown checklist item {item}")));
    }
    Ok(())
}

/// Apply `update` to one item.
pub(crate) fn update_item(
    transaction: &Transaction<'_>,
    workspace_id: &str,
    item: &str,
    update: &ChecklistItemUpdate,
    now_ms: u64,
) -> anyhow::Result<()> {
    if update.is_empty() {
        return Err(bad_request("update names no field (text, state, index, attachments)"));
    }
    require_item(transaction, workspace_id, item)?;
    let now = i64::try_from(now_ms)?;
    if let Some(text) = &update.text {
        let text = normalized_text(text)?;
        transaction.execute(
            "UPDATE workspace_checklist_items SET text = ?3, updated_at_ms = ?4
             WHERE workspace_id = ?1 AND item_id = ?2",
            params![workspace_id, item, text, now],
        )?;
    }
    if let Some(state) = &update.state {
        validate_state(state)?;
        transaction.execute(
            "UPDATE workspace_checklist_items SET state = ?3, updated_at_ms = ?4
             WHERE workspace_id = ?1 AND item_id = ?2",
            params![workspace_id, item, state, now],
        )?;
    }
    if let Some(inputs) = &update.attachments {
        let attachments = resolve_attachments(inputs)?;
        transaction.execute(
            "UPDATE workspace_checklist_items SET attachments_json = ?3, updated_at_ms = ?4
             WHERE workspace_id = ?1 AND item_id = ?2",
            params![workspace_id, item, serde_json::to_string(&attachments)?, now],
        )?;
    }
    if let Some(index) = update.index {
        place(transaction, workspace_id, item, Some(index))?;
    }
    Ok(())
}

/// Remove one item.
pub(crate) fn remove_item(
    transaction: &Transaction<'_>,
    workspace_id: &str,
    item: &str,
) -> anyhow::Result<()> {
    require_item(transaction, workspace_id, item)?;
    transaction.execute(
        "DELETE FROM workspace_checklist_items WHERE workspace_id = ?1 AND item_id = ?2",
        params![workspace_id, item],
    )?;
    let order = item_ids(transaction, workspace_id)?;
    write_order(transaction, workspace_id, &order)
}

/// Remove every item of a workspace that closed; true when it had any.
pub(crate) fn forget_workspace(
    transaction: &Transaction<'_>,
    workspace_id: &str,
) -> anyhow::Result<bool> {
    let removed = transaction
        .execute("DELETE FROM workspace_checklist_items WHERE workspace_id = ?1", [workspace_id])?;
    Ok(removed > 0)
}

/// The `WorkspaceChecklist` of one workspace.
pub(crate) fn checklist_snapshot(
    connection: &Connection,
    workspace_id: &str,
) -> anyhow::Result<Value> {
    let mut statement = connection.prepare(
        "SELECT item_id, text, state, origin, attachments_json, created_at_ms, updated_at_ms
         FROM workspace_checklist_items WHERE workspace_id = ?1
         ORDER BY position ASC, created_at_ms ASC, item_id ASC",
    )?;
    let rows = statement
        .query_map([workspace_id], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, i64>(5)?,
                row.get::<_, i64>(6)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    let items = rows
        .into_iter()
        .map(|(id, text, state, origin, attachments, created, updated)| {
            // A row another build wrote with a bad list shows no attachments.
            let attachments: Vec<ChecklistAttachment> =
                serde_json::from_str(&attachments).unwrap_or_default();
            json!({
                "id": id,
                "text": text,
                "state": state,
                "origin": origin,
                "attachments": attachments,
                "created_at_ms": created.to_string(),
                "updated_at_ms": updated.to_string(),
            })
        })
        .collect::<Vec<_>>();
    Ok(json!({"workspace_id": workspace_id, "items": items}))
}

/// Checklists of every live workspace that has items, in workspace order.
pub(crate) fn checklist_snapshots(connection: &Connection) -> anyhow::Result<Vec<Value>> {
    let ids = {
        let mut statement = connection.prepare(
            "SELECT rw.public_id FROM resource_workspaces AS rw
             JOIN workspaces AS w ON w.workspace_key = rw.workspace_key
             WHERE rw.deleted_revision IS NULL AND w.tombstoned = 0
               AND EXISTS(SELECT 1 FROM workspace_checklist_items AS c
                          WHERE c.workspace_id = rw.public_id)
             ORDER BY w.position ASC",
        )?;
        statement.query_map([], |row| row.get::<_, String>(0))?.collect::<Result<Vec<_>, _>>()?
    };
    ids.iter().map(|id| checklist_snapshot(connection, id)).collect()
}
