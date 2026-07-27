use std::collections::HashSet;
use std::ffi::OsStr;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
#[cfg(unix)]
use std::process::{Command, Stdio};
#[cfg(unix)]
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use cmux_tui_core::platform::transport;
use cmux_tui_core::release::ReleaseIdentity;
use cmux_tui_core::server::{
    PROTOCOL_VERSION, SERVER_SHUTDOWN_CAPABILITY, SERVER_SHUTDOWN_INCOMPLETE_ERROR,
    SERVER_SHUTDOWN_TIMEOUT,
};
use serde_json::{Value, json};

#[cfg(unix)]
mod legacy_process;
#[cfg(all(unix, test))]
use legacy_process::terminate_process_tree;
#[cfg(unix)]
use legacy_process::{
    CapturedProcessSession, CapturedProcessTree, ProcessIdentity, capture_process_session,
    capture_process_tree_until,
};

const PROBE_REQUEST_ID: u64 = 0;
const SHUTDOWN_REQUEST_ID: u64 = 1;
#[cfg(unix)]
const LEGACY_LIST_REQUEST_ID: u64 = 2;
#[cfg(unix)]
const LEGACY_STABLE_EMPTY_SCANS: usize = 2;
#[cfg(unix)]
const LEGACY_MAX_SCAN_ROUNDS: usize = 64;
const RESPONSE_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_LIFECYCLE_RESPONSE_BYTES: usize = 16 * 1024 * 1024;
const SHUTDOWN_TRANSPORT_MARGIN: Duration = Duration::from_secs(5);
const SHUTDOWN_RESPONSE_TIMEOUT: Duration =
    SERVER_SHUTDOWN_TIMEOUT.saturating_add(SHUTDOWN_TRANSPORT_MARGIN);
#[cfg(unix)]
const LEGACY_SHUTDOWN_TIMEOUT: Duration = SHUTDOWN_RESPONSE_TIMEOUT;
#[cfg(unix)]
const LEGACY_HELPER_WAIT_MARGIN: Duration = Duration::from_millis(250);
#[cfg(unix)]
const LEGACY_HELPER_POLL_INTERVAL: Duration = Duration::from_millis(10);
#[cfg(unix)]
const LEGACY_HELPER_CANCEL_MARGIN: Duration = Duration::from_millis(100);
const LAUNCHER_COMMAND_ENV: &str = "CMUX_TUI_LAUNCHER_COMMAND";
const MAX_LAUNCHER_COMMAND_BYTES: usize = 4096;

type TransportReader = BufReader<Box<dyn transport::Stream>>;

#[cfg(unix)]
static LEGACY_HELPER_CANCELLED: AtomicBool = AtomicBool::new(false);

#[cfg(unix)]
extern "C" fn handle_legacy_helper_signal(_: libc::c_int) {
    LEGACY_HELPER_CANCELLED.store(true, Ordering::Release);
}

#[cfg(unix)]
fn install_legacy_helper_signal_handler() {
    unsafe {
        libc::signal(libc::SIGTERM, handle_legacy_helper_signal as *const () as libc::sighandler_t);
    }
}

#[cfg(unix)]
fn legacy_helper_cancelled() -> bool {
    LEGACY_HELPER_CANCELLED.load(Ordering::Acquire)
}

#[cfg(unix)]
fn ensure_legacy_helper_active() -> anyhow::Result<()> {
    if legacy_helper_cancelled() {
        anyhow::bail!(crate::localization::catalog().server.legacy_cleanup_failed);
    }
    Ok(())
}

#[cfg(unix)]
#[derive(Debug)]
struct LegacyConnectionInterrupted;

#[cfg(unix)]
impl std::fmt::Display for LegacyConnectionInterrupted {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("legacy server control connection was interrupted")
    }
}

#[cfg(unix)]
impl std::error::Error for LegacyConnectionInterrupted {}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ReleaseMismatch {
    DistributionVersion,
    SourceBuild,
    TerminalEngine,
    Protocol,
}

impl ReleaseMismatch {
    pub(crate) fn code(self) -> &'static str {
        match self {
            Self::DistributionVersion => "distribution-version",
            Self::SourceBuild => "source-build",
            Self::TerminalEngine => "terminal-engine",
            Self::Protocol => "protocol",
        }
    }

    pub(crate) fn message(self, messages: &crate::localization::ServerMessages) -> &'static str {
        match self {
            Self::DistributionVersion => messages.reason_version,
            Self::SourceBuild => messages.reason_source,
            Self::TerminalEngine => messages.reason_terminal_engine,
            Self::Protocol => messages.reason_protocol,
        }
    }
}

fn release_mismatches(server: &ReleaseIdentity, client: &ReleaseIdentity) -> Vec<ReleaseMismatch> {
    let mut mismatches = Vec::new();
    if server.version != client.version {
        mismatches.push(ReleaseMismatch::DistributionVersion);
    }
    if server.build_commit != client.build_commit {
        mismatches.push(ReleaseMismatch::SourceBuild);
    }
    if server.ghostty_commit != client.ghostty_commit {
        mismatches.push(ReleaseMismatch::TerminalEngine);
    }
    if server.protocol != client.protocol {
        mismatches.push(ReleaseMismatch::Protocol);
    }
    mismatches
}

#[derive(Clone, Debug)]
pub(crate) struct ServerIdentity {
    pub release: ReleaseIdentity,
    pub pid: u32,
    capabilities: HashSet<String>,
    pub(crate) shutdown_cleanup: ShutdownCleanupStatus,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct ShutdownCleanupStatus {
    pub(crate) pending: u64,
    pub(crate) retrying: bool,
    pub(crate) degraded: bool,
}

impl ServerIdentity {
    fn from_protocol_data(data: &Value) -> anyhow::Result<Self> {
        if data.get("app").and_then(Value::as_str) != Some("cmux-tui") {
            anyhow::bail!(crate::localization::catalog().server.endpoint_invalid);
        }
        let pid = data
            .get("pid")
            .and_then(Value::as_u64)
            .and_then(|pid| u32::try_from(pid).ok())
            .unwrap_or(0);
        let capabilities = data
            .get("capabilities")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .map(str::to_string)
            .collect();
        let cleanup = data.get("shutdown_cleanup");
        let shutdown_cleanup = ShutdownCleanupStatus {
            pending: cleanup
                .and_then(|cleanup| cleanup.get("pending"))
                .and_then(Value::as_u64)
                .unwrap_or(0),
            retrying: cleanup
                .and_then(|cleanup| cleanup.get("retrying"))
                .and_then(Value::as_bool)
                .unwrap_or(false),
            degraded: cleanup
                .and_then(|cleanup| cleanup.get("degraded"))
                .and_then(Value::as_bool)
                .unwrap_or(false),
        };
        Ok(Self {
            release: ReleaseIdentity::from_protocol_data(data),
            pid,
            capabilities,
            shutdown_cleanup,
        })
    }

    pub(crate) fn supports(&self, capability: &str) -> bool {
        self.capabilities.contains(capability)
    }
}

#[derive(Clone, Debug)]
pub(crate) struct ServerProbe {
    pub identity: ServerIdentity,
}

impl ServerProbe {
    pub(crate) fn inspect(reader: &mut TransportReader) -> anyhow::Result<Self> {
        Self::inspect_until(reader, Instant::now() + RESPONSE_TIMEOUT)
    }

    fn inspect_until(reader: &mut TransportReader, deadline: Instant) -> anyhow::Result<Self> {
        let previous_read_timeout = reader
            .get_ref()
            .read_timeout()
            .map_err(|_| anyhow::anyhow!(crate::localization::catalog().server.transport_failed))?;
        let previous_write_timeout = reader
            .get_ref()
            .write_timeout()
            .map_err(|_| anyhow::anyhow!(crate::localization::catalog().server.transport_failed))?;
        let result = (|| {
            set_transport_deadline(reader.get_mut().as_ref(), deadline)?;
            write_json_line(reader.get_mut(), &json!({"id": PROBE_REQUEST_ID, "cmd": "identify"}))
                .map_err(|_| {
                    anyhow::anyhow!(crate::localization::catalog().server.transport_failed)
                })?;
            let response = read_response_until(reader, PROBE_REQUEST_ID, deadline)?;
            if response.get("ok").and_then(Value::as_bool) != Some(true) {
                anyhow::bail!(crate::localization::catalog().server.identity_failed);
            }
            let data = response.get("data").unwrap_or(&Value::Null);
            Ok(Self { identity: ServerIdentity::from_protocol_data(data)? })
        })();
        let restored = reader
            .get_ref()
            .set_read_timeout(previous_read_timeout)
            .and_then(|()| reader.get_ref().set_write_timeout(previous_write_timeout));
        match result {
            Ok(probe) => match restored {
                Ok(()) => Ok(probe),
                // A server may close immediately after its complete identity
                // response. macOS then rejects timeout socket options with
                // EINVAL even though the response remains authoritative.
                Err(error) if closed_peer_timeout_error(&error) => Ok(probe),
                Err(_) => {
                    Err(anyhow::anyhow!(crate::localization::catalog().server.transport_failed))
                }
            },
            Err(error) => {
                let _ = restored;
                Err(error)
            }
        }
    }

    pub(crate) fn connect(path: &Path) -> anyhow::Result<(Self, TransportReader, Option<u32>)> {
        Self::connect_until(path, Instant::now() + RESPONSE_TIMEOUT)
    }

    fn connect_until(
        path: &Path,
        deadline: Instant,
    ) -> anyhow::Result<(Self, TransportReader, Option<u32>)> {
        let stream = transport::connect_until(path, deadline)
            .map_err(|_| anyhow::anyhow!(crate::localization::catalog().server.connect_failed))?;
        let peer_process_id = stream.peer_process_id().ok().flatten();
        set_transport_deadline(stream.as_ref(), deadline)?;
        let mut reader = BufReader::new(stream);
        let probe = Self::inspect_until(&mut reader, deadline)?;
        Ok((probe, reader, peer_process_id))
    }

    pub(crate) fn is_compatible(&self) -> bool {
        self.mismatches().is_empty()
    }

    pub(crate) fn mismatches(&self) -> Vec<ReleaseMismatch> {
        release_mismatches(&self.identity.release, &ReleaseIdentity::current(PROTOCOL_VERSION))
    }

    pub(crate) fn require_compatible(&self, path: &Path) -> anyhow::Result<()> {
        if self.is_compatible() {
            return Ok(());
        }
        Err(IncompatibleLocalServer { message: incompatible_server_message(&self.identity, path) }
            .into())
    }
}

#[derive(Debug)]
pub(crate) struct IncompatibleLocalServer {
    message: String,
}

impl std::fmt::Display for IncompatibleLocalServer {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for IncompatibleLocalServer {}

pub(crate) struct ServerLifecycle {
    path: PathBuf,
    probe: ServerProbe,
    reader: TransportReader,
    peer_process_id: Option<u32>,
}

impl ServerLifecycle {
    pub(crate) fn connect(path: PathBuf) -> anyhow::Result<Self> {
        let (probe, reader, peer_process_id) = ServerProbe::connect(&path)?;
        Ok(Self { path, probe, reader, peer_process_id })
    }

    #[cfg(unix)]
    fn connect_until(path: PathBuf, deadline: Instant) -> anyhow::Result<Self> {
        let (probe, reader, peer_process_id) = ServerProbe::connect_until(&path, deadline)?;
        Ok(Self { path, probe, reader, peer_process_id })
    }

    pub(crate) fn probe(&self) -> &ServerProbe {
        &self.probe
    }

    pub(crate) fn stop(mut self) -> anyhow::Result<()> {
        if !self.probe.identity.supports(SERVER_SHUTDOWN_CAPABILITY) {
            return self.stop_legacy_server();
        }

        self.reader
            .get_mut()
            .set_read_timeout(Some(SHUTDOWN_RESPONSE_TIMEOUT))
            .map_err(|_| anyhow::anyhow!(crate::localization::catalog().server.transport_failed))?;
        write_json_line(
            self.reader.get_mut(),
            &json!({"id": SHUTDOWN_REQUEST_ID, "cmd": "shutdown"}),
        )
        .map_err(|_| anyhow::anyhow!(crate::localization::catalog().server.transport_failed))?;

        let response = read_shutdown_response(&mut self.reader, SHUTDOWN_REQUEST_ID)?;
        if response.get("ok").and_then(Value::as_bool) == Some(true) {
            return wait_for_disconnect(&mut self.reader, &self.path);
        }
        anyhow::bail!(localized_shutdown_error(response.get("error").and_then(Value::as_str)))
    }

    #[cfg(unix)]
    fn stop_legacy_server(self) -> anyhow::Result<()> {
        let process = verified_legacy_process(self.probe.identity.pid, self.peer_process_id)?;
        let result = run_detached_legacy_stop(&self.path, process);
        drop(self.reader);
        result
    }

    #[cfg(not(unix))]
    fn stop_legacy_server(self) -> anyhow::Result<()> {
        anyhow::bail!(crate::localization::catalog().server.shutdown_unsupported)
    }

    #[cfg(unix)]
    fn close_legacy_surfaces_until_stable(
        &mut self,
        expected: ProcessIdentity,
        captured: &CapturedProcessTree,
        deadline: Instant,
    ) -> anyhow::Result<Vec<CapturedProcessSession>> {
        let mut next_request_id = LEGACY_LIST_REQUEST_ID;
        let mut consecutive_empty_scans = 0;
        let mut owners = Vec::<CapturedProcessSession>::new();
        let mut owner_ids = HashSet::<libc::pid_t>::new();
        for _ in 0..LEGACY_MAX_SCAN_ROUNDS {
            ensure_legacy_helper_active()?;
            if Instant::now() >= deadline {
                anyhow::bail!(crate::localization::catalog().server.legacy_cleanup_failed);
            }
            let closed = match self.close_legacy_surface_snapshot(
                &mut next_request_id,
                expected,
                captured,
                &mut owners,
                &mut owner_ids,
                deadline,
            ) {
                Ok(closed) => closed,
                Err(error) if error.downcast_ref::<LegacyConnectionInterrupted>().is_some() => {
                    self.reconnect_legacy_server(expected, deadline)?;
                    consecutive_empty_scans = 0;
                    continue;
                }
                Err(error) => return Err(error),
            };
            if closed == 0 {
                consecutive_empty_scans += 1;
                if consecutive_empty_scans == LEGACY_STABLE_EMPTY_SCANS {
                    return Ok(owners);
                }
            } else {
                consecutive_empty_scans = 0;
            }
        }
        anyhow::bail!(crate::localization::catalog().server.legacy_cleanup_failed)
    }

    #[cfg(unix)]
    fn reconnect_legacy_server(
        &mut self,
        expected: ProcessIdentity,
        deadline: Instant,
    ) -> anyhow::Result<()> {
        let replacement = Self::connect_until(self.path.clone(), deadline).map_err(|_| {
            anyhow::anyhow!(crate::localization::catalog().server.legacy_cleanup_failed)
        })?;
        if replacement.probe.identity.supports(SERVER_SHUTDOWN_CAPABILITY) {
            anyhow::bail!(crate::localization::catalog().server.legacy_peer_mismatch);
        }
        let actual =
            verified_legacy_process(replacement.probe.identity.pid, replacement.peer_process_id)?;
        if actual != expected {
            anyhow::bail!(crate::localization::catalog().server.legacy_peer_mismatch);
        }
        *self = replacement;
        Ok(())
    }

    #[cfg(unix)]
    fn close_legacy_surface_snapshot(
        &mut self,
        next_request_id: &mut u64,
        expected: ProcessIdentity,
        captured: &CapturedProcessTree,
        owners: &mut Vec<CapturedProcessSession>,
        owner_ids: &mut HashSet<libc::pid_t>,
        deadline: Instant,
    ) -> anyhow::Result<usize> {
        let list_request_id = take_legacy_request_id(next_request_id)?;
        set_transport_deadline(self.reader.get_mut().as_ref(), deadline)
            .map_err(|_| LegacyConnectionInterrupted)?;
        write_json_line(
            self.reader.get_mut(),
            &json!({"id": list_request_id, "cmd": "list-workspaces"}),
        )
        .map_err(|_| LegacyConnectionInterrupted)?;
        let response = read_response_until(&mut self.reader, list_request_id, deadline)
            .map_err(|_| LegacyConnectionInterrupted)?;
        let data = response_data(&response)?;
        let surfaces = legacy_surfaces(data)?;

        for surface in &surfaces {
            ensure_legacy_helper_active()?;
            if surface.kind != "pty" {
                anyhow::bail!(crate::localization::catalog().server.legacy_cleanup_failed);
            }
            let process_request_id = take_legacy_request_id(next_request_id)?;
            set_transport_deadline(self.reader.get_mut().as_ref(), deadline)
                .map_err(|_| LegacyConnectionInterrupted)?;
            write_json_line(
                self.reader.get_mut(),
                &json!({
                    "id": process_request_id,
                    "cmd": "process-info",
                    "surface": surface.id,
                }),
            )
            .map_err(|_| LegacyConnectionInterrupted)?;
            let process_response =
                read_response_until(&mut self.reader, process_request_id, deadline)
                    .map_err(|_| LegacyConnectionInterrupted)?;
            let process_data = response_data(&process_response)?;
            let pid = process_data
                .get("pid")
                .and_then(Value::as_u64)
                .and_then(|pid| libc::pid_t::try_from(pid).ok())
                .filter(|pid| *pid > 1);
            if let Some(pid) = pid {
                let owner = capture_process_session(pid, expected, captured, deadline)
                    .map_err(|_| {
                        anyhow::anyhow!(crate::localization::catalog().server.legacy_cleanup_failed)
                    })?
                    .ok_or_else(|| {
                        anyhow::anyhow!(crate::localization::catalog().server.legacy_cleanup_failed)
                    })?;
                if owner_ids.insert(owner.id()) {
                    owners.push(owner);
                }
            } else if !surface.dead {
                anyhow::bail!(crate::localization::catalog().server.legacy_cleanup_failed);
            }

            let request_id = take_legacy_request_id(next_request_id)?;
            set_transport_deadline(self.reader.get_mut().as_ref(), deadline)
                .map_err(|_| LegacyConnectionInterrupted)?;
            write_json_line(
                self.reader.get_mut(),
                &json!({"id": request_id, "cmd": "close-surface", "surface": surface.id}),
            )
            .map_err(|_| LegacyConnectionInterrupted)?;
            let _response = read_response_until(&mut self.reader, request_id, deadline)
                .map_err(|_| LegacyConnectionInterrupted)?;
            // Older servers can commit topology removal, then report a late
            // runtime-cleanup error. Reconcile every close response against
            // subsequent authoritative workspace snapshots. A genuinely
            // failed close remains present for all bounded rounds, so the
            // server is still never signaled on ambiguity.
        }
        Ok(surfaces.len())
    }
}

fn localized_shutdown_error(error: Option<&str>) -> &'static str {
    let messages = &crate::localization::catalog().server;
    match error {
        Some(SERVER_SHUTDOWN_INCOMPLETE_ERROR) => messages.shutdown_cleanup_incomplete,
        Some(_) | None => messages.shutdown_failed,
    }
}

#[cfg(unix)]
fn take_legacy_request_id(next_request_id: &mut u64) -> anyhow::Result<u64> {
    let request_id = *next_request_id;
    *next_request_id = request_id.checked_add(1).ok_or_else(|| {
        anyhow::anyhow!(crate::localization::catalog().server.legacy_too_many_surfaces)
    })?;
    Ok(request_id)
}

#[cfg(unix)]
fn run_detached_legacy_stop(path: &Path, expected: ProcessIdentity) -> anyhow::Result<()> {
    use std::os::unix::process::CommandExt;

    let executable = std::env::current_exe().map_err(|_| {
        anyhow::anyhow!(crate::localization::catalog().server.legacy_cleanup_failed)
    })?;
    let mut command = Command::new(executable);
    command
        .arg("__legacy-stop-helper")
        .arg(path)
        .arg(expected.pid().to_string())
        .arg(expected.started_at().to_string())
        .arg(LEGACY_SHUTDOWN_TIMEOUT.as_millis().to_string())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut helper = command.spawn().map_err(|_| {
        anyhow::anyhow!(crate::localization::catalog().server.legacy_cleanup_failed)
    })?;
    let deadline = Instant::now() + LEGACY_SHUTDOWN_TIMEOUT + LEGACY_HELPER_WAIT_MARGIN;
    let status = wait_for_child_until(&mut helper, deadline)?;
    if status.success() {
        return Ok(());
    }
    anyhow::bail!(crate::localization::catalog().server.legacy_cleanup_failed)
}

#[cfg(unix)]
fn wait_for_child_until(
    child: &mut std::process::Child,
    deadline: Instant,
) -> anyhow::Result<std::process::ExitStatus> {
    loop {
        if let Some(status) = child.try_wait().map_err(|_| {
            anyhow::anyhow!(crate::localization::catalog().server.legacy_cleanup_failed)
        })? {
            return Ok(status);
        }
        if Instant::now() >= deadline {
            let pid = libc::pid_t::try_from(child.id()).ok();
            if let Some(pid) = pid {
                // The helper installs a cooperative handler so Rust cleanup
                // can thaw any exact process identities currently fenced.
                let _ = unsafe { libc::kill(pid, libc::SIGTERM) };
            }
            let cancel_deadline = Instant::now() + LEGACY_HELPER_CANCEL_MARGIN;
            while Instant::now() < cancel_deadline {
                if child
                    .try_wait()
                    .map_err(|_| {
                        anyhow::anyhow!(crate::localization::catalog().server.legacy_cleanup_failed)
                    })?
                    .is_some()
                {
                    break;
                }
                std::thread::sleep(
                    cancel_deadline
                        .saturating_duration_since(Instant::now())
                        .min(LEGACY_HELPER_POLL_INTERVAL),
                );
            }
            anyhow::bail!(crate::localization::catalog().server.legacy_cleanup_failed);
        }
        std::thread::sleep(
            deadline.saturating_duration_since(Instant::now()).min(LEGACY_HELPER_POLL_INTERVAL),
        );
    }
}

#[cfg(unix)]
pub(crate) fn run_legacy_stop_helper(args: &[String]) -> anyhow::Result<()> {
    install_legacy_helper_signal_handler();
    let [path, expected_pid, expected_started_at, timeout_ms] = args else {
        anyhow::bail!(crate::localization::catalog().server.shutdown_unsupported);
    };
    let expected_pid =
        expected_pid.parse::<libc::pid_t>().ok().filter(|pid| *pid > 1).ok_or_else(|| {
            anyhow::anyhow!(crate::localization::catalog().server.shutdown_unsupported)
        })?;
    let expected_started_at = expected_started_at
        .parse::<u128>()
        .map_err(|_| anyhow::anyhow!(crate::localization::catalog().server.shutdown_unsupported))?;
    let timeout = timeout_ms
        .parse::<u64>()
        .ok()
        .map(Duration::from_millis)
        .filter(|timeout| !timeout.is_zero() && *timeout <= LEGACY_SHUTDOWN_TIMEOUT)
        .ok_or_else(|| {
            anyhow::anyhow!(crate::localization::catalog().server.shutdown_unsupported)
        })?;
    let deadline = Instant::now() + timeout;
    ensure_legacy_helper_active()?;
    let expected = ProcessIdentity::from_parts(expected_pid, expected_started_at);
    let mut lifecycle = ServerLifecycle::connect_until(PathBuf::from(path), deadline)?;
    if lifecycle.probe.identity.supports(SERVER_SHUTDOWN_CAPABILITY) {
        anyhow::bail!(crate::localization::catalog().server.legacy_peer_mismatch);
    }
    let actual = verified_legacy_process(lifecycle.probe.identity.pid, lifecycle.peer_process_id)?;
    if actual != expected {
        anyhow::bail!(crate::localization::catalog().server.legacy_peer_mismatch);
    }
    let captured = capture_legacy_process_tree(actual, deadline)?;

    ensure_legacy_helper_active()?;
    let owners =
        lifecycle.close_legacy_surfaces_until_stable(actual, &captured, deadline).map_err(
            |_| anyhow::anyhow!(crate::localization::catalog().server.legacy_cleanup_failed),
        )?;
    for owner in owners {
        ensure_legacy_helper_active()?;
        owner.terminate_until(deadline).map_err(|_| {
            anyhow::anyhow!(crate::localization::catalog().server.legacy_cleanup_failed)
        })?;
    }
    ensure_legacy_helper_active()?;
    terminate_captured_legacy_process_tree(captured, deadline)?;
    wait_for_disconnect_until(&mut lifecycle.reader, &lifecycle.path, deadline)
}

#[cfg(unix)]
fn verified_legacy_process(
    reported_pid: u32,
    peer_process_id: Option<u32>,
) -> anyhow::Result<ProcessIdentity> {
    let messages = &crate::localization::catalog().server;
    let peer_process_id =
        peer_process_id.ok_or_else(|| anyhow::anyhow!(messages.legacy_peer_unavailable))?;
    if reported_pid != peer_process_id {
        anyhow::bail!(messages.legacy_peer_mismatch);
    }
    let current_pid = libc::pid_t::try_from(std::process::id()).ok();
    let pid = libc::pid_t::try_from(reported_pid)
        .ok()
        .filter(|pid| *pid > 1 && Some(*pid) != current_pid)
        .ok_or_else(|| anyhow::anyhow!(messages.shutdown_unsupported))?;
    ProcessIdentity::capture(pid)
        .map_err(|_| anyhow::anyhow!(messages.legacy_peer_unavailable))?
        .ok_or_else(|| anyhow::anyhow!(messages.legacy_peer_mismatch))
}

#[cfg(all(unix, test))]
fn terminate_legacy_process_tree(process: ProcessIdentity) -> anyhow::Result<()> {
    terminate_process_tree(process)
        .map_err(|_| anyhow::anyhow!(crate::localization::catalog().server.legacy_signal_failed))
}

#[cfg(unix)]
fn capture_legacy_process_tree(
    process: ProcessIdentity,
    deadline: Instant,
) -> anyhow::Result<CapturedProcessTree> {
    capture_process_tree_until(process, deadline)
        .map_err(|_| anyhow::anyhow!(crate::localization::catalog().server.legacy_signal_failed))
}

#[cfg(unix)]
fn terminate_captured_legacy_process_tree(
    process: CapturedProcessTree,
    deadline: Instant,
) -> anyhow::Result<()> {
    process
        .terminate_until(deadline)
        .map_err(|_| anyhow::anyhow!(crate::localization::catalog().server.legacy_signal_failed))
}

pub(crate) fn validate_local_identity(data: &Value, path: &Path) -> anyhow::Result<()> {
    let probe = ServerProbe { identity: ServerIdentity::from_protocol_data(data)? };
    probe.require_compatible(path)
}

pub(crate) fn incompatible_server_message(identity: &ServerIdentity, path: &Path) -> String {
    let messages = &crate::localization::catalog().server;
    let client = ReleaseIdentity::current(PROTOCOL_VERSION);
    let reasons = release_mismatches(&identity.release, &client)
        .into_iter()
        .map(|reason| reason.message(messages))
        .collect::<Vec<_>>()
        .join(messages.reason_separator);
    let launcher = current_launcher_command();
    let command = format!("{launcher} server stop --socket {}", shell_quote(path));
    let replay = current_replay_command();
    let restart = format!(
        "{}{}{}{}{}",
        messages.restart_before_command,
        command,
        messages.restart_between_commands,
        replay,
        messages.restart_after_command
    );
    format!(
        "{}\n\n{}: v{} {} {}\n{}: v{} {} {}\n{}: {}\n\n{}\n{}\n{}",
        messages.incompatible_local_server,
        messages.server_label,
        identity.release.version,
        messages.protocol_label,
        identity.release.protocol,
        messages.client_label,
        client.version,
        messages.protocol_label,
        client.protocol,
        messages.reason_label,
        reasons,
        messages.stop_to_use,
        messages.stopping_exits_panes,
        restart,
    )
}

fn current_launcher_command() -> String {
    let override_command = std::env::var_os(LAUNCHER_COMMAND_ENV);
    let argv0 = std::env::args_os().next();
    launcher_command_from(override_command.as_deref(), argv0.as_deref())
}

fn current_replay_command() -> String {
    replay_command_from(current_launcher_command(), std::env::args_os().skip(1))
}

fn replay_command_from<I, S>(mut command: String, arguments: I) -> String
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    for argument in arguments {
        command.push(' ');
        command.push_str(&shell_quote(Path::new(argument.as_ref())));
    }
    command
}

fn launcher_command_from(override_command: Option<&OsStr>, argv0: Option<&OsStr>) -> String {
    if let Some(command) =
        override_command.and_then(OsStr::to_str).map(str::trim).filter(|command| {
            !command.is_empty()
                && command.len() <= MAX_LAUNCHER_COMMAND_BYTES
                && !command.chars().any(char::is_control)
        })
    {
        return command.to_string();
    }

    argv0
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .map(|path| shell_quote(&path))
        .unwrap_or_else(|| "cmux-tui".to_string())
}

pub(crate) fn write_json_line(writer: &mut dyn Write, value: &Value) -> std::io::Result<()> {
    serde_json::to_writer(&mut *writer, value).map_err(std::io::Error::other)?;
    writer.write_all(b"\n")
}

fn set_transport_deadline(stream: &dyn transport::Stream, deadline: Instant) -> anyhow::Result<()> {
    set_transport_deadline_raw(stream, deadline)
        .map_err(|_| anyhow::anyhow!(crate::localization::catalog().server.transport_failed))
}

fn set_transport_deadline_raw(
    stream: &dyn transport::Stream,
    deadline: Instant,
) -> std::io::Result<()> {
    let remaining = deadline
        .checked_duration_since(Instant::now())
        .filter(|remaining| !remaining.is_zero())
        .ok_or_else(|| {
            std::io::Error::new(std::io::ErrorKind::TimedOut, "server lifecycle deadline expired")
        })?;
    stream
        .set_read_timeout(Some(remaining))
        .and_then(|()| stream.set_write_timeout(Some(remaining)))
}

fn closed_peer_timeout_error(error: &std::io::Error) -> bool {
    error.raw_os_error() == Some(libc::EINVAL)
        || matches!(
            error.kind(),
            std::io::ErrorKind::InvalidInput
                | std::io::ErrorKind::NotConnected
                | std::io::ErrorKind::BrokenPipe
                | std::io::ErrorKind::ConnectionReset
        )
}

fn read_response_until(
    reader: &mut TransportReader,
    request_id: u64,
    deadline: Instant,
) -> anyhow::Result<Value> {
    read_matching_response_until(reader, request_id, false, deadline)
}

fn read_shutdown_response(reader: &mut TransportReader, request_id: u64) -> anyhow::Result<Value> {
    read_matching_response_with_timeout(reader, request_id, true, SHUTDOWN_RESPONSE_TIMEOUT)
}

fn read_matching_response_with_timeout(
    reader: &mut TransportReader,
    request_id: u64,
    accept_unidentified_error: bool,
    timeout: Duration,
) -> anyhow::Result<Value> {
    read_matching_response_until(
        reader,
        request_id,
        accept_unidentified_error,
        Instant::now() + timeout,
    )
}

fn read_matching_response_until(
    reader: &mut TransportReader,
    request_id: u64,
    accept_unidentified_error: bool,
    deadline: Instant,
) -> anyhow::Result<Value> {
    let mut line = Vec::new();
    loop {
        match read_bounded_lifecycle_line_until(reader, &mut line, deadline) {
            Ok(false) => anyhow::bail!(crate::localization::catalog().server.response_closed),
            Ok(true) => {}
            Err(LifecycleLineError::Invalid) => {
                anyhow::bail!(crate::localization::catalog().server.response_invalid)
            }
            Err(LifecycleLineError::Deadline | LifecycleLineError::Transport) => {
                anyhow::bail!(crate::localization::catalog().server.transport_failed)
            }
        }
        let value: Value = serde_json::from_slice(&line)
            .map_err(|_| anyhow::anyhow!(crate::localization::catalog().server.response_invalid))?;
        if value.get("event").is_some() {
            continue;
        }
        let response_id = value.get("id").and_then(Value::as_u64);
        if response_id == Some(request_id)
            || (accept_unidentified_error
                && response_id.is_none()
                && value.get("ok").and_then(Value::as_bool) == Some(false))
        {
            return Ok(value);
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum LifecycleLineError {
    Deadline,
    Invalid,
    Transport,
}

fn read_bounded_lifecycle_line_until(
    reader: &mut TransportReader,
    line: &mut Vec<u8>,
    deadline: Instant,
) -> Result<bool, LifecycleLineError> {
    line.clear();
    loop {
        if Instant::now() >= deadline {
            return Err(LifecycleLineError::Deadline);
        }
        if let Err(error) = set_transport_deadline_raw(reader.get_mut().as_ref(), deadline)
            && !closed_peer_timeout_error(&error)
        {
            return Err(
                if Instant::now() >= deadline || error.kind() == std::io::ErrorKind::TimedOut {
                    LifecycleLineError::Deadline
                } else {
                    LifecycleLineError::Transport
                },
            );
        }
        let available = match reader.fill_buf() {
            Ok(available) => available,
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                if Instant::now() >= deadline {
                    return Err(LifecycleLineError::Deadline);
                }
                continue;
            }
            Err(_) => return Err(LifecycleLineError::Transport),
        };
        if available.is_empty() {
            return Ok(!line.is_empty());
        }
        let newline = available.iter().position(|byte| *byte == b'\n');
        let payload_bytes = newline.unwrap_or(available.len());
        if payload_bytes > MAX_LIFECYCLE_RESPONSE_BYTES.saturating_sub(line.len()) {
            return Err(LifecycleLineError::Invalid);
        }
        line.extend_from_slice(&available[..payload_bytes]);
        let consumed = payload_bytes + usize::from(newline.is_some());
        reader.consume(consumed);
        if newline.is_some() {
            return Ok(true);
        }
    }
}

#[cfg(unix)]
fn response_data(response: &Value) -> anyhow::Result<&Value> {
    if response.get("ok").and_then(Value::as_bool) != Some(true) {
        anyhow::bail!(crate::localization::catalog().server.legacy_list_failed);
    }
    Ok(response.get("data").unwrap_or(&Value::Null))
}

#[cfg(unix)]
struct LegacySurface {
    id: u64,
    kind: String,
    dead: bool,
}

#[cfg(unix)]
fn legacy_surfaces(data: &Value) -> anyhow::Result<Vec<LegacySurface>> {
    let mut surfaces = std::collections::HashMap::<u64, (String, bool)>::new();
    for workspace in data.get("workspaces").and_then(Value::as_array).into_iter().flatten() {
        for screen in workspace.get("screens").and_then(Value::as_array).into_iter().flatten() {
            for pane in screen.get("panes").and_then(Value::as_array).into_iter().flatten() {
                for tab in pane.get("tabs").and_then(Value::as_array).into_iter().flatten() {
                    if let Some(surface) = tab.get("surface").and_then(Value::as_u64) {
                        let kind = tab.get("kind").and_then(Value::as_str).ok_or_else(|| {
                            anyhow::anyhow!(
                                crate::localization::catalog().server.legacy_cleanup_failed
                            )
                        })?;
                        let dead = tab.get("dead").and_then(Value::as_bool).unwrap_or(false);
                        if let Some(previous) = surfaces.insert(surface, (kind.to_string(), dead))
                            && previous != (kind.to_string(), dead)
                        {
                            anyhow::bail!(
                                crate::localization::catalog().server.legacy_cleanup_failed
                            );
                        }
                    }
                }
            }
        }
    }
    let mut surfaces = surfaces
        .into_iter()
        .map(|(id, (kind, dead))| LegacySurface { id, kind, dead })
        .collect::<Vec<_>>();
    surfaces.sort_by_key(|surface| surface.id);
    Ok(surfaces)
}

#[cfg(all(unix, test))]
fn legacy_surface_ids(data: &Value) -> Vec<u64> {
    legacy_surfaces(data).unwrap().into_iter().map(|surface| surface.id).collect()
}

fn wait_for_disconnect(reader: &mut TransportReader, path: &Path) -> anyhow::Result<()> {
    wait_for_disconnect_until(reader, path, Instant::now() + RESPONSE_TIMEOUT)
}

fn wait_for_disconnect_until(
    reader: &mut TransportReader,
    path: &Path,
    deadline: Instant,
) -> anyhow::Result<()> {
    let mut line = Vec::new();
    loop {
        match read_bounded_lifecycle_line_until(reader, &mut line, deadline) {
            Ok(false) => return Ok(()),
            Ok(true) => {}
            Err(LifecycleLineError::Deadline) => {
                if !path.exists() {
                    return Ok(());
                }
                anyhow::bail!(crate::localization::catalog().server.shutdown_timed_out);
            }
            Err(LifecycleLineError::Transport) => {
                // A transport failure on the already-authenticated control
                // stream is the disconnect this post-ACK wait is looking for.
                // Reconnecting here can block on a saturated accept queue and
                // cannot strengthen the identity already proven by the stream.
                return Ok(());
            }
            Err(LifecycleLineError::Invalid) => {
                anyhow::bail!(crate::localization::catalog().server.transport_failed);
            }
        }
    }
}

fn shell_quote(path: &Path) -> String {
    let value = path.display().to_string();
    if !value.is_empty()
        && value.chars().all(|character| {
            character.is_ascii_alphanumeric() || matches!(character, '/' | '.' | '_' | '-')
        })
    {
        value
    } else {
        format!("'{}'", value.replace('\'', "'\"'\"'"))
    }
}

#[cfg(test)]
mod tests {
    use std::io::{self, Read};
    use std::net::Shutdown;
    #[cfg(unix)]
    use std::process::{Command, Stdio};
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;

    struct FloodStream {
        remaining_chunks: usize,
        reads: Arc<AtomicUsize>,
    }

    impl Read for FloodStream {
        fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
            if self.remaining_chunks == 0 {
                return Ok(0);
            }
            self.remaining_chunks -= 1;
            self.reads.fetch_add(1, Ordering::AcqRel);
            buffer.fill(b'x');
            Ok(buffer.len())
        }
    }

    impl Write for FloodStream {
        fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
            Ok(buffer.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    impl transport::Stream for FloodStream {
        fn try_clone_box(&self) -> io::Result<Box<dyn transport::Stream>> {
            Err(io::Error::new(io::ErrorKind::Unsupported, "test stream is not cloneable"))
        }

        fn read_timeout(&self) -> io::Result<Option<Duration>> {
            Ok(None)
        }

        fn set_read_timeout(&self, _timeout: Option<Duration>) -> io::Result<()> {
            Ok(())
        }

        fn write_timeout(&self) -> io::Result<Option<Duration>> {
            Ok(None)
        }

        fn set_write_timeout(&self, _timeout: Option<Duration>) -> io::Result<()> {
            Ok(())
        }

        fn shutdown(&self, _how: Shutdown) -> io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn mismatch_message_contains_both_release_identities_and_stop_command() {
        let identity = ServerIdentity {
            release: ReleaseIdentity {
                version: "0.1.0-old".to_string(),
                build_commit: None,
                ghostty_commit: None,
                protocol: PROTOCOL_VERSION - 1,
            },
            pid: 42,
            capabilities: HashSet::new(),
            shutdown_cleanup: ShutdownCleanupStatus::default(),
        };

        let message = incompatible_server_message(&identity, Path::new("/tmp/test socket"));

        assert!(message.contains(&format!("server: v0.1.0-old protocol {}", PROTOCOL_VERSION - 1)));
        assert!(message.contains("client: v"));
        assert!(message.contains("reason: distribution version differs"));
        assert!(message.contains("source build differs"));
        assert!(message.contains("terminal engine build differs"));
        assert!(message.contains("protocol differs"));
        let launcher = current_launcher_command();
        assert!(
            message.contains(&format!("{launcher} server stop --socket '/tmp/test socket'")),
            "{message}"
        );
        let replay_arguments = std::env::args_os().skip(1).collect::<Vec<_>>();
        assert!(!replay_arguments.is_empty(), "test runner must provide an argument");
        let mut replay = launcher;
        for argument in replay_arguments {
            replay.push(' ');
            replay.push_str(&shell_quote(Path::new(&argument)));
        }
        assert!(message.contains(&format!("then run `{replay}` again")), "{message}");
        assert!(message.contains("Stopping exits pane processes."));
    }

    #[test]
    fn replayable_launcher_override_survives_one_shot_package_shims() {
        let argv0 = OsStr::new("/tmp/ephemeral/bin/cmux");

        assert_eq!(launcher_command_from(Some(OsStr::new("npx cmux")), Some(argv0)), "npx cmux");
        assert_eq!(launcher_command_from(Some(OsStr::new("uvx cmux")), Some(argv0)), "uvx cmux");
        assert_eq!(
            launcher_command_from(Some(OsStr::new("bad\ncommand")), Some(argv0)),
            "/tmp/ephemeral/bin/cmux"
        );
    }

    #[test]
    fn replay_command_preserves_quoted_and_empty_arguments() {
        assert_eq!(
            replay_command_from("cmux-tui".to_string(), ["--session", "two words", "", "it's"]),
            "cmux-tui --session 'two words' '' 'it'\"'\"'s'"
        );
    }

    #[cfg(unix)]
    #[test]
    fn lifecycle_connect_deadline_expires_before_socket_resolution() {
        let path = PathBuf::from("/tmp").join(format!(
            "cmux-tui-connect-deadline-{}-{}.sock",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let started = Instant::now();
        let result = ServerProbe::connect_until(&path, started - Duration::from_millis(1));
        let elapsed = started.elapsed();

        assert!(result.is_err(), "missing lifecycle socket unexpectedly connected");
        assert!(
            elapsed < Duration::from_millis(50),
            "expired lifecycle connect entered socket resolution: {elapsed:?}"
        );
    }

    #[cfg(unix)]
    #[test]
    fn modern_shutdown_requires_a_success_response_before_disconnect() {
        let path = PathBuf::from("/tmp").join(format!(
            "cmux-tui-shutdown-disconnect-{}-{}.sock",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let listener = std::os::unix::net::UnixListener::bind(&path).unwrap();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let identify: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(identify["cmd"], "identify");
            write_json_line(
                &mut stream,
                &json!({
                    "id": identify["id"],
                    "ok": true,
                    "data": {
                        "app": "cmux-tui",
                        "version": "test",
                        "protocol": PROTOCOL_VERSION,
                        "pid": std::process::id(),
                        "capabilities": [SERVER_SHUTDOWN_CAPABILITY],
                    },
                }),
            )
            .unwrap();
            line.clear();
            reader.read_line(&mut line).unwrap();
            let shutdown: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(shutdown["cmd"], "shutdown");
        });

        let result = ServerLifecycle::connect(path.clone()).unwrap().stop();

        server.join().unwrap();
        std::fs::remove_file(path).unwrap();
        let error = result.expect_err("disconnect without a success response was accepted");
        assert!(
            error.to_string().contains(crate::localization::catalog().server.response_closed)
                || error
                    .to_string()
                    .contains(crate::localization::catalog().server.transport_failed)
        );
    }

    #[cfg(unix)]
    #[test]
    fn modern_shutdown_does_not_expose_unlocalized_server_details() {
        let path = PathBuf::from("/tmp").join(format!(
            "cmux-tui-shutdown-localization-{}-{}.sock",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let listener = std::os::unix::net::UnixListener::bind(&path).unwrap();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let identify: Value = serde_json::from_str(&line).unwrap();
            write_json_line(
                &mut stream,
                &json!({
                    "id": identify["id"],
                    "ok": true,
                    "data": {
                        "app": "cmux-tui",
                        "version": "test",
                        "protocol": PROTOCOL_VERSION,
                        "pid": std::process::id(),
                        "capabilities": [SERVER_SHUTDOWN_CAPABILITY],
                    },
                }),
            )
            .unwrap();
            line.clear();
            reader.read_line(&mut line).unwrap();
            let shutdown: Value = serde_json::from_str(&line).unwrap();
            write_json_line(
                &mut stream,
                &json!({
                    "id": shutdown["id"],
                    "ok": false,
                    "error": "raw internal shutdown detail",
                }),
            )
            .unwrap();
        });

        let error = ServerLifecycle::connect(path.clone()).unwrap().stop().unwrap_err();

        server.join().unwrap();
        std::fs::remove_file(path).unwrap();
        assert_eq!(error.to_string(), crate::localization::catalog().server.shutdown_failed);
    }

    #[test]
    fn modern_shutdown_localizes_stable_cleanup_error_code() {
        assert_eq!(
            localized_shutdown_error(Some(SERVER_SHUTDOWN_INCOMPLETE_ERROR)),
            crate::localization::catalog().server.shutdown_cleanup_incomplete
        );
    }

    #[cfg(unix)]
    #[test]
    fn legacy_helper_timeout_is_bounded_without_force_killing_the_helper() {
        use std::io::BufRead as _;

        let mut helper = Command::new("/bin/sh")
            .arg("-c")
            .arg("trap '' TERM; printf 'ready\\n'; while :; do sleep 1; done")
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let mut ready = String::new();
        BufReader::new(helper.stdout.take().unwrap()).read_line(&mut ready).unwrap();
        assert_eq!(ready, "ready\n");
        let started = Instant::now();

        let error = wait_for_child_until(&mut helper, Instant::now() + Duration::from_millis(50))
            .unwrap_err();
        let elapsed = started.elapsed();
        let still_running = helper.try_wait().unwrap().is_none();
        let _ = helper.kill();
        let _ = helper.wait();

        assert_eq!(error.to_string(), crate::localization::catalog().server.legacy_cleanup_failed);
        assert!(
            elapsed < Duration::from_millis(250),
            "helper wait exceeded its bound: {elapsed:?}"
        );
        assert!(still_running, "parent force-killed the helper after its deadline");
    }

    #[cfg(unix)]
    #[test]
    fn legacy_stop_terminates_only_the_identified_process() {
        let mut child =
            Command::new("yes").stdout(Stdio::null()).stderr(Stdio::null()).spawn().unwrap();

        let process = verified_legacy_process(child.id(), Some(child.id())).unwrap();
        terminate_legacy_process_tree(process).unwrap();

        assert!(!child.wait().unwrap().success());
    }

    #[cfg(unix)]
    #[test]
    fn legacy_stop_rejects_a_reported_pid_that_is_not_the_socket_peer() {
        let error = verified_legacy_process(41, Some(42)).unwrap_err();

        assert_eq!(error.to_string(), crate::localization::catalog().server.legacy_peer_mismatch);
    }

    #[cfg(unix)]
    #[test]
    fn legacy_surface_ids_follow_the_workspace_tree() {
        let data = json!({
            "workspaces": [{
                "screens": [{
                    "panes": [
                        {"tabs": [
                            {"surface": 11, "kind": "pty"},
                            {"surface": 12, "kind": "pty"}
                        ]},
                        {"tabs": [{"surface": 13, "kind": "pty"}]},
                    ],
                }],
            }],
        });

        assert_eq!(legacy_surface_ids(&data), [11, 12, 13]);
    }

    #[cfg(unix)]
    #[test]
    fn response_deadline_overrides_a_longer_stream_timeout() {
        let (client, _server) = std::os::unix::net::UnixStream::pair().unwrap();
        client.set_read_timeout(Some(Duration::from_millis(500))).unwrap();
        let mut reader = BufReader::new(Box::new(client) as Box<dyn transport::Stream>);
        let started = Instant::now();

        let error =
            read_matching_response_with_timeout(&mut reader, 7, false, Duration::from_millis(50))
                .unwrap_err();

        assert!(
            started.elapsed() < Duration::from_millis(250),
            "response deadline was hidden by the stream timeout: {:?}",
            started.elapsed()
        );
        assert_eq!(error.to_string(), crate::localization::catalog().server.transport_failed);
    }

    #[test]
    fn response_reader_rejects_an_unterminated_frame_at_its_size_limit() {
        const CHUNK_BYTES: usize = 1024 * 1024;
        let reads = Arc::new(AtomicUsize::new(0));
        let stream = FloodStream { remaining_chunks: 20, reads: reads.clone() };
        let mut reader =
            BufReader::with_capacity(CHUNK_BYTES, Box::new(stream) as Box<dyn transport::Stream>);

        let error =
            read_matching_response_with_timeout(&mut reader, 7, false, Duration::from_secs(1))
                .unwrap_err();

        assert_eq!(error.to_string(), crate::localization::catalog().server.response_invalid);
        assert!(
            reads.load(Ordering::Acquire) <= 17,
            "response reader consumed an unbounded unterminated frame"
        );
    }
}
