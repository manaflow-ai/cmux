//! `frontend-browser-tab-keys-v1`: `new-frontend-browser-tab` with a
//! client-chosen `idempotency_key` (OWNERSHIP-PRINCIPLES: every change is a
//! typed op with an idempotency key).
//!
//! The key row commits with the frontend browser row, so the browser id a key
//! chose is durable before the tab commits. A retry with the same key and the
//! same request returns the tab the first request created (`replayed`); a
//! retry after a crash between the two commits creates the tab under the
//! recorded browser id; the same key with another request is refused and
//! creates nothing. The conversation-tab creation keys its rows the same way
//! (state/conversation_tabs.rs).

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde_json::{Map, json};

use crate::Surface;
use crate::mux::*;
use crate::resource::{BrowserPublicId, ContentPublicId};
use crate::state::prelude::*;
use crate::workspace_registry::{FrontendBrowserRecord, WorkspaceMutation};

pub(crate) const FRONTEND_BROWSER_TAB_KEYS_CAPABILITY: &str = "frontend-browser-tab-keys-v1";

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
fn browser_for_key(connection: &Connection, key: &str) -> anyhow::Result<Option<(String, String)>> {
    Ok(connection
        .query_row(
            "SELECT browser_id, fingerprint FROM frontend_browser_tab_keys
             WHERE idempotency_key = ?1",
            [key],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        )
        .optional()?)
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
        let fingerprint = json!({"pane": pane, "size": size, "record": &record}).to_string();
        let (browser_id, fresh) = match self.read_registry_state(|c| browser_for_key(c, key))? {
            Some((browser_id, stored)) => {
                anyhow::ensure!(
                    stored == fingerprint,
                    "idempotency.conflict: the key named another new-frontend-browser-tab request"
                );
                let content = ContentPublicId::Browser(BrowserPublicId::parse(browser_id.clone())?);
                let placed = self.with_state(|state| {
                    let surface = state.single_placement_of_content(&content)?;
                    state.surfaces.get(&surface).cloned()
                });
                if let Some(surface) = placed {
                    return Ok(FrontendBrowserTabOutcome { surface, replayed: true });
                }
                (BrowserPublicId::parse(browser_id)?, false)
            }
            None => (BrowserPublicId::random()?, true),
        };
        if fresh {
            let id = browser_id.as_str().to_string();
            let write = |tx: &Transaction<'_>| -> anyhow::Result<()> {
                tx.execute(
                    "INSERT INTO frontend_browser_tab_keys(idempotency_key, browser_id, fingerprint)
                     VALUES(?1, ?2, ?3)",
                    params![key, id, fingerprint],
                )?;
                Ok(())
            };
            let mut registry = self.workspace_registry.lock().unwrap();
            registry.put_frontend_browser(browser_id.as_str(), &record, Some(&write))?;
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
