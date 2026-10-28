//! Keeps `cmux host serve` running for this user: a launchd agent
//! (macOS), a systemd user unit (Linux) or a per-user Run entry (Windows),
//! plus a detached start now so the host is reachable before the next login.
//! Hosting always runs as the user, never as root or SYSTEM: the daemon it
//! serves is the user's.

use std::fs::{File, OpenOptions, TryLockError};
use std::io::{Read as _, Write as _};
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::Duration;

#[cfg(not(windows))]
use anyhow::anyhow;
use anyhow::{Context as _, bail};
use cmux_process::{Command, Stdio};

#[cfg(any(target_os = "macos", test))]
use cmux_server_core::units::LaunchdJob;

#[cfg(any(target_os = "macos", test))]
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
    match crate::blocking::fs::open_with(&options, &path) {
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
    crate::blocking::fs::open_with(&options, path)
        .with_context(|| format!("cannot write {}", path.display()))
}

fn read_pid() -> Option<u32> {
    let mut text = String::new();
    cmux_blocking::fs::open(pid_path().ok()?).ok()?.read_to_string(&mut text).ok()?;
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
    crate::blocking::sync::recv_timeout(&rx, bound).unwrap_or(false)
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

/// The environment variable that names the readiness pipe's write end in a
/// detached `serve` (Unix): `serve` writes one line there once every
/// listener is bound, so the starter returns only when the host answers.
pub(crate) const READY_FD_ENV: &str = "CMUX_HOST_READY_FD";
/// The fd number the readiness pipe gets in the child.
#[cfg(unix)]
const READY_FD: libc::c_int = 3;
/// How long a detached `serve` has to bind its listeners.
#[cfg(unix)]
const READY_BOUND: Duration = Duration::from_secs(20);

/// Starts `serve` detached from this terminal, logging to `serve.log`. On
/// Unix it returns once the listener is bound (or fails with the reason
/// when `serve` exits first), so a client that runs right after `enable`
/// or `deny` finds the host answering.
pub(crate) fn spawn_detached(exe: &Path) -> anyhow::Result<u32> {
    let dir = super::config::ensure_dir()?;
    let log = log_path()?;
    let mut options = OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let out = crate::blocking::fs::open_with(&options, &log)?;
    let err = out.try_clone()?;
    let mut command = Command::new(exe);
    command.args(["host", "serve", "--dir"]).arg(&dir).stdin(Stdio::null()).stdout(out).stderr(err);
    #[cfg(unix)]
    let (ready_reader, ready_writer) =
        std::io::pipe().context("cannot create the readiness pipe")?;
    #[cfg(unix)]
    {
        use std::os::fd::AsFd as _;
        // The `host` verbs live on the `cmux` surface, chosen from argv[0].
        command.arg0("cmux");
        command.env(READY_FD_ENV, READY_FD.to_string());
        // Its own session; the pipe's write end reaches it as READY_FD.
        command.new_session().inherit_fd(ready_writer.as_fd(), READY_FD)?;
    }
    #[cfg(windows)]
    {
        const DETACHED_PROCESS: u32 = 0x0000_0008;
        const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW);
    }
    let child =
        command.spawn().with_context(|| format!("cannot start {} host serve", exe.display()))?;
    #[cfg(unix)]
    {
        // Only the child may hold the write end now: EOF then means it exited.
        drop(command);
        drop(ready_writer);
        wait_ready(ready_reader, &log)?;
    }
    Ok(child.id())
}

#[cfg(unix)]
fn wait_ready(reader: std::io::PipeReader, log: &Path) -> anyhow::Result<()> {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let mut line = String::new();
        let _ = std::io::BufRead::read_line(&mut std::io::BufReader::new(reader), &mut line);
        let _ = tx.send(line);
    });
    match crate::blocking::sync::recv_timeout(&rx, READY_BOUND) {
        Ok(line) if line.trim() == "ready" => Ok(()),
        Ok(line) if line.trim() == "disabled" => {
            bail!("remote hosting is disabled (run `cmux host enable`)")
        }
        Ok(_) => bail!("cmux host serve stopped before it listened; see {}", log.display()),
        Err(_) => bail!(
            "cmux host serve did not listen within {}s; see {}",
            READY_BOUND.as_secs(),
            log.display()
        ),
    }
}

/// `serve` side: takes the readiness pipe from the environment (so no
/// child process inherits it) and returns a function that reports ready.
pub(crate) fn take_ready_signal() -> impl FnOnce(&str) {
    let fd = std::env::var(READY_FD_ENV).ok().and_then(|v| v.parse::<i32>().ok());
    // SAFETY: removing our own variable before any thread reads the
    // environment of this process for a child.
    unsafe { std::env::remove_var(READY_FD_ENV) };
    #[cfg(unix)]
    let file = fd.filter(|fd| *fd >= 3).map(|fd| {
        use std::os::fd::FromRawFd as _;
        // SAFETY: the starter dup2'd the pipe's write end to this fd for us.
        unsafe {
            libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC);
            File::from_raw_fd(fd)
        }
    });
    #[cfg(not(unix))]
    let file: Option<File> = {
        let _ = fd;
        None
    };
    move |line: &str| {
        if let Some(mut file) = file {
            let _ = writeln!(file, "{line}");
        }
    }
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
    let mut why = String::new();
    if service {
        match imp::start() {
            Ok(true) => return Ok("started by the service manager".to_owned()),
            Ok(false) => {}
            Err(e) => why = format!(" (the service manager did not start it: {e:#})"),
        }
    }
    let pid = spawn_detached(exe)?;
    Ok(format!("started cmux host serve (pid {pid}){why}"))
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

/// The launchd agent plist that runs `exe host serve --dir dir`, logging to
/// `log`. Built outside `imp` so its tests run on every platform.
#[cfg(any(target_os = "macos", test))]
fn launchd_plist(exe: &Path, dir: &Path, log: &Path) -> String {
    let escape = |path: &Path| {
        path.display().to_string().replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
    };
    format!(
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
  <key>ProcessType</key><string>{}</string>
  <key>StandardOutPath</key><string>{}</string>
  <key>StandardErrorPath</key><string>{}</string>
</dict>
</plist>
"#,
        escape(exe),
        escape(dir),
        LaunchdJob::RemoteHost.process_type(),
        escape(log),
        escape(log),
    )
}

/// Sets the `ProcessType` of the agent plist at `path` (one an older cmux
/// wrote) to the process-roles table value before launchd reads it, so a
/// restart after an update runs `serve` at the new role. Returns whether it
/// rewrote the file.
#[cfg(any(target_os = "macos", all(unix, test)))]
fn upgrade_launchd_role(path: &Path) -> anyhow::Result<bool> {
    crate::launchd_role::upgrade_process_type(path, LaunchdJob::RemoteHost)
        .with_context(|| format!("cannot update {}", path.display()))
}

/// `serve` start: brings the installed agent's role up to the table, so the
/// next bootstrap (login, `enable`, a restart) runs `serve` at it. Returns a
/// note when it rewrote the plist.
pub(crate) fn upgrade_installed_role() -> Option<String> {
    #[cfg(target_os = "macos")]
    match imp::upgrade_role() {
        Ok(true) => {
            return Some(format!(
                "updated the {LAUNCHD_LABEL} agent to ProcessType {}; it applies at the next \
                 restart or login",
                LaunchdJob::RemoteHost.process_type()
            ));
        }
        Ok(false) => {}
        Err(error) => return Some(format!("{error:#}")),
    }
    None
}

#[cfg(target_os = "macos")]
mod imp {
    use super::*;

    fn plist_path() -> anyhow::Result<PathBuf> {
        let home = cmux_tui_core::platform::home_dir()
            .ok_or_else(|| anyhow!("cannot find the home directory"))?;
        Ok(home.join("Library").join("LaunchAgents").join(format!("{LAUNCHD_LABEL}.plist")))
    }

    fn domain() -> String {
        format!("gui/{}", cmux_tui_core::platform::effective_uid())
    }

    pub(super) fn write(exe: &Path, dir: &Path) -> anyhow::Result<String> {
        let path = plist_path()?;
        let plist = launchd_plist(exe, dir, &log_path()?);
        if let Some(parent) = path.parent() {
            cmux_blocking::fs::create_dir_all(parent)?;
        }
        cmux_blocking::fs::write(&path, plist)?;
        Ok(format!("launchd agent {LAUNCHD_LABEL}"))
    }

    pub(super) fn stop() {
        let _ = run_quiet("launchctl", &["bootout", &format!("{}/{LAUNCHD_LABEL}", domain())]);
    }

    pub(super) fn start() -> anyhow::Result<bool> {
        let path = plist_path()?;
        upgrade_launchd_role(&path)?;
        run_quiet("launchctl", &["bootstrap", &domain(), &path.display().to_string()])?;
        Ok(true)
    }

    /// Brings the installed agent's role up to the table; the running job
    /// gets it at its next bootstrap (a restart or the next login).
    pub(super) fn upgrade_role() -> anyhow::Result<bool> {
        upgrade_launchd_role(&plist_path()?)
    }

    pub(super) fn remove() -> anyhow::Result<()> {
        stop();
        let path = plist_path()?;
        if cmux_blocking::fs::metadata(&path).is_ok() {
            cmux_blocking::fs::remove_file(&path)?;
        }
        Ok(())
    }

    pub(super) fn installed() -> Option<String> {
        plist_path()
            .ok()
            .filter(|p| cmux_blocking::fs::metadata(p).is_ok())
            .map(|p| p.display().to_string())
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
            cmux_blocking::fs::create_dir_all(parent)?;
        }
        cmux_blocking::fs::write(&path, unit)?;
        // No user manager (a headless login without linger, `su`, a
        // container): leave no unit behind, so `installed()` stays false
        // and the caller starts `serve` detached instead.
        if let Err(e) = run_quiet("systemctl", &["--user", "daemon-reload"]) {
            let _ = cmux_blocking::fs::remove_file(&path);
            return Err(e);
        }
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
        if cmux_blocking::fs::metadata(&path).is_ok() {
            cmux_blocking::fs::remove_file(&path)?;
            let _ = run_quiet("systemctl", &["--user", "daemon-reload"]);
        }
        Ok(())
    }

    pub(super) fn installed() -> Option<String> {
        unit_path()
            .ok()
            .filter(|p| cmux_blocking::fs::metadata(p).is_ok())
            .map(|p| p.display().to_string())
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_launchd_agent_runs_at_the_process_roles_table_value_never_background() {
        let plist = launchd_plist(
            Path::new("/Applications/cmux.app/Contents/Resources/bin/cmux"),
            Path::new("/Users/ana/.cmux/host"),
            Path::new("/Users/ana/.cmux/host-serve.log"),
        );
        let process_type = format!(
            "<key>ProcessType</key><string>{}</string>",
            LaunchdJob::RemoteHost.process_type()
        );
        assert!(plist.contains(&process_type), "{plist}");
        assert!(plist.contains("<key>ProcessType</key><string>Interactive</string>"), "{plist}");
        assert!(plist.contains("<string>host</string><string>serve</string>"), "{plist}");
    }

    /// An agent `cmux host enable` installed before p02-threads-234 (written
    /// `Background`) runs at the table value from the next bootstrap a
    /// restart makes: `imp::start` upgrades it first. The upgraded plist is
    /// the one `enable` writes now.
    #[cfg(unix)]
    #[test]
    fn a_background_agent_from_an_older_cmux_is_upgraded_before_its_bootstrap() {
        let exe = Path::new("/Applications/cmux.app/Contents/Resources/bin/cmux");
        let state = Path::new("/Users/ana/.cmux/host");
        let log = Path::new("/Users/ana/.cmux/host/serve.log");
        let current = launchd_plist(exe, state, log);
        let old = current.replace(
            &format!("<string>{}</string>", LaunchdJob::RemoteHost.process_type()),
            "<string>Background</string>",
        );
        assert_ne!(old, current);
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(format!("{LAUNCHD_LABEL}.plist"));
        std::fs::write(&path, old).unwrap();

        assert!(upgrade_launchd_role(&path).unwrap());
        let upgraded = plist::Value::from_file(&path).unwrap();
        let wanted = plist::Value::from_reader_xml(current.as_bytes()).unwrap();
        assert_eq!(upgraded, wanted);
        assert!(!upgrade_launchd_role(&path).unwrap(), "a second start leaves it as it is");
    }

    #[test]
    fn the_launchd_agent_escapes_paths() {
        let plist = launchd_plist(Path::new("/a&b/cmux"), Path::new("/d<i>r"), Path::new("/l.log"));
        assert!(plist.contains("<string>/a&amp;b/cmux</string>"), "{plist}");
        assert!(plist.contains("<string>/d&lt;i&gt;r</string>"), "{plist}");
    }
}
