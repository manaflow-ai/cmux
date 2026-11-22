//! An orphaned `server ensure` owner (a killed probe's, as on aws-m4pro-5)
//! must not spin. Its clients going away mid-request leaves it idle; on
//! macOS, its executable's volume being force-removed ends it at once
//! (headless.rs `fatal_faults_end_the_owner`) instead of leaving its threads
//! faulting on their own code pages at about 100% system time each, as the
//! two leaked owners did; and once its socket and state directory are
//! removed with no client connected, it stops (headless/lost_paths.rs)
//! instead of running for days where nothing can reach it.

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

/// How long an owner may take to stop once its socket and state directory
/// are gone and its last client left: well inside the 30 s reap grace it
/// was started with. The stop is event-driven (a vnode or inotify watch and
/// the client registry), so it takes milliseconds; the rest is room for a
/// loaded runner.
const LOSS_EXIT_BOUND: Duration = Duration::from_secs(10);

/// CPU an owner may use in a window where it should be idle or exiting. An
/// idle owner uses next to nothing (idle_wakeups.rs); a spinning thread uses
/// a full second per second. Linux `ps` counts whole seconds.
const SPIN_LIMIT: Duration = Duration::from_secs(1);

/// An owner this test started with `server ensure`, from `bin` in `cwd`.
/// Dropping it stops the session (also when the launch half failed), kills
/// the owner by its verified identity if it still runs, and waits until it
/// is gone before removing its scratch directory.
struct Owner {
    root: PathBuf,
    identity: Option<(u32, u64)>,
    socket: PathBuf,
}

impl Owner {
    fn ensure(root: &Path, bin: &Path, cwd: &Path) -> Self {
        fs::create_dir_all(root.join("home")).unwrap();
        fs::create_dir_all(root.join("state")).unwrap();
        // The guard exists before the launch, so a failure below still stops
        // whatever `ensure` started.
        let mut owner = Self { root: root.to_path_buf(), identity: None, socket: PathBuf::new() };
        let output = owner
            .command(bin)
            .args(["server", "ensure", "--terminal-reap-grace-seconds", "30"])
            .current_dir(cwd)
            .output()
            .unwrap();
        let stdout = String::from_utf8_lossy(&output.stdout);
        let line = stdout.lines().rev().find(|line| line.trim_start().starts_with('{'));
        let endpoint: serde_json::Value =
            line.and_then(|line| serde_json::from_str(line).ok()).unwrap_or_else(|| {
                panic!("ensure: {stdout} {}", String::from_utf8_lossy(&output.stderr))
            });
        let pid = endpoint["pid"].as_u64().and_then(|pid| u32::try_from(pid).ok()).unwrap();
        let started = cmux_tui_core::server::Starter::current(pid)
            .unwrap_or_else(|| panic!("no start time for the owner {pid}"));
        owner.identity = Some((pid, started.started_ms));
        owner.socket = PathBuf::from(endpoint["socket"].as_str().unwrap());
        owner
    }

    fn command(&self, bin: &Path) -> Command {
        let mut command = Command::new(bin);
        command
            .args(["--session", "cdc-idle", "--json"])
            .env_clear()
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
            .env("HOME", self.root.join("home"))
            .env("TMPDIR", &self.root)
            .env("CMUX_TUI_STATE_DIR", self.root.join("state"))
            .env("CMUX_TUI_CONFIG", self.root.join("home/no-config.toml"));
        command
    }

    fn pid(&self) -> u32 {
        self.identity.unwrap().0
    }
}

impl Drop for Owner {
    fn drop(&mut self) {
        let bin = Path::new(env!("CARGO_BIN_EXE_cmux-tui"));
        let _ = self.command(bin).args(["server", "stop", "--force"]).output();
        if let Some((pid, started_ms)) = self.identity {
            let same = || {
                cmux_tui_core::server::Starter::current(pid).map(|it| it.started_ms)
                    == Some(started_ms)
            };
            if same() {
                // SAFETY: the owner this test started (pid and start time).
                unsafe { libc::kill(pid as libc::pid_t, libc::SIGKILL) };
            }
            let deadline = std::time::Instant::now() + Duration::from_secs(10);
            while same() && std::time::Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(50));
            }
            assert!(!same() || std::thread::panicking(), "the test's owner {pid} did not end");
        }
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn scratch(name: &str) -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() % 1_000_000;
    PathBuf::from(format!("/tmp/oil-{name}-{}-{stamp}", std::process::id()))
}

/// The CPU time `ps` reports for `pid`; `None` only once the process is
/// confirmed gone (no such process, or a zombie). A `ps` that cannot run or
/// prints something unreadable fails the test instead of counting as gone.
fn cpu(pid: u32) -> Option<Duration> {
    let output = Command::new("ps")
        .args(["-o", "stat=,time=", "-p", &pid.to_string()])
        .output()
        .expect("run ps");
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    let mut fields = text.split_whitespace();
    let Some(stat) = fields.next() else {
        // SAFETY: signal 0 only checks that the pid exists.
        let gone = unsafe { libc::kill(pid as libc::pid_t, 0) } == -1
            && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH);
        assert!(gone, "ps printed nothing for {pid}, which still exists: {output:?}");
        return None;
    };
    if stat.starts_with('Z') {
        return None;
    }
    // `[[dd-]hh:]mm:ss[.ff]` (macOS prints fractions, Linux whole seconds).
    let time = fields.next().unwrap_or_else(|| panic!("no time from ps: {text:?}"));
    let number = |part: &str| -> f64 {
        part.parse().unwrap_or_else(|_| panic!("unreadable ps time {time:?}"))
    };
    let (days, clock) = time.split_once('-').unwrap_or(("0", time));
    let clock = clock.split(':').fold(0.0, |total, part| total * 60.0 + number(part));
    Some(Duration::from_secs_f64(number(days) * 86_400.0 + clock))
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
    let before = cpu(owner.pid()).expect("the owner is running");
    std::thread::sleep(Duration::from_secs(5));
    let used = cpu(owner.pid()).expect("the owner outlives its clients").saturating_sub(before);
    assert!(used <= SPIN_LIMIT, "the owner used {used:?} of CPU in 5 s after its clients left");
}

/// The probe's case on aws-m4pro-5: `server ensure` started the owner
/// (passing it the readiness pipe, `--owner-ready-fd`) and exited, the
/// harness that ran it died without stopping it (no `--exit-with-pid`), and
/// the harness's temporary root, which held the owner's socket and state
/// directory, was removed later. Nothing can reach that owner again, so it
/// stops once no client is connected; while one still is, it keeps serving.
#[test]
fn orphaned_owner_exits_when_its_socket_and_state_are_removed() {
    let root = scratch("removed");
    fs::create_dir_all(&root).unwrap();
    let owner = Owner::ensure(&root, Path::new(env!("CARGO_BIN_EXE_cmux-tui")), &root);
    // An answered request proves the owner registered this client before
    // its root goes (a bare connect is only queued in the kernel).
    let mut client = UnixStream::connect(&owner.socket).unwrap();
    client.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    client.write_all(b"{\"id\":1,\"cmd\":\"identify\"}\n").unwrap();
    let answered = std::io::BufRead::lines(std::io::BufReader::new(&client))
        .map_while(Result::ok)
        .any(|line| line.contains("\"id\":1"));
    assert!(answered, "the owner never answered identify");
    let before = cpu(owner.pid()).expect("the owner is running");
    fs::remove_dir_all(&root).unwrap();
    std::thread::sleep(Duration::from_secs(2));
    assert!(
        cpu(owner.pid()).is_some(),
        "the owner stopped while a client was still connected to it"
    );
    drop(client);
    let deadline = std::time::Instant::now() + LOSS_EXIT_BOUND;
    let mut used = Duration::ZERO;
    while let Some(now) = cpu(owner.pid()) {
        used = now.saturating_sub(before);
        assert!(
            std::time::Instant::now() < deadline,
            "the owner outlived its removed socket and state directory by {LOSS_EXIT_BOUND:?} \
             after its last client left, using {used:?} of CPU"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(used <= SPIN_LIMIT, "the owner used {used:?} of CPU before it exited");
}

/// A disk image this test attached at `mount`. Dropped after the owner
/// (declared before it): it force-detaches the volume while it is still
/// attached and removes the image and scratch directory only once it is not.
#[cfg(target_os = "macos")]
struct Volume {
    root: PathBuf,
    mount: PathBuf,
    attached: bool,
}

#[cfg(target_os = "macos")]
impl Volume {
    fn attach(root: &Path, megabytes: u64) -> Self {
        fs::create_dir_all(root).unwrap();
        let image = root.join("owner.dmg");
        let mut volume =
            Self { root: root.to_path_buf(), mount: root.join("volume"), attached: false };
        let size = format!("{megabytes}m");
        let image = image.to_str().unwrap();
        hdiutil(&["create", "-quiet", "-size", &size, "-fs", "HFS+", "-volname", "oil", image]);
        // Counted as attached before the call: a half-done attach is detached too.
        volume.attached = true;
        hdiutil(&["attach", "-quiet", "-nobrowse", "-mountpoint", volume.path(), image]);
        volume
    }

    fn path(&self) -> &str {
        self.mount.to_str().unwrap()
    }

    fn detach(&mut self) {
        hdiutil(&["detach", "-force", self.path()]);
        self.attached = false;
    }
}

#[cfg(target_os = "macos")]
impl Drop for Volume {
    fn drop(&mut self) {
        if self.attached {
            let detached = Command::new("hdiutil")
                .args(["detach", "-force", self.path()])
                .output()
                .is_ok_and(|output| output.status.success());
            let mounted = Command::new("mount")
                .output()
                .is_ok_and(|out| String::from_utf8_lossy(&out.stdout).contains(self.path()));
            if !detached && mounted {
                // Never delete files under a volume that is still mounted.
                return;
            }
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
    let mut volume = Volume::attach(&scratch("volume"), megabytes);
    let mount = PathBuf::from(volume.path());
    fs::create_dir_all(mount.join("cwd")).unwrap();
    let bin = mount.join("cmux-tui");
    fs::copy(&source, &bin).unwrap();
    let owner = Owner::ensure(&scratch("volume-owner"), &bin, &mount.join("cwd"));
    let before = cpu(owner.pid()).expect("the owner is running");
    // Force-remove the volume under the running owner, as the runner's
    // instance-store volume vanished under the leaked owners.
    volume.detach();
    // A client makes the owner run code it has not run yet (the leaked
    // owners spun once a thread did).
    let _client = UnixStream::connect(&owner.socket).map(|mut stream| {
        let _ = stream.write_all(b"{\"id\":1,\"cmd\":\"identify\"}\n");
        stream
    });
    let deadline = std::time::Instant::now() + EXIT_BOUND;
    let mut used = Duration::ZERO;
    while let Some(now) = cpu(owner.pid()) {
        used = now.saturating_sub(before);
        assert!(
            std::time::Instant::now() < deadline,
            "the owner outlived its executable's volume by {EXIT_BOUND:?}, using {used:?} of CPU"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(used <= SPIN_LIMIT, "the owner used {used:?} of CPU before it exited");
}
