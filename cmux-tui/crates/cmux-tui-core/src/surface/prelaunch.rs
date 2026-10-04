//! Launching a new terminal's host before its creation commits.

use super::*;

impl Surface {
    /// Launch the durable host of a new session-owned terminal without
    /// building its surface, so a caller can launch several hosts in
    /// parallel outside the creation transaction and finish each one with
    /// [`Surface::spawn_prelaunched`] after it. The caller picks the surface
    /// id and tab identity, so a launching placeholder can carry them first. Dropping the result before
    /// then exact-kills the host (the attachment's launch guard); a protocol
    /// v4 host also never starts its child before activation. The host starts
    /// with Kitty graphics disabled; its share of the image budget is applied
    /// once the surface commits. `standby` is a host process started ahead
    /// (R81, the pool's spare); `None` starts one now.
    pub(crate) fn prelaunch_hosted(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        terminal_id: crate::terminal_host::TerminalId,
        resource_identity: TabResourceIdentity,
        cell_pixels: (u16, u16),
        standby: Option<crate::terminal_host_runtime::StandbyTerminalHost>,
    ) -> anyhow::Result<PrelaunchedHost> {
        let root = opts
            .terminal_host_root
            .clone()
            .ok_or_else(|| anyhow::anyhow!("prelaunch needs a terminal host root"))?;
        let (opts, terminal_public_id, kitty_reservation) =
            Self::spawn_prelude(id, opts, &mux, Some(&resource_identity), KittyQuota::AfterCommit)?;
        let initial_kitty_limits = kitty_reservation
            .as_ref()
            .map(crate::mux::KittyImageBudgetReservation::initial_limits)
            .unwrap_or_default();
        let default_colors = mux.upgrade().map(|mux| mux.default_colors()).unwrap_or_default();
        let attachment = crate::terminal_host_runtime::launch_terminal_host_from(
            &opts,
            &root,
            default_colors,
            cell_pixels,
            initial_kitty_limits,
            terminal_id,
            standby,
        )?;
        Ok(PrelaunchedHost {
            id,
            opts,
            attachment,
            kitty_reservation,
            terminal_public_id,
            resource_identity,
        })
    }
}
