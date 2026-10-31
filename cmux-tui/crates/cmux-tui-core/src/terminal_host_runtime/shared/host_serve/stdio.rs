//! The terminal host process's main loop (`__terminal-host
//! --bootstrap-stdio`): bootstrap and launch over the private pipe, bind the
//! endpoint, publish the discovery record and liveness lease, answer Ready,
//! then accept clients until the terminal is dead and no client stream is
//! left. The OS edges are `sys` seams: `HostListener`, the launch/adoption
//! entry points (`sys::adopt_launch`) and the service-manager signal hooks
//! (`sys::host_signals`).

use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
use std::thread;
use std::time::{Duration, Instant};

use super::super::super::sys::{
    self, HostListener, HostLivenessLease, acquire_terminal_host_publication_lock, adopt_launch,
    host_signals, prepare_private_dir,
};
use super::super::host_accept;
use super::super::records::*;
use super::*;

/// The host process's entry (`__terminal-host --bootstrap-stdio ...`): its
/// bootstrap streams are stdio on Unix and two named pipes on Windows
/// (`sys::host_bootstrap_streams`).
pub fn serve_terminal_host_process(args: &[String]) -> anyhow::Result<()> {
    // Key-press flow marks start here, before any PTY or client work (`CMUX_TRACE_FLOWS`).
    cmux_flow_trace::init();
    let (mut reader, mut writer) = sys::host_bootstrap_streams(args)?;
    serve_terminal_host_stdio(args, &mut reader, &mut writer)
}

pub fn serve_terminal_host_stdio(
    args: &[String],
    reader: &mut impl Read,
    writer: &mut impl Write,
) -> anyhow::Result<()> {
    let adopt_fd = adopt_launch::adopt_pty_fd(args)?;
    let mut bootstrapped = crate::terminal_host::bootstrap_stdio_once(reader, writer)?;
    let Some(launch_frame) = read_frame(reader, adopt_launch::max_payload(adopt_fd))? else {
        // Keep the one-frame bootstrap probe useful for compatibility and
        // packaging diagnostics. Production launchers always follow it
        // with Launch on the same private pipe.
        return Ok(());
    };
    let (launch, adopt) = adopt_launch::decode(&launch_frame, adopt_fd, &mut bootstrapped)?;
    crate::debug_spans::install(crate::debug_spans::Trace::start("host", Instant::now()));
    crate::debug_spans::label_terminal(|| bootstrapped.terminal_id.to_hex());
    let (shared, _pty_lock) = match adopt_launch::start(&launch, adopt, &bootstrapped) {
        Ok(shared) => shared,
        Err(error) => {
            let failure = host_launch_failure(&error);
            let mut response =
                Frame::new(MessageKind::LaunchFailed, encode_host_launch_failure(&failure)?);
            response.request_id = launch_frame.request_id;
            write_frame(writer, &response)?;
            return Ok(());
        }
    };

    let stopping = shared.clone();
    host_signals::on_service_manager_stop(Box::new(move || stopping.request_termination()));
    // In a build with an orphan grace (tagged DEV, staging, debug), a plain
    // SIGTERM ends an orphaned host (no client stream for a while: its
    // daemon is gone); a host its daemon still serves, or one in a short
    // reconnect gap, records and survives it. A normal install's host has
    // no orphan grace and survives every stray SIGTERM: only an explicit
    // close or a service-manager stop (PID 1) ends it (cx-t2sqm.17).
    let watched = shared.clone();
    host_signals::on_orphan_check(Box::new(move || {
        host_orphan_grace().is_some()
            && watched.active_client_streams.load(Ordering::Acquire) == 0
            && orphaned_for(HOST_SIGTERM_ORPHAN_MIN)
    }));
    let endpoint = PathBuf::from(&launch.endpoint);
    let mut unpublished =
        UnpublishedHostGuard { shared: shared.clone(), endpoint: endpoint.clone(), armed: true };
    let _ = fs::remove_file(&endpoint);
    if let Some(parent) = endpoint.parent() {
        prepare_private_dir(parent)?;
    }
    let listener = HostListener::bind(&endpoint)?;
    crate::debug_spans::mark("host.endpoint_bound");

    let start_nonce = CapabilityToken::random()?;
    let record = TerminalHostRecord {
        record_version: HOST_RECORD_VERSION,
        terminal_id: bootstrapped.terminal_id.to_hex(),
        incarnation: bootstrapped.incarnation.to_hex(),
        endpoint: launch.endpoint.clone(),
        owner_token: encode_hex(bootstrapped.owner_token().as_bytes()),
        host_pid: std::process::id(),
        host_start_nonce: encode_hex(start_nonce.as_bytes()),
        workspace_key: launch.workspace_key.clone(),
        supports_set_defaults: true,
        supports_clear_history: true,
        supports_terminate_ack: true,
        supports_input_ack: true,
        supports_terminal_metadata: true,
        supports_clipboard_read: true,
        supports_viewer_size_priority: true,
        supports_pty_custody: sys::SUPPORTS_PTY_CUSTODY,
        supports_program_status: true,
        supports_shell_activity: true,
        orphan_grace_secs: host_orphan_grace().map(|grace| grace.as_secs()),
    };
    let record_root = Path::new(&launch.record_path)
        .parent()
        .ok_or_else(|| anyhow::anyhow!("terminal-host record has no parent directory"))?;
    let _publication_lock = acquire_terminal_host_publication_lock(record_root)?;
    // The lease's and the record directory's syncs run after Ready (below),
    // off the new terminal's first output (new-terminal-100x).
    let (lease, unsynced_lease) = HostLivenessLease::acquire_deferring_sync(liveness_path(
        Path::new(&launch.record_path),
        &record,
    ))?;
    crate::debug_spans::mark("host.lease_acquired");
    let mut guard = HostServiceGuard {
        shared: shared.clone(),
        endpoint,
        record_path: PathBuf::from(&launch.record_path),
        record: record.clone(),
        lease: Some(lease),
        published: false,
    };
    unpublished.armed = false;

    // The PTY owner publishes its own adoption record before Ready. A
    // daemon killed immediately after launch acknowledgement can never
    // leave behind an undiscoverable terminal process.
    write_record_deferring_dir_sync(Path::new(&launch.record_path), &record)?;
    guard.published = true;
    host_signals::set_breadcrumb_path(
        Path::new(&launch.record_path).with_extension("signals"),
        record.terminal_id.clone(),
        record.incarnation,
    );
    crate::debug_spans::mark("host.record_written");
    crate::debug_spans::finish(crate::debug_spans::take());

    // Integration failure-injection seam for the narrow record-before-
    // Ready crash window. It is inherited only by explicitly configured
    // test daemons and bounded so an accidental environment setting
    // cannot wedge a production host indefinitely.
    if let Ok(delay) = std::env::var("CMUX_TUI_TEST_HOST_READY_DELAY_MS")
        && let Ok(delay) = delay.parse::<u64>()
        && delay > 0
    {
        thread::sleep(Duration::from_millis(delay.min(5_000)));
    }
    // Debug builds only: a test can hold several launches open at once
    // before Ready and prove they overlap.
    #[cfg(debug_assertions)]
    wait_at_test_gate("CMUX_TUI_TEST_HOST_READY_GATE");

    let ready = HostReady {
        selected_version: PROTOCOL_VERSION,
        terminal_id: bootstrapped.terminal_id,
        incarnation: bootstrapped.incarnation,
    };
    let mut response = Frame::new(MessageKind::Ready, ready.encode());
    response.request_id = launch_frame.request_id;
    // Publication is the ownership handoff. If the launcher dies in the
    // narrow record-before-Ready window, EPIPE must not tear down the
    // independently adoptable shell; a replacement daemon discovers the
    // record and connects through the already-listening Unix socket.
    let _ = write_frame(writer, &response);
    // The discovery files' remaining syncs, after Ready: they only order
    // the files on disk for a power cut, which also ends this host.
    let record_dir = Path::new(&launch.record_path).parent().map(Path::to_path_buf);
    let _ = thread::Builder::new().name("terminal-host-publication-sync".into()).spawn(move || {
        if let Some(lease) = unsynced_lease {
            let _ = sys::barrier_sync(&lease);
        }
        if let Some(record_dir) = record_dir {
            let _ = sys::barrier_sync_dir(&record_dir);
        }
    });

    let launch_owner_deadline = Instant::now() + HOST_LAUNCH_OWNER_TIMEOUT;
    let mut backoff = host_accept::AcceptBackoff::new();
    // No client stream since this instant: the owner daemon is gone. In a
    // build with an orphan grace (tagged DEV, staging, debug; none in normal
    // installs, cx-t2sqm D1), after that grace with still no client the host
    // ends its terminal the way an owner's Terminate does (exit record
    // included), so a deleted throwaway build does not hold a PTY until
    // reboot. Any accepted connection restarts the clock, so a restarted
    // daemon's adoption always wins.
    let orphan_grace = host_orphan_grace();
    let mut orphan_since: Option<Instant> = None;
    let mut orphan_ended = false;
    loop {
        let now = Instant::now();
        if !shared.launch_owner_claimed.load(Ordering::Acquire)
            && now >= launch_owner_deadline
            && shared
                .launch_owner_claimed
                .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                .is_ok()
        {
            // A launcher that vanished before authenticating must not
            // retain an already-exited host forever. A live PTY remains
            // adoptable; only its eventual exit is now unblocked.
            shared.mark_launch_owner_stream_ready();
        }
        if shared.dead.load(Ordering::Acquire)
            && shared.active_client_streams.load(Ordering::Acquire) == 0
        {
            break;
        }
        if shared.active_client_streams.load(Ordering::Acquire) == 0 {
            if orphan_since.is_none() {
                orphan_since = Some(now);
                set_orphan_since(orphan_since);
            }
        } else if orphan_since.take().is_some() {
            set_orphan_since(None);
        }
        match listener.accept() {
            Ok(stream) => {
                if orphan_since.take().is_some() {
                    set_orphan_since(None);
                }
                match host_accept::serve_accepted(&shared, stream) {
                    Ok(()) => backoff.reset(),
                    Err(error) => backoff.after_error(&shared, &error),
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                // The queue is drained: a waiting daemon connection was
                // accepted above and reset the clock, so adoption wins a
                // tie with the deadline.
                if let (Some(since), Some(orphan_grace)) = (orphan_since, orphan_grace)
                    && !orphan_ended
                    && now.saturating_duration_since(since) >= orphan_grace
                {
                    orphan_ended = true;
                    eprintln!(
                        "terminal-host: no client for {} s (owner daemon gone); ending the \
                         terminal",
                        orphan_grace.as_secs()
                    );
                    mark_owner_gone();
                    shared.request_termination();
                    continue;
                }
                // Block until an attachment arrives or the accept waker
                // reports a lifecycle change (terminal exit, last client
                // stream closed). The timeouts are the one-shot launch
                // owner deadline, used until it passes, and the orphan
                // deadline while no client is attached; this loop used to
                // wake every 20 ms for the whole life of every terminal.
                let launch_timeout = if shared.launch_owner_claimed.load(Ordering::Acquire) {
                    None
                } else {
                    Some(launch_owner_deadline.saturating_duration_since(now))
                };
                let orphan_timeout = orphan_since
                    .filter(|_| !orphan_ended)
                    .zip(orphan_grace)
                    .map(|(since, grace)| (since + grace).saturating_duration_since(now));
                let timeout = match (launch_timeout, orphan_timeout) {
                    (Some(a), Some(b)) => Some(a.min(b)),
                    (a, b) => a.or(b),
                };
                match listener.wait(&shared.accept_waker, timeout) {
                    Err(error) => {
                        if error.kind() != std::io::ErrorKind::Interrupted {
                            backoff.after_error(&shared, &error);
                        }
                    }
                    Ok(woken) => {
                        // The listener drained without error: a later error
                        // starts a new streak.
                        backoff.reset();
                        if woken {
                            shared.accept_waker.drain();
                        }
                    }
                }
            }
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::Interrupted | std::io::ErrorKind::ConnectionAborted
                ) => {}
            // EMFILE, ENFILE, ENOBUFS, ENOMEM: never end the shell.
            Err(error) => backoff.after_error(&shared, &error),
        }
    }
    // Debug builds only (cx-6xk9): a test holds an ended host alive, with
    // its record, endpoint and live marker, to prove a restart waits for
    // the old host's exit.
    #[cfg(debug_assertions)]
    wait_at_test_gate("CMUX_TUI_TEST_HOST_EXIT_GATE");
    thread::sleep(Duration::from_millis(20));
    drop(guard);
    Ok(())
}

/// Test seam: when the FIFO that `variable` names exists, wait until a test
/// opens it for writing. A test killed before it opens the gate leaves the
/// host waiting 30 s at most. Only explicitly configured test daemons set
/// the variable.
#[cfg(debug_assertions)]
fn wait_at_test_gate(variable: &str) {
    let Some(gate) = std::env::var_os(variable).filter(|gate| Path::new(gate).exists()) else {
        return;
    };
    let (opened, wait) = std::sync::mpsc::channel();
    let _ = thread::Builder::new().name("host-test-gate".into()).spawn(move || {
        let _ = fs::File::open(&gate);
        let _ = opened.send(());
    });
    let _ = wait.recv_timeout(Duration::from_secs(30));
}
