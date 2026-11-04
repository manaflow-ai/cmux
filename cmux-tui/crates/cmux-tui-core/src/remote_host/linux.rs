//! Linux parts of cmux Remote (docs/cmux-remote.md, "Windows and Linux"): a
//! sha256-verified copy of `cmux-remote-host` from beside the daemon, started
//! inside the person's graphical session, and `/proc` process identity.
//!
//! The host must run in the desktop session (it needs `DISPLAY` or
//! `WAYLAND_DISPLAY`, the session bus, the portal and the polkit agent), and
//! the daemon may not (an SSH login, a service). So the daemon starts it as a
//! transient unit of the user's systemd manager, which carries the session's
//! environment (`systemd-run --user`, `Type=notify`): the start returns once
//! the host serves. Without a user manager (a container, headless Xvfb), the
//! daemon starts it directly in its own session, as on macOS.

use std::io::{BufRead, BufReader, Read, Write};
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::time::Duration;

use cmux_process::{Command, Stdio};
use serde_json::Value;

use super::Paths;

const EXECUTABLE: &str = "cmux-remote-host";

/// The copy that runs.
pub(super) struct Staged {
    pub(super) executable: PathBuf,
    /// SHA-256 of the executable.
    pub(super) digest: String,
}

fn sha256_file(path: &Path) -> Result<String, String> {
    use sha2::{Digest, Sha256};
    let mut file = std::fs::File::open(path).map_err(|error| format!("{}: {error}", path.display()))?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0_u8; 1 << 20];
    loop {
        let count = file.read(&mut buffer).map_err(|error| format!("{}: {error}", path.display()))?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

/// The shipped host: `CMUX_REMOTE_HOST_BIN`, else beside the daemon, else `../lib/cmux/`.
fn shipped() -> Result<PathBuf, String> {
    if let Some(path) = std::env::var_os("CMUX_REMOTE_HOST_BIN").map(PathBuf::from) {
        return path.is_file().then_some(path).ok_or_else(|| "CMUX_REMOTE_HOST_BIN is not a file".into());
    }
    let exe = std::env::current_exe().map_err(|error| format!("{error}"))?;
    let dir = exe.parent().ok_or("the daemon has no directory")?;
    [dir.join(EXECUTABLE), dir.join("../lib/cmux").join(EXECUTABLE)]
        .into_iter()
        .find(|path| path.is_file())
        .ok_or_else(|| format!("this cmux build has no {EXECUTABLE} beside {}", exe.display()))
}

/// The digest the package pins (`cmux-remote-host.sha256` beside the binary), if any.
fn pinned_digest(shipped: &Path) -> Option<String> {
    let text = std::fs::read_to_string(shipped.with_file_name(format!("{EXECUTABLE}.sha256"))).ok()?;
    text.split_whitespace().next().map(str::to_ascii_lowercase)
}

/// A verified copy under `state/bin/<digest>/`, reused while the shipped
/// binary is the same; never followed through a symlink. The two newest
/// copies are kept (a host of the previous build may still run from one).
pub(super) fn stage(state: &Path) -> Result<Staged, String> {
    use std::os::unix::fs::PermissionsExt;
    let source = shipped()?;
    let digest = sha256_file(&source)?;
    if let Some(pinned) = pinned_digest(&source)
        && pinned != digest
    {
        return Err(format!("{} does not match its pinned sha256", source.display()));
    }
    let root = state.join("bin");
    for dir in [state, root.as_path()] {
        std::fs::create_dir_all(dir).map_err(|error| format!("{}: {error}", dir.display()))?;
        let meta = std::fs::symlink_metadata(dir).map_err(|error| format!("{error}"))?;
        if !meta.is_dir() {
            return Err(format!("{} is not a directory", dir.display()));
        }
        let _ = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700));
    }
    let slot = root.join(&digest[..16]);
    let executable = slot.join(EXECUTABLE);
    let marker = slot.join(".verified");
    let ready = std::fs::read_to_string(&marker).is_ok_and(|text| text.trim() == digest)
        && std::fs::symlink_metadata(&executable).is_ok_and(|meta| meta.is_file())
        && sha256_file(&executable).is_ok_and(|copy| copy == digest);
    if !ready {
        let temporary = root.join(format!(".staging-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&temporary);
        std::fs::create_dir_all(&temporary).map_err(|error| format!("{error}"))?;
        let copy = temporary.join(EXECUTABLE);
        std::fs::copy(&source, &copy).map_err(|error| format!("cannot stage {EXECUTABLE}: {error}"))?;
        std::fs::set_permissions(&copy, std::fs::Permissions::from_mode(0o700)).map_err(|error| format!("{error}"))?;
        if sha256_file(&copy)? != digest {
            let _ = std::fs::remove_dir_all(&temporary);
            return Err("the staged copy differs from the shipped binary".into());
        }
        std::fs::write(temporary.join(".verified"), &digest).map_err(|error| format!("{error}"))?;
        let _ = std::fs::remove_dir_all(&slot);
        std::fs::rename(&temporary, &slot).map_err(|error| format!("{error}"))?;
    }
    prune(&root, &slot);
    Ok(Staged { executable, digest })
}

fn prune(root: &Path, current: &Path) {
    let Ok(entries) = std::fs::read_dir(root) else { return };
    let mut others: Vec<(std::time::SystemTime, PathBuf)> = entries
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path != current && !path.file_name().is_some_and(|name| name.to_string_lossy().starts_with('.')))
        .filter_map(|path| Some((std::fs::metadata(&path).ok()?.modified().ok()?, path)))
        .collect();
    others.sort();
    others.pop();
    for (_, path) in others {
        let _ = std::fs::remove_dir_all(path);
    }
}

/// This build's acpmux, beside the daemon.
pub(super) fn acpmux_executable() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let acpmux = exe.parent()?.join("acpmux");
    acpmux.is_file().then_some(acpmux)
}

/// The user's systemd manager, when this machine has one for this user.
fn user_manager() -> Option<PathBuf> {
    let runtime = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from)?;
    let systemd_run = ["/usr/bin/systemd-run", "/bin/systemd-run"].into_iter().map(PathBuf::from).find(|path| path.is_file())?;
    runtime.join("systemd/private").exists().then_some(systemd_run)
}

/// The desktop session's variables a direct spawn passes on (never cmux tokens).
const DESKTOP_ENV: [&str; 13] = [
    "DISPLAY",
    "WAYLAND_DISPLAY",
    "XAUTHORITY",
    "XDG_RUNTIME_DIR",
    "XDG_SESSION_TYPE",
    "XDG_CURRENT_DESKTOP",
    "XDG_SESSION_DESKTOP",
    "DBUS_SESSION_BUS_ADDRESS",
    "HOME",
    "USER",
    "LOGNAME",
    "LANG",
    "LC_ALL",
];

fn host_arguments(paths: &Paths) -> Vec<std::ffi::OsString> {
    vec![
        "host".into(),
        "--layout-dir".into(),
        paths.runtime.clone().into_os_string(),
        "--state-dir".into(),
        paths.state.join("worker").into_os_string(),
        "--scope".into(),
        paths.scope.clone().into(),
    ]
}

/// Starts the host in the desktop session and waits until it serves.
pub(super) fn spawn_host(staged: &Staged, paths: &Paths, bootstrap: &Value, ready_timeout: Duration) -> Result<u32, String> {
    std::fs::create_dir_all(&paths.runtime).map_err(|error| format!("{error}"))?;
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&paths.runtime, std::fs::Permissions::from_mode(0o700));
    }
    match user_manager() {
        Some(systemd_run) => spawn_unit(&systemd_run, staged, paths, bootstrap),
        None => spawn_direct(staged, paths, bootstrap, ready_timeout),
    }
}

/// `systemd-run --user`: a transient `Type=notify` unit in the user's manager,
/// whose environment is the graphical session's. The bootstrap goes in a 0600
/// file the host deletes once read.
fn spawn_unit(systemd_run: &Path, staged: &Staged, paths: &Paths, bootstrap: &Value) -> Result<u32, String> {
    let leaf = paths.runtime.file_name().map(|leaf| leaf.to_string_lossy().into_owned()).unwrap_or_default();
    let unit = format!("cmux-remote-host-{leaf}.service");
    let file = paths.runtime.join("bootstrap.json");
    let bytes = serde_json::to_vec(bootstrap).map_err(|error| format!("{error}"))?;
    super::write_private(&file, &bytes);
    let systemctl = |args: &[&str]| {
        let _ = Command::new("systemctl").arg("--user").args(args).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).status();
    };
    // A unit of a host this daemon did not adopt (it refused, or another build) is stopped
    // first: one host per runtime directory. One that already exited keeps its name until reset.
    systemctl(&["stop", &unit]);
    systemctl(&["reset-failed", &unit]);
    let output = Command::new(systemd_run)
        .args(["--user", "--collect", "--quiet", "--unit", &unit])
        .args(["--description", "cmux Remote (Computer Use host)"])
        .args(["--property=Type=notify", "--property=NotifyAccess=main", "--property=TimeoutStartSec=15"])
        .args([
            "--property=UnsetEnvironment=CUA_DRIVER_PERMISSION_MODE CUA_DRIVER_DANGEROUSLY_BYPASS_APPROVALS",
            "--",
        ])
        .arg(&staged.executable)
        .args(host_arguments(paths))
        .arg("--bootstrap-file")
        .arg(&file)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()
        .map_err(|error| format!("systemd-run: {error}"))?;
    if !output.status.success() {
        let _ = std::fs::remove_file(&file);
        return Err(format!("cmux Remote did not start: {}", String::from_utf8_lossy(&output.stderr).trim()));
    }
    let shown = Command::new("systemctl")
        .args(["--user", "show", "--property=MainPID", "--value", &unit])
        .stdin(Stdio::null())
        .output()
        .map_err(|error| format!("systemctl: {error}"))?;
    String::from_utf8_lossy(&shown.stdout)
        .trim()
        .parse::<u32>()
        .ok()
        .filter(|pid| *pid > 1)
        .ok_or_else(|| format!("{unit} reports no main process"))
}

/// No user manager: the host runs in its own session, with the bootstrap
/// line on fd 3, and reports `ready` on stdout.
fn spawn_direct(staged: &Staged, paths: &Paths, bootstrap: &Value, ready_timeout: Duration) -> Result<u32, String> {
    let log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(paths.runtime.join("host.log"))
        .map_err(|error| format!("host.log: {error}"))?;
    let (bootstrap_read, bootstrap_write) = std::io::pipe().map_err(|error| format!("pipe: {error}"))?;
    let mut command = Command::new(&staged.executable);
    command
        .args(host_arguments(paths))
        .env_clear()
        .env("PATH", "/usr/local/bin:/usr/bin:/bin")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::from(log))
        .new_session();
    for name in DESKTOP_ENV {
        if let Some(value) = std::env::var_os(name) {
            command.env(name, value);
        }
    }
    use std::os::fd::AsFd;
    command.inherit_fd(bootstrap_read.as_fd(), 3).map_err(|error| format!("{error}"))?;
    let mut child = command.spawn().map_err(|error| format!("cmux Remote did not start: {error}"))?;
    drop(bootstrap_read);
    let pid = child.id();
    let stdout = child.stdout.take().ok_or("cmux Remote has no stdout")?;
    let _ = std::thread::Builder::new().name("remote-host-reap".into()).spawn(move || {
        let _ = child.wait();
    });
    let mut writer = std::fs::File::from(std::os::fd::OwnedFd::from(bootstrap_write));
    let written = writeln!(writer, "{bootstrap}");
    drop(writer);
    let (sender, receiver) = std::sync::mpsc::sync_channel(1);
    let _ = std::thread::Builder::new().name("remote-host-ready".into()).spawn(move || {
        let mut line = String::new();
        let ok = BufReader::new(stdout).read_line(&mut line).is_ok() && line == "ready\n";
        let _ = sender.send(ok);
    });
    if written.is_err() || !matches!(receiver.recv_timeout(ready_timeout), Ok(true)) {
        // SAFETY: a signal to the child we just started.
        unsafe { libc::kill(pid as libc::pid_t, libc::SIGKILL) };
        return Err(format!("cmux Remote did not report ready (see {})", paths.runtime.join("host.log").display()));
    }
    Ok(pid)
}

/// A live process's start time: clock ticks after boot (`/proc/<pid>/stat`
/// field 22) and 0, in the record's (seconds, microseconds) slots.
pub(super) fn process_start(pid: u32) -> Option<(u64, u64)> {
    let text = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let rest = &text[text.rfind(')')? + 1..];
    let ticks = rest.split_whitespace().nth(19)?.parse().ok()?;
    Some((ticks, 0))
}

/// The pid of a connected Unix socket's peer, when it runs as this user.
pub(super) fn peer_pid(stream: &std::os::unix::net::UnixStream) -> Option<u32> {
    let mut credentials = libc::ucred { pid: 0, uid: 0, gid: 0 };
    let mut length = size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: getsockopt into a correctly sized ucred.
    let ok = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&raw mut credentials).cast(),
            &mut length,
        )
    } == 0;
    // SAFETY: geteuid has no preconditions.
    let me = unsafe { libc::geteuid() };
    (ok && credentials.uid == me).then(|| u32::try_from(credentials.pid).ok()).flatten()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn this_process_has_a_start_time_and_a_parent_does_not_match_it() {
        let me = process_start(std::process::id()).expect("own start time");
        assert_eq!(me.1, 0);
        assert_eq!(process_start(std::process::id()), Some(me));
        assert_eq!(process_start(u32::MAX), None);
    }

    #[test]
    fn a_socket_pair_peer_is_this_process() {
        let (left, _right) = std::os::unix::net::UnixStream::pair().unwrap();
        assert_eq!(peer_pid(&left), Some(std::process::id()));
    }

    #[test]
    fn staging_copies_verifies_and_reuses() {
        let dir = std::env::temp_dir().join(format!("cmux-rh-stage-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let shipped = dir.join(EXECUTABLE);
        std::fs::write(&shipped, b"#!/bin/sh\nexit 0\n").unwrap();
        // SAFETY: single-threaded test setup of a variable only this crate reads.
        unsafe { std::env::set_var("CMUX_REMOTE_HOST_BIN", &shipped) };
        let first = stage(&dir.join("state")).unwrap();
        assert_eq!(first.digest, sha256_file(&shipped).unwrap());
        assert_eq!(std::fs::read(&first.executable).unwrap(), std::fs::read(&shipped).unwrap());
        let again = stage(&dir.join("state")).unwrap();
        assert_eq!(again.executable, first.executable);
        std::fs::write(shipped.with_file_name("cmux-remote-host.sha256"), "0".repeat(64)).unwrap();
        assert!(stage(&dir.join("state")).is_err(), "a pinned digest that differs refuses the copy");
        // SAFETY: as above.
        unsafe { std::env::remove_var("CMUX_REMOTE_HOST_BIN") };
        let _ = std::fs::remove_dir_all(&dir);
    }
}
