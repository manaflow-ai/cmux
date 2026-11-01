//! A restarted daemon re-attaches the terminals the holder kept running
//! (`holder_runtime`, terminal-host-model-DESIGN.md section 5).
//!
//! A holder terminal has no host record, so the startup pass
//! (`adopt_terminal_hosts`) reaches it in its "no record" loop. There the
//! holder is asked first: if it still runs the terminal id, the row moves to
//! adopting, a surface re-attaches from the holder's ring and the usual
//! adoption commit places it; otherwise the terminal ended as before.
//!
//! A new owner never ends a shell the holder still runs (QUIT P0, 2026-11-01:
//! a version handoff at the app's reopen lost the person's terminals). A row
//! a previous owner left `adopting` (it stopped mid-adoption) re-attaches like
//! a running one. A re-attach that fails keeps the row and the holder keeps
//! the shell: the next start tries again. After the pass the holder ends only
//! terminals whose row ended (exited or tombstoned: the shell exited, or the
//! person closed the tab); a terminal the registry has no row for stays held.

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
        // Asked before the re-attach, which takes the holder's entry.
        let held = self.holder_lists(terminal, options);
        match self.adopt_from_holder(terminal, options) {
            Ok(true) => return Ok(()),
            Ok(false) => {}
            Err(error) => {
                eprintln!(
                    "cmux-tui: re-attach terminal {} from the holder: {error:#}",
                    terminal.terminal_id
                );
                // The holder still runs this shell and its row has not ended
                // (read again: a re-attach that got as far as a dead surface
                // records the exit): keep the row and the shell for the next
                // start, never end it here.
                if held && self.row_still_live(&terminal.terminal_id) {
                    eprintln!(
                        "cmux-tui: keep holder terminal {} for the next start",
                        terminal.terminal_id
                    );
                    // The tab shows adopting, not a live terminal that takes no
                    // input, until a start re-attaches it.
                    self.set_pending_terminal(&terminal.terminal_id, PendingTerminal::Adopting);
                    return Ok(());
                }
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

    #[cfg(not(unix))]
    fn holder_lists(&self, _: &RegistryTerminal, _: &SurfaceOptions) -> bool {
        false
    }

    /// Whether `terminal_id`'s row is still running or adopting (a row that
    /// cannot be read counts as live: the shell is kept, the safe side).
    fn row_still_live(&self, terminal_id: &str) -> bool {
        let Ok(registry) = self.workspace_registry.lock() else { return true };
        match registry.terminal_record(terminal_id) {
            Ok(Some(row)) => {
                matches!(row.lifecycle, TerminalLifecycle::Running | TerminalLifecycle::Adopting)
            }
            Ok(None) => false,
            Err(_) => true,
        }
    }

    /// Whether the holder still runs `terminal` (it listed it when this owner
    /// first reached it). An unreachable holder lists nothing.
    #[cfg(unix)]
    fn holder_lists(&self, terminal: &RegistryTerminal, options: &SurfaceOptions) -> bool {
        let (Some(host_root), Some(id)) =
            (options.terminal_host_root.as_deref(), TerminalId::from_hex(&terminal.terminal_id))
        else {
            return false;
        };
        crate::holder_runtime::HolderService::may_run(host_root)
            && crate::holder_runtime::HolderService::for_root(host_root)
                .is_ok_and(|service| service.lists(id.as_bytes()))
    }

    /// After the startup pass re-attached every terminal it could: end the
    /// holder's terminals whose row ended (the shell exited, or the person
    /// closed the tab: exited or tombstoned), which no surface will ever
    /// claim. Every other unclaimed terminal stays held: a running or
    /// adopting row the pass could not re-attach, or a terminal the
    /// registry has no row for, is never ended by a start. Starts no holder.
    #[cfg(unix)]
    pub(in crate::mux) fn release_unclaimed_holder_terminals(&self, options: &SurfaceOptions) {
        let Some(host_root) = options.terminal_host_root.as_deref() else { return };
        if !crate::holder_runtime::HolderService::may_run(host_root) {
            return;
        }
        let ended = |id: &[u8; 16]| -> bool {
            let terminal_id = TerminalId::from_bytes(*id).to_hex();
            // No row, or an unreadable one, keeps the shell (the safe side).
            let Ok(registry) = self.workspace_registry.lock() else { return false };
            registry.terminal_record(&terminal_id).ok().flatten().is_some_and(|row| {
                matches!(row.lifecycle, TerminalLifecycle::Exited | TerminalLifecycle::Tombstoned)
            })
        };
        match crate::holder_runtime::HolderService::for_root(host_root) {
            Ok(service) => service.release_unclaimed(ended),
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
        // A row a previous owner left adopting (it stopped mid-adoption)
        // re-attaches like a running one.
        if !matches!(terminal.lifecycle, TerminalLifecycle::Running | TerminalLifecycle::Adopting)
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
