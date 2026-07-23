//! Config-backed machine catalog and transport connectors.

use std::collections::HashSet;
use std::ffi::OsString;
#[cfg(test)]
use std::io::Read;
use std::io::{self, BufRead, BufReader, Write};
#[cfg(unix)]
use std::os::unix::net::UnixStream;
#[cfg(unix)]
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
#[cfg(unix)]
use std::time::{Duration, Instant};

use crate::config::{MachineConfig, MachineTargetConfig};
use crate::machine::{
    MachineCapabilities, MachineDescriptor, MachineKey, MachineSnapshot, MachineStatus,
};
use crate::process_diagnostics::BoundedDiagnosticBuffer;
use crate::session::{
    RemoteMessageReader, RemoteMessageWriter, RemoteSession, RemoteTransport, Session,
};

const SSH_DIAGNOSTIC_BYTES: usize = 4096;
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
}

impl MachineRuntime {
    pub fn new(current_socket: PathBuf, configured: Vec<MachineConfig>) -> Self {
        let current_name = local_hostname().unwrap_or_else(|| "this machine".to_string());
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
        let mut runtime =
            Self { entries: Vec::new(), next_key: CLIENT_MACHINE_KEY_START, connect_enabled };
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

    pub fn snapshot(&self, active: MachineKey) -> MachineSnapshot {
        self.snapshot_with_active(Some(active))
    }

    pub fn snapshot_with_active(&self, active: Option<MachineKey>) -> MachineSnapshot {
        MachineSnapshot {
            machines: self.entries.iter().map(|entry| entry.descriptor.clone()).collect(),
            active,
            capabilities: MachineCapabilities { create: false, connect: self.connect_enabled },
        }
    }

    pub fn contains(&self, key: MachineKey) -> bool {
        self.entry(key).is_some()
    }

    pub fn name(&self, key: MachineKey) -> Option<&str> {
        self.entry(key).map(|entry| entry.descriptor.name.as_str())
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
    identity_file: Option<&std::path::Path>,
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
        Box::new(ProcessWriter { inner: stdin, process }),
    ))
}

fn ssh_arguments(
    host: &str,
    user: Option<&str>,
    port: Option<u16>,
    identity_file: Option<&std::path::Path>,
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

impl RemoteMessageReader for ProcessReader {
    fn receive(&mut self) -> io::Result<Option<String>> {
        let _keep_alive = &self.process;
        let mut message = String::new();
        if self.inner.read_line(&mut message)? == 0 {
            if let Some(diagnostic) = self.process.diagnostic_after_stdout_eof() {
                return Err(io::Error::other(format!("ssh transport closed: {diagnostic}")));
            }
            return Ok(None);
        }
        if message.ends_with('\n') {
            message.pop();
            if message.ends_with('\r') {
                message.pop();
            }
        }
        Ok(Some(message))
    }
}

struct ProcessWriter {
    inner: ChildStdin,
    process: Arc<Process>,
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
            Some(std::path::Path::new("/tmp/cloud key")),
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
