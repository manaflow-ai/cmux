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
//!
//! `agent-session-tabs-v1` adds a second source, an acpmux agent session
//! (`agent_session_tabs`), so agent chat tabs are store tabs too
//! (plans/cmux-next/agent-tabs-store.md). Idempotency keys of both sources
//! live in `conversation_tab_keys` with the request's record and target (a
//! key copied from an older `conversation_tabs` row has no target) and
//! outlive the tab, so a replay after a close is refused. A connection that
//! did not negotiate `agent-session-tabs-v1` reads an agent session tab as a
//! `browser` tab without its record (server/conversation_tabs_wire.rs).
//!
//! `page-tabs-v1` adds a third source, one of the app's own pages (App
//! Store, Settings, ...; `page_tabs`), so those tabs move, split and close
//! like any tab instead of living only in one app session. The store keeps
//! only the page id; the app draws the page. A connection that did not
//! negotiate `page-tabs-v1` reads a page tab as `browser` without its record.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde_json::{Value, json};

pub(crate) const CONVERSATION_TABS_CAPABILITY: &str = "conversation-tabs-v1";
/// The agent session source of a conversation tab and its session bind.
pub(crate) const AGENT_SESSION_TABS_CAPABILITY: &str = "agent-session-tabs-v1";
/// The page source of a conversation tab (one of the app's own pages).
pub(crate) const PAGE_TABS_CAPABILITY: &str = "page-tabs-v1";
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
           ON conversation_tabs(origin, mutation_id) WHERE mutation_id IS NOT NULL;
         CREATE TABLE IF NOT EXISTS agent_session_tabs (
           browser_id TEXT PRIMARY KEY NOT NULL,
           host TEXT NOT NULL,
           session TEXT,
           harness TEXT
         );
         CREATE TABLE IF NOT EXISTS page_tabs (
           browser_id TEXT PRIMARY KEY NOT NULL,
           page TEXT NOT NULL
         );
         CREATE TABLE IF NOT EXISTS conversation_tab_keys (
           origin TEXT NOT NULL,
           mutation_id TEXT NOT NULL,
           browser_id TEXT NOT NULL,
           record TEXT NOT NULL,
           target TEXT,
           PRIMARY KEY(origin, mutation_id)
         );
         INSERT OR IGNORE INTO conversation_tab_keys(origin, mutation_id, browser_id, record)
           SELECT origin, mutation_id, browser_id,
                  json_object('conversation', conversation, 'owner', owner)
           FROM conversation_tabs WHERE origin IS NOT NULL AND mutation_id IS NOT NULL;",
    )?;
    add_agent_session_host_name(transaction)
}

/// `agent_session_tabs.host_name`, added to databases created before it.
fn add_agent_session_host_name(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    let present = transaction
        .query_row(
            "SELECT 1 FROM pragma_table_info('agent_session_tabs') WHERE name = 'host_name'",
            [],
            |_| Ok(()),
        )
        .optional()?
        .is_some();
    if !present {
        transaction.execute_batch("ALTER TABLE agent_session_tabs ADD COLUMN host_name TEXT;")?;
    }
    Ok(())
}

/// What a conversation tab shows (`conversation-tabs-v1`): a conversation of
/// the local or the cloud conversation owner, or (`agent-session-tabs-v1`)
/// an acpmux agent session that runs on the install `host` (`host_name` is
/// that machine's display name). A new chat has no session yet; the tab's
/// session changes by compare-and-swap (`bind-conversation-tab-session`).
/// A page tab (`page-tabs-v1`) shows one of the app's own pages by id.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConversationTabRecord {
    Conversation {
        conversation: String,
        owner: String,
    },
    AgentSession {
        host: String,
        session: Option<String>,
        harness: Option<String>,
        host_name: Option<String>,
    },
    Page {
        page: String,
    },
}

/// `bytes` is 1..=`max` long and every byte is a letter, a digit or one of `extra`.
fn token(value: &str, max: usize, extra: &[u8]) -> bool {
    (1..=max).contains(&value.len())
        && value.bytes().all(|byte| byte.is_ascii_alphanumeric() || extra.contains(&byte))
}

pub(crate) fn validate_session(session: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        token(session, 128, b"_.:-"),
        "bad request: session must be 1 to 128 letters, digits or '_', '.', ':', '-'"
    );
    Ok(())
}

impl ConversationTabRecord {
    pub(crate) fn validate(&self) -> anyhow::Result<()> {
        match self {
            Self::Conversation { conversation, owner } => {
                anyhow::ensure!(
                    conversation.starts_with("conv_") && token(conversation, 64, b"_"),
                    "bad request: conversation must be a conv_ id of at most 64 letters, digits or '_'"
                );
                anyhow::ensure!(
                    matches!(owner.as_str(), "local" | "cloud"),
                    "bad request: owner must be \"local\" or \"cloud\""
                );
            }
            Self::AgentSession { host, session, harness, host_name } => {
                anyhow::ensure!(
                    host.strip_prefix("install:").is_some_and(|id| token(id, 120, b"_.-")),
                    "bad request: host must be install: and 1 to 120 letters, digits or '_', '.', '-'"
                );
                if let Some(session) = session {
                    validate_session(session)?;
                }
                if let Some(harness) = harness {
                    anyhow::ensure!(
                        token(harness, 64, b"_.-"),
                        "bad request: harness must be 1 to 64 letters, digits or '_', '.', '-'"
                    );
                }
                if let Some(host_name) = host_name {
                    anyhow::ensure!(
                        (1..=255).contains(&host_name.len())
                            && !host_name.chars().any(char::is_control),
                        "bad request: host_name must be 1 to 255 bytes without control characters"
                    );
                }
            }
            Self::Page { page } => {
                anyhow::ensure!(
                    token(page, 64, b"-_.") && !page.bytes().any(|byte| byte.is_ascii_uppercase()),
                    "bad request: page must be 1 to 64 lowercase letters, digits or '-', '_', '.'"
                );
            }
        }
        Ok(())
    }

    pub(crate) fn wire(&self) -> Value {
        match self {
            Self::Conversation { conversation, owner } => {
                json!({"conversation": conversation, "owner": owner})
            }
            Self::AgentSession { host, session, harness, host_name } => json!({"agent_session": {
                "host": host, "session": session, "harness": harness, "host_name": host_name,
            }}),
            Self::Page { page } => json!({"page": page}),
        }
    }

    /// The record of a wire value (a closed-history record or a stored key).
    pub(crate) fn from_wire(value: &Value) -> Option<Self> {
        let text = |value: &Value| value.as_str().map(str::to_string);
        let record = match (value.get("agent_session"), value.get("page")) {
            (Some(agent), _) => Self::AgentSession {
                host: text(&agent["host"])?,
                session: text(&agent["session"]),
                harness: text(&agent["harness"]),
                host_name: text(&agent["host_name"]),
            },
            (None, Some(page)) => Self::Page { page: text(page)? },
            (None, None) => Self::Conversation {
                conversation: text(&value["conversation"])?,
                owner: text(&value["owner"])?,
            },
        };
        record.validate().ok().map(|()| record)
    }
}

/// Write the record of browser `browser_id` and its idempotency key (in the
/// frontend row's commit).
/// An idempotency key of a conversation tab creation and the request's
/// target (`{"pane": …}` or `{"workspace": …}` public ids).
#[derive(Debug, Clone, Copy)]
pub(crate) struct ConversationTabKey<'a> {
    pub(crate) origin: &'a str,
    pub(crate) mutation_id: &'a str,
    pub(crate) target: &'a Value,
}

pub(crate) fn write_conversation_tab(
    transaction: &Transaction<'_>,
    browser_id: &str,
    record: &ConversationTabRecord,
    key: Option<ConversationTabKey<'_>>,
) -> anyhow::Result<()> {
    record.validate()?;
    match record {
        ConversationTabRecord::Conversation { conversation, owner } => {
            transaction.execute(
                "INSERT INTO conversation_tabs(browser_id, conversation, owner) VALUES(?1, ?2, ?3)",
                params![browser_id, conversation, owner],
            )?;
        }
        ConversationTabRecord::AgentSession { host, session, harness, host_name } => {
            transaction.execute(
                "INSERT INTO agent_session_tabs(browser_id, host, session, harness, host_name)
                 VALUES(?1, ?2, ?3, ?4, ?5)",
                params![browser_id, host, session, harness, host_name],
            )?;
        }
        ConversationTabRecord::Page { page } => {
            transaction.execute(
                "INSERT INTO page_tabs(browser_id, page) VALUES(?1, ?2)",
                params![browser_id, page],
            )?;
        }
    }
    if let Some(key) = key {
        transaction.execute(
            "INSERT INTO conversation_tab_keys(origin, mutation_id, browser_id, record, target)
             VALUES(?1, ?2, ?3, ?4, ?5)",
            params![
                key.origin,
                key.mutation_id,
                browser_id,
                record.wire().to_string(),
                key.target.to_string()
            ],
        )?;
    }
    Ok(())
}

/// Delete the store rows of browser content a commit closes (coordinator
/// decision, 2026-10-04): the frontend record, its session history and the
/// conversation record go in the close's transaction; reopen uses the
/// closed-history record. Keys stay, so a replay of a closed tab's creation
/// is refused. The in-memory presentation snapshot may keep the deleted
/// records until its next reload; they are keyed by a tombstoned browser id
/// that no live surface resolves to.
pub(crate) fn delete_closed_browser_rows(
    transaction: &Transaction<'_>,
    browser_id: &str,
) -> anyhow::Result<()> {
    transaction.execute("DELETE FROM frontend_browser_tabs WHERE browser_id = ?1", [browser_id])?;
    transaction
        .execute("DELETE FROM frontend_browser_history WHERE browser_id = ?1", [browser_id])?;
    if super::store::state_tables_ready(transaction)? {
        transaction.execute("DELETE FROM conversation_tabs WHERE browser_id = ?1", [browser_id])?;
        transaction
            .execute("DELETE FROM agent_session_tabs WHERE browser_id = ?1", [browser_id])?;
        transaction.execute("DELETE FROM page_tabs WHERE browser_id = ?1", [browser_id])?;
    }
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
        tx.execute("DELETE FROM agent_session_tabs WHERE browser_id = ?1", [browser_id])?;
        tx.execute("DELETE FROM page_tabs WHERE browser_id = ?1", [browser_id])?;
        Ok(tx.commit()?)
    }
}

/// The session of agent tab `browser_id`: `None` when it is no agent
/// session tab, `Some(None)` before its session is bound.
pub(crate) fn agent_session_of(
    connection: &Connection,
    browser_id: &str,
) -> anyhow::Result<Option<Option<String>>> {
    Ok(connection
        .query_row(
            "SELECT session FROM agent_session_tabs WHERE browser_id = ?1",
            [browser_id],
            |row| row.get::<_, Option<String>>(0),
        )
        .optional()?)
}

/// The outcome of a session compare-and-swap that changed nothing.
#[derive(Debug)]
pub(crate) struct AgentSessionUnchanged;

impl std::fmt::Display for AgentSessionUnchanged {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("the tab already has this session")
    }
}

impl std::error::Error for AgentSessionUnchanged {}

/// Set the session of agent tab `browser_id` to `session` when its current
/// session is `expected` (None: unbound), in the caller's transaction. A
/// tab that already has `session` fails with [`AgentSessionUnchanged`], so
/// the caller commits nothing; another current session is
/// `conversation_tab.session_conflict`.
pub(crate) fn swap_agent_session(
    transaction: &Transaction<'_>,
    browser_id: &str,
    session: &str,
    expected: Option<&str>,
) -> anyhow::Result<()> {
    validate_session(session)?;
    if let Some(expected) = expected {
        validate_session(expected)?;
    }
    let current = agent_session_of(transaction, browser_id)?
        .ok_or_else(|| anyhow::anyhow!("bad request: the tab has no agent session source"))?;
    if current.as_deref() == Some(session) {
        return Err(AgentSessionUnchanged.into());
    }
    if current.as_deref() != expected {
        anyhow::bail!(
            "conversation_tab.session_conflict: current session is {}",
            current.as_deref().unwrap_or("null")
        );
    }
    transaction.execute(
        "UPDATE agent_session_tabs SET session = ?1 WHERE browser_id = ?2",
        params![session, browser_id],
    )?;
    Ok(())
}

/// What a creation with an idempotency key recorded: the browser id, the
/// record and the target (absent for a key copied from an older row).
pub(crate) struct RecordedConversationTab {
    pub(crate) browser_id: String,
    pub(crate) record: Option<ConversationTabRecord>,
    pub(crate) target: Option<Value>,
}

/// What a creation with this idempotency key recorded.
pub(crate) fn browser_for_mutation(
    connection: &Connection,
    origin: &str,
    mutation_id: &str,
) -> anyhow::Result<Option<RecordedConversationTab>> {
    let row = connection
        .query_row(
            "SELECT browser_id, record, target FROM conversation_tab_keys
             WHERE origin = ?1 AND mutation_id = ?2",
            params![origin, mutation_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                ))
            },
        )
        .optional()?;
    Ok(row.map(|(browser_id, record, target)| RecordedConversationTab {
        browser_id,
        record: serde_json::from_str::<Value>(&record)
            .ok()
            .and_then(|value| ConversationTabRecord::from_wire(&value)),
        target: target.and_then(|target| serde_json::from_str(&target).ok()),
    }))
}

/// Every conversation tab record of either source, keyed by browser id (the
/// presentation snapshot the raw tree reads).
pub(crate) fn read_conversation_tabs(
    connection: &Connection,
) -> anyhow::Result<HashMap<String, ConversationTabRecord>> {
    let mut rows = HashMap::new();
    let mut statement =
        connection.prepare("SELECT browser_id, conversation, owner FROM conversation_tabs")?;
    for row in statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            ConversationTabRecord::Conversation { conversation: row.get(1)?, owner: row.get(2)? },
        ))
    })? {
        let (id, record) = row?;
        rows.insert(id, record);
    }
    let mut statement = connection
        .prepare("SELECT browser_id, host, session, harness, host_name FROM agent_session_tabs")?;
    for row in statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            ConversationTabRecord::AgentSession {
                host: row.get(1)?,
                session: row.get(2)?,
                harness: row.get(3)?,
                host_name: row.get(4)?,
            },
        ))
    })? {
        let (id, record) = row?;
        rows.insert(id, record);
    }
    let mut statement = connection.prepare("SELECT browser_id, page FROM page_tabs")?;
    for row in statement.query_map([], |row| {
        Ok((row.get::<_, String>(0)?, ConversationTabRecord::Page { page: row.get(1)? }))
    })? {
        let (id, record) = row?;
        rows.insert(id, record);
    }
    if !rows.is_empty() {
        mark_conversation_tabs_present();
    }
    Ok(rows)
}

/// The wire record of tab `tab_id`'s content, if it is a conversation tab
/// (v2 `extra.conversation` and the closed-history record).
pub(crate) fn tab_conversation_wire(
    connection: &Connection,
    tab_id: &str,
) -> anyhow::Result<Option<Value>> {
    let conversation = connection
        .query_row(
            "SELECT c.conversation, c.owner FROM resource_tabs AS t
             JOIN conversation_tabs AS c ON c.browser_id = t.content_id
             WHERE t.public_id = ?1",
            [tab_id],
            |row| {
                Ok(ConversationTabRecord::Conversation {
                    conversation: row.get(0)?,
                    owner: row.get(1)?,
                })
            },
        )
        .optional()?;
    let record = match conversation {
        Some(record) => Some(record),
        None => connection
            .query_row(
                "SELECT a.host, a.session, a.harness, a.host_name FROM resource_tabs AS t
                 JOIN agent_session_tabs AS a ON a.browser_id = t.content_id
                 WHERE t.public_id = ?1",
                [tab_id],
                |row| {
                    Ok(ConversationTabRecord::AgentSession {
                        host: row.get(0)?,
                        session: row.get(1)?,
                        harness: row.get(2)?,
                        host_name: row.get(3)?,
                    })
                },
            )
            .optional()?,
    };
    let record = match record {
        Some(record) => Some(record),
        None => connection
            .query_row(
                "SELECT p.page FROM resource_tabs AS t
                 JOIN page_tabs AS p ON p.browser_id = t.content_id
                 WHERE t.public_id = ?1",
                [tab_id],
                |row| Ok(ConversationTabRecord::Page { page: row.get(0)? }),
            )
            .optional()?,
    };
    Ok(record.map(|record| record.wire()))
}

/// What a connection reads of conversation tabs it did not negotiate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ConversationTabDowngrade {
    /// No `conversation-tabs-v1`: every conversation tab reads as `browser`.
    All,
    /// `conversation-tabs-v1` without `agent-session-tabs-v1`: agent
    /// session tabs read as `browser`.
    AgentSessions,
    /// `conversation-tabs-v1` without `page-tabs-v1`: page tabs read as `browser`.
    Pages,
    /// `conversation-tabs-v1` with neither: agent session and page tabs read
    /// as `browser`.
    AgentSessionsAndPages,
}

impl ConversationTabDowngrade {
    /// Whether a tab with this record reads as `browser`.
    fn hides(self, record: Option<&Value>) -> bool {
        match self {
            Self::All => true,
            Self::AgentSessions => is_agent_session(record),
            Self::Pages => is_page(record),
            Self::AgentSessionsAndPages => is_agent_session(record) || is_page(record),
        }
    }
}

/// Whether a conversation record (`conversation` of a raw tab, or
/// `extra.conversation` of a resource tab) has an agent session source.
fn is_agent_session(record: Option<&Value>) -> bool {
    record.is_some_and(|record| record.get("agent_session").is_some())
}

/// Whether a conversation record has a page source.
fn is_page(record: Option<&Value>) -> bool {
    record.is_some_and(|record| record.get("page").is_some())
}

/// Whether an older reader cannot decode the record (it requires a
/// conversation source), so a hidden tab also loses it.
fn strips_record(record: Option<&Value>) -> bool {
    is_agent_session(record) || is_page(record)
}

/// Rewrite the conversation tabs in `value` that `downgrade` hides to
/// `browser`: the v2 `content_kind` and the raw tree `kind` (a raw tab has
/// `browser_renderer`). An agent session or page tab also loses its record,
/// which an older reader cannot decode. Returns whether anything changed.
pub(crate) fn downgrade_conversation_tabs(
    value: &mut Value,
    downgrade: ConversationTabDowngrade,
) -> bool {
    match value {
        Value::Object(object) => {
            let mut changed = false;
            if object.get("content_kind").and_then(Value::as_str) == Some(CONVERSATION_KIND) {
                let extra = object.get_mut("extra").and_then(Value::as_object_mut);
                let record = extra.as_ref().and_then(|extra| extra.get("conversation"));
                let (hidden, strip) = (downgrade.hides(record), strips_record(record));
                if hidden {
                    if strip && let Some(extra) = extra {
                        extra.remove("conversation");
                    }
                    object.insert("content_kind".into(), Value::String("browser".into()));
                    changed = true;
                }
            }
            if object.contains_key("browser_renderer")
                && object.get("kind").and_then(Value::as_str) == Some(CONVERSATION_KIND)
            {
                let record = object.get("conversation");
                let (hidden, strip) = (downgrade.hides(record), strips_record(record));
                if hidden {
                    if strip {
                        object.insert("conversation".into(), Value::Null);
                    }
                    object.insert("kind".into(), Value::String("browser".into()));
                    changed = true;
                }
            }
            for child in object.values_mut() {
                changed |= downgrade_conversation_tabs(child, downgrade);
            }
            changed
        }
        Value::Array(items) => {
            let mut changed = false;
            for item in items {
                changed |= downgrade_conversation_tabs(item, downgrade);
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
        assert!(downgrade_conversation_tabs(&mut value, ConversationTabDowngrade::All));
        assert_eq!(value["change"]["kind"], "conversation", "a conversation event is not a tab");
        assert_eq!(value["tabs"][0]["content_kind"], "browser");
        assert_eq!(value["tabs"][0]["extra"]["conversation"]["owner"], "local");
        assert_eq!(value["tabs"][1]["kind"], "browser");
        assert_eq!(value["tabs"][2]["content_kind"], "terminal");
        assert!(!downgrade_conversation_tabs(&mut value, ConversationTabDowngrade::All));
    }

    #[test]
    fn conversation_tab_record_validates_its_id_and_owner() {
        let ok = ConversationTabRecord::Conversation {
            conversation: "conv_01ABC".into(),
            owner: "local".into(),
        };
        assert!(ok.validate().is_ok());
        for (conversation, owner) in
            [("chat_1", "local"), ("conv_1", "elsewhere"), ("conv_a b", "cloud")]
        {
            let record = ConversationTabRecord::Conversation {
                conversation: conversation.into(),
                owner: owner.into(),
            };
            assert!(record.validate().is_err(), "{conversation} {owner}");
        }
    }

    #[test]
    fn agent_session_record_validates_and_round_trips_its_wire_form() {
        let record = ConversationTabRecord::AgentSession {
            host: "install:mac-1".into(),
            session: None,
            harness: Some("claude".into()),
            host_name: Some("Build Mac".into()),
        };
        assert!(record.validate().is_ok());
        let wire = record.wire();
        assert_eq!(
            wire,
            json!({"agent_session":{"host":"install:mac-1","session":null,"harness":"claude",
                                    "host_name":"Build Mac"}})
        );
        assert_eq!(ConversationTabRecord::from_wire(&wire), Some(record));
        for (host, session) in [("mac-1", None), ("install:", None), ("install:a", Some("a b"))] {
            let record = ConversationTabRecord::AgentSession {
                host: host.into(),
                session: session.map(str::to_string),
                harness: None,
                host_name: None,
            };
            assert!(record.validate().is_err(), "{host} {session:?}");
        }
    }

    #[test]
    fn agent_session_tabs_downgrade_without_their_record() {
        let agent = json!({"agent_session":{"host":"install:a","session":null,"harness":null}});
        let original = json!({
            "tabs": [
                {"content_kind": "conversation", "extra": {"conversation": agent, "pinned": true}},
                {"content_kind": "conversation",
                 "extra": {"conversation": {"conversation": "conv_1", "owner": "local"}}}
            ],
            "raw": [{"kind": "conversation", "browser_renderer": "frontend", "conversation": agent}]
        });
        let mut value = original.clone();
        assert!(downgrade_conversation_tabs(&mut value, ConversationTabDowngrade::AgentSessions));
        assert_eq!(value["tabs"][0]["content_kind"], "browser");
        assert_eq!(value["tabs"][0]["extra"], json!({"pinned": true}));
        assert_eq!(value["tabs"][1], original["tabs"][1], "a conversation source stays");
        assert_eq!(value["raw"][0]["kind"], "browser");
        assert_eq!(value["raw"][0]["conversation"], Value::Null);
        let mut all = original;
        assert!(downgrade_conversation_tabs(&mut all, ConversationTabDowngrade::All));
        assert_eq!(all["tabs"][1]["content_kind"], "browser");
        assert_eq!(all["tabs"][1]["extra"]["conversation"]["owner"], "local");
        assert_eq!(all["tabs"][0]["extra"], json!({"pinned": true}));
    }
}
