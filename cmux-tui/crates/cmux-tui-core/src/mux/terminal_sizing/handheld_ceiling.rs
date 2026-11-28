//! The fixed-grid handheld ceiling: a phone or tablet view that cannot show a
//! grid larger than its own never gets one (docs/shared-terminal-sizing.md,
//! "Phone viewers").
//!
//! Every phone build so far renders the PTY's output into its own grid. Under
//! the default policy (last active) a Mac that was active last keeps the
//! grid when a phone attaches, so the phone drew a wider PTY's output into a
//! narrower grid: rows overprinted and cut, stray characters in the last
//! column (a Claude Code session on the user's TestFlight phone,
//! 2026-10-23). Until a phone shows a larger grid itself (letterbox or pan)
//! and says so with `host-grid-view-v1`, its reported size caps the grid the
//! daemon applies, whoever is active. The published size state stays the
//! engine's decision, like the departed-view hold.

use super::*;

impl Mux {
    /// `target` capped, per dimension, at the viewport of every attached
    /// phone or tablet view of `entry` that has reported one, whose counts
    /// override is not off (a preview), and whose connection does not list
    /// `host-grid-view-v1`. It applies under every policy, `fixed` and a
    /// phone deferring under `priority` included: such a phone misrenders
    /// any larger grid. A relayed phone (a sub-view) is capped unless its
    /// relay lists the capability, so a relay lists it only when every leaf
    /// it forwards shows a larger grid.
    pub(in crate::mux) fn cap_to_fixed_grid_handhelds(
        &self,
        entry: &TerminalSizingEntry,
        target: (u16, u16),
    ) -> (u16, u16) {
        let mut capped = target;
        for id in entry.engine.participant_ids() {
            let Some(participant) = entry.engine.participant(id) else { continue };
            if !participant.device_kind.is_handheld() || participant.counts_override == Some(false)
            {
                continue;
            }
            let Some(viewport) = participant.viewport.map(TerminalGridSize::clamped) else {
                continue;
            };
            let Some(member) = entry.members.get(id) else { continue };
            if self
                .control_clients
                .supports_capability(member.client, crate::server::HOST_GRID_VIEW_CAPABILITY)
            {
                continue;
            }
            capped = (capped.0.min(viewport.cols), capped.1.min(viewport.rows));
        }
        capped
    }
}
