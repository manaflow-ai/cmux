//! Terminal host records: terminating discovered hosts, acknowledging exits, and host record cleanup.

use super::*;

/// Terminate every host record under `root` for one terminal and
/// acknowledge its exit sidecar. A host that does not end at once is left
/// to `closes`' record cleanup, which the owner's shutdown waits for.
#[cfg(any(unix, windows))]
pub(super) fn terminate_discovered_terminal_host_in(
    closes: &Arc<host_close::TerminalHostCloses>,
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
            closes.schedule_record_cleanup(record, path);
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
pub(super) fn terminal_host_record_liveness(
    record_path: &Path,
    record: &crate::terminal_host_runtime::TerminalHostRecord,
) -> TerminalHostLiveness {
    crate::terminal_host_runtime::terminal_host_record_liveness(record_path, record)
        .unwrap_or(TerminalHostLiveness::Indeterminate)
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
