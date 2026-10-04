//! `conversation-tabs-v1`: the store record of a conversation tab
//! (plans/cmux-next/home.md section 7).
//!
//! A conversation tab reuses the frontend-rendered tab plumbing: a browser
//! surface with no CDP target and a `frontend_browser_tabs` row (engine
//! `webkit`, URL `about:blank`). The row here names the conversation and its
//! owner and is written in the same commit as that frontend row. The store
//! never reads conversation content. On the wire the tab's canonical
//! `content_kind` is `conversation` with `extra.conversation`; a connection
//! that did not negotiate `conversation-tabs-v1` sees `browser`
//! (server/conversation_tabs_wire.rs). Browser operations refuse the tab.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde::Serialize;
use serde_json::{Value, json};

pub(crate) const CONVERSATION_TABS_CAPABILITY: &str = "conversation-tabs-v1";
/// The canonical `content_kind` (v2) and raw tab `kind` of a conversation tab.
pub(crate) const CONVERSATION_KIND: &str = "conversation";
/// The frontend record of a conversation tab: no page is loaded.
pub(crate) const CONVERSATION_TAB_URL: &str = "about:blank";
pub(crate) const CONVERSATION_TAB_ENGINE: &str = "webkit";

/// Set once any conversation tab exists in this process, so the outbound
/// downgrade scans messages only when there can be something to downgrade.
static CONVERSATION_TABS_PRESENT: AtomicBool = AtomicBool::new(false);

pub(crate) fn conversation_tabs_present() -> bool {
    CONVERSATION_TABS_PRESENT.load(Ordering::Acquire)
}

pub(crate) fn mark_conversation_tabs_present() {
    CONVERSATION_TABS_PRESENT.store(true, Ordering::Release);
}

pub(crate) fn create_conversation_tabs_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS conversation_tabs (
           browser_id TEXT PRIMARY KEY NOT NULL,
           conversation TEXT NOT NULL,
           owner TEXT NOT NULL CHECK(owner IN ('local','cloud')),
           origin TEXT,
           mutation_id TEXT
         );
         CREATE UNIQUE INDEX IF NOT EXISTS conversation_tabs_by_mutation
           ON conversation_tabs(origin, mutation_id) WHERE mutation_id IS NOT NULL;",
    )?;
    Ok(())
}

/// What a conversation tab shows: a conversation of the local or the cloud
/// conversation owner.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ConversationTabRecord {
    pub conversation: String,
    pub owner: String,
}

impl ConversationTabRecord {
    pub(crate) fn validate(&self) -> anyhow::Result<()> {
        anyhow::ensure!(
            self.conversation.starts_with("conv_")
                && self.conversation.len() <= 64
                && self
                    .conversation
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_'),
            "bad request: conversation must be a conv_ id of at most 64 letters, digits or '_'"
        );
        anyhow::ensure!(
            matches!(self.owner.as_str(), "local" | "cloud"),
            "bad request: owner must be \"local\" or \"cloud\""
        );
        Ok(())
    }

    pub(crate) fn wire(&self) -> Value {
        json!({"conversation": self.conversation, "owner": self.owner})
    }
}

/// Write the record of browser `browser_id` (in the frontend row's commit).
pub(crate) fn write_conversation_tab(
    transaction: &Transaction<'_>,
    browser_id: &str,
    record: &ConversationTabRecord,
    mutation: Option<(&str, &str)>,
) -> anyhow::Result<()> {
    record.validate()?;
    transaction.execute(
        "INSERT INTO conversation_tabs(browser_id, conversation, owner, origin, mutation_id)
         VALUES(?1, ?2, ?3, ?4, ?5)",
        params![
            browser_id,
            record.conversation,
            record.owner,
            mutation.map(|(origin, _)| origin),
            mutation.map(|(_, id)| id),
        ],
    )?;
    Ok(())
}

impl crate::workspace_registry::WorkspaceRegistry {
    /// Forget a frontend browser (and its conversation record) whose tab
    /// creation failed.
    pub fn delete_frontend_browser(&mut self, browser_id: &str) -> anyhow::Result<()> {
        crate::resource::BrowserPublicId::parse(browser_id.to_string())?;
        let tx = self.connection.transaction()?;
        tx.execute("DELETE FROM frontend_browser_tabs WHERE browser_id = ?1", [browser_id])?;
        tx.execute("DELETE FROM conversation_tabs WHERE browser_id = ?1", [browser_id])?;
        tx.execute("DELETE FROM app_tabs WHERE browser_id = ?1", [browser_id])?;
        Ok(tx.commit()?)
    }
}

/// The browser id a creation with this idempotency key recorded.
pub(crate) fn browser_for_mutation(
    connection: &Connection,
    origin: &str,
    mutation_id: &str,
) -> anyhow::Result<Option<(String, ConversationTabRecord)>> {
    Ok(connection
        .query_row(
            "SELECT browser_id, conversation, owner FROM conversation_tabs
             WHERE origin = ?1 AND mutation_id = ?2",
            params![origin, mutation_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    ConversationTabRecord { conversation: row.get(1)?, owner: row.get(2)? },
                ))
            },
        )
        .optional()?)
}

/// Every conversation tab record, keyed by browser id (the presentation
/// snapshot the raw tree reads).
pub(crate) fn read_conversation_tabs(
    connection: &Connection,
) -> anyhow::Result<HashMap<String, ConversationTabRecord>> {
    let mut statement =
        connection.prepare("SELECT browser_id, conversation, owner FROM conversation_tabs")?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                ConversationTabRecord { conversation: row.get(1)?, owner: row.get(2)? },
            ))
        })?
        .collect::<Result<HashMap<_, _>, _>>()?;
    if !rows.is_empty() {
        mark_conversation_tabs_present();
    }
    Ok(rows)
}

/// Rewrite every conversation tab in `value` to its `browser` form, for a
/// connection that did not negotiate `conversation-tabs-v1`: a v2 tab
/// snapshot (`content_kind`) and a raw tree tab (`kind` next to
/// `browser_renderer`). Returns whether anything changed.
pub(crate) fn downgrade_conversation_tabs(value: &mut Value) -> bool {
    match value {
        Value::Object(object) => {
            let mut changed = false;
            if object.get("content_kind").and_then(Value::as_str) == Some(CONVERSATION_KIND) {
                object.insert("content_kind".into(), Value::String("browser".into()));
                changed = true;
            }
            if object.contains_key("browser_renderer")
                && object.get("kind").and_then(Value::as_str) == Some(CONVERSATION_KIND)
            {
                object.insert("kind".into(), Value::String("browser".into()));
                changed = true;
            }
            for child in object.values_mut() {
                changed |= downgrade_conversation_tabs(child);
            }
            changed
        }
        Value::Array(items) => {
            let mut changed = false;
            for item in items {
                changed |= downgrade_conversation_tabs(item);
            }
            changed
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn conversation_tab_downgrade_touches_only_tab_kinds() {
        let mut value = json!({
            "event": "conversation-changed",
            "change": {"kind": "conversation"},
            "tabs": [
                {"content_kind": "conversation", "extra": {"conversation": {"owner": "local"}}},
                {"kind": "conversation", "browser_renderer": "frontend"},
                {"content_kind": "terminal"}
            ]
        });
        assert!(downgrade_conversation_tabs(&mut value));
        assert_eq!(value["change"]["kind"], "conversation", "a conversation event is not a tab");
        assert_eq!(value["tabs"][0]["content_kind"], "browser");
        assert_eq!(value["tabs"][0]["extra"]["conversation"]["owner"], "local");
        assert_eq!(value["tabs"][1]["kind"], "browser");
        assert_eq!(value["tabs"][2]["content_kind"], "terminal");
        assert!(!downgrade_conversation_tabs(&mut value));
    }

    #[test]
    fn conversation_tab_record_validates_its_id_and_owner() {
        let ok = ConversationTabRecord { conversation: "conv_01ABC".into(), owner: "local".into() };
        assert!(ok.validate().is_ok());
        for (conversation, owner) in
            [("chat_1", "local"), ("conv_1", "elsewhere"), ("conv_a b", "cloud")]
        {
            let record =
                ConversationTabRecord { conversation: conversation.into(), owner: owner.into() };
            assert!(record.validate().is_err(), "{conversation} {owner}");
        }
    }
}
