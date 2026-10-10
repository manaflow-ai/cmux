//! Terminal host records: terminating discovered hosts, acknowledging exits, and scheduled host record cleanup.

use super::*;

/// Terminate every host record under `root` for one terminal and
/// acknowledge its exit sidecar.
#[cfg(unix)]
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

#[cfg(unix)]
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

#[cfg(unix)]
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

#[cfg(unix)]
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

#[cfg(unix)]
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

#[cfg(unix)]
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

#[cfg(unix)]
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
#[cfg(unix)]
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
