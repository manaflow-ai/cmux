//! Keeps `cmux host serve` running for this user: a launchd agent
//! (macOS), a systemd user unit (Linux) or a per-user Run entry (Windows),
//! plus a detached start now so the host is reachable before the next login.
//! Hosting always runs as the user, never as root or SYSTEM: the daemon it
//! serves is the user's.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

#[cfg(not(windows))]
use anyhow::anyhow;
use anyhow::{Context as _, bail};

#[cfg(target_os = "macos")]
const LAUNCHD_LABEL: &str = "com.cmuxterm.host-remote";
#[cfg(target_os = "linux")]
const SYSTEMD_UNIT: &str = "cmux-host-remote.service";
#[cfg(windows)]
const RUN_VALUE: &str = "cmux-host-remote";

pub(crate) fn pid_path() -> anyhow::Result<PathBuf> {
    Ok(super::config::dir()?.join("serve.pid"))
}

pub(crate) fn log_path() -> anyhow::Result<PathBuf> {
    Ok(super::config::dir()?.join("serve.log"))
}

pub(crate) fn write_pid() -> anyhow::Result<()> {
    let path = pid_path()?;
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    std::fs::write(&path, std::process::id().to_string())?;
    Ok(())
}

/// The recorded `serve` pid when that process still runs.
pub(crate) fn running_pid() -> Option<u32> {
    let pid: u32 = std::fs::read_to_string(pid_path().ok()?).ok()?.trim().parse().ok()?;
    alive(pid).then_some(pid)
}

#[cfg(unix)]
fn alive(pid: u32) -> bool {
    // SAFETY: signal 0 only checks that the process exists.
    let rc = unsafe { libc::kill(pid as libc::pid_t, 0) };
    rc == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

#[cfg(windows)]
fn alive(pid: u32) -> bool {
    Command::new("tasklist")
        .args(["/FI", &format!("PID eq {pid}"), "/NH", "/FO", "CSV"])
        .stdin(Stdio::null())
        .output()
        .map(|out| String::from_utf8_lossy(&out.stdout).contains(&format!("\"{pid}\"")))
        .unwrap_or(false)
}

/// Stops the recorded `serve` process (exact pid only).
pub(crate) fn stop_running() {
    let Some(pid) = running_pid() else { return };
    #[cfg(unix)]
    {
        // SAFETY: SIGTERM to the exact pid this host recorded for itself.
        unsafe {
            libc::kill(pid as libc::pid_t, libc::SIGTERM);
        }
    }
    #[cfg(windows)]
    {
        let _ = Command::new("taskkill")
            .args(["/PID", &pid.to_string(), "/F"])
            .stdin(Stdio::null())
            .output();
    }
    if let Ok(path) = pid_path() {
        let _ = std::fs::remove_file(path);
    }
}

/// Starts `serve` detached from this terminal, logging to `serve.log`.
pub(crate) fn spawn_detached(exe: &Path) -> anyhow::Result<u32> {
    let log = log_path()?;
    if let Some(dir) = log.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let out = std::fs::OpenOptions::new().create(true).append(true).open(&log)?;
    let err = out.try_clone()?;
    let mut command = Command::new(exe);
    command.args(["host", "serve"]).stdin(Stdio::null()).stdout(out).stderr(err);
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt as _;
        // SAFETY: setsid only, between fork and exec.
        unsafe {
            command.pre_exec(|| {
                libc::setsid();
                Ok(())
            });
        }
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt as _;
        const DETACHED_PROCESS: u32 = 0x0000_0008;
        const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW);
    }
    let child =
        command.spawn().with_context(|| format!("cannot start {} host serve", exe.display()))?;
    Ok(child.id())
}

/// What `status` reports about the service.
pub(crate) fn describe() -> String {
    match installed_path() {
        Some(path) => format!("installed ({path})"),
        None => "not installed".to_owned(),
    }
}

/// Installs the service. `started` is true when the service manager runs
/// `serve` now; otherwise the caller starts a detached one.
pub(crate) struct Installed {
    pub what: String,
    pub started: bool,
}

pub(crate) fn install(exe: &Path) -> anyhow::Result<Installed> {
    imp::install(exe)
}

pub(crate) fn uninstall() -> anyhow::Result<()> {
    imp::uninstall()
}

fn installed_path() -> Option<String> {
    imp::installed()
}

fn run_quiet(program: &str, args: &[&str]) -> anyhow::Result<()> {
    let out = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .output()
        .with_context(|| format!("cannot run {program}"))?;
    if !out.status.success() {
        bail!(
            "`{program} {}` failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(())
}

#[cfg(target_os = "macos")]
mod imp {
    use super::*;

    fn plist_path() -> anyhow::Result<PathBuf> {
        let home = cmux_tui_core::platform::home_dir()
            .ok_or_else(|| anyhow!("cannot find the home directory"))?;
        Ok(home.join("Library").join("LaunchAgents").join(format!("{LAUNCHD_LABEL}.plist")))
    }

    fn escape(text: &str) -> String {
        text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
    }

    pub(super) fn install(exe: &Path) -> anyhow::Result<Installed> {
        let path = plist_path()?;
        let log = log_path()?;
        let plist = format!(
            r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>{LAUNCHD_LABEL}</string>
  <key>ProgramArguments</key>
  <array><string>{}</string><string>host</string><string>serve</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>{}</string>
  <key>StandardErrorPath</key><string>{}</string>
</dict>
</plist>
"#,
            escape(&exe.display().to_string()),
            escape(&log.display().to_string()),
            escape(&log.display().to_string()),
        );
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        std::fs::write(&path, plist)?;
        let domain = format!("gui/{}", cmux_tui_core::platform::effective_uid());
        // A loaded older job is replaced; an absent one is fine.
        let _ = run_quiet("launchctl", &["bootout", &format!("{domain}/{LAUNCHD_LABEL}")]);
        run_quiet("launchctl", &["bootstrap", &domain, &path.display().to_string()])?;
        Ok(Installed { what: format!("launchd agent {LAUNCHD_LABEL}"), started: true })
    }

    pub(super) fn uninstall() -> anyhow::Result<()> {
        let domain = format!("gui/{}", cmux_tui_core::platform::effective_uid());
        let _ = run_quiet("launchctl", &["bootout", &format!("{domain}/{LAUNCHD_LABEL}")]);
        let path = plist_path()?;
        if path.exists() {
            std::fs::remove_file(&path)?;
        }
        Ok(())
    }

    pub(super) fn installed() -> Option<String> {
        plist_path().ok().filter(|p| p.exists()).map(|p| p.display().to_string())
    }
}

#[cfg(target_os = "linux")]
mod imp {
    use super::*;

    fn unit_path() -> anyhow::Result<PathBuf> {
        let base = std::env::var_os("XDG_CONFIG_HOME")
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
            .or_else(|| cmux_tui_core::platform::home_dir().map(|h| h.join(".config")))
            .ok_or_else(|| anyhow!("cannot find the home directory"))?;
        Ok(base.join("systemd").join("user").join(SYSTEMD_UNIT))
    }

    pub(super) fn install(exe: &Path) -> anyhow::Result<Installed> {
        if cmux_tui_core::platform::effective_uid() == 0 {
            bail!(
                "remote hosting runs as a user, not root: run `cmux host enable` as the user whose sessions to serve"
            );
        }
        let path = unit_path()?;
        let unit = format!(
            "[Unit]\nDescription=cmux remote hosting (cmux host serve)\nAfter=network-online.target\n\n[Service]\nExecStart=\"{}\" host serve\nRestart=on-failure\nRestartSec=10\n\n[Install]\nWantedBy=default.target\n",
            exe.display()
        );
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        std::fs::write(&path, unit)?;
        run_quiet("systemctl", &["--user", "daemon-reload"])?;
        run_quiet("systemctl", &["--user", "enable", "--now", SYSTEMD_UNIT])?;
        Ok(Installed { what: format!("systemd user unit {SYSTEMD_UNIT}"), started: true })
    }

    pub(super) fn uninstall() -> anyhow::Result<()> {
        let _ = run_quiet("systemctl", &["--user", "disable", "--now", SYSTEMD_UNIT]);
        let path = unit_path()?;
        if path.exists() {
            std::fs::remove_file(&path)?;
            let _ = run_quiet("systemctl", &["--user", "daemon-reload"]);
        }
        Ok(())
    }

    pub(super) fn installed() -> Option<String> {
        unit_path().ok().filter(|p| p.exists()).map(|p| p.display().to_string())
    }
}

#[cfg(windows)]
mod imp {
    use super::*;

    const RUN_KEY: &str = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run";

    pub(super) fn install(exe: &Path) -> anyhow::Result<Installed> {
        let command = format!("\"{}\" host serve-detached", exe.display());
        run_quiet("reg", &["add", RUN_KEY, "/v", RUN_VALUE, "/t", "REG_SZ", "/d", &command, "/f"])?;
        Ok(Installed { what: format!("logon entry {RUN_KEY}\\{RUN_VALUE}"), started: false })
    }

    pub(super) fn uninstall() -> anyhow::Result<()> {
        if installed().is_some() {
            run_quiet("reg", &["delete", RUN_KEY, "/v", RUN_VALUE, "/f"])?;
        }
        Ok(())
    }

    pub(super) fn installed() -> Option<String> {
        let out = Command::new("reg")
            .args(["query", RUN_KEY, "/v", RUN_VALUE])
            .stdin(Stdio::null())
            .output()
            .ok()?;
        out.status.success().then(|| format!("{RUN_KEY}\\{RUN_VALUE}"))
    }
}

#[cfg(not(any(target_os = "macos", target_os = "linux", windows)))]
mod imp {
    use super::*;

    pub(super) fn install(_exe: &Path) -> anyhow::Result<Installed> {
        bail!("no service manager support on this platform; run `cmux host serve` yourself")
    }

    pub(super) fn uninstall() -> anyhow::Result<()> {
        Ok(())
    }

    pub(super) fn installed() -> Option<String> {
        None
    }
}
