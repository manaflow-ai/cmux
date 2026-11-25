//! Starting the worker on Linux: in the person's graphical session (its
//! DISPLAY, WAYLAND_DISPLAY, XDG_RUNTIME_DIR and session bus), in its own
//! systemd user scope when the user manager runs (so closing the terminal
//! that started the daemon does not take the worker with it), else as a
//! plain child.
//!
//! A machine whose desktop starts on demand (a cmux Cloud VM: Xvfb and its
//! AT-SPI bus stay off until an agent asks) installs a desktop starter,
//! [`DESKTOP_STARTER`]: when the daemon has no display, the launcher runs it
//! (only when root owns it and no other user can write it, as the owner
//! policy file), and it starts the display and prints the worker's
//! variables, one `KEY=VALUE` per line. Only [`STARTER_VARS`] are taken.

use std::ffi::OsString;
use std::fs::File;
use std::io::{Read, Seek};
use std::path::{Path, PathBuf};
use std::time::Duration;

use cmux_process::{Command, Stdio};

use super::{Launcher, NO_NEW_PRIVS_ENV, WORKER_MODE, WorkerProcess};

/// The machine's desktop starter (see the module docs).
pub(crate) const DESKTOP_STARTER: &str = "/etc/cmux/computer-use-desktop";
/// How long the starter may take (a display and its AT-SPI bus).
const STARTER_LIMIT: Duration = Duration::from_secs(60);
/// The most of the starter's output read (its variables, its reason).
const STARTER_OUTPUT_LIMIT: u64 = 64 * 1024;
/// The variables a desktop starter may set for the worker: the session's,
/// the headless switch, a PATH (the machine's refusing tools first) and the
/// no-new-privileges switch. Anything else it prints is ignored.
const STARTER_VARS: &[&str] = &[
    "DISPLAY",
    "WAYLAND_DISPLAY",
    "XAUTHORITY",
    "XDG_RUNTIME_DIR",
    "XDG_SESSION_TYPE",
    "XDG_CURRENT_DESKTOP",
    "DBUS_SESSION_BUS_ADDRESS",
    "PATH",
    "CMUX_CU_HEADLESS",
    NO_NEW_PRIVS_ENV,
];

/// The session variables the worker needs to reach the desktop.
const SESSION_VARS: &[&str] = &[
    "DISPLAY",
    "WAYLAND_DISPLAY",
    "XAUTHORITY",
    "XDG_RUNTIME_DIR",
    "XDG_SESSION_TYPE",
    "XDG_CURRENT_DESKTOP",
    "DBUS_SESSION_BUS_ADDRESS",
];
/// Plain process variables passed on as they are.
const PROCESS_VARS: &[&str] = &[
    "HOME",
    "USER",
    "LOGNAME",
    "PATH",
    "LANG",
    "LC_ALL",
    "CMUX_TUI_STATE_DIR",
    "CMUX_CU_FAKE_DESKTOP",
    // Whether a person shares the display (1: cmux cloud images, 0: someone
    // watches an Xvfb display); the worker reads it, so it must get through.
    "CMUX_CU_HEADLESS",
    // The worker drops the right to gain privileges (no sudo for it or the
    // apps it starts) when this is 1 (computer_use_worker.rs).
    NO_NEW_PRIVS_ENV,
];

/// The plain process variables (PROCESS_VARS) the worker gets from `own`.
fn process_env(own: impl Fn(&str) -> Option<OsString>) -> Vec<(String, OsString)> {
    PROCESS_VARS.iter().filter_map(|name| own(name).map(|v| ((*name).to_string(), v))).collect()
}

pub(crate) struct NativeLauncher {
    exe: PathBuf,
}

impl NativeLauncher {
    pub(crate) fn new(exe: PathBuf) -> Self {
        Self { exe }
    }
}

/// `KEY=VALUE` lines (systemd's show-environment) into pairs.
fn parse_environment(text: &str) -> Vec<(String, String)> {
    text.lines()
        .filter_map(|line| line.split_once('='))
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
}

/// The graphical session's variables: the daemon's own, else the systemd
/// user manager's (a desktop session imports DISPLAY and WAYLAND_DISPLAY
/// there, so a daemon started outside it still finds the desktop).
fn session_env(own: impl Fn(&str) -> Option<OsString>) -> Vec<(String, OsString)> {
    let mut found: Vec<(String, OsString)> = SESSION_VARS
        .iter()
        .filter_map(|name| own(name).filter(|v| !v.is_empty()).map(|v| ((*name).to_string(), v)))
        .collect();
    let has_display = |found: &[(String, OsString)]| {
        found.iter().any(|(k, _)| k == "DISPLAY" || k == "WAYLAND_DISPLAY")
    };
    if !has_display(&found) && user_manager(&found).is_some() {
        let output = Command::new("systemctl")
            .args(["--user", "show-environment"])
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output();
        if let Ok(output) = output
            && output.status.success()
        {
            for (key, value) in parse_environment(&String::from_utf8_lossy(&output.stdout)) {
                if SESSION_VARS.contains(&key.as_str()) && !found.iter().any(|(k, _)| *k == key) {
                    found.push((key, value.into()));
                }
            }
        }
    }
    found
}

/// The systemd user manager's private socket, when it runs.
fn user_manager(found: &[(String, OsString)]) -> Option<PathBuf> {
    let runtime = found
        .iter()
        .find(|(k, _)| k == "XDG_RUNTIME_DIR")
        .map(|(_, v)| PathBuf::from(v))
        // SAFETY: plain call.
        .unwrap_or_else(|| PathBuf::from(format!("/run/user/{}", unsafe { libc::geteuid() })));
    let socket = runtime.join("systemd").join("private");
    socket.exists().then_some(socket)
}

fn systemd_run() -> Option<PathBuf> {
    ["/usr/bin/systemd-run", "/bin/systemd-run"].iter().map(PathBuf::from).find(|p| p.is_file())
}

fn fake_desktop() -> bool {
    cfg!(debug_assertions) && std::env::var_os("CMUX_CU_FAKE_DESKTOP").is_some_and(|v| v == "1")
}

fn has_display(env: &[(String, OsString)]) -> bool {
    env.iter().any(|(k, v)| (k == "DISPLAY" || k == "WAYLAND_DISPLAY") && !v.is_empty())
}

/// `env` with each of `over`'s variables in place of its own.
fn overridden(
    mut env: Vec<(String, OsString)>,
    over: Vec<(String, OsString)>,
) -> Vec<(String, OsString)> {
    for (key, value) in over {
        env.retain(|(k, _)| *k != key);
        env.push((key, value));
    }
    env
}

/// An anonymous in-memory file (`memfd_create`) for a child's output.
fn capture_file(name: &str) -> Result<File, String> {
    use std::os::fd::FromRawFd;
    let name = std::ffi::CString::new(name).map_err(|e| e.to_string())?;
    // SAFETY: a valid C string; the returned fd is new and owned by the File.
    let fd = unsafe { libc::memfd_create(name.as_ptr(), libc::MFD_CLOEXEC) };
    if fd < 0 {
        return Err(format!("starter output: {}", std::io::Error::last_os_error()));
    }
    // SAFETY: `fd` was just created and nothing else owns it.
    Ok(unsafe { File::from_raw_fd(fd) })
}

/// The first [`STARTER_OUTPUT_LIMIT`] bytes written to a [`capture_file`].
fn captured(mut file: File) -> String {
    let mut text = String::new();
    if file.rewind().is_ok() {
        let _ = file.take(STARTER_OUTPUT_LIMIT).read_to_string(&mut text);
    }
    text
}

/// Runs the desktop starter at `path` when `trust` accepts it, and returns
/// the [`STARTER_VARS`] it printed. `Err` says why there is no desktop: the
/// file is not trusted, did not run, failed (with what it said) or took
/// longer than [`STARTER_LIMIT`].
pub(crate) fn run_starter(
    path: &Path,
    trust: impl Fn(&Path) -> Result<(), String>,
) -> Result<Vec<(String, OsString)>, String> {
    trust(path).map_err(|why| format!("the desktop starter was not run: {why}"))?;
    // The starter's output goes to two in-memory files, not pipes: a display
    // it leaves running may keep them open, and nothing waits for that.
    let (out, err) = (capture_file("cmux-cu-starter-out")?, capture_file("cmux-cu-starter-err")?);
    let mut child = Command::new(path)
        .stdin(Stdio::null())
        .stdout(Stdio::from(out.try_clone().map_err(|e| format!("starter output: {e}"))?))
        .stderr(Stdio::from(err.try_clone().map_err(|e| format!("starter output: {e}"))?))
        .spawn()
        .map_err(|error| format!("{}: {error}", path.display()))?;
    let status =
        child.wait_timeout(STARTER_LIMIT).map_err(|e| format!("{}: {e}", path.display()))?;
    let Some(status) = status else {
        // Ended when `child` drops.
        drop(child);
        return Err(format!(
            "the desktop starter {} did not finish within {} s",
            path.display(),
            STARTER_LIMIT.as_secs()
        ));
    };
    let (out, err) = (captured(out), captured(err));
    if !status.success() {
        let said = err.trim();
        let said = said.get(said.len().saturating_sub(600)..).unwrap_or(said);
        return Err(format!("the desktop starter {} failed ({status}): {said}", path.display()));
    }
    Ok(parse_environment(&out)
        .into_iter()
        .filter(|(key, _)| STARTER_VARS.contains(&key.as_str()))
        .map(|(key, value)| (key, value.into()))
        .collect())
}

/// The worker's whole environment: the graphical session's variables and
/// the plain process ones from `own`; with no display, those of the desktop
/// `starter` (when one exists) over them.
pub(crate) fn worker_env(
    own: impl Fn(&str) -> Option<OsString>,
    starter: &Path,
    trust: impl Fn(&Path) -> Result<(), String>,
) -> Result<Vec<(String, OsString)>, String> {
    let session = session_env(&own);
    let started = if has_display(&session) || fake_desktop() {
        Vec::new()
    } else if std::fs::symlink_metadata(starter).is_ok() {
        run_starter(starter, trust)?
    } else {
        Vec::new()
    };
    let env = overridden(overridden(session, process_env(&own)), started);
    if !has_display(&env) && !fake_desktop() {
        return Err("no graphical session here: Computer Use needs a desktop (DISPLAY or \
                    WAYLAND_DISPLAY in the cmux daemon's environment or the systemd user \
                    session, or a desktop starter at /etc/cmux/computer-use-desktop)"
            .into());
    }
    Ok(env)
}

impl Launcher for NativeLauncher {
    fn launch(&self, log: &Path) -> Result<WorkerProcess, String> {
        let mut env = worker_env(
            |name| std::env::var_os(name),
            Path::new(DESKTOP_STARTER),
            super::config::trusted,
        )?;
        if let Some(dir) = log.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let log_file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(log)
            .map_err(|error| format!("{}: {error}", log.display()))?;
        let manager = user_manager(&env);
        let scoped = systemd_run().filter(|_| manager.is_some());
        // systemd-run finds the user manager through XDG_RUNTIME_DIR.
        if let Some(runtime) = manager.as_ref().and_then(|socket| socket.parent()?.parent())
            && !env.iter().any(|(k, _)| k == "XDG_RUNTIME_DIR")
        {
            env.push(("XDG_RUNTIME_DIR".into(), runtime.as_os_str().to_os_string()));
        }
        let mut command = match &scoped {
            Some(systemd_run) => {
                let mut command = Command::new(systemd_run);
                command.args(["--user", "--scope", "--quiet", "--collect", "--"]).arg(&self.exe);
                command
            }
            None => Command::new(&self.exe),
        };
        command
            .arg(WORKER_MODE)
            .env_clear()
            .envs(env)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::from(log_file))
            // Its own process group: a terminal's Ctrl-C to the daemon's
            // group does not reach it.
            .process_group(0);
        let mut child = command
            .spawn()
            .map_err(|error| format!("the Computer Use worker did not start: {error}"))?;
        let input = child.stdin.take().ok_or("the worker has no stdin")?;
        let output = child.stdout.take().ok_or("the worker has no stdout")?;
        Ok(WorkerProcess {
            input: Box::new(input),
            output: Box::new(output),
            reap: Box::new(move || {
                let _ = child.wait();
            }),
        })
    }
}

#[cfg(test)]
#[path = "linux_tests.rs"]
mod tests;
