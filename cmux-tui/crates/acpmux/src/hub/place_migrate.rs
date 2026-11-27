//! Part of `Hub`; see `hub/mod.rs`. A chat's pin (`SessionMeta::place_mode`) saved, and the
//! one-time migration that pins every chat older than place modes to this machine
//! (`place_pin.rs` has the rules).

use super::*;
use crate::place_mode::PlaceMode;
use crate::place_pin::{self, Report};

impl Hub {
    /// Stores (or with None clears) `session`'s pin, answered once it is saved.
    pub(crate) fn set_place_mode(
        &self,
        session: &Session,
        mode: Option<PlaceMode>,
    ) -> Result<(), RpcError> {
        session.meta.lock().unwrap_or_else(|e| e.into_inner()).place_mode = mode;
        self.save_meta_answered(session)
    }

    /// The chat's mode now: its pin, else what a chat with none reads as here.
    pub(crate) fn place_mode_of(&self, session: &Session) -> PlaceMode {
        let (stored, created_at) = session.read_meta(|m| (m.place_mode.clone(), m.created_at));
        place_pin::effective(stored, super::host_label(), created_at, place_pin::cutoff())
    }

    /// The migration [`place_pin::start`] asked for, with its `cutoff` (`home` holds the marker
    /// and the older pin file): every chat made before the cutoff with no pin gets its older
    /// pick or this machine. Nothing else in a chat changes. The marker is written only when
    /// every pin was saved; until then such a chat still reads as pinned here (by the cutoff),
    /// and the next start runs it again.
    #[doc(hidden)]
    pub fn migrate_place_modes(&self, home: &std::path::Path, cutoff: u64) -> Report {
        let here = super::host_label();
        let legacy = place_pin::read_legacy(home);
        let mut report = Report { here: here.to_owned(), at: cutoff, ..Report::default() };
        // It runs beside the daemon's start: a chat made meanwhile is new, and stays Auto.
        for session in self.session_handles() {
            let (stored, created_at) = session.read_meta(|m| (m.place_mode.clone(), m.created_at));
            if created_at >= cutoff {
                continue;
            }
            let Some(pin) = place_pin::plan(stored.as_ref(), legacy.get(&session.id), here) else {
                report.kept += 1;
                continue;
            };
            let from_legacy = legacy.contains_key(&session.id);
            match self.set_place_mode(&session, Some(pin)) {
                Ok(()) if from_legacy => report.from_legacy += 1,
                Ok(()) => report.pinned += 1,
                Err(e) => {
                    tracing::warn!(session = %session.id, "place mode migration: {}", e.message);
                    report.failed += 1;
                }
            }
        }
        if report.failed > 0 {
            tracing::warn!(
                ?report,
                "place mode migration: not every pin was saved; next start retries"
            );
            return report;
        }
        if let Err(e) = place_pin::write_marker(home, &report) {
            tracing::warn!("place mode migration: marker not written: {e}");
        }
        tracing::info!(?report, "place modes: every older chat pinned to its machine");
        report
    }
}
