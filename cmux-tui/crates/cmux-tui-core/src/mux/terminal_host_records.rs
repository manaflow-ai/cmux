//! Terminal host records: terminating discovered hosts, acknowledging exits, and scheduled host record cleanup.
//!
//! Every removal of a host's records here takes the owner's panic log
//! (`SurfaceOptions::host_panic_log`): the host's crash sidecar goes there
//! as one line before it is removed, whichever path removes it.

use super::mux_work::{self, Retry};
use super::*;
use crate::terminal_host_runtime::HostPanicLog;
use cmux_threads::work::{Lane, Priority};

/// The terminal-host record directory and the owner's panic log for its
/// hosts' crash sidecars, from one `SurfaceOptions` snapshot.
pub(crate) struct TerminalHostPaths {
    /// `None` without host records.
    pub(crate) root: Option<std::path::PathBuf>,
    pub(crate) panic_log: Option<HostPanicLog>,
}

impl Mux {
    /// The one read of the host root and the panic log: both under one
    /// `surface_options` guard, which ends before this returns, so a caller
    /// never holds it while it ends hosts or locks the options again.
    pub(crate) fn terminal_host_paths(&self) -> TerminalHostPaths {
        let options = self.surface_options.lock().recover_poison();
        TerminalHostPaths {
            root: options.terminal_host_root.clone(),
            panic_log: options.host_panic_log.clone(),
        }
    }
}

/// Terminate every host record under `root` for one terminal and
/// acknowledge its exit sidecar. A host that does not accept termination
/// gets a cleanup retry on `owner`'s work.
#[cfg(any(unix, windows))]
pub(super) fn terminate_discovered_terminal_host_in(
    owner: &Weak<Mux>,
    root: &Path,
    terminal_id: &str,
    incarnation: Option<&str>,
    panic_log: Option<&HostPanicLog>,
) {
    let Ok(records) = crate::terminal_host_runtime::load_terminal_host_records(root) else {
        return;
    };
    for (path, record) in records {
        if record.terminal_id == terminal_id
            && incarnation.is_none_or(|expected| record.incarnation == expected)
            && !terminate_host_record(record.clone(), path.clone(), panic_log)
        {
            schedule_terminal_host_record_cleanup(owner, record, path, panic_log.cloned());
        }
    }
    pending_terminals::terminate_unadoptable_hosts_in(root, terminal_id);
    let record_path = root.join(format!("{terminal_id}.json"));
    let _ = acknowledge_terminal_exit_sidecar(&record_path, terminal_id, incarnation, panic_log);
}

#[cfg(any(unix, windows))]
pub(super) fn terminate_host_record(
    record: crate::terminal_host_runtime::TerminalHostRecord,
    record_path: std::path::PathBuf,
    panic_log: Option<&HostPanicLog>,
) -> bool {
    let Some(mut host) = pending_terminals::adopt_host_to_terminate(record, record_path) else {
        return false;
    };
    let exit_path = host.exit_record_path();
    let exit = host.terminate_and_wait_for_exit();
    host.disconnect();
    let Ok(exit) = exit else { return false };
    acknowledge_exact_terminal_host_exit(&exit_path, &exit, panic_log)
}

#[cfg(any(unix, windows))]
pub(super) fn acknowledge_exact_terminal_host_exit(
    exit_path: &Path,
    exit: &crate::terminal_host_runtime::TerminalHostExitRecord,
    panic_log: Option<&HostPanicLog>,
) -> bool {
    match crate::terminal_host_runtime::acknowledge_terminal_host_exit_record(
        exit_path, exit, panic_log,
    ) {
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
    panic_log: Option<&HostPanicLog>,
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
    acknowledge_exact_terminal_host_exit(&exit_path, &exit, panic_log)
}

/// Retries the cleanup of a host record that did not accept termination,
/// with backoff from 25 ms to 5 s, until the host accepts or proves itself
/// dead: a work retry (`post_mux_retry_from`), no thread per terminal. Each
/// try's termination wait runs inside `will_block`. Shutdown drops a waiting
/// try; the next owner's start sweep reconciles the record then.
#[cfg(any(unix, windows))]
pub(super) fn schedule_terminal_host_record_cleanup(
    owner: &Weak<Mux>,
    record: crate::terminal_host_runtime::TerminalHostRecord,
    record_path: std::path::PathBuf,
    panic_log: Option<HostPanicLog>,
) {
    let terminal_id = record.terminal_id.clone();
    let mut delay = Duration::from_millis(25);
    let posted = mux_work::post_mux_retry_from(
        owner,
        delay,
        Priority::BestEffort,
        Lane::System,
        move |_| {
            if cmux_threads::work::will_block(|| {
                cleanup_terminal_host_record(&record, &record_path, panic_log.as_ref())
            }) {
                return Retry::Done;
            }
            delay = (delay * 2).min(Duration::from_secs(5));
            Retry::After(delay)
        },
    );
    if posted.is_err() {
        eprintln!(
            "cmux-tui: no cleanup retry for the host of terminal {terminal_id}: shutting down"
        );
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
#[cfg(any(unix, windows))]
pub(super) fn cleanup_terminal_host_record(
    record: &crate::terminal_host_runtime::TerminalHostRecord,
    record_path: &Path,
    panic_log: Option<&HostPanicLog>,
) -> bool {
    match terminal_host_record_liveness(record_path, record) {
        TerminalHostLiveness::Dead => {
            match crate::terminal_host_runtime::remove_stale_terminal_host_record(
                record_path,
                record,
                panic_log,
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
            terminate_host_record(record.clone(), record_path.to_path_buf(), panic_log)
        }
    }
}
