//! systemd user and system units (server.md 4.3, 7.4). Measured behavior
//! from the Linux prototype (server/prototype/linux/README.md): `systemctl
//! start` of a `Type=notify` unit returns at readiness, so there is no wait
//! loop; `loginctl enable-linger <user>` needs the user name when there is
//! no session; a lingering user's manager is at `/run/user/<uid>`.

use std::path::{Path, PathBuf};

use cmux_server_core::layout::{SYSTEMD_UNIT, ServiceKind};
use cmux_server_core::pg::SOCKET_GROUP;
use cmux_server_core::units::{
    SERVICE_USER, UnitError, systemd_app_server_template, systemd_session_unit,
    systemd_system_unit, systemd_update_path_unit, systemd_update_service_unit, systemd_user_unit,
};

use super::{ServiceReport, ServiceState, Services};
use crate::error::{Error, Result};
use crate::fsx;
use crate::process::{Cmd, Runner};

const UPDATE_PATH: &str = "cmux-update.path";
const UPDATE_SERVICE: &str = "cmux-update.service";
const APP_TEMPLATE: &str = "cmux-app-server@.service";
const APP_INSTANCES: &str = "cmux-app-server@*.service";

fn unit_error(e: UnitError) -> Error {
    Error::rejected(format!("cannot render the unit: {e:?}"))
}

fn system(s: &Services<'_>) -> bool {
    matches!(s.layout.service, ServiceKind::SystemdSystem { .. })
}

fn unit_dir(s: &Services<'_>) -> Result<PathBuf> {
    let main = s.unit_path()?;
    Ok(main.parent().map(Path::to_path_buf).unwrap_or_default())
}

/// Every unit file of the layout with its core-rendered content.
pub fn files(s: &Services<'_>) -> Result<Vec<(PathBuf, String)>> {
    let dir = unit_dir(s)?;
    let layout = s.layout;
    if let Some(host) = &s.session {
        if system(s) {
            return Err(Error::rejected("the session service runs as your own user, not --system"));
        }
        let unit = systemd_session_unit(layout, &host.binary, &host.session).map_err(unit_error)?;
        return Ok(vec![(dir.join(SYSTEMD_UNIT), unit)]);
    }
    if !system(s) {
        return Ok(vec![(dir.join(SYSTEMD_UNIT), systemd_user_unit(layout).map_err(unit_error)?)]);
    }
    Ok(vec![
        (dir.join(SYSTEMD_UNIT), systemd_system_unit(layout).map_err(unit_error)?),
        (dir.join(UPDATE_PATH), systemd_update_path_unit(layout).map_err(unit_error)?),
        (dir.join(UPDATE_SERVICE), systemd_update_service_unit(layout).map_err(unit_error)?),
        (dir.join(APP_TEMPLATE), systemd_app_server_template(layout).map_err(unit_error)?),
    ])
}

fn systemctl(s: &Services<'_>) -> Cmd {
    if system(s) {
        // Never prompt through polkit: the caller already runs as root, and
        // a prompt from a service-manager call would block an agent.
        return Cmd::new("systemctl").arg("--no-ask-password");
    }
    let mut cmd = Cmd::new("systemctl").arg("--user");
    if std::env::var_os("XDG_RUNTIME_DIR").is_none() {
        cmd = cmd.env("XDG_RUNTIME_DIR", format!("/run/user/{}", s.uid));
    }
    cmd
}

/// Asks systemd, for each unit file of the layout, where it loads that unit
/// from. Fine: systemd does not know the unit, or loads it from the file
/// cmux writes. An error (nothing changes) for anything else: another file
/// (a package's, `/etc`, a mask), a transient or generated unit, or no
/// answer, since cmux cannot tell then whose unit it would stop or replace.
/// Templates (`@.service`) cannot be asked and are checked as files only.
pub fn check_sources(s: &Services<'_>) -> Result<()> {
    for (path, _) in files(s)? {
        check_unit(s, &path)?;
    }
    if system(s) {
        app_instances(s)?;
    }
    Ok(())
}

/// [`check_sources`] for the one unit file `path`.
fn check_unit(s: &Services<'_>, path: &Path) -> Result<()> {
    let Some(name) = path.file_name().and_then(|n| n.to_str()) else { return Ok(()) };
    if name.contains("@.") {
        return Ok(());
    }
    let cmd = systemctl(s).args([
        "show",
        "--property=LoadState,FragmentPath,Transient,DropInPaths",
        name,
    ]);
    let cannot = |why: String| {
        Error::rejected(format!(
            "cmux cannot tell where systemd loads {name} from ({why}), so it changes nothing. Make sure `{}` works in this shell (a login session, or XDG_RUNTIME_DIR=/run/user/{}), then run the command again",
            cmd.display(),
            s.uid
        ))
    };
    let out = s.runner.run(&cmd).map_err(|e| cannot(e.to_string()))?;
    if !out.ok() {
        return Err(cannot(format!(
            "it exited {}",
            out.code.map_or("by a signal".to_owned(), |c| c.to_string())
        )));
    }
    let text = out.stdout_text();
    let field = |key: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(key).and_then(|v| v.strip_prefix('=')))
            .map(str::trim)
    };
    let Some(state) = field("LoadState") else {
        return Err(cannot("it did not say whether it knows the unit".to_owned()));
    };
    if state == "not-found" {
        return Ok(());
    }
    let fragment = field("FragmentPath").unwrap_or("");
    let refuse = |from: String| {
        Error::rejected(format!(
            "systemd {from}, not from {} (the file cmux writes), so cmux leaves {name}, and everything it may use, alone. Remove or disable that unit yourself, then run the command again",
            path.display()
        ))
    };
    if field("Transient") == Some("yes") || fragment.is_empty() {
        return Err(refuse(format!(
            "runs {name} as a transient or generated unit with no unit file (load state {state})"
        )));
    }
    if Path::new(fragment) != path {
        return Err(refuse(format!("loads {name} from {fragment} (load state {state})")));
    }
    // A drop-in changes what systemd runs and stops for the unit as much as
    // the unit file does: each one, and its folder, must be writable by no
    // other account.
    for drop_in in field("DropInPaths").unwrap_or("").split_whitespace().map(Path::new) {
        let what = format!("a drop-in for {name}");
        super::check_not_shared(drop_in, &what)?;
        if let Some(dir) = drop_in.parent() {
            super::check_not_shared(dir, &format!("the folder of {what}"))?;
        }
    }
    Ok(())
}

/// The app server instances (`cmux-app-server@*.service`) systemd knows,
/// each checked to come from the template cmux writes: uninstall stops
/// these, by name. A list systemd cannot give changes nothing.
fn app_instances(s: &Services<'_>) -> Result<Vec<String>> {
    let template = unit_dir(s)?.join(APP_TEMPLATE);
    let list = systemctl(s).args([
        "list-units",
        "--all",
        "--plain",
        "--no-legend",
        "--full",
        APP_INSTANCES,
    ]);
    let out = s.runner.run(&list).map_err(|e| Error::io(list.display(), e))?;
    if !out.ok() {
        return Err(Error::rejected(format!(
            "cmux cannot list the app server units (`{}` failed), so it changes nothing",
            list.display()
        )));
    }
    let mut units = Vec::new();
    for unit in out.stdout_text().lines().filter_map(|l| l.split_whitespace().next()) {
        if !unit.starts_with("cmux-app-server@")
            || !unit.ends_with(".service")
            || unit.contains('*')
        {
            continue;
        }
        check_instance(s, unit, &template)?;
        units.push(unit.to_owned());
    }
    Ok(units)
}

/// Refuses the app server instance `unit` unless systemd loads it from
/// `template`, the template cmux writes.
fn check_instance(s: &Services<'_>, unit: &str, template: &Path) -> Result<()> {
    let show = systemctl(s).args(["show", "--property=FragmentPath", "--value", unit]);
    let out = s.runner.run(&show).map_err(|e| Error::io(show.display(), e))?;
    let fragment = out.stdout_text();
    if !out.ok() || Path::new(fragment.trim()) != template {
        return Err(Error::rejected(format!(
            "systemd runs {unit} from {}, not from {} (the template cmux writes), so cmux leaves it, and everything it may use, alone",
            if fragment.trim().is_empty() { "no unit file" } else { fragment.trim() },
            template.display()
        )));
    }
    Ok(())
}

/// What uninstall says when a check before a stop refuses: the units
/// checked before were stopped, nothing was removed.
const STOPPED_ONLY_CHECKED: &str =
    "cmux stopped only the units it had checked before this one, and removed nothing";

/// Runs `stop`, a command that stops `unit` by name, right between two
/// checks that systemd loads `unit` from the file cmux writes (`check`),
/// so no earlier answer stands in for the unit it stops (Codex R-005).
/// With `stopped`, the unit must also be stopped after it (an
/// `ActiveState` of inactive or failed): a stop that failed must not let
/// uninstall remove what the unit still uses.
///
/// systemd has no stop bound to a unit file (D-Bus `StopUnit` takes a name
/// only), so a gap of one command remains between the check and the stop.
/// No other account can use it: the unit folders and drop-ins are writable
/// by no other account (checked), the unit file is a new one no older
/// write descriptor reaches (`Services::renew_unit_files`), and only root
/// or this account can make the manager load a name from another file.
/// No other cmux command can use it either: every command that changes the
/// service holds the service lock (`Services::lock`). The check after the
/// stop finds a change made by hand in that gap when it is still in place
/// then; uninstall then removes nothing and says what cmux may have
/// stopped.
fn stop_checked(
    s: &Services<'_>,
    unit: &str,
    check: &dyn Fn() -> Result<()>,
    stop: &Cmd,
    stopped: bool,
) -> Result<()> {
    check().map_err(|e| super::outcome(e, STOPPED_ONLY_CHECKED))?;
    let _ = s.runner.run(stop);
    check().map_err(|e| {
        super::outcome(
            e,
            &format!(
                "that changed while cmux stopped {unit} by name, so cmux may have stopped that unit: start it again if it should run (`{}`). cmux removed nothing",
                systemctl(s).args(["start", unit]).display()
            ),
        )
    })?;
    if stopped {
        check_stopped(s, unit)?;
    }
    Ok(())
}

/// How long [`check_stopped`] waits for the processes a kill signalled to
/// end: 50 polls of 100 ms.
const PROCESS_WAIT_POLLS: u32 = 50;
const PROCESS_WAIT_POLL: std::time::Duration = std::time::Duration::from_millis(100);

/// Refuses unless systemd says `unit` is inactive or failed (a unit systemd
/// does not know is inactive); its processes may still run.
fn check_inactive(s: &Services<'_>, unit: &str) -> Result<()> {
    let cmd = systemctl(s).args(["show", "--property=ActiveState", "--value", unit]);
    let out = s.runner.run(&cmd).map_err(|e| Error::io(cmd.display(), e))?;
    let state = out.stdout_text();
    let state = state.trim();
    if !(out.ok() && matches!(state, "inactive" | "failed")) {
        return Err(Error::rejected(format!(
            "{unit} did not stop (`{}` says {}), so cmux removed nothing it may still use. Stop it (`{}`), then run the command again",
            cmd.display(),
            if state.is_empty() { "nothing" } else { state },
            systemctl(s).args(["stop", unit]).display()
        )));
    }
    Ok(())
}

/// Refuses unless systemd says `unit` is stopped (inactive or failed; a
/// unit systemd does not know is inactive). Any other state, or no answer,
/// means its processes may still run.
fn check_stopped(s: &Services<'_>, unit: &str) -> Result<()> {
    check_inactive(s, unit)?;
    // An inactive unit can keep processes: `KillMode=process` stops only
    // the main one, and the kill that ends the rest may have failed. That
    // kill does not wait, so give the processes it signalled a moment to
    // end (systemd 255: the group empties within milliseconds).
    let mut left = processes_left(s, unit)?;
    for _ in 0..PROCESS_WAIT_POLLS {
        if left.is_none() {
            break;
        }
        std::thread::sleep(PROCESS_WAIT_POLL);
        left = processes_left(s, unit)?;
    }
    if let Some(left) = left {
        return Err(Error::rejected(format!(
            "{left} of {unit} still run after it stopped, so cmux removed nothing they may use. End them (`{}`), then run the command again",
            systemctl(s).args(["kill", "--kill-whom=all", unit]).display()
        )));
    }
    Ok(())
}

/// How many processes are left in `unit`'s control group (`Some("3
/// processes")`), or None when there are none. systemd's own count
/// (`TasksCurrent`) when it keeps one; else the group's `cgroup.procs`
/// (the unified cgroup v2 mount, else the v1 `systemd` hierarchy), where a
/// group that is gone from a mounted hierarchy has none. Anything cmux
/// cannot read is an error, never "none": uninstall must not remove what
/// running processes may use.
fn processes_left(s: &Services<'_>, unit: &str) -> Result<Option<String>> {
    let cmd = systemctl(s).args(["show", "--property=ControlGroup,TasksCurrent", unit]);
    let cannot = |why: String| {
        Error::rejected(format!(
            "cmux cannot tell whether processes of {unit} still run ({why}), so it removed nothing they may use. Check `{}`, then run the command again",
            systemctl(s).args(["status", unit]).display()
        ))
    };
    let out = s.runner.run(&cmd).map_err(|e| cannot(e.to_string()))?;
    if !out.ok() {
        return Err(cannot(format!(
            "`{}` exited {}",
            cmd.display(),
            out.code.map_or("by a signal".to_owned(), |c| c.to_string())
        )));
    }
    let text = out.stdout_text();
    let field = |key: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(key).and_then(|v| v.strip_prefix('=')))
            .map(str::trim)
    };
    let Some(group) = field("ControlGroup") else {
        return Err(cannot(format!("`{}` did not name its control group", cmd.display())));
    };
    if group.is_empty() {
        return Ok(None);
    }
    // u64::MAX or `[not set]`: systemd keeps no count for this unit.
    if let Some(Ok(tasks)) = field("TasksCurrent").map(str::parse::<u64>)
        && tasks != u64::MAX
    {
        return Ok((tasks > 0).then(|| format!("{tasks} processes")));
    }
    let roots = CGROUP_ROOTS.map(|(root, marker)| (Path::new(root), marker));
    match procs_in(&roots, group) {
        Ok(Some(n)) => Ok(Some(format!("{n} processes"))),
        Ok(None) => Ok(None),
        Err(why) => Err(cannot(why)),
    }
}

/// Where cgroup hierarchies are mounted, each with a file only that
/// hierarchy's root has: the unified v2 mount, the hybrid layout's v2
/// mount, and the v1 `name=systemd` hierarchy that tracks units there.
const CGROUP_ROOTS: [(&str, &str); 3] = [
    ("/sys/fs/cgroup", "cgroup.controllers"),
    ("/sys/fs/cgroup/unified", "cgroup.controllers"),
    ("/sys/fs/cgroup/systemd", "cgroup.procs"),
];

/// The processes in the control group `group` under every mounted
/// hierarchy of `roots` (`(root, marker)`), the most any one lists: a
/// hybrid layout tracks units in v1 while v2 may list none. None only when
/// every mounted hierarchy has the group gone or empty. An error (why)
/// when none is mounted or a list cannot be read.
fn procs_in(roots: &[(&Path, &str)], group: &str) -> std::result::Result<Option<usize>, String> {
    let relative = group.trim_start_matches('/');
    let (mut mounted, mut most) = (false, 0);
    for (root, marker) in roots {
        if !root.join(marker).exists() {
            continue;
        }
        mounted = true;
        let procs = root.join(relative).join("cgroup.procs");
        match std::fs::read_to_string(&procs) {
            Ok(list) => most = most.max(list.lines().filter(|l| !l.trim().is_empty()).count()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(format!("{}: {e}", procs.display())),
        }
    }
    if !mounted {
        return Err(format!(
            "systemd keeps no count for {group} and no cgroup hierarchy is mounted"
        ));
    }
    Ok((most > 0).then_some(most))
}

/// `loginctl show-user <user> -p Linger --value`: `Some(true)` for `yes`,
/// `None` when logind cannot answer.
pub fn linger_state(runner: &dyn Runner, user: &str) -> Option<bool> {
    let cmd = Cmd::new("loginctl").args(["show-user", user, "-p", "Linger", "--value"]);
    let out = runner.run(&cmd).ok()?;
    match (out.ok(), out.stdout_text().as_str()) {
        (true, "yes") => Some(true),
        (true, "no") => Some(false),
        _ => None,
    }
}

/// Linux user mode: turns linger on when polkit allows it without root
/// (stock polkitd does); otherwise reports the one `sudo` command.
fn ensure_linger(s: &Services<'_>, report: &mut ServiceReport) {
    let state = linger_state(s.runner, &s.user);
    if state == Some(true) {
        report.linger = Some(true);
        return;
    }
    let enable = Cmd::new("loginctl").args(["enable-linger", &s.user]);
    if s.runner.run(&enable).is_ok_and(|o| o.ok()) && linger_state(s.runner, &s.user) == Some(true)
    {
        report.linger = Some(true);
        return;
    }
    report.linger = Some(false);
    report.warnings.push(format!(
        "linger is off, so the server stops at logout and does not start at boot. Run once: sudo loginctl enable-linger {}",
        s.user
    ));
}

/// System mode: the service user `cmux` and the socket group `cmux-db`.
fn ensure_accounts(s: &Services<'_>) -> Result<()> {
    let has = |db: &str, name: &str| {
        s.runner.run(&Cmd::new("getent").args([db, name])).is_ok_and(|o| o.ok())
    };
    if !has("group", SOCKET_GROUP) {
        s.runner.check(&Cmd::new("groupadd").args(["--system", SOCKET_GROUP]))?;
    }
    if !has("passwd", SERVICE_USER) {
        let home = s.layout.state.as_str();
        s.runner.check(&Cmd::new("useradd").args([
            "--system",
            "--user-group",
            "--no-create-home",
            "--home-dir",
            home,
            "--shell",
            "/usr/sbin/nologin",
            SERVICE_USER,
        ]))?;
    }
    Ok(())
}

pub fn install(s: &Services<'_>, restart: bool) -> Result<ServiceReport> {
    let mut report = ServiceReport { unit: s.unit_path()?, ..ServiceReport::default() };
    if system(s) {
        ensure_accounts(s)?;
    }
    let files = files(s)?;
    for (path, text) in &files {
        if let Some(dir) = path.parent() {
            fsx::ensure_dir(dir, 0o755)?;
        }
        report.changed |= fsx::write_fresh(path, text.as_bytes(), 0o644)?;
    }
    s.wrote(&files)?;
    if !system(s) {
        if s.linger {
            ensure_linger(s, &mut report);
        } else {
            // `install --user`: linger stays as it is.
            report.linger = linger_state(s.runner, &s.user);
        }
    }
    let ctl = systemctl(s);
    if report.changed {
        s.runner.check(&ctl.clone().arg("daemon-reload"))?;
    }
    let mut enable = ctl.clone().arg("enable").arg(SYSTEMD_UNIT);
    if system(s) {
        enable = enable.arg(UPDATE_PATH);
    }
    s.runner.check(&enable)?;
    if system(s) {
        s.runner.check(&ctl.clone().args(["start", UPDATE_PATH]))?;
    }
    // A running server restarts for a new generation or a changed unit
    // (daemon-reload alone does not apply a unit to a running service).
    // `start` is a no-op when the unit is already active and returns at
    // readiness (`Type=notify`).
    let wants_restart = restart || report.changed;
    let verb = if wants_restart && is_active(s) { "restart" } else { "start" };
    s.runner.check(&ctl.args([verb, SYSTEMD_UNIT]))?;
    report.restarted = verb == "restart";
    Ok(report)
}

fn is_active(s: &Services<'_>) -> bool {
    let cmd = systemctl(s).args(["is-active", "--quiet", SYSTEMD_UNIT]);
    s.runner.run(&cmd).is_ok_and(|o| o.ok())
}

pub fn restart(s: &Services<'_>) -> Result<()> {
    s.runner.check(&systemctl(s).args(["restart", SYSTEMD_UNIT])).map(|_| ())
}

pub fn start(s: &Services<'_>) -> Result<()> {
    s.runner.check(&systemctl(s).args(["enable", "--now", SYSTEMD_UNIT])).map(|_| ())
}

/// `KillMode=process` keeps terminal hosts after a stop, as on a restart.
pub fn stop(s: &Services<'_>) -> Result<()> {
    s.runner.check(&systemctl(s).args(["disable", "--now", SYSTEMD_UNIT])).map(|_| ())
}

/// What uninstall needs to end the session's terminals ([`super::sweep`]).
pub(super) fn sweep(s: &Services<'_>) -> Result<Option<super::Sweep>> {
    if s.session.is_none() {
        return Ok(None);
    }
    super::sweep(s, daemon_pid(s)?, &|key| manager_env(s, key))
}

pub fn uninstall(s: &Services<'_>, sweep: Option<&super::Sweep>) -> Result<Vec<PathBuf>> {
    let ctl = systemctl(s);
    let dir = unit_dir(s)?;
    let unit_check = |unit: &'static str| {
        let path = dir.join(unit);
        move || check_unit(s, &path)
    };
    // KillMode=process leaves terminal hosts after a stop by design;
    // uninstall ends every process of the unit first.
    // (The unit may restart after a kill: `disable --now` below stops it.)
    let kill = ctl.clone().args(["kill", "--kill-whom=all", SYSTEMD_UNIT]);
    if let Some(sweep) = sweep {
        // A terminal host ignores the kill's SIGTERM (it does not come from
        // PID 1): a running daemon ends its own terminals first; then stop
        // the unit so it cannot restart, end any terminals a daemon that
        // did not run left (through a daemon of their own), then signal
        // whatever is left.
        super::end_running_daemon_terminals(s, sweep)?;
        let disable = ctl.clone().args(["disable", "--now", SYSTEMD_UNIT]);
        stop_checked(s, SYSTEMD_UNIT, &unit_check(SYSTEMD_UNIT), &disable, false)?;
        // Its host processes may stay (KillMode=process); the daemon must
        // not, or it could start terminals after the sweep.
        check_inactive(s, SYSTEMD_UNIT)?;
        super::end_terminal_hosts(s, sweep, "systemd stopped the service")?;
    }
    stop_checked(s, SYSTEMD_UNIT, &unit_check(SYSTEMD_UNIT), &kill, false)?;
    let mut units = vec![SYSTEMD_UNIT];
    if system(s) {
        units.extend([UPDATE_PATH, UPDATE_SERVICE]);
    }
    // One unit per call: systemctl aborts the whole call on a missing unit.
    for unit in units {
        let disable = ctl.clone().args(["disable", "--now", unit]);
        stop_checked(s, unit, &unit_check(unit), &disable, true)?;
    }
    if system(s) {
        // Every app server instance stops before its template is removed.
        // Listed once the supervisor is down (so one it started meanwhile
        // is in the list), then each checked again right before and after
        // its own stop, by name, never by a pattern.
        let template = dir.join(APP_TEMPLATE);
        let instances = app_instances(s).map_err(|e| super::outcome(e, STOPPED_ONLY_CHECKED))?;
        for unit in instances {
            let check = || check_instance(s, &unit, &template);
            stop_checked(s, &unit, &check, &ctl.clone().args(["stop", unit.as_str()]), true)?;
        }
    }
    let removed = s.remove_unit_files();
    let _ = s.runner.run(&ctl.arg("daemon-reload"));
    removed
}

/// The main pid of the session unit while it runs (`MainPID`, 0 when not).
fn daemon_pid(s: &Services<'_>) -> Result<Option<u32>> {
    let cmd = systemctl(s).args(["show", "--property=MainPID", "--value", SYSTEMD_UNIT]);
    let out = s.runner.check(&cmd)?;
    let text = out.stdout_text();
    // No answer: a unit systemd does not know (it prints 0 for one it knows).
    if text.is_empty() {
        return Ok(None);
    }
    let pid: u32 = text.parse().map_err(|_| {
        Error::rejected(format!("`{}` answered {text:?}, not a pid", cmd.display()))
    })?;
    Ok((pid != 0).then_some(pid))
}

/// `key` in the environment of the user's service manager (`systemctl
/// show-environment`, one `KEY=VALUE` per line, the value quoted as
/// [`unquote_env_value`] reads), which the session unit (it sets no
/// variable of its own) passes to the daemon. Read only when the daemon
/// does not run (a running one's own environment is read instead).
fn manager_env(s: &Services<'_>, key: &str) -> Result<Option<std::ffi::OsString>> {
    let out = s.runner.check(&systemctl(s).arg("show-environment"))?;
    let text = String::from_utf8_lossy(&out.stdout).into_owned();
    let Some(raw) = text.lines().find_map(|line| line.strip_prefix(key)?.strip_prefix('=')) else {
        return Ok(None);
    };
    let value = unquote_env_value(raw).ok_or_else(|| {
        Error::rejected(format!(
            "cmux cannot read {key} from `systemctl --user show-environment` ({raw:?})"
        ))
    })?;
    Ok((!value.is_empty()).then(|| value.into()))
}

/// A value as `systemctl show-environment` prints it: as is when it holds
/// only plain characters, else `$'...'` with C escapes (systemd
/// `shell_maybe_quote` with `SHELL_ESCAPE_POSIX`, `cescape`: `\xHH` or
/// octal `\NNN` for other bytes). `None` for anything else.
fn unquote_env_value(raw: &str) -> Option<String> {
    let Some(body) = raw.strip_prefix("$'").and_then(|r| r.strip_suffix('\'')) else {
        return (!raw.contains(['\'', '"', '\\', '$', '`'])).then(|| raw.to_owned());
    };
    let mut bytes = Vec::new();
    let mut chars = body.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            let mut b = [0; 4];
            bytes.extend_from_slice(c.encode_utf8(&mut b).as_bytes());
            continue;
        }
        let escaped = match chars.next()? {
            'a' => 0x07,
            'b' => 0x08,
            'f' => 0x0c,
            'n' => b'\n',
            'r' => b'\r',
            't' => b'\t',
            'v' => 0x0b,
            '\\' => b'\\',
            '\'' => b'\'',
            '"' => b'"',
            'x' => {
                let hex: String = [chars.next()?, chars.next()?].iter().collect();
                u8::from_str_radix(&hex, 16).ok()?
            }
            first @ '0'..='7' => {
                let oct: String = [first, chars.next()?, chars.next()?].iter().collect();
                u8::from_str_radix(&oct, 8).ok()?
            }
            _ => return None,
        };
        bytes.push(escaped);
    }
    String::from_utf8(bytes).ok()
}

pub fn state(s: &Services<'_>) -> ServiceState {
    let installed = s.unit_path().is_ok_and(|p| p.is_file());
    let query = |verb: &str, yes: &str| {
        let out = s.runner.run(&systemctl(s).args([verb, SYSTEMD_UNIT])).ok()?;
        Some(out.stdout_text() == yes)
    };
    ServiceState {
        installed,
        active: query("is-active", "active"),
        enabled: query("is-enabled", "enabled"),
    }
}

#[cfg(test)]
#[path = "systemd_tests.rs"]
mod tests;
