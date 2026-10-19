//! Keeps `cmux host serve` running for this user: a launchd agent
//! (macOS), a systemd user unit (Linux) or a per-user Run entry (Windows),
//! plus a detached start now so the host is reachable before the next login.
//! Hosting always runs as the user, never as root or SYSTEM: the daemon it
//! serves is the user's.

use std::fs::{File, OpenOptions, TryLockError};
use std::io::{Read as _, Write as _};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;

#[cfg(not(windows))]
use anyhow::anyhow;
use anyhow::{Context as _, bail};

#[cfg(target_os = "macos")]
const LAUNCHD_LABEL: &str = "com.cmuxterm.host-remote";
#[cfg(target_os = "linux")]
const SYSTEMD_UNIT: &str = "cmux-host-remote.service";
#[cfg(windows)]
const RUN_VALUE: &str = "cmux-host-remote";

/// How long a stopped `serve` has to release its lock before SIGKILL.
const STOP_BOUND: Duration = Duration::from_secs(5);

fn lock_path() -> anyhow::Result<PathBuf> {
    Ok(super::config::dir()?.join("serve.lock"))
}

fn pid_path() -> anyhow::Result<PathBuf> {
    Ok(super::config::dir()?.join("serve.pid"))
}

pub(crate) fn log_path() -> anyhow::Result<PathBuf> {
    Ok(super::config::dir()?.join("serve.log"))
}

/// Held by the running `serve` for its whole life. The OS drops the lock
/// when the process ends, however it ends, so a stale pid file never names
/// a live process (pid reuse). The pid is a separate file: on Windows a
/// locked file cannot be read by another handle.
pub(crate) struct ServeLock {
    _file: File,
}

pub(crate) fn acquire() -> anyhow::Result<ServeLock> {
    super::config::ensure_dir()?;
    let file = open_lock(true)?.ok_or_else(|| anyhow::anyhow!("cannot create the lock file"))?;
    match file.try_lock() {
        Ok(()) => {}
        Err(TryLockError::WouldBlock) => bail!(
            "another `cmux host serve` runs for this state directory (pid {})",
            read_pid().map(|p| p.to_string()).unwrap_or_else(|| "unknown".to_owned())
        ),
        Err(TryLockError::Error(e)) => return Err(e).context("cannot lock serve.lock"),
    }
    let mut pid = new_private_file(&pid_path()?)?;
    pid.write_all(std::process::id().to_string().as_bytes())?;
    Ok(ServeLock { _file: file })
}

fn open_lock(create: bool) -> anyhow::Result<Option<File>> {
    let path = lock_path()?;
    let mut options = OpenOptions::new();
    options.read(true).write(true).create(create).truncate(false);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    match options.open(&path) {
        Ok(file) => Ok(Some(file)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e).with_context(|| format!("cannot open {}", path.display())),
    }
}

fn new_private_file(path: &Path) -> anyhow::Result<File> {
    let mut options = OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    options.open(path).with_context(|| format!("cannot write {}", path.display()))
}

fn read_pid() -> Option<u32> {
    let mut text = String::new();
    File::open(pid_path().ok()?).ok()?.read_to_string(&mut text).ok()?;
    text.trim().parse().ok()
}

/// The pid of the running `serve`: someone holds the lock.
pub(crate) fn running_pid() -> Option<u32> {
    let file = open_lock(false).ok()??;
    match file.try_lock() {
        Ok(()) => None,
        Err(TryLockError::WouldBlock) => read_pid(),
        Err(TryLockError::Error(_)) => None,
    }
}

/// Stops the running `serve` (the pid that holds the lock) and returns when
/// its lock is released.
pub(crate) fn stop_running() {
    let Some(pid) = running_pid() else { return };
    signal(pid, false);
    if !lock_released_within(STOP_BOUND) {
        signal(pid, true);
        let _ = lock_released_within(STOP_BOUND);
    }
}

fn lock_released_within(bound: Duration) -> bool {
    let Ok(Some(file)) = open_lock(false) else { return true };
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(file.lock().is_ok());
    });
    rx.recv_timeout(bound).unwrap_or(false)
}

#[cfg(unix)]
fn signal(pid: u32, kill: bool) {
    let sig = if kill { libc::SIGKILL } else { libc::SIGTERM };
    // SAFETY: a signal to the exact pid that holds this host's serve lock.
    unsafe {
        libc::kill(pid as libc::pid_t, sig);
    }
}

#[cfg(windows)]
fn signal(pid: u32, _kill: bool) {
    let _ = Command::new("taskkill")
        .args(["/PID", &pid.to_string(), "/F"])
        .stdin(Stdio::null())
        .output();
}

/// Starts `serve` detached from this terminal, logging to `serve.log`.
pub(crate) fn spawn_detached(exe: &Path) -> anyhow::Result<u32> {
    let dir = super::config::ensure_dir()?;
    let log = log_path()?;
    let mut options = OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let out = options.open(&log)?;
    let err = out.try_clone()?;
    let mut command = Command::new(exe);
    command.args(["host", "serve", "--dir"]).arg(&dir).stdin(Stdio::null()).stdout(out).stderr(err);
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
    match imp::installed() {
        Some(path) => format!("installed ({path})"),
        None => "not installed".to_owned(),
    }
}

/// Writes the service definition (does not start it); returns what it is.
pub(crate) fn install(exe: &Path) -> anyhow::Result<String> {
    let dir = super::config::ensure_dir()?;
    imp::write(exe, &dir)
}

/// Stops and removes the service definition.
pub(crate) fn uninstall() -> anyhow::Result<()> {
    imp::remove()
}

pub(crate) fn installed() -> bool {
    imp::installed().is_some()
}

/// Replaces any running `serve` (the service's or a detached one) with a
/// fresh one: through the service manager when `with_service` and one is
/// installed, else detached. Returns a note for `status`.
pub(crate) fn restart(exe: &Path, with_service: bool) -> anyhow::Result<String> {
    let service = with_service && installed();
    if installed() {
        imp::stop();
    }
    stop_running();
    if service && imp::start()? {
        return Ok("started by the service manager".to_owned());
    }
    let pid = spawn_detached(exe)?;
    Ok(format!("started cmux host serve (pid {pid})"))
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

    fn escape(path: &Path) -> String {
        path.display().to_string().replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
    }

    fn domain() -> String {
        format!("gui/{}", cmux_tui_core::platform::effective_uid())
    }

    pub(super) fn write(exe: &Path, dir: &Path) -> anyhow::Result<String> {
        let path = plist_path()?;
        let log = log_path()?;
        let plist = format!(
            r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>{LAUNCHD_LABEL}</string>
  <key>ProgramArguments</key>
  <array><string>{}</string><string>host</string><string>serve</string><string>--dir</string><string>{}</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>{}</string>
  <key>StandardErrorPath</key><string>{}</string>
</dict>
</plist>
"#,
            escape(exe),
            escape(dir),
            escape(&log),
            escape(&log),
        );
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(&path, plist)?;
        Ok(format!("launchd agent {LAUNCHD_LABEL}"))
    }

    pub(super) fn stop() {
        let _ = run_quiet("launchctl", &["bootout", &format!("{}/{LAUNCHD_LABEL}", domain())]);
    }

    pub(super) fn start() -> anyhow::Result<bool> {
        run_quiet("launchctl", &["bootstrap", &domain(), &plist_path()?.display().to_string()])?;
        Ok(true)
    }

    pub(super) fn remove() -> anyhow::Result<()> {
        stop();
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

    /// A path for `ExecStart=`: quoted, and refused when it holds a
    /// character systemd would expand or unescape (`%`, `$`, `\`, `"`).
    fn quoted(path: &Path) -> anyhow::Result<String> {
        let text = path.to_str().ok_or_else(|| anyhow!("{} is not UTF-8", path.display()))?;
        if text.chars().any(|c| matches!(c, '%' | '$' | '\\' | '"') || c.is_control()) {
            bail!("{text} has a character a systemd unit cannot hold; move it to a plain path");
        }
        Ok(format!("\"{text}\""))
    }

    pub(super) fn write(exe: &Path, dir: &Path) -> anyhow::Result<String> {
        if cmux_tui_core::platform::effective_uid() == 0 {
            bail!(
                "remote hosting runs as a user, not root: run `cmux host enable` as the user whose sessions to serve"
            );
        }
        let path = unit_path()?;
        let unit = format!(
            "[Unit]\nDescription=cmux remote hosting (cmux host serve)\nAfter=network-online.target\n\n[Service]\nExecStart={} host serve --dir {}\nRestart=on-failure\nRestartSec=10\n\n[Install]\nWantedBy=default.target\n",
            quoted(exe)?,
            quoted(dir)?,
        );
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(&path, unit)?;
        run_quiet("systemctl", &["--user", "daemon-reload"])?;
        Ok(format!("systemd user unit {SYSTEMD_UNIT}"))
    }

    pub(super) fn stop() {
        let _ = run_quiet("systemctl", &["--user", "stop", SYSTEMD_UNIT]);
    }

    pub(super) fn start() -> anyhow::Result<bool> {
        run_quiet("systemctl", &["--user", "enable", SYSTEMD_UNIT])?;
        run_quiet("systemctl", &["--user", "start", SYSTEMD_UNIT])?;
        Ok(true)
    }

    pub(super) fn remove() -> anyhow::Result<()> {
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

    pub(super) fn write(exe: &Path, dir: &Path) -> anyhow::Result<String> {
        // Windows paths cannot hold `"`, so plain quoting is exact.
        let command =
            format!("\"{}\" host serve-detached --dir \"{}\"", exe.display(), dir.display());
        run_quiet("reg", &["add", RUN_KEY, "/v", RUN_VALUE, "/t", "REG_SZ", "/d", &command, "/f"])?;
        Ok(format!("logon entry {RUN_KEY}\\{RUN_VALUE}"))
    }

    /// The Run entry starts `serve` at logon only; the running one is
    /// stopped through its lock.
    pub(super) fn stop() {}

    pub(super) fn start() -> anyhow::Result<bool> {
        Ok(false)
    }

    pub(super) fn remove() -> anyhow::Result<()> {
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

    pub(super) fn write(_exe: &Path, _dir: &Path) -> anyhow::Result<String> {
        bail!("no service manager support on this platform; run `cmux host serve` yourself")
    }

    pub(super) fn stop() {}

    pub(super) fn start() -> anyhow::Result<bool> {
        Ok(false)
    }

    pub(super) fn remove() -> anyhow::Result<()> {
        Ok(())
    }

    pub(super) fn installed() -> Option<String> {
        None
    }
}
