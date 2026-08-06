//! Native Windows remote command entrypoints.

use std::fs::OpenOptions;
use std::io::{self, BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::net::Shutdown;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
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
const REMOTE_COMMANDS: &[&str] = &[
    "connect",
    "ssh",
    "forward",
    "rpc",
    "enroll",
    "known-daemons",
    "remote-probe",
    "remote-link",
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
        Some("remote-probe") => run_probe(&args[1..]),
        Some("remote-link") => run_remote_link(&args[1..]),
        Some("remote-mux-owner") => run_remote_mux_owner(&args[1..]),
        Some("remote-stop") => run_remote_stop(&args[1..]),
        Some(command) => Err(anyhow!("{command} is not implemented on Windows yet")),
        None => Err(anyhow!("missing remote command")),
    }
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
    proxy_windows_stdio(&paths.link_socket)
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
                            let _ = services.serve_client(client).await;
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
        Err(error)
            if matches!(
                error.kind(),
                io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused
            ) =>
        {
            return Ok(None);
        }
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

fn proxy_windows_stdio(link: &Path) -> anyhow::Result<()> {
    let socket = uds_windows::UnixStream::connect(link)
        .with_context(|| format!("could not attach Windows carrier to {}", link.display()))?;
    let mut upload_socket = socket.try_clone()?;
    let upload_shutdown = socket.try_clone()?;
    std::thread::Builder::new().name("windows-carrier-upload".into()).spawn(move || {
        let mut stdin = io::stdin().lock();
        let _ = io::copy(&mut stdin, &mut upload_socket);
        let _ = upload_socket.flush();
        let _ = upload_shutdown.shutdown(Shutdown::Write);
    })?;

    let mut download_socket = socket;
    let mut stdout = io::stdout().lock();
    let result = io::copy(&mut download_socket, &mut stdout)
        .and_then(|_| stdout.flush())
        .context("Windows remote carrier stopped")
        .map(|_| ());
    let _ = download_socket.shutdown(Shutdown::Both);
    result
}

fn windows_daemon_name() -> String {
    std::env::var("COMPUTERNAME").unwrap_or_else(|_| "Windows".into())
}
