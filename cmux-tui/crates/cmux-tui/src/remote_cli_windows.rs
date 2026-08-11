//! Native Windows remote command entrypoints.

use std::fs::OpenOptions;
use std::io::{self, BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::net::Shutdown;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::time::Duration;

use anyhow::{Context, anyhow};
use cmux_remote::daemon::{DaemonSessionPolicy, RemoteDaemon, serve_windows_local};
use cmux_remote::identity::{AuthDatabase, default_state_dir};
use cmux_remote::secure_directory::{DirectoryAccess, ensure_secure_directory};
use cmux_remote::services::DaemonServices;
use cmux_remote::session::SessionLimits;
use cmux_remote::ssh_bootstrap::BUILD_IDENTITY;
use cmux_remote::workspace::WorkspaceService;
use cmux_remote_protocol::REMOTE_PROTOCOL_VERSION;
use cmux_tui_core::platform::transport;
use cmux_tui_core::{Mux, SurfaceOptions};
use fs4::FileExt;
use serde_json::{Value, json};
use windows_sys::Win32::System::Threading::{
    CREATE_BREAKAWAY_FROM_JOB, CREATE_NEW_PROCESS_GROUP, DETACHED_PROCESS, WaitForSingleObject,
};

const MAX_CARRIER_FRAME_BYTES: usize = 65_535;
const CONTROL_RESPONSE_BYTES: u64 = 64 * 1024;
const CONTROL_TIMEOUT: Duration = Duration::from_secs(5);
const OWNER_START_TIMEOUT: Duration = Duration::from_secs(10);
const OWNER_START_LOCK_TIMEOUT: Duration = Duration::from_secs(15);
const OWNER_LOG_TAIL_BYTES: u64 = 8 * 1024;
const OWNER_READY: &str = "cmux-tui-windows-owner-ready-v1";
// WSAENETDOWN is how Windows reports connect() against an orphaned AF_UNIX path.
const WINDOWS_STALE_AF_UNIX_SOCKET_ERROR: i32 = 10_050;
const REMOTE_COMMANDS: &[&str] = &[
    "connect",
    "ssh",
    "forward",
    "rpc",
    "enroll",
    "known-daemons",
    "remote-probe",
    "remote-link",
    "remote-relay",
    "remote-mux-owner",
    "remote-sidecar",
    "remote-stop",
    "install-self",
];

pub fn is_remote_invocation(args: &[String]) -> bool {
    args.first().is_some_and(|argument| REMOTE_COMMANDS.contains(&argument.as_str()))
}

pub fn run(args: &[String], _: &str) -> i32 {
    match run_inner(args) {
        Ok(()) => 0,
        Err(error) => {
            eprintln!("cmux-tui: {error:#}");
            1
        }
    }
}

fn run_inner(args: &[String]) -> anyhow::Result<()> {
    match args.first().map(String::as_str) {
        Some("ssh") => run_ssh(&args[1..]),
        Some("remote-probe") => run_probe(&args[1..]),
        Some("remote-link") => run_remote_link(&args[1..]),
        Some("remote-relay") => run_remote_relay(&args[1..]),
        Some("remote-mux-owner") => run_remote_mux_owner(&args[1..]),
        Some("remote-stop") => run_remote_stop(&args[1..]),
        Some(command) => Err(anyhow!("{command} is not implemented on Windows yet")),
        None => Err(anyhow!("missing remote command")),
    }
}

#[derive(Clone)]
pub(crate) struct ManagedSshOptions {
    pub destination: String,
    pub session: String,
    pub remote_binary: String,
    pub remote_state_dir: Option<String>,
    pub ssh_args: Vec<String>,
    pub connect_timeout: Duration,
}

pub(crate) struct ManagedSshConnection {
    pub session: crate::session::Session,
    pub lease: ManagedSshLease,
}

type ActiveSshProcesses = Arc<Mutex<Vec<Arc<Mutex<Child>>>>>;

pub(crate) struct ManagedSshLease {
    cancellation: Arc<crate::machine_runtime::MachineConnectCancellation>,
    socket_path: PathBuf,
    processes: ActiveSshProcesses,
    diagnostic: Arc<Mutex<String>>,
}

impl Drop for ManagedSshLease {
    fn drop(&mut self) {
        self.cancellation.cancel();
        wake_ssh_listener(&self.socket_path);
        kill_active_ssh_processes(&self.processes);
    }
}

pub(crate) fn validate_managed_ssh_options(options: &ManagedSshOptions) -> anyhow::Result<()> {
    parse_ssh_destination(&options.destination)?;
    validate_remote_component(&options.session, "session")?;
    validate_remote_component(&options.remote_binary, "binary")?;
    if let Some(state_dir) = &options.remote_state_dir {
        validate_remote_component(state_dir, "state directory")?;
    }
    anyhow::ensure!(!options.connect_timeout.is_zero(), "SSH connect timeout must be positive");
    Ok(())
}

pub(crate) fn connect_managed_ssh(
    options: ManagedSshOptions,
    cancellation: Arc<crate::machine_runtime::MachineConnectCancellation>,
) -> anyhow::Result<ManagedSshConnection> {
    let lease = start_managed_ssh_bridge(options.clone(), cancellation)?;
    let stream = transport::connect(&lease.socket_path).with_context(|| {
        format!("could not connect to Windows SSH bridge {}", lease.socket_path.display())
    })?;
    stream.set_read_timeout(Some(options.connect_timeout))?;
    stream.set_write_timeout(Some(options.connect_timeout))?;
    let timeout_control = stream.try_clone_box()?;
    let connected = crate::session::RemoteSession::connect_stream(stream);
    let _ = timeout_control.set_read_timeout(None);
    let _ = timeout_control.set_write_timeout(None);
    match connected {
        Ok(remote) => Ok(ManagedSshConnection {
            session: crate::session::Session::Remote(remote),
            lease,
        }),
        Err(error) => {
            let diagnostic = lease
                .diagnostic
                .lock()
                .map(|value| value.clone())
                .unwrap_or_default();
            if diagnostic.is_empty() {
                Err(error).context("Windows SSH transport did not become ready")
            } else {
                Err(error).with_context(|| format!("Windows SSH transport failed: {diagnostic}"))
            }
        }
    }
}

struct WindowsSshFlags {
    options: ManagedSshOptions,
    headless: bool,
    json: bool,
}

fn run_ssh(args: &[String]) -> anyhow::Result<()> {
    let flags = parse_windows_ssh_flags(args)?;
    let cancellation = Arc::new(crate::machine_runtime::MachineConnectCancellation::default());
    if flags.headless {
        let lease = start_managed_ssh_bridge(flags.options.clone(), Arc::clone(&cancellation))?;
        if flags.json {
            println!(
                "{}",
                json!({
                    "event": "connection-snapshot",
                    "local_socket": lease.socket_path.display().to_string(),
                    "connection": {
                        "transport": {
                            "provider": "ssh",
                            "route": format!("ssh://{}", flags.options.destination),
                        }
                    }
                })
            );
        } else {
            println!("{}", lease.socket_path.display());
        }
        io::stdout().flush()?;
        cancellation.wait_until_cancelled();
        drop(lease);
        return Ok(());
    }

    let connected = connect_managed_ssh(flags.options.clone(), cancellation)?;
    let result = crate::run_tui(
        connected.session.clone(),
        format!("ssh://{}", flags.options.destination),
        None,
    );
    drop(connected);
    result
}

fn parse_windows_ssh_flags(args: &[String]) -> anyhow::Result<WindowsSshFlags> {
    let destination = args
        .first()
        .filter(|argument| !argument.starts_with('-'))
        .cloned()
        .context("SSH destination is required")?;
    let mut session = "main".to_owned();
    let mut remote_binary = "~/.local/bin/cmux-tui".to_owned();
    let mut remote_state_dir = None;
    let mut ssh_args = Vec::new();
    let mut connect_timeout = Duration::from_secs(30);
    let mut headless = false;
    let mut json_output = false;
    let mut index = 1;
    while index < args.len() {
        match args[index].as_str() {
            "--headless" => {
                headless = true;
                index += 1;
            }
            "--json" => {
                json_output = true;
                index += 1;
            }
            "--no-install" => index += 1,
            "--session" | "--remote-binary" | "--remote-state-dir" | "--ssh-arg"
            | "--connect-timeout-seconds" | "--state-dir" => {
                let option = args[index].as_str();
                let value = args
                    .get(index + 1)
                    .ok_or_else(|| anyhow!("{option} needs a value"))?
                    .clone();
                match option {
                    "--session" => session = value,
                    "--remote-binary" => remote_binary = value,
                    "--remote-state-dir" => remote_state_dir = Some(value),
                    "--ssh-arg" => ssh_args.push(value),
                    "--connect-timeout-seconds" => {
                        let seconds = value
                            .parse::<u64>()
                            .context("--connect-timeout-seconds must be a positive integer")?;
                        connect_timeout = Duration::from_secs(seconds);
                    }
                    // The native bridge uses the private runtime directory for
                    // its short AF_UNIX path. Durable client state is not used.
                    "--state-dir" => {}
                    _ => unreachable!(),
                }
                index += 2;
            }
            option => return Err(anyhow!("unknown Windows SSH option {option:?}")),
        }
    }
    if json_output && !headless {
        return Err(anyhow!("--json requires --headless"));
    }
    let options = ManagedSshOptions {
        destination,
        session,
        remote_binary,
        remote_state_dir,
        ssh_args,
        connect_timeout,
    };
    validate_managed_ssh_options(&options)?;
    Ok(WindowsSshFlags { options, headless, json: json_output })
}

fn start_managed_ssh_bridge(
    options: ManagedSshOptions,
    cancellation: Arc<crate::machine_runtime::MachineConnectCancellation>,
) -> anyhow::Result<ManagedSshLease> {
    validate_managed_ssh_options(&options)?;
    anyhow::ensure!(!cancellation.is_cancelled(), "machine connection was canceled");
    let runtime_dir = cmux_tui_core::platform::runtime_dir();
    ensure_secure_directory(&runtime_dir, DirectoryAccess::ManagedOwnerOnly)?;
    let socket_path = runtime_dir.join(format!("ssh-{}.sock", uuid::Uuid::new_v4().simple()));
    let listener = transport::listen(&socket_path).with_context(|| {
        format!("could not create Windows SSH bridge {}", socket_path.display())
    })?;
    let processes: ActiveSshProcesses = Arc::new(Mutex::new(Vec::new()));
    let diagnostic = Arc::new(Mutex::new(String::new()));
    let worker_options = options.clone();
    let worker_cancellation = Arc::clone(&cancellation);
    let worker_processes = Arc::clone(&processes);
    let worker_diagnostic = Arc::clone(&diagnostic);
    let worker_path = socket_path.clone();
    std::thread::Builder::new().name("windows-ssh-listener".into()).spawn(move || {
        while !worker_cancellation.is_cancelled() {
            let local = match listener.accept() {
                Ok(local) => local,
                Err(error) => {
                    if !worker_cancellation.is_cancelled()
                        && let Ok(mut value) = worker_diagnostic.lock()
                    {
                        *value = format!("Windows SSH listener failed: {error}");
                    }
                    break;
                }
            };
            if worker_cancellation.is_cancelled() {
                let _ = local.shutdown(Shutdown::Both);
                break;
            }
            let options = worker_options.clone();
            let cancellation = Arc::clone(&worker_cancellation);
            let processes = Arc::clone(&worker_processes);
            let diagnostic = Arc::clone(&worker_diagnostic);
            let _ = std::thread::Builder::new()
                .name("windows-ssh-connection".into())
                .spawn(move || {
                    if let Err(error) = proxy_local_connection_over_ssh(
                        local,
                        &options,
                        Arc::clone(&cancellation),
                        &processes,
                        &diagnostic,
                    ) && let Ok(mut value) = diagnostic.lock()
                    {
                        *value = error.to_string();
                    }
                });
        }
        let _ = std::fs::remove_file(&worker_path);
    })?;
    Ok(ManagedSshLease { cancellation, socket_path, processes, diagnostic })
}

fn proxy_local_connection_over_ssh(
    mut local: Box<dyn transport::Stream>,
    options: &ManagedSshOptions,
    cancellation: Arc<crate::machine_runtime::MachineConnectCancellation>,
    processes: &ActiveSshProcesses,
    diagnostic: &Arc<Mutex<String>>,
) -> anyhow::Result<()> {
    let (destination, port) = parse_ssh_destination(&options.destination)?;
    let mut command = Command::new("ssh.exe");
    command.arg("-T");
    if let Some(port) = port {
        command.arg("-p").arg(port.to_string());
    }
    command.args(&options.ssh_args);
    command.arg(destination);
    command.arg(windows_remote_relay_command(options)?);
    command.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
    use std::os::windows::process::CommandExt;
    command.creation_flags(CREATE_NEW_PROCESS_GROUP);
    let mut child = command.spawn().context("could not start Windows OpenSSH client")?;
    let mut ssh_stdin = child.stdin.take().context("Windows OpenSSH stdin is unavailable")?;
    let mut ssh_stdout = child.stdout.take().context("Windows OpenSSH stdout is unavailable")?;
    let mut ssh_stderr = child.stderr.take().context("Windows OpenSSH stderr is unavailable")?;
    let child = Arc::new(Mutex::new(child));
    processes
        .lock()
        .map_err(|_| anyhow!("Windows SSH process registry is unavailable"))?
        .push(Arc::clone(&child));

    let mut upload = local.try_clone_box()?;
    let upload_shutdown = local.try_clone_box()?;
    let saw_shutdown = Arc::new(AtomicBool::new(false));
    let upload_saw_shutdown = Arc::clone(&saw_shutdown);
    let upload_thread = std::thread::Builder::new()
        .name("windows-ssh-upload".into())
        .spawn(move || {
            let mut buffer = [0_u8; 8 * 1024];
            let mut tail = Vec::new();
            loop {
                let size = match upload.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(size) => size,
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                    Err(_) => break,
                };
                tail.extend_from_slice(&buffer[..size]);
                if tail.windows(b"shutdown-daemon".len()).any(|bytes| bytes == b"shutdown-daemon")
                {
                    upload_saw_shutdown.store(true, Ordering::Release);
                }
                if tail.len() > 64 {
                    tail.drain(..tail.len() - 64);
                }
                if ssh_stdin.write_all(&buffer[..size]).is_err() || ssh_stdin.flush().is_err() {
                    break;
                }
            }
            drop(ssh_stdin);
            let _ = upload_shutdown.shutdown(Shutdown::Read);
        })?;

    let connection_diagnostic = Arc::new(Mutex::new(Vec::<u8>::new()));
    let stderr_bytes = Arc::clone(&connection_diagnostic);
    let stderr_thread = std::thread::Builder::new()
        .name("windows-ssh-stderr".into())
        .spawn(move || {
            let mut buffer = [0_u8; 1024];
            while let Ok(size) = ssh_stderr.read(&mut buffer) {
                if size == 0 {
                    break;
                }
                if let Ok(mut bytes) = stderr_bytes.lock() {
                    bytes.extend_from_slice(&buffer[..size]);
                    if bytes.len() > OWNER_LOG_TAIL_BYTES as usize {
                        let overflow = bytes.len() - OWNER_LOG_TAIL_BYTES as usize;
                        bytes.drain(..overflow);
                    }
                }
            }
        })?;

    let copy_result = io::copy(&mut ssh_stdout, &mut local);
    let _ = local.flush();
    let _ = local.shutdown(Shutdown::Both);
    let _ = upload_thread.join();
    let _ = stderr_thread.join();
    if let Ok(mut child) = child.lock() {
        let _ = child.wait();
    }
    if let Ok(mut active) = processes.lock() {
        active.retain(|candidate| !Arc::ptr_eq(candidate, &child));
    }
    if let Ok(bytes) = connection_diagnostic.lock() {
        let text = sanitize_diagnostic(&bytes);
        if !text.is_empty()
            && let Ok(mut value) = diagnostic.lock()
        {
            *value = text;
        }
    }
    if saw_shutdown.load(Ordering::Acquire) {
        cancellation.cancel();
    }
    copy_result.context("Windows SSH relay stopped")?;
    Ok(())
}

fn parse_ssh_destination(destination: &str) -> anyhow::Result<(String, Option<u16>)> {
    anyhow::ensure!(
        !destination.starts_with('-') && !destination.chars().any(char::is_whitespace),
        "SSH destination is invalid"
    );
    let url = url::Url::parse(&format!("ssh://{destination}"))
        .context("SSH destination is invalid")?;
    anyhow::ensure!(url.password().is_none(), "SSH destination cannot contain a password");
    anyhow::ensure!(matches!(url.path(), "" | "/"), "SSH destination cannot contain a path");
    let host = url.host_str().context("SSH destination must contain a host")?;
    let host = if host.contains(':') { format!("[{host}]") } else { host.to_owned() };
    let destination = if url.username().is_empty() {
        host
    } else {
        format!("{}@{host}", url.username())
    };
    Ok((destination, url.port()))
}

fn validate_remote_component(value: &str, label: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        !value.is_empty()
            && value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || b"_./\\%:~-".contains(&byte)),
        "remote SSH {label} is not shell-safe"
    );
    Ok(())
}

fn windows_remote_relay_command(options: &ManagedSshOptions) -> anyhow::Result<String> {
    validate_managed_ssh_options(options)?;
    let mut command = format!(
        "{} remote-relay --stdio --session {}",
        options.remote_binary, options.session
    );
    if let Some(state_dir) = &options.remote_state_dir {
        command.push_str(" --state-dir ");
        command.push_str(state_dir);
    }
    Ok(command)
}

fn wake_ssh_listener(path: &Path) {
    if let Ok(stream) = transport::connect(path) {
        let _ = stream.shutdown(Shutdown::Both);
    }
}

fn kill_active_ssh_processes(processes: &ActiveSshProcesses) {
    let children = processes.lock().map(|value| value.clone()).unwrap_or_default();
    for child in children {
        if let Ok(mut child) = child.lock() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

fn sanitize_diagnostic(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes)
        .chars()
        .map(|character| if character.is_control() { ' ' } else { character })
        .collect::<String>()
        .trim()
        .to_owned()
}

fn run_probe(args: &[String]) -> anyhow::Result<()> {
    if args.iter().any(|argument| !matches!(argument.as_str(), "--json" | "-h" | "--help")) {
        return Err(anyhow!("remote-probe accepts only --json"));
    }
    let value = serde_json::json!({
        "app": "cmux-tui",
        "version": env!("CARGO_PKG_VERSION"),
        "distribution_version": option_env!("CMUX_TUI_DISTRIBUTION_VERSION")
            .unwrap_or(env!("CARGO_PKG_VERSION")),
        "npm_bootstrap_version": option_env!("CMUX_TUI_NPM_BOOTSTRAP_VERSION"),
        "build_identity": BUILD_IDENTITY,
        "remote_protocol": REMOTE_PROTOCOL_VERSION,
        "os": std::env::consts::OS,
        "arch": std::env::consts::ARCH,
    });
    if args.iter().any(|argument| argument == "--json") {
        println!("{}", serde_json::to_string(&value)?);
    } else {
        println!(
            "cmux-tui {} remote-protocol={} {}-{}",
            env!("CARGO_PKG_VERSION"),
            REMOTE_PROTOCOL_VERSION,
            std::env::consts::OS,
            std::env::consts::ARCH
        );
    }
    Ok(())
}

struct RemoteLinkOptions {
    session: String,
    state_root: Option<PathBuf>,
}

struct WindowsSessionPaths {
    state_dir: PathBuf,
    workspace_state: PathBuf,
    mux_socket: PathBuf,
    link_socket: PathBuf,
    owner_log: PathBuf,
}

#[derive(Debug)]
struct MuxIdentity {
    pid: u32,
    generation: String,
}

fn parse_remote_link(args: &[String]) -> anyhow::Result<RemoteLinkOptions> {
    let mut session = "main".to_string();
    let mut state_root = None;
    let mut stdio = false;
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--stdio" => {
                if stdio {
                    return Err(anyhow!("remote-link received --stdio more than once"));
                }
                stdio = true;
                index += 1;
            }
            "--session" | "--state-dir" => {
                let option = args[index].as_str();
                let value = args
                    .get(index + 1)
                    .ok_or_else(|| anyhow!("remote-link {option} needs a value"))?;
                if option == "--session" {
                    session = value.clone();
                } else {
                    state_root = Some(PathBuf::from(value));
                }
                index += 2;
            }
            option => return Err(anyhow!("unknown remote-link option {option:?}")),
        }
    }
    if !stdio {
        return Err(anyhow!("remote-link currently requires --stdio"));
    }
    if session.is_empty()
        || !session.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"_.-".contains(&byte))
    {
        return Err(anyhow!("remote-link session is not path-safe"));
    }
    Ok(RemoteLinkOptions { session, state_root })
}

fn run_remote_link(args: &[String]) -> anyhow::Result<()> {
    let options = parse_remote_link(args)?;
    let paths = windows_session_paths(&options)?;
    ensure_mux_owner(&options, &paths)?;
    proxy_windows_stdio(&paths)
}

/// Start the persistent Windows owner and expose its JSONL mux protocol over
/// stdio. This private transport primitive lets the native Windows SSH client
/// use OpenSSH without translating the mux protocol or allocating a PTY.
fn run_remote_relay(args: &[String]) -> anyhow::Result<()> {
    let options = parse_remote_link(args)?;
    let paths = windows_session_paths(&options)?;
    ensure_mux_owner(&options, &paths)?;
    proxy_raw_mux_stdio(&paths.mux_socket)
}

fn windows_session_paths(options: &RemoteLinkOptions) -> anyhow::Result<WindowsSessionPaths> {
    let root = options.state_root.clone().or_else(default_state_dir).ok_or_else(|| {
        anyhow!("cannot determine Windows remote state directory; LOCALAPPDATA is unset")
    })?;
    let state_dir = root.join("sessions").join(&options.session);
    Ok(WindowsSessionPaths {
        workspace_state: state_dir.join("workspaces"),
        mux_socket: state_dir.join("mux.sock"),
        link_socket: state_dir.join("link.sock"),
        owner_log: state_dir.join("owner.log"),
        state_dir,
    })
}

fn prepare_session_state(paths: &WindowsSessionPaths) -> anyhow::Result<()> {
    ensure_secure_directory(&paths.state_dir, DirectoryAccess::ManagedOwnerOnly)
        .with_context(|| format!("could not protect {}", paths.state_dir.display()))
}

fn run_remote_mux_owner(args: &[String]) -> anyhow::Result<()> {
    let options = parse_session_options(args, "remote-mux-owner")?;
    let paths = windows_session_paths(&options)?;
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .thread_name("cmux-remote-windows-owner")
        .enable_all()
        .build()
        .context("could not start the Windows owner runtime")?
        .block_on(serve_remote_mux_owner(options, paths))
}

async fn serve_remote_mux_owner(
    options: RemoteLinkOptions,
    paths: WindowsSessionPaths,
) -> anyhow::Result<()> {
    prepare_session_state(&paths)?;

    let auth = AuthDatabase::load_or_create(&paths.state_dir, windows_daemon_name(), true)
        .context("could not open Windows remote identity")?;
    let mut surface_options = SurfaceOptions::default();
    surface_options.terminal_host_root = Some(paths.state_dir.join("terminal-host"));
    let mux = Mux::open_persistent(options.session, surface_options, &paths.workspace_state)
        .context("could not open Windows mux owner")?;
    cmux_tui_core::server::serve(mux.clone(), Some(paths.mux_socket.clone()))
        .context("could not start Windows mux control socket")?;
    let (daemon, mut accepted) =
        RemoteDaemon::with_policy(auth, SessionLimits::default(), DaemonSessionPolicy::default())?;
    let link_server =
        serve_windows_local(daemon, paths.link_socket.clone(), MAX_CARRIER_FRAME_BYTES).await?;
    let mut link_completion = link_server.completion();

    println!("{OWNER_READY}");
    io::stdout().flush().context("could not publish Windows mux readiness")?;

    let events = mux.subscribe();
    let shutdown_mux = mux.clone();
    let (shutdown_tx, mut shutdown_rx) = tokio::sync::oneshot::channel();
    std::thread::Builder::new().name("windows-owner-shutdown".into()).spawn(move || {
        loop {
            if shutdown_mux.daemon_shutdown_requested() {
                let _ = shutdown_tx.send(());
                break;
            }
            match events.recv_timeout(Duration::from_millis(250)) {
                Ok(_) | Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                    let _ = shutdown_tx.send(());
                    break;
                }
            }
        }
    })?;
    let mux_socket = paths.mux_socket.clone();
    let local = tokio::task::LocalSet::new();
    let services = local
        .run_until(async move {
            loop {
                tokio::select! {
                    _ = &mut shutdown_rx => return Ok(()),
                    result = wait_for_link_server_exit(&mut link_completion) => {
                        return match result {
                            Ok(()) => Err(anyhow!("Windows remote listener stopped unexpectedly")),
                            Err(error) => Err(anyhow!("Windows remote listener failed: {error}")),
                        };
                    }
                    client = accepted.recv() => {
                        let client = client.ok_or_else(|| {
                            anyhow!("Windows remote daemon stopped accepting clients")
                        })?;
                        let services = DaemonServices::new(
                            WorkspaceService::new(),
                            Some(mux_socket.clone()),
                        );
                        tokio::task::spawn_local(async move {
                            if let Err(error) = services.serve_client(client).await {
                                eprintln!("cmux-tui: Windows remote services failed: {error}");
                            }
                        });
                    }
                }
            }
        })
        .await;
    let link_shutdown = link_server.shutdown();
    mux.shutdown();
    cmux_tui_core::server::cleanup(&paths.mux_socket);
    services?;
    link_shutdown.context("could not stop Windows remote listener")
}

fn ensure_mux_owner(
    options: &RemoteLinkOptions,
    paths: &WindowsSessionPaths,
) -> anyhow::Result<()> {
    prepare_session_state(paths)?;
    let _start_lock = acquire_owner_start_lock(paths)?;
    if identify_mux_owner(&paths.mux_socket, &options.session)?.is_some() {
        ensure_owner_link_ready(paths)?;
        return Ok(());
    }

    let executable = std::env::current_exe().context("could not locate Windows cmux-tui")?;
    let log = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(&paths.owner_log)
        .with_context(|| format!("could not open {}", paths.owner_log.display()))?;
    let mut command = Command::new(executable);
    command.args(["remote-mux-owner", "--session", &options.session]);
    if let Some(state_root) = &options.state_root {
        command.arg("--state-dir").arg(state_root);
    }
    command.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::from(log));
    use std::os::windows::process::CommandExt;
    command.creation_flags(CREATE_BREAKAWAY_FROM_JOB | CREATE_NEW_PROCESS_GROUP | DETACHED_PROCESS);
    let mut child = command.spawn().context("could not start Windows mux owner")?;
    let stdout = child.stdout.take().context("Windows mux owner readiness pipe is unavailable")?;
    let (ready_tx, ready_rx) = mpsc::sync_channel(1);
    std::thread::Builder::new().name("windows-owner-ready".into()).spawn(move || {
        let mut line = String::new();
        let result = BufReader::new(stdout).read_line(&mut line).map(|_| line);
        let _ = ready_tx.send(result);
    })?;

    let ready = ready_rx.recv_timeout(OWNER_START_TIMEOUT);
    match ready {
        Ok(Ok(line)) if line.trim() == OWNER_READY => {
            let identity = identify_mux_owner(&paths.mux_socket, &options.session)?;
            anyhow::ensure!(
                identity.is_some(),
                "Windows mux owner reported ready without a socket"
            );
            ensure_owner_link_ready(paths)?;
            Ok(())
        }
        _ if identify_mux_owner(&paths.mux_socket, &options.session)?.is_some() => {
            ensure_owner_link_ready(paths)?;
            Ok(())
        }
        Ok(Ok(line)) => {
            terminate_failed_owner(&mut child);
            Err(owner_start_error(
                paths,
                &format!("Windows mux owner returned unexpected readiness {:?}", line.trim()),
            ))
        }
        Ok(Err(error)) => {
            terminate_failed_owner(&mut child);
            Err(owner_start_error(paths, &format!("Windows mux owner readiness failed: {error}")))
        }
        Err(mpsc::RecvTimeoutError::Disconnected) => {
            terminate_failed_owner(&mut child);
            Err(owner_start_error(paths, "Windows mux owner exited before readiness"))
        }
        Err(mpsc::RecvTimeoutError::Timeout) => {
            terminate_failed_owner(&mut child);
            Err(owner_start_error(paths, "Windows mux owner startup timed out after 10s"))
        }
    }
}

fn acquire_owner_start_lock(paths: &WindowsSessionPaths) -> anyhow::Result<std::fs::File> {
    let lock_path = paths.state_dir.join("start.lock");
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(&lock_path)
        .with_context(|| format!("could not open {}", lock_path.display()))?;
    let (locked_tx, locked_rx) = mpsc::sync_channel(1);
    std::thread::Builder::new().name("windows-owner-start-lock".into()).spawn(move || {
        let result = FileExt::lock(&lock).map(|()| lock);
        let _ = locked_tx.send(result);
    })?;
    match locked_rx.recv_timeout(OWNER_START_LOCK_TIMEOUT) {
        Ok(Ok(lock)) => Ok(lock),
        Ok(Err(error)) => Err(error).context("could not acquire Windows owner startup lease"),
        Err(mpsc::RecvTimeoutError::Disconnected) => {
            Err(anyhow!("Windows owner startup lease worker stopped unexpectedly"))
        }
        Err(mpsc::RecvTimeoutError::Timeout) => {
            Err(anyhow!("Windows owner startup lease timed out after 15s"))
        }
    }
}

fn ensure_owner_link_ready(paths: &WindowsSessionPaths) -> anyhow::Result<()> {
    let socket = uds_windows::UnixStream::connect(&paths.link_socket).with_context(|| {
        format!(
            "Windows session owner is running but its remote listener is unavailable at {}",
            paths.link_socket.display()
        )
    })?;
    let _ = socket.shutdown(Shutdown::Both);
    Ok(())
}

async fn wait_for_link_server_exit(
    completion: &mut tokio::sync::watch::Receiver<Option<Result<(), String>>>,
) -> Result<(), String> {
    loop {
        if let Some(result) = completion.borrow().clone() {
            return result;
        }
        completion
            .changed()
            .await
            .map_err(|_| "Windows remote listener completion channel closed".to_owned())?;
    }
}

fn terminate_failed_owner(child: &mut Child) {
    let _ = child.kill();
    use std::os::windows::io::AsRawHandle;

    // SAFETY: `child` owns a live process handle and the finite timeout keeps
    // cleanup from blocking if Windows cannot reap the process immediately.
    unsafe {
        WaitForSingleObject(child.as_raw_handle(), 2_000);
    }
}

fn owner_start_error(paths: &WindowsSessionPaths, summary: &str) -> anyhow::Error {
    match owner_log_tail(&paths.owner_log) {
        Ok(tail) if !tail.is_empty() => anyhow!("{summary}: {tail}"),
        _ => anyhow!("{summary}; log: {}", paths.owner_log.display()),
    }
}

fn owner_log_tail(path: &Path) -> io::Result<String> {
    let mut log = OpenOptions::new().read(true).open(path)?;
    let length = log.metadata()?.len();
    let offset = length.saturating_sub(OWNER_LOG_TAIL_BYTES);
    log.seek(SeekFrom::Start(offset))?;
    let mut bytes = Vec::new();
    log.take(OWNER_LOG_TAIL_BYTES).read_to_end(&mut bytes)?;
    if offset != 0
        && let Some(newline) = bytes.iter().position(|byte| *byte == b'\n')
    {
        bytes.drain(..=newline);
    }
    Ok(String::from_utf8_lossy(&bytes)
        .chars()
        .map(|character| if character.is_control() { ' ' } else { character })
        .collect::<String>()
        .trim()
        .to_owned())
}

fn parse_session_options(args: &[String], command: &str) -> anyhow::Result<RemoteLinkOptions> {
    let mut normalized = args.to_vec();
    normalized.push("--stdio".into());
    parse_remote_link(&normalized).with_context(|| format!("invalid {command} options"))
}

fn identify_mux_owner(socket: &Path, session: &str) -> anyhow::Result<Option<MuxIdentity>> {
    let stream = match cmux_tui_core::platform::transport::connect(socket) {
        Ok(stream) => stream,
        Err(error) if mux_socket_is_absent(&error) => return Ok(None),
        Err(error) => {
            return Err(error).with_context(|| format!("could not inspect {}", socket.display()));
        }
    };
    let data = control_request(stream, json!({"id": 1, "cmd": "identify"}))?;
    anyhow::ensure!(data["app"] == "cmux-tui", "mux owner returned an unexpected identity");
    anyhow::ensure!(data["session"] == session, "mux socket belongs to another session");
    let pid = data["pid"]
        .as_u64()
        .and_then(|pid| u32::try_from(pid).ok())
        .context("mux owner identity omitted its process id")?;
    let generation = data["generation"]
        .as_str()
        .context("mux owner identity omitted its generation")?
        .to_owned();
    Ok(Some(MuxIdentity { pid, generation }))
}

fn mux_socket_is_absent(error: &io::Error) -> bool {
    matches!(error.kind(), io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused)
        || error.raw_os_error() == Some(WINDOWS_STALE_AF_UNIX_SOCKET_ERROR)
}

fn control_request(
    stream: Box<dyn cmux_tui_core::platform::transport::Stream>,
    request: Value,
) -> anyhow::Result<Value> {
    stream.set_read_timeout(Some(CONTROL_TIMEOUT))?;
    stream.set_write_timeout(Some(CONTROL_TIMEOUT))?;
    let mut writer = stream.try_clone_box()?;
    serde_json::to_writer(&mut writer, &request)?;
    writer.write_all(b"\n")?;
    writer.flush()?;

    let mut reader = BufReader::new(stream).take(CONTROL_RESPONSE_BYTES);
    let mut line = String::new();
    reader.read_line(&mut line)?;
    anyhow::ensure!(line.ends_with('\n'), "mux owner returned a truncated response");
    let response: Value = serde_json::from_str(&line)?;
    anyhow::ensure!(
        response["ok"] == true,
        "mux owner rejected request: {}",
        response["error"].as_str().unwrap_or("unknown error")
    );
    Ok(response["data"].clone())
}

fn run_remote_stop(args: &[String]) -> anyhow::Result<()> {
    let options = parse_session_options(args, "remote-stop")?;
    let paths = windows_session_paths(&options)?;
    let Some(identity) = identify_mux_owner(&paths.mux_socket, &options.session)? else {
        return Ok(());
    };
    let mut exit_watcher = cmux_tui_core::platform::transport::connect(&paths.mux_socket)
        .context("could not watch Windows mux owner shutdown")?;
    exit_watcher.set_read_timeout(Some(CONTROL_TIMEOUT))?;
    let shutdown = cmux_tui_core::platform::transport::connect(&paths.mux_socket)?;
    control_request(
        shutdown,
        json!({
            "id": 2,
            "cmd": "shutdown-daemon",
            "pid": identity.pid,
            "generation": identity.generation,
        }),
    )?;

    let mut byte = [0_u8; 1];
    match exit_watcher.read(&mut byte) {
        Ok(0) => Ok(()),
        Ok(_) => Err(anyhow!("Windows mux owner sent unexpected shutdown data")),
        Err(error)
            if matches!(
                error.kind(),
                io::ErrorKind::BrokenPipe
                    | io::ErrorKind::ConnectionAborted
                    | io::ErrorKind::ConnectionReset
                    | io::ErrorKind::NotConnected
            ) =>
        {
            Ok(())
        }
        Err(error) => Err(error).context("Windows mux owner did not finish shutdown"),
    }
}

fn proxy_windows_stdio(paths: &WindowsSessionPaths) -> anyhow::Result<()> {
    let socket = uds_windows::UnixStream::connect(&paths.link_socket).with_context(|| {
        format!("could not attach Windows carrier to {}", paths.link_socket.display())
    })?;
    let mut upload_socket = socket.try_clone()?;
    let upload_shutdown = socket.try_clone()?;
    std::thread::Builder::new().name("windows-carrier-upload".into()).spawn(move || {
        let mut stdin = io::stdin().lock();
        if let Err(error) =
            io::copy(&mut stdin, &mut upload_socket).and_then(|_| upload_socket.flush())
        {
            eprintln!("cmux-tui: Windows remote carrier upload failed: {error}");
        }
        let _ = upload_shutdown.shutdown(Shutdown::Write);
    })?;

    let mut download_socket = socket;
    let mut stdout = io::stdout().lock();
    let result = copy_windows_carrier_download(&mut download_socket, &mut stdout)
        .context("Windows remote carrier stopped")
        .map(|_| ());
    let _ = download_socket.shutdown(Shutdown::Both);
    result?;
    Err(owner_start_error(paths, "Windows session owner closed the carrier"))
}

fn proxy_raw_mux_stdio(socket_path: &Path) -> anyhow::Result<()> {
    let socket = transport::connect(socket_path).with_context(|| {
        format!("could not attach Windows SSH relay to {}", socket_path.display())
    })?;
    let mut upload_socket = socket.try_clone_box()?;
    let upload_shutdown = socket.try_clone_box()?;
    std::thread::Builder::new().name("windows-ssh-remote-upload".into()).spawn(move || {
        let mut stdin = io::stdin().lock();
        let _ = io::copy(&mut stdin, &mut upload_socket).and_then(|_| upload_socket.flush());
        let _ = upload_shutdown.shutdown(Shutdown::Write);
    })?;

    let mut download_socket = socket;
    let mut stdout = io::stdout().lock();
    let result = io::copy(&mut download_socket, &mut stdout)
        .and_then(|_| stdout.flush())
        .context("Windows SSH remote relay stopped")
        .map(|_| ());
    let _ = download_socket.shutdown(Shutdown::Both);
    result
}

fn copy_windows_carrier_download(
    source: &mut impl Read,
    destination: &mut impl Write,
) -> io::Result<u64> {
    let mut buffer = [0_u8; 8 * 1024];
    let mut copied = 0_u64;
    loop {
        let size = match source.read(&mut buffer) {
            Ok(0) => return Ok(copied),
            Ok(size) => size,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        };
        destination.write_all(&buffer[..size])?;
        destination.flush()?;
        copied += size as u64;
    }
}

fn windows_daemon_name() -> String {
    std::env::var("COMPUTERNAME").unwrap_or_else(|_| "Windows".into())
}
