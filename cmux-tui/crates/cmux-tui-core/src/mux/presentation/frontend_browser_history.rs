//! Frontend-rendered browser tabs after creation: the location and
//! presentation they report (`update-frontend-browser-tab`) and their opaque
//! session history (`frontend-browser-history-v1`). The history is not
//! presentation state: it is never journaled, emitted, or serialized into
//! the tree.

use super::*;

impl Mux {
    /// Record the URL, title, or favicon a frontend-rendered browser
    /// reports. `favicon_url: Some(None)` clears the favicon.
    pub fn update_frontend_browser_tab(
        &self,
        surface: SurfaceId,
        url: Option<String>,
        title: Option<String>,
        favicon_url: Option<Option<String>>,
    ) -> anyhow::Result<(FrontendBrowserRecord, bool)> {
        let runtime =
            self.surface(surface).ok_or_else(|| anyhow::anyhow!("unknown surface {surface}"))?;
        let browser_id = self.frontend_browser_id(&runtime).ok_or_else(|| {
            anyhow::anyhow!("surface {surface} is not a frontend-rendered browser")
        })?;
        let (record, changed) = {
            let mut registry = self.workspace_registry.lock().unwrap();
            let result = registry.update_frontend_browser(
                browser_id.as_str(),
                url.as_deref(),
                title.as_deref(),
                favicon_url.as_ref().map(Option::as_deref),
            )?;
            if result.1 {
                self.reload_presentation(&registry)?;
            }
            result
        };
        if changed {
            if let Some(browser) = runtime.as_browser() {
                browser.set_frontend_location(url, title.clone());
            }
            self.publish_journal_event();
            if let Some(title) = title {
                self.emit(MuxEvent::TitleChanged { surface, title: Arc::from(title) });
            }
            self.emit_tab_changed(surface);
        }
        Ok((record, changed))
    }

    /// The frontend browser id behind a surface, with the errors
    /// `update_frontend_browser_tab` reports.
    fn require_frontend_browser_id(&self, surface: SurfaceId) -> anyhow::Result<BrowserPublicId> {
        let runtime =
            self.surface(surface).ok_or_else(|| anyhow::anyhow!("unknown surface {surface}"))?;
        self.frontend_browser_id(&runtime)
            .ok_or_else(|| anyhow::anyhow!("surface {surface} is not a frontend-rendered browser"))
    }

    /// Store (`Some`) or clear (`None`) the opaque session history (back and
    /// forward entries, scroll) a frontend keeps for a frontend-rendered
    /// browser.
    pub fn set_frontend_browser_history(
        &self,
        surface: SurfaceId,
        history: Option<String>,
    ) -> anyhow::Result<()> {
        let browser_id = self.require_frontend_browser_id(surface)?;
        let mut registry = self.workspace_registry.lock().unwrap();
        registry.set_frontend_browser_history(browser_id.as_str(), history.as_deref())
    }

    /// The session history last stored for a frontend-rendered browser.
    pub fn frontend_browser_history(&self, surface: SurfaceId) -> anyhow::Result<Option<String>> {
        let browser_id = self.require_frontend_browser_id(surface)?;
        let registry = self.workspace_registry.lock().unwrap();
        registry.frontend_browser_history(browser_id.as_str())
    }
}

#[cfg(test)]
mod tests {
    use super::super::tests::PresentationTestSession;
    use super::*;

    #[test]
    fn cmux_next_frontend_browser_history_is_kept_out_of_the_tree() {
        let session = PresentationTestSession::new("frontend-browser-history");
        let mux = session.open();
        let terminal = mux.new_workspace(None, None).unwrap().id;
        let pane = mux.with_state(|state| state.pane_of(terminal)).unwrap();
        let record = FrontendBrowserRecord {
            engine: "cef".into(),
            url: "https://example.com/".into(),
            title: None,
            favicon_url: None,
            profile_id: None,
        };
        let browser = mux.new_frontend_browser_tab(Some(pane), record, None).unwrap().id;
        assert_eq!(mux.frontend_browser_history(browser).unwrap(), None);
        let history = r#"{"entries":["https://example.com/"],"index":0,"scroll_y":120}"#;
        mux.set_frontend_browser_history(browser, Some(history.into())).unwrap();
        assert_eq!(mux.frontend_browser_history(browser).unwrap().as_deref(), Some(history));
        // The history never reaches the tree.
        let decorations = mux.tree_decorations();
        let tree = mux.with_state(|state| crate::server::workspaces_json(state, &decorations));
        assert!(!tree.to_string().contains("scroll_y"));

        // A PTY tab or an unknown surface has no frontend browser history.
        let error = mux.set_frontend_browser_history(terminal, Some("{}".into())).unwrap_err();
        assert!(error.to_string().contains("not a frontend-rendered browser"));
        assert!(mux.frontend_browser_history(terminal).is_err());
        let error = mux.frontend_browser_history(999_999).unwrap_err();
        assert!(error.to_string().contains("unknown surface"));
        assert!(mux.set_frontend_browser_history(browser, Some("[]".into())).is_err());
        let tab_id = mux.with_state(|state| state.resource_indexes.tab_ids[&browser].clone());
        drop(mux);

        // It survives a daemon restart, and `None` clears it.
        let mux = session.open();
        let restored = mux
            .with_state(|state| state.resource_indexes.tabs.get(&tab_id).copied())
            .expect("frontend browser tab restored");
        assert_eq!(mux.frontend_browser_history(restored).unwrap().as_deref(), Some(history));
        mux.set_frontend_browser_history(restored, None).unwrap();
        assert_eq!(mux.frontend_browser_history(restored).unwrap(), None);
    }
}
