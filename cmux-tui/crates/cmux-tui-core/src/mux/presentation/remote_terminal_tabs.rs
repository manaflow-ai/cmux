//! Remote-terminal tabs (`remote-terminal-tabs-v1`): tabs in this session's
//! layout that reference a terminal on another session. The home workspace
//! store owns the reference; the remote session host owns the terminal, and
//! this daemon never attaches, spawns or bootstraps anything for it.

use super::super::*;
use crate::resource::BrowserPublicId;
use crate::workspace_registry::{
    PresentationSnapshot, RemoteTerminalChange, RemoteTerminalRecord, RemoteTerminalUpdate,
};

impl Mux {
    /// Give a restored remote-terminal placeholder its recorded title.
    pub(in crate::mux) fn restore_remote_terminal_title(
        &self,
        presentation: &PresentationSnapshot,
        browser_id: &BrowserPublicId,
        surface: &Surface,
    ) {
        if let (Some(record), Some(runtime)) =
            (presentation.remote_terminals.get(browser_id.as_str()), surface.as_browser())
        {
            runtime.set_frontend_location(None, Some(record.display_title()));
        }
    }

    /// See [`Mux::is_frontend_browser_surface`].
    pub fn is_frontend_rendered_surface(&self, surface: &Surface) -> bool {
        let Some(identity) = surface.resource_identity() else { return false };
        let ContentPublicId::Browser(id) = &identity.content_id else { return false };
        let presentation = self.presentation_snapshot();
        presentation.frontend_browsers.contains_key(id.as_str())
            || presentation.remote_terminals.contains_key(id.as_str())
    }

    fn remote_terminal_id(&self, surface: &Surface) -> Option<BrowserPublicId> {
        let identity = surface.resource_identity()?;
        let ContentPublicId::Browser(id) = &identity.content_id else { return None };
        self.presentation_snapshot().remote_terminals.contains_key(id.as_str()).then(|| id.clone())
    }

    /// The reference of a remote-terminal tab (`remote-terminal-tabs-v1`).
    pub fn remote_terminal(&self, surface: &Surface) -> Option<RemoteTerminalRecord> {
        let id = self.remote_terminal_id(surface)?;
        self.presentation_snapshot().remote_terminals.get(id.as_str()).cloned()
    }

    /// Create a tab that references terminal `record.terminal_id` on
    /// session `record.session_id`. The reference is stored before the tab
    /// commits, under the content id the creation then uses, so the
    /// placeholder surface never bootstraps a browser. A failed creation
    /// removes it.
    pub fn new_remote_terminal_tab(
        self: &Arc<Self>,
        pane: Option<PaneId>,
        record: RemoteTerminalRecord,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        record.validate()?;
        let browser_id = BrowserPublicId::random()?;
        {
            let mut registry = self.workspace_registry.lock().unwrap();
            registry.put_remote_terminal(browser_id.as_str(), &record)?;
            self.reload_presentation(&registry)?;
        }
        let fields = Map::from_iter([(
            "frontend_browser_id".to_string(),
            Value::String(browser_id.as_str().to_string()),
        )]);
        let url = crate::remote_terminal_placeholder_url(&record.session_id, &record.terminal_id);
        match self.new_browser_tab_with_fields(url, pane, size, fields) {
            Ok(surface) => {
                if let Some(runtime) = surface.as_browser()
                    && runtime.set_frontend_location(None, Some(record.display_title()))
                {
                    self.emit_tab_changed(surface.id);
                }
                self.publish_journal_event();
                Ok(surface)
            }
            Err(error) => {
                let mut registry = self.workspace_registry.lock().unwrap();
                if registry.delete_remote_terminal(browser_id.as_str()).is_ok() {
                    let _ = self.reload_presentation(&registry);
                }
                Err(error)
            }
        }
    }

    /// Record a remote-terminal tab's title, session name, or text
    /// snapshot. Title and session name changes are tab changes; a
    /// snapshot is stored silently.
    pub fn update_remote_terminal_tab(
        &self,
        surface: SurfaceId,
        update: RemoteTerminalUpdate,
    ) -> anyhow::Result<RemoteTerminalChange> {
        let runtime =
            self.surface(surface).ok_or_else(|| anyhow::anyhow!("unknown surface {surface}"))?;
        let browser_id = self
            .remote_terminal_id(&runtime)
            .ok_or_else(|| anyhow::anyhow!("surface {surface} is not a remote-terminal tab"))?;
        let (record, change) = {
            let mut registry = self.workspace_registry.lock().unwrap();
            let result = registry.update_remote_terminal(browser_id.as_str(), &update)?;
            if result.1.presentation {
                self.reload_presentation(&registry)?;
            }
            result
        };
        if change.presentation {
            let title = record.display_title();
            if let Some(browser) = runtime.as_browser() {
                browser.set_frontend_location(None, Some(title.clone()));
            }
            self.publish_journal_event();
            self.emit(MuxEvent::TitleChanged { surface, title: Arc::from(title) });
            self.emit_tab_changed(surface);
        }
        Ok(change)
    }

    /// The public `term_` id of the live terminal with host id `terminal_id`
    /// (32 hex digits). It is a separate random id, so a frontend that knows
    /// only the host id (a remote-terminal reference) reads it here before
    /// attaching by identity.
    pub fn terminal_public_id_for_host(
        &self,
        terminal_id: &str,
    ) -> anyhow::Result<Option<TerminalPublicId>> {
        self.workspace_registry.lock().unwrap().terminal_resource_id(terminal_id)
    }

    /// The last text snapshot the frontend stored for a remote-terminal tab.
    pub fn remote_terminal_snapshot(&self, surface: SurfaceId) -> anyhow::Result<Option<String>> {
        let runtime =
            self.surface(surface).ok_or_else(|| anyhow::anyhow!("unknown surface {surface}"))?;
        let browser_id = self
            .remote_terminal_id(&runtime)
            .ok_or_else(|| anyhow::anyhow!("surface {surface} is not a remote-terminal tab"))?;
        self.workspace_registry.lock().unwrap().remote_terminal_snapshot(browser_id.as_str())
    }
}

#[cfg(test)]
mod tests {
    use super::super::tests::PresentationTestSession;
    use super::*;

    fn tab_json(mux: &Mux, surface: SurfaceId) -> Value {
        let decorations = mux.tree_decorations();
        mux.with_state(|state| {
            crate::server::tree_entity_json(state, &decorations, TreeDeltaKind::TabChanged, surface)
        })
        .expect("tab is present in the tree")
    }

    #[test]
    fn cmux_next_remote_terminal_tabs_persist_across_restart() {
        let session = PresentationTestSession::new("remote-terminal");
        let mux = session.open();
        let terminal = mux.new_workspace(None, None).unwrap().id;
        let pane = mux.with_state(|state| state.pane_of(terminal)).unwrap();
        let record = RemoteTerminalRecord {
            session_id: "0b7f2c1e-4d3a-4f6b-9c8d-1a2b3c4d5e6f".into(),
            terminal_id: "5f0c3a9e2b7d4c1a8e6f0b3d2c1a9e8f".into(),
            session_name: "build-box".into(),
            title: Some("cargo build".into()),
        };
        let remote = mux.new_remote_terminal_tab(Some(pane), record, None).unwrap();
        assert!(mux.is_frontend_rendered_surface(&remote));
        assert!(
            mux.frontend_browser(&remote).is_none(),
            "a remote terminal is not a browser record"
        );
        mux.update_remote_terminal_tab(
            remote.id,
            RemoteTerminalUpdate {
                snapshot: Some(Some("$ cargo build\n".into())),
                ..Default::default()
            },
        )
        .unwrap();
        let tab = tab_json(&mux, remote.id);
        assert_eq!(tab["kind"], "remote-terminal");
        assert_eq!(tab["title"], "cargo build");
        let tab_id = mux.with_state(|state| state.resource_indexes.tab_ids[&remote.id].clone());
        drop(remote);
        drop(mux);

        let mux = session.open();
        let restored = mux
            .with_state(|state| state.resource_indexes.tabs.get(&tab_id).copied())
            .and_then(|surface| mux.surface(surface))
            .expect("remote-terminal tab restored");
        assert!(mux.is_frontend_rendered_surface(&restored));
        let tab = tab_json(&mux, restored.id);
        assert_eq!(tab["kind"], "remote-terminal");
        assert_eq!(tab["title"], "cargo build");
        assert_eq!(tab["remote"]["session_name"], "build-box");
        assert_eq!(tab["remote"]["terminal_id"], "5f0c3a9e2b7d4c1a8e6f0b3d2c1a9e8f");
        assert_eq!(
            mux.remote_terminal_snapshot(restored.id).unwrap().as_deref(),
            Some("$ cargo build\n")
        );
    }
}
