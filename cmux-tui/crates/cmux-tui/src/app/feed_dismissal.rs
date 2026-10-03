//! The TUI's notification dismissal policy (`feed-local-owner-v1`,
//! plans/cmux-next/feed.md section 9.1 item 5).
//!
//! A daemon with the local feed owner never clears unread on selection or
//! focus; each client acknowledges what its user saw. The TUI acknowledges a
//! tab with `ack-tab-notifications` when the user focuses it (a client focus
//! change) or types into it (the `keystroke` default of notifications.md).
//! It sends nothing for a tab its tree shows as read. Against an older
//! daemon the ack is harmless: that daemon also clears on selection.

use super::*;

impl App {
    /// Acknowledge `surface`'s tab when the tree shows it unread.
    pub(super) fn acknowledge_viewed_tab(&mut self, surface: SurfaceId) {
        if self.tab_is_unread(surface) {
            self.session.inner.ack_tab_notifications(surface);
        }
    }

    /// Acknowledge the client's focused tab (after a focus change).
    pub(super) fn acknowledge_focused_tab(&mut self) {
        if let Some(surface) = self.active_surface() {
            self.acknowledge_viewed_tab(surface);
        }
    }

    fn tab_is_unread(&self, surface: SurfaceId) -> bool {
        self.tree.workspaces().iter().flat_map(|workspace| &workspace.screens).any(|screen| {
            screen.panes.iter().flat_map(|pane| &pane.tabs).any(|tab| {
                tab.surface == surface && tab.notification.is_some_and(|marker| marker.unread)
            })
        })
    }
}

impl Session {
    /// Best-effort `ack-tab-notifications`: the local path writes through the
    /// mux; the remote send is never awaited (a failure leaves the tab
    /// unread, and the next focus or keystroke retries).
    pub(crate) fn ack_tab_notifications(&self, surface: SurfaceId) {
        match self {
            Session::Local(mux) => {
                let _ = mux.acknowledge_tab_notifications(surface);
            }
            Session::Remote(remote) => {
                let _ = remote.notify(serde_json::json!({
                    "cmd": "ack-tab-notifications",
                    "surface": surface,
                }));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::super::tests::test_app;
    use super::*;

    #[test]
    fn focus_and_keystroke_acknowledge_only_unread_tabs() {
        let command = ["/bin/sh", "-c", "sleep 30"].map(str::to_string).to_vec();
        let options =
            cmux_tui_core::SurfaceOptions { command: Some(command), ..Default::default() };
        let mux = Mux::new("feed-dismissal-test", options);
        let surface = mux.new_workspace(Some("work".into()), Some((20, 8))).unwrap();
        let mut app = test_app(Session::Local(mux.clone()));
        mux.post_notification(
            "done".into(),
            "".into(),
            cmux_tui_core::NotificationLevel::Info,
            Some(surface.id),
        )
        .unwrap();
        // Selecting the tab no longer clears it on the daemon.
        mux.select_tab(None, Some(0), None);
        assert!(mux.surface_notification(surface.id).is_some());
        app.replace_tree(app.session.tree());
        assert!(app.tab_is_unread(surface.id));
        app.acknowledge_focused_tab();
        assert!(mux.surface_notification(surface.id).is_none(), "focus acknowledges");

        mux.post_notification(
            "again".into(),
            "".into(),
            cmux_tui_core::NotificationLevel::Info,
            Some(surface.id),
        )
        .unwrap();
        app.replace_tree(app.session.tree());
        app.forward_key_to_surface(
            KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE).into(),
            surface.id,
        );
        assert!(mux.surface_notification(surface.id).is_none(), "a keystroke acknowledges");
        // A read tab sends nothing (and the tree says read).
        app.replace_tree(app.session.tree());
        assert!(!app.tab_is_unread(surface.id));
        mux.close_surface(surface.id).unwrap();
    }

    /// A focus change the server causes (the focused tab closed) is not a
    /// user view: the newly focused unread tab stays unread.
    #[test]
    fn feedfix_server_focus_change_does_not_ack() {
        let command = ["/bin/sh", "-c", "sleep 30"].map(str::to_string).to_vec();
        let options =
            cmux_tui_core::SurfaceOptions { command: Some(command), ..Default::default() };
        let mux = Mux::new("feed-dismissal-server-focus", options);
        let first = mux.new_workspace(Some("work".into()), Some((20, 8))).unwrap();
        let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let second = mux.new_tab(Some(pane), None, None).unwrap();
        let mut app = test_app(Session::Local(mux.clone()));
        app.replace_tree(app.session.tree());
        app.report_client_focus();
        assert_eq!(app.active_surface(), Some(second.id), "the client starts on the new tab");
        mux.post_notification(
            "done".into(),
            "".into(),
            cmux_tui_core::NotificationLevel::Info,
            Some(first.id),
        )
        .unwrap();
        mux.close_surface(second.id).unwrap();
        app.replace_tree(app.session.tree());
        assert_eq!(app.active_surface(), Some(first.id), "the server moved focus");
        app.report_client_focus();
        assert!(mux.surface_notification(first.id).is_some(), "a server focus change never acks");
        mux.close_surface(first.id).unwrap();
    }
}
