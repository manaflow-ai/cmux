//! A terminal's threads follow its visibility (feature
//! `hiddenTerminalQos`). A view shows the terminal while it has a viewport
//! and has not said it is hidden. The app's hidden view sends
//! `set-size-counts counts:false` by its lease (`TerminalAttachment.sendHidden`),
//! which marks it hidden (`SizingMember::hidden`); a daemon without in-place
//! hiding gets `release-attached-view-size`, which drops the viewport; a
//! closed view detaches. A `counts:false` by any other selector (the TUI's
//! "counts toward size", tmux `ignore-size`) is a sizing choice of a view
//! someone still watches, so it keeps the class. Only the terminals marked
//! since the last pass are visited: O(changed), never O(session).
//!
//! The class is requested under the sizing lock from the state current at
//! that moment, so of two racing publications the later one always requests
//! the later state; the host's copy is sent after the lock and reads the
//! class again (`PtySurface::send_host_thread_qos`).

use super::*;

impl ClientSizingState {
    /// Whether a view shows terminal `runtime`: one with a viewport whose
    /// view did not say it is hidden.
    fn terminal_shown(&self, runtime: SurfaceId) -> bool {
        let Some(entry) = self.terminal_sizing.get(&runtime) else { return false };
        entry.engine.state().participants.iter().any(|participant| {
            let participant = &participant.participant;
            participant.viewport.is_some()
                && !entry.members.get(&participant.id).is_some_and(|member| member.hidden)
        })
    }
}

impl Mux {
    /// Requests each marked terminal's class from its views now: the echo
    /// class while one shows it, utility while none does. Call under the
    /// sizing lock; it only stores the class. Returns the terminals whose
    /// class changed, whose hosts the caller tells after the lock
    /// (`Surface::send_thread_qos_to_host`).
    pub(super) fn request_terminal_threads_shown(
        &self,
        sizing: &mut ClientSizingState,
    ) -> Vec<Arc<Surface>> {
        std::mem::take(&mut sizing.pending_thread_visibility)
            .into_iter()
            .filter_map(|runtime| {
                let shown = sizing.terminal_shown(runtime);
                let surface = self.surface(runtime)?;
                surface.request_threads_shown(shown).then_some(surface)
            })
            .collect()
    }

    /// `set-size-counts` by a view's own lease: the app's hide
    /// (`counts:false`) and show (`null`). Also marks the view hidden or
    /// shown for its terminal's threads.
    pub fn set_leased_view_size_counts(
        &self,
        surface: SurfaceId,
        participant: &str,
        counts: Option<bool>,
    ) -> Option<bool> {
        self.set_terminal_size_counts_hiding(
            surface,
            participant,
            counts,
            Some(counts == Some(false)),
        )
    }

    /// Sets or clears participant's counts choice and, with `hidden`, marks
    /// its view hidden or shown, in one sizing turn.
    pub(super) fn set_terminal_size_counts_hiding(
        &self,
        surface: SurfaceId,
        participant: &str,
        counts: Option<bool>,
        hidden: Option<bool>,
    ) -> Option<bool> {
        let runtime = self.surface(surface)?.terminal_runtime_id()?;
        self.mutate_terminal_sizing(runtime, |_, sizing| {
            let entry = sizing.terminal_sizing.get_mut(&runtime)?;
            if !entry.engine.contains(participant) {
                return None;
            }
            let changed = entry.engine.set_counts_override(participant, counts);
            sizing.note_size_state(runtime, changed);
            if let Some(hidden) = hidden {
                Self::set_sizing_view_hidden(sizing, runtime, participant, hidden);
            }
            Some(changed)
        })
    }

    /// Marks participant `id`'s view of `runtime` hidden or shown, as its
    /// lease said. True when that changed.
    fn set_sizing_view_hidden(
        sizing: &mut ClientSizingState,
        runtime: SurfaceId,
        id: &str,
        hidden: bool,
    ) -> bool {
        let Some(member) =
            sizing.terminal_sizing.get_mut(&runtime).and_then(|entry| entry.members.get_mut(id))
        else {
            return false;
        };
        if member.hidden == hidden {
            return false;
        }
        member.hidden = hidden;
        sizing.note_thread_visibility(runtime);
        true
    }

    #[cfg(test)]
    pub(crate) fn set_terminal_threads_follow_visibility_for_test(&self, follow: bool) {
        self.client_sizing.lock().unwrap().threads_follow_visibility = follow;
    }
}
