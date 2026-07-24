use std::collections::HashSet;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use anyhow::Context;
use cmux_tui_core::platform::transport;
use cmux_tui_core::release::ReleaseIdentity;
use cmux_tui_core::server::PROTOCOL_VERSION;
use serde_json::{Value, json};

const PROBE_REQUEST_ID: u64 = 0;
const SHUTDOWN_REQUEST_ID: u64 = 1;
#[cfg(unix)]
const LEGACY_LIST_REQUEST_ID: u64 = 2;
#[cfg(unix)]
const LEGACY_CLOSE_REQUEST_ID_START: u64 = 3;
const RESPONSE_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Clone, Debug)]
pub(crate) struct ServerIdentity {
    pub release: ReleaseIdentity,
    pub session: String,
    pub pid: u32,
    capabilities: HashSet<String>,
}

impl ServerIdentity {
    fn from_protocol_data(data: &Value) -> anyhow::Result<Self> {
        if data.get("app").and_then(Value::as_str) != Some("cmux-tui") {
            anyhow::bail!("socket endpoint is not a cmux-tui session");
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
        Ok(Self {
            release: ReleaseIdentity::from_protocol_data(data),
            session: data.get("session").and_then(Value::as_str).unwrap_or("").to_string(),
            pid,
            capabilities,
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
    pub(crate) fn inspect(
        reader: &mut BufReader<Box<dyn transport::Stream>>,
    ) -> anyhow::Result<Self> {
        write_json_line(reader.get_mut(), &json!({"id": PROBE_REQUEST_ID, "cmd": "identify"}))
            .map_err(|error| anyhow::anyhow!("transport error: {error}"))?;
        let response = read_response(reader, PROBE_REQUEST_ID)?;
        if response.get("ok").and_then(Value::as_bool) != Some(true) {
            anyhow::bail!(
                "{}",
                response.get("error").and_then(Value::as_str).unwrap_or("identify failed")
            );
        }
        let data = response.get("data").unwrap_or(&Value::Null);
        Ok(Self { identity: ServerIdentity::from_protocol_data(data)? })
    }

    pub(crate) fn connect(
        path: &Path,
    ) -> anyhow::Result<(Self, BufReader<Box<dyn transport::Stream>>)> {
        let stream = transport::connect(path).map_err(|error| {
            anyhow::anyhow!("cannot connect to session socket {}: {error}", path.display())
        })?;
        stream.set_read_timeout(Some(RESPONSE_TIMEOUT))?;
        let mut reader = BufReader::new(stream);
        let probe = Self::inspect(&mut reader)?;
        Ok((probe, reader))
    }

    pub(crate) fn is_compatible(&self) -> bool {
        self.identity.release.exactly_matches(&ReleaseIdentity::current(PROTOCOL_VERSION))
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
    reader: BufReader<Box<dyn transport::Stream>>,
}

impl ServerLifecycle {
    pub(crate) fn connect(path: PathBuf) -> anyhow::Result<Self> {
        let (probe, reader) = ServerProbe::connect(&path)?;
        Ok(Self { path, probe, reader })
    }

    pub(crate) fn probe(&self) -> &ServerProbe {
        &self.probe
    }

    pub(crate) fn stop(mut self) -> anyhow::Result<()> {
        write_json_line(
            self.reader.get_mut(),
            &json!({"id": SHUTDOWN_REQUEST_ID, "cmd": "shutdown"}),
        )
        .map_err(|error| anyhow::anyhow!("transport error: {error}"))?;

        let accepted = match read_shutdown_response(&mut self.reader, SHUTDOWN_REQUEST_ID) {
            Ok(response) => response.get("ok").and_then(Value::as_bool) == Some(true),
            Err(_error) if connection_is_gone(&self.path) => return Ok(()),
            Err(error) => return Err(error),
        };
        if !accepted {
            self.stop_legacy_server()?;
        }
        wait_for_disconnect(&mut self.reader).context("failed while waiting for the server to stop")
    }

    #[cfg(unix)]
    fn stop_legacy_server(&mut self) -> anyhow::Result<()> {
        self.close_legacy_surfaces().with_context(|| {
            crate::localization::catalog().server.legacy_cleanup_failed.to_string()
        })?;
        terminate_legacy_server(self.probe.identity.pid)
            .context("failed to signal the older server")
    }

    #[cfg(not(unix))]
    fn stop_legacy_server(&mut self) -> anyhow::Result<()> {
        anyhow::bail!(crate::localization::catalog().server.shutdown_unsupported)
    }

    #[cfg(unix)]
    fn close_legacy_surfaces(&mut self) -> anyhow::Result<()> {
        write_json_line(
            self.reader.get_mut(),
            &json!({"id": LEGACY_LIST_REQUEST_ID, "cmd": "list-workspaces"}),
        )
        .map_err(|error| anyhow::anyhow!("transport error: {error}"))?;
        let response = read_response(&mut self.reader, LEGACY_LIST_REQUEST_ID)?;
        let data = response_data(&response, "list-workspaces")?;

        for (index, surface) in legacy_surface_ids(data).into_iter().enumerate() {
            let request_id = LEGACY_CLOSE_REQUEST_ID_START
                .checked_add(u64::try_from(index)?)
                .ok_or_else(|| anyhow::anyhow!("too many surfaces to close"))?;
            write_json_line(
                self.reader.get_mut(),
                &json!({"id": request_id, "cmd": "close-surface", "surface": surface}),
            )
            .map_err(|error| anyhow::anyhow!("transport error: {error}"))?;
            let response = read_response(&mut self.reader, request_id)?;
            if response.get("ok").and_then(Value::as_bool) != Some(true) {
                let error =
                    response.get("error").and_then(Value::as_str).unwrap_or("close-surface failed");
                if !error.starts_with("unknown surface ") {
                    anyhow::bail!("{error}");
                }
            }
        }
        Ok(())
    }
}

#[cfg(unix)]
fn terminate_legacy_server(pid: u32) -> anyhow::Result<()> {
    let current_pid = libc::pid_t::try_from(std::process::id()).ok();
    let pid = libc::pid_t::try_from(pid)
        .ok()
        .filter(|pid| *pid > 1 && Some(*pid) != current_pid)
        .ok_or_else(|| {
        anyhow::anyhow!(crate::localization::catalog().server.shutdown_unsupported)
    })?;
    if unsafe { libc::kill(pid, libc::SIGTERM) } != 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(())
}

pub(crate) fn validate_local_identity(data: &Value, path: &Path) -> anyhow::Result<()> {
    let probe = ServerProbe { identity: ServerIdentity::from_protocol_data(data)? };
    probe.require_compatible(path)
}

pub(crate) fn incompatible_server_message(identity: &ServerIdentity, path: &Path) -> String {
    let messages = &crate::localization::catalog().server;
    let client = ReleaseIdentity::current(PROTOCOL_VERSION);
    let (server_version, client_version) = if identity.release.version == client.version {
        (identity.release.version_with_build_metadata(), client.version_with_build_metadata())
    } else {
        (identity.release.version.clone(), client.version.clone())
    };
    let command = format!("cmux-tui server stop --socket {}", shell_quote(path));
    let restart = messages.restart_instruction.replace("{command}", &command);
    format!(
        "{}\n\n{}: v{} {} {}\n{}: v{} {} {}\n\n{}\n{}\n{}",
        messages.incompatible_local_server,
        messages.server_label,
        server_version,
        messages.protocol_label,
        identity.release.protocol,
        messages.client_label,
        client_version,
        messages.protocol_label,
        client.protocol,
        messages.stop_to_use,
        messages.stopping_exits_panes,
        restart,
    )
}

pub(crate) fn write_json_line(writer: &mut dyn Write, value: &Value) -> std::io::Result<()> {
    serde_json::to_writer(&mut *writer, value).map_err(std::io::Error::other)?;
    writer.write_all(b"\n")
}

fn read_response(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
    request_id: u64,
) -> anyhow::Result<Value> {
    read_matching_response(reader, request_id, false)
}

fn read_shutdown_response(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
    request_id: u64,
) -> anyhow::Result<Value> {
    read_matching_response(reader, request_id, true)
}

fn read_matching_response(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
    request_id: u64,
    accept_unidentified_error: bool,
) -> anyhow::Result<Value> {
    let deadline = Instant::now() + RESPONSE_TIMEOUT;
    let mut line = String::new();
    loop {
        match reader.read_line(&mut line) {
            Ok(0) => anyhow::bail!("transport closed before response"),
            Ok(_) => {}
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) && Instant::now() < deadline =>
            {
                continue;
            }
            Err(error) => return Err(error.into()),
        }
        let value: Value = serde_json::from_str(&line)
            .map_err(|error| anyhow::anyhow!("bad response: {error}"))?;
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
fn response_data<'a>(response: &'a Value, command: &str) -> anyhow::Result<&'a Value> {
    if response.get("ok").and_then(Value::as_bool) != Some(true) {
        anyhow::bail!("{}", response.get("error").and_then(Value::as_str).unwrap_or(command));
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

fn wait_for_disconnect(reader: &mut BufReader<Box<dyn transport::Stream>>) -> anyhow::Result<()> {
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
            Err(error) => return Err(error.into()),
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
            session: "test".to_string(),
            pid: 42,
            capabilities: HashSet::new(),
        };

        let message = incompatible_server_message(&identity, Path::new("/tmp/test socket"));

        assert!(message.contains("server: v0.1.0-old protocol 8"));
        assert!(message.contains("client: v"));
        assert!(message.contains("cmux-tui server stop --socket '/tmp/test socket'"));
        assert!(message.contains("Stopping exits pane processes."));
    }

    #[cfg(unix)]
    #[test]
    fn legacy_stop_terminates_only_the_identified_process() {
        let mut child =
            Command::new("yes").stdout(Stdio::null()).stderr(Stdio::null()).spawn().unwrap();

        terminate_legacy_server(child.id()).unwrap();

        assert!(!child.wait().unwrap().success());
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
