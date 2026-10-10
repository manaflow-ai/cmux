//! Transport-neutral byte streams for the machine-provider protocol.
//!
//! A connector creates one control generation. The generation owns its bearer
//! credential and the factory used to open one fresh byte stream for every
//! provider-issued machine ticket. Protocol framing remains in
//! `machine_provider_client`; this module only owns endpoints and lifetimes.

use std::ffi::{OsStr, OsString};
use std::fs::{self, DirBuilder};
use std::io::{self, Read, Write};
use std::os::unix::fs::DirBuilderExt;
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, SyncSender};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use cmux_tui_machine_protocol::BearerToken;
use zeroize::Zeroize;

use crate::process_diagnostics::BoundedDiagnosticBuffer;

const PROVIDER_WRITE_TIMEOUT: Duration = Duration::from_secs(5);
const COMMAND_TERMINATION_GRACE: Duration = Duration::from_millis(250);
const COMMAND_DIAGNOSTIC_BYTES: usize = 16 * 1024;
const PRIVATE_PATH_ATTEMPTS: usize = 16;

/// Creates a fresh authenticated provider-control generation.
pub(crate) trait MachineProviderConnector: Send + Sync {
    fn connect(&self) -> io::Result<ProviderConnection>;
}

/// Opens one independent byte stream for one provider-issued transport ticket.
pub(crate) trait MachineStreamConnector: Send + Sync {
    fn open(&self) -> io::Result<ProviderIo>;
}

/// One control generation and its associated machine-stream factory.
pub(crate) struct ProviderConnection {
    token: BearerToken,
    control: ProviderIo,
    streams: Arc<dyn MachineStreamConnector>,
}

impl ProviderConnection {
    pub(crate) fn into_parts(self) -> (BearerToken, ProviderIo, Arc<dyn MachineStreamConnector>) {
        (self.token, self.control, self.streams)
    }
}

/// A full-duplex provider endpoint with an explicit shared lifetime guard.
pub(crate) struct ProviderIo {
    reader: Box<dyn Read + Send>,
    writer: Box<dyn Write + Send>,
    guard: ProviderIoGuard,
}

impl ProviderIo {
    fn new<R, W>(reader: R, writer: W, guard: ProviderIoGuard) -> Self
    where
        R: Read + Send + 'static,
        W: Write + Send + 'static,
    {
        Self { reader: Box::new(reader), writer: Box::new(writer), guard }
    }

    pub(crate) fn into_parts(self) -> ProviderIoParts {
        ProviderIoParts { reader: self.reader, writer: self.writer, guard: self.guard }
    }
}

pub(crate) struct ProviderIoParts {
    pub(crate) reader: Box<dyn Read + Send>,
    pub(crate) writer: Box<dyn Write + Send>,
    pub(crate) guard: ProviderIoGuard,
}

trait ProviderIoCleanup: Send + Sync {
    fn close(&self);

    fn add_diagnostic_redaction(&self, _secret: &str) {}

    fn diagnostic(&self) -> Option<String> {
        None
    }
}

/// Clones keep a provider endpoint alive. `close` interrupts every clone.
#[derive(Clone)]
pub(crate) struct ProviderIoGuard {
    cleanup: Arc<dyn ProviderIoCleanup>,
}

impl ProviderIoGuard {
    fn new(cleanup: Arc<dyn ProviderIoCleanup>) -> Self {
        Self { cleanup }
    }

    pub(crate) fn close(&self) {
        self.cleanup.close();
    }

    pub(crate) fn add_diagnostic_redaction(&self, secret: &str) {
        self.cleanup.add_diagnostic_redaction(secret);
    }

    pub(crate) fn diagnostic(&self) -> Option<String> {
        self.cleanup.diagnostic()
    }

    /// Interrupts a blocking pipe or socket read when a handshake stalls.
    pub(crate) fn deadline(&self, timeout: Duration) -> io::Result<ProviderIoDeadline> {
        let cleanup = self.clone();
        let (cancel, cancelled) = mpsc::sync_channel(1);
        let timed_out = Arc::new(AtomicBool::new(false));
        let thread_timed_out = Arc::clone(&timed_out);
        let worker = thread::Builder::new().name("machine-provider-deadline".to_string()).spawn(
            move || {
                if cancelled.recv_timeout(timeout).is_err() {
                    thread_timed_out.store(true, Ordering::Release);
                    cleanup.close();
                }
            },
        )?;
        Ok(ProviderIoDeadline { cancel: Some(cancel), timed_out, worker: Some(worker) })
    }
}

pub(crate) struct ProviderIoDeadline {
    cancel: Option<SyncSender<()>>,
    timed_out: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
}

impl ProviderIoDeadline {
    pub(crate) fn timed_out(&self) -> bool {
        self.timed_out.load(Ordering::Acquire)
    }

    fn stop(&mut self) {
        if let Some(cancel) = self.cancel.take() {
            let _ = cancel.try_send(());
        }
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

impl Drop for ProviderIoDeadline {
    fn drop(&mut self) {
        self.stop();
    }
}

/// Existing local Unix-socket provider transport.
pub(crate) struct UnixProviderConnector {
    socket_path: PathBuf,
    token: Option<BearerToken>,
}

impl UnixProviderConnector {
    pub(crate) fn new(socket_path: impl Into<PathBuf>, token: BearerToken) -> Self {
        Self { socket_path: socket_path.into(), token: Some(token) }
    }

    pub(crate) fn generated(socket_path: impl Into<PathBuf>) -> Self {
        Self { socket_path: socket_path.into(), token: None }
    }

    /// Test-only seam for exercising the control socket before `hello`.
    #[cfg(test)]
    pub(crate) fn open_unauthenticated(
        socket_path: impl Into<PathBuf>,
    ) -> io::Result<(ProviderIo, Arc<dyn MachineStreamConnector>)> {
        let streams = Arc::new(UnixMachineStreamConnector { socket_path: socket_path.into() });
        let control = streams.open()?;
        Ok((control, streams))
    }
}

impl MachineProviderConnector for UnixProviderConnector {
    fn connect(&self) -> io::Result<ProviderConnection> {
        let token = match &self.token {
            Some(token) => token.clone(),
            None => random_bearer_token()?,
        };
        let streams =
            Arc::new(UnixMachineStreamConnector { socket_path: self.socket_path.clone() });
        let control = streams.open()?;
        Ok(ProviderConnection { token, control, streams })
    }
}

struct UnixMachineStreamConnector {
    socket_path: PathBuf,
}

impl MachineStreamConnector for UnixMachineStreamConnector {
    fn open(&self) -> io::Result<ProviderIo> {
        let writer = UnixStream::connect(&self.socket_path)?;
        writer.set_write_timeout(Some(PROVIDER_WRITE_TIMEOUT))?;
        let reader = writer.try_clone()?;
        let cleanup =
            Arc::new(UnixCleanup { stream: writer.try_clone()?, closed: AtomicBool::new(false) });
        Ok(ProviderIo::new(reader, writer, ProviderIoGuard::new(cleanup)))
    }
}

struct UnixCleanup {
    stream: UnixStream,
    closed: AtomicBool,
}

impl ProviderIoCleanup for UnixCleanup {
    fn close(&self) {
        if !self.closed.swap(true, Ordering::AcqRel) {
            let _ = self.stream.shutdown(std::net::Shutdown::Both);
        }
    }
}

impl Drop for UnixCleanup {
    fn drop(&mut self) {
        self.close();
    }
}

/// Directly executes an arbitrary argv prefix and appends `control` or `stream`.
/// No shell parses the program or its arguments.
pub(crate) struct CommandProviderConnector {
    command: CommandTemplate,
}

impl CommandProviderConnector {
    pub(crate) fn new<I, S>(argv: I) -> io::Result<Self>
    where
        I: IntoIterator<Item = S>,
        S: Into<OsString>,
    {
        Ok(Self { command: CommandTemplate::new(argv)? })
    }
}

impl MachineProviderConnector for CommandProviderConnector {
    fn connect(&self) -> io::Result<ProviderConnection> {
        let token = random_bearer_token()?;
        let redactions = Arc::new(vec![token.expose().to_string()]);
        let streams =
            Arc::new(CommandMachineStreamConnector { command: self.command.clone(), redactions });
        let control = streams.open_role(CommandRole::Control)?;
        Ok(ProviderConnection { token, control, streams })
    }
}

#[derive(Clone)]
struct CommandMachineStreamConnector {
    command: CommandTemplate,
    redactions: Arc<Vec<String>>,
}

impl CommandMachineStreamConnector {
    fn open_role(&self, role: CommandRole) -> io::Result<ProviderIo> {
        let mut arguments = self.command.arguments.as_ref().clone();
        arguments.push(OsString::from(role.as_str()));
        spawn_command(&self.command.program, &arguments, Arc::clone(&self.redactions))
    }
}

impl MachineStreamConnector for CommandMachineStreamConnector {
    fn open(&self) -> io::Result<ProviderIo> {
        self.open_role(CommandRole::Stream)
    }
}

/// OpenSSH connector used by the built-in cmux.cloud configuration.
///
/// The control command owns a private master socket. Stream commands request
/// that exact socket, while the server-side registry remains a safe fallback
/// if OpenSSH has to establish a separate connection.
pub(crate) struct SshProviderConnector {
    ssh_program: OsString,
    destination: OsString,
    port: Option<u16>,
    identity_file: Option<PathBuf>,
}

impl SshProviderConnector {
    pub(crate) fn cloud(
        host: &str,
        user: Option<&str>,
        port: Option<u16>,
        identity_file: Option<PathBuf>,
    ) -> io::Result<Self> {
        Self::cloud_with_program("ssh", host, user, port, identity_file)
    }

    fn cloud_with_program(
        ssh_program: impl Into<OsString>,
        host: &str,
        user: Option<&str>,
        port: Option<u16>,
        identity_file: Option<PathBuf>,
    ) -> io::Result<Self> {
        let ssh_program = ssh_program.into();
        if ssh_program.is_empty() {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "SSH program is empty"));
        }
        validate_ssh_host(host)?;
        if let Some(user) = user {
            validate_ssh_user(user)?;
        }
        if port == Some(0) {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "SSH port cannot be zero"));
        }
        if identity_file.as_ref().is_some_and(|path| path.as_os_str().is_empty()) {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "SSH identity file is empty"));
        }
        let destination = user.map_or_else(|| host.to_string(), |user| format!("{user}@{host}"));
        Ok(Self { ssh_program, destination: OsString::from(destination), port, identity_file })
    }
}

impl MachineProviderConnector for SshProviderConnector {
    fn connect(&self) -> io::Result<ProviderConnection> {
        let token = random_bearer_token()?;
        let redactions = Arc::new(vec![token.expose().to_string()]);
        let control_socket = Arc::new(PrivateControlSocket::create()?);
        let streams = Arc::new(SshMachineStreamConnector {
            ssh_program: self.ssh_program.clone(),
            destination: self.destination.clone(),
            port: self.port,
            identity_file: self.identity_file.clone(),
            control_socket,
            redactions,
        });
        let control = streams.open_role(CommandRole::Control)?;
        Ok(ProviderConnection { token, control, streams })
    }
}

struct SshMachineStreamConnector {
    ssh_program: OsString,
    destination: OsString,
    port: Option<u16>,
    identity_file: Option<PathBuf>,
    control_socket: Arc<PrivateControlSocket>,
    redactions: Arc<Vec<String>>,
}

impl SshMachineStreamConnector {
    fn open_role(&self, role: CommandRole) -> io::Result<ProviderIo> {
        let master = match role {
            CommandRole::Control => "yes",
            CommandRole::Stream => "no",
        };
        let path_option = format!("ControlPath={}", self.control_socket.path().display());
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
            OsString::from("-o"),
            OsString::from("PermitLocalCommand=no"),
            OsString::from("-o"),
            OsString::from(format!("ControlMaster={master}")),
            OsString::from("-o"),
            OsString::from("ControlPersist=no"),
            OsString::from("-o"),
            OsString::from(path_option),
        ];
        if let Some(port) = self.port {
            arguments.push(OsString::from("-p"));
            arguments.push(OsString::from(port.to_string()));
        }
        if let Some(identity_file) = &self.identity_file {
            arguments.push(OsString::from("-i"));
            arguments.push(identity_file.as_os_str().to_os_string());
        }
        arguments.extend([
            OsString::from("--"),
            self.destination.clone(),
            OsString::from("cmux"),
            OsString::from("provider"),
            OsString::from(role.as_str()),
        ]);
        let io = spawn_command(&self.ssh_program, &arguments, Arc::clone(&self.redactions))?;
        // Every process guard retains the directory until its process exits.
        let ProviderIoParts { reader, writer, guard } = io.into_parts();
        let guard = ProviderIoGuard::new(Arc::new(CompositeCleanup {
            process: guard,
            _control_socket: Arc::clone(&self.control_socket),
        }));
        Ok(ProviderIo { reader, writer, guard })
    }
}

impl MachineStreamConnector for SshMachineStreamConnector {
    fn open(&self) -> io::Result<ProviderIo> {
        self.open_role(CommandRole::Stream)
    }
}

struct CompositeCleanup {
    process: ProviderIoGuard,
    _control_socket: Arc<PrivateControlSocket>,
}

impl ProviderIoCleanup for CompositeCleanup {
    fn close(&self) {
        self.process.close();
    }

    fn add_diagnostic_redaction(&self, secret: &str) {
        self.process.add_diagnostic_redaction(secret);
    }

    fn diagnostic(&self) -> Option<String> {
        self.process.diagnostic()
    }
}

#[derive(Clone)]
struct CommandTemplate {
    program: OsString,
    arguments: Arc<Vec<OsString>>,
}

impl CommandTemplate {
    fn new<I, S>(argv: I) -> io::Result<Self>
    where
        I: IntoIterator<Item = S>,
        S: Into<OsString>,
    {
        let mut argv = argv.into_iter().map(Into::into);
        let program = argv.next().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "provider command is empty")
        })?;
        if program.is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "provider command program is empty",
            ));
        }
        Ok(Self { program, arguments: Arc::new(argv.collect()) })
    }
}

#[derive(Clone, Copy)]
enum CommandRole {
    Control,
    Stream,
}

impl CommandRole {
    fn as_str(self) -> &'static str {
        match self {
            Self::Control => "control",
            Self::Stream => "stream",
        }
    }
}

fn spawn_command(
    program: &OsStr,
    arguments: &[OsString],
    redactions: Arc<Vec<String>>,
) -> io::Result<ProviderIo> {
    let (stderr_cancel, stderr_cancel_worker) = UnixStream::pair()?;
    let mut command = Command::new(program);
    command
        .args(arguments)
        .env_remove("CMUX_MACHINE_PROVIDER_TOKEN")
        .env_remove("CMUX_PROVIDER_WORKSPACE_AUTHORITY")
        .process_group(0)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = command.spawn().map_err(|error| {
        io::Error::new(error.kind(), format!("failed to start machine-provider command: {error}"))
    })?;
    let stdin = child
        .stdin
        .take()
        .ok_or_else(|| io::Error::other("provider command did not expose stdin"))?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| io::Error::other("provider command did not expose stdout"))?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| io::Error::other("provider command did not expose stderr"))?;
    let process_group = match libc::pid_t::try_from(child.id()) {
        Ok(process_group) => process_group,
        Err(_) => {
            let _ = child.kill();
            let _ = child.wait();
            return Err(io::Error::other("provider process ID is invalid"));
        }
    };

    let diagnostics =
        Arc::new(BoundedDiagnosticBuffer::with_redactions(COMMAND_DIAGNOSTIC_BYTES, &redactions));
    let cleanup = Arc::new(ProcessCleanup {
        process_group,
        child: Mutex::new(Some(child)),
        diagnostics: Arc::clone(&diagnostics),
        stderr_cancel,
        stderr_worker: Mutex::new(None),
        closed: AtomicBool::new(false),
    });
    let worker_diagnostics = Arc::clone(&diagnostics);
    let worker = thread::Builder::new()
        .name("machine-provider-stderr".to_string())
        .spawn(move || worker_diagnostics.drain_cancellable(stderr, stderr_cancel_worker));
    match worker {
        Ok(worker) => {
            *cleanup
                .stderr_worker
                .lock()
                .map_err(|_| io::Error::other("provider stderr state is poisoned"))? = Some(worker);
        }
        Err(error) => {
            cleanup.close();
            return Err(error);
        }
    }

    Ok(ProviderIo::new(stdout, stdin, ProviderIoGuard::new(cleanup)))
}

struct ProcessCleanup {
    process_group: libc::pid_t,
    child: Mutex<Option<Child>>,
    diagnostics: Arc<BoundedDiagnosticBuffer>,
    stderr_cancel: UnixStream,
    stderr_worker: Mutex<Option<JoinHandle<()>>>,
    closed: AtomicBool,
}

impl ProcessCleanup {
    fn signal_group(&self, signal: libc::c_int) {
        // `spawn_command` creates a dedicated group whose ID is the direct child PID.
        let _ = unsafe { libc::kill(-self.process_group, signal) };
    }

    fn group_is_alive(&self) -> bool {
        let result = unsafe { libc::kill(-self.process_group, 0) };
        result == 0 || io::Error::last_os_error().kind() == io::ErrorKind::PermissionDenied
    }

    fn terminate_and_reap(&self) {
        if !self.closed.swap(true, Ordering::AcqRel) {
            let mut child = self.child.lock().ok().and_then(|mut child| child.take());
            self.signal_group(libc::SIGTERM);
            let deadline = Instant::now() + COMMAND_TERMINATION_GRACE;
            while self.group_is_alive() && Instant::now() < deadline {
                if let Some(child) = &mut child {
                    let _ = child.try_wait();
                }
                thread::sleep(Duration::from_millis(10));
            }
            if self.group_is_alive() {
                self.signal_group(libc::SIGKILL);
            }
            if let Some(mut child) = child {
                let _ = child.wait();
            }
        }
        let _ = self.stderr_cancel.shutdown(std::net::Shutdown::Both);
        if let Ok(mut worker) = self.stderr_worker.lock()
            && let Some(worker) = worker.take()
        {
            let _ = worker.join();
        }
    }
}

impl ProviderIoCleanup for ProcessCleanup {
    fn close(&self) {
        self.terminate_and_reap();
    }

    fn add_diagnostic_redaction(&self, secret: &str) {
        self.diagnostics.add_redaction(secret);
    }

    fn diagnostic(&self) -> Option<String> {
        self.diagnostics.sanitized()
    }
}

impl Drop for ProcessCleanup {
    fn drop(&mut self) {
        self.terminate_and_reap();
    }
}

struct PrivateControlSocket {
    directory: PathBuf,
    path: PathBuf,
}

impl PrivateControlSocket {
    fn create() -> io::Result<Self> {
        let base = if cfg!(target_os = "macos") {
            Path::new("/tmp").to_path_buf()
        } else {
            std::env::temp_dir()
        };
        for _ in 0..PRIVATE_PATH_ATTEMPTS {
            let suffix = random_hex(16)?;
            let directory = base.join(format!("cmux-provider-{suffix}"));
            let mut builder = DirBuilder::new();
            builder.mode(0o700);
            match builder.create(&directory) {
                Ok(()) => {
                    let path = directory.join("master.sock");
                    return Ok(Self { directory, path });
                }
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(error),
            }
        }
        Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "could not allocate a private SSH control directory",
        ))
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for PrivateControlSocket {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
        let _ = fs::remove_dir(&self.directory);
    }
}

fn random_bearer_token() -> io::Result<BearerToken> {
    let mut bytes = [0_u8; 32];
    getrandom::fill(&mut bytes)
        .map_err(|_| io::Error::other("cryptographic randomness is unavailable"))?;
    let encoded = URL_SAFE_NO_PAD.encode(bytes);
    bytes.zeroize();
    BearerToken::new(encoded).map_err(|_| io::Error::other("generated bearer token was invalid"))
}

fn random_hex(byte_count: usize) -> io::Result<String> {
    let mut bytes = vec![0_u8; byte_count];
    getrandom::fill(&mut bytes)
        .map_err(|_| io::Error::other("cryptographic randomness is unavailable"))?;
    let mut encoded = String::with_capacity(byte_count * 2);
    for byte in &bytes {
        use std::fmt::Write as _;
        let _ = write!(encoded, "{byte:02x}");
    }
    bytes.zeroize();
    Ok(encoded)
}

fn validate_ssh_host(host: &str) -> io::Result<()> {
    if host.is_empty()
        || host.starts_with('-')
        || host.contains('@')
        || host.chars().any(|character| character.is_control() || character.is_whitespace())
    {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "SSH host is invalid"));
    }
    Ok(())
}

fn validate_ssh_user(user: &str) -> io::Result<()> {
    if user.is_empty()
        || user.starts_with('-')
        || user.contains('@')
        || user.chars().any(|character| character.is_control() || character.is_whitespace())
    {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "SSH user is invalid"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    #[cfg(unix)]
    use crate::test_exec::write_executable;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{Duration, Instant};

    use super::*;

    static NEXT_TEST_DIRECTORY: AtomicU64 = AtomicU64::new(1);

    struct TestDirectory {
        path: PathBuf,
    }

    impl TestDirectory {
        fn new() -> Self {
            let sequence = NEXT_TEST_DIRECTORY.fetch_add(1, Ordering::Relaxed);
            // Darwin limits Unix-domain socket paths to 103 bytes. macOS's
            // per-user temporary directory can consume most of that budget.
            let base = if cfg!(target_os = "macos") {
                Path::new("/tmp").to_path_buf()
            } else {
                std::env::temp_dir()
            };
            let path = base.join(format!("cmux-pt-{}-{sequence}", std::process::id()));
            let _ = fs::remove_dir_all(&path);
            fs::create_dir(&path).expect("create transport test directory");
            Self { path }
        }

        fn script(&self, name: &str, body: &str) -> PathBuf {
            let path = self.path.join(name);
            write_executable(&path, format!("#!/bin/sh\nset -eu\n{body}\n"));
            path
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }

    fn wait_for_file(path: &Path) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while !path.exists() {
            assert!(Instant::now() < deadline, "timed out waiting for {}", path.display());
            thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn command_connector_does_not_inherit_provider_capability_secrets() {
        const CHILD_MARKER: &str = "CMUX_PROVIDER_ENV_TEST_CHILD";
        if std::env::var_os(CHILD_MARKER).is_some() {
            let directory = TestDirectory::new();
            let environment = directory.path.join("environment");
            let complete = directory.path.join("complete");
            let script = directory.script(
                "record-environment",
                "environment=$1; complete=$2; env > \"$environment.tmp\"; mv \"$environment.tmp\" \"$environment\"; printf 'done\\n' > \"$complete\"; while IFS= read -r _line; do :; done",
            );
            let connector = CommandProviderConnector::new([
                script.into_os_string(),
                environment.clone().into_os_string(),
                complete.clone().into_os_string(),
            ])
            .expect("create command connector");
            let connection = connector.connect().expect("open command control");
            let (_, control, _) = connection.into_parts();
            wait_for_file(&complete);
            let recorded_environment = fs::read_to_string(environment).expect("read environment");
            assert!(
                !recorded_environment
                    .lines()
                    .any(|line| line.starts_with("CMUX_MACHINE_PROVIDER_TOKEN=")),
                "machine provider token reached child environment"
            );
            assert!(
                !recorded_environment
                    .lines()
                    .any(|line| line.starts_with("CMUX_PROVIDER_WORKSPACE_AUTHORITY=")),
                "provider workspace authority reached child environment"
            );
            drop(control);
            return;
        }

        let helper_test = format!(
            "{}::command_connector_does_not_inherit_provider_capability_secrets",
            module_path!()
        );
        let output =
            Command::new(std::env::current_exe().expect("locate provider environment test binary"))
                .arg("--exact")
                .arg(&helper_test)
                .arg("--nocapture")
                .env(CHILD_MARKER, "1")
                .env("CMUX_MACHINE_PROVIDER_TOKEN", "provider-token-test")
                .env("CMUX_PROVIDER_WORKSPACE_AUTHORITY", "provider-authority-test")
                .output()
                .expect("run provider environment test helper");
        assert!(
            output.status.success(),
            "provider environment test helper failed:\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    #[test]
    fn unix_connector_preserves_fixed_token_and_opens_distinct_sockets() {
        use std::os::unix::net::UnixListener;

        let directory = TestDirectory::new();
        let socket_path = directory.path.join("provider.sock");
        let listener = UnixListener::bind(&socket_path).expect("bind provider socket");
        let connector = UnixProviderConnector::new(
            socket_path,
            BearerToken::new("fixed-token").expect("fixed token"),
        );
        let connection = connector.connect().expect("connect Unix control");
        let (token, control, streams) = connection.into_parts();
        let (_accepted_control, _) = listener.accept().expect("accept control");
        let stream = streams.open().expect("connect Unix stream");
        let (_accepted_stream, _) = listener.accept().expect("accept stream");
        assert_eq!(token.expose(), "fixed-token");
        drop((stream, control));
    }

    #[test]
    fn generated_unix_connector_uses_a_fresh_client_side_bearer_per_generation() {
        use std::os::unix::net::UnixListener;

        let directory = TestDirectory::new();
        let socket_path = directory.path.join("generated-provider.sock");
        let listener = UnixListener::bind(&socket_path).expect("bind provider socket");
        let connector = UnixProviderConnector::generated(socket_path);

        let first = connector.connect().expect("connect first generation");
        let (_first_socket, _) = listener.accept().expect("accept first generation");
        let second = connector.connect().expect("connect second generation");
        let (_second_socket, _) = listener.accept().expect("accept second generation");
        let (first_token, first_control, _) = first.into_parts();
        let (second_token, second_control, _) = second.into_parts();

        assert_ne!(first_token.expose(), second_token.expose());
        assert!(first_token.expose().len() >= 32);
        assert!(second_token.expose().len() >= 32);
        drop((first_control, second_control));
    }
}
