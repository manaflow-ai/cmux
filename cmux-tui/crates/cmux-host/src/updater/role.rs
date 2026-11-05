//! The `updater` role and the `cmux host update` verbs: the system half of
//! the self-update (see the module docs of [`super`]). Linux, root, the
//! image's system layout only.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::thread::JoinHandle;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_server_core::role::{HostEvent, Role, RoleContext, RoleError, StopContext};
use serde_json::{Value, json};

use super::channel::{self, CHANNEL_MAX_BYTES, CHANNEL_URL, CMUX_TUI, CMUX_TUI_HOOK};
use super::store::{self, STORE_DIR};
use super::{
    DOWNLOAD_DIR, Decision, Pending, Plan, clear_pending, decide, load_pending, load_state,
    off_reason, record_installed, record_rollback, save_pending, save_state,
};
use crate::config::Paths;
use crate::daemon_spec::{WORK_HOME, WORK_USER};

/// The first check after `cmux host run` starts (a boot or an update's restart).
const BOOT_DELAY: Duration = Duration::from_secs(30);
/// Every few minutes while the machine runs.
const INTERVAL: Duration = Duration::from_secs(300);
/// An update waiting for a turn to end looks again this soon.
const BUSY_RETRY: Duration = Duration::from_secs(60);
/// The new build has this long to serve after its restart: a session host
/// replays its journal before it listens (minutes for a large one).
const HEALTH_TIMEOUT: Duration = Duration::from_secs(10 * 60);
/// The previous build's guard runs this long after the flip, past the
/// health check, and rolls back an update that never proved itself.
const GUARD_AFTER_SECS: u64 = 20 * 60;
const GUARD_UNIT: &str = "cmux-self-update-guard";
const HOST_UNIT: &str = "cmux-host.service";
const ACPMUX_UNIT: &str = "acpmux.service";
const ACPMUX_UNIT_FILE: &str = "/home/cmux/.config/systemd/user/acpmux.service";
const CURRENT_ACPMUX: &str = "/opt/cmux/current/bin/acpmux";

fn log(line: &str) {
    eprintln!("cmux-host: updater: {line}");
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

enum Msg {
    Check,
    Stop,
}

struct Worker {
    tx: Sender<Msg>,
    thread: JoinHandle<()>,
    done: Receiver<()>,
}

/// The role `cmux host run` starts last on a bound Cloud machine.
pub struct UpdaterRole {
    paths: Paths,
    worker: Option<Worker>,
}

impl UpdaterRole {
    pub fn new(paths: Paths) -> Self {
        Self { paths, worker: None }
    }

    fn halt(&mut self, deadline: Instant) -> Result<(), RoleError> {
        let Some(worker) = self.worker.take() else { return Ok(()) };
        let _ = worker.tx.send(Msg::Stop);
        match worker.done.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
            Err(RecvTimeoutError::Timeout) => {
                // A download or a restart command is bounded; it ends on its own.
                Err(RoleError("updater did not stop by the deadline".to_owned()))
            }
            _ => {
                let _ = worker.thread.join();
                Ok(())
            }
        }
    }
}

impl Role for UpdaterRole {
    fn name(&self) -> &str {
        "updater"
    }

    fn start(&mut self, ctx: &RoleContext) -> Result<(), RoleError> {
        // A Cloud machine only: bound, the system root, the image's store.
        if ctx.instance_id.is_none() || !self.paths.is_system_root() || self.worker.is_some() {
            return Ok(());
        }
        if !self.paths.at(store::CURRENT_LINK).exists() {
            return Ok(());
        }
        let (tx, rx) = mpsc::channel();
        let (done_tx, done) = mpsc::channel::<()>();
        let paths = self.paths.clone();
        let thread = std::thread::Builder::new()
            .name("cmux-host-updater".to_owned())
            .spawn(move || {
                let _done = done_tx;
                run(&paths, &rx);
            })
            .map_err(|e| RoleError(e.to_string()))?;
        self.worker = Some(Worker { tx, thread, done });
        Ok(())
    }

    fn stop(&mut self, ctx: &StopContext) -> Result<(), RoleError> {
        self.halt(ctx.deadline)
    }

    fn on_event(&mut self, event: &HostEvent) -> Result<(), RoleError> {
        match event {
            HostEvent::Resumed | HostEvent::ChannelChanged => {
                if let Some(worker) = &self.worker {
                    let _ = worker.tx.send(Msg::Check);
                }
                Ok(())
            }
            HostEvent::Parked { deadline } | HostEvent::Shutdown { deadline } => {
                self.halt(*deadline)
            }
            _ => Ok(()),
        }
    }
}

/// Waits `d` or until a message: false when the role stops.
fn wait(rx: &Receiver<Msg>, d: Duration) -> bool {
    match rx.recv_timeout(d) {
        Ok(Msg::Check) | Err(RecvTimeoutError::Timeout) => true,
        Ok(Msg::Stop) | Err(RecvTimeoutError::Disconnected) => false,
    }
}

fn run(paths: &Paths, rx: &Receiver<Msg>) {
    if let Some(pending) = load_pending(paths)
        && !resolve(paths, &pending, rx)
    {
        return;
    }
    if !wait(rx, BOOT_DELAY) {
        return;
    }
    loop {
        let outcome = check(paths);
        let next = if matches!(outcome, Outcome::Busy(_)) { BUSY_RETRY } else { INTERVAL };
        if !wait(rx, next) {
            return;
        }
    }
}

/// What one check did.
#[derive(Debug)]
pub enum Outcome {
    Off(String),
    Current(String),
    Older,
    RolledBackBefore,
    Busy(Vec<String>),
    /// The flip happened; this process is about to be restarted.
    Updating(String),
    Failed(String),
}

impl Outcome {
    fn line(&self) -> String {
        match self {
            Outcome::Off(why) => format!("off: {why}"),
            Outcome::Current(commit) => format!("current ({commit})"),
            Outcome::Older => "the channel's build is older than the one applied here".to_owned(),
            Outcome::RolledBackBefore => "the channel's build was rolled back here".to_owned(),
            Outcome::Busy(names) => format!("waiting for idle: {}", names.join(", ")),
            Outcome::Updating(commit) => format!("updating to {commit}"),
            Outcome::Failed(why) => format!("failed: {why}"),
        }
    }

    fn json(&self) -> Value {
        let state = match self {
            Outcome::Off(_) => "off",
            Outcome::Current(_) => "current",
            Outcome::Older => "older",
            Outcome::RolledBackBefore => "rolled-back-before",
            Outcome::Busy(_) => "busy",
            Outcome::Updating(_) => "updating",
            Outcome::Failed(_) => "failed",
        };
        json!({"state": state, "detail": self.line()})
    }
}

/// One check; on an update this ends with `cmux-host.service` restarting.
pub fn check(paths: &Paths) -> Outcome {
    let outcome = check_inner(paths);
    let mut state = load_state(paths);
    let line = outcome.line();
    if state.last.as_deref() != Some(line.as_str()) {
        log(&line);
    }
    state.last = Some(line);
    state.last_at = now();
    let _ = save_state(paths, &state);
    outcome
}

fn check_inner(paths: &Paths) -> Outcome {
    if let Some(why) = off_reason(paths) {
        return Outcome::Off(why);
    }
    if load_pending(paths).is_some() {
        return Outcome::Failed("an update is waiting for its health check".to_owned());
    }
    let Some(target) = channel::local_target() else {
        return Outcome::Off(format!("no build for {}", std::env::consts::ARCH));
    };
    let body = match fetch(CHANNEL_URL, CHANNEL_MAX_BYTES as u64, None) {
        Ok(body) => body,
        Err(e) => return Outcome::Failed(format!("reading {CHANNEL_URL}: {e}")),
    };
    let payload = match channel::verify(&body, &channel::trusted_keys(), now()) {
        Ok(payload) => payload,
        Err(e) => return Outcome::Failed(format!("refusing {CHANNEL_URL}: {e}")),
    };
    let mut state = load_state(paths);
    let plan = match decide(paths, &state, &payload, target) {
        Ok(Decision::Update(plan)) => plan,
        Ok(Decision::Current) => return Outcome::Current(payload.commit),
        Ok(Decision::Older) => return Outcome::Older,
        Ok(Decision::RolledBack) => return Outcome::RolledBackBefore,
        Err(e) => return Outcome::Failed(e),
    };
    match busy_sessions() {
        Ok(busy) if busy.is_empty() => {}
        Ok(busy) => return Outcome::Busy(busy),
        Err(e) => return Outcome::Busy(vec![e]),
    }
    if let Err(e) = stage(paths, &plan) {
        return Outcome::Failed(e);
    }
    // The download took a while: look again right before anything moves.
    if let Some(why) = off_reason(paths) {
        return Outcome::Off(why);
    }
    match busy_sessions() {
        Ok(busy) if busy.is_empty() => {}
        Ok(busy) => return Outcome::Busy(busy),
        Err(e) => return Outcome::Busy(vec![e]),
    }
    if let Err(e) = store::build_profile(paths, plan.from, plan.to, &plan.replacements()) {
        return Outcome::Failed(format!("building profile {}: {e}", plan.to));
    }
    record_installed(&mut state, &plan);
    let _ = save_state(paths, &state);
    let pending = plan.pending(now());
    if let Err(e) = save_pending(paths, &pending) {
        return Outcome::Failed(format!("recording the update: {e}"));
    }
    if let Err(e) = arm_guard(&pending) {
        clear_pending(paths);
        return Outcome::Failed(format!("arming the guard: {e}"));
    }
    if let Err(e) = store::flip(paths, plan.to) {
        disarm_guard();
        clear_pending(paths);
        return Outcome::Failed(format!("flipping to profile {}: {e}", plan.to));
    }
    log(&format!(
        "profile {} -> {}: cmux-tui {} ({}); restarting the services",
        plan.from,
        plan.to,
        &plan.cmux_tui.sha256[..12],
        &plan.commit[..12]
    ));
    restart_after_flip(&store_binary(&plan.old_cmux_tui));
    Outcome::Updating(plan.commit)
}

fn store_binary(sha: &str) -> PathBuf {
    Path::new(STORE_DIR).join(sha).join(CMUX_TUI)
}

/// Downloads what the store lacks, each checked against the signed sha256 and size.
fn stage(paths: &Paths, plan: &Plan) -> Result<(), String> {
    let need: Vec<_> = [(&plan.cmux_tui, CMUX_TUI), (&plan.cmux_tui_hook, CMUX_TUI_HOOK)]
        .into_iter()
        .filter(|(bin, name)| !store::has_entry(paths, &bin.sha256, name))
        .collect();
    let total: u64 = need.iter().map(|(bin, _)| bin.size).sum();
    if let Some(free) = free_bytes(&paths.at(store::STORE_ROOT))
        && free < total.saturating_mul(2) + (256 << 20)
    {
        return Err(format!("{free} bytes free; the update needs {total} and room to spare"));
    }
    let dir = paths.at(DOWNLOAD_DIR);
    fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    for (bin, name) in need {
        let file = dir.join(format!("{}-{name}", bin.sha256));
        let _ = fs::remove_file(&file);
        fetch(&bin.url, bin.size, Some(&file))
            .map_err(|e| format!("downloading {}: {e}", bin.url))?;
        let size = fs::metadata(&file).map(|m| m.len()).unwrap_or(0);
        if size != bin.size {
            let _ = fs::remove_file(&file);
            return Err(format!("{} is {size} bytes, not the channel's {}", bin.url, bin.size));
        }
        if let Err(e) = store::add_entry(paths, &bin.sha256, name, &file) {
            let _ = fs::remove_file(&file);
            return Err(format!("{}: {e}", bin.url));
        }
    }
    Ok(())
}

fn free_bytes(path: &Path) -> Option<u64> {
    use std::os::unix::ffi::OsStrExt as _;
    let c = std::ffi::CString::new(path.as_os_str().as_bytes()).ok()?;
    // SAFETY: a valid C string and an out parameter of the right type.
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statvfs(c.as_ptr(), &mut st) } != 0 {
        return None;
    }
    Some(st.f_bavail as u64 * st.f_frsize as u64)
}

/// HTTPS GET with curl (the image has it; no redirects), at most `max`
/// bytes; into `out`, or the body.
fn fetch(url: &str, max: u64, out: Option<&Path>) -> Result<Vec<u8>, String> {
    let mut cmd = Command::new("curl");
    cmd.args(["--fail", "--silent", "--show-error", "--proto", "=https", "--tlsv1.2"])
        .args(["--connect-timeout", "20", "--max-time", "900", "--retry", "2"])
        .arg("--max-filesize")
        .arg(max.to_string());
    if let Some(out) = out {
        cmd.arg("--output").arg(out);
    }
    let output = cmd.arg(url).stdin(Stdio::null()).output().map_err(|e| format!("curl: {e}"))?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_owned());
    }
    if output.stdout.len() as u64 > max {
        return Err("the body is over its limit".to_owned());
    }
    Ok(output.stdout)
}

/// `acpmux …` as the work user, at most 20 s; its stdout.
fn acpmux(args: &[&str]) -> Option<String> {
    let user = crate::linux::spawn::lookup_user(WORK_USER)?;
    let output = Command::new("timeout")
        .args(["20", "runuser", "-u", WORK_USER, "--", "env"])
        .arg(format!("HOME={WORK_HOME}"))
        .arg(format!("XDG_RUNTIME_DIR=/run/user/{}", user.uid))
        .arg(CURRENT_ACPMUX)
        .args(args)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    Some(String::from_utf8_lossy(&output.stdout).into_owned())
}

/// The acpmux sessions that run a turn or wait on a permission, by name
/// (as `acpmux host update --if-idle` reads them). Empty when no daemon runs.
fn busy_sessions() -> Result<Vec<String>, String> {
    let status = acpmux(&["--json", "daemon", "status"]).ok_or("acpmux did not run")?;
    if daemon_build(&status).is_none() {
        return Ok(Vec::new());
    }
    let ls = acpmux(&["--json", "ls"]).ok_or("acpmux ls did not run")?;
    super::busy_sessions_in(&ls).ok_or_else(|| "acpmux ls is unreadable".to_owned())
}

/// The build of the acpmux daemon that answered (`"91d3ea019 2026-11-05"`), if one did.
fn daemon_build(status: &str) -> Option<String> {
    let v: Value = serde_json::from_str(status.trim()).ok()?;
    v.get("pid").filter(|p| !p.is_null())?;
    Some(v.get("build").and_then(Value::as_str).unwrap_or_default().to_owned())
}

/// Whether the new build serves: the session host answers `identify` and
/// its process, and the work user's acpmux daemon (where the image runs
/// one), run the new store entry. (A build reports the commit of the first
/// build of its source tree, which need not be the channel's commit, so the
/// executable is what tells the builds apart.)
fn healthy(paths: &Paths, pending: &Pending) -> bool {
    let new = store_binary(&pending.cmux_tui);
    let runs_new = |pid: &str| {
        let pid = pid.trim();
        !pid.is_empty()
            && pid.bytes().all(|b| b.is_ascii_digit())
            && fs::read_link(format!("/proc/{pid}/exe")).ok().as_deref() == Some(new.as_path())
    };
    let serving = crate::cloud::role::daemon_socket(paths).is_some_and(|socket| {
        crate::cloud::role::query_identify(&socket, Duration::from_secs(2)).is_ok()
    });
    let session_host = serving
        && fs::read_to_string(paths.at(crate::config::DAEMON_PID_FILE))
            .is_ok_and(|pid| runs_new(&pid));
    if !session_host {
        return false;
    }
    if !paths.at(ACPMUX_UNIT_FILE).exists() {
        return true;
    }
    acpmux(&["--json", "daemon", "status"])
        .and_then(|status| serde_json::from_str::<Value>(status.trim()).ok())
        .and_then(|v| v.get("pid").and_then(Value::as_u64))
        .is_some_and(|pid| runs_new(&pid.to_string()))
}

/// The new `cmux host run` proves the pending update or rolls it back.
/// False when the role stopped meanwhile (the guard still covers it).
fn resolve(paths: &Paths, pending: &Pending, rx: &Receiver<Msg>) -> bool {
    if store::current_generation(paths).ok() != Some(pending.to) {
        log("the pending update's profile is not current (rolled back?); clearing it");
        clear_pending(paths);
        return true;
    }
    let deadline = Instant::now() + HEALTH_TIMEOUT;
    loop {
        if healthy(paths, pending) {
            commit(paths, pending);
            return true;
        }
        if Instant::now() >= deadline {
            rollback(
                paths,
                pending,
                "the new build did not serve within ten minutes of its restart",
                true,
            );
            return true;
        }
        match rx.recv_timeout(Duration::from_secs(5)) {
            Ok(Msg::Stop) | Err(RecvTimeoutError::Disconnected) => return false,
            _ => {}
        }
    }
}

fn commit(paths: &Paths, pending: &Pending) {
    let mut state = load_state(paths);
    state.applied_commit = Some(pending.commit.clone());
    state.applied_committed_at = pending.committed_at;
    let took = now().saturating_sub(pending.started_at);
    state.last = Some(format!("updated to {} (serving {took} s after the flip)", pending.commit));
    state.last_at = now();
    clear_pending(paths);
    disarm_guard();
    let (profiles, packages) = store::gc(paths, &[pending.from], &state.installed);
    state.installed.retain(|sha| !packages.contains(sha));
    let _ = save_state(paths, &state);
    log(&format!(
        "updated to {} (profile {}, serving {took} s after the flip); removed profiles {profiles:?}",
        pending.commit, pending.to
    ));
}

/// Flips back to the previous profile and restarts what runs the new build.
fn rollback(paths: &Paths, pending: &Pending, why: &str, in_host: bool) {
    log(&format!("rolling {} back to profile {}: {why}", pending.commit, pending.from));
    if let Err(e) = store::flip(paths, pending.from) {
        log(&format!("flipping back to profile {}: {e}", pending.from));
        return;
    }
    let mut state = load_state(paths);
    record_rollback(&mut state, pending);
    state.last = Some(format!("rolled back {}: {why}", pending.commit));
    state.last_at = now();
    let _ = save_state(paths, &state);
    clear_pending(paths);
    if in_host {
        disarm_guard();
    }
    restart_after_flip(&store_binary(&pending.cmux_tui));
}

fn systemctl(args: &[&str]) -> bool {
    Command::new("timeout")
        .arg("60")
        .arg("systemctl")
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

/// `systemctl --user …` in the work user's manager, at most 60 s.
fn user_systemctl(args: &[&str]) -> bool {
    let Some(user) = crate::linux::spawn::lookup_user(WORK_USER) else { return false };
    Command::new("timeout")
        .args(["60", "runuser", "-u", WORK_USER, "--", "env"])
        .arg(format!("XDG_RUNTIME_DIR=/run/user/{}", user.uid))
        .args(["systemctl", "--user"])
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

/// The previous build's `cmux host update guard --to <to>`, as a transient
/// timer [`GUARD_AFTER_SECS`] from now.
fn arm_guard(pending: &Pending) -> Result<(), String> {
    disarm_guard();
    let _ = systemctl(&["reset-failed", &format!("{GUARD_UNIT}.service")]);
    let program = store::profile_dir(&Paths::new("/"), pending.from).join("bin/cmux");
    let status = Command::new("systemd-run")
        .arg(format!("--unit={GUARD_UNIT}"))
        .arg(format!("--on-active={GUARD_AFTER_SECS}"))
        .args(["--timer-property=AccuracySec=10s", "--property=Type=oneshot", "--quiet"])
        .arg(program)
        .args(["host", "update", "guard", "--to", &pending.to.to_string()])
        .stdin(Stdio::null())
        .status()
        .map_err(|e| format!("systemd-run: {e}"))?;
    if status.success() { Ok(()) } else { Err(format!("systemd-run exited {status}")) }
}

fn disarm_guard() {
    let _ = systemctl(&["stop", &format!("{GUARD_UNIT}.timer")]);
}

/// Restarts what runs `old` (the binary just replaced): the work user's
/// acpmux, the other `cmux-*` system services, and last `cmux-host.service`.
fn restart_after_flip(old: &Path) {
    if !user_systemctl(&["restart", ACPMUX_UNIT]) {
        log("restarting the work user's acpmux.service failed (none on this image?)");
    }
    for unit in services_running(old) {
        // Only the image's own cmux units: a provider agent or an operator's
        // shell that happens to run the binary (`cmux host update check`) stays.
        if unit.starts_with("cmux-") && unit != HOST_UNIT && !unit.starts_with(GUARD_UNIT) {
            let _ = systemctl(&["restart", "--no-block", &unit]);
        }
    }
    let _ = systemctl(&["restart", "--no-block", HOST_UNIT]);
}

/// The system services (`/system.slice/<unit>.service`) with a process
/// whose executable is `binary`. Terminal hosts (their own scopes) and the
/// user's units are not services here.
fn services_running(binary: &Path) -> Vec<String> {
    let mut units = Vec::new();
    for entry in fs::read_dir("/proc").into_iter().flatten().flatten() {
        let dir = entry.path();
        if !entry.file_name().to_str().is_some_and(|n| n.bytes().all(|b| b.is_ascii_digit())) {
            continue;
        }
        if fs::read_link(dir.join("exe")).ok().as_deref() != Some(binary) {
            continue;
        }
        let Ok(cgroup) = fs::read_to_string(dir.join("cgroup")) else { continue };
        for line in cgroup.lines() {
            if let Some(unit) = line.strip_prefix("0::/system.slice/")
                && unit.ends_with(".service")
                && !unit.contains('/')
                && !units.iter().any(|u| u == unit)
            {
                units.push(unit.to_owned());
            }
        }
    }
    units
}

/// `cmux host update status [--json] | check | guard --to N`.
pub fn verb(args: &[String]) -> u8 {
    let paths = Paths::new("/");
    match args.iter().map(String::as_str).collect::<Vec<_>>().as_slice() {
        ["status"] | ["status", "--json"] => {
            let state = load_state(&paths);
            let value = json!({
                "channel": CHANNEL_URL,
                "off": off_reason(&paths),
                "current": store::current_generation(&paths).ok(),
                "generations": store::generations(&paths),
                "cmux_tui": store::current_generation(&paths).ok()
                    .and_then(|g| store::linked_package(&paths, g, CMUX_TUI).ok()),
                "pending": load_pending(&paths),
                "state": state,
            });
            println!("{value}");
            0
        }
        ["check"] => {
            let outcome = check(&paths);
            println!("{}", outcome.json());
            if matches!(outcome, Outcome::Failed(_)) { 1 } else { 0 }
        }
        ["guard", "--to", to] => {
            let Ok(to) = to.parse::<u64>() else { return 2 };
            let Some(pending) = load_pending(&paths).filter(|p| p.to == to) else { return 0 };
            if store::current_generation(&paths).ok() != Some(to) {
                clear_pending(&paths);
                return 0;
            }
            rollback(
                &paths,
                &pending,
                "the new build did not prove itself within twenty minutes of the flip",
                false,
            );
            0
        }
        _ => {
            eprintln!("usage: cmux host update status [--json] | check | guard --to GENERATION");
            2
        }
    }
}
