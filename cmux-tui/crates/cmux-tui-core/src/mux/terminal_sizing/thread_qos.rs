//! A terminal's threads follow its visibility (p02-threads-236, feature
//! `hiddenTerminalQos`). The signal is the app's own: a view that hides (a
//! parked tab, a workspace switched away) sends `set-size-counts
//! counts:false` (`TerminalAttachment.sendHidden`), or releases its size on
//! a daemon without in-place hiding, and a closed view detaches. Each of
//! those publishes the terminal's size state, and a terminal with no view
//! that counts toward its size is one no one sees. Only the terminals whose
//! size state changed are visited: O(changed), never O(session).

use super::*;
use crate::mux::client_sizing_state::SizeStatePublication;

impl Mux {
    /// Runs each published terminal's threads at the echo class while a
    /// view that counts toward its size shows it, at utility while none
    /// does. Call without the sizing lock.
    pub(super) fn set_terminal_threads_shown(&self, publications: &[SizeStatePublication]) {
        for publication in publications {
            let shown = publication.state.participants.iter().any(|participant| participant.counts);
            if let Some(surface) = self.surface(publication.runtime) {
                surface.set_threads_shown(shown);
            }
        }
    }

    #[cfg(test)]
    pub(crate) fn set_terminal_threads_follow_visibility_for_test(&self, follow: bool) {
        self.client_sizing.lock().unwrap().threads_follow_visibility = follow;
    }
}
