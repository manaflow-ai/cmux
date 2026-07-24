use std::collections::HashSet;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
#[cfg(unix)]
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use cmux_tui_core::platform::transport;
use cmux_tui_core::release::ReleaseIdentity;
use cmux_tui_core::server::{PROTOCOL_VERSION, SERVER_SHUTDOWN_CAPABILITY};
use serde_json::{Value, json};

#[cfg(unix)]
mod legacy_process;
#[cfg(unix)]
use legacy_process::{ProcessIdentity, terminate_process_tree};

const PROBE_REQUEST_ID: u64 = 0;
const SHUTDOWN_REQUEST_ID: u64 = 1;
#[cfg(unix)]
const LEGACY_LIST_REQUEST_ID: u64 = 2;
#[cfg(unix)]
const LEGACY_STABLE_EMPTY_SCANS: usize = 2;
#[cfg(unix)]
const LEGACY_MAX_SCAN_ROUNDS: usize = 64;
const RESPONSE_TIMEOUT: Duration = Duration::from_secs(10);

type TransportReader = BufReader<Box<dyn transport::Stream>>;

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
        write_json_line(reader.get_mut(), &json!({"id": PROBE_REQUEST_ID, "cmd": "identify"}))
            .map_err(|_| anyhow::anyhow!(crate::localization::catalog().server.transport_failed))?;
        let response = read_response(reader, PROBE_REQUEST_ID)?;
        if response.get("ok").and_then(Value::as_bool) != Some(true) {
            anyhow::bail!(crate::localization::catalog().server.identity_failed);
        }
        let data = response.get("data").unwrap_or(&Value::Null);
        Ok(Self { identity: ServerIdentity::from_protocol_data(data)? })
    }

    pub(crate) fn connect(path: &Path) -> anyhow::Result<(Self, TransportReader, Option<u32>)> {
        let stream = transport::connect(path)
            .map_err(|_| anyhow::anyhow!(crate::localization::catalog().server.connect_failed))?;
        let peer_process_id = stream.peer_process_id().ok().flatten();
        stream
            .set_read_timeout(Some(RESPONSE_TIMEOUT))
            .map_err(|_| anyhow::anyhow!(crate::localization::catalog().server.transport_failed))?;
        let mut reader = BufReader::new(stream);
        let probe = Self::inspect(&mut reader)?;
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

    pub(crate) fn probe(&self) -> &ServerProbe {
        &self.probe
    }

    pub(crate) fn stop(mut self) -> anyhow::Result<()> {
        if !self.probe.identity.supports(SERVER_SHUTDOWN_CAPABILITY) {
            return self.stop_legacy_server();
        }

        write_json_line(
            self.reader.get_mut(),
            &json!({"id": SHUTDOWN_REQUEST_ID, "cmd": "shutdown"}),
        )
        .map_err(|_| anyhow::anyhow!(crate::localization::catalog().server.transport_failed))?;

        let accepted = match read_shutdown_response(&mut self.reader, SHUTDOWN_REQUEST_ID) {
            Ok(response) => response.get("ok").and_then(Value::as_bool) == Some(true),
            Err(_error) if connection_is_gone(&self.path) => return Ok(()),
            Err(error) => return Err(error),
        };
        if accepted {
            return wait_for_disconnect(&mut self.reader);
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
    fn close_legacy_surfaces_until_stable(&mut self) -> anyhow::Result<()> {
        let mut next_request_id = LEGACY_LIST_REQUEST_ID;
        let mut consecutive_empty_scans = 0;
        for _ in 0..LEGACY_MAX_SCAN_ROUNDS {
            let closed = self.close_legacy_surface_snapshot(&mut next_request_id)?;
            if closed == 0 {
                consecutive_empty_scans += 1;
                if consecutive_empty_scans == LEGACY_STABLE_EMPTY_SCANS {
                    return Ok(());
                }
            } else {
                consecutive_empty_scans = 0;
            }
        }
        anyhow::bail!(crate::localization::catalog().server.legacy_cleanup_failed)
    }

    #[cfg(unix)]
    fn close_legacy_surface_snapshot(
        &mut self,
        next_request_id: &mut u64,
    ) -> anyhow::Result<usize> {
        let list_request_id = take_legacy_request_id(next_request_id)?;
        write_json_line(
            self.reader.get_mut(),
            &json!({"id": list_request_id, "cmd": "list-workspaces"}),
        )
        .map_err(|_| anyhow::anyhow!(crate::localization::catalog().server.transport_failed))?;
        let response = read_response(&mut self.reader, list_request_id)?;
        let data = response_data(&response)?;
        let mut surfaces = legacy_surface_ids(data);
        surfaces.sort_unstable();
        surfaces.dedup();

        for &surface in &surfaces {
            let request_id = take_legacy_request_id(next_request_id)?;
            write_json_line(
                self.reader.get_mut(),
                &json!({"id": request_id, "cmd": "close-surface", "surface": surface}),
            )
            .map_err(|_| anyhow::anyhow!(crate::localization::catalog().server.transport_failed))?;
            let response = read_response(&mut self.reader, request_id)?;
            if response.get("ok").and_then(Value::as_bool) != Some(true) {
                let error =
                    response.get("error").and_then(Value::as_str).unwrap_or("close-surface failed");
                if !error.starts_with("unknown surface ") {
                    anyhow::bail!(crate::localization::catalog().server.legacy_close_failed);
                }
            }
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
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped());
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let output = command.output().map_err(|_| {
        anyhow::anyhow!(crate::localization::catalog().server.legacy_cleanup_failed)
    })?;
    if output.status.success() {
        return Ok(());
    }
    anyhow::bail!(crate::localization::catalog().server.legacy_cleanup_failed)
}

#[cfg(unix)]
pub(crate) fn run_legacy_stop_helper(args: &[String]) -> anyhow::Result<()> {
    let [path, expected_pid, expected_started_at] = args else {
        anyhow::bail!(crate::localization::catalog().server.shutdown_unsupported);
    };
    let expected_pid =
        expected_pid.parse::<libc::pid_t>().ok().filter(|pid| *pid > 1).ok_or_else(|| {
            anyhow::anyhow!(crate::localization::catalog().server.shutdown_unsupported)
        })?;
    let expected_started_at = expected_started_at
        .parse::<u128>()
        .map_err(|_| anyhow::anyhow!(crate::localization::catalog().server.shutdown_unsupported))?;
    let expected = ProcessIdentity::from_parts(expected_pid, expected_started_at);
    let mut lifecycle = ServerLifecycle::connect(PathBuf::from(path))?;
    if lifecycle.probe.identity.supports(SERVER_SHUTDOWN_CAPABILITY) {
        anyhow::bail!(crate::localization::catalog().server.legacy_peer_mismatch);
    }
    let actual = verified_legacy_process(lifecycle.probe.identity.pid, lifecycle.peer_process_id)?;
    if actual != expected {
        anyhow::bail!(crate::localization::catalog().server.legacy_peer_mismatch);
    }

    lifecycle.close_legacy_surfaces_until_stable().map_err(|_| {
        anyhow::anyhow!(crate::localization::catalog().server.legacy_cleanup_failed)
    })?;
    terminate_legacy_process_tree(actual)?;
    wait_for_disconnect(&mut lifecycle.reader)
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

#[cfg(unix)]
fn terminate_legacy_process_tree(process: ProcessIdentity) -> anyhow::Result<()> {
    terminate_process_tree(process)
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
    let command = format!("cmux-tui server stop --socket {}", shell_quote(path));
    let restart =
        format!("{}{}{}", messages.restart_before_command, command, messages.restart_after_command);
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

pub(crate) fn write_json_line(writer: &mut dyn Write, value: &Value) -> std::io::Result<()> {
    serde_json::to_writer(&mut *writer, value).map_err(std::io::Error::other)?;
    writer.write_all(b"\n")
}

fn read_response(reader: &mut TransportReader, request_id: u64) -> anyhow::Result<Value> {
    read_matching_response(reader, request_id, false)
}

fn read_shutdown_response(reader: &mut TransportReader, request_id: u64) -> anyhow::Result<Value> {
    read_matching_response(reader, request_id, true)
}

fn read_matching_response(
    reader: &mut TransportReader,
    request_id: u64,
    accept_unidentified_error: bool,
) -> anyhow::Result<Value> {
    let deadline = Instant::now() + RESPONSE_TIMEOUT;
    let mut line = String::new();
    loop {
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
fn legacy_surface_ids(data: &Value) -> Vec<u64> {
    let mut surfaces = Vec::new();
    for workspace in data.get("workspaces").and_then(Value::as_array).into_iter().flatten() {
        for screen in workspace.get("screens").and_then(Value::as_array).into_iter().flatten() {
            for pane in screen.get("panes").and_then(Value::as_array).into_iter().flatten() {
                for tab in pane.get("tabs").and_then(Value::as_array).into_iter().flatten() {
                    if let Some(surface) = tab.get("surface").and_then(Value::as_u64) {
                        surfaces.push(surface);
                    }
                }
            }
        }
    }
    surfaces
}

fn wait_for_disconnect(reader: &mut TransportReader) -> anyhow::Result<()> {
    let deadline = Instant::now() + RESPONSE_TIMEOUT;
    let mut line = String::new();
    loop {
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
                anyhow::bail!(crate::localization::catalog().server.shutdown_timed_out)
            }
            Err(_) => anyhow::bail!(crate::localization::catalog().server.transport_failed),
        }
    }
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
        assert!(message.contains("cmux-tui server stop --socket '/tmp/test socket'"));
        assert!(message.contains("Stopping exits pane processes."));
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
                        {"tabs": [{"surface": 11}, {"surface": 12}]},
                        {"tabs": [{"surface": 13}]},
                    ],
                }],
            }],
        });

        assert_eq!(legacy_surface_ids(&data), [11, 12, 13]);
    }
}
