//! The App side of host terminal notifications (`crate::host_notify`): on a
<<<<<<< ours
//! daemon notification it gathers what the gate needs (is the tab drawn, does
//! the host window have focus, is the tab the TUI's own host terminal) and
//! writes the gate's bytes to the host terminal under the stdout lock.
=======
//! daemon notification or a terminal bell it gathers what the gate needs (is
//! the tab drawn, does the host window have focus, is the tab the TUI's own
//! host terminal) and writes the gate's bytes to the host terminal under the
//! stdout lock.
>>>>>>> theirs

use std::io::Write;
use std::time::Instant;

<<<<<<< ours
use cmux_tui_core::NotificationEvent;

use crate::app::App;
use crate::host_notify::{HostNotifyContext, HostNotifyRequest};

impl App {
    /// A daemon notification, a terminal bell's `desktop: false` mark
    /// included (the raw `MuxEvent::Bell` is not passed on, so one bell rings
    /// the host once).
=======
use cmux_tui_core::{NotificationEvent, SurfaceId};

use super::App;
use crate::host_notify::{HostNotifyContext, HostNotifyRequest};

impl App {
    /// A daemon notification about a tab.
>>>>>>> theirs
    pub(super) fn forward_notification_to_host(&mut self, notification: &NotificationEvent) {
        if let Some(bytes) = self.host_notification_bytes(notification, Instant::now()) {
            self.write_host_notification(&bytes);
        }
    }

<<<<<<< ours
=======
    /// A terminal bell (BEL) in a tab: it asks for no desktop banner, so it
    /// rings the host bell only with `notifications.bell` on.
    pub(super) fn forward_bell_to_host(&mut self, surface: SurfaceId) {
        if let Some(bytes) = self.host_bell_bytes(surface, Instant::now()) {
            self.write_host_notification(&bytes);
        }
    }

>>>>>>> theirs
    /// What `forward_notification_to_host` writes for `notification` at
    /// `now`, after the gate (a write counts against its rate limit).
    pub(crate) fn host_notification_bytes(
        &mut self,
        notification: &NotificationEvent,
        now: Instant,
    ) -> Option<Vec<u8>> {
        let surface = notification.surface?;
<<<<<<< ours
        let context = self.host_notify_context(surface);
=======
>>>>>>> theirs
        let request = HostNotifyRequest {
            surface,
            title: &notification.title,
            body: &notification.body,
<<<<<<< ours
            desktop: notification.desktop,
        };
        let config = self.config.notifications;
        self.host_notify.decide(config, &request, context, now)
    }

    pub(crate) fn host_notify_context(
        &self,
        surface: cmux_tui_core::SurfaceId,
    ) -> HostNotifyContext {
=======
            desktop: true,
        };
        self.decide_host_notification(&request, now)
    }

    /// What `forward_bell_to_host` writes for a bell in `surface` at `now`.
    pub(crate) fn host_bell_bytes(&mut self, surface: SurfaceId, now: Instant) -> Option<Vec<u8>> {
        let request = HostNotifyRequest { surface, title: "Bell", body: "", desktop: false };
        self.decide_host_notification(&request, now)
    }

    fn decide_host_notification(
        &mut self,
        request: &HostNotifyRequest<'_>,
        now: Instant,
    ) -> Option<Vec<u8>> {
        let context = self.host_notify_context(request.surface);
        let config = self.config.notifications;
        self.host_notify.decide(config, request, context, now)
    }

    pub(crate) fn host_notify_context(&self, surface: SurfaceId) -> HostNotifyContext {
>>>>>>> theirs
        let host_terminal = self.host_notify.host().cmux_terminal.as_deref();
        let tabs = || {
            self.tree
                .workspaces()
                .iter()
                .flat_map(|workspace| &workspace.screens)
                .flat_map(|screen| &screen.panes)
                .flat_map(|pane| &pane.tabs)
        };
        let shows_host = |tab: &crate::session::tree::TabView| {
            host_terminal.is_some_and(|host| {
                tab.terminal_id.as_ref().is_some_and(|terminal| terminal.as_str() == host)
            })
        };
        HostNotifyContext {
            attached: self.surface_only.is_none() && !self.quit,
            tab_drawn: self.pane_areas.iter().any(|area| area.surface == surface),
            host_focused: self.host_focused,
            own_host_terminal: tabs().any(|tab| tab.surface == surface && shows_host(tab)),
            session_hosts_tui: tabs().any(shows_host),
        }
    }

    fn write_host_notification(&self, bytes: &[u8]) {
        let lock = self.stdout_lock.clone();
        let _guard = lock.lock();
        if lock.recover_stream_locked().is_err() {
            return;
        }
        if self.ensure_graphics_writer_healthy().is_err() {
            return;
        }
        let mut stdout = std::io::stdout();
        let _ = stdout.write_all(bytes);
        let _ = stdout.flush();
    }
}
