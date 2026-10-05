//! Part of `Hub`; see `hub/mod.rs`. Web control of a session follows the
//! asking-mode table (`web_modes.rs`): the merged table is built and logged
//! once at start and at every config reload, and a session whose mode leaves
//! the table (a harness update, also one the harness makes by itself, or a
//! set) loses Web control at once. Web reads stay. Only the unix socket or
//! the local app setting an asking mode again restores it; a harness that
//! returns to an asking mode by itself does not.

use super::*;
use crate::web_modes::WebModeTable;

/// The `webAskingModes` the table was built from, and the table.
pub(super) type WebModeCache = (std::collections::BTreeMap<String, Vec<String>>, Arc<WebModeTable>);

impl Hub {
    /// The merged asking-mode table the remote guard and Web control use.
    /// config.json stays the source: a config changed without a reload (as
    /// in-process tests do) rebuilds the table quietly, still minus the
    /// non-asking entries.
    pub(crate) fn web_modes(&self) -> Arc<WebModeTable> {
        let mut cached = self.web_modes.lock().unwrap_or_else(|e| e.into_inner());
        if let Ok(c) = self.config.try_read()
            && c.web_asking_modes != cached.0
        {
            *cached =
                (c.web_asking_modes.clone(), Arc::new(WebModeTable::build(&c.web_asking_modes).0));
        }
        cached.1.clone()
    }

    /// Build the table from config.json and log it (and every ignored
    /// `webAskingModes` entry) once.
    pub(super) fn refresh_web_modes(
        &self,
        extra: &std::collections::BTreeMap<String, Vec<String>>,
    ) {
        let (table, warnings) = WebModeTable::build(extra);
        for w in &warnings {
            tracing::warn!("{w}");
        }
        tracing::info!("web asking modes: {}", table.summary());
        *self.web_modes.lock().unwrap_or_else(|e| e.into_inner()) =
            (extra.clone(), Arc::new(table));
    }

    /// A session's mode may have changed. Leaving the table ends Web control;
    /// `restore` (the unix socket or the local app set it) and an asking
    /// mode bring it back.
    pub(crate) fn note_mode(&self, session: &Session, restore: bool) {
        let meta = session.meta();
        if self.web_modes().session_asks(&meta) {
            if restore && session.web_control_ended.swap(false, Ordering::SeqCst) {
                self.append(session, "mux", "remote_control_restored", json!({}));
            }
            return;
        }
        if !session.web_control_ended.swap(true, Ordering::SeqCst) {
            let mode = crate::web_modes::mode_of(&meta);
            tracing::warn!(session = %session.id, ?mode, "the session left the asking-mode table: Web control ends");
            self.append(session, "mux", "remote_control_ended", json!({"mode": mode}));
        }
    }

    /// Whether a Web connection may still control `session` (prompt, answer
    /// a permission, change its mode or options).
    pub(crate) fn web_control_check(&self, session: &Session) -> Result<(), RpcError> {
        if session.web_control_ended.load(Ordering::SeqCst) {
            let meta = session.meta();
            let mode = crate::web_modes::mode_of(&meta);
            return Err(RpcError::new(
                -32000,
                format!(
                    "Web control of this session ended: its mode {} is not in the asking-mode table; the local user or the local app can set an asking mode again",
                    mode.as_deref().unwrap_or("(unknown)")
                ),
            )
            .with_data(json!({"reason": "remote.mode_left_asking_table", "mode": mode})));
        }
        Ok(())
    }
}
