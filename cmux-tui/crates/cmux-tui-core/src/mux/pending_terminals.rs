//! Terminals whose host may still run while this daemon has no runtime for
//! them (R41, plans/cmux-next/durable-sessions.md section 7): a host still
//! being adopted after a restart, or one whose record this build cannot read.
//! Their tabs are not dead. Also the typed ends of surfaceless ended
//! terminals that the tab JSON reports.

use super::*;

impl Mux {
    /// Terminals whose tabs must not read as dead while they have no runtime
    /// surface ([`PendingTerminal`]), keyed by public terminal id.
    pub(crate) fn pending_terminals_snapshot(&self) -> HashMap<String, PendingTerminal> {
        self.pending_terminals
            .lock()
            .unwrap()
            .iter()
            .map(|(public_id, (_, pending))| (public_id.clone(), pending.clone()))
            .collect()
    }

    /// Typed ends of surfaceless ended terminals, keyed by public terminal id.
    pub(crate) fn terminal_ends_snapshot(&self) -> HashMap<String, Value> {
        self.terminal_ends.lock().unwrap().clone()
    }

    /// Whether a terminal's host may run while it has no runtime here.
    pub(crate) fn terminal_is_pending(&self, terminal_id: &str) -> bool {
        self.pending_terminals.lock().unwrap().values().any(|(id, _)| id == terminal_id)
    }

    /// Whether a pending terminal may be closed. An adopting host speaks this
    /// build's protocol and is ended by the close. An unadoptable one is ended
    /// only with proof that its recorded PID is its live host; without proof
    /// the close still removes the tab (a tab the user cannot remove is
    /// worse), keeps the host record, and logs that the host may still run.
    pub(crate) fn pending_terminal_closable(&self, terminal_id: &str) -> bool {
        self.terminal_is_pending(terminal_id)
    }

    /// After a committed close: forget the terminal's recorded end, and end
    /// the host of a pending terminal (it has a host but no runtime here).
    pub(super) fn after_terminal_close(
        &self,
        public_id: &TerminalPublicId,
        terminal_id: &str,
        result: &Value,
        pending: bool,
    ) {
        self.forget_terminal_end(public_id.as_str());
        if pending {
            self.terminate_discovered_terminal_host(terminal_id, result["incarnation"].as_str());
        }
    }

    /// Drop a stale `Adopting` marker when an adoption thread ends.
    #[cfg(unix)]
    pub(super) fn clear_adopting_marker(&self, terminal_id: &str) {
        self.pending_terminals
            .lock()
            .unwrap()
            .retain(|_, (id, pending)| id != terminal_id || *pending != PendingTerminal::Adopting);
    }

    /// Forget the recorded end of a terminal that is gone (closed).
    pub(crate) fn forget_terminal_end(&self, public_id: &str) {
        self.terminal_ends.lock().unwrap().remove(public_id);
    }

    /// Mark a terminal pending. Takes the registry lock briefly to resolve
    /// its public id; the caller must not hold the registry or state lock.
    #[cfg(unix)]
    pub(super) fn set_pending_terminal(&self, terminal_id: &str, pending: PendingTerminal) {
        let public_id = self.workspace_registry.lock().unwrap().terminal_resource_id(terminal_id);
        let Ok(Some(public_id)) = public_id else { return };
        self.pending_terminals
            .lock()
            .unwrap()
            .insert(public_id.as_str().to_string(), (terminal_id.to_string(), pending));
    }

    /// Forget a pending marker. Returns whether one was present. A respawn's
    /// marker stays: only its worker clears it.
    #[cfg(unix)]
    pub(super) fn clear_pending_terminal(&self, terminal_id: &str) -> bool {
        let mut pending = self.pending_terminals.lock().unwrap();
        let before = pending.len();
        pending
            .retain(|_, (id, marker)| id != terminal_id || *marker == PendingTerminal::Respawning);
        pending.len() != before
    }

    /// Whether a respawn of `terminal_id` (L2) is under way.
    #[cfg(unix)]
    pub(super) fn terminal_is_respawning(&self, terminal_id: &str) -> bool {
        self.pending_terminals
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .values()
            .any(|(id, marker)| id == terminal_id && *marker == PendingTerminal::Respawning)
    }

    /// Remember the typed end of an ended terminal from its durable receipt,
    /// for tabs that keep showing it without a runtime surface (R41).
    #[cfg(unix)]
    pub(super) fn record_terminal_end(&self, terminal_id: &str) {
        let (terminal, public_id) = {
            let registry = self.workspace_registry.lock().unwrap();
            (registry.terminal_record(terminal_id), registry.terminal_resource_id(terminal_id))
        };
        let (Ok(Some(terminal)), Ok(Some(public_id))) = (terminal, public_id) else { return };
        if terminal.lifecycle != TerminalLifecycle::Exited {
            return;
        }
        let end = TerminalEnd::from_receipt(terminal.exit.as_ref()).wire_json();
        self.terminal_ends.lock().unwrap().insert(public_id.as_str().to_string(), end);
    }

    /// Watch an unadoptable host: when its live marker frees (the host
    /// exited, by itself or by a close), end the terminal with the host's
    /// exit sidecar when it left one, and remove its artifacts.
    #[cfg(unix)]
    fn watch_unadoptable_terminal_host(
        self: &Arc<Self>,
        options: SurfaceOptions,
        record: crate::terminal_host_runtime::UnadoptableTerminalHostRecord,
    ) {
        let mux = Arc::downgrade(self);
        let name = format!("terminal-unadoptable-{}", record.terminal_id);
        let spawned = std::thread::Builder::new().name(name).spawn(move || {
            if let Err(error) =
                crate::terminal_host_runtime::wait_for_unadoptable_terminal_host_exit(&record)
            {
                eprintln!(
                    "cmux-tui: could not watch the unadoptable host of terminal {}: {error:#}",
                    record.terminal_id
                );
                return;
            }
            let Some(mux) = mux.upgrade() else { return };
            if mux.shutting_down.load(Ordering::Acquire) {
                return;
            }
            if let Err(error) = mux.mark_terminal_ended(
                &record.terminal_id,
                "terminal-unadoptable-host-ended",
                "unadoptable-host-ended",
                &options,
            ) {
                eprintln!(
                    "cmux-tui: could not end terminal {} after its unadoptable host exited: \
                     {error:#}",
                    record.terminal_id
                );
            }
            mux.emit(MuxEvent::TreeChanged);
        });
        if spawned.is_err() {
            eprintln!("cmux-tui: no thread to watch an unadoptable terminal host");
        }
    }

    /// A record this build cannot read belongs to a host that may still run
    /// its shell (a newer record version after a rollback). Never report that
    /// terminal ended: keep it visible as unadoptable and watch its host.
    #[cfg(unix)]
    pub(super) fn mark_unadoptable_terminal_hosts(
        self: &Arc<Self>,
        options: &SurfaceOptions,
        handled_terminals: &mut HashSet<String>,
    ) -> anyhow::Result<()> {
        let unadoptable = match options.terminal_host_root.as_deref() {
            Some(root) => {
                crate::terminal_host_runtime::load_unadoptable_terminal_host_records(root)?
            }
            None => Vec::new(),
        };
        for record in unadoptable {
            if handled_terminals.contains(&record.terminal_id) {
                continue;
            }
            let lifecycle = self
                .workspace_registry
                .lock()
                .unwrap()
                .terminal_record(&record.terminal_id)?
                .map(|terminal| terminal.lifecycle);
            if matches!(
                lifecycle,
                None | Some(TerminalLifecycle::Exited | TerminalLifecycle::Tombstoned)
            ) {
                continue;
            }
            eprintln!(
                "cmux-tui: terminal {} has a host record this build cannot adopt \
                 (record_version {:?}): {}",
                record.terminal_id, record.record_version, record.reason
            );
            self.set_pending_terminal(
                &record.terminal_id,
                PendingTerminal::Unadoptable { record_version: record.record_version },
            );
            handled_terminals.insert(record.terminal_id.clone());
            self.watch_unadoptable_terminal_host(options.clone(), record);
        }
        Ok(())
    }
}

/// End the hosts of `terminal_id`'s unreadable records under `root`, with
/// proof only; without proof the host may still run and its record stays.
#[cfg(unix)]
pub(super) fn terminate_unadoptable_hosts_in(root: &Path, terminal_id: &str) {
    if let Ok(unadoptable) =
        crate::terminal_host_runtime::load_unadoptable_terminal_host_records(root)
    {
        for record in unadoptable.iter().filter(|record| record.terminal_id == terminal_id) {
            if !matches!(
                crate::terminal_host_runtime::terminate_unadoptable_terminal_host(record),
                Ok(true)
            ) {
                eprintln!(
                    "cmux-tui: closed terminal {terminal_id} without proof its unadoptable \
                     host ended; the host may still run; its record stays at {}",
                    record.record_path.display()
                );
            }
        }
    }
}
