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
//!
//! The pass asks the holder one time ([`HolderPass`]) and gives it one
//! deadline for all its terminals together (`holder_late::ADOPTION_BOUND`).
//! A holder that took the connect and did not answer in that time, or that
//! ended the connect before its answer, may still run every shell: its
//! terminals are not ended. They stay `adopting` and re-attach after the
//! start, when the holder answers (mux/holder_late.rs). So does a terminal
//! whose turn in the pass came after the deadline. A terminal ends at a
//! start only when the holder answered and does not run it, or when no
//! holder can be asked (a refused connect, a missing socket, a holder that
//! refuses this daemon, or another error of the ask).
//!
//! A start does not wait for a creation that a crash interrupted when its
//! terminal is kept, for the late thread or for the next start
//! (`Mux::late_holder_terminals`): such a creation stays pending.

use super::*;
#[cfg(unix)]
use crate::holder_runtime::{HolderReach, HolderService};
#[cfg(unix)]
use crate::mux::holder_late::{ADOPTION_BOUND, HolderClock, holder_clock};

/// One start's dealings with the terminal holder: one ask, and one deadline
/// for the ask and every re-attach together.
#[cfg(unix)]
pub(in crate::mux) struct HolderPass {
    clock: Arc<dyn HolderClock>,
    /// When the start stops waiting for the holder; set at the ask.
    deadline: Option<Instant>,
    /// What the one ask found; `None` until a terminal needs the holder.
    reach: Option<HolderReach>,
    /// How many terminals had their turn before the deadline.
    in_time: usize,
    /// The terminals kept for the late thread, by host id.
    late: Vec<String>,
}

/// No terminal holder runs off unix.
#[cfg(not(unix))]
pub(in crate::mux) struct HolderPass;

#[cfg(unix)]
impl HolderPass {
    /// What the holder of `host_root` said to this start's one ask. The
    /// first call asks, and waits at most `ADOPTION_BOUND` for the answer.
    fn reach(&mut self, host_root: &Path) -> HolderReach {
        if let Some(reach) = self.reach {
            return reach;
        }
        let clock = self.clock.clone();
        let deadline = clock.now() + ADOPTION_BOUND;
        self.deadline = Some(deadline);
        let reach = match HolderService::for_root(host_root) {
            Ok(service) => service
                .reach(&|| deadline.saturating_duration_since(clock.now()).min(clock.read_slice())),
            Err(error) => {
                eprintln!("cmux-tui: reach the terminal holder: {error}");
                HolderReach::Absent
            }
        };
        self.reach = Some(reach);
        reach
    }

    /// Whether the start stopped waiting for the holder.
    fn past_deadline(&self) -> bool {
        self.deadline.is_some_and(|deadline| self.clock.now() >= deadline)
    }
}

impl Mux {
    /// The start pass's dealings with the terminal holder, before its ask.
    #[cfg(unix)]
    pub(in crate::mux) fn holder_pass(&self, options: &SurfaceOptions) -> HolderPass {
        HolderPass {
            clock: holder_clock(options.terminal_host_root.as_deref()),
            deadline: None,
            reach: None,
            in_time: 0,
            late: Vec::new(),
        }
    }

    #[cfg(not(unix))]
    pub(in crate::mux) fn holder_pass(&self, _: &SurfaceOptions) -> HolderPass {
        HolderPass
    }

    /// Re-attach `terminal` from the holder, or record its end when the
    /// holder does not run it (`mark_terminal_ended`, reason
    /// `missing-host-record`). A terminal whose holder did not answer this
    /// start's ask in time, or whose turn came after the deadline, is kept
    /// for the late thread instead (mux/holder_late.rs).
    pub(in crate::mux) fn adopt_from_holder_or_end(
        self: &Arc<Self>,
        terminal: &RegistryTerminal,
        options: &SurfaceOptions,
        pass: &mut HolderPass,
    ) -> anyhow::Result<()> {
        #[cfg(unix)]
        if let Some(host_root) = Self::holder_candidate(terminal, options) {
            match pass.reach(host_root) {
                HolderReach::Linked if !pass.past_deadline() => {
                    pass.in_time += 1;
                    if self.adopt_from_reached_holder_or_end(terminal, options)? {
                        // Kept for the next start: this start does not wait
                        // for a creation of it either.
                        self.keep_holder_terminal(&terminal.terminal_id);
                    }
                    return Ok(());
                }
                // A holder that ended the connect before its answer, or
                // that refused it because another connect took its link,
                // may still run the shell, as a silent one: the late thread
                // connects again. What ends the terminal is `Absent`: a
                // connect that no holder takes, a holder that refuses this
                // daemon, or another error of the ask.
                HolderReach::Linked | HolderReach::Silent | HolderReach::Dropped => {
                    // The tab shows adopting until the late thread
                    // re-attaches the terminal.
                    self.set_pending_terminal(&terminal.terminal_id, PendingTerminal::Adopting);
                    self.keep_holder_terminal(&terminal.terminal_id);
                    pass.late.push(terminal.terminal_id.clone());
                    return Ok(());
                }
                // No holder runs its shell, as before this start.
                HolderReach::Absent => {}
            }
        }
        #[cfg(not(unix))]
        let _ = pass;
        self.mark_terminal_ended(
            &terminal.terminal_id,
            "terminal-record-missing",
            "missing-host-record",
            options,
        )
    }

    /// The host root of the holder that may run `terminal`: a running or
    /// adopting row (one a previous owner left adopting re-attaches like a
    /// running one) with an incarnation, in a session whose holder socket
    /// exists. `None` for every other row: no holder runs it.
    #[cfg(unix)]
    fn holder_candidate<'a>(
        terminal: &RegistryTerminal,
        options: &'a SurfaceOptions,
    ) -> Option<&'a Path> {
        let host_root = options.terminal_host_root.as_deref()?;
        (terminal.incarnation.is_some()
            && TerminalId::from_hex(&terminal.terminal_id).is_some()
            && matches!(
                terminal.lifecycle,
                TerminalLifecycle::Running | TerminalLifecycle::Adopting
            )
            && HolderService::may_run(host_root))
        .then_some(host_root)
    }

    /// The end of the pass's holder part. With every terminal re-attached or
    /// ended in time, the holder ends the terminals whose row ended
    /// (`release_unclaimed_holder_terminals`). With a terminal kept for the
    /// late thread, or a holder that has not answered, the late thread does
    /// both after the start.
    #[cfg(unix)]
    pub(in crate::mux) fn finish_holder_pass(
        self: &Arc<Self>,
        mut pass: HolderPass,
        options: &SurfaceOptions,
    ) {
        let Some(host_root) = options.terminal_host_root.as_deref() else { return };
        if !HolderService::may_run(host_root) {
            return;
        }
        let reach = pass.reach(host_root);
        if pass.in_time + pass.late.len() > 0 {
            eprintln!(
                "cmux-tui: terminal holder at this start ({reach:?}, bound {} ms): {} of {} \
                 terminals had their turn in time, {} re-attach after the start",
                ADOPTION_BOUND.as_millis(),
                pass.in_time,
                pass.in_time + pass.late.len(),
                pass.late.len()
            );
        }
        match reach {
            HolderReach::Linked if pass.late.is_empty() => {
                self.release_unclaimed_holder_terminals(options);
            }
            HolderReach::Linked | HolderReach::Silent | HolderReach::Dropped => {
                self.adopt_late_holder_terminals(options.clone(), pass.clock, pass.late);
            }
            HolderReach::Absent => {}
        }
    }

    /// Put `terminal_id` with the terminals this start does not wait for
    /// (`late_holder_terminals`).
    #[cfg(unix)]
    fn keep_holder_terminal(&self, terminal_id: &str) {
        self.late_holder_terminals
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(terminal_id.to_string());
    }

    #[cfg(not(unix))]
    pub(in crate::mux) fn finish_holder_pass(self: &Arc<Self>, _: HolderPass, _: &SurfaceOptions) {}

    /// Re-attach `terminal` from a holder that answered, or record its end
    /// when that holder does not run it. `true` when neither happened: the
    /// re-attach failed, the holder keeps the shell, and the row stays
    /// `adopting` for the next start.
    #[cfg(unix)]
    pub(in crate::mux) fn adopt_from_reached_holder_or_end(
        self: &Arc<Self>,
        terminal: &RegistryTerminal,
        options: &SurfaceOptions,
    ) -> anyhow::Result<bool> {
        // Asked before the re-attach, which takes the holder's entry.
        let held = self.holder_lists(terminal, options);
        match self.adopt_from_holder(terminal, options) {
            Ok(true) => return Ok(false),
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
                    return Ok(true);
                }
            }
        }
        self.mark_terminal_ended(
            &terminal.terminal_id,
            "terminal-record-missing",
            "missing-host-record",
            options,
        )?;
        Ok(false)
    }

    /// Whether `terminal_id`'s row is still running or adopting (a row that
    /// cannot be read counts as live: the shell is kept, the safe side).
    #[cfg(unix)]
    pub(in crate::mux) fn row_still_live(&self, terminal_id: &str) -> bool {
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
        HolderService::may_run(host_root)
            && HolderService::for_root(host_root).is_ok_and(|service| service.lists(id.as_bytes()))
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
        if !HolderService::may_run(host_root) {
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
        match HolderService::for_root(host_root) {
            Ok(service) => service.release_unclaimed(ended),
            Err(error) => eprintln!("cmux-tui: reach the terminal holder: {error}"),
        }
    }

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
            || !HolderService::may_run(&host_root)
            || !HolderService::for_root(&host_root)?.lists(id.as_bytes())
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
