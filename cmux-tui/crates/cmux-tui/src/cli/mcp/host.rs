//! One cmux MCP host per app build, and a stdio relay per agent
//! (plans/cmux-next/chrome-parity/p07-memory.md task 093, feature
//! `mcpCatalogHost`, off by default).
//!
//! Every agent chat runs `cmux mcp serve`; each used to keep the app's whole
//! action catalog and its own copy of the multicall binary's runtime (21.6 MB
//! per agent, 2.3 GB at 110 agents). With the feature on, `serve` finds or
//! starts the host for its build, hands it the caller (its settings file,
//! global options and environment, [`super::super::caller_env`]) and then
//! replaces itself with the relay, `cmux-tui-host __mcp-relay <fd>`, which
//! only copies bytes between its stdio and the host's socket. The host runs
//! each client's requests on that client's thread with the client's
//! environment in scope, so a call has the same caller, routes, allowlist
//! and proxied servers as before, and keeps the app's catalog once for every
//! client of that app (`catalog.rs`). This is Chromium's split between one
//! browser process that owns shared state and many small clients that hold a
//! connection to it (content/browser/renderer_host/render_process_host_impl.cc
//! hands each renderer a channel, never a copy of the browser's tables).
//!
//! The host listens on a user-private socket named by the build and the
//! settings that fix process-wide state (`HOME`, the acpmux home and socket,
//! the locale), takes a lock file so two never serve one socket, refuses a
//! peer of another user, and exits once no client has been connected for
//! [`IDLE_EXIT`]. When anything here fails, `serve` serves in its own
//! process as before.

use std::convert::Infallible;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, mpsc};
use std::time::Duration;

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::super::caller_env::{self, CallerEnv};
use super::super::{GlobalArgs, OutputMode};
use super::catalog::SharedCatalog;
use super::{Backend, client_server, watch};

/// `cmux mcp __host-start PATH`: starts the host in its own session
/// and exits, so the host is no child of an agent's relay.
pub(super) const START_VERB: &str = "__host-start";
/// `cmux mcp __host PATH`: the host.
pub(super) const RUN_VERB: &str = "__host";

/// The host's first line on its stdout once it listens, or that another
/// host holds the socket's lock.
const READY: &str = "ready";
const LOCK_HELD: &str = "lock-held";
/// The first line of a client: `{hello, code_mode, config, global, caller}`.
const HELLO: &str = "cmux-mcp-host/1";
const MAX_HELLO_BYTES: u64 = 4 << 20;
/// How long the host stays with no client.
const IDLE_EXIT: Duration = Duration::from_secs(5 * 60);
/// Milliseconds that replace [`IDLE_EXIT`] (tests).
const IDLE_EXIT_ENV: &str = "CMUX_MCP_HOST_IDLE_EXIT_MS";
/// How long a client waits for the host's answer to its hello.
const HELLO_ANSWER_TIMEOUT: Duration = Duration::from_secs(10);
/// How long the host waits for the app's answer to its admission probe;
/// well under [`HELLO_ANSWER_TIMEOUT`], so the client hears the refusal.
const APP_PROBE_TIMEOUT: Duration = Duration::from_secs(3);
/// Tries to reach a host; between them another host may be starting or exiting.
const START_ATTEMPTS: u32 = 4;
const START_RETRY: Duration = Duration::from_millis(100);
/// The relay: the slim terminal host binary beside this one.
const RELAY_BINARY: &str = "cmux-tui-host";
const RELAY_VERB: &str = "__mcp-relay";
/// Environment that fixes the host's process-wide state: part of its key.
const KEY_ENV: [&str; 8] = [
    "HOME",
    "TMPDIR",
    "XDG_RUNTIME_DIR",
    "ACPMUX_HOME",
    "ACPMUX_SOCKET",
    "LANG",
    "LC_ALL",
    "LC_MESSAGES",
];
/// A caller's identity, never part of the host's own environment: every
/// request reads its client's (a read outside a client scope then finds
/// none, instead of the agent that started the host).
const CALLER_ENV: [&str; 12] = [
    "CMUX_AGENT_SESSION",
    "ACPMUX_SESSION_ID",
    acpmux::hub::person::CALLER_TOKEN_ENV,
    acpmux::hub::person::CALLER_SOCKET_ENV,
    "CMUX_TUI_TERMINAL_ID",
    "CMUX_SURFACE_ID",
    "CMUX_PANEL_ID",
    "CMUX_CALLER_HOME_CHAT",
    "CMUX_CHIEF_OWNER_SOCKET",
    "CMUX_AGENT_PRINCIPAL",
    super::ALLOWED_TOOLS_ENV,
    super::upstream::ENV,
];

/// Turns this `serve` into a relay to the shared host when `mcpCatalogHost`
/// is on: it does not return then. `None` when the feature is off, else why
/// this process must serve itself.
pub(super) fn relay(global: &GlobalArgs, code_mode: bool, config: &Path) -> Option<String> {
    let features = crate::feature_flags::daemon_features();
    if !features.is_enabled(cmux_features::feature::MCP_CATALOG_HOST) {
        return None;
    }
    Some(match try_relay(global, code_mode, config) {
        Ok(never) => match never {},
        Err(why) => why,
    })
}

fn try_relay(global: &GlobalArgs, code_mode: bool, config: &Path) -> Result<Infallible, String> {
    let relay = relay_binary().ok_or_else(|| format!("no {RELAY_BINARY} beside this cmux"))?;
    let hello = hello_line(global, code_mode, config)?;
    let socket = socket_path()?;
    // A host that reaches its idle exit between our connect and its answer
    // closes the connection: the next try starts a new one.
    // A refusal is the host's answer and final.
    let mut last = String::new();
    for _ in 0..2 {
        let mut stream = connect_or_start(&socket)?;
        match greet(&mut stream, &hello) {
            Ok(()) => return exec_relay(&relay, stream),
            Err(Greeting::Refused(why)) => return Err(why),
            Err(Greeting::Lost(why)) => last = why,
        }
    }
    Err(last)
}

/// Why a hello did not lead to a session.
#[derive(Debug)]
enum Greeting {
    /// The host answered no (a bad hello, or an app that does not admit it).
    Refused(String),
    /// No answer: the connection failed or closed.
    Lost(String),
}

/// `cmux-tui-host` beside this executable (never from `PATH`), a regular file.
fn relay_binary() -> Option<PathBuf> {
    let own = cmux_blocking::fs::canonicalize(std::env::current_exe().ok()?).ok()?;
    let relay = own.parent()?.join(RELAY_BINARY);
    cmux_blocking::fs::symlink_metadata(&relay)
        .is_ok_and(|meta| meta.file_type().is_file())
        .then_some(relay)
}

/// The host's socket for this build and the caller's process-wide settings,
/// in the user's private runtime directory.
fn socket_path() -> Result<PathBuf, String> {
    let exe = std::env::current_exe()
        .and_then(cmux_blocking::fs::canonicalize)
        .map_err(|e| e.to_string())?;
    let name = format!("mcp-{}.sock", host_key(&exe, |key| std::env::var_os(key)));
    let preferred = cmux_tui_core::platform::runtime_dir();
    let dir = if preferred.join(&name).as_os_str().len() < 100 {
        preferred
    } else {
        cmux_tui_core::platform::fallback_runtime_dir()
    };
    private_dir(&dir).map_err(|error| format!("{}: {error}", dir.display()))?;
    Ok(dir.join(name))
}

fn host_key(exe: &Path, env: impl Fn(&str) -> Option<std::ffi::OsString>) -> String {
    let mut digest = Sha256::new();
    digest.update(exe.as_os_str().as_encoded_bytes());
    digest.update([0]);
    digest.update(cmux_build_identity::BUILD_IDENTITY.as_bytes());
    for key in KEY_ENV {
        digest.update([0]);
        digest.update(key.as_bytes());
        digest.update([0]);
        if let Some(value) = env(key) {
            digest.update(value.as_encoded_bytes());
        }
    }
    digest.finalize().iter().take(8).map(|byte| format!("{byte:02x}")).collect()
}

/// `dir`, made if missing: a directory of this user that no one else may write.
fn private_dir(dir: &Path) -> io::Result<()> {
    use std::os::unix::fs::{DirBuilderExt, MetadataExt};
    match crate::blocking::fs::create_dir_with(std::fs::DirBuilder::new().mode(0o700), dir) {
        Err(error) if error.kind() != io::ErrorKind::AlreadyExists => return Err(error),
        _ => {}
    }
    let meta = cmux_blocking::fs::symlink_metadata(dir)?;
    // SAFETY: getuid has no preconditions and cannot fail.
    let uid = unsafe { libc::getuid() };
    if !meta.is_dir() || meta.uid() != uid || meta.mode() & 0o022 != 0 {
        return Err(io::Error::new(io::ErrorKind::PermissionDenied, "not a private directory"));
    }
    Ok(())
}

fn connect_or_start(socket: &Path) -> Result<UnixStream, String> {
    let mut last = String::new();
    for attempt in 1..=START_ATTEMPTS {
        match connect(socket) {
            Ok(stream) => return Ok(stream),
            Err(error) => last = error,
        }
        if !start_host(socket)? && attempt < START_ATTEMPTS {
            // wakeup-allow: backoff another host holds the lock while it starts or exits; at most 3 short waits
            cmux_blocking::thread::sleep(START_RETRY * attempt);
        }
    }
    Err(last)
}

fn connect(socket: &Path) -> Result<UnixStream, String> {
    let stream = UnixStream::connect(socket)
        .map_err(|error| format!("no MCP host at {}: {error}", socket.display()))?;
    // SAFETY: getuid has no preconditions and cannot fail.
    cmux_tui_core::platform::require_unix_peer_uid(&stream, unsafe { libc::getuid() })
        .map_err(|error| error.to_string())?;
    Ok(stream)
}

/// Starts a host for `socket`: `true` once it listens, `false` when another
/// one holds the socket's lock.
fn start_host(socket: &Path) -> Result<bool, String> {
    let exe = std::env::current_exe().map_err(|error| error.to_string())?;
    let mut command = cmux_process::Command::new(exe);
    command
        .arg("mcp")
        .arg(START_VERB)
        .arg(socket)
        .current_dir("/")
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::piped())
        .stderr(host_log(socket));
    for key in CALLER_ENV {
        command.env_remove(key);
    }
    let mut starter =
        command.spawn().map_err(|error| format!("cannot start the MCP host: {error}"))?;
    let stdout = starter.stdout.take().ok_or("the MCP host starter has no stdout")?;
    // The starter exits as soon as the host runs; the host writes the line.
    let _ = starter.wait();
    let mut line = String::new();
    BufReader::new(stdout).read_line(&mut line).map_err(|error| error.to_string())?;
    match line.trim() {
        READY => Ok(true),
        LOCK_HELD => Ok(false),
        _ => Err(format!("the MCP host did not start; see {}", log_path(socket).display())),
    }
}

fn log_path(socket: &Path) -> PathBuf {
    socket.with_extension("log")
}

/// The host's stderr: its log beside the socket, emptied when it passed 1 MiB.
fn host_log(socket: &Path) -> cmux_process::Stdio {
    use std::os::unix::fs::OpenOptionsExt;
    let path = log_path(socket);
    let full = cmux_blocking::fs::metadata(&path).is_ok_and(|meta| meta.len() > 1 << 20);
    let mut options = std::fs::OpenOptions::new();
    options.create(true).mode(0o600);
    if full {
        options.write(true).truncate(true);
    } else {
        options.append(true);
    }
    crate::blocking::fs::open_with(&options, &path)
        .map_or_else(|_| cmux_process::Stdio::null(), cmux_process::Stdio::from)
}

/// The client's hello line: who calls, with which options and settings file.
fn hello_line(global: &GlobalArgs, code_mode: bool, config: &Path) -> Result<String, String> {
    let config = config.to_str().ok_or("the settings file path is not UTF-8")?;
    let caller = CallerEnv::of_process();
    let hello = json!({
        "hello": HELLO,
        "code_mode": code_mode,
        "config": config,
        "global": global_json(global)?,
        "caller": caller.to_json(),
    });
    Ok(format!("{hello}\n"))
}

/// Sends the hello and reads the host's answer, one byte at a time so
/// nothing after it is taken from the relay.
fn greet(stream: &mut UnixStream, hello: &str) -> Result<(), Greeting> {
    use Greeting::{Lost, Refused};
    stream.write_all(hello.as_bytes()).map_err(|error| Lost(format!("MCP host: {error}")))?;
    // wakeup-allow: deadline one bounded wait for the host's answer to the hello
    let _ = stream.set_read_timeout(Some(HELLO_ANSWER_TIMEOUT));
    let mut answer = Vec::new();
    let mut byte = [0u8];
    while answer.len() < 4096 {
        match stream.read(&mut byte) {
            Ok(0) => return Err(Lost("the MCP host closed the connection".into())),
            Ok(_) if byte[0] == b'\n' => break,
            Ok(_) => answer.push(byte[0]),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(Lost(format!("MCP host: {error}"))),
        }
    }
    let _ = stream.set_read_timeout(None);
    let answer: Value = serde_json::from_slice(&answer).map_err(|error| Lost(error.to_string()))?;
    if answer["ok"] == true {
        return Ok(());
    }
    Err(Refused(format!(
        "the MCP host refused: {}",
        answer["error"].as_str().unwrap_or("no reason")
    )))
}

/// Replaces this process with the relay on `stream` (same pid, stdio and
/// parent, so the harness sees no change). Returns only when that failed.
fn exec_relay(relay: &Path, stream: UnixStream) -> Result<Infallible, String> {
    let fd = stream.as_raw_fd();
    set_inheritable(fd, true).map_err(|error| error.to_string())?;
    let error = cmux_process::Command::new(relay).arg(RELAY_VERB).arg(fd.to_string()).exec();
    let _ = set_inheritable(fd, false);
    drop(stream);
    Err(format!("cannot start {}: {error}", relay.display()))
}

fn set_inheritable(fd: i32, inheritable: bool) -> io::Result<()> {
    // SAFETY: F_GETFD/F_SETFD on a descriptor this process owns.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
    if flags < 0 {
        return Err(io::Error::last_os_error());
    }
    let flags = if inheritable { flags & !libc::FD_CLOEXEC } else { flags | libc::FD_CLOEXEC };
    // SAFETY: as above.
    if unsafe { libc::fcntl(fd, libc::F_SETFD, flags) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn global_json(global: &GlobalArgs) -> Result<Value, String> {
    let path = |path: &Option<PathBuf>| match path {
        None => Ok(Value::Null),
        Some(path) => path.to_str().map(|text| json!(text)).ok_or("a socket path is not UTF-8"),
    };
    let output = match global.output {
        OutputMode::Human => "human",
        OutputMode::Json => "json",
        OutputMode::JsonLines => "json_lines",
        OutputMode::Quiet => "quiet",
    };
    Ok(json!({
        "socket": path(&global.socket)?,
        "session": global.session,
        "machine": global.machine,
        "app_socket": path(&global.app_socket)?,
        "idempotency_key": global.idempotency_key,
        "all_sessions": global.all_sessions,
        "output": output,
    }))
}

fn global_from_json(value: &Value) -> Option<GlobalArgs> {
    let text = |name: &str| match value.get(name) {
        None | Some(Value::Null) => Some(None),
        Some(Value::String(text)) => Some(Some(text.clone())),
        Some(_) => None,
    };
    let output = match value.get("output")?.as_str()? {
        "human" => OutputMode::Human,
        "json" => OutputMode::Json,
        "json_lines" => OutputMode::JsonLines,
        "quiet" => OutputMode::Quiet,
        _ => return None,
    };
    Some(GlobalArgs {
        socket: text("socket")?.map(PathBuf::from),
        session: text("session")?,
        machine: text("machine")?,
        app_socket: text("app_socket")?.map(PathBuf::from),
        idempotency_key: text("idempotency_key")?,
        all_sessions: value.get("all_sessions")?.as_bool()?,
        output,
    })
}

/// A client's hello, read on the host.
struct Hello {
    global: GlobalArgs,
    config: PathBuf,
    code_mode: bool,
    caller: CallerEnv,
}

fn parse_hello(line: &[u8]) -> Result<Hello, String> {
    let value: Value = serde_json::from_slice(line).map_err(|error| error.to_string())?;
    if value["hello"] != HELLO {
        return Err(format!("this host speaks {HELLO}"));
    }
    let bad = |field: &str| format!("the hello has no valid {field}");
    Ok(Hello {
        global: global_from_json(&value["global"]).ok_or_else(|| bad("global"))?,
        config: value["config"].as_str().map(PathBuf::from).ok_or_else(|| bad("config"))?,
        code_mode: value["code_mode"].as_bool().ok_or_else(|| bad("code_mode"))?,
        caller: CallerEnv::from_json(&value["caller"]).ok_or_else(|| bad("caller"))?,
    })
}

/// `__host-start`: the host in a new session with this process's stdout
/// (the starter's readiness pipe) and stderr (the log).
pub(super) fn start_detached(socket: &Path) -> i32 {
    let started = std::env::current_exe().and_then(|exe| {
        cmux_process::Command::new(exe)
            .arg("mcp")
            .arg(RUN_VERB)
            .arg(socket)
            .current_dir("/")
            .new_session()
            .stdin(cmux_process::Stdio::null())
            .stdout(cmux_process::Stdio::inherit())
            .stderr(cmux_process::Stdio::inherit())
            .spawn()
    });
    match started {
        Ok(_) => 0,
        Err(error) => {
            eprintln!("cmux mcp: cannot start the MCP host: {error}");
            1
        }
    }
}

/// `__host`: serves clients on `socket` until it has had none for the idle
/// grace.
pub(super) fn run(socket: &Path) -> i32 {
    let _ = crate::restore_default_termination_signals();
    let _lock = match take_lock(socket) {
        Ok(Some(lock)) => lock,
        Ok(None) => {
            say(LOCK_HELD);
            return 0;
        }
        Err(error) => {
            eprintln!("cmux mcp host: lock {}: {error}", socket.display());
            return 1;
        }
    };
    let started = bind(socket).and_then(|listener| {
        let catalog = SharedCatalog::start()?;
        let idle = Idle::start(socket.to_owned(), idle_grace())?;
        Ok((listener, catalog, idle))
    });
    let (listener, catalog, idle) = match started {
        Ok(started) => started,
        Err(error) => {
            eprintln!("cmux mcp host: {}: {error}", socket.display());
            return 1;
        }
    };
    say(READY);
    release_stdout();
    eprintln!("cmux mcp host: serving {}", socket.display());
    serve_clients(&listener, &catalog, &idle);
    let _ = cmux_blocking::fs::remove_file(socket);
    1
}

fn idle_grace() -> Duration {
    std::env::var(IDLE_EXIT_ENV)
        .ok()
        .and_then(|ms| ms.parse().ok())
        .map_or(IDLE_EXIT, Duration::from_millis)
}

/// The lock on `<socket>.lock` for this process's life, or `None` when
/// another host holds it.
fn take_lock(socket: &Path) -> io::Result<Option<std::fs::File>> {
    use std::os::unix::fs::OpenOptionsExt;
    let file = crate::blocking::fs::open_with(
        std::fs::OpenOptions::new().create(true).write(true).truncate(false).mode(0o600),
        socket.with_extension("lock"),
    )?;
    // SAFETY: flock on a descriptor this function owns.
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
        return Ok(Some(file));
    }
    let error = io::Error::last_os_error();
    if error.kind() == io::ErrorKind::WouldBlock { Ok(None) } else { Err(error) }
}

/// Listens on `socket` (the lock holder removes a stale file first), read
/// and write for this user only.
fn bind(socket: &Path) -> io::Result<UnixListener> {
    use std::os::unix::fs::PermissionsExt;
    let _ = cmux_blocking::fs::remove_file(socket);
    let listener = UnixListener::bind(socket)?;
    crate::blocking::fs::set_permissions(socket, std::fs::Permissions::from_mode(0o600))?;
    Ok(listener)
}

fn say(line: &str) {
    let mut stdout = io::stdout().lock();
    let _ = writeln!(stdout, "{line}").and_then(|()| stdout.flush());
}

/// Points stdout at /dev/null once the starter has its line, so the host
/// never writes into a pipe nobody reads.
fn release_stdout() {
    if let Ok(null) =
        crate::blocking::fs::open_with(std::fs::OpenOptions::new().write(true), "/dev/null")
    {
        // SAFETY: dup2 of a descriptor this function owns onto stdout; `null`
        // closes its own copy when dropped.
        unsafe { libc::dup2(null.as_raw_fd(), libc::STDOUT_FILENO) };
    }
}

fn serve_clients(listener: &UnixListener, catalog: &SharedCatalog, idle: &Idle) {
    // SAFETY: getuid has no preconditions and cannot fail.
    let uid = unsafe { libc::getuid() };
    let mut next = 0u64;
    for stream in listener.incoming() {
        let stream = match stream {
            Ok(stream) => stream,
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::Interrupted | io::ErrorKind::ConnectionAborted
                ) =>
            {
                continue;
            }
            Err(error) => {
                eprintln!("cmux mcp host: accept: {error}; exiting");
                return;
            }
        };
        if cmux_tui_core::platform::require_unix_peer_uid(&stream, uid).is_err() {
            continue;
        }
        if !idle.connected() {
            continue;
        }
        next += 1;
        let client = next;
        let (catalog, done) = (catalog.clone(), idle.clone());
        let started =
            cmux_threads::spawn("cmux-mcp-client", cmux_threads::ThreadQos::Utility, move || {
                let mut seat = Seat { client, catalog, idle: done, watched: None };
                serve_client(stream, &mut seat);
            });
        if let Err(error) = started {
            eprintln!("cmux mcp host: cannot serve a client: {error}");
            idle.disconnected();
        }
    }
}

/// A connected client's hold on the host: its count in [`Idle`] and its
/// app's watch. Its client thread drops it at the end, on a panic's unwind
/// too, so a failed client neither keeps the host alive nor leaves its
/// socket open behind the owner's notifier.
struct Seat {
    client: u64,
    catalog: SharedCatalog,
    idle: Idle,
    watched: Option<PathBuf>,
}

impl Seat {
    fn watch(&mut self, app: PathBuf, output: &watch::Output) {
        self.catalog.watch(app.clone(), self.client, output.clone());
        self.watched = Some(app);
    }
}

impl Drop for Seat {
    fn drop(&mut self) {
        if let Some(app) = self.watched.take() {
            self.catalog.unwatch(app, self.client);
        }
        self.idle.disconnected();
    }
}

/// One client: its hello, then its MCP session with its caller in scope.
/// Writes to the client block until it reads, as the in-process server's
/// writes to its stdout did: a message is never cut, and a client that stops
/// reading holds only its own threads.
fn serve_client(stream: UnixStream, seat: &mut Seat) {
    let Ok(read_half) = stream.try_clone() else { return };
    let mut reader = BufReader::new(read_half);
    let mut line = Vec::new();
    let read = reader.by_ref().take(MAX_HELLO_BYTES).read_until(b'\n', &mut line);
    let hello = match read {
        Ok(0) | Err(_) => return,
        Ok(_) => parse_hello(&line),
    };
    let Hello { global, config, code_mode, caller } = match hello {
        Ok(hello) => hello,
        Err(why) => {
            let _ = writeln!(&stream, "{}", json!({"ok": false, "error": why}));
            return;
        }
    };
    caller_env::scope(Arc::new(caller), || {
        let mut server = client_server(global, config, code_mode);
        let app = server.backend.catalog_key();
        let answer = match app.as_deref().map_or(Ok(()), app_admits_host) {
            Ok(()) => json!({"ok": true}),
            Err(why) => json!({"ok": false, "error": why}),
        };
        if writeln!(&stream, "{answer}").is_err() || answer["ok"] != true {
            return;
        }
        let output = watch::Output::new(stream);
        server.shared = Some(seat.catalog.clone());
        if let Some(app) = app {
            seat.watch(app, &output);
        }
        server.run(reader, &output);
    });
}

/// `Ok` when the app at `app` answers this host's requests. In `cmuxOnly`
/// mode the app admits only a peer with a trusted ancestor
/// (ControlPeerAncestry.swift), and the host is launchd's child, so that
/// client serves in its own process, which descends from its agent's
/// supervisor. An app that is not listening cannot say which mode it will
/// use, so its clients serve in their own process too.
fn app_admits_host(app: &Path) -> Result<(), String> {
    let mut stream = super::super::app::connect(app)?;
    match super::super::app::request(&mut stream, "system.ping", json!({}), APP_PROBE_TIMEOUT) {
        // The app's one plain-text line for a peer it refuses
        // (`ControlAuthorizer.accessDenied`).
        Err(message) if message.starts_with("ERROR: Access denied") => Err(message),
        _ => Ok(()),
    }
}

/// Counts connected clients and ends the host once none has been
/// connected for the grace. The count and a closed bit share one atomic:
/// the idle exit closes it only at zero, and a client accepted after that is
/// dropped unanswered (its `serve` starts a new host), so no client the host
/// answered is cut off by the exit.
#[derive(Clone)]
struct Idle {
    live: Arc<AtomicUsize>,
    wake: mpsc::Sender<()>,
}

/// The closed bit of [`Idle::live`].
const CLOSED: usize = 1 << (usize::BITS - 1);

impl Idle {
    fn start(socket: PathBuf, grace: Duration) -> io::Result<Self> {
        let (wake, woken) = mpsc::channel();
        let live = Arc::new(AtomicUsize::new(0));
        let counted = live.clone();
        cmux_threads::spawn("cmux-mcp-host-idle", cmux_threads::ThreadQos::Utility, move || {
            if wait_for_idle(&counted, &woken, grace) {
                // Unlinked first: a client that comes now starts a new host,
                // which takes the lock once this process is gone.
                let _ = cmux_blocking::fs::remove_file(&socket);
                crate::client_log::exit(0);
            }
        })?;
        Ok(Self { live, wake })
    }

    /// Counts a new client; `false` once the host is closing.
    fn connected(&self) -> bool {
        let counted = self
            .live
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |live| {
                (live & CLOSED == 0).then_some(live + 1)
            })
            .is_ok();
        let _ = self.wake.send(());
        counted
    }

    fn disconnected(&self) {
        self.live.fetch_sub(1, Ordering::AcqRel);
        let _ = self.wake.send(());
    }
}

/// `true` once no client has been connected for `grace` (`live` is then
/// closed); `false` when the host stopped counting (every sender gone).
fn wait_for_idle(live: &AtomicUsize, woken: &mpsc::Receiver<()>, grace: Duration) -> bool {
    loop {
        if live.load(Ordering::Acquire) != 0 {
            if cmux_blocking::sync::recv(woken).is_err() {
                return false;
            }
            continue;
        }
        // wakeup-allow: deadline the idle exit: one wait, only while no client is connected
        match crate::blocking::sync::recv_timeout(woken, grace) {
            Ok(()) => {}
            Err(mpsc::RecvTimeoutError::Timeout) => {
                if live.compare_exchange(0, CLOSED, Ordering::AcqRel, Ordering::Acquire).is_ok() {
                    return true;
                }
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => return false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;
    use std::ffi::OsString;

    /// The refusal of an app in `cmuxOnly` mode (`ControlAuthorizer.accessDenied`).
    const DENIED: &str = "ERROR: Access denied - only processes started inside cmux can connect";

    /// An app control socket in `dir` that answers each request line with
    /// `answer(request)`.
    fn fake_app(dir: &Path, answer: fn(&Value) -> String) -> PathBuf {
        let path = dir.join("app.sock");
        let listener = UnixListener::bind(&path).unwrap();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { return };
                std::thread::spawn(move || {
                    let mut writer = stream.try_clone().unwrap();
                    for line in BufReader::new(stream).lines() {
                        let Ok(line) = line else { return };
                        let request: Value = serde_json::from_str(&line).unwrap();
                        if writeln!(writer, "{}", answer(&request)).is_err() {
                            return;
                        }
                    }
                });
            }
        });
        path
    }

    /// An app with a catalog whose tools/list answer is larger than a
    /// socket's buffer.
    fn large_app(request: &Value) -> String {
        let result = if request["method"] == "action.list" {
            let actions = (0..2000)
                .map(|index| {
                    json!({"id": format!("a{index}"), "cli_name": format!("app action-{index}"),
                           "title": format!("Action {index} {}", "x".repeat(400)), "cli": true,
                           "surfaces": {"cli": "offered", "mcp": "offered"}, "arguments": []})
                })
                .collect::<Vec<_>>();
            json!({ "actions": actions })
        } else {
            json!({})
        };
        json!({"id": request["id"], "ok": true, "result": result}).to_string()
    }

    struct Client {
        agent: UnixStream,
        idle: Idle,
        thread: std::thread::JoinHandle<()>,
        greeting: Result<(), Greeting>,
    }

    /// One client of the host for the app at `app`, through `serve_client`.
    fn connect_client(app: &Path, catalog: &SharedCatalog) -> Client {
        let (host_end, mut agent) = UnixStream::pair().unwrap();
        let (wake, _) = mpsc::channel();
        let idle = Idle { live: Arc::new(AtomicUsize::new(0)), wake };
        assert!(idle.connected());
        let (seat_idle, seat_catalog) = (idle.clone(), catalog.clone());
        let thread = std::thread::spawn(move || {
            let mut seat =
                Seat { client: 1, catalog: seat_catalog, idle: seat_idle, watched: None };
            serve_client(host_end, &mut seat);
        });
        let global = GlobalArgs { app_socket: Some(app.to_owned()), ..GlobalArgs::default() };
        let hello = hello_line(&global, false, &app.with_file_name("cmux-next.json")).unwrap();
        let greeting = greet(&mut agent, &hello);
        Client { agent, idle, thread, greeting }
    }

    #[test]
    fn a_client_that_panics_leaves_the_host_and_closes_its_socket() {
        let catalog = SharedCatalog::start_unwatched().unwrap();
        let (wake, _) = mpsc::channel();
        let idle = Idle { live: Arc::new(AtomicUsize::new(0)), wake };
        assert!(idle.connected());
        let (host_end, agent) = UnixStream::pair().unwrap();
        let (seat_idle, seat_catalog) = (idle.clone(), catalog);
        let client = std::thread::spawn(move || {
            let mut seat =
                Seat { client: 1, catalog: seat_catalog, idle: seat_idle, watched: None };
            let output = watch::Output::new(host_end);
            seat.watch(PathBuf::from("/tmp/app.sock"), &output);
            panic!("a request of this client failed");
        });
        assert!(client.join().is_err());
        assert_eq!(idle.live.load(Ordering::Acquire), 0, "a panicked client still counts");
        // The owner dropped the client's notifier, the last holder of its
        // output: the agent's relay reads the end.
        agent.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let mut rest = Vec::new();
        assert_eq!((&agent).read_to_end(&mut rest).unwrap(), 0);
    }

    #[test]
    fn a_client_that_pauses_reading_gets_only_whole_messages() {
        let dir = tempfile::tempdir().unwrap();
        let app = fake_app(dir.path(), large_app);
        let catalog = SharedCatalog::start_unwatched().unwrap();
        let Client { agent, idle, thread, greeting } = connect_client(&app, &catalog);
        greeting.unwrap();
        for message in [
            json!({"jsonrpc": "2.0", "id": "init", "method": "initialize", "params": {
                "protocolVersion": "2025-06-18", "capabilities": {},
                "clientInfo": {"name": "pause", "version": "1"}}}),
            json!({"jsonrpc": "2.0", "method": "notifications/initialized"}),
            json!({"jsonrpc": "2.0", "id": "list-1", "method": "tools/list"}),
            json!({"jsonrpc": "2.0", "id": "list-2", "method": "tools/list"}),
        ] {
            writeln!(&agent, "{message}").unwrap();
        }
        // The agent reads nothing for 25 s (a harness stopped in a debugger)
        // while each response is larger than the socket's buffer, and
        // notifications come while the first response waits to be sent.
        std::thread::sleep(Duration::from_secs(1));
        for _ in 0..3 {
            catalog.changed(app.clone());
        }
        std::thread::sleep(Duration::from_secs(24));
        agent.set_read_timeout(Some(Duration::from_secs(30))).unwrap();
        let mut reader = BufReader::new(&agent);
        let mut answered = HashSet::new();
        while answered.len() < 3 {
            let mut line = String::new();
            assert!(reader.read_line(&mut line).unwrap() > 0, "the host ended the session");
            let message: Value = serde_json::from_str(&line)
                .unwrap_or_else(|error| panic!("a cut message ({error}): {line:.200}"));
            if let Some(id) = message["id"].as_str() {
                if id.starts_with("list") {
                    assert!(message["result"]["tools"].as_array().is_some_and(|t| t.len() > 2000));
                }
                answered.insert(id.to_owned());
            }
        }
        agent.shutdown(std::net::Shutdown::Write).unwrap();
        thread.join().unwrap();
        assert_eq!(idle.live.load(Ordering::Acquire), 0);
    }

    #[test]
    fn an_app_that_refuses_the_host_sends_its_client_to_serve_itself() {
        let dir = tempfile::tempdir().unwrap();
        let app = fake_app(dir.path(), |_| DENIED.to_owned());
        let catalog = SharedCatalog::start_unwatched().unwrap();
        let Client { idle, thread, greeting, .. } = connect_client(&app, &catalog);
        assert!(
            matches!(&greeting, Err(Greeting::Refused(why)) if why.contains("Access denied")),
            "{greeting:?}"
        );
        thread.join().unwrap();
        assert_eq!(idle.live.load(Ordering::Acquire), 0);

        // An app that does not listen cannot say which mode it will use.
        let Client { thread, greeting, .. } =
            connect_client(&dir.path().join("gone.sock"), &catalog);
        assert!(matches!(greeting, Err(Greeting::Refused(_))), "{greeting:?}");
        thread.join().unwrap();

        // An app that admits the host keeps its client.
        let admits = tempfile::tempdir().unwrap();
        let app = fake_app(admits.path(), large_app);
        let Client { agent, thread, greeting, .. } = connect_client(&app, &catalog);
        greeting.unwrap();
        agent.shutdown(std::net::Shutdown::Write).unwrap();
        thread.join().unwrap();
    }

    #[test]
    fn the_hello_carries_the_caller_and_the_options() {
        let global = GlobalArgs {
            app_socket: Some(PathBuf::from("/tmp/app.sock")),
            session: Some("work".into()),
            output: OutputMode::JsonLines,
            ..GlobalArgs::default()
        };
        let line = hello_line(&global, true, Path::new("/tmp/cmux-next.json")).unwrap();
        let hello = parse_hello(line.trim_end().as_bytes()).unwrap();
        assert_eq!(hello.global.app_socket, global.app_socket);
        assert_eq!(hello.global.session.as_deref(), Some("work"));
        assert!(matches!(hello.global.output, OutputMode::JsonLines));
        assert_eq!(hello.config, PathBuf::from("/tmp/cmux-next.json"));
        assert!(hello.code_mode);
        assert_eq!(hello.caller.var("PATH"), std::env::var("PATH").ok().as_deref());
        assert_eq!(hello.caller.cwd(), std::env::current_dir().ok().as_ref());
        assert!(parse_hello(br#"{"hello": "other/1"}"#).is_err());
        assert!(
            parse_hello(line.replace("\"code_mode\":true", "\"code_mode\":1").as_bytes()).is_err()
        );
    }

    #[test]
    fn the_host_key_follows_the_build_and_the_process_wide_settings() {
        let env =
            |home: &'static str| move |key: &str| (key == "HOME").then(|| OsString::from(home));
        let exe = Path::new("/Applications/cmux.app/Contents/Resources/bin/cmux-tui");
        assert_eq!(host_key(exe, env("/Users/a")), host_key(exe, env("/Users/a")));
        assert_ne!(host_key(exe, env("/Users/a")), host_key(exe, env("/Users/b")));
        assert_ne!(
            host_key(exe, env("/Users/a")),
            host_key(Path::new("/other/cmux-tui"), env("/Users/a"))
        );
        assert_eq!(host_key(exe, env("/Users/a")).len(), 16);
    }

    #[test]
    fn the_host_waits_for_its_last_client_then_its_grace() {
        let (wake, woken) = mpsc::channel();
        let idle = Idle { live: Arc::new(AtomicUsize::new(0)), wake };
        assert!(idle.connected());
        assert!(idle.connected());
        idle.disconnected();
        let counted = idle.live.clone();
        let waiter =
            std::thread::spawn(move || wait_for_idle(&counted, &woken, Duration::from_millis(50)));
        // One client is still connected: no exit while it stays.
        std::thread::sleep(Duration::from_millis(150));
        assert!(!waiter.is_finished(), "the host exited with a client connected");
        idle.disconnected();
        assert!(waiter.join().unwrap(), "the host must exit after its grace");
        assert!(!idle.connected(), "a closing host takes no new client");

        let (wake, woken) = mpsc::channel::<()>();
        drop(wake);
        assert!(!wait_for_idle(&AtomicUsize::new(0), &woken, Duration::from_secs(60)));
    }

    #[test]
    fn a_private_dir_refuses_one_others_may_write() {
        use std::os::unix::fs::PermissionsExt;
        let temp = tempfile::tempdir().unwrap();
        let dir = temp.path().join("runtime");
        private_dir(&dir).unwrap();
        assert_eq!(std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777, 0o700);
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o777)).unwrap();
        assert!(private_dir(&dir).is_err());
    }
}
