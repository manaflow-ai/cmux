//! BrowserSurface navigation commands: history, reload, activate, close, and
//! JavaScript dialog handling.

use super::*;

impl BrowserSurface {
    pub fn back(&self) -> anyhow::Result<()> {
        self.enqueue_control(BrowserCommand::Back)
    }

    pub fn forward(&self) -> anyhow::Result<()> {
        self.enqueue_control(BrowserCommand::Forward)
    }

    pub(super) fn back_blocking(&self) -> anyhow::Result<()> {
        self.navigate_history_blocking(-1)
    }

    pub(super) fn forward_blocking(&self) -> anyhow::Result<()> {
        self.navigate_history_blocking(1)
    }

    pub(crate) fn back_confirmed(&self) -> anyhow::Result<()> {
        self.execute_confirmed(BrowserCommand::Back)
    }

    pub(crate) fn forward_confirmed(&self) -> anyhow::Result<()> {
        self.execute_confirmed(BrowserCommand::Forward)
    }

    pub(super) fn navigate_history_blocking(&self, delta: isize) -> anyhow::Result<()> {
        let session = self.require_navigation_session()?;
        let invalidation = self.begin_latest_navigation_frame_transition(&session, true)?;
        let history = match session.runtime.client.navigation_history(&session.session_id) {
            Ok(history) => history,
            Err(error) => {
                self.restore_pointer_frame_after_failed_command(invalidation);
                return Err(error);
            }
        };
        let next = history.current_index as isize + delta;
        if next < 0 || next as usize >= history.entries.len() {
            self.restore_pointer_frame_after_failed_command(invalidation);
            anyhow::bail!(
                "browser has no {} history entry",
                if delta < 0 { "back" } else { "forward" }
            );
        }
        let entry = &history.entries[next as usize];
        self.finish_navigation_command(
            invalidation,
            session.runtime.client.navigate_to_history_entry(&session.session_id, entry.id),
        )?;
        Ok(())
    }

    pub fn reload(&self) -> anyhow::Result<()> {
        self.enqueue_control(BrowserCommand::Reload)
    }

    pub(super) fn reload_blocking(&self) -> anyhow::Result<()> {
        let session = self.require_navigation_session()?;
        let invalidation = self.begin_latest_navigation_frame_transition(&session, false)?;
        self.finish_navigation_command(
            invalidation,
            session.runtime.client.reload(&session.session_id),
        )?;
        Ok(())
    }

    pub(crate) fn reload_confirmed(&self) -> anyhow::Result<()> {
        self.execute_confirmed(BrowserCommand::Reload)
    }

    pub fn activate(&self) -> anyhow::Result<()> {
        self.enqueue_control(BrowserCommand::Activate)
    }

    pub(super) fn activate_blocking(&self) -> anyhow::Result<()> {
        let session = self.require_live_session()?;
        session.runtime.client.activate_target(&session.target_id, &session.session_id)
    }

    pub(crate) fn activate_confirmed(&self) -> anyhow::Result<()> {
        self.execute_confirmed(BrowserCommand::Activate)
    }

    pub(super) fn close_blocking(&self) -> anyhow::Result<()> {
        let session = self.require_live_session()?;
        if session.runtime.source() != BrowserSource::Provider {
            session.runtime.client.close_target(&session.target_id)?;
        }
        if !self.dead.swap(true, Ordering::AcqRel) {
            self.close_taps();
            if let Some(session) = self.session.lock().unwrap().take() {
                if session.runtime.source() == BrowserSource::Provider {
                    session.runtime.close_surface_detached(&session.target_id, &session.session_id);
                } else {
                    session.runtime.unregister(&session.target_id, &session.session_id);
                }
            }
            self.close_command_sender();
        }
        Ok(())
    }

    pub(crate) fn close_confirmed(&self) -> anyhow::Result<()> {
        self.execute_confirmed(BrowserCommand::Close)
    }

    pub(super) fn handle_javascript_dialog(&self, accept: bool) -> anyhow::Result<()> {
        let session = self.require_live_session()?;
        session.runtime.client.handle_javascript_dialog(&session.session_id, accept)
    }
}
