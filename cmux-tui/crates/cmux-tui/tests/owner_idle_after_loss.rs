//! An orphaned `server ensure` owner (a killed probe's, as on aws-m4pro-5)
//! must not spin. Its clients going away mid-request leaves it idle; on
//! macOS, its executable's volume being force-removed makes it exit at once
//! (headless/exe_revoke_exit.rs) instead of faulting on its own code pages
//! at about 100% system time per thread, as the two leaked owners did.

#![cfg(any(target_vendor = "apple", target_os = "linux"))]

use std::fs;
use std::io::Write;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// How long an owner may take to exit once its executable is revoked. The
/// watcher wakes on the kernel's revoke event and exits without running the
/// owner's teardown, so it takes milliseconds; 10 s is `ENSURE_DEADLINE` and
/// leaves room for a loaded runner. Without the watcher it never exits.
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
fn an_orphaned_owner_stays_idle_after_its_clients_go_away() {
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

#[cfg(target_os = "macos")]
#[test]
fn an_owner_exits_when_its_executables_volume_is_removed() {
    let root = scratch("volume");
    fs::create_dir_all(&root).unwrap();
    let source = PathBuf::from(env!("CARGO_BIN_EXE_cmux-tui"));
    let megabytes = fs::metadata(&source).unwrap().len() / (1 << 20) * 3 / 2 + 64;
    let (image, volume) = (root.join("owner.dmg"), root.join("volume"));
    let hdiutil = |args: &[&str]| {
        let output = Command::new("hdiutil").args(args).output().unwrap();
        assert!(output.status.success(), "hdiutil {args:?}: {output:?}");
    };
    let image_arg = image.to_str().unwrap();
    let size = format!("{megabytes}m");
    hdiutil(&["create", "-quiet", "-size", &size, "-fs", "HFS+", "-volname", "oil", image_arg]);
    hdiutil(&["attach", "-quiet", "-nobrowse", "-mountpoint", volume.to_str().unwrap(), image_arg]);
    fs::create_dir_all(volume.join("cwd")).unwrap();
    let bin = volume.join("cmux-tui");
    fs::copy(&source, &bin).unwrap();
    let owner = Owner::ensure(&root.join("owner"), &bin, &volume.join("cwd"));
    let before = cpu(owner.pid).expect("the owner is running");
    // Force-remove the volume under the running owner, as the runner's
    // instance-store volume vanished under the leaked owners.
    hdiutil(&["detach", "-force", volume.to_str().unwrap()]);
    // A client makes the owner run code it has not run yet (the leaked
    // owners spun once a thread did).
    let _client = UnixStream::connect(&owner.socket).map(|mut stream| {
        let _ = stream.write_all(b"{\"id\":1,\"cmd\":\"identify\"}\n");
        stream
    });
    let deadline = Instant::now() + EXIT_BOUND;
    let mut used = Duration::ZERO;
    while let Some(now) = cpu(owner.pid) {
        used = now.saturating_sub(before);
        assert!(
            Instant::now() < deadline,
            "the owner outlived its executable's volume by {EXIT_BOUND:?}, using {used:?} of CPU"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(used <= SPIN_LIMIT, "the owner used {used:?} of CPU before it exited");
}
