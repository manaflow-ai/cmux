//! Starting the worker on Linux: in the person's graphical session (its
//! DISPLAY, WAYLAND_DISPLAY, XDG_RUNTIME_DIR and session bus), in its own
//! systemd user scope when the user manager runs (so closing the terminal
//! that started the daemon does not take the worker with it), else as a
//! plain child.

use std::ffi::OsString;
use std::path::{Path, PathBuf};

use cmux_process::{Command, Stdio};

use super::{Launcher, WORKER_MODE, WorkerProcess};

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

impl Launcher for NativeLauncher {
    fn launch(&self, log: &Path) -> Result<WorkerProcess, String> {
        let mut env = session_env(|name| std::env::var_os(name));
        if !env.iter().any(|(k, _)| k == "DISPLAY" || k == "WAYLAND_DISPLAY") && !fake_desktop() {
            return Err("no graphical session here: Computer Use needs a desktop (DISPLAY or \
                        WAYLAND_DISPLAY in the cmux daemon's environment or the systemd user \
                        session)"
                .into());
        }
        env.extend(process_env(|name| std::env::var_os(name)));
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
mod tests {
    use super::*;

    #[test]
    fn session_vars_come_from_the_daemon_first() {
        let own = |name: &str| match name {
            "DISPLAY" => Some(OsString::from(":1")),
            "XDG_RUNTIME_DIR" => Some(OsString::from("/nonexistent-run")),
            "WAYLAND_DISPLAY" => Some(OsString::new()),
            _ => None,
        };
        let env = session_env(own);
        assert!(env.contains(&("DISPLAY".into(), ":1".into())));
        assert!(!env.iter().any(|(k, _)| k == "WAYLAND_DISPLAY"));
        assert_eq!(
            parse_environment("DISPLAY=:0\nBROKEN\nA=b=c\n"),
            [("DISPLAY".to_string(), ":0".to_string()), ("A".into(), "b=c".into())]
        );
    }

    #[test]
    fn the_headless_switch_reaches_the_worker() {
        let own = |name: &str| (name == "CMUX_CU_HEADLESS").then(|| OsString::from("0"));
        assert_eq!(process_env(own), [("CMUX_CU_HEADLESS".to_string(), OsString::from("0"))]);
    }
}
