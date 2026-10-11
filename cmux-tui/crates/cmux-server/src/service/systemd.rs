//! systemd user and system units (server.md 4.3, 7.4). Measured behavior
//! from the Linux prototype (server/prototype/linux/README.md): `systemctl
//! start` of a `Type=notify` unit returns at readiness, so there is no wait
//! loop; `loginctl enable-linger <user>` needs the user name when there is
//! no session; a lingering user's manager is at `/run/user/<uid>`.

use std::path::{Path, PathBuf};

use cmux_server_core::layout::{SYSTEMD_UNIT, ServiceKind};
use cmux_server_core::pg::SOCKET_GROUP;
use cmux_server_core::units::{
    SERVICE_USER, UnitError, systemd_app_server_template, systemd_system_unit,
    systemd_update_path_unit, systemd_update_service_unit, systemd_user_unit,
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
        report.changed |= fsx::write_if_changed(path, text.as_bytes(), 0o644)?;
    }
    if !system(s) {
        ensure_linger(s, &mut report);
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

pub fn uninstall(s: &Services<'_>) -> Result<Vec<PathBuf>> {
    let ctl = systemctl(s);
    // KillMode=process leaves terminal hosts after a stop by design;
    // uninstall ends every process of the unit first.
    let _ = s.runner.run(&ctl.clone().args(["kill", "--kill-whom=all", SYSTEMD_UNIT]));
    let mut units = vec![SYSTEMD_UNIT];
    if system(s) {
        units.extend([UPDATE_PATH, UPDATE_SERVICE]);
    }
    // One unit per call: systemctl aborts the whole call on a missing unit.
    for unit in units {
        let _ = s.runner.run(&ctl.clone().args(["disable", "--now", unit]));
    }
    if system(s) {
        // Every app server instance stops before its template is removed;
        // systemctl expands the pattern itself (literal argv, no shell).
        let _ = s.runner.run(&ctl.clone().args(["stop", APP_INSTANCES]));
    }
    let mut removed = Vec::new();
    for (path, _) in files(s)? {
        if fsx::exists_no_follow(&path) {
            fsx::remove_tree(&path)?;
            removed.push(path);
        }
    }
    let _ = s.runner.run(&ctl.arg("daemon-reload"));
    Ok(removed)
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
