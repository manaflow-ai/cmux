//! `frontend-browser-tab-keys-v1`: `new-frontend-browser-tab` with a
//! client-chosen `idempotency_key` (OWNERSHIP-PRINCIPLES: every change is a
//! typed op with an idempotency key).
//!
//! The key row commits with the frontend browser record, so the browser id a
//! key chose is durable before the tab commits. One lock serializes keyed
//! creations, so a retry that arrives while the first request still runs
//! waits for it and replays it. With the same key and the same request:
//! - the tab is placed: the daemon returns it (`replayed`);
//! - the browser never got a tab (a crash between the two commits): the tab
//!   is created under the recorded browser id;
//! - the tab was created and later closed: refused, nothing is created.
//!
//! The same key with another request is refused and creates nothing. The
//! request fingerprint names the pane by its public id (numeric pane ids do
//! not survive a daemon restart) and leaves out the size hint. The
//! conversation-tab creation keys its rows the same way
//! (state/conversation_tabs.rs).

use std::sync::Mutex;

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde_json::{Map, json};

use crate::Surface;
use crate::mux::*;
use crate::resource::BrowserPublicId;
use crate::state::prelude::*;
use crate::workspace_registry::FrontendBrowserRecord;

pub(crate) const FRONTEND_BROWSER_TAB_KEYS_CAPABILITY: &str = "frontend-browser-tab-keys-v1";

/// Serializes keyed creations (process-wide; held for the whole creation and
/// taken before every other lock).
static KEYED_CREATION: Mutex<()> = Mutex::new(());

pub(crate) fn create_frontend_browser_keys_schema(tx: &Transaction<'_>) -> anyhow::Result<()> {
    tx.execute_batch(
        "CREATE TABLE IF NOT EXISTS frontend_browser_tab_keys (
           idempotency_key TEXT PRIMARY KEY NOT NULL,
           browser_id TEXT NOT NULL,
           fingerprint TEXT NOT NULL
         );",
    )?;
    Ok(())
}

/// The browser id and request fingerprint a key recorded.
fn browser_for_key(connection: &Connection, key: &str) -> anyhow::Result<Option<(String, Value)>> {
    let row = connection
        .query_row(
            "SELECT browser_id, fingerprint FROM frontend_browser_tab_keys
             WHERE idempotency_key = ?1",
            [key],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        )
        .optional()?;
    row.map(|(browser_id, fingerprint)| Ok((browser_id, serde_json::from_str(&fingerprint)?)))
        .transpose()
}

/// Whether a tab ever committed browser content `browser_id` (live or
/// closed: closed identities keep their row as a tombstone).
pub(crate) fn browser_committed(connection: &Connection, browser_id: &str) -> anyhow::Result<bool> {
    Ok(connection
        .query_row(
            "SELECT 1 FROM resource_identities WHERE public_id = ?1
             UNION ALL SELECT 1 FROM resource_browsers WHERE public_id = ?1 LIMIT 1",
            [browser_id],
            |_| Ok(()),
        )
        .optional()?
        .is_some())
}

/// A refused reuse of a frontend browser id. One browser id belongs to at
/// most one tab, ever: a closed tab keeps its id as a tombstone.
#[derive(Debug)]
pub(crate) enum FrontendBrowserReuse {
    /// A tab already committed this browser id (live or closed).
    Bound(String),
    /// The idempotency key's tab was closed: a new tab needs a new key.
    KeyClosed(String),
}

impl FrontendBrowserReuse {
    pub(crate) const BOUND_CODE: &'static str = "frontend_browser_bound";
    pub(crate) const KEY_CLOSED_CODE: &'static str = "frontend_browser_key_closed";

    fn code(&self) -> &'static str {
        match self {
            Self::Bound(_) => Self::BOUND_CODE,
            Self::KeyClosed(_) => Self::KEY_CLOSED_CODE,
        }
    }
}

impl std::fmt::Display for FrontendBrowserReuse {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Bound(id) => write!(f, "{}: browser {id} already belongs to a tab", self.code()),
            Self::KeyClosed(id) => write!(
                f,
                "{}: the key's tab {id} is closed: send a new key for a new tab",
                self.code()
            ),
        }
    }
}

impl std::error::Error for FrontendBrowserReuse {}

/// The raw `error_code` of a refused frontend browser id reuse.
pub(crate) fn error_code(error: &anyhow::Error) -> Option<String> {
    error.downcast_ref::<FrontendBrowserReuse>().map(|error| error.code().to_string())
}

impl Mux {
    /// The `frontend_browser_id` of a browser creation (`tab.create_browser`),
    /// parsed. Refused (`frontend_browser_bound`) before any receipt when a
    /// tab ever committed it, so no retry or caller binds one browser id to
    /// two tabs.
    pub(crate) fn unbound_frontend_browser_id(
        connection: &Connection,
        browser_id: &str,
    ) -> anyhow::Result<BrowserPublicId> {
        let id = BrowserPublicId::parse(browser_id.to_string())?;
        if browser_committed(connection, id.as_str())? {
            return Err(FrontendBrowserReuse::Bound(id.to_string()).into());
        }
        Ok(id)
    }
}

/// A created or replayed frontend browser tab.
pub(crate) struct FrontendBrowserTabOutcome {
    pub(crate) surface: Arc<Surface>,
    pub(crate) replayed: bool,
}

impl Mux {
    /// `new-frontend-browser-tab {idempotency_key}`.
    pub(crate) fn new_frontend_browser_tab_keyed(
        self: &Arc<Self>,
        pane: Option<PaneId>,
        record: FrontendBrowserRecord,
        size: Option<(u16, u16)>,
        key: &str,
    ) -> anyhow::Result<FrontendBrowserTabOutcome> {
        record.validate()?;
        WorkspaceMutation::new(key, "new-frontend-browser-tab")?;
        let _serial = KEYED_CREATION.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let pane_id = match pane {
            Some(pane) => Some(self.with_state(|state| {
                state.resource_indexes.pane_ids.get(&pane).cloned().context("unknown pane")
            })?),
            None => None,
        };
        let fingerprint = json!({"pane": pane_id, "record": &record});
        let (browser_id, fresh) = match self.read_registry_state(|c| browser_for_key(c, key))? {
            Some((browser_id, stored)) => {
                anyhow::ensure!(
                    stored == fingerprint,
                    "idempotency.conflict: the key named another new-frontend-browser-tab request"
                );
                let browser_id = BrowserPublicId::parse(browser_id)?;
                let content = ContentPublicId::Browser(browser_id.clone());
                let placed = self.with_state(|state| {
                    let surface = state.single_placement_of_content(&content)?;
                    state.surfaces.get(&surface).cloned()
                });
                if let Some(surface) = placed {
                    return Ok(FrontendBrowserTabOutcome { surface, replayed: true });
                }
                if self.read_registry_state(|c| browser_committed(c, browser_id.as_str()))? {
                    return Err(FrontendBrowserReuse::KeyClosed(browser_id.to_string()).into());
                }
                (browser_id, false)
            }
            None => (BrowserPublicId::random()?, true),
        };
        if fresh {
            let id = browser_id.as_str();
            let write = |tx: &Transaction<'_>| insert_key(tx, key, id, &fingerprint);
            let mut registry = self.workspace_registry.lock().unwrap();
            registry.put_frontend_browser(id, &record, Some(&write))?;
            self.reload_presentation(&registry)?;
        }
        let fields = Map::from_iter([(
            "frontend_browser_id".to_string(),
            Value::String(browser_id.as_str().to_string()),
        )]);
        // A failed keyed creation keeps its rows, so a retry resumes it.
        let surface = self.new_browser_tab_with_fields(record.url.clone(), pane, size, fields)?;
        if let Some(runtime) = surface.as_browser()
            && runtime.set_frontend_location(None, record.title)
        {
            self.emit_tab_changed(surface.id);
        }
        self.publish_journal_event();
        Ok(FrontendBrowserTabOutcome { surface, replayed: false })
    }
}

/// Records the browser id and request fingerprint of `key` (in the frontend
/// browser record's commit).
pub(crate) fn insert_key(
    tx: &Transaction<'_>,
    key: &str,
    browser_id: &str,
    fingerprint: &Value,
) -> anyhow::Result<()> {
    tx.execute(
        "INSERT INTO frontend_browser_tab_keys(idempotency_key, browser_id, fingerprint)
         VALUES(?1, ?2, ?3)",
        params![key, browser_id, fingerprint.to_string()],
    )?;
    Ok(())
}
