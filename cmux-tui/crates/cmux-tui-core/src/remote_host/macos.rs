//! macOS parts of cmux Remote: the staged copy of the signed bundle, the
//! responsibility-disclaimed spawn, and process identity checks.

use cmux_process::{Command, Stdio};
use std::io::{BufRead, BufReader, Write};
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::Value;

use super::Paths;

/// cmux's signing team: the staged copy must carry it (Developer ID in
/// Release, the pinned Apple Development signature in DEV builds), so its
/// grants hold across builds and an ad-hoc copy never runs.
const TEAM: &str = "7WLXT3NR37";
const BUNDLE_IDS: [&str; 2] = ["com.cmuxterm.remote", "com.cmuxterm.remote.dev"];
const BUNDLE_NAMES: [&str; 2] = ["cmux Remote.app", "cmux Remote (dev).app"];
const EXECUTABLE: &str = "cmux-remote";
const LOCAL_PEERPID: libc::c_int = 0x002;

/// The copy that runs.
pub(super) struct Staged {
    pub(super) executable: PathBuf,
    /// Content digest of the signed bundle (its executable and seal).
    pub(super) digest: String,
}

/// The app's embedded bundle: `CMUX_REMOTE_APP`, else `Contents/Library`
/// of the app whose `Contents/Resources/bin` holds this daemon.
pub(super) fn embedded() -> Result<PathBuf, String> {
    if let Some(path) = std::env::var_os("CMUX_REMOTE_APP").map(PathBuf::from) {
        return path
            .is_dir()
            .then_some(path)
            .ok_or_else(|| "CMUX_REMOTE_APP is not a bundle".into());
    }
    // The file itself, never the link it was started by (`~/.local/bin/acpmux`).
    let exe = cmux_link::app_caller::own_executable()?;
    let contents = exe
        .parent()
        .and_then(Path::parent)
        .and_then(Path::parent)
        .ok_or("the daemon is not inside an app bundle")?;
    BUNDLE_NAMES
        .iter()
        .map(|name| contents.join("Library").join(name))
        .find(|path| path.join("Contents/MacOS").join(EXECUTABLE).is_file())
        .ok_or_else(|| "this cmux build has no cmux Remote".into())
}

pub(super) fn bundle_id(app: &Path) -> Option<String> {
    cmux_signed_bundle::bundle_id(app)
}

/// Whether `app` is a valid, sealed cmux Remote of cmux's team.
fn verify(app: &Path) -> Result<(), String> {
    let id = bundle_id(app).ok_or("the bundle has no identifier")?;
    if !BUNDLE_IDS.contains(&id.as_str()) {
        return Err(format!("{id} is not cmux Remote"));
    }
    cmux_signed_bundle::verify(app, &cmux_signed_bundle::team_requirement(&id, TEAM))
}

/// A verified copy of the embedded bundle under `state/app/<digest>/`,
/// reused while the embedded bundle is the same; never followed through a
/// symlink. The two newest copies are kept (a host of the previous build may
/// still run from one until it drains). The staging itself is
/// `cmux-signed-bundle`'s, shared with the acpmux share host's helper.
pub(super) fn stage(state: &Path) -> Result<Staged, String> {
    let source = embedded()?;
    cmux_signed_bundle::private_dir(state)?;
    let parts = cmux_signed_bundle::digest_parts(EXECUTABLE);
    let staged = cmux_signed_bundle::stage(&source, &state.join("app"), &parts, verify)?;
    let executable = staged.executable(EXECUTABLE);
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
