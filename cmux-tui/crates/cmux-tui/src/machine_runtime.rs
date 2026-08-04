//! Config-backed machine catalog and transport connectors.

use std::collections::{HashMap, HashSet};
use std::ffi::OsString;
use std::fs;
use std::io::{self, BufReader, Write};
#[cfg(test)]
use std::io::{BufRead, Read};
#[cfg(unix)]
use std::os::unix::net::UnixStream;
#[cfg(unix)]
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
#[cfg(unix)]
use std::time::{Duration, Instant};

use crate::config::{MachineConfig, MachineCreationSourceConfig, MachineTargetConfig};
use crate::machine::{
    MachineCapabilities, MachineConnectionTarget, MachineCreationSource, MachineDescriptor,
    MachineKey, MachineSnapshot, MachineStatus, MachineUiState,
};
use crate::process_diagnostics::BoundedDiagnosticBuffer;
use crate::session::{
    REMOTE_CONTROL_MESSAGE_MAX_BYTES, RemoteMessageReader, RemoteMessageWriter, RemoteSession,
    RemoteTransport, RemoteTransportAbort, Session, read_bounded_json_line,
    read_json_line_with_progress,
};

const SSH_DIAGNOSTIC_BYTES: usize = 4096;
const SSH_CONFIG_MAX_DEPTH: usize = 16;
const SSH_CONFIG_MAX_FILES: usize = 256;
const SSH_CONFIG_MAX_HOSTS: usize = 4096;
#[cfg(unix)]
const SSH_TERMINATION_GRACE: Duration = Duration::from_millis(250);
#[cfg(unix)]
const SSH_DIAGNOSTIC_DRAIN_GRACE: Duration = Duration::from_millis(50);
/// Provider-backed machine keys grow upward from one. Client-local overlay
/// keys live in the upper half so the two process-local catalogs cannot
/// collide without changing the provider protocol.
pub(crate) const CLIENT_MACHINE_KEY_START: u64 = 1 << 63;

#[derive(Debug, Clone)]
struct Entry {
    descriptor: MachineDescriptor,
    target: MachineTargetConfig,
}

/// A client-local catalog. Provider-backed catalogs can implement the same
/// snapshot/connect/action boundary without changing the App or rail.
pub struct MachineRuntime {
    entries: Vec<Entry>,
    next_key: u64,
    connect_enabled: bool,
    connection_targets: Vec<MachineConnectionTarget>,
    creation_sources: Vec<MachineCreationSourceConfig>,
    creation_counts: HashMap<String, usize>,
    prototype_target: Option<MachineTargetConfig>,
}

impl MachineRuntime {
    #[cfg(test)]
    pub fn new(current_socket: PathBuf, configured: Vec<MachineConfig>) -> Self {
        Self::with_creation_sources(current_socket, configured, Vec::new())
    }

    pub fn with_creation_sources(
        current_socket: PathBuf,
        configured: Vec<MachineConfig>,
        creation_sources: Vec<MachineCreationSourceConfig>,
    ) -> Self {
        let current_name = local_hostname().unwrap_or_else(|| "this machine".to_string());
        let prototype_target = MachineTargetConfig::Unix { socket: current_socket.clone() };
        let mut runtime = Self {
            entries: vec![Entry {
                descriptor: MachineDescriptor {
                    key: MachineKey(1),
                    id: "current".to_string(),
                    name: current_name,
                    subtitle: "local".to_string(),
                    status: MachineStatus::Running,
                },
                target: MachineTargetConfig::Unix { socket: current_socket },
            }],
            next_key: 2,
            connect_enabled: true,
            connection_targets: discover_ssh_config_hosts(),
            creation_sources,
            creation_counts: HashMap::new(),
            prototype_target: Some(prototype_target),
        };
        let mut seen_ids = HashSet::from(["current".to_string()]);
        for machine in configured {
            if !seen_ids.insert(machine.id.clone()) {
                continue;
            }
            runtime.push(machine);
        }
        runtime
    }

    /// Build a catalog that is overlaid on a dynamic provider. It has no
    /// implicit "current machine" entry because the provider owns the active
    /// session. Ephemeral SSH targets are enabled only for trusted local
    /// launch modes such as `--cloud`.
    pub fn external(configured: Vec<MachineConfig>, connect_enabled: bool) -> Self {
        let mut runtime = Self {
            entries: Vec::new(),
            next_key: CLIENT_MACHINE_KEY_START,
            connect_enabled,
            connection_targets: if connect_enabled {
                discover_ssh_config_hosts()
            } else {
                Vec::new()
            },
            creation_sources: Vec::new(),
            creation_counts: HashMap::new(),
            prototype_target: None,
        };
        let mut seen_ids = HashSet::new();
        for machine in configured {
            if !seen_ids.insert(machine.id.clone()) {
                continue;
            }
            runtime.push(machine);
        }
        runtime
    }

    fn push(&mut self, machine: MachineConfig) -> MachineKey {
        let key = MachineKey(self.next_key);
        self.next_key = self.next_key.saturating_add(1);
        self.entries.push(Entry {
            descriptor: MachineDescriptor {
                key,
                id: machine.id,
                name: machine.name,
                subtitle: machine.subtitle,
                status: MachineStatus::Running,
            },
            target: machine.target,
        });
        key
    }

    pub fn initial_key(&self) -> MachineKey {
        self.entries[0].descriptor.key
    }

    #[cfg(test)]
    pub fn snapshot(&self, active: MachineKey) -> MachineSnapshot {
        self.snapshot_with_active(Some(active))
    }

    pub fn snapshot_with_active(&self, active: Option<MachineKey>) -> MachineSnapshot {
        MachineSnapshot {
            machines: self.entries.iter().map(|entry| entry.descriptor.clone()).collect(),
            active,
            capabilities: MachineCapabilities {
                create: !self.creation_sources.is_empty(),
                connect: self.connect_enabled,
            },
        }
    }

    pub fn ui_state(&self, active: MachineKey) -> MachineUiState {
        self.ui_state_with_active(Some(active))
    }

    pub fn ui_state_with_active(&self, active: Option<MachineKey>) -> MachineUiState {
        let mut ui = MachineUiState::new(self.snapshot_with_active(active));
        ui.creation_sources = self
            .creation_sources
            .iter()
            .map(|source| MachineCreationSource {
                id: source.id.clone(),
                name: source.name.clone(),
                subtitle: source.subtitle.clone(),
            })
            .collect();
        ui.connection_targets.clone_from(&self.connection_targets);
        ui.set_client_renamable_machines(self.entries.iter().map(|entry| entry.descriptor.key));
        ui
    }

    /// Add a session-local catalog entry using the current mux transport.
    /// This intentionally proves the provider picker and column behavior
    /// without invoking Docker or a billable VM API.
    pub fn create_from(&mut self, source_id: &str) -> anyhow::Result<(MachineKey, String)> {
        let source = self
            .creation_sources
            .iter()
            .find(|source| source.id == source_id)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("unknown machine creation source {source_id:?}"))?;
        let target = self
            .prototype_target
            .clone()
            .ok_or_else(|| anyhow::anyhow!("machine creation is unavailable in this client"))?;
        let ordinal = self.creation_counts.entry(source.id.clone()).or_default();
        *ordinal = ordinal.saturating_add(1);
        let ordinal = *ordinal;
        let name = format!("{} {ordinal}", source.name);
        let key = self.push(MachineConfig {
            id: format!("prototype:{}:{ordinal}", source.id),
            name: name.clone(),
            subtitle: source.subtitle,
            target,
        });
        Ok((key, name))
    }

    pub fn contains(&self, key: MachineKey) -> bool {
        self.entry(key).is_some()
    }

    pub fn name(&self, key: MachineKey) -> Option<&str> {
        self.entry(key).map(|entry| entry.descriptor.name.as_str())
    }

    /// Rename a client-owned catalog row for this process. Persistent source
    /// configuration remains untouched.
    pub fn rename_machine(&mut self, key: MachineKey, name: &str) -> anyhow::Result<String> {
        let name = name.trim();
        if name.is_empty() {
            anyhow::bail!(crate::localization::catalog().sidebar.machine_name_required);
        }
        let entry =
            self.entries.iter_mut().find(|entry| entry.descriptor.key == key).ok_or_else(|| {
                anyhow::anyhow!(crate::localization::catalog().sidebar.client_machine_unavailable)
            })?;
        entry.descriptor.name = name.to_string();
        Ok(entry.descriptor.name.clone())
    }

    pub fn connect(&mut self, key: MachineKey) -> anyhow::Result<Session> {
        let entry =
            self.entry(key).cloned().ok_or_else(|| anyhow::anyhow!("unknown machine {}", key.0))?;
        match connect_target(&entry.target) {
            Ok(session) => {
                self.set_status(key, MachineStatus::Running);
                Ok(session)
            }
            Err(error) => {
                self.set_status(key, MachineStatus::Unavailable);
                Err(error)
            }
        }
    }

    pub fn connect_machine(&mut self, target: &str) -> anyhow::Result<MachineKey> {
        if !self.connect_enabled {
            anyhow::bail!("this client cannot connect external machines");
        }
        let target = target.trim();
        let target = target.strip_prefix("ssh ").map(str::trim).unwrap_or(target);
        if target.is_empty() || target.starts_with('-') || target.chars().any(char::is_whitespace) {
            anyhow::bail!("machine address must be a host or user@host without whitespace");
        }
        let id = format!("ssh:{target}");
        if let Some(entry) = self.entries.iter().find(|entry| entry.descriptor.id == id) {
            return Ok(entry.descriptor.key);
        }
        let name = target.rsplit('@').next().unwrap_or(target).to_string();
        Ok(self.push(MachineConfig {
            id,
            name,
            subtitle: target.to_string(),
            target: MachineTargetConfig::Ssh {
                host: target.to_string(),
                user: None,
                port: None,
                identity_file: None,
                session: "main".to_string(),
                binary: "cmux-tui".to_string(),
            },
        }))
    }

    fn entry(&self, key: MachineKey) -> Option<&Entry> {
        self.entries.iter().find(|entry| entry.descriptor.key == key)
    }

    fn set_status(&mut self, key: MachineKey, status: MachineStatus) {
        if let Some(entry) = self.entries.iter_mut().find(|entry| entry.descriptor.key == key) {
            entry.descriptor.status = status;
        }
    }
}

fn discover_ssh_config_hosts() -> Vec<MachineConnectionTarget> {
    let Some(home) = std::env::var_os("HOME").filter(|home| !home.is_empty()) else {
        return Vec::new();
    };
    let home = PathBuf::from(home);
    let ssh_root = home.join(".ssh");
    ssh_config_hosts_from_path(&ssh_root.join("config"), &ssh_root, &home)
        .into_iter()
        .map(|host| MachineConnectionTarget { name: host.clone(), target: host })
        .collect()
}

fn ssh_config_hosts_from_path(config: &Path, ssh_root: &Path, home: &Path) -> Vec<String> {
    let mut discovery = SshConfigDiscovery {
        ssh_root,
        home,
        visited: HashSet::new(),
        seen_hosts: HashSet::new(),
        hosts: Vec::new(),
    };
    discovery.visit(config, 0);
    discovery.hosts
}

struct SshConfigDiscovery<'a> {
    ssh_root: &'a Path,
    home: &'a Path,
    visited: HashSet<PathBuf>,
    seen_hosts: HashSet<String>,
    hosts: Vec<String>,
}

impl SshConfigDiscovery<'_> {
    fn visit(&mut self, path: &Path, depth: usize) {
        if depth > SSH_CONFIG_MAX_DEPTH
            || self.visited.len() >= SSH_CONFIG_MAX_FILES
            || self.hosts.len() >= SSH_CONFIG_MAX_HOSTS
        {
            return;
        }
        let identity = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
        if !self.visited.insert(identity) {
            return;
        }
        let Ok(contents) = fs::read_to_string(path) else { return };
        for line in contents.lines() {
            let mut words = ssh_config_words(line);
            let Some(first) = words.first_mut() else { continue };
            let mut inline_value = None;
            if let Some((keyword, value)) = first.split_once('=') {
                inline_value = (!value.is_empty()).then(|| value.to_string());
                *first = keyword.to_string();
            }
            let keyword = first.to_ascii_lowercase();
            let mut values = inline_value.into_iter().chain(words.into_iter().skip(1));
            match keyword.as_str() {
                "host" => {
                    for host in values.by_ref() {
                        if self.hosts.len() >= SSH_CONFIG_MAX_HOSTS {
                            return;
                        }
                        if is_concrete_ssh_host(&host)
                            && self.seen_hosts.insert(host.to_ascii_lowercase())
                        {
                            self.hosts.push(host);
                        }
                    }
                }
                "include" => {
                    for pattern in values.by_ref() {
                        for included in self.expand_include(&pattern) {
                            self.visit(&included, depth.saturating_add(1));
                        }
                    }
                }
                _ => {}
            }
        }
    }

    fn expand_include(&self, pattern: &str) -> Vec<PathBuf> {
        let path = if pattern == "~" {
            self.home.to_path_buf()
        } else if let Some(relative) = pattern.strip_prefix("~/") {
            self.home.join(relative)
        } else {
            let path = PathBuf::from(pattern);
            if path.is_absolute() { path } else { self.ssh_root.join(path) }
        };
        let Some(pattern) = path.to_str() else { return Vec::new() };
        let Ok(paths) = glob::glob(pattern) else { return Vec::new() };
        paths.filter_map(Result::ok).take(SSH_CONFIG_MAX_FILES).collect()
    }
}

fn is_concrete_ssh_host(host: &str) -> bool {
    !host.is_empty()
        && !host.starts_with('-')
        && !host.chars().any(|character| matches!(character, '*' | '?' | '!' | '[' | ']'))
}

/// OpenSSH's config grammar only needs shell-like quoting for the directives
/// read here. Comments start outside quotes; backslashes quote one character.
fn ssh_config_words(line: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut current = String::new();
    let mut quote = None;
    let mut escaped = false;
    for character in line.chars() {
        if escaped {
            current.push(character);
            escaped = false;
            continue;
        }
        if character == '\\' {
            escaped = true;
            continue;
        }
        if let Some(delimiter) = quote {
            if character == delimiter {
                quote = None;
            } else {
                current.push(character);
            }
            continue;
        }
        match character {
            '\'' | '"' => quote = Some(character),
            '#' => break,
            character if character.is_whitespace() => {
                if !current.is_empty() {
                    words.push(std::mem::take(&mut current));
                }
            }
            _ => current.push(character),
        }
    }
    if escaped {
        current.push('\\');
    }
    if !current.is_empty() {
        words.push(current);
    }
    words
}

fn connect_target(target: &MachineTargetConfig) -> anyhow::Result<Session> {
    let remote = match target {
        MachineTargetConfig::Unix { socket } => RemoteSession::connect(socket)?,
        MachineTargetConfig::Ssh { host, user, port, identity_file, session, binary } => {
            let transport = ssh_transport(
                host,
                user.as_deref(),
                *port,
                identity_file.as_deref(),
                session,
                binary,
            )?;
            RemoteSession::connect_transport(transport)?
        }
    };
    Ok(Session::Remote(remote))
}

fn ssh_transport(
    host: &str,
    user: Option<&str>,
    port: Option<u16>,
    identity_file: Option<&Path>,
    session: &str,
    binary: &str,
) -> anyhow::Result<RemoteTransport> {
    let mut command = Command::new("ssh");
    command
        .args(ssh_arguments(host, user, port, identity_file, session, binary))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let (stdin, stdout, process) = spawn_transport_process(&mut command)?;
    Ok(RemoteTransport::new(
        Box::new(ProcessReader { inner: BufReader::new(stdout), process: process.clone() }),
        Box::new(ProcessWriter { inner: stdin, process: process.clone() }),
        Arc::new(ProcessAbort { process }),
    ))
}

fn ssh_arguments(
    host: &str,
    user: Option<&str>,
    port: Option<u16>,
    identity_file: Option<&Path>,
    session: &str,
    binary: &str,
) -> Vec<OsString> {
    let destination = user.map_or_else(|| host.to_string(), |user| format!("{user}@{host}"));
    let remote_command =
        format!("{} relay --session {}", shell_quote(binary), shell_quote(session));
    let mut arguments = vec![
        OsString::from("-T"),
        OsString::from("-o"),
        OsString::from("BatchMode=yes"),
        OsString::from("-o"),
        OsString::from("StrictHostKeyChecking=yes"),
        OsString::from("-o"),
        OsString::from("ForwardAgent=no"),
        OsString::from("-o"),
        OsString::from("ForwardX11=no"),
        OsString::from("-o"),
        OsString::from("ClearAllForwardings=yes"),
    ];
    if let Some(port) = port {
        arguments.push(OsString::from("-p"));
        arguments.push(OsString::from(port.to_string()));
    }
    if let Some(identity_file) = identity_file {
        arguments.push(OsString::from("-i"));
        arguments.push(identity_file.as_os_str().to_owned());
    }
    arguments.extend([
        OsString::from("--"),
        OsString::from(destination),
        OsString::from(remote_command),
    ]);
    arguments
}

fn spawn_transport_process(
    command: &mut Command,
) -> anyhow::Result<(ChildStdin, ChildStdout, Arc<Process>)> {
    #[cfg(unix)]
    let (stderr_cancel, stderr_cancel_worker) = UnixStream::pair()
        .map_err(|error| anyhow::anyhow!("cannot create ssh diagnostics cancellation: {error}"))?;
    #[cfg(unix)]
    command.process_group(0);
    let mut child =
        command.spawn().map_err(|error| anyhow::anyhow!("cannot start ssh: {error}"))?;
    #[cfg(unix)]
    let process_group = match libc::pid_t::try_from(child.id()) {
        Ok(process_group) => process_group,
        Err(_) => {
            let _ = child.kill();
            let _ = child.wait();
            return Err(anyhow::anyhow!("ssh process ID is invalid"));
        }
    };
    let stdin = child.stdin.take().ok_or_else(|| anyhow::anyhow!("ssh stdin unavailable"))?;
    let stdout = child.stdout.take().ok_or_else(|| anyhow::anyhow!("ssh stdout unavailable"))?;
    let stderr = child.stderr.take().ok_or_else(|| anyhow::anyhow!("ssh stderr unavailable"))?;
    let diagnostics = Arc::new(BoundedDiagnosticBuffer::new(SSH_DIAGNOSTIC_BYTES));
    let worker_diagnostics = Arc::clone(&diagnostics);
    let worker = thread::Builder::new().name("machine-ssh-stderr".to_string()).spawn(move || {
        #[cfg(unix)]
        worker_diagnostics.drain_cancellable(stderr, stderr_cancel_worker);
        #[cfg(not(unix))]
        worker_diagnostics.drain(stderr);
    });
    let worker = match worker {
        Ok(worker) => worker,
        Err(error) => {
            #[cfg(unix)]
            unsafe {
                libc::kill(-process_group, libc::SIGKILL);
            }
            let _ = child.kill();
            let _ = child.wait();
            return Err(anyhow::anyhow!("cannot monitor ssh diagnostics: {error}"));
        }
    };
    let process = Arc::new(Process {
        child: Mutex::new(Some(child)),
        diagnostics,
        #[cfg(unix)]
        process_group,
        #[cfg(unix)]
        stderr_cancel,
        stderr_worker: Mutex::new(Some(worker)),
        closed: AtomicBool::new(false),
    });
    Ok((stdin, stdout, process))
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

struct Process {
    child: Mutex<Option<Child>>,
    diagnostics: Arc<BoundedDiagnosticBuffer>,
    #[cfg(unix)]
    process_group: libc::pid_t,
    #[cfg(unix)]
    stderr_cancel: UnixStream,
    stderr_worker: Mutex<Option<JoinHandle<()>>>,
    closed: AtomicBool,
}

impl Process {
    fn diagnostic_after_stdout_eof(&self) -> Option<String> {
        let exited = self
            .child
            .lock()
            .ok()
            .and_then(|mut child| child.as_mut()?.try_wait().ok().flatten())
            .is_some();
        if exited {
            let _ = self.terminate_and_reap();
        }
        self.diagnostic()
    }

    fn diagnostic(&self) -> Option<String> {
        self.diagnostics.sanitized()
    }

    #[cfg(unix)]
    fn signal_group(&self, signal: libc::c_int) {
        let _ = unsafe { libc::kill(-self.process_group, signal) };
    }

    #[cfg(unix)]
    fn group_is_alive(&self) -> bool {
        let result = unsafe { libc::kill(-self.process_group, 0) };
        result == 0 || io::Error::last_os_error().kind() == io::ErrorKind::PermissionDenied
    }

    fn finish_stderr(&self) {
        if let Ok(mut worker) = self.stderr_worker.lock()
            && let Some(worker) = worker.take()
        {
            #[cfg(unix)]
            {
                let deadline = Instant::now() + SSH_DIAGNOSTIC_DRAIN_GRACE;
                while !worker.is_finished() && Instant::now() < deadline {
                    thread::sleep(Duration::from_millis(1));
                }
                if !worker.is_finished() {
                    let _ = self.stderr_cancel.shutdown(std::net::Shutdown::Both);
                }
            }
            let _ = worker.join();
        }
    }

    fn terminate_and_reap(&self) -> io::Result<()> {
        let mut result = Ok(());
        if !self.closed.swap(true, Ordering::AcqRel) {
            match self.child.lock() {
                Ok(mut child) => {
                    if let Some(mut child) = child.take() {
                        #[cfg(unix)]
                        {
                            self.signal_group(libc::SIGTERM);
                            let deadline = Instant::now() + SSH_TERMINATION_GRACE;
                            while self.group_is_alive() && Instant::now() < deadline {
                                let _ = child.try_wait();
                                thread::sleep(Duration::from_millis(10));
                            }
                            if self.group_is_alive() {
                                self.signal_group(libc::SIGKILL);
                            }
                        }
                        #[cfg(not(unix))]
                        {
                            let running = match child.try_wait() {
                                Ok(status) => status.is_none(),
                                Err(error) => {
                                    result = Err(error);
                                    true
                                }
                            };
                            if running
                                && let Err(error) = child.kill()
                                && result.is_ok()
                            {
                                result = Err(error);
                            }
                        }
                        if let Err(error) = child.wait()
                            && result.is_ok()
                        {
                            result = Err(error);
                        }
                    }
                }
                Err(_) => result = Err(io::Error::other("ssh lock poisoned")),
            }
        }
        self.finish_stderr();
        result
    }
}

impl Drop for Process {
    fn drop(&mut self) {
        let _ = self.terminate_and_reap();
    }
}

struct ProcessReader {
    inner: BufReader<ChildStdout>,
    process: Arc<Process>,
}

impl ProcessReader {
    fn receive_inner(&mut self, on_progress: &mut dyn FnMut(&[u8])) -> io::Result<Option<String>> {
        let _keep_alive = &self.process;
        let message = read_json_line_with_progress(&mut self.inner, on_progress)?;
        if message.is_none()
            && let Some(diagnostic) = self.process.diagnostic_after_stdout_eof()
        {
            return Err(io::Error::other(format!("ssh transport closed: {diagnostic}")));
        }
        Ok(message)
    }
}

impl RemoteMessageReader for ProcessReader {
    fn receive(&mut self) -> io::Result<Option<String>> {
        let _keep_alive = &self.process;
        let message = read_bounded_json_line(&mut self.inner, REMOTE_CONTROL_MESSAGE_MAX_BYTES)?;
        if message.is_none()
            && let Some(diagnostic) = self.process.diagnostic_after_stdout_eof()
        {
            return Err(io::Error::other(format!("ssh transport closed: {diagnostic}")));
        }
        Ok(message)
    }

    fn receive_with_progress(
        &mut self,
        on_progress: &mut dyn FnMut(&[u8]),
    ) -> io::Result<Option<String>> {
        self.receive_inner(on_progress)
    }
}

struct ProcessWriter {
    inner: ChildStdin,
    process: Arc<Process>,
}

struct ProcessAbort {
    process: Arc<Process>,
}

impl RemoteTransportAbort for ProcessAbort {
    fn abort(&self) -> io::Result<()> {
        self.process.terminate_and_reap()
    }
}

impl RemoteMessageWriter for ProcessWriter {
    fn send(&mut self, message: &str) -> io::Result<()> {
        self.inner.write_all(message.as_bytes())?;
        self.inner.write_all(b"\n")?;
        self.inner.flush()
    }

    fn close(&mut self) -> io::Result<()> {
        self.process.terminate_and_reap()
    }
}

fn local_hostname() -> Option<String> {
    std::env::var("HOSTNAME").ok().filter(|value| !value.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shell_quote_preserves_remote_arguments() {
        assert_eq!(shell_quote("main"), "'main'");
        assert_eq!(shell_quote("a'b"), "'a'\"'\"'b'");
    }

    #[cfg(unix)]
    #[test]
    fn transport_stderr_is_captured_instead_of_inheriting_the_tui() {
        let mut command = Command::new("sh");
        command
            .args(["-c", "printf 'permission denied\\nretry later' >&2"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let (stdin, mut stdout, process) = spawn_transport_process(&mut command).unwrap();
        drop(stdin);
        let mut output = Vec::new();
        stdout.read_to_end(&mut output).unwrap();

        assert!(output.is_empty());
        assert_eq!(
            process.diagnostic_after_stdout_eof().as_deref(),
            Some("permission denied retry later")
        );
    }

    #[cfg(unix)]
    #[test]
    fn transport_cleanup_does_not_wait_for_descendant_inheriting_stderr() {
        let mut command = Command::new("sh");
        command
            .args([
                "-c",
                "sleep 30 >&2 & helper=$!; printf '%s\\n' \"$helper\"; printf 'permission denied\\n' >&2",
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let (stdin, stdout, process) = spawn_transport_process(&mut command).unwrap();
        drop(stdin);

        let mut stdout = BufReader::new(stdout);
        let mut helper_pid = String::new();
        stdout.read_line(&mut helper_pid).unwrap();
        let helper_pid = helper_pid.trim().parse::<libc::pid_t>().unwrap();
        let mut remaining = Vec::new();
        stdout.read_to_end(&mut remaining).unwrap();
        assert!(remaining.is_empty());

        let (result_sender, result_receiver) = std::sync::mpsc::sync_channel(1);
        let diagnostic_process = Arc::clone(&process);
        let waiter = thread::spawn(move || {
            let _ = result_sender.send(diagnostic_process.diagnostic_after_stdout_eof());
        });
        let prompt_result = result_receiver.recv_timeout(Duration::from_millis(500));
        let completed_promptly = prompt_result.is_ok();
        let diagnostic = match prompt_result {
            Ok(diagnostic) => diagnostic,
            Err(_) => {
                unsafe {
                    libc::kill(helper_pid, libc::SIGKILL);
                }
                result_receiver
                    .recv_timeout(Duration::from_secs(5))
                    .expect("diagnostic reader should stop once the inherited descriptor closes")
            }
        };
        waiter.join().unwrap();

        assert!(completed_promptly, "transport cleanup waited for an inherited stderr handle");
        assert_eq!(diagnostic.as_deref(), Some("permission denied"));
    }

    #[test]
    fn connected_target_is_deduplicated() {
        let mut runtime = MachineRuntime::new(PathBuf::from("/tmp/current.sock"), Vec::new());
        let first = runtime.connect_machine("lawrence@mini.local").unwrap();
        let second = runtime.connect_machine("lawrence@mini.local").unwrap();
        assert_eq!(first, second);
        assert_eq!(runtime.snapshot(runtime.initial_key()).machines.len(), 2);
    }

    #[test]
    fn typed_ssh_command_prefix_adds_the_same_host_alias() {
        let mut runtime = MachineRuntime::new(PathBuf::from("/tmp/current.sock"), Vec::new());
        let command = runtime.connect_machine("ssh cmux-lawrence").unwrap();
        let alias = runtime.connect_machine("cmux-lawrence").unwrap();

        assert_eq!(command, alias);
        assert_eq!(runtime.name(command), Some("cmux-lawrence"));
    }

    #[test]
    fn client_catalog_machine_rename_is_session_local() {
        let machine = MachineConfig {
            id: "mini".into(),
            name: "Mini".into(),
            subtitle: "ssh".into(),
            target: MachineTargetConfig::Unix { socket: PathBuf::from("/tmp/mini.sock") },
        };
        let mut runtime = MachineRuntime::new(PathBuf::from("/tmp/current.sock"), vec![machine]);
        let key = runtime.snapshot(runtime.initial_key()).machines[1].key;

        assert_eq!(runtime.rename_machine(key, "  Build box  ").unwrap(), "Build box");
        assert_eq!(runtime.name(key), Some("Build box"));
        assert!(runtime.ui_state(runtime.initial_key()).is_client_machine_renamable(key));
    }

    #[test]
    fn ssh_config_discovery_follows_includes_and_skips_patterns() {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path();
        let ssh_root = home.join(".ssh");
        let include_root = ssh_root.join("hosts");
        fs::create_dir_all(&include_root).unwrap();
        fs::write(
            ssh_root.join("config"),
            "Include hosts/*.conf\nHost buildbox *.internal !blocked duplicate\n",
        )
        .unwrap();
        fs::write(include_root.join("a.conf"), "Host mini duplicate\n  HostName 192.0.2.10\n")
            .unwrap();
        fs::write(include_root.join("b.conf"), "Host=quoted-host # note\n").unwrap();

        assert_eq!(
            ssh_config_hosts_from_path(&ssh_root.join("config"), &ssh_root, home),
            vec!["mini", "duplicate", "quoted-host", "buildbox"]
        );
    }

    #[test]
    fn ssh_config_discovery_breaks_include_cycles() {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path();
        let ssh_root = home.join(".ssh");
        fs::create_dir_all(&ssh_root).unwrap();
        fs::write(ssh_root.join("config"), "Include loop\nHost root\n").unwrap();
        fs::write(ssh_root.join("loop"), "Include config\nHost nested\n").unwrap();

        assert_eq!(
            ssh_config_hosts_from_path(&ssh_root.join("config"), &ssh_root, home),
            vec!["nested", "root"]
        );
    }

    #[test]
    fn configured_targets_are_deduplicated_in_one_pass() {
        let machine = MachineConfig {
            id: "mini".into(),
            name: "Mini".into(),
            subtitle: "local".into(),
            target: MachineTargetConfig::Unix { socket: PathBuf::from("/tmp/mini.sock") },
        };
        let runtime =
            MachineRuntime::new(PathBuf::from("/tmp/current.sock"), vec![machine.clone(), machine]);

        assert_eq!(runtime.snapshot(runtime.initial_key()).machines.len(), 2);
    }

    #[test]
    fn prototype_creation_sources_add_local_catalog_entries_without_provisioning() {
        let mut runtime = MachineRuntime::with_creation_sources(
            PathBuf::from("/tmp/current.sock"),
            Vec::new(),
            vec![MachineCreationSourceConfig {
                id: "docker".into(),
                name: "Docker".into(),
                subtitle: "container prototype".into(),
            }],
        );
        let active = runtime.initial_key();

        let ui = runtime.ui_state(active);
        assert!(ui.snapshot.capabilities.create);
        assert_eq!(ui.creation_sources[0].id, "docker");

        let (first, first_name) = runtime.create_from("docker").unwrap();
        let (second, second_name) = runtime.create_from("docker").unwrap();
        assert_ne!(first, second);
        assert_eq!(first_name, "Docker 1");
        assert_eq!(second_name, "Docker 2");
        let snapshot = runtime.snapshot(active);
        assert_eq!(snapshot.machines.len(), 3);
        assert_eq!(snapshot.machines[1].id, "prototype:docker:1");
        assert!(matches!(
            runtime.entry(first).map(|entry| &entry.target),
            Some(MachineTargetConfig::Unix { socket }) if socket == &PathBuf::from("/tmp/current.sock")
        ));
    }

    #[test]
    fn external_catalog_has_no_implicit_machine_and_uses_disjoint_keys() {
        let machine = MachineConfig {
            id: "mini".into(),
            name: "Mini".into(),
            subtitle: "local".into(),
            target: MachineTargetConfig::Unix { socket: PathBuf::from("/tmp/mini.sock") },
        };
        let runtime = MachineRuntime::external(vec![machine], false);
        let snapshot = runtime.snapshot_with_active(None);

        assert_eq!(snapshot.machines.len(), 1);
        assert!(snapshot.machines[0].key.0 >= CLIENT_MACHINE_KEY_START);
        assert_eq!(snapshot.active, None);
        assert!(!snapshot.capabilities.connect);
    }

    #[test]
    fn disabled_external_catalog_rejects_ephemeral_targets() {
        let mut runtime = MachineRuntime::external(Vec::new(), false);
        let error = runtime.connect_machine("mini.local").unwrap_err().to_string();
        assert!(error.contains("cannot connect external machines"), "{error}");
    }

    #[test]
    fn ssh_transport_is_noninteractive_and_fail_closed() {
        let arguments = ssh_arguments(
            "mini.local",
            Some("lawrence"),
            Some(2200),
            Some(Path::new("/tmp/cloud key")),
            "agent's work",
            "/opt/cmux tui",
        )
        .into_iter()
        .map(|argument| argument.to_string_lossy().into_owned())
        .collect::<Vec<_>>();

        for option in [
            "BatchMode=yes",
            "StrictHostKeyChecking=yes",
            "ForwardAgent=no",
            "ForwardX11=no",
            "ClearAllForwardings=yes",
        ] {
            assert!(arguments.windows(2).any(|pair| pair == ["-o", option]), "{arguments:?}");
        }
        assert!(arguments.windows(2).any(|pair| pair == ["-p", "2200"]));
        assert!(arguments.windows(2).any(|pair| pair == ["-i", "/tmp/cloud key"]));
        let separator = arguments.iter().position(|argument| argument == "--").unwrap();
        assert_eq!(arguments[separator + 1], "lawrence@mini.local");
        assert_eq!(
            arguments[separator + 2],
            "'/opt/cmux tui' relay --session 'agent'\"'\"'s work'"
        );
    }
}
