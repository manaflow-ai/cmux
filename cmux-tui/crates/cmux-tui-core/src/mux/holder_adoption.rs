//! A restarted daemon re-attaches the terminals the holder kept running
//! (`holder_runtime`, terminal-host-model-DESIGN.md section 5).
//!
//! A holder terminal has no host record, so the startup pass
//! (`adopt_terminal_hosts`) reaches it in its "no record" loop. There the
//! holder is asked first: if it still runs the terminal id, the row moves to
//! adopting, a surface re-attaches from the holder's ring and the usual
//! adoption commit places it; otherwise the terminal ended as before.

use super::*;

impl Mux {
    /// Re-attach `terminal` from the holder, or record its end when the
    /// holder does not run it (`mark_terminal_ended`, reason
    /// `missing-host-record`).
    pub(in crate::mux) fn adopt_from_holder_or_end(
        self: &Arc<Self>,
        terminal: &RegistryTerminal,
        options: &SurfaceOptions,
    ) -> anyhow::Result<()> {
        match self.adopt_from_holder(terminal, options) {
            Ok(true) => return Ok(()),
            Ok(false) => {}
            Err(error) => {
                eprintln!(
                    "cmux-tui: re-attach terminal {} from the holder: {error:#}",
                    terminal.terminal_id
                );
            }
        }
        self.mark_terminal_ended(
            &terminal.terminal_id,
            "terminal-record-missing",
            "missing-host-record",
            options,
        )
    }

    #[cfg(not(unix))]
    fn adopt_from_holder(&self, _: &RegistryTerminal, _: &SurfaceOptions) -> anyhow::Result<bool> {
        Ok(false)
    }

    /// After the startup pass re-attached every terminal it could: end the
    /// holder's other terminals, which no surface will ever claim. Starts
    /// no holder.
    #[cfg(unix)]
    pub(in crate::mux) fn release_unclaimed_holder_terminals(&self, options: &SurfaceOptions) {
        let Some(host_root) = options.terminal_host_root.as_deref() else { return };
        if !crate::holder_runtime::HolderService::may_run(host_root) {
            return;
        }
        match crate::holder_runtime::HolderService::for_root(host_root) {
            Ok(service) => service.release_unclaimed(),
            Err(error) => eprintln!("cmux-tui: reach the terminal holder: {error}"),
        }
    }

    #[cfg(not(unix))]
    pub(in crate::mux) fn release_unclaimed_holder_terminals(&self, _: &SurfaceOptions) {}

    #[cfg(unix)]
    fn adopt_from_holder(
        self: &Arc<Self>,
        terminal: &RegistryTerminal,
        options: &SurfaceOptions,
    ) -> anyhow::Result<bool> {
        let (Some(host_root), Some(incarnation)) =
            (options.terminal_host_root.clone(), terminal.incarnation.clone())
        else {
            return Ok(false);
        };
        let Some(id) = TerminalId::from_hex(&terminal.terminal_id) else {
            return Ok(false);
        };
        if terminal.lifecycle != TerminalLifecycle::Running
            || !crate::holder_runtime::HolderService::may_run(&host_root)
            || !crate::holder_runtime::HolderService::for_root(&host_root)?.lists(id.as_bytes())
        {
            return Ok(false);
        }
        self.transition_terminal_lifecycle(
            "terminal-adopting",
            "holder-terminal-adoption",
            &terminal.terminal_id,
            TerminalLifecycle::Adopting,
            Some(&incarnation),
        )?;
        let binding = self.restored_terminal_binding(&terminal.terminal_id)?;
        let placement = binding.as_ref().and_then(|binding| binding.placements.first().cloned());
        let surface = Surface::adopt_on_holder(crate::surface::HolderAdoption {
            id: placement.as_ref().map(|(slot, _)| *slot).unwrap_or_else(|| self.next_id()),
            opts: options.clone(),
            mux: Arc::downgrade(self),
            host_root,
            identity: TerminalHostIdentity {
                terminal_id: terminal.terminal_id.clone(),
                incarnation: incarnation.clone(),
            },
            terminal_public_id: binding.map(|binding| binding.public_id),
            resource_identity: placement.map(|(_, identity)| identity),
            cell_pixels: self.cell_pixel_creation_size(),
        })?;
        let Some(surface) = surface else { return Ok(false) };
        self.finish_terminal_adoption(&terminal.terminal_id, &incarnation, surface.clone())?;
        self.reap_if_dead(&surface);
        Ok(true)
    }
}
