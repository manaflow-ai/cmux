//! The share host on a joined Linux machine (design D11; Leo, 2026-11-16: "if you've connected to
//! a headlessly running mini why... would it need anything?"). There the host is `cmux-rd
//! linux-host` (crate cmux-rd-host), not this daemon: at its start on a joined machine (the join
//! line restarts it once the join is stored) the daemon runs `cmux-rd linux-host enable
//! --non-interactive --hub <the join's device hub>` with `ACPMUX_HOME` set to its own home, so
//! cmux-rd signs the machine in with this machine's credential, installs its systemd user unit
//! and starts it. The unit then keeps the host signed in and renews it hourly with the same
//! credential. Nobody at the machine does anything.
//!
//! - cmux-rd is `~/.local/bin/cmux-rd`, the path the host's unit runs
//!   (`ExecStart=%h/.local/bin/cmux-rd linux-host run`) and where the join puts its binaries; no
//!   other place is looked at, so the binary the daemon sets up is the one the unit runs.
//! - The enable runs once per join: a host unit already running for this join (the record in
//!   [`MARK`]) is left alone, so a daemon restart or upgrade never cuts a live share. A new
//!   join (another machine id or credential generation) runs it again.
//! - It runs in the background, at most [`ENABLE_WAIT`], and never fails the daemon: one log
//!   line says how it went, and `acpmux share-host status` says it too.

use super::NotRunning;
use cmux_hub_host::identity;
use serde_json::{Value, json};
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::time::Duration;

/// How long the enable may take: cmux-rd leaves the desktop portal's dialog up for a minute at
/// most, and signs in, registers and installs the unit after it.
pub(crate) const ENABLE_WAIT: Duration = Duration::from_secs(180);
/// The host's systemd user unit (cmux-rd-host's `systemd/cmux-screen-host.service`).
pub(crate) const HOST_UNIT: &str = "cmux-screen-host.service";
/// In the share host's folder: the join the running host unit was set up for.
pub(crate) const MARK: &str = "linux-host.json";
/// The line `enable --non-interactive` prints when it could not sign the machine in.
const NOT_INSTALLED: &str = "not_installed:";

/// Where cmux-rd is: `<user home>/.local/bin/cmux-rd`, the host unit's own path.
pub(crate) fn cmux_rd_path(user_home: &Path) -> PathBuf {
    user_home.join(".local/bin/cmux-rd")
}

/// Whether `path` is a file this user may run.
pub(crate) fn executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

/// The user manager's variables `systemctl --user` needs, for a daemon started without a login
/// session's (`sudo -u`, a service): the runtime directory `/run/user/<uid>` and its session
/// bus, as pam_systemd sets them, when they exist and the daemon has none of its own.
pub(crate) fn user_manager_env(
    uid: u32,
    runtime_dir: Option<OsString>,
    bus: Option<OsString>,
    exists: impl Fn(&Path) -> bool,
) -> Vec<(&'static str, OsString)> {
    let mut env = Vec::new();
    let runtime = match runtime_dir.filter(|v| !v.is_empty()) {
        Some(dir) => PathBuf::from(dir),
        None => {
            let dir = PathBuf::from(format!("/run/user/{uid}"));
            if !exists(&dir) {
                return env;
            }
            env.push(("XDG_RUNTIME_DIR", dir.clone().into_os_string()));
            dir
        }
    };
    if bus.filter(|v| !v.is_empty()).is_none() {
        let socket = runtime.join("bus");
        if exists(&socket) {
            let mut address = OsString::from("unix:path=");
            address.push(socket.as_os_str());
            env.push(("DBUS_SESSION_BUS_ADDRESS", address));
        }
    }
    env
}

/// The arguments of the enable for the join at device hub `hub`.
pub(crate) fn enable_args(hub: &str) -> [&str; 5] {
    ["linux-host", "enable", "--non-interactive", "--hub", hub]
}

/// How an enable ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Outcome {
    /// Signed in and the host unit installed and started: cmux-rd's own line.
    SetUp(String),
    /// cmux-rd could not sign the machine in (its `not_installed:` line, without the prefix).
    NotInstalled(String),
    /// It exited with an error, or did not start: its last line.
    Failed(String),
    /// Cancelled (a leave, or the daemon stopping) and stopped with everything it started.
    Cancelled,
    /// It did not finish within its wait and was stopped.
    TimedOut,
}

impl Outcome {
    /// `share-host status`'s state.
    pub(crate) fn state(&self) -> &'static str {
        match self {
            Self::SetUp(_) => "set_up",
            Self::NotInstalled(_) => "not_installed",
            Self::Failed(_) => "enable_failed",
            Self::TimedOut => "timed_out",
            Self::Cancelled => "cancelled",
        }
    }

    pub(crate) fn detail(&self) -> String {
        match self {
            Self::SetUp(line) | Self::NotInstalled(line) | Self::Failed(line) => line.clone(),
            Self::TimedOut => format!(
                "cmux-rd linux-host enable did not finish within {} s",
                ENABLE_WAIT.as_secs()
            ),
            Self::Cancelled => {
                "cmux-rd linux-host enable was cancelled: the join changed or the daemon stopped"
                    .into()
            }
        }
    }
}

/// What the daemon does once an enable ended ([`after_enable`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct After {
    /// Record the join as set up ([`MARK`]).
    pub(crate) save_mark: bool,
    /// Stop the host unit the enable may have started.
    pub(crate) stop_host: bool,
}

/// After `outcome`, cancelled or not, with the join it ran for still `current` or not.
/// Only an enable that finished for the join still current, uncancelled, keeps its host: any
/// other may have started the unit, for a join that is gone or one the daemon does not record
/// as set up, so the unit is stopped (review of #45369).
pub(crate) fn after_enable(outcome: &Outcome, cancelled: bool, current: bool) -> After {
    let finished = matches!(outcome, Outcome::SetUp(_));
    let superseded = cancelled || !current || matches!(outcome, Outcome::Cancelled);
    let kept = finished && !superseded;
    // Any enable that did not finish (failed, timed out, not installed, cancelled) may have
    // started the unit before it ended: its host is stopped, never left running unmarked.
    After { save_mark: kept, stop_host: !kept }
}

/// One line of cmux-rd's output, made plain and short for a log line.
fn plain(line: &str) -> String {
    let line: String = line.chars().filter(|c| !c.is_control()).take(300).collect();
    line.trim().to_owned()
}

/// The outcome of an enable that exited (`success`) with `stdout` and `stderr`.
pub(crate) fn outcome(success: bool, stdout: &str, stderr: &str) -> Outcome {
    if let Some(rest) = stdout.lines().find_map(|l| l.trim().strip_prefix(NOT_INSTALLED)) {
        return Outcome::NotInstalled(plain(rest));
    }
    let last = |text: &str| text.lines().map(plain).rfind(|l| !l.is_empty());
    if success {
        let line = stdout.lines().map(plain).rfind(|l| l.starts_with("This desktop is shared"));
        return Outcome::SetUp(line.or_else(|| last(stdout)).unwrap_or_default());
    }
    Outcome::Failed(
        last(stderr).or_else(|| last(stdout)).unwrap_or_else(|| "it exited with an error".into()),
    )
}

/// Reads `pipe` to its end (at most 64 KiB) on a thread of its own; the text comes on the
/// returned channel.
fn read_pipe(pipe: Option<impl std::io::Read + Send + 'static>) -> mpsc::Receiver<String> {
    let (send, text) = mpsc::channel();
    let Some(pipe) = pipe else {
        let _ = send.send(String::new());
        return text;
    };
    let reader =
        std::thread::Builder::new().name("share-host-enable-pipe".into()).spawn(move || {
            use std::io::Read;
            let mut bytes = Vec::new();
            let _ = pipe.take(64 * 1024).read_to_end(&mut bytes);
            let _ = send.send(String::from_utf8_lossy(&bytes).into_owned());
        });
    if let Err(e) = reader {
        tracing::warn!("{}: the enable's output is not read: {e}", super::LOG);
    }
    text
}

/// Runs cmux-rd's enable and waits for it (blocking): `rd` with `args`, `ACPMUX_HOME` =
/// `acpmux_home` and `env` added to the daemon's own, as the leader of its own process group.
/// Past `wait` the whole group is ended ([`cmux_process::Child`]'s drop).
pub(crate) fn run_enable(
    rd: &Path,
    args: &[&str],
    acpmux_home: &Path,
    env: &[(&'static str, OsString)],
    wait: Duration,
    cancel: &AtomicBool,
) -> Outcome {
    let spawned = cmux_process::Command::new(rd)
        .args(args)
        .env("ACPMUX_HOME", acpmux_home)
        .envs(env.iter().map(|(k, v)| (*k, v)))
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::piped())
        .stderr(cmux_process::Stdio::piped())
        .process_group(0)
        .spawn();
    let mut child = match spawned {
        Ok(child) => child,
        Err(e) => return Outcome::Failed(format!("{} did not start: {e}", rd.display())),
    };
    let stdout = read_pipe(child.stdout.take());
    let stderr = read_pipe(child.stderr.take());
    // Waited in short slices so a cancel ends it at once, not at `wait`.
    let deadline = std::time::Instant::now() + wait;
    loop {
        if cancel.load(Ordering::SeqCst) {
            drop(child);
            return Outcome::Cancelled;
        }
        let left = deadline.saturating_duration_since(std::time::Instant::now());
        if left.is_zero() {
            drop(child);
            return Outcome::TimedOut;
        }
        match child.wait_timeout(left.min(CANCEL_CHECK)) {
            Ok(Some(status)) => {
                // A process it left holding a pipe does not hold up the answer.
                let text = |rx: mpsc::Receiver<String>| {
                    rx.recv_timeout(Duration::from_secs(5)).unwrap_or_default()
                };
                return outcome(status.success(), &text(stdout), &text(stderr));
            }
            Ok(None) => {}
            Err(e) => return Outcome::Failed(format!("waiting for cmux-rd: {e}")),
        }
    }
}

/// How often a running enable looks at its cancel flag.
const CANCEL_CHECK: Duration = Duration::from_millis(200);

/// The join a host was set up for: the machine id and its credential's generation.
pub(crate) fn mark_of(credential: &crate::machine_record::MachineCredential) -> Value {
    json!({"machineId": credential.machine_id, "credentialGeneration": credential.credential_generation})
}

/// Whether the host was set up for `mark` (the record in `folder`).
pub(crate) fn marked(folder: &Path, mark: &Value) -> bool {
    identity::read_private(&folder.join(MARK))
        .ok()
        .flatten()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .is_some_and(|saved| &saved == mark)
}

pub(crate) fn save_mark(folder: &Path, mark: &Value) -> cmux_hub_host::Res<()> {
    identity::private_dir(folder)?;
    identity::write_private(&folder.join(MARK), mark.to_string().as_bytes())
}

/// `acpmux machine leave` and a superseded enable: stops and disables the screen host the join
/// set up (`systemctl --user disable --now`, blocking, 10 s at most), then checks by its pid
/// file's lock that no host runs, the unit's or one started by hand, killing one that did not
/// stop with its process group (review F1 of #45369). cmux-rd itself refuses to start again
/// with the join's credential gone, and a running one exits once it is. Ok only once no host
/// runs; else what may still run and how to stop it.
pub(crate) fn stop_host() -> Result<(), String> {
    use cmux_hub_host::host_process;
    // SAFETY: getuid has no preconditions and cannot fail.
    let uid = unsafe { libc::getuid() };
    let env = user_manager_env(
        uid,
        std::env::var_os("XDG_RUNTIME_DIR"),
        std::env::var_os("DBUS_SESSION_BUS_ADDRESS"),
        |p| p.exists(),
    );
    let spawned = cmux_process::Command::new("systemctl")
        .args(["--user", "disable", "--now", HOST_UNIT])
        .envs(env.iter().map(|(k, v)| (*k, v)))
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::null())
        .stderr(cmux_process::Stdio::null())
        .spawn();
    let disabled = spawned.is_ok_and(|mut child| {
        matches!(child.wait_timeout(Duration::from_secs(10)), Ok(Some(s)) if s.success())
    });
    let gone = match identity::config_dir() {
        Ok(dir) => host_process::ensure_gone(&dir, host_process::STOP_WAIT),
        Err(_) => Err(None),
    };
    gone.map_err(|pid| still_running(pid, disabled))
}

/// What [`stop_host`] says when the host, `pid` when known, may still run.
pub(crate) fn still_running(pid: Option<u32>, disabled: bool) -> String {
    format!(
        "the screen host may still be running ({}){}; stop it with: {}",
        pid.map_or("its pid is unknown: a host of an older build records none".into(), |pid| {
            format!("pid {pid}")
        }),
        if disabled { "" } else { "; systemctl --user disable --now did not finish" },
        pid.map_or(format!("systemctl --user kill --signal=KILL {HOST_UNIT}"), |pid| {
            format!("kill -KILL {pid}")
        })
    )
}

/// Whether cmux-rd's own record says it signed in for the join `mark` (its `joined.json`):
/// a unit that runs is that join's only when it says so too.
pub(crate) fn rd_signed_in_for(rd_config: &Path, mark: &Value) -> bool {
    identity::read_private(&rd_config.join("joined.json"))
        .ok()
        .flatten()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .is_some_and(|joined| {
            joined.get("machine_id") == mark.get("machineId")
                && joined.get("credential_generation") == mark.get("credentialGeneration")
        })
}

/// Whether the host unit runs (`systemctl --user is-active`), asked with `env` (blocking, 10 s
/// at most).
fn host_active(env: &[(&'static str, OsString)]) -> bool {
    let spawned = cmux_process::Command::new("systemctl")
        .args(["--user", "is-active", "--quiet", HOST_UNIT])
        .envs(env.iter().map(|(k, v)| (*k, v)))
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::null())
        .stderr(cmux_process::Stdio::null())
        .spawn();
    spawned.is_ok_and(|mut child| {
        matches!(child.wait_timeout(Duration::from_secs(10)), Ok(Some(s)) if s.success())
    })
}

/// `share-host status` for this machine's cmux-rd host.
pub(crate) fn status_json(state: &str, detail: &str, rd: &Path, hub: &str) -> Value {
    json!({
        "schema": super::state::SCHEMA,
        "running": matches!(state, "set_up" | "already_set_up"),
        "state": state,
        "detail": detail,
        "host": "cmux-rd",
        "cmuxRd": rd,
        "hub": hub,
        "unit": HOST_UNIT,
    })
}

/// Sets up this joined Linux machine's cmux-rd host from the daemon's start, as a task of
/// `scope` (its blocking work on a thread of its own): nothing when the machine is not joined
/// (or its record was copied or revoked), or when cmux-rd is not installed; else the enable.
#[cfg_attr(
    not(target_os = "linux"),
    allow(
        dead_code,
        reason = "the daemon starts it on Linux; elsewhere it is compiled and tested"
    )
)]
pub(crate) fn start(scope: &cmux_scope::Scope) {
    let home = crate::config::home();
    let (credential, hub) = match super::joined() {
        Ok(joined) => joined,
        Err(why) => return not_running(why),
    };
    let Some(user_home) = dirs::home_dir() else {
        return not_running(NotRunning::new(
            "not_installed",
            "no home directory to find cmux-rd in",
        ));
    };
    let rd = cmux_rd_path(&user_home);
    if !executable(&rd) {
        tracing::info!("{}: not running: cmux-rd is not installed ({})", super::LOG, rd.display());
        super::state::not_running(NotRunning::new(
            "not_installed",
            &format!("cmux-rd is not installed ({})", rd.display()),
        ));
        return;
    }
    let folder = super::dir(&home);
    let mark = mark_of(&credential);
    // SAFETY: getuid has no preconditions and cannot fail.
    let uid = unsafe { libc::getuid() };
    let env = user_manager_env(
        uid,
        std::env::var_os("XDG_RUNTIME_DIR"),
        std::env::var_os("DBUS_SESSION_BUS_ADDRESS"),
        |p| p.exists(),
    );
    super::state::linux(status_json("setting_up", "cmux-rd linux-host enable runs", &rd, &hub));
    scope.spawn_named("share-host-linux", async move {
        // The thread outlives an aborted task: dropping this cancels its enable (stopped with
        // its process group), and nothing it set up is kept (review F2 of #45369).
        struct CancelOnDrop(Arc<AtomicBool>);
        impl Drop for CancelOnDrop {
            fn drop(&mut self) {
                self.0.store(true, Ordering::SeqCst);
            }
        }
        let cancel = Arc::new(AtomicBool::new(false));
        let _cancel_on_drop = CancelOnDrop(cancel.clone());
        let (done, ended) = tokio::sync::oneshot::channel::<()>();
        let spawned =
            std::thread::Builder::new().name("share-host-linux".into()).spawn(move || {
                set_up(&home, &folder, &mark, &rd, &hub, &env, &cancel);
                let _ = done.send(());
            });
        match spawned {
            Ok(_) => {
                let _ = ended.await;
            }
            Err(e) => tracing::warn!("{}: cmux-rd's enable did not start: {e}", super::LOG),
        }
    });
}

/// The enable, unless the host unit already runs for this join; what it did goes to the log and
/// the status.
fn set_up(
    home: &Path,
    folder: &Path,
    mark: &Value,
    rd: &Path,
    hub: &str,
    env: &[(&'static str, OsString)],
    cancel: &AtomicBool,
) {
    // A unit that runs is left alone only when cmux-rd's own record says it is this join's: a
    // person's sign-in that replaced it is set up over.
    let rd_signed_in = identity::config_dir().is_ok_and(|c| rd_signed_in_for(&c, mark));
    if marked(folder, mark) && rd_signed_in && host_active(env) {
        tracing::info!("{}: cmux-rd's host already runs for this join", super::LOG);
        let detail = format!("{HOST_UNIT} runs for this join");
        super::state::linux(status_json("already_set_up", &detail, rd, hub));
        return;
    }
    let outcome = run_enable(rd, &enable_args(hub), home, env, ENABLE_WAIT, cancel);
    // The join it ran for, read again now: a leave or a new join may have come meanwhile.
    let current = super::joined().is_ok_and(|(credential, _)| &mark_of(&credential) == mark);
    let after = after_enable(&outcome, cancel.load(Ordering::SeqCst), current);
    if after.save_mark
        && let Err(e) = save_mark(folder, mark)
    {
        tracing::warn!("{}: {}: {e}", super::LOG, folder.join(MARK).display());
    }
    if after.stop_host {
        match stop_host() {
            Ok(()) => tracing::info!(
                "{}: the enable's join is gone or it was cancelled; the host is stopped",
                super::LOG
            ),
            Err(e) => tracing::warn!(
                "{}: the enable's join is gone or it was cancelled, but {e}",
                super::LOG
            ),
        }
    }
    match &outcome {
        Outcome::SetUp(line) => tracing::info!("{}: cmux-rd's host is set up: {line}", super::LOG),
        other => tracing::warn!(
            "{}: cmux-rd's host is not set up ({}): {}",
            super::LOG,
            other.state(),
            other.detail()
        ),
    }
    super::state::linux(status_json(outcome.state(), &outcome.detail(), rd, hub));
}

fn not_running(why: NotRunning) {
    tracing::info!("{}: not running: {why}", super::LOG);
    super::state::not_running(why);
}
