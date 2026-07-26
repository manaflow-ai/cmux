use std::collections::HashSet;
use std::ffi::OsStr;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
#[cfg(unix)]
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use cmux_tui_core::platform::transport;
use cmux_tui_core::release::ReleaseIdentity;
use cmux_tui_core::server::{
    PROTOCOL_VERSION, SERVER_SHUTDOWN_CAPABILITY, SERVER_SHUTDOWN_TIMEOUT,
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
const SHUTDOWN_TRANSPORT_MARGIN: Duration = Duration::from_secs(5);
const SHUTDOWN_RESPONSE_TIMEOUT: Duration =
    SERVER_SHUTDOWN_TIMEOUT.saturating_add(SHUTDOWN_TRANSPORT_MARGIN);
#[cfg(unix)]
const LEGACY_SHUTDOWN_TIMEOUT: Duration = SHUTDOWN_RESPONSE_TIMEOUT;
#[cfg(unix)]
const LEGACY_HELPER_WAIT_MARGIN: Duration = Duration::from_millis(250);
#[cfg(unix)]
const LEGACY_HELPER_POLL_INTERVAL: Duration = Duration::from_millis(10);
const LAUNCHER_COMMAND_ENV: &str = "CMUX_TUI_LAUNCHER_COMMAND";
const MAX_LAUNCHER_COMMAND_BYTES: usize = 4096;

type TransportReader = BufReader<Box<dyn transport::Stream>>;

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
        Ok(Self { release: ReleaseIdentity::from_protocol_data(data), pid, capabilities })
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
        set_transport_deadline(reader.get_mut().as_ref(), deadline)?;
        write_json_line(reader.get_mut(), &json!({"id": PROBE_REQUEST_ID, "cmd": "identify"}))
            .map_err(|_| anyhow::anyhow!(crate::localization::catalog().server.transport_failed))?;
        let response = read_response_until(reader, PROBE_REQUEST_ID, deadline)?;
        if response.get("ok").and_then(Value::as_bool) != Some(true) {
            anyhow::bail!(crate::localization::catalog().server.identity_failed);
        }
        let data = response.get("data").unwrap_or(&Value::Null);
        Ok(Self { identity: ServerIdentity::from_protocol_data(data)? })
    }

    pub(crate) fn connect(path: &Path) -> anyhow::Result<(Self, TransportReader, Option<u32>)> {
        Self::connect_until(path, Instant::now() + RESPONSE_TIMEOUT)
    }

    fn connect_until(
        path: &Path,
        deadline: Instant,
    ) -> anyhow::Result<(Self, TransportReader, Option<u32>)> {
        let stream = transport::connect(path)
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
        if let Some(error) = response.get("error").and_then(Value::as_str) {
            anyhow::bail!("{}: {error}", crate::localization::catalog().server.shutdown_failed);
        }
        anyhow::bail!(crate::localization::catalog().server.shutdown_failed)
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
        deadline: Instant,
    ) -> anyhow::Result<Vec<CapturedProcessSession>> {
        let mut next_request_id = LEGACY_LIST_REQUEST_ID;
        let mut consecutive_empty_scans = 0;
        let mut owners = Vec::<CapturedProcessSession>::new();
        for _ in 0..LEGACY_MAX_SCAN_ROUNDS {
            if Instant::now() >= deadline {
                anyhow::bail!(crate::localization::catalog().server.legacy_cleanup_failed);
            }
            let closed = match self.close_legacy_surface_snapshot(
                &mut next_request_id,
                expected,
                &mut owners,
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
        owners: &mut Vec<CapturedProcessSession>,
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
                .filter(|pid| *pid > 1)
                .ok_or_else(|| {
                    anyhow::anyhow!(crate::localization::catalog().server.legacy_cleanup_failed)
                })?;
            let owner = capture_process_session(pid, expected)
                .map_err(|_| {
                    anyhow::anyhow!(crate::localization::catalog().server.legacy_cleanup_failed)
                })?
                .ok_or_else(|| {
                    anyhow::anyhow!(crate::localization::catalog().server.legacy_cleanup_failed)
                })?;
            if !owners.iter().any(|captured| captured.id() == owner.id()) {
                owners.push(owner);
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
            let _ = child.kill();
            let _ = child.wait();
            anyhow::bail!(crate::localization::catalog().server.legacy_cleanup_failed);
        }
        std::thread::sleep(
            deadline.saturating_duration_since(Instant::now()).min(LEGACY_HELPER_POLL_INTERVAL),
        );
    }
}

#[cfg(unix)]
pub(crate) fn run_legacy_stop_helper(args: &[String]) -> anyhow::Result<()> {
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

    let owners = lifecycle.close_legacy_surfaces_until_stable(actual, deadline).map_err(|_| {
        anyhow::anyhow!(crate::localization::catalog().server.legacy_cleanup_failed)
    })?;
    for owner in owners {
        owner.terminate_until(deadline).map_err(|_| {
            anyhow::anyhow!(crate::localization::catalog().server.legacy_cleanup_failed)
        })?;
    }
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
    let restart = format!(
        "{}{}{}{}{}",
        messages.restart_before_command,
        command,
        messages.restart_between_commands,
        launcher,
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
    let remaining = deadline
        .checked_duration_since(Instant::now())
        .filter(|remaining| !remaining.is_zero())
        .ok_or_else(|| anyhow::anyhow!(crate::localization::catalog().server.transport_failed))?;
    stream
        .set_read_timeout(Some(remaining))
        .and_then(|()| stream.set_write_timeout(Some(remaining)))
        .map_err(|_| anyhow::anyhow!(crate::localization::catalog().server.transport_failed))
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
    let mut line = String::new();
    loop {
        set_transport_deadline(reader.get_mut().as_ref(), deadline)?;
        match reader.read_line(&mut line) {
            Ok(0) => anyhow::bail!(crate::localization::catalog().server.response_closed),
            Ok(_) => {}
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) && Instant::now() < deadline =>
            {
                continue;
            }
            Err(_) => anyhow::bail!(crate::localization::catalog().server.transport_failed),
        }
        let value: Value = serde_json::from_str(&line)
            .map_err(|_| anyhow::anyhow!(crate::localization::catalog().server.response_invalid))?;
        line.clear();
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
}

#[cfg(unix)]
fn legacy_surfaces(data: &Value) -> anyhow::Result<Vec<LegacySurface>> {
    let mut surfaces = std::collections::HashMap::<u64, String>::new();
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
                        if let Some(previous) = surfaces.insert(surface, kind.to_string())
                            && previous != kind
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
    let mut surfaces =
        surfaces.into_iter().map(|(id, kind)| LegacySurface { id, kind }).collect::<Vec<_>>();
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
    let mut line = String::new();
    loop {
        if set_transport_deadline(reader.get_mut().as_ref(), deadline).is_err() {
            if connection_is_gone(path) {
                return Ok(());
            }
            anyhow::bail!(crate::localization::catalog().server.shutdown_timed_out);
        }
        match reader.read_line(&mut line) {
            Ok(0) => return Ok(()),
            Ok(_) => line.clear(),
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) && Instant::now() < deadline => {}
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                if connection_is_gone(path) {
                    return Ok(());
                }
                anyhow::bail!(crate::localization::catalog().server.shutdown_timed_out);
            }
            Err(_) => return shutdown_read_error(path),
        }
    }
}

fn shutdown_read_error(path: &Path) -> anyhow::Result<()> {
    if connection_is_gone(path) {
        return Ok(());
    }
    anyhow::bail!(crate::localization::catalog().server.transport_failed)
}

fn connection_is_gone(path: &Path) -> bool {
    transport::connect(path).is_err()
}

fn shell_quote(path: &Path) -> String {
    let value = path.display().to_string();
    if value.chars().all(|character| {
        character.is_ascii_alphanumeric() || matches!(character, '/' | '.' | '_' | '-')
    }) {
        value
    } else {
        format!("'{}'", value.replace('\'', "'\"'\"'"))
    }
}

#[cfg(test)]
mod tests {
    #[cfg(unix)]
    use std::process::{Command, Stdio};

    use super::*;

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
        };

        let message = incompatible_server_message(&identity, Path::new("/tmp/test socket"));

        assert!(message.contains("server: v0.1.0-old protocol 8"));
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
        assert!(message.contains(&format!("then run `{launcher}` again")), "{message}");
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
}
