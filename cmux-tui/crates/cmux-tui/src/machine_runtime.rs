//! Config-backed machine catalog and transport connectors.

#[cfg(test)]
use std::io::Read;
use std::io::{self, BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};

use crate::config::{MachineConfig, MachineTargetConfig};
use crate::machine::{
    MachineCapabilities, MachineDescriptor, MachineKey, MachineSnapshot, MachineStatus,
};
use crate::process_diagnostics::BoundedDiagnosticBuffer;
use crate::session::{
    RemoteMessageReader, RemoteMessageWriter, RemoteSession, RemoteTransport, Session,
};

const SSH_DIAGNOSTIC_BYTES: usize = 4096;

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
        };
        for machine in configured {
            if runtime.entries.iter().any(|entry| entry.descriptor.id == machine.id) {
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
        MachineSnapshot {
            machines: self.entries.iter().map(|entry| entry.descriptor.clone()).collect(),
            active: Some(active),
            capabilities: MachineCapabilities { create: false, connect: true },
        }
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
    let destination = user.map_or_else(|| host.to_string(), |user| format!("{user}@{host}"));
    let remote_command =
        format!("{} relay --session {}", shell_quote(binary), shell_quote(session));
    let mut command = Command::new("ssh");
    command.arg("-T");
    if let Some(port) = port {
        command.arg("-p").arg(port.to_string());
    }
    if let Some(identity_file) = identity_file {
        command.arg("-i").arg(identity_file);
    }
    command
        .arg("--")
        .arg(destination)
        .arg(remote_command)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let (stdin, stdout, process) = spawn_transport_process(&mut command)?;
    Ok(RemoteTransport::new(
        Box::new(ProcessReader { inner: BufReader::new(stdout), process: process.clone() }),
        Box::new(ProcessWriter { inner: stdin, process }),
    ))
}

fn spawn_transport_process(
    command: &mut Command,
) -> anyhow::Result<(ChildStdin, ChildStdout, Arc<Process>)> {
    let mut child =
        command.spawn().map_err(|error| anyhow::anyhow!("cannot start ssh: {error}"))?;
    let stdin = child.stdin.take().ok_or_else(|| anyhow::anyhow!("ssh stdin unavailable"))?;
    let stdout = child.stdout.take().ok_or_else(|| anyhow::anyhow!("ssh stdout unavailable"))?;
    let stderr = child.stderr.take().ok_or_else(|| anyhow::anyhow!("ssh stderr unavailable"))?;
    let diagnostics = Arc::new(BoundedDiagnosticBuffer::new(SSH_DIAGNOSTIC_BYTES));
    let worker_diagnostics = Arc::clone(&diagnostics);
    let worker = thread::Builder::new()
        .name("machine-ssh-stderr".to_string())
        .spawn(move || worker_diagnostics.drain(stderr));
    let worker = match worker {
        Ok(worker) => worker,
        Err(error) => {
            let _ = child.kill();
            let _ = child.wait();
            return Err(anyhow::anyhow!("cannot monitor ssh diagnostics: {error}"));
        }
    };
    let process = Arc::new(Process {
        child: Mutex::new(child),
        diagnostics,
        stderr_worker: Mutex::new(Some(worker)),
    });
    Ok((stdin, stdout, process))
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

struct Process {
    child: Mutex<Child>,
    diagnostics: Arc<BoundedDiagnosticBuffer>,
    stderr_worker: Mutex<Option<JoinHandle<()>>>,
}

impl Process {
    fn diagnostic_after_stdout_eof(&self) -> Option<String> {
        let exited =
            self.child.lock().ok().and_then(|mut child| child.try_wait().ok().flatten()).is_some();
        if exited {
            self.join_stderr();
        }
        self.diagnostic()
    }

    fn diagnostic(&self) -> Option<String> {
        self.diagnostics.sanitized(&[])
    }

    fn join_stderr(&self) {
        if let Ok(mut worker) = self.stderr_worker.lock()
            && let Some(worker) = worker.take()
        {
            let _ = worker.join();
        }
    }
}

impl Drop for Process {
    fn drop(&mut self) {
        let Ok(child) = self.child.get_mut() else { return };
        if child.try_wait().ok().flatten().is_none() {
            let _ = child.kill();
        }
        let _ = child.wait();
        self.join_stderr();
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
        let mut child =
            self.process.child.lock().map_err(|_| io::Error::other("ssh lock poisoned"))?;
        if child.try_wait()?.is_none() {
            child.kill()?;
        }
        Ok(())
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

    #[test]
    fn connected_target_is_deduplicated() {
        let mut runtime = MachineRuntime::new(PathBuf::from("/tmp/current.sock"), Vec::new());
        let first = runtime.connect_machine("lawrence@mini.local").unwrap();
        let second = runtime.connect_machine("lawrence@mini.local").unwrap();
        assert_eq!(first, second);
        assert_eq!(runtime.snapshot(runtime.initial_key()).machines.len(), 2);
    }
}
