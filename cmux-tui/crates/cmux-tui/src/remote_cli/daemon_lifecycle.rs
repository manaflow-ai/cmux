//! The remote daemon's lifecycle: `remote-stop` and its finalization checks,
//! `remote-sidecar`, `ensure_daemon` starting the mux owner and sidecar, and the
//! detached processes, logs, monitor socket and start lock behind them.

use super::*;

pub(super) struct RemoteStopArgs {
    pub(super) session: String,
    pub(super) state_dir: Option<PathBuf>,
    pub(super) acknowledge_failed_finalization: bool,
    pub(super) acknowledge_legacy_finalization: bool,
}

pub(super) fn parse_remote_stop_args(args: &[String]) -> anyhow::Result<RemoteStopArgs> {
    let mut session = "main".to_string();
    let mut state_dir = None;
    let mut acknowledge_failed_finalization = false;
    let mut acknowledge_legacy_finalization = false;
    let mut seen = BTreeSet::new();
    let mut index = 0;
    while index < args.len() {
        let argument = &args[index];
        index += 1;
        match argument.as_str() {
            "--session" => {
                require_unique_flag(&mut seen, "--session")?;
                session = strict_option_value(args, &mut index, "--session")?;
            }
            "--state-dir" => {
                require_unique_flag(&mut seen, "--state-dir")?;
                state_dir = Some(strict_option_value(args, &mut index, "--state-dir")?.into());
            }
            "--acknowledge-failed-finalization" => {
                require_unique_flag(&mut seen, "--acknowledge-failed-finalization")?;
                acknowledge_failed_finalization = true;
            }
            "--acknowledge-legacy-finalization" => {
                require_unique_flag(&mut seen, "--acknowledge-legacy-finalization")?;
                acknowledge_legacy_finalization = true;
            }
            option if option.starts_with("--") => {
                return Err(anyhow!(catalog().remote.remote_stop_unknown_option(option)));
            }
            _ => return Err(anyhow!(catalog().remote.remote_stop_no_positional)),
        }
    }
    if acknowledge_failed_finalization && acknowledge_legacy_finalization {
        return Err(anyhow!(catalog().remote.remote_stop_acknowledgements_mutually_exclusive));
    }
    Ok(RemoteStopArgs {
        session,
        state_dir,
        acknowledge_failed_finalization,
        acknowledge_legacy_finalization,
    })
}

pub(super) fn run_remote_stop(args: &[String]) -> anyhow::Result<()> {
    let parsed = parse_remote_stop_args(args)?;
    let (state_dir, default_link, default_admin) =
        daemon_paths(&parsed.session, parsed.state_dir.as_deref())?;
    let runtime = match load_runtime_info(&parsed.session, parsed.state_dir.as_deref()) {
        Ok(runtime) => runtime,
        Err(_)
            if UnixStream::connect(&default_link).is_err()
                && UnixStream::connect(&default_admin).is_err() =>
        {
            if parsed.acknowledge_failed_finalization {
                return tokio_runtime()?.block_on(acknowledge_failed_shutdown_outcome(
                    &state_dir,
                    &parsed.session,
                    &default_link,
                    &default_admin,
                ));
            }
            if parsed.acknowledge_legacy_finalization {
                return tokio_runtime()?.block_on(acknowledge_legacy_shutdown_state(
                    &state_dir,
                    &parsed.session,
                    &default_link,
                    &default_admin,
                ));
            }
            let runtime_path = state_dir.join("runtime.json");
            match fs::symlink_metadata(&runtime_path) {
                Ok(_) => {
                    return Err(anyhow!(
                        catalog()
                            .remote
                            .invalid_runtime_metadata(&runtime_path.display().to_string())
                    ));
                }
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => {
                    return Err(error).with_context(|| {
                        catalog()
                            .remote
                            .inspect_runtime_metadata(&runtime_path.display().to_string())
                    });
                }
            }
            verify_inactive_shutdown_outcome(&state_dir)?;
            if inactive_daemon_needs_legacy_acknowledgement(&state_dir)? {
                return Err(anyhow!(catalog().remote.inactive_legacy_needs_migration));
            }
            return Ok(());
        }
        Err(error) => {
            return Err(error.context(catalog().remote.refuse_live_invalid_lifecycle));
        }
    };
    if parsed.acknowledge_failed_finalization {
        return tokio_runtime()?.block_on(acknowledge_failed_shutdown_outcome(
            &runtime.state_dir,
            &parsed.session,
            &runtime.link_socket,
            &runtime.admin_socket,
        ));
    }
    if parsed.acknowledge_legacy_finalization {
        return tokio_runtime()?.block_on(acknowledge_legacy_shutdown_state(
            &runtime.state_dir,
            &parsed.session,
            &runtime.link_socket,
            &runtime.admin_socket,
        ));
    }
    if !runtime.replaceable_sidecar {
        return Err(anyhow!(catalog().remote.embedded_daemon_stop_refused));
    }
    let runtime_file = runtime.state_dir.join("runtime.json");
    let state_dir = runtime.state_dir;
    let lifecycle_id = runtime.lifecycle_id;
    let link = runtime.link_socket;
    let admin = runtime.admin_socket;
    let shutdown_request = shutdown_request_for_lifecycle(lifecycle_id.as_deref());
    let (response, mut peer_exit) =
        tokio_runtime()?.block_on(call_admin_with_peer_exit(&admin, &shutdown_request))?;
    if !response.ok {
        return Err(anyhow!(
            response.error.unwrap_or_else(|| catalog().remote.daemon_shutdown_failed.to_owned())
        ));
    }
    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline {
        let process_exited =
            peer_exit.has_exited().context(catalog().remote.observe_daemon_exit)?;
        if process_exited && UnixStream::connect(&link).is_err() && !runtime_file.exists() {
            match lifecycle_id.as_deref() {
                Some(lifecycle_id) => verify_shutdown_outcome(&state_dir, lifecycle_id),
                None => Ok(()),
            }?;
            tokio_runtime()?
                .block_on(complete_verified_daemon_stop(&state_dir, &parsed.session))?;
            return Ok(());
        }
        thread::sleep(Duration::from_millis(50));
    }
    Err(anyhow!(catalog().remote.daemon_stop_timeout))
}

pub(super) fn shutdown_request_for_lifecycle(lifecycle_id: Option<&str>) -> AdminRequest {
    match lifecycle_id {
        Some(lifecycle_id) => {
            AdminRequest::ShutdownLifecycle { lifecycle_id: lifecycle_id.to_owned() }
        }
        None => AdminRequest::Shutdown,
    }
}

fn verify_inactive_shutdown_outcome(state_dir: &Path) -> anyhow::Result<()> {
    let path = state_dir.join("shutdown.json");
    match fs::symlink_metadata(&path) {
        Ok(_) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => {
            return Err(error).with_context(|| {
                catalog().remote.verify_previous_finalization_path(&path.display().to_string())
            });
        }
    }
    let outcome =
        load_shutdown_outcome(state_dir).context(catalog().remote.verify_previous_finalization)?;
    match outcome.status {
        DaemonShutdownStatus::Succeeded => Ok(()),
        DaemonShutdownStatus::Failed => {
            Err(anyhow!(catalog().remote.previous_finalization_failed_ack))
        }
    }
}

pub(super) fn verify_shutdown_outcome(state_dir: &Path, lifecycle_id: &str) -> anyhow::Result<()> {
    let outcome = load_shutdown_outcome(state_dir).context(catalog().remote.verify_finalization)?;
    if outcome.lifecycle_id != lifecycle_id {
        return Err(anyhow!(catalog().remote.finalization_wrong_lifecycle));
    }
    match outcome.status {
        DaemonShutdownStatus::Succeeded => Ok(()),
        DaemonShutdownStatus::Failed => Err(anyhow!(catalog().remote.finalization_failed)),
    }
}

pub(super) fn run_remote_sidecar(args: &[String]) -> anyhow::Result<()> {
    let session = flag_value(args, "--session").unwrap_or_else(|| "main".into());
    let mux_socket = flag_value(args, "--mux-socket")
        .map(PathBuf::from)
        .ok_or_else(|| anyhow!("remote-sidecar needs --mux-socket"))?;
    let mut mux_monitor = open_mux_monitor(&mux_socket)?;
    let state_dir = flag_value(args, "--state-dir").map(PathBuf::from);
    let link_socket = flag_value(args, "--link-socket").map(PathBuf::from);
    let runtime = start_daemon_runtime(
        mux_socket.clone(),
        DaemonRuntimeOptions {
            session,
            state_dir,
            link_socket,
            admin_socket: None,
            direct_websocket: None,
            allow_insecure_non_loopback: false,
            trusted_carrier_websocket: false,
            workspace_http: None,
            relays: Vec::new(),
            carrier_grant_config: None,
            iroh: false,
            advertised_routes: Vec::new(),
            resume_lease: cmux_remote::daemon::DEFAULT_RESUME_LEASE,
            replaceable_sidecar: true,
            local_sockets: Vec::new(),
        },
    )?;
    let mut mux_disappeared = false;
    let mut monitor_error = None;
    while !crate::shutdown_requested() && !runtime.is_finished() {
        match mux_monitor_disconnected(&mut mux_monitor, &mux_socket) {
            Ok(false) => {}
            Ok(true) => {
                mux_disappeared = true;
                break;
            }
            Err(error) => {
                mux_disappeared = true;
                monitor_error = Some(error);
                break;
            }
        }
    }
    if !mux_disappeared {
        return runtime.shutdown();
    }

    // The runtime owns its socket and metadata paths through shutdown. A
    // separate check-then-unlink cleanup can remove a replacement daemon that
    // binds the same path after this runtime releases it.
    let lifecycle = runtime.shutdown();
    match (lifecycle, monitor_error) {
        (result, None) => result,
        (Ok(()), Some(error)) => Err(error.context("mux socket health monitor failed")),
        (Err(lifecycle), Some(monitor)) => Err(anyhow!(
            "mux socket health monitor failed: {monitor:#}; sidecar cleanup failed: {lifecycle:#}"
        )),
    }
}

pub(super) fn ensure_daemon(
    session: &str,
    state_root: Option<&Path>,
    session_state: &Path,
    link: &Path,
    mux_socket_override: Option<&Path>,
) -> anyhow::Result<UnixStream> {
    let _lock = lock_daemon_start(session_state)?;
    if let Ok(stream) = connect_same_user_socket(link) {
        return remote_link_mux::check_binding(
            stream,
            session,
            state_root,
            link,
            mux_socket_override,
        );
    }

    // Spawn the daemon from this client's own running build (open inode on
    // Linux) so an in-place binary upgrade cannot leave a long-lived client
    // exec'ing a "(deleted)" path, and daemon/client builds never skew.
    let executable = cmux_tui_core::platform::self_exe_for_spawn()?;
    let log_path = session_state.join("daemon.log");
    let explicit_mux_socket = socket_for(mux_socket_override, session, state_root, session_state)?;
    let mux_socket_is_derived = explicit_mux_socket.is_none();
    let attach_only = mux_socket_override.is_some();
    let mux_socket = explicit_mux_socket
        .map_or_else(|| cmux_tui_core::server::try_default_socket_path(session), Ok)?;
    if mux_socket_is_derived {
        // A derived path may fall back to a shared /tmp name. Claim or check
        // its directory the same way the mux owner will before probing it.
        cmux_tui_core::server::prepare_socket_parent(&mux_socket, true)?;
    }
    if connect_same_user_socket(&mux_socket).is_err() {
        if attach_only {
            return Err(remote_link_mux::not_running(&mux_socket));
        }
        let log = open_private_daemon_file(&log_path, true)
            .with_context(|| format!("could not open daemon log {}", log_path.display()))?;
        let mut mux_owner = Command::new(&executable);
        log_under_state_root(&mut mux_owner, state_root);
        mux_owner
            .args(mux_owner_args(session, &mux_socket, mux_socket_is_derived, state_root))
            .stdin(Stdio::null())
            .stdout(Stdio::from(log.try_clone()?))
            .stderr(Stdio::from(log));
        configure_detached_process(&mut mux_owner);
        let mut child = mux_owner.spawn().context("could not start remote mux owner")?;
        wait_for_detached_socket(
            &mut child,
            &mux_socket,
            Duration::from_secs(20),
            "remote mux owner",
            &log_path,
        )?;
    }

    let log = open_private_daemon_file(&log_path, true)
        .with_context(|| format!("could not open daemon log {}", log_path.display()))?;
    let mut command = Command::new(executable);
    command
        .args(["remote-sidecar", "--session", session, "--mux-socket"])
        .arg(&mux_socket)
        .arg("--link-socket")
        .arg(link);
    if let Some(state_root) = state_root {
        command.arg("--state-dir").arg(state_root);
    }
    log_under_state_root(&mut command, state_root);
    command.stdin(Stdio::null());
    command.stdout(Stdio::from(log.try_clone()?)).stderr(Stdio::from(log));
    configure_detached_process(&mut command);
    let mut child = command.spawn().context("could not start remote daemon")?;
    wait_for_detached_socket(
        &mut child,
        link,
        Duration::from_secs(20),
        "remote daemon",
        &log_path,
    )?;
    if mux_socket_override.is_some() {
        // The link listener is created before the admin listener during startup.
        let (_, _, admin) = daemon_paths(session, state_root)?;
        wait_for_detached_socket(
            &mut child,
            &admin,
            Duration::from_secs(20),
            "remote daemon admin",
            &log_path,
        )?;
    }
    remote_link_mux::check_binding(
        connect_same_user_socket(link)?,
        session,
        state_root,
        link,
        mux_socket_override,
    )
}

/// The mux owner and sidecar of a link with its own state directory log to
/// `<state-dir>/client.log`, as the link does, unless `CMUX_TUI_LOG_FILE`
/// already names a file (cx-bduj).
fn log_under_state_root(command: &mut Command, state_root: Option<&Path>) {
    if let Some(root) = state_root
        && std::env::var_os("CMUX_TUI_LOG_FILE").is_none()
    {
        command.env("CMUX_TUI_LOG_FILE", root.join("client.log"));
    }
}

/// Connect to a socket this daemon's own user serves. The daemon only starts
/// and talks to listeners it or an earlier run of it created.
fn connect_same_user_socket(path: &Path) -> io::Result<UnixStream> {
    let stream = UnixStream::connect(path)?;
    cmux_tui_core::platform::require_unix_peer_uid(
        &stream,
        cmux_tui_core::platform::effective_uid(),
    )?;
    Ok(stream)
}

pub(super) fn wait_for_detached_socket(
    child: &mut Child,
    socket: &Path,
    timeout: Duration,
    process_name: &str,
    log_path: &Path,
) -> anyhow::Result<()> {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if connect_same_user_socket(socket).is_ok() {
            return Ok(());
        }
        match child.try_wait() {
            Ok(Some(status)) => {
                let cause = exit_cause(log_path);
                let message = format!(
                    "{process_name} exited {status}{}; inspect {}",
                    cause.as_deref().map(|cause| format!(": {cause}")).unwrap_or_default(),
                    log_path.display()
                );
                if cause.is_some_and(|cause| cause.contains(SESSION_IN_USE)) {
                    return Err(SessionInUse(message).into());
                }
                return Err(anyhow!(message));
            }
            Ok(None) => {}
            Err(error) => {
                let cleanup = terminate_detached_process(child);
                return match cleanup {
                    Ok(()) => Err(error).with_context(|| {
                        format!("could not inspect {process_name}; inspect {}", log_path.display())
                    }),
                    Err(cleanup) => Err(anyhow!(
                        "could not inspect {process_name}: {error}; process cleanup failed: {cleanup}; inspect {}",
                        log_path.display()
                    )),
                };
            }
        }
        thread::sleep(Duration::from_millis(50));
    }
    match terminate_detached_process(child) {
        Ok(()) => Err(anyhow!("{process_name} did not create {}", socket.display())),
        Err(error) => Err(anyhow!(
            "{process_name} did not create {}; process cleanup failed: {error}",
            socket.display()
        )),
    }
}

/// What `exit_cause` says of a session another daemon owns.
const SESSION_IN_USE: &str = "in use by another cmux daemon";

/// A mux owner exited because another daemon of the machine owns its
/// session: `remote-link` may keep the session in a private root instead.
#[derive(Debug)]
pub(super) struct SessionInUse(String);

impl std::fmt::Display for SessionInUse {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for SessionInUse {}

/// The state root a link keeps its session in when another daemon (a Chief
/// brain on the default root, `cmux-tui --headless --socket <its own>`)
/// owns the session there: `<remote state>/private`. Once it holds a
/// registry, later links use it first, so the workspaces stay put.
pub(super) fn private_link_root() -> Option<PathBuf> {
    default_state_dir().map(|root| root.join("private"))
}

/// The bytes of a detached process's log read for its exit cause: enough for
/// its last lines, never the whole log a long-lived session has grown.
const EXIT_CAUSE_TAIL_BYTES: u64 = 4096;

/// Why a detached process that exited before its socket appeared did so: its
/// own last log line (it writes its error there before exiting). A session
/// another daemon owns (a Chief brain or the machine's own app holds `main`)
/// says how to get past it, since retrying the same session cannot.
fn exit_cause(log_path: &Path) -> Option<String> {
    use std::io::{Seek, SeekFrom};
    let mut file = fs::File::open(log_path).ok()?;
    let length = file.metadata().ok()?.len();
    file.seek(SeekFrom::Start(length.saturating_sub(EXIT_CAUSE_TAIL_BYTES))).ok()?;
    let mut tail = Vec::new();
    file.take(EXIT_CAUSE_TAIL_BYTES).read_to_end(&mut tail).ok()?;
    let tail = String::from_utf8_lossy(&tail);
    let line = tail.lines().map(str::trim).rfind(|line| !line.is_empty())?;
    let line = line.strip_prefix("cmux-tui: ").unwrap_or(line);
    if line.contains("workspace session is already owned by another daemon") {
        return Some(format!(
            "this session on the machine is {SESSION_IN_USE} ({line}); connect with another session name (--session NAME)"
        ));
    }
    Some(line.to_owned())
}

fn terminate_detached_process(child: &mut Child) -> io::Result<()> {
    if child.try_wait()?.is_some() {
        return Ok(());
    }
    signal_detached_process_group(child, libc::SIGTERM)?;
    if wait_for_child_exit(child, DETACHED_TERM_GRACE)? {
        return Ok(());
    }
    signal_detached_process_group(child, libc::SIGKILL)?;
    if wait_for_child_exit(child, DETACHED_KILL_GRACE)? {
        return Ok(());
    }
    Err(io::Error::new(
        io::ErrorKind::TimedOut,
        format!("detached process {} did not exit after SIGKILL", child.id()),
    ))
}

fn signal_detached_process_group(child: &Child, signal: libc::c_int) -> io::Result<()> {
    let process_group = libc::pid_t::try_from(child.id())
        .map_err(|_| io::Error::other("detached child PID does not fit pid_t"))?;
    if unsafe { libc::kill(-process_group, signal) } == 0 {
        return Ok(());
    }
    let error = io::Error::last_os_error();
    if error.raw_os_error() == Some(libc::ESRCH) { Ok(()) } else { Err(error) }
}

fn wait_for_child_exit(child: &mut Child, timeout: Duration) -> io::Result<bool> {
    let deadline = Instant::now() + timeout;
    loop {
        if child.try_wait()?.is_some() {
            return Ok(true);
        }
        if Instant::now() >= deadline {
            return Ok(false);
        }
        thread::sleep(Duration::from_millis(10));
    }
}

pub(super) fn configure_detached_process(command: &mut Command) {
    use std::os::unix::process::CommandExt;

    unsafe {
        command.pre_exec(|| {
            if libc::setsid() < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
}

pub(super) fn open_mux_monitor(path: &Path) -> anyhow::Result<UnixStream> {
    let stream = connect_same_user_socket(path).with_context(|| {
        format!("cannot attach remote sidecar to mux socket {}", path.display())
    })?;
    stream.set_read_timeout(Some(Duration::from_millis(250)))?;
    Ok(stream)
}

pub(super) fn mux_monitor_disconnected(
    stream: &mut UnixStream,
    path: &Path,
) -> anyhow::Result<bool> {
    use std::os::unix::fs::FileTypeExt;

    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_socket() => {}
        Ok(_) => return Ok(true),
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(true),
        Err(error) => return Err(error.into()),
    }

    let mut byte = [0_u8; 1];
    match stream.read(&mut byte) {
        Ok(0) => Ok(true),
        Ok(_) => Ok(false),
        Err(error)
            if matches!(
                error.kind(),
                io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut | io::ErrorKind::Interrupted
            ) =>
        {
            Ok(false)
        }
        Err(error)
            if matches!(
                error.kind(),
                io::ErrorKind::BrokenPipe
                    | io::ErrorKind::ConnectionAborted
                    | io::ErrorKind::ConnectionReset
                    | io::ErrorKind::NotConnected
            ) =>
        {
            Ok(true)
        }
        Err(error) => Err(error.into()),
    }
}

pub(super) fn open_private_daemon_file(path: &Path, append: bool) -> io::Result<fs::File> {
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};

    let mut options = OpenOptions::new();
    options
        .read(!append)
        .write(true)
        .create(true)
        .append(append)
        .truncate(false)
        .mode(0o600)
        // Opening a hostile FIFO must return so its type can be rejected
        // below, rather than waiting for a peer that never arrives.
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK);
    let file = options.open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "daemon state path is not a regular file",
        ));
    }
    if metadata.uid() != unsafe { libc::geteuid() } {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "daemon state file is not owned by the effective user",
        ));
    }
    if metadata.nlink() != 1 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "daemon state file has unexpected hard links",
        ));
    }
    // Existing files may predate this check and have inherited a broad umask.
    // Tighten the inode through the open descriptor, avoiding a pathname race.
    if metadata.permissions().mode() & 0o077 != 0 {
        file.set_permissions(fs::Permissions::from_mode(0o600))?;
    }
    Ok(file)
}

pub(super) fn lock_daemon_start(session_state: &Path) -> anyhow::Result<fs::File> {
    ensure_secure_directory(session_state, DirectoryAccess::OwnerControlled).with_context(
        || format!("could not prepare secure daemon state directory {}", session_state.display()),
    )?;
    let lock_path = session_state.join("start.lock");
    let lock = open_private_daemon_file(&lock_path, false)
        .with_context(|| format!("could not open daemon start lock {}", lock_path.display()))?;
    let locked = unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) };
    if locked != 0 {
        return Err(io::Error::last_os_error().into());
    }
    Ok(lock)
}
