//! Terminal host records: terminating discovered hosts, acknowledging exits, and scheduled host record cleanup.

use super::*;

/// Terminate every host record under `root` for one terminal and
/// acknowledge its exit sidecar.
#[cfg(any(unix, windows))]
pub(super) fn terminate_discovered_terminal_host_in(
    root: &Path,
    terminal_id: &str,
    incarnation: Option<&str>,
) {
    let Ok(records) = crate::terminal_host_runtime::load_terminal_host_records(root) else {
        return;
    };
    for (path, record) in records {
        if record.terminal_id == terminal_id
            && incarnation.is_none_or(|expected| record.incarnation == expected)
            && !terminate_host_record(record.clone(), path.clone())
        {
            schedule_terminal_host_record_cleanup(record, path);
        }
    }
    pending_terminals::terminate_unadoptable_hosts_in(root, terminal_id);
    let record_path = root.join(format!("{terminal_id}.json"));
    let _ = acknowledge_terminal_exit_sidecar(&record_path, terminal_id, incarnation);
}

#[cfg(any(unix, windows))]
pub(super) fn terminate_host_record(
    record: crate::terminal_host_runtime::TerminalHostRecord,
    record_path: std::path::PathBuf,
) -> bool {
    let Some(mut host) = pending_terminals::adopt_host_to_terminate(record, record_path) else {
        return false;
    };
    let exit_path = host.exit_record_path();
    let exit = host.terminate_and_wait_for_exit();
    host.disconnect();
    let Ok(exit) = exit else { return false };
    acknowledge_exact_terminal_host_exit(&exit_path, &exit)
}

#[cfg(any(unix, windows))]
pub(super) fn acknowledge_exact_terminal_host_exit(
    exit_path: &Path,
    exit: &crate::terminal_host_runtime::TerminalHostExitRecord,
) -> bool {
    match crate::terminal_host_runtime::acknowledge_terminal_host_exit_record(exit_path, exit) {
        Ok(true) => true,
        Ok(false) => !exit_path.exists(),
        Err(_) => false,
    }
}

#[cfg(any(unix, windows))]
pub(super) fn acknowledge_terminal_exit_sidecar(
    record_path: &Path,
    terminal_id: &str,
    incarnation: Option<&str>,
) -> bool {
    let exit_path = record_path.with_extension("exit");
    let exit = match crate::terminal_host_runtime::terminal_host_exit_record(record_path) {
        Ok(Some((_, exit))) => exit,
        Ok(None) => return !exit_path.exists(),
        Err(_) => return false,
    };
    if exit.terminal_id != terminal_id
        || incarnation.is_some_and(|expected| exit.incarnation != expected)
    {
        return false;
    }
    match crate::terminal_host_runtime::acknowledge_terminal_host_exit_record(&exit_path, &exit) {
        Ok(true) => true,
        Ok(false) => !exit_path.exists(),
        Err(_) => false,
    }
}

#[cfg(any(unix, windows))]
pub(super) fn schedule_terminal_host_record_cleanup(
    record: crate::terminal_host_runtime::TerminalHostRecord,
    record_path: std::path::PathBuf,
) {
    let fallback_record = record.clone();
    let fallback_path = record_path.clone();
    let name = format!("terminal-clean-{}", record.terminal_id);
    if std::thread::Builder::new()
        .name(name)
        .spawn(move || retry_terminal_host_record_cleanup(record, record_path))
        .is_err()
    {
        // Thread exhaustion cannot turn a durable close into a permanent
        // orphan. The request may remain blocked, but the exact host keeps
        // being reconciled until it accepts termination or proves itself dead.
        retry_terminal_host_record_cleanup(fallback_record, fallback_path);
    }
}

#[cfg(any(unix, windows))]
pub(super) fn retry_terminal_host_record_cleanup(
    record: crate::terminal_host_runtime::TerminalHostRecord,
    record_path: std::path::PathBuf,
) {
    let mut delay = Duration::from_millis(25);
    loop {
        std::thread::sleep(delay);
        if cleanup_terminal_host_record(&record, &record_path) {
            return;
        }
        delay = (delay * 2).min(Duration::from_secs(5));
    }
}

#[cfg(any(unix, windows))]
pub(super) fn terminal_host_record_liveness(
    record_path: &Path,
    record: &crate::terminal_host_runtime::TerminalHostRecord,
) -> TerminalHostLiveness {
    crate::terminal_host_runtime::terminal_host_record_liveness(record_path, record)
        .unwrap_or(TerminalHostLiveness::Indeterminate)
}

/// The process of a record's host for a seat: `host` only when the answer
/// for the record is that the host lives. An answer that the daemon could
/// not read is not that answer.
#[cfg(any(unix, windows))]
fn host_that_lives(
    liveness: TerminalHostLiveness,
    host: Option<crate::diagnostics::KeptHost>,
) -> Option<crate::diagnostics::KeptHost> {
    host.filter(|_| liveness == TerminalHostLiveness::Live)
}

/// The answer for a record and, for that answer, the process of the
/// record's host for a seat ([`host_that_lives`]). `host` reads the process
/// BEFORE `answer` asks if the host lives: when the answer is that the host
/// lives, the host had its process id for the whole time between the two.
#[cfg(any(unix, windows))]
fn host_read_before_the_answer(
    host: impl FnOnce() -> Option<crate::diagnostics::KeptHost>,
    answer: impl FnOnce() -> TerminalHostLiveness,
) -> (TerminalHostLiveness, Option<crate::diagnostics::KeptHost>) {
    let host = host();
    let liveness = answer();
    (liveness, host_that_lives(liveness, host))
}

/// The seat of a kept host, as its adoption owns it ([`Mux::kept_host`]).
/// The default is no seat.
///
/// A client can have its class from the seat. At each end of the seat (the
/// drop of this value), the clients that have their class from it get the
/// class that the seats give at that moment
/// (`ClientRegistry::kept_seat_ended`). The owner drops this value with no
/// lock held.
#[cfg(any(unix, windows))]
#[derive(Default)]
#[must_use = "the seat ends when this value is dropped"]
pub(crate) struct KeptHostHold {
    seat: crate::diagnostics::KeptHostSeat,
    mux: std::sync::Weak<Mux>,
}

#[cfg(any(unix, windows))]
impl Drop for KeptHostHold {
    fn drop(&mut self) {
        if self.seat.end()
            && let Some(mux) = self.mux.upgrade()
        {
            mux.control_clients.kept_seat_ended(mux.connection_stats());
        }
    }
}

#[cfg(all(test, any(unix, windows)))]
mod kept_host_tests;

#[cfg(any(unix, windows))]
impl Mux {
    /// [`terminal_host_record_liveness`] for a start's adoption pass and,
    /// for a host that lives, the host's seat among the session's terminals
    /// (`diagnostics/terminal_seats.rs`, `KeptHost`). The adoption owns the
    /// seat to its end, so a process of the terminal is the terminal's while
    /// the adoption runs. An adoption that gives the terminal the seat of
    /// its session ends this seat after that; each other end of an adoption
    /// (and an adoption that starts no thread) leaves the terminal with no
    /// seat.
    ///
    /// The host's process is read before the answer and seated only when the
    /// answer is that the host lives ([`host_read_before_the_answer`]). No seat: an
    /// answer that is not that one, or a start that is not read or is not
    /// before this daemon's. `terminal`: the terminal's public id, when the
    /// pass has it.
    ///
    /// A second seat for one host makes the host name no terminal. The
    /// clients that had their class from the first seat get their class
    /// again here, as at an end of the seat ([`KeptHostHold`]).
    pub(crate) fn kept_host(
        self: &Arc<Self>,
        record_path: &Path,
        record: &crate::terminal_host_runtime::TerminalHostRecord,
        terminal: Option<&TerminalPublicId>,
    ) -> (TerminalHostLiveness, KeptHostHold) {
        let (liveness, host) = host_read_before_the_answer(
            || crate::diagnostics::KeptHost::read(record.host_pid),
            || terminal_host_record_liveness(record_path, record),
        );
        if host.is_none() {
            return (liveness, KeptHostHold::default());
        }
        let terminal = terminal.cloned().or_else(|| {
            let read = {
                let registry =
                    self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
                registry.terminal_resource_id(&record.terminal_id)
            };
            // When the public id is not read, the host's seat names no terminal:
            // say why.
            read.unwrap_or_else(|error| {
                eprintln!(
                    "cmux-tui: terminal {}: its seat names no terminal before adoption: {error:#}",
                    record.terminal_id
                );
                None
            })
        });
        let terminal = terminal.as_ref().map(TerminalPublicId::as_str);
        let seating =
            crate::diagnostics::HostSeating::of(self.connection_stats().clone(), terminal);
        let seat = seating.seat_kept(host);
        if seat.ended_a_class() {
            self.control_clients.kept_seat_ended(self.connection_stats());
        }
        (liveness, KeptHostHold { seat, mux: Arc::downgrade(self) })
    }
}

/// Ask a host to terminate first; if its admin socket is unavailable, remove
/// discovery artifacts only when the process-start nonce positively proves
/// this exact incarnation is dead. `false` means the live/ambiguous record is
/// deliberately retained for a later retry.
/// An end decided and asked for, whose wait comes later.
#[cfg(any(unix, windows))]
pub(super) enum HostEnd {
    /// Finished: whether the host (or its stale record) is gone.
    Done(bool),
    /// The host was asked to end; the call waits for its exit receipt
    /// (bounded as [`terminate_host_record`]) and says whether it ended.
    Requested(Box<dyn FnOnce() -> bool>),
}

/// [`cleanup_terminal_host_record`] in two steps: what can be done at once
/// (a dead host's stale record removed, a live host's end requested over
/// its bounded handshake) is done here, and the wait for a live host's exit
/// is left to the caller, so a lock held around this call is held only that
/// long.
#[cfg(any(unix, windows))]
pub(super) fn request_terminal_host_end(
    record: &crate::terminal_host_runtime::TerminalHostRecord,
    record_path: &Path,
) -> HostEnd {
    match terminal_host_record_liveness(record_path, record) {
        TerminalHostLiveness::Dead => {
            HostEnd::Done(cleanup_terminal_host_record(record, record_path))
        }
        TerminalHostLiveness::Live | TerminalHostLiveness::Indeterminate => {
            let Some(mut host) = pending_terminals::adopt_host_to_terminate(
                record.clone(),
                record_path.to_path_buf(),
            ) else {
                return HostEnd::Done(false);
            };
            if host.request_termination().is_err() {
                host.disconnect();
                return HostEnd::Done(false);
            }
            HostEnd::Requested(Box::new(move || {
                let exit_path = host.exit_record_path();
                let exit = host.wait_for_requested_exit();
                host.disconnect();
                exit.is_ok_and(|exit| acknowledge_exact_terminal_host_exit(&exit_path, &exit))
            }))
        }
    }
}

#[cfg(any(unix, windows))]
pub(super) fn cleanup_terminal_host_record(
    record: &crate::terminal_host_runtime::TerminalHostRecord,
    record_path: &Path,
) -> bool {
    match terminal_host_record_liveness(record_path, record) {
        TerminalHostLiveness::Dead => {
            match crate::terminal_host_runtime::remove_stale_terminal_host_record(
                record_path,
                record,
            ) {
                Ok(removed) => removed,
                // Positive nonce/PID death proof remains authoritative when
                // the host already removed its own record between probe and
                // compare-delete.
                Err(_) if !record_path.exists() => true,
                Err(_) => false,
            }
        }
        TerminalHostLiveness::Live | TerminalHostLiveness::Indeterminate => {
            terminate_host_record(record.clone(), record_path.to_path_buf())
        }
    }
}
