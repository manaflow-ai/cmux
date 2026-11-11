//! macOS parts of cmux Remote: the staged copy of the signed bundle, the
//! responsibility-disclaimed spawn, and process identity checks.

use cmux_process::{Command, Stdio};
use std::io::{BufRead, BufReader, Read, Write};
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
    pub(super) app: PathBuf,
    pub(super) executable: PathBuf,
    /// Content digest of the signed bundle (its executable and seal).
    pub(super) digest: String,
    /// A verified copy of a new build waiting in `state/app/next` to replace
    /// `current` ([`promote`]) once no host runs from it.
    pub(super) next: Option<PathBuf>,
}

/// The app's embedded bundle: `CMUX_REMOTE_APP`, else `Contents/Library`
/// of the app whose `Contents/Resources/bin` holds this daemon.
fn embedded() -> Result<PathBuf, String> {
    if let Some(path) = std::env::var_os("CMUX_REMOTE_APP").map(PathBuf::from) {
        return path
            .is_dir()
            .then_some(path)
            .ok_or_else(|| "CMUX_REMOTE_APP is not a bundle".into());
    }
    let exe = std::env::current_exe().map_err(|error| format!("{error}"))?;
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

fn digest_of(app: &Path) -> Result<String, String> {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    for part in [
        "Contents/MacOS/cmux-remote",
        "Contents/_CodeSignature/CodeResources",
        "Contents/Info.plist",
    ] {
        let mut file =
            std::fs::File::open(app.join(part)).map_err(|error| format!("{part}: {error}"))?;
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

/// The verified copy of the embedded bundle that runs, always at one path,
/// `state/app/current/<bundle>`: macOS keys the person's screen-capture
/// approvals (and other per-app records) by the app's path, so a path per
/// build asked them again after every update. A new build is copied and
/// verified into `state/app/next/` first; [`promote`] moves it to `current`
/// only when no host runs from `current` (the caller drains or never adopted
/// one), so a busy host of the previous build keeps its bundle until it
/// stops. Never followed through a symlink.
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
    let current = root.join(CURRENT);
    let app = current.join(name);
    let executable = app.join("Contents/MacOS").join(EXECUTABLE);
    if slot_holds(&current, name, &digest) {
        let _ = std::fs::remove_dir_all(root.join(NEXT));
        return Ok(Staged { app, executable, digest, next: None });
    }
    let next = root.join(NEXT);
    if !slot_holds(&next, name, &digest) {
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
            (digest_of(&copy)? == digest)
                .then_some(())
                .ok_or("the copy differs from the embedded bundle".into())
        }) {
            let _ = std::fs::remove_dir_all(&temporary);
            return Err(error);
        }
        std::fs::write(temporary.join(".verified"), &digest).map_err(|error| format!("{error}"))?;
        let _ = std::fs::remove_dir_all(&next);
        std::fs::rename(&temporary, &next).map_err(|error| format!("{error}"))?;
    }
    Ok(Staged { app, executable, digest, next: Some(next) })
}

/// The slot that runs, and the one a new build waits in.
const CURRENT: &str = "current";
const NEXT: &str = "next";

/// Whether `slot` holds a verified copy of the build with `digest`.
fn slot_holds(slot: &Path, name: &std::ffi::OsStr, digest: &str) -> bool {
    std::fs::read_to_string(slot.join(".verified")).is_ok_and(|text| text.trim() == digest)
        && digest_of(&slot.join(name)).is_ok_and(|copy| copy == digest)
}

/// Moves a waiting new build into `current` and removes copies of earlier
/// layouts. Call it only when no host runs from any staged copy: right
/// before starting one.
pub(super) fn promote(staged: &Staged) -> Result<(), String> {
    let Some(next) = &staged.next else {
        if let Some(root) = staged.app.parent().and_then(Path::parent) {
            prune(root);
        }
        return Ok(());
    };
    let root = next.parent().ok_or("bad staging path")?;
    let current = root.join(CURRENT);
    let previous = root.join(format!(".previous-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&previous);
    if current.exists() {
        std::fs::rename(&current, &previous).map_err(|error| format!("{error}"))?;
    }
    if let Err(error) = std::fs::rename(next, &current) {
        let _ = std::fs::rename(&previous, &current);
        return Err(format!("{error}"));
    }
    let _ = std::fs::remove_dir_all(&previous);
    prune(root);
    Ok(())
}

/// Removes copies an earlier layout made (one folder per build digest) and
/// any interrupted staging; keeps `current` and `next`.
fn prune(root: &Path) {
    let Ok(entries) = std::fs::read_dir(root) else { return };
    for path in entries.filter_map(Result::ok).map(|entry| entry.path()) {
        let keep = path.file_name().is_some_and(|name| name == CURRENT || name == NEXT);
        // A staging folder of a live daemon is its own; only dead ones go.
        let live_staging = path
            .file_name()
            .and_then(|name| name.to_str())
            .and_then(|name| name.strip_prefix(".staging-"))
            .and_then(|pid| pid.parse::<i32>().ok())
            // SAFETY: kill with signal 0 only checks that the process exists.
            .is_some_and(|pid| unsafe { libc::kill(pid, 0) } == 0);
        if !keep && !live_staging {
            let _ = std::fs::remove_dir_all(path);
        }
    }
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
    let mut length = std::mem::size_of::<libc::pid_t>() as libc::socklen_t;
    // SAFETY: getsockopt into a pid_t.
    let ok = unsafe {
        libc::getsockopt(stream.as_raw_fd(), 0, LOCAL_PEERPID, (&raw mut pid).cast(), &mut length)
    } == 0;
    ok.then_some(pid as u32)
}

#[cfg(test)]
mod staging_tests {
    use super::*;

    fn dir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("cu-stage-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn slot(root: &Path, name: &str, marker: &str) {
        let s = root.join(name);
        std::fs::create_dir_all(s.join("cmux Remote (dev).app")).unwrap();
        std::fs::write(s.join(".verified"), marker).unwrap();
    }

    #[test]
    fn a_new_build_moves_into_the_one_stable_path_and_old_layouts_go() {
        let root = dir("promote");
        slot(&root, CURRENT, "old");
        slot(&root, NEXT, "new");
        slot(&root, "0123456789abcdef", "older layout");
        let app = root.join(CURRENT).join("cmux Remote (dev).app");
        let staged = Staged {
            executable: app.join("Contents/MacOS/cmux-remote"),
            app: app.clone(),
            digest: "new".into(),
            next: Some(root.join(NEXT)),
        };
        promote(&staged).unwrap();
        assert_eq!(std::fs::read_to_string(root.join(CURRENT).join(".verified")).unwrap(), "new");
        assert!(!root.join(NEXT).exists());
        assert!(!root.join("0123456789abcdef").exists());
        assert!(app.exists(), "the app keeps its path across builds");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn nothing_waiting_keeps_current_and_a_live_staging_folder() {
        let root = dir("keep");
        slot(&root, CURRENT, "same");
        let live = root.join(format!(".staging-{}", std::process::id()));
        std::fs::create_dir_all(&live).unwrap();
        let app = root.join(CURRENT).join("cmux Remote (dev).app");
        let staged = Staged {
            executable: app.join("Contents/MacOS/cmux-remote"),
            app,
            digest: "same".into(),
            next: None,
        };
        promote(&staged).unwrap();
        assert_eq!(std::fs::read_to_string(root.join(CURRENT).join(".verified")).unwrap(), "same");
        assert!(live.exists());
        let _ = std::fs::remove_dir_all(&root);
    }
}
