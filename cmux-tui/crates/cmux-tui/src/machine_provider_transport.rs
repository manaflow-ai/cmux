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
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, SyncSender};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use cmux_tui_machine_protocol::BearerToken;

use crate::process_diagnostics::BoundedDiagnosticBuffer;

const PROVIDER_WRITE_TIMEOUT: Duration = Duration::from_secs(5);
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

    #[cfg(test)]
    fn diagnostic(&self) -> Option<String> {
        self.guard.diagnostic()
    }
}

pub(crate) struct ProviderIoParts {
    pub(crate) reader: Box<dyn Read + Send>,
    pub(crate) writer: Box<dyn Write + Send>,
    pub(crate) guard: ProviderIoGuard,
}

trait ProviderIoCleanup: Send + Sync {
    fn close(&self);

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

    /// Compatibility seam for callers that still perform `hello` separately.
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
    pub(crate) fn new(destination: impl Into<OsString>) -> io::Result<Self> {
        Self::with_program("ssh", destination)
    }

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

    fn with_program(
        ssh_program: impl Into<OsString>,
        destination: impl Into<OsString>,
    ) -> io::Result<Self> {
        let ssh_program = ssh_program.into();
        if ssh_program.is_empty() {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "SSH program is empty"));
        }
        let destination = destination.into();
        validate_ssh_destination(&destination)?;
        Ok(Self { ssh_program, destination, port: None, identity_file: None })
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
    let mut command = Command::new(program);
    command
        .args(arguments)
        .env_remove("CMUX_MACHINE_PROVIDER_TOKEN")
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

    let diagnostics = Arc::new(BoundedDiagnosticBuffer::new(COMMAND_DIAGNOSTIC_BYTES));
    let cleanup = Arc::new(ProcessCleanup {
        child: Mutex::new(Some(child)),
        diagnostics: Arc::clone(&diagnostics),
        redactions,
        stderr_worker: Mutex::new(None),
        closed: AtomicBool::new(false),
    });
    let worker_diagnostics = Arc::clone(&diagnostics);
    let worker = thread::Builder::new()
        .name("machine-provider-stderr".to_string())
        .spawn(move || worker_diagnostics.drain(stderr));
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
    child: Mutex<Option<Child>>,
    diagnostics: Arc<BoundedDiagnosticBuffer>,
    redactions: Arc<Vec<String>>,
    stderr_worker: Mutex<Option<JoinHandle<()>>>,
    closed: AtomicBool,
}

impl ProcessCleanup {
    fn terminate_and_reap(&self) {
        if !self.closed.swap(true, Ordering::AcqRel)
            && let Ok(mut child) = self.child.lock()
            && let Some(mut child) = child.take()
        {
            match child.try_wait() {
                Ok(Some(_)) => {}
                Ok(None) | Err(_) => {
                    let _ = child.kill();
                    let _ = child.wait();
                }
            }
        }
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

    fn diagnostic(&self) -> Option<String> {
        self.diagnostics.sanitized(&self.redactions)
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
    bytes.fill(0);
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
    bytes.fill(0);
    Ok(encoded)
}

fn validate_ssh_destination(destination: &OsStr) -> io::Result<()> {
    let Some(destination) = destination.to_str() else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "SSH destination is not valid UTF-8",
        ));
    };
    if destination.is_empty()
        || destination.starts_with('-')
        || destination.chars().any(char::is_control)
    {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "SSH destination is invalid"));
    }
    Ok(())
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
    use std::io::{BufRead, BufReader};
    use std::os::unix::fs::PermissionsExt;
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
            fs::write(&path, format!("#!/bin/sh\nset -eu\n{body}\n"))
                .expect("write provider test script");
            fs::set_permissions(&path, fs::Permissions::from_mode(0o700))
                .expect("make provider test script executable");
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
    fn command_connector_executes_literal_argv_without_a_shell_or_token_leak() {
        let directory = TestDirectory::new();
        let arguments = directory.path.join("arguments");
        let environment = directory.path.join("environment");
        let injected = directory.path.join("injected");
        let script = directory.script(
            "record",
            "arguments=$1; environment=$2; shift 2; printf '%s\\n' \"$@\" > \"$arguments\"; env > \"$environment\"; while IFS= read -r _line; do :; done",
        );
        let metacharacters =
            format!("$(touch {}) ; touch {}", injected.display(), injected.display());
        let connector = CommandProviderConnector::new([
            script.into_os_string(),
            arguments.clone().into_os_string(),
            environment.clone().into_os_string(),
            OsString::from(&metacharacters),
        ])
        .expect("create command connector");

        let connection = connector.connect().expect("open command control");
        let (token, control, _) = connection.into_parts();
        wait_for_file(&arguments);
        wait_for_file(&environment);
        let recorded_arguments = fs::read_to_string(arguments).expect("read recorded arguments");
        let recorded_environment = fs::read_to_string(environment).expect("read environment");
        assert!(recorded_arguments.lines().any(|argument| argument == metacharacters));
        assert_eq!(recorded_arguments.lines().last(), Some("control"));
        assert!(!injected.exists(), "metacharacters were evaluated by a shell");
        assert!(!recorded_arguments.contains(token.expose()));
        assert!(!recorded_environment.contains(token.expose()));
        drop(control);
    }

    #[test]
    fn command_connector_uses_fresh_bearers_and_processes_for_every_descriptor() {
        let directory = TestDirectory::new();
        let records = directory.path.join("records");
        let script = directory.script(
            "record-process",
            "records=$1; shift; printf '%s:%s\\n' \"$$\" \"$1\" >> \"$records\"; while IFS= read -r _line; do :; done",
        );
        let connector = CommandProviderConnector::new([
            script.into_os_string(),
            records.clone().into_os_string(),
        ])
        .expect("create command connector");

        let first = connector.connect().expect("open first generation");
        let (first_token, first_control, first_streams) = first.into_parts();
        let first_stream = first_streams.open().expect("open first stream");
        let second_stream = first_streams.open().expect("open second stream");
        let second = connector.connect().expect("open second generation");
        let (second_token, second_control, _) = second.into_parts();
        assert_ne!(first_token.expose(), second_token.expose());
        assert!(first_token.expose().len() >= 32);

        let deadline = Instant::now() + Duration::from_secs(10);
        let lines = loop {
            let lines = fs::read_to_string(&records).unwrap_or_default();
            if lines.lines().count() >= 4 {
                break lines;
            }
            assert!(Instant::now() < deadline, "timed out waiting for command records");
            thread::sleep(Duration::from_millis(10));
        };
        let mut process_ids = lines
            .lines()
            .map(|line| line.split_once(':').expect("pid and role"))
            .collect::<Vec<_>>();
        process_ids.sort_unstable();
        process_ids.dedup();
        assert_eq!(process_ids.len(), 4, "each descriptor must own a distinct process");
        assert_eq!(lines.lines().filter(|line| line.ends_with(":control")).count(), 2);
        assert_eq!(lines.lines().filter(|line| line.ends_with(":stream")).count(), 2);
        drop((first_stream, second_stream, first_control, second_control));
    }

    #[test]
    fn dropping_command_io_kills_and_reaps_its_child() {
        let directory = TestDirectory::new();
        let pid_path = directory.path.join("pid");
        let script = directory.script(
            "block",
            "pid_path=$1; shift; printf '%s' \"$$\" > \"$pid_path\"; while IFS= read -r _line; do :; done",
        );
        let connector = CommandProviderConnector::new([
            script.into_os_string(),
            pid_path.clone().into_os_string(),
        ])
        .expect("create command connector");
        let connection = connector.connect().expect("start provider child");
        let (_, control, _) = connection.into_parts();
        wait_for_file(&pid_path);
        let pid = fs::read_to_string(&pid_path)
            .expect("read child pid")
            .parse::<i32>()
            .expect("parse child pid");
        drop(control);

        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let alive = unsafe { libc::kill(pid, 0) } == 0;
            if !alive {
                break;
            }
            assert!(Instant::now() < deadline, "provider child {pid} survived cleanup");
            thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn command_stderr_is_drained_bounded_sanitized_and_token_redacted() {
        let directory = TestDirectory::new();
        let ready = directory.path.join("ready");
        let script = directory.script(
            "stderr",
            "ready=$1; shift; IFS= read -r secret; printf '%s\\n' \"$secret\" >&2; printf ready > \"$ready\"; i=0; while [ $i -lt 20000 ]; do printf 'unsafe\\033[31m diagnostic '; i=$((i + 1)); done >&2; while IFS= read -r _line; do :; done",
        );
        let connector = CommandProviderConnector::new([
            script.into_os_string(),
            ready.clone().into_os_string(),
        ])
        .expect("create command connector");
        let connection = connector.connect().expect("start provider child");
        let (token, mut control, _) = connection.into_parts();
        control
            .writer
            .write_all(format!("{}\n", token.expose()).as_bytes())
            .expect("send token-shaped input");
        control.writer.flush().expect("flush token-shaped input");
        wait_for_file(&ready);

        let deadline = Instant::now() + Duration::from_secs(10);
        let diagnostic = loop {
            let diagnostic = control.diagnostic().unwrap_or_default();
            if diagnostic.contains("[truncated]") {
                break diagnostic;
            }
            assert!(Instant::now() < deadline, "timed out draining provider stderr");
            thread::sleep(Duration::from_millis(10));
        };
        assert!(diagnostic.len() <= COMMAND_DIAGNOSTIC_BYTES + 32);
        assert!(!diagnostic.contains('\u{1b}'));
        assert!(!diagnostic.contains(token.expose()));
        drop(control);
    }

    #[test]
    fn ssh_connector_uses_one_private_master_path_and_fixed_remote_commands() {
        let directory = TestDirectory::new();
        let records = directory.path.join("ssh-arguments");
        let fake_ssh = directory.script(
            "ssh",
            "records=$(dirname \"$0\")/ssh-arguments; printf '%s\\t%s\\n' \"$$\" \"$*\" >> \"$records\"; while IFS= read -r _line; do :; done",
        );

        let connector = SshProviderConnector::with_program(fake_ssh, "cmux.cloud")
            .expect("create SSH connector");
        let connection = connector.connect().expect("open SSH control");
        let (token, control, streams) = connection.into_parts();
        let stream = streams.open().expect("open SSH stream");
        let deadline = Instant::now() + Duration::from_secs(10);
        let lines = loop {
            let lines = fs::read_to_string(&records).unwrap_or_default();
            if lines.lines().count() >= 2 {
                break lines;
            }
            assert!(Instant::now() < deadline, "timed out waiting for SSH argv records");
            thread::sleep(Duration::from_millis(10));
        };
        let lines = lines.lines().collect::<Vec<_>>();
        let control_line = lines
            .iter()
            .find(|line| line.ends_with("cmux provider control"))
            .expect("control command");
        let stream_line = lines
            .iter()
            .find(|line| line.ends_with("cmux provider stream"))
            .expect("stream command");
        assert!(control_line.contains("ControlMaster=yes"));
        assert!(stream_line.contains("ControlMaster=no"));
        let control_path = control_line
            .split_whitespace()
            .find(|argument| argument.starts_with("ControlPath="))
            .expect("control path");
        assert!(stream_line.split_whitespace().any(|argument| argument == control_path));
        let path = PathBuf::from(control_path.trim_start_matches("ControlPath="));
        let control_directory = path.parent().expect("control directory").to_path_buf();
        let directory_mode = fs::metadata(&control_directory)
            .expect("control directory metadata")
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(directory_mode, 0o700);
        assert!(!lines.join("\n").contains(token.expose()));
        drop((stream, control, streams));
        assert!(!control_directory.exists());
    }

    #[test]
    fn cloud_ssh_connector_emits_host_user_port_identity_and_exact_remote_command() {
        let directory = TestDirectory::new();
        let records = directory.path.join("cloud-ssh-arguments");
        let fake_ssh = directory.script(
            "cloud-ssh",
            "records=$(dirname \"$0\")/cloud-ssh-arguments; temporary=$records.$$; printf '%s\\n' \"$@\" > \"$temporary\"; mv \"$temporary\" \"$records\"; while IFS= read -r _line; do :; done",
        );
        let identity = directory.path.join("cloud identity");
        let connector = SshProviderConnector::cloud_with_program(
            fake_ssh,
            "edge.example.com",
            Some("lawrence"),
            Some(2200),
            Some(identity.clone()),
        )
        .expect("create configured cloud SSH connector");

        let connection = connector.connect().expect("open cloud SSH control");
        let (token, control, _) = connection.into_parts();
        wait_for_file(&records);
        let arguments = fs::read_to_string(records).expect("read cloud SSH argv");
        let arguments = arguments.lines().collect::<Vec<_>>();

        assert!(arguments.windows(2).any(|pair| pair == ["-p", "2200"]));
        assert!(
            arguments
                .windows(2)
                .any(|pair| { pair[0] == "-i" && pair[1] == identity.to_string_lossy().as_ref() })
        );
        assert!(arguments.windows(5).any(|tail| {
            tail == ["--", "lawrence@edge.example.com", "cmux", "provider", "control"]
        }));
        assert!(!arguments.iter().any(|argument| argument.contains(token.expose())));
        drop(control);
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

    #[test]
    fn rejects_ssh_option_injection_in_destination() {
        assert!(SshProviderConnector::new("-oProxyCommand=bad").is_err());
        assert!(SshProviderConnector::new(OsString::new()).is_err());
        assert!(SshProviderConnector::cloud("-oProxyCommand=bad", None, None, None).is_err());
        assert!(SshProviderConnector::cloud("cmux.cloud", Some("bad user"), None, None).is_err());
        assert!(SshProviderConnector::cloud("cmux.cloud", None, Some(0), None).is_err());
    }

    #[test]
    fn deadline_interrupts_a_blocked_provider_pipe() {
        let directory = TestDirectory::new();
        let script = directory.script("block-forever", "while IFS= read -r _line; do :; done");
        let connector = CommandProviderConnector::new([script.into_os_string()])
            .expect("create command connector");
        let connection = connector.connect().expect("open command control");
        let (_, control, _) = connection.into_parts();
        let ProviderIoParts { reader, writer: _writer, guard } = control.into_parts();
        let deadline = guard.deadline(Duration::from_millis(25)).expect("start deadline");
        let mut reader = BufReader::new(reader);
        let mut line = String::new();
        assert_eq!(reader.read_line(&mut line).expect("deadline closes pipe"), 0);
        assert!(deadline.timed_out());
    }
}
