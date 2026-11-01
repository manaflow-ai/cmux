//! `cmux link ensure`, `cmux link stop` and `cmux link status` (cx-rtipa
//! slice S1): the app starts and stops the per-user link on demand, the way
//! it ensures the session daemon (`cmux-tui server ensure`) and acpmux. A
//! link is found only through its registration (`link.json` in the parent
//! of its state directory); its socket name comes from its state directory
//! (`state::socket_path_for`), so a tagged DEV app's link and the release
//! app's link never share a socket, a registration or a state directory.
//!
//! - `ensure --state-dir D [--install ID] [--port P] [--session-socket S]
//!   [--server-config F]`: runs `init` first when D has no config (then
//!   `--install` is required; `--port 0` binds any free UDP port), returns
//!   the live link of D when one runs, else starts `cmux link serve` in its
//!   own session (it survives the caller) and waits for its ready line. A
//!   different install, port, session socket or server config is refused;
//!   `--handoff` (the owning app only; see spec/cli.md) restarts or re-inits
//!   instead, and also replaces a link of another build. One JSON line on
//!   stdout: `{"status":"running"|"started"|"restarted", "pid", "socket",
//!   "build", ...}`.
//! - `stop --state-dir D`: signals the registered pid (only after a fresh
//!   connection proved that pid serves D's own socket), waits for that
//!   connection to end and then for the process to exit. Never by name or
//!   pattern. `{"ok":true,"stopped":bool}`, or `stop_timeout`.
//! - `status --state-dir D`: `{"running":false}`, or `{"running":true}` with
//!   the link's own `link.status` answer.

use std::io::{BufRead as _, BufReader, Read as _, Write as _};
use std::os::fd::{FromRawFd as _, RawFd};
use std::path::Path;
use std::time::Duration;

use anyhow::{Context as _, anyhow, bail};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use cmux_link::registration;
use serde_json::{Value, json};

use super::state::{DEFAULT_PORT, LinkConfig, LinkState};
use super::{Flags, print_json};
use cmux_json::JsonSet as _;

/// How long `ensure` waits for a started link's ready line.
const START_BUDGET: Duration = Duration::from_secs(20);
/// How long `stop` waits for the link to end after the signal.
const STOP_BUDGET: Duration = Duration::from_secs(10);
/// How long `ensure` or `stop` waits for another one of the same state
/// directory (`link.ensure.lock`).
const LOCK_BUDGET: Duration = Duration::from_secs(30);
/// How long a `link.status` read may take.
const STATUS_BUDGET: Duration = Duration::from_secs(3);

/// The build of this binary, which a link reports in `link.status`.
fn build() -> &'static str {
    cmux_build_identity::BUILD_IDENTITY
}

/// The write end of the readiness pipe that `ensure` gave `serve`
/// (`--ready-fd`). The ready line goes there once; dropping it closes it,
/// so `ensure` sees end of file when the link exits before it is ready.
pub(super) struct ReadyPipe(std::fs::File);

impl ReadyPipe {
    pub(super) fn take(fd: &str) -> anyhow::Result<Self> {
        let fd: RawFd = fd.parse().map_err(|_| anyhow!("--ready-fd needs a descriptor number"))?;
        if fd < 3 {
            bail!("--ready-fd must not be stdin, stdout or stderr");
        }
        // SAFETY: F_GETFD only reads the descriptor flags.
        if unsafe { libc::fcntl(fd, libc::F_GETFD) } == -1 {
            bail!("--ready-fd {fd} is not open");
        }
        // The link's own children (dials, sync) must not keep the pipe open.
        // SAFETY: F_SETFD on a descriptor this process owns.
        unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) };
        // SAFETY: `ensure` passed this descriptor to this process only, and
        // nothing else in this process owns it.
        Ok(Self(unsafe { std::fs::File::from_raw_fd(fd) }))
    }

    pub(super) fn send(mut self, line: &Value) {
        let _ = writeln!(self.0, "{line}");
    }
}

/// What a link serves besides its state: the session socket its paired
/// peers reach and the `server.json` its owner session came from (path and
/// the SHA-256 of its bytes, null when absent).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Served {
    pub session_socket: Option<std::path::PathBuf>,
    pub credential_socket: Option<std::path::PathBuf>,
    pub server_config: Option<std::path::PathBuf>,
    pub server_config_sha256: Option<String>,
}

impl Served {
    /// What `flags` ask for: `--session-socket`, and `--server-config` or
    /// the user-mode default (`super::server_config_path`), hashed now.
    pub(super) fn wanted(flags: &Flags) -> anyhow::Result<Self> {
        let server_config = super::server_config_path(flags);
        let bytes = super::read_server_config(server_config.as_deref())?;
        Ok(Self::of(flags, server_config, bytes.as_deref()))
    }

    /// The served fields of `flags`, with `server_config`'s `bytes` (read
    /// once by the caller).
    pub(super) fn of(
        flags: &Flags,
        server_config: Option<std::path::PathBuf>,
        bytes: Option<&[u8]>,
    ) -> Self {
        use sha2::{Digest as _, Sha256};
        let server_config_sha256 =
            bytes.map(|bytes| Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect());
        Self {
            session_socket: flags.get("--session-socket").map(std::path::PathBuf::from),
            credential_socket: flags.get("--credential-socket").map(std::path::PathBuf::from),
            server_config,
            server_config_sha256,
        }
    }

    fn json(&self) -> Value {
        json!({
            "session_socket": self.session_socket,
            "credential_socket": self.credential_socket,
            "server_config": { "path": self.server_config, "sha256": self.server_config_sha256 },
        })
    }

    /// The same fields in a `link.status` answer. An older link that
    /// answers without them counts as a match: it stays usable for CLI
    /// callers, and the app (`--handoff`) restarts it as another build.
    fn matches(&self, status: &Value) -> bool {
        if status.get("session_socket").is_none() && status.get("server_config").is_none() {
            return true;
        }
        status["session_socket"] == json!(self.session_socket)
            && status.get("credential_socket").unwrap_or(&Value::Null)
                == &json!(self.credential_socket)
            && status["server_config"]["path"] == json!(self.server_config)
            && status["server_config"]["sha256"] == json!(self.server_config_sha256)
    }
}

/// The answer to `link.status`.
pub(super) fn status_line(
    state: &LinkState,
    config: &LinkConfig,
    socket: &Path,
    pid: u32,
    udp: &str,
    served: &Served,
    public_key: &[u8; 32],
) -> Value {
    let mut line = json!({
        "ok": true,
        "pid": pid,
        "socket": socket,
        "state_dir": state.dir(),
        "install": config.install,
        "port": config.port,
        "udp": udp,
        "build": build(),
        "public_key": STANDARD.encode(public_key),
        "identity_source": if config.server_identity.is_some() { "server_pairing" } else { "local" },
    });
    if let (Some(line), Value::Object(extra)) = (line.as_object_mut(), served.json()) {
        line.extend(extra);
    }
    line
}

/// The live link of `state`: its registration only when the registered
/// socket is this state directory's own socket, so a link of another state
/// folder that shares the registration folder is never reported or stopped.
pub(super) fn live(state: &LinkState) -> Option<registration::Registration> {
    registration::read_live(&state.registration_dir()).filter(|live| owns(state, &live.socket))
}

/// Whether `socket` is `state`'s own link socket. The socket's name comes
/// from the state directory (`link-<12 hex>.sock`); its folder comes from
/// the runtime base (`TMPDIR`) of the process that started the link, which
/// a CLI caller may not share with the app, so only the name is compared,
/// and the folder must be this user's private folder (a real folder, owned
/// by this user, that no one else may open): a registration that names a
/// socket in an open or foreign folder is not used. `read_live` has
/// already checked that the registered pid serves it.
fn owns(state: &LinkState, socket: &Path) -> bool {
    socket.file_name().is_some()
        && socket.file_name() == state.socket_path().file_name()
        && socket.parent().is_some_and(|folder| super::state::check_socket_dir(folder).is_ok())
}

/// `<state>/link.ensure.lock`, held by `ensure` and `stop` while they run,
/// so two of them never init, start or stop the same link at once. (`serve`
/// holds `link.lock` for its lifetime; one file would deadlock `ensure`,
/// which waits for the `serve` it started while it holds its lock.)
pub(super) fn ensure_lock(state: &LinkState) -> anyhow::Result<std::fs::File> {
    let file = super::state::open_lock(&state.dir().join("link.ensure.lock"))?;
    // flock has no timed wait: a helper thread takes the lock (blocking)
    // and hands the file over; this waits for that event with a deadline.
    // A lock the helper gets after the deadline is released at once: its
    // send fails and the file drops.
    let (sender, receiver) = std::sync::mpsc::sync_channel(1);
    std::thread::Builder::new().name("cmux-link-lock".into()).spawn(move || {
        // SAFETY: flock on a descriptor this thread owns.
        let locked =
            unsafe { libc::flock(std::os::fd::AsRawFd::as_raw_fd(&file), libc::LOCK_EX) } == 0;
        let answer = if locked { Ok(file) } else { Err(std::io::Error::last_os_error()) };
        let _ = sender.send(answer);
    })?;
    match receiver.recv_timeout(LOCK_BUDGET) {
        Ok(Ok(file)) => Ok(file),
        Ok(Err(error)) => Err(error).context("lock the link state directory"),
        Err(_) => bail!(
            "lock_timeout: another cmux link ensure or stop of {} still runs",
            state.dir().display()
        ),
    }
}

/// `link.status` of the link at `socket`, or None when it did not answer.
pub(super) fn query_status(socket: &Path) -> Option<Value> {
    let mut stream = std::os::unix::net::UnixStream::connect(socket).ok()?;
    stream.set_read_timeout(Some(STATUS_BUDGET)).ok()?;
    stream.set_write_timeout(Some(STATUS_BUDGET)).ok()?;
    stream.write_all(b"{\"op\":\"link.status\"}\n").ok()?;
    let mut line = String::new();
    BufReader::new(stream.take(64 * 1024)).read_line(&mut line).ok()?;
    let value: Value = serde_json::from_str(line.trim()).ok()?;
    (value["ok"] == json!(true)).then_some(value)
}

/// An enrolled link must prove the key actually loaded by its running mesh.
/// Older links without the proof cannot be silently reused as that identity.
pub(super) fn matches_enrollment(state: &LinkState, status: &Value) -> anyhow::Result<bool> {
    let config = state.config()?;
    if config.server_identity.is_none() {
        return Ok(true);
    }
    let public = super::state::public_key(&*state.private_key()?);
    Ok(status["identity_source"] == "server_pairing"
        && status["install"] == config.install
        && status["public_key"] == STANDARD.encode(public))
}

/// Runs `init` when the state directory has none; otherwise checks
/// `--install` and `--port` against the config. With `handoff` (the app,
/// which owns this link), another install or port replaces the config: the
/// running link stops; the old install's WireGuard key and paired peers are
/// archived under its name (`private.key.<install>`, `peers.<install>.json`),
/// and the new install gets its own archived pair back, or a new key and no
/// peers (it may be another signed-in person); true when a running link was
/// stopped.
fn init_or_check(state: &LinkState, flags: &Flags, handoff: bool) -> anyhow::Result<bool> {
    // A bad id stops here, before any link is stopped or a file is moved
    // (it would name archive files).
    if let Some(install) = flags.get("--install")
        && !cmux_link::stamp::valid_id(install)
    {
        bail!("invalid_install: {install:?} is not an install id");
    }
    let port = match flags.get("--port") {
        Some(text) => Some(text.parse::<u16>().map_err(|_| anyhow!("--port needs a UDP port"))?),
        None => None,
    };
    if !state.has_config() {
        let install = flags
            .get("--install")
            .ok_or_else(|| anyhow!("this state directory has no link yet: give --install ID"))?;
        // An install that comes back gets its own archived key and peers.
        state.restore_install(install)?;
        state.init(&LinkConfig {
            install: install.clone(),
            port: port.unwrap_or(DEFAULT_PORT),
            server_identity: None,
        })?;
        return Ok(false);
    }
    let config = state.config()?;
    if config.server_identity.is_some() {
        let _ = state.private_key()?;
        if flags.get("--install").is_some_and(|install| install != &config.install) {
            bail!("server_link.identity_conflict");
        }
    }
    let install = flags.get("--install").filter(|install| **install != config.install);
    let other_port = port.filter(|port| *port != config.port);
    if install.is_none() && other_port.is_none() {
        return Ok(false);
    }
    if !handoff {
        if install.is_some() {
            bail!("install_mismatch: this link belongs to install {}", config.install);
        }
        bail!("port_mismatch: this link uses UDP port {}", config.port);
    }
    let stopped = stop_live(state)?;
    let fresh = LinkConfig {
        install: install.cloned().unwrap_or_else(|| config.install.clone()),
        port: other_port.unwrap_or(config.port),
        server_identity: config.server_identity.clone(),
    };
    if install.is_some() {
        // Nothing is deleted: the old install's key and peers are kept
        // under its name, and an install that comes back gets its own.
        state.switch_install(&config.install, &fresh.install)?;
    }
    state.init(&fresh)?;
    Ok(stopped)
}

pub(super) fn run_ensure(flags: &Flags, handoff: bool) -> anyhow::Result<()> {
    let state = super::state(flags)?;
    let _lock = ensure_lock(&state)?;
    let mut restarted = init_or_check(&state, flags, handoff)?;
    let wanted = Served::wanted(flags)?;
    if let Some(live) = live(&state) {
        let status = query_status(&live.socket);
        let same_build = status.as_ref().is_some_and(|s| s["build"] == json!(build()));
        let same_served = status.as_ref().is_some_and(|s| wanted.matches(s));
        let same_identity = match status.as_ref() {
            Some(status) => matches_enrollment(&state, status)?,
            None => state.config()?.server_identity.is_none(),
        };
        if !same_identity && !handoff {
            bail!("server_link.identity_mismatch");
        }
        if status.is_some() && !same_served && !handoff {
            bail!(
                "config_mismatch: the running link serves another session socket or server \
                 config; stop it first"
            );
        }
        if (same_build && same_served && same_identity) || !handoff {
            let mut out = json!({"status": "running", "pid": live.pid, "socket": live.socket});
            if let Some(status) = status {
                out.set("build", status["build"].clone());
                out.set("udp", status["udp"].clone());
            }
            print_json(&out);
            return Ok(());
        }
        stop_live(&state)?;
        restarted = true;
    }
    match start(&state, flags)? {
        Some(ready) => {
            print_json(&json!({
                "status": if restarted { "restarted" } else { "started" },
                "pid": ready["pid"],
                "socket": ready["socket"],
                "udp": ready["udp"],
                "build": build(),
            }));
            Ok(())
        }
        // The link exited before it was ready: another `ensure` may have
        // won the socket, so the registration decides.
        None => match live(&state) {
            Some(live) => {
                if state.config()?.server_identity.is_some()
                    && !query_status(&live.socket)
                        .map(|status| matches_enrollment(&state, &status))
                        .transpose()?
                        .unwrap_or(false)
                {
                    bail!("server_link.identity_mismatch");
                }
                print_json(&json!({"status": "running", "pid": live.pid, "socket": live.socket}));
                Ok(())
            }
            None => Err(anyhow!("the link did not start; see {}", state.log_path().display())),
        },
    }
}

/// Starts `cmux link serve` for `state` in its own session, its output in
/// the state directory's `link.log`, and returns its ready line (None when
/// it exited first).
fn start(state: &LinkState, flags: &Flags) -> anyhow::Result<Option<Value>> {
    use std::os::unix::fs::OpenOptionsExt as _;
    use std::os::unix::process::CommandExt as _;
    let log = std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .mode(0o600)
        .open(state.log_path())
        .with_context(|| format!("open {}", state.log_path().display()))?;
    let log_err = log.try_clone()?;
    let mut fds = [0 as RawFd; 2];
    // SAFETY: fds has room for the two descriptors pipe writes.
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return Err(std::io::Error::last_os_error()).context("pipe for the link's ready line");
    }
    let (read_fd, write_fd) = (fds[0], fds[1]);
    // SAFETY: both descriptors were just created and are owned here.
    let (reader, writer) =
        unsafe { (std::fs::File::from_raw_fd(read_fd), std::fs::File::from_raw_fd(write_fd)) };
    // Neither end leaks into another child; pre_exec opens the write end
    // for the link only.
    // SAFETY: F_SETFD on descriptors this process owns.
    unsafe {
        libc::fcntl(read_fd, libc::F_SETFD, libc::FD_CLOEXEC);
        libc::fcntl(write_fd, libc::F_SETFD, libc::FD_CLOEXEC);
    }
    let mut command = std::process::Command::new(std::env::current_exe()?);
    command.args(["link", "serve", "--state-dir"]).arg(state.dir());
    for name in ["--session-socket", "--server-config", "--credential-socket"] {
        if let Some(value) = flags.get(name) {
            command.arg(name).arg(value);
        }
    }
    command
        .arg("--ready-fd")
        .arg(write_fd.to_string())
        .stdin(std::process::Stdio::null())
        .stdout(log)
        .stderr(log_err);
    // SAFETY: setsid and fcntl are async-signal-safe.
    unsafe {
        command.pre_exec(move || {
            // Its own session, so the link outlives the caller.
            libc::setsid();
            libc::fcntl(write_fd, libc::F_SETFD, 0);
            Ok(())
        });
    }
    command.spawn().context("start cmux link serve")?;
    // Close this process's copy so end of file means the link closed it.
    drop(writer);
    let (sender, receiver) = std::sync::mpsc::sync_channel(1);
    std::thread::Builder::new().name("cmux-link-ready".into()).spawn(move || {
        let mut line = String::new();
        let read = BufReader::new(reader.take(64 * 1024)).read_line(&mut line);
        let _ = sender.send(read.ok().filter(|n| *n > 0).map(|_| line));
    })?;
    let line = receiver.recv_timeout(START_BUDGET).map_err(|_| {
        anyhow!(
            "the link was not ready within {START_BUDGET:?}; see {}",
            state.log_path().display()
        )
    })?;
    Ok(line.and_then(|line| serde_json::from_str(line.trim()).ok()))
}

/// Stops the live link of `state` and waits until its process is gone:
/// true when one ran. A link that does not end within [`STOP_BUDGET`] is an
/// error (`stop_timeout`), never a stopped or a running link.
fn stop_live(state: &LinkState) -> anyhow::Result<bool> {
    let Some((live, mut stream)) = registration::connect_live(&state.registration_dir())
        .filter(|(live, _)| owns(state, &live.socket))
    else {
        return Ok(false);
    };
    let deadline = std::time::Instant::now() + STOP_BUDGET;
    let pid = libc::pid_t::try_from(live.pid).map_err(|_| anyhow!("bad registered pid"))?;
    // SAFETY: kill with a pid this connection's peer credentials named.
    if unsafe { libc::kill(pid, libc::SIGTERM) } != 0 {
        return Err(std::io::Error::last_os_error()).context("signal the link");
    }
    // The link ends this connection when it stops serving, after it removed
    // its registration; end of file is the signal, with a deadline.
    stream.set_read_timeout(Some(STOP_BUDGET))?;
    let mut sink = [0u8; 256];
    loop {
        match stream.read(&mut sink) {
            Ok(0) => break,
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                bail!("stop_timeout: link {} did not stop within {STOP_BUDGET:?}", live.pid)
            }
            Err(_) => break,
        }
    }
    // The connection ended; the process must be gone too before anything
    // else runs (an exit event, not a guess).
    let left = deadline.saturating_duration_since(std::time::Instant::now());
    if !super::process_exit::wait_exit(pid, left)? {
        bail!("stop_timeout: link {} did not exit within {STOP_BUDGET:?}", live.pid);
    }
    Ok(true)
}

/// `link archive --state-dir D`: after a sign-out, the install's key and
/// peers go into its archive and the config goes. Refused while the link
/// of D runs (stop it first).
pub(super) fn run_archive(flags: &Flags) -> anyhow::Result<()> {
    let state = super::state(flags)?;
    let _lock = ensure_lock(&state)?;
    if live(&state).is_some() {
        bail!("link_running: stop the link before archiving its install");
    }
    if !state.has_config() {
        print_json(&json!({"ok": true, "archived": false}));
        return Ok(());
    }
    let install = state.config()?.install;
    state.archive_install(&install)?;
    print_json(&json!({"ok": true, "archived": true, "install": install}));
    Ok(())
}

pub(super) fn run_stop(flags: &Flags) -> anyhow::Result<()> {
    let state = super::state(flags)?;
    let _lock = ensure_lock(&state)?;
    let stopped = stop_live(&state)?;
    print_json(&json!({"ok": true, "stopped": stopped}));
    Ok(())
}

pub(super) fn run_status(flags: &Flags) -> anyhow::Result<()> {
    let state = super::state(flags)?;
    let Some(live) = live(&state) else {
        print_json(&json!({"running": false}));
        return Ok(());
    };
    let mut out = query_status(&live.socket)
        .unwrap_or_else(|| json!({"pid": live.pid, "socket": live.socket}));
    out.set("running", json!(true));
    if let Some(object) = out.as_object_mut() {
        object.remove("ok");
    }
    print_json(&out);
    Ok(())
}
