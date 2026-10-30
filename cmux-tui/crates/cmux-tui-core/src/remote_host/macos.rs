//! macOS parts of cmux Remote: the staged copy of the signed bundle, the
//! responsibility-disclaimed spawn, and process identity checks.

use std::io::{BufRead, BufReader, Read, Write};
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use cmux_process::{Command, Stdio};
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
    pub(super) app: PathBuf,
    pub(super) executable: PathBuf,
    /// Content digest of the signed bundle (its executable and seal).
    pub(super) digest: String,
}

/// The app's embedded bundle: `CMUX_REMOTE_APP`, else `Contents/Library`
/// of the app whose `Contents/Resources/bin` holds this daemon.
fn embedded() -> Result<PathBuf, String> {
    if let Some(path) = std::env::var_os("CMUX_REMOTE_APP").map(PathBuf::from) {
        return path.is_dir().then_some(path).ok_or_else(|| "CMUX_REMOTE_APP is not a bundle".into());
    }
    let exe = std::env::current_exe().map_err(|error| format!("{error}"))?;
    let contents = exe.parent().and_then(Path::parent).and_then(Path::parent)
        .ok_or("the daemon is not inside an app bundle")?;
    BUNDLE_NAMES
        .iter()
        .map(|name| contents.join("Library").join(name))
        .find(|path| path.join("Contents/MacOS").join(EXECUTABLE).is_file())
        .ok_or_else(|| "this cmux build has no cmux Remote".into())
}

fn digest_of(app: &Path) -> Result<String, String> {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    for part in ["Contents/MacOS/cmux-remote", "Contents/_CodeSignature/CodeResources", "Contents/Info.plist"] {
        let mut file = std::fs::File::open(app.join(part)).map_err(|error| format!("{part}: {error}"))?;
        let mut buffer = vec![0_u8; 1 << 20];
        loop {
            let count = file.read(&mut buffer).map_err(|error| format!("{part}: {error}"))?;
            if count == 0 {
                break;
            }
            hasher.update(&buffer[..count]);
        }
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn bundle_id(app: &Path) -> Option<String> {
    let output = Command::new("/usr/bin/plutil")
        .args(["-extract", "CFBundleIdentifier", "raw", "-o", "-"])
        .arg(app.join("Contents/Info.plist"))
        .stdin(Stdio::null())
        .output()
        .ok()?;
    output.status.success().then(|| String::from_utf8_lossy(&output.stdout).trim().to_string())
}

/// Whether `app` is a valid, sealed cmux Remote of cmux's team.
fn verify(app: &Path) -> Result<(), String> {
    let id = bundle_id(app).ok_or("the bundle has no identifier")?;
    if !BUNDLE_IDS.contains(&id.as_str()) {
        return Err(format!("{id} is not cmux Remote"));
    }
    let requirement = format!(
        "=identifier \"{id}\" and anchor apple generic and certificate leaf[subject.OU] = \"{TEAM}\""
    );
    let output = Command::new("/usr/bin/codesign")
        .args(["--verify", "--strict", "--deep", "-R"])
        .arg(&requirement)
        .arg(app)
        .stdin(Stdio::null())
        .output()
        .map_err(|error| format!("codesign: {error}"))?;
    if output.status.success() {
        Ok(())
    } else {
        Err(format!("signature: {}", String::from_utf8_lossy(&output.stderr).trim()))
    }
}

/// A verified copy of the embedded bundle under `state/app/<digest>/`,
/// reused while the embedded bundle is the same; never followed through a
/// symlink. The two newest copies are kept (a host of the previous build may
/// still run from one until it drains).
pub(super) fn stage(state: &Path) -> Result<Staged, String> {
    use std::os::unix::fs::PermissionsExt;
    let source = embedded()?;
    let digest = digest_of(&source)?;
    let root = state.join("app");
    for dir in [state, root.as_path()] {
        std::fs::create_dir_all(dir).map_err(|error| format!("{}: {error}", dir.display()))?;
        let meta = std::fs::symlink_metadata(dir).map_err(|error| format!("{error}"))?;
        if !meta.is_dir() {
            return Err(format!("{} is not a directory", dir.display()));
        }
        let _ = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700));
    }
    let name = source.file_name().ok_or("bad bundle name")?;
    let slot = root.join(&digest[..16]);
    let app = slot.join(name);
    let marker = slot.join(".verified");
    let ready = std::fs::read_to_string(&marker).is_ok_and(|text| text.trim() == digest)
        && digest_of(&app).is_ok_and(|copy| copy == digest);
    if !ready {
        let temporary = root.join(format!(".staging-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&temporary);
        std::fs::create_dir_all(&temporary).map_err(|error| format!("{error}"))?;
        let copy = temporary.join(name);
        let status = Command::new("/usr/bin/ditto")
            .args(["--norsrc", "--noqtn"])
            .arg(&source)
            .arg(&copy)
            .stdin(Stdio::null())
            .status()
            .map_err(|error| format!("ditto: {error}"))?;
        if !status.success() {
            let _ = std::fs::remove_dir_all(&temporary);
            return Err("cannot copy cmux Remote out of the app".into());
        }
        if let Err(error) = verify(&copy).and_then(|()| {
            (digest_of(&copy)? == digest).then_some(()).ok_or("the copy differs from the embedded bundle".into())
        }) {
            let _ = std::fs::remove_dir_all(&temporary);
            return Err(error);
        }
        std::fs::write(temporary.join(".verified"), &digest).map_err(|error| format!("{error}"))?;
        let _ = std::fs::remove_dir_all(&slot);
        std::fs::rename(&temporary, &slot).map_err(|error| format!("{error}"))?;
    }
    prune(&root, &slot);
    let executable = app.join("Contents/MacOS").join(EXECUTABLE);
    Ok(Staged { app, executable, digest })
}

/// Keeps `current` and the newest other copy; removes the rest.
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

/// Starts the host with responsibility disclaimed (its own responsible
/// process: macOS checks its grants as cmux Remote's), in its own session,
/// with the bootstrap line on fd 3, and waits for its `ready` line. Without
/// the disclaim it does not start: the grants would belong to cmux.
pub(super) fn spawn_host(staged: &Staged, paths: &Paths, bootstrap: &Value, ready_timeout: Duration) -> Result<u32, String> {
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
    let (bootstrap_read, bootstrap_write) = std::io::pipe().map_err(|error| format!("pipe: {error}"))?;
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
    let mut child = command.spawn().map_err(|error| format!("cmux Remote did not start: {error}"))?;
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
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
    // SAFETY: proc_pidinfo into a correctly sized buffer.
    let read = unsafe {
        libc::proc_pidinfo(pid as libc::c_int, libc::PROC_PIDTBSDINFO, 0, (&raw mut info).cast(), size)
    };
    (read == size).then_some((info.pbi_start_tvsec, info.pbi_start_tvusec))
}

/// The pid of a connected Unix socket's peer.
pub(super) fn peer_pid(stream: &std::os::unix::net::UnixStream) -> Option<u32> {
    let mut pid: libc::pid_t = 0;
    let mut length = std::mem::size_of::<libc::pid_t>() as libc::socklen_t;
    // SAFETY: getsockopt into a pid_t.
    let ok = unsafe {
        libc::getsockopt(stream.as_raw_fd(), 0, LOCAL_PEERPID, (&raw mut pid).cast(), &mut length)
    } == 0;
    ok.then_some(pid as u32)
}
