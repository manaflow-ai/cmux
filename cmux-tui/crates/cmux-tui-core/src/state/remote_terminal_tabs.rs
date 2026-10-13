//! Remote-terminal tabs (`remote-terminal-tabs-v1`, raw
//! `new-remote-terminal-tab`, `update-remote-terminal-tab` and
//! `remote-terminal-snapshot`): a tab in this session's layout that
//! references a terminal on another session. The frontend browser row and the
//! `remote_terminal_tabs` row commit together; the tab then commits through
//! the frontend browser creation path, under the browser id that commit
//! chose, so the placeholder surface never bootstraps a browser
//! (state/remote_terminal_tabs_store.rs).

use std::sync::PoisonError;

use crate::Actor;
use serde_json::Map;

use crate::Surface;
use crate::mux::*;
use crate::resource::BrowserPublicId;
use crate::resource::TerminalPublicId;
use crate::state::prelude::*;
use crate::state::remote_terminal_tabs_store::{
    REMOTE_TERMINAL_TAB_ENGINE, REMOTE_TERMINAL_TAB_URL, RemoteTerminalChange,
    RemoteTerminalRecord, RemoteTerminalUpdate, read_snapshot, update_remote_terminal,
    write_remote_terminal,
};
use crate::workspace_registry::FrontendBrowserRecord;

impl Mux {
    /// The browser id behind a remote-terminal tab's placeholder surface.
    pub(crate) fn remote_terminal_id(&self, surface: &Surface) -> Option<BrowserPublicId> {
        let identity = surface.resource_identity()?;
        let ContentPublicId::Browser(id) = &identity.content_id else { return None };
        self.presentation_snapshot().remote_terminals.contains_key(id.as_str()).then(|| id.clone())
    }

    fn require_remote_terminal_id(&self, surface: SurfaceId) -> anyhow::Result<BrowserPublicId> {
        let runtime =
            self.surface(surface).ok_or_else(|| anyhow::anyhow!("unknown surface {surface}"))?;
        self.remote_terminal_id(&runtime)
            .ok_or_else(|| anyhow::anyhow!("surface {surface} is not a remote-terminal tab"))
    }

    /// Create a tab in `pane` (default: the active pane) that references
    /// terminal `record.terminal_id` on session `record.session_id`. A failed
    /// creation removes the stored reference.
    pub(crate) fn new_remote_terminal_tab_as(
        self: &Arc<Self>,
        actor: &Actor,
        pane: Option<PaneId>,
        record: RemoteTerminalRecord,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        record.validate()?;
        let browser_id = BrowserPublicId::random()?;
        let title = record.display_title();
        {
            let frontend = FrontendBrowserRecord {
                engine: REMOTE_TERMINAL_TAB_ENGINE.to_string(),
                url: REMOTE_TERMINAL_TAB_URL.to_string(),
                title: Some(title.clone()),
                favicon_url: None,
                profile_id: None,
                owner: None,
            };
            let id = browser_id.as_str().to_string();
            let write = |tx: &rusqlite::Transaction<'_>| write_remote_terminal(tx, &id, &record);
            let mut registry =
                self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
            registry.put_frontend_browser(browser_id.as_str(), &frontend, Some(&write))?;
            self.reload_presentation(&registry)?;
        }
        let fields = Map::from_iter([(
            "frontend_browser_id".to_string(),
            Value::String(browser_id.as_str().to_string()),
        )]);
        let created = self.new_browser_tab_with_fields_as(
            actor,
            REMOTE_TERMINAL_TAB_URL.to_string(),
            pane,
            size,
            fields,
        );
        match created {
            Ok(surface) => {
                if let Some(runtime) = surface.as_browser()
                    && runtime.set_frontend_location(None, Some(title))
                {
                    self.emit_tab_changed(surface.id);
                }
                self.publish_journal_event();
                Ok(surface)
            }
            Err(error) => {
                let mut registry =
                    self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
                if registry.delete_frontend_browser(browser_id.as_str()).is_ok() {
                    let _ = self.reload_presentation(&registry);
                }
                Err(error)
            }
        }
    }

    /// Record a remote-terminal tab's title, session name, or text snapshot.
    /// Title and session name changes are tab changes; a snapshot is stored
    /// silently.
    pub(crate) fn update_remote_terminal_tab(
        &self,
        surface: SurfaceId,
        update: RemoteTerminalUpdate,
    ) -> anyhow::Result<RemoteTerminalChange> {
        let browser_id = self.require_remote_terminal_id(surface)?;
        let (record, change) = {
            let mut registry =
                self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
            let result = update_remote_terminal(&mut registry, browser_id.as_str(), &update)?;
            if result.1.presentation {
                self.reload_presentation(&registry)?;
            }
            result
        };
        if change.presentation {
            let title = record.display_title();
            if let Some(runtime) = self.surface(surface)
                && let Some(browser) = runtime.as_browser()
            {
                browser.set_frontend_location(None, Some(title.clone()));
            }
            self.publish_journal_event();
            if change.title {
                self.emit(MuxEvent::TitleChanged { surface, title: Arc::from(title) });
            }
            self.emit_tab_changed(surface);
        }
        Ok(change)
    }

    /// The last text snapshot the frontend stored for a remote-terminal tab.
    pub(crate) fn remote_terminal_snapshot(
        &self,
        surface: SurfaceId,
    ) -> anyhow::Result<Option<String>> {
        let browser_id = self.require_remote_terminal_id(surface)?;
        self.read_registry_state(|connection| read_snapshot(connection, browser_id.as_str()))
    }

    /// The public `term_` id of the terminal with host id `terminal_id`. It is
    /// a separate random id, so a frontend that knows only the host id (a
    /// remote-terminal reference) reads it here before attaching by identity.
    pub(crate) fn terminal_public_id_for_host(
        &self,
        terminal_id: &str,
    ) -> anyhow::Result<Option<TerminalPublicId>> {
        self.workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .terminal_resource_id(terminal_id)
    }
}
