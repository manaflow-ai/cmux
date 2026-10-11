//! The TUI's notification dismissal policy (`feed-local-owner-v1`,
//! plans/cmux-next/feed.md section 9.1 item 5).
//!
//! A daemon with the local feed owner never clears unread on selection or
//! focus; each client acknowledges what its user saw. The TUI acknowledges a
//! tab with `ack-tab-notifications` when the user focuses it (a client focus
//! change the user made; a change the server causes, such as a closed tab, is
//! absorbed without an ack) or types into it (the `keystroke` default of
//! notifications.md).
//! It sends nothing for a tab its tree shows as read. Against an older
//! daemon the ack is harmless: that daemon also clears on selection.
//! Tests: app/tests/feed_dismissal.rs.

use cmux_tui_core::SurfaceId;

use crate::app::App;
use crate::session::Session;

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

    /// After a tree replacement: when the replacement itself moved the
    /// client's focus (the server closed the focused tab, or a remote change
    /// moved it), report the new focus as the baseline without acknowledging,
    /// so only a user focus change or a keystroke acks.
    pub(super) fn absorb_server_focus_change(
        &mut self,
        before: Option<crate::session::ClientFocus>,
    ) {
        let (Some(previous), Some(after)) = (self.reported_focus, self.current_client_focus())
        else {
            return;
        };
        if before != Some(after) && previous != after {
            self.session.report_focus(Some(previous), after, self.client_focus_id.as_deref());
            self.reported_focus = Some(after);
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
