//! macOS parts of cmux Remote: the staged copy of the signed bundle, the
//! responsibility-disclaimed spawn, and process identity checks.

use cmux_process::{Command, Stdio};
use cmux_signed_bundle::computer_use;
use std::io::{BufRead, BufReader, Write};
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::Value;

use super::Paths;

const LOCAL_PEERPID: libc::c_int = 0x002;

/// The copy that runs.
pub(super) struct Staged {
    pub(super) executable: PathBuf,
    /// Content digest of the signed bundle (its executables, seal and Info.plist).
    pub(super) digest: String,
}

/// The Computer Use helper that carries the supervisor (`find_helper`).
pub(super) fn embedded() -> Result<PathBuf, String> {
    let env = std::env::var_os("CMUX_REMOTE_APP").map(PathBuf::from);
    let own = cmux_link::app_caller::own_executable();
    super::find_helper(env, own.as_deref().ok())
}

pub(super) fn bundle_id(app: &Path) -> Option<String> {
    cmux_signed_bundle::bundle_id(app)
}

/// A verified copy of the Computer Use helper, the one the acpmux share host
/// runs too (`cmux_signed_bundle::computer_use::stage`: one root per helper id
/// under `~/Library/Application Support/cmux-next/screen-sharing/<id>/daemon`,
/// one digest over its executables, seal and Info.plist, one stager at a
/// time). Checked against the Release helper's pinned Developer ID
/// requirement, or the DEV helper's identifier and cmux's team, so its grants
/// hold across builds and an ad-hoc copy never runs. Reused while the helper
/// is the same; never followed through a symlink; the copies used last are
/// kept (a host of the previous build may still run from one until it drains).
pub(super) fn stage() -> Result<Staged, String> {
    let source = embedded()?;
    let home = crate::platform::home_dir().ok_or("no home folder")?;
    let staged = computer_use::stage(&source, &home)?;
    let executable = staged.executable(computer_use::SUPERVISOR);
    Ok(Staged { executable, digest: staged.digest })
}

/// Starts the host with responsibility disclaimed (its own responsible
/// process: macOS checks its grants as cmux Remote's), in its own session,
/// with the bootstrap line on fd 3, and waits for its `ready` line. Without
/// the disclaim it does not start: the grants would belong to cmux.
pub(super) fn spawn_host(
    staged: &Staged,
    paths: &Paths,
    bootstrap: &Value,
    ready_timeout: Duration,
) -> Result<u32, String> {
    let worker_state = paths.state.join("worker");
    std::fs::create_dir_all(&paths.runtime).map_err(|error| format!("{error}"))?;
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&paths.runtime, std::fs::Permissions::from_mode(0o700));
    }
    let log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(paths.log())
        .map_err(|error| format!("{}: {error}", paths.log().display()))?;
    let (bootstrap_read, bootstrap_write) =
        std::io::pipe().map_err(|error| format!("pipe: {error}"))?;
    let mut command = Command::new(&staged.executable);
    command
        .args(["host", "--layout-dir"])
        .arg(&paths.runtime)
        .arg("--state-dir")
        .arg(&worker_state)
        .arg("--scope")
        .arg(&paths.scope)
        .env_clear()
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::from(log))
        .new_session()
        .disclaim_responsibility();
    if let Some(home) = crate::platform::home_dir() {
        command.env("HOME", home);
    }
    for name in ["USER", "TMPDIR", "LANG"] {
        if let Some(value) = std::env::var_os(name) {
            command.env(name, value);
        }
    }
    use std::os::fd::AsFd;
    command.inherit_fd(bootstrap_read.as_fd(), 3).map_err(|error| format!("{error}"))?;
    let mut child =
        command.spawn().map_err(|error| format!("cmux Remote did not start: {error}"))?;
    child.detach("cmux Remote runs in its own session and outlives this daemon; launchd reaps it");
    drop(bootstrap_read);
    let pid = child.id();
    let stdout = child.stdout.take().ok_or("cmux Remote has no stdout")?;
    // Reaps the host whenever it exits while this daemon lives (its own
    // session survives this daemon; launchd reaps it then).
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
        return Err(format!("cmux Remote did not report ready (see {})", paths.log().display()));
    }
    Ok(pid)
}

/// A live process's start time (seconds, microseconds), or None.
pub(super) fn process_start(pid: u32) -> Option<(u64, u64)> {
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = size_of::<libc::proc_bsdinfo>() as libc::c_int;
    // SAFETY: proc_pidinfo into a correctly sized buffer.
    let read = unsafe {
        libc::proc_pidinfo(
            pid as libc::c_int,
            libc::PROC_PIDTBSDINFO,
            0,
            (&raw mut info).cast(),
            size,
        )
    };
    (read == size).then_some((info.pbi_start_tvsec, info.pbi_start_tvusec))
}

/// The pid of a connected Unix socket's peer.
pub(super) fn peer_pid(stream: &std::os::unix::net::UnixStream) -> Option<u32> {
    let mut pid: libc::pid_t = 0;
    let mut length = size_of::<libc::pid_t>() as libc::socklen_t;
    // SAFETY: getsockopt into a pid_t.
    let ok = unsafe {
        libc::getsockopt(stream.as_raw_fd(), 0, LOCAL_PEERPID, (&raw mut pid).cast(), &mut length)
    } == 0;
    ok.then_some(pid as u32)
}
