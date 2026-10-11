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
        self.terminal_loss_causes.lock().unwrap_or_else(PoisonError::into_inner).forget(public_id);
    }

    /// Remember why a terminal's host was lost, for its tab's `end.cause`.
    #[cfg(unix)]
    pub(super) fn record_terminal_loss_cause(&self, public_id: &str, cause: Value) {
        self.terminal_loss_causes
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .record(public_id, cause);
    }

    /// Causes of host losses, keyed by public terminal id.
    pub(crate) fn terminal_loss_causes_snapshot(&self) -> HashMap<String, Value> {
        self.terminal_loss_causes.lock().unwrap_or_else(PoisonError::into_inner).snapshot()
    }

    /// Mark a terminal pending. Takes the registry lock briefly to resolve
    /// its public id; the caller must not hold the registry or state lock.
    #[cfg(unix)]
    /// Returns whether the marker was set (false: the public id is unknown).
    pub(super) fn set_pending_terminal(&self, terminal_id: &str, pending: PendingTerminal) -> bool {
        let public_id = self.workspace_registry.lock().unwrap().terminal_resource_id(terminal_id);
        let Ok(Some(public_id)) = public_id else { return false };
        self.pending_terminals
            .lock()
            .unwrap()
            .insert(public_id.as_str().to_string(), (terminal_id.to_string(), pending));
        true
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
        if end["kind"] == "host_lost" {
            let root = self.surface_options.lock().unwrap_or_else(PoisonError::into_inner);
            let root = root.terminal_host_root.clone();
            self.terminal_loss_causes.lock().unwrap_or_else(PoisonError::into_inner).restore(
                root.as_deref(),
                terminal_id,
                public_id.as_str(),
            );
        }
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

    /// A live host refused every protocol this build offers on at least
    /// [`NO_COMMON_PROTOCOL_REFUSALS`] adoptions over at least
    /// [`NO_COMMON_PROTOCOL_MIN_SPAN`], with no other outcome between them:
    /// retrying cannot adopt it. Keep the terminal visible as unadoptable
    /// instead of adopting forever, watch its host, and push the change.
    ///
    /// A host of this build also closes an owner hello without HostHello
    /// when it cannot start a client thread (descriptor or memory pressure)
    /// or denies the owner token; the time span keeps such a passing refusal
    /// from making a healthy terminal unadoptable. An unadoptable terminal is
    /// not adopted again by this daemon; close still ends its host with proof.
    ///
    /// Returns whether the terminal is now unadoptable, so adoption must stop.
    #[cfg(unix)]
    pub(super) fn refused_all<T>(
        self: &Arc<Self>,
        streak: &mut RefusalStreak,
        now: Instant,
        adopted: &anyhow::Result<T>,
        options: &SurfaceOptions,
        record_path: &Path,
        record: &crate::terminal_host_runtime::TerminalHostRecord,
    ) -> bool {
        let refused = matches!(
            adopted,
            Err(error) if crate::terminal_host_runtime::is_no_common_host_protocol(error)
        );
        if !streak.record(refused, now)
            || terminal_host_record_liveness(record_path, record) != TerminalHostLiveness::Live
        {
            return false;
        }
        let record =
            crate::terminal_host_runtime::UnadoptableTerminalHostRecord::with_no_common_protocol(
                record_path,
                record,
            );
        if !self.set_pending_terminal(
            &record.terminal_id,
            PendingTerminal::Unadoptable { record_version: record.record_version },
        ) {
            // Without a marker the tab would read exited: keep adopting.
            return false;
        }
        eprintln!(
            "cmux-tui: terminal {} has a live host this build cannot adopt \
             (record_version {:?}): {}",
            record.terminal_id, record.record_version, record.reason
        );
        self.watch_unadoptable_terminal_host(options.clone(), record);
        self.emit(MuxEvent::TreeChanged);
        true
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

/// Adoptions of a live host refused for want of a common protocol, in a row,
/// before its terminal is unadoptable. One refusal could be a host that
/// closed the connection while exiting; the live marker then frees and the
/// watcher ends the terminal with the host's real status.
#[cfg(unix)]
pub(super) const NO_COMMON_PROTOCOL_REFUSALS: u32 = 3;

/// The shortest time from the first to the last of those refusals: a host
/// of this build that refuses a hello under passing pressure recovers
/// within it (see [`Mux::refused_all`]).
#[cfg(unix)]
pub(super) const NO_COMMON_PROTOCOL_MIN_SPAN: Duration = Duration::from_secs(10);

/// Refused adoptions in a row since the first of them.
#[cfg(unix)]
#[derive(Debug, Default)]
pub(super) struct RefusalStreak {
    count: u32,
    since: Option<Instant>,
}

#[cfg(unix)]
impl RefusalStreak {
    /// Record one adoption outcome at `now`. Returns whether the streak is
    /// long enough to call the host unadoptable.
    pub(super) fn record(&mut self, refused: bool, now: Instant) -> bool {
        if !refused {
            *self = Self::default();
            return false;
        }
        self.count += 1;
        let since = *self.since.get_or_insert(now);
        self.count >= NO_COMMON_PROTOCOL_REFUSALS
            && now.saturating_duration_since(since) >= NO_COMMON_PROTOCOL_MIN_SPAN
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

/// Adopt a host to send it Terminate. A host with no protocol in common
/// cannot take Terminate: end it with proof that the recorded PID is its
/// live host and return `None`; the caller's cleanup removes the record
/// once the live marker frees.
#[cfg(unix)]
pub(super) fn adopt_host_to_terminate(
    record: crate::terminal_host_runtime::TerminalHostRecord,
    record_path: std::path::PathBuf,
) -> Option<crate::terminal_host_runtime::HostAttachment> {
    match crate::terminal_host_runtime::adopt_terminal_host(record.clone(), record_path.clone()) {
        Ok(host) => Some(host),
        Err(error) => {
            if crate::terminal_host_runtime::is_no_common_host_protocol(&error) {
                let unadoptable =
                    crate::terminal_host_runtime::UnadoptableTerminalHostRecord::with_no_common_protocol(
                        &record_path,
                        &record,
                    );
                let _ =
                    crate::terminal_host_runtime::terminate_unadoptable_terminal_host(&unadoptable);
            }
            None
        }
    }
}

#[cfg(all(test, unix))]
mod tests;
