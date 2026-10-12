//! `cmux link ensure`, `cmux link stop` and `cmux link status` (cx-rtipa
//! slice S1): the app starts and stops the per-user link on demand, the way
//! it ensures the session daemon (`cmux-tui server ensure`) and acpmux. A
//! link is found only through its registration (`link.json` in the parent
//! of its state directory); its socket name comes from its state directory
//! (`state::socket_path_for`), so a tagged DEV app's link and the release
//! app's link never share a socket, a registration or a state directory.
//!
//! - `ensure --state-dir D [--install ID] [--port P] [--session-socket S]
//!   [--server-config F] [--handoff]`: runs `init` first when D has no
//!   config (then `--install` is required; `--port 0` binds any free UDP
//!   port), returns the live link when one runs, else starts `cmux link
//!   serve` in its own session (it survives the caller) and waits for its
//!   ready line. With `--handoff`, a live link of another build is stopped
//!   and replaced; without it, it is kept (a CLI of another build never
//!   flips the app's link). One JSON line on stdout: `{"status":"running"|
//!   "started"|"restarted", "pid", "socket", "build", ...}`.
//! - `stop --state-dir D`: signals the registered pid (only after a fresh
//!   connection proved that pid serves the registered socket) and waits for
//!   that connection to end, which the link does after it removed its
//!   registration. Never by name or pattern. `{"ok":true,"stopped":bool}`.
//! - `status --state-dir D`: `{"running":false}`, or `{"running":true}` with
//!   the link's own `link.status` answer.

use std::io::{BufRead as _, BufReader, Read as _, Write as _};
use std::os::fd::{FromRawFd as _, RawFd};
use std::path::Path;
use std::time::Duration;

use anyhow::{Context as _, anyhow, bail};
use cmux_link::registration;
use serde_json::{Value, json};

use super::state::{DEFAULT_PORT, LinkConfig, LinkState};
use super::{Flags, print_json};

/// How long `ensure` waits for a started link's ready line.
const START_BUDGET: Duration = Duration::from_secs(20);
/// How long `stop` waits for the link to end after the signal.
const STOP_BUDGET: Duration = Duration::from_secs(10);
/// How long a `link.status` read may take.
const STATUS_BUDGET: Duration = Duration::from_secs(3);

/// The build of this binary, which a link reports in `link.status`.
fn build() -> &'static str {
    cmux_remote::ssh_bootstrap::BUILD_IDENTITY
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

/// The answer to `link.status`.
pub(super) fn status_line(
    state: &LinkState,
    config: &LinkConfig,
    socket: &Path,
    pid: u32,
    udp: &str,
) -> Value {
    json!({
        "ok": true,
        "pid": pid,
        "socket": socket,
        "state_dir": state.dir(),
        "install": config.install,
        "port": config.port,
        "udp": udp,
        "build": build(),
    })
}

/// `link.status` of the link at `socket`, or None when it did not answer.
fn query_status(socket: &Path) -> Option<Value> {
    let mut stream = std::os::unix::net::UnixStream::connect(socket).ok()?;
    stream.set_read_timeout(Some(STATUS_BUDGET)).ok()?;
    stream.set_write_timeout(Some(STATUS_BUDGET)).ok()?;
    stream.write_all(b"{\"op\":\"link.status\"}\n").ok()?;
    let mut line = String::new();
    BufReader::new(stream.take(64 * 1024)).read_line(&mut line).ok()?;
    let value: Value = serde_json::from_str(line.trim()).ok()?;
    (value["ok"] == json!(true)).then_some(value)
}

fn init_or_check(state: &LinkState, flags: &Flags) -> anyhow::Result<()> {
    let port = match flags.get("--port") {
        Some(text) => Some(text.parse::<u16>().map_err(|_| anyhow!("--port needs a UDP port"))?),
        None => None,
    };
    if !state.has_config() {
        let install = flags
            .get("--install")
            .ok_or_else(|| anyhow!("this state directory has no link yet: give --install ID"))?;
        state.init(&LinkConfig { install: install.clone(), port: port.unwrap_or(DEFAULT_PORT) })?;
        return Ok(());
    }
    let config = state.config()?;
    if let Some(install) = flags.get("--install")
        && *install != config.install
    {
        bail!("install_mismatch: this link belongs to install {}", config.install);
    }
    if let Some(port) = port
        && port != config.port
    {
        bail!("port_mismatch: this link uses UDP port {}", config.port);
    }
    Ok(())
}

pub(super) fn run_ensure(flags: &Flags, handoff: bool) -> anyhow::Result<()> {
    let state = super::state(flags)?;
    init_or_check(&state, flags)?;
    let mut restarted = false;
    if let Some(live) = registration::read_live(&state.registration_dir()) {
        let status = query_status(&live.socket);
        let same_build = status.as_ref().is_some_and(|s| s["build"] == json!(build()));
        if same_build || !handoff {
            let mut out = json!({"status": "running", "pid": live.pid, "socket": live.socket});
            if let Some(status) = status {
                out["build"] = status["build"].clone();
                out["udp"] = status["udp"].clone();
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
        None => match registration::read_live(&state.registration_dir()) {
            Some(live) => {
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
    for name in ["--session-socket", "--server-config"] {
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

/// Stops the live link of `state`: true when one ran.
fn stop_live(state: &LinkState) -> anyhow::Result<bool> {
    let Some((live, mut stream)) = registration::connect_live(&state.registration_dir()) else {
        return Ok(false);
    };
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
            Ok(0) => return Ok(true),
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
            Err(_) => return Ok(true),
        }
    }
}

pub(super) fn run_stop(flags: &Flags) -> anyhow::Result<()> {
    let state = super::state(flags)?;
    let stopped = stop_live(&state)?;
    print_json(&json!({"ok": true, "stopped": stopped}));
    Ok(())
}

pub(super) fn run_status(flags: &Flags) -> anyhow::Result<()> {
    let state = super::state(flags)?;
    let Some(live) = registration::read_live(&state.registration_dir()) else {
        print_json(&json!({"running": false}));
        return Ok(());
    };
    let mut out = query_status(&live.socket)
        .unwrap_or_else(|| json!({"pid": live.pid, "socket": live.socket}));
    out["running"] = json!(true);
    if let Some(object) = out.as_object_mut() {
        object.remove("ok");
    }
    print_json(&out);
    Ok(())
}
