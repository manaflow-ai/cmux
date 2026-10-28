//! An orphaned `server ensure` owner (a killed probe's, as on aws-m4pro-5)
//! must not spin. Its clients going away mid-request leaves it idle; on
//! macOS, its executable's volume being force-removed ends it at once
//! (headless.rs `fatal_faults_end_the_owner`) instead of leaving its threads
//! faulting on their own code pages at about 100% system time each, as the
//! two leaked owners did.

#![cfg(any(target_vendor = "apple", target_os = "linux"))]

use std::fs;
use std::io::Write;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// How long an owner may take to exit once its executable's volume is gone.
/// The kernel ends it on the first fault on a page it can no longer read,
/// within milliseconds of a thread running code it had not run; 10 s is
/// `ENSURE_DEADLINE` and leaves room for a loaded runner. With a fault
/// handler installed it never exits.
#[cfg(target_os = "macos")]
const EXIT_BOUND: Duration = Duration::from_secs(10);

/// CPU an owner may use in a window where it should be idle or exiting. An
/// idle owner uses next to nothing (idle_wakeups.rs); a spinning thread uses
/// a full second per second. Linux `ps` counts whole seconds.
const SPIN_LIMIT: Duration = Duration::from_secs(1);

/// An owner this test started with `server ensure`, from `bin` in `cwd`.
struct Owner {
    root: PathBuf,
    pid: u32,
    started_ms: Option<u64>,
    socket: PathBuf,
}

impl Owner {
    fn ensure(root: &Path, bin: &Path, cwd: &Path) -> Self {
        fs::create_dir_all(root.join("home")).unwrap();
        fs::create_dir_all(root.join("state")).unwrap();
        let output = Command::new(bin)
            .args(["--session", "cdc-idle", "--json", "server", "ensure"])
            .args(["--terminal-reap-grace-seconds", "30"])
            .current_dir(cwd)
            .env_clear()
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
            .env("HOME", root.join("home"))
            .env("TMPDIR", root)
            .env("CMUX_TUI_STATE_DIR", root.join("state"))
            .env("CMUX_TUI_CONFIG", root.join("home/no-config.toml"))
            .output()
            .unwrap();
        let stdout = String::from_utf8_lossy(&output.stdout);
        let line = stdout.lines().rev().find(|line| line.trim_start().starts_with('{'));
        let endpoint: serde_json::Value =
            line.and_then(|line| serde_json::from_str(line).ok()).unwrap_or_else(|| {
                panic!("ensure: {stdout} {}", String::from_utf8_lossy(&output.stderr))
            });
        let pid = endpoint["pid"].as_u64().and_then(|pid| u32::try_from(pid).ok()).unwrap();
        let started_ms = cmux_tui_core::server::Starter::current(pid).map(|it| it.started_ms);
        let socket = PathBuf::from(endpoint["socket"].as_str().unwrap());
        Self { root: root.to_path_buf(), pid, started_ms, socket }
    }
}

impl Drop for Owner {
    fn drop(&mut self) {
        // Only this test's owner, and only while the pid still names it.
        let current = cmux_tui_core::server::Starter::current(self.pid).map(|it| it.started_ms);
        if current.is_some() && current == self.started_ms {
            // SAFETY: signals the owner this test started.
            unsafe { libc::kill(self.pid as libc::pid_t, libc::SIGKILL) };
        }
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn scratch(name: &str) -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() % 1_000_000;
    PathBuf::from(format!("/tmp/oil-{name}-{}-{stamp}", std::process::id()))
}

/// The CPU time `ps` reports for `pid`; `None` once it is gone (a zombie
/// counts as gone).
fn cpu(pid: u32) -> Option<Duration> {
    let output = Command::new("ps").args(["-o", "stat=,time=", "-p", &pid.to_string()]).output();
    let text = String::from_utf8_lossy(&output.ok()?.stdout).to_string();
    let mut fields = text.split_whitespace();
    if fields.next()?.starts_with('Z') {
        return None;
    }
    // `[[dd-]hh:]mm:ss[.ff]` (macOS prints fractions, Linux whole seconds).
    let time = fields.next()?;
    let (days, clock) = time.split_once('-').unwrap_or(("0", time));
    let clock =
        clock.split(':').fold(0.0, |total, part| total * 60.0 + part.parse().unwrap_or(0.0));
    Some(Duration::from_secs_f64(days.parse::<f64>().unwrap_or(0.0) * 86_400.0 + clock))
}

#[test]
fn orphaned_owner_stays_idle_after_its_clients_go_away() {
    let root = scratch("peers");
    fs::create_dir_all(&root).unwrap();
    let owner = Owner::ensure(&root, Path::new(env!("CARGO_BIN_EXE_cmux-tui")), &root);
    // Clients cut off mid-conversation, as a killed probe's were: waiting
    // on a stream, answered, a half-written line, silent.
    let requests: [&[u8]; 6] = [
        b"{\"id\":1,\"cmd\":\"subscribe\"}\n",
        b"{\"id\":1,\"cmd\":\"identify\"}\n",
        b"{\"id\":1,\"cmd\":\"ide",
        b"",
        b"{\"id\":1,\"cmd\":\"wait-for\",\"name\":\"never\"}\n",
        b"{\"id\":1,\"cmd\":\"events\"}\n",
    ];
    let clients: Vec<UnixStream> = requests
        .iter()
        .chain(requests.iter())
        .map(|request| {
            let mut stream = UnixStream::connect(&owner.socket).unwrap();
            stream.write_all(request).unwrap();
            stream
        })
        .collect();
    std::thread::sleep(Duration::from_secs(1));
    drop(clients);
    std::thread::sleep(Duration::from_millis(500));
    let before = cpu(owner.pid).expect("the owner is running");
    std::thread::sleep(Duration::from_secs(5));
    let used = cpu(owner.pid).expect("the owner outlives its clients").saturating_sub(before);
    assert!(used <= SPIN_LIMIT, "the owner used {used:?} of CPU in 5 s after its clients left");
}

/// A disk image this test attached at `volume`; dropped after the owner
/// (declared before it), it detaches the volume if it is still attached and
/// removes the image and its scratch directory.
#[cfg(target_os = "macos")]
struct Volume {
    root: PathBuf,
    mount: PathBuf,
}

#[cfg(target_os = "macos")]
impl Volume {
    fn attach(root: &Path, megabytes: u64) -> Self {
        fs::create_dir_all(root).unwrap();
        let image = root.join("owner.dmg");
        let volume = Self { root: root.to_path_buf(), mount: root.join("volume") };
        let size = format!("{megabytes}m");
        let image = image.to_str().unwrap();
        hdiutil(&["create", "-quiet", "-size", &size, "-fs", "HFS+", "-volname", "oil", image]);
        hdiutil(&["attach", "-quiet", "-nobrowse", "-mountpoint", volume.path(), image]);
        volume
    }

    fn path(&self) -> &str {
        self.mount.to_str().unwrap()
    }
}

#[cfg(target_os = "macos")]
impl Drop for Volume {
    fn drop(&mut self) {
        if self.mount.join("cwd").exists() {
            let _ = Command::new("hdiutil").args(["detach", "-force", self.path()]).output();
        }
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[cfg(target_os = "macos")]
fn hdiutil(args: &[&str]) {
    let output = Command::new("hdiutil").args(args).output().unwrap();
    assert!(output.status.success(), "hdiutil {args:?}: {output:?}");
}

#[cfg(target_os = "macos")]
#[test]
fn orphaned_owner_exits_when_its_executables_volume_is_removed() {
    let source = PathBuf::from(env!("CARGO_BIN_EXE_cmux-tui"));
    let megabytes = fs::metadata(&source).unwrap().len() / (1 << 20) * 3 / 2 + 64;
    let volume = Volume::attach(&scratch("volume"), megabytes);
    let mount = PathBuf::from(volume.path());
    fs::create_dir_all(mount.join("cwd")).unwrap();
    let bin = mount.join("cmux-tui");
    fs::copy(&source, &bin).unwrap();
    let owner = Owner::ensure(&scratch("volume-owner"), &bin, &mount.join("cwd"));
    let before = cpu(owner.pid).expect("the owner is running");
    // Force-remove the volume under the running owner, as the runner's
    // instance-store volume vanished under the leaked owners.
    hdiutil(&["detach", "-force", volume.path()]);
    // A client makes the owner run code it has not run yet (the leaked
    // owners spun once a thread did).
    let _client = UnixStream::connect(&owner.socket).map(|mut stream| {
        let _ = stream.write_all(b"{\"id\":1,\"cmd\":\"identify\"}\n");
        stream
    });
    let deadline = std::time::Instant::now() + EXIT_BOUND;
    let mut used = Duration::ZERO;
    while let Some(now) = cpu(owner.pid) {
        used = now.saturating_sub(before);
        assert!(
            std::time::Instant::now() < deadline,
            "the owner outlived its executable's volume by {EXIT_BOUND:?}, using {used:?} of CPU"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(used <= SPIN_LIMIT, "the owner used {used:?} of CPU before it exited");
}
