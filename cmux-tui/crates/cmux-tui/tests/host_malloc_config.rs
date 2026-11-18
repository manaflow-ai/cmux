//! A terminal host on macOS starts with a small malloc configuration (one
//! magazine, no nano zone), and nothing the host starts sees it (HOST-MEM
//! cut 1).
//!
//! libmalloc gives every process one magazine per CPU and a nano zone; an
//! idle host holds about 93 KB of live heap but 576 KB of malloc metadata
//! and 300 KB of malloc pages on a 14-core Mac. libmalloc reads its
//! configuration from the environment when the process starts, so the daemon
//! puts `MallocMaxMagazines=1` and `MallocNanoZone=0` in each host's
//! environment, and the host removes them as its first step: its shell and
//! every other program it starts get the environment they got before.
#![cfg(target_os = "macos")]

use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// The malloc variables a host starts with; no program in a terminal may
/// see one of them or the marker that lists them.
const HOST_ONLY_NAMES: [&str; 3] = ["MallocMaxMagazines", "MallocNanoZone", "CMUX_TUI_HOST_MALLOC"];

/// How much less dirty memory a waiting host must use than the same host
/// binary started without the configuration.
/// Bound 80 KB, half of the smallest measured gain (164 KB, macOS 26.7, 14 cores), so it proves the config is active, not its size.
const SAVED_KB_AT_LEAST: u64 = 80;

fn test_timeout(timeout: Duration) -> Duration {
    let scale = std::env::var("CMUX_TEST_TIMEOUT_SCALE")
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .unwrap_or(1)
        .clamp(1, 16);
    timeout.saturating_mul(scale)
}

struct Daemon {
    child: Child,
    socket: PathBuf,
    dir: PathBuf,
}

impl Daemon {
    fn start() -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir =
            PathBuf::from("/tmp").join(format!("cmux-hostmalloc-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("mux.sock");
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .args(["--headless", "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(dir.join("state"))
            .env("CMUX_TUI_CONFIG", dir.join("config.json"))
            .stdout(Stdio::null())
            .stderr(Stdio::from(fs::File::create(dir.join("daemon.stderr")).unwrap()));
        // The daemon itself runs without the configuration, as a person's
        // daemon does; it adds the variables for its hosts only.
        for name in HOST_ONLY_NAMES {
            command.env_remove(name);
        }
        let child = command.spawn().unwrap();
        let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
        while UnixStream::connect(&socket).is_err() {
            assert!(Instant::now() < deadline, "daemon did not create {}", socket.display());
            std::thread::sleep(Duration::from_millis(25));
        }
        Self { child, socket, dir }
    }

    fn pid(&self) -> u32 {
        self.child.id()
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        // End every terminal through the owner; never signal a host.
        if let Some(identify) = try_request(&self.socket, &serde_json::json!({"cmd": "identify"})) {
            let _ = try_request(
                &self.socket,
                &serde_json::json!({
                    "cmd": "shutdown-daemon",
                    "pid": identify["data"]["pid"],
                    "generation": identify["data"]["generation"],
                    "end_terminals": true,
                }),
            );
        }
        let deadline = Instant::now() + test_timeout(Duration::from_secs(60));
        while self.child.try_wait().ok().flatten().is_none() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(50));
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn try_request(path: &Path, value: &serde_json::Value) -> Option<serde_json::Value> {
    let stream = UnixStream::connect(path).ok()?;
    stream.set_read_timeout(Some(test_timeout(Duration::from_secs(60)))).ok()?;
    let mut writer = stream.try_clone().ok()?;
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{value}").ok()?;
    let mut line = String::new();
    reader.read_line(&mut line).ok()?;
    serde_json::from_str(&line).ok()
}

fn request(path: &Path, value: serde_json::Value) -> serde_json::Value {
    let response = try_request(path, &value).unwrap_or_else(|| panic!("{value}: no response"));
    assert_eq!(response["ok"], true, "{value} failed: {response}");
    response["data"].clone()
}

/// (pid, parent pid, command) of every process of this user.
fn processes() -> Vec<(u32, u32, String)> {
    let out = Command::new("/bin/ps").args(["-x", "-o", "pid=,ppid=,command="]).output().unwrap();
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|line| {
            let mut parts = line.split_whitespace();
            let pid = parts.next()?.parse().ok()?;
            let ppid = parts.next()?.parse().ok()?;
            Some((pid, ppid, parts.collect::<Vec<_>>().join(" ")))
        })
        .collect()
}

/// The environment `pid` was started with (what its parent passed), as
/// `ps -E` shows it after the command.
fn start_environment(pid: u32) -> String {
    let out = Command::new("/bin/ps")
        .args(["-E", "-ww", "-o", "command=", "-p", &pid.to_string()])
        .output()
        .unwrap();
    String::from_utf8_lossy(&out.stdout).into_owned()
}

fn descendants(all: &[(u32, u32, String)], root: u32) -> Vec<u32> {
    let mut found = Vec::new();
    let mut next = vec![root];
    while let Some(parent) = next.pop() {
        for &(pid, ppid, _) in all {
            if ppid == parent && !found.contains(&pid) {
                found.push(pid);
                next.push(pid);
            }
        }
    }
    found
}

/// phys_footprint of `pid` in KB (proc_pid_rusage, RUSAGE_INFO_V2).
fn footprint_kb(pid: u32) -> u64 {
    unsafe extern "C" {
        fn proc_pid_rusage(
            pid: libc::c_int,
            flavor: libc::c_int,
            buffer: *mut libc::c_void,
        ) -> libc::c_int;
    }
    // rusage_info_v2: a 16-byte uuid, then u64 fields; ri_phys_footprint is
    // the 8th of them.
    let mut info = [0u64; 32];
    // SAFETY: `info` is larger than rusage_info_v2 and outlives the call.
    let status = unsafe { proc_pid_rusage(pid as libc::c_int, 2, info.as_mut_ptr().cast()) };
    assert_eq!(status, 0, "proc_pid_rusage({pid}): {}", std::io::Error::last_os_error());
    info[2 + 7] / 1024
}

fn wait_for_file(path: &Path) -> String {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(20));
    loop {
        if let Ok(text) = fs::read_to_string(path)
            && text.contains("END-OF-ENV")
        {
            return text;
        }
        assert!(Instant::now() < deadline, "{} was never written", path.display());
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// The daemon's terminal hosts: its children that run `__terminal-host`.
fn hosts_of(daemon: u32) -> Vec<(u32, u32, String)> {
    processes()
        .into_iter()
        .filter(|(_, ppid, command)| *ppid == daemon && command.contains("__terminal-host"))
        .collect()
}

#[test]
fn a_terminal_host_starts_small_and_its_shell_sees_none_of_its_malloc_config() {
    let daemon = Daemon::start();
    request(&daemon.socket, serde_json::json!({"cmd": "new-workspace", "name": "hostmalloc"}));
    let tree = request(&daemon.socket, serde_json::json!({"cmd": "list-workspaces"}));
    let key = tree["workspaces"]
        .as_array()
        .and_then(|workspaces| workspaces.last())
        .and_then(|workspace| workspace["key"].as_str())
        .expect("workspace key")
        .to_owned();
    let probe = daemon.dir.join("shell-env");
    // The shell writes its environment, then starts a grandchild that stays.
    let script =
        format!("env > '{p}'; echo END-OF-ENV >> '{p}'; exec /bin/sleep 600", p = probe.display());
    request(
        &daemon.socket,
        serde_json::json!({"cmd": "create-terminal", "key": key, "argv": ["/bin/sh", "-c", script]}),
    );
    let shell_env = wait_for_file(&probe);
    for name in HOST_ONLY_NAMES {
        assert!(
            !shell_env.lines().any(|line| line.starts_with(&format!("{name}="))),
            "the terminal's shell sees {name}:\n{shell_env}"
        );
    }

    // Every program below every host (login, the shell, the program it ran)
    // started without the host's variables.
    let all = processes();
    let hosts = hosts_of(daemon.pid());
    assert!(hosts.len() >= 2, "expected the terminal's host and a waiting host, found {hosts:?}");
    let mut children = 0;
    for (host, _, _) in &hosts {
        for pid in descendants(&all, *host) {
            children += 1;
            let env = start_environment(pid);
            for name in HOST_ONLY_NAMES {
                assert!(
                    !env.contains(&format!(" {name}=")),
                    "process {pid} below host {host} started with {name}: {env}"
                );
            }
        }
    }
    assert!(children >= 1, "no program runs below the hosts {hosts:?}");

    // The waiting host (no child yet) holds less memory than the same
    // binary started without the configuration, because it started with it.
    let waiting = hosts
        .iter()
        .find(|(pid, _, _)| descendants(&all, *pid).is_empty())
        .map(|(pid, _, _)| *pid)
        .expect("a waiting host");
    let mut control = Command::new(env!("CARGO_BIN_EXE_cmux-tui-host"));
    control
        .args(["__terminal-host", "--bootstrap-stdio"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    for name in HOST_ONLY_NAMES {
        control.env_remove(name);
    }
    let mut control = control.spawn().unwrap();
    // Both wait on their bootstrap pipe; let each settle.
    std::thread::sleep(Duration::from_secs(2));
    let (with_config, without) = (footprint_kb(waiting), footprint_kb(control.id()));
    drop(control.stdin.take());
    let _ = control.wait();
    assert!(
        with_config + SAVED_KB_AT_LEAST <= without,
        "a waiting host uses {with_config} KB, the same host without the malloc configuration {without} KB: \
         less than {SAVED_KB_AT_LEAST} KB saved"
    );
    let started_with = start_environment(waiting);
    assert!(
        started_with.contains(" MallocMaxMagazines=1")
            && started_with.contains(" MallocNanoZone=0"),
        "the waiting host {waiting} did not start with the malloc configuration: {started_with}"
    );
}

#[test]
fn a_host_started_with_the_malloc_config_writes_no_malloc_message() {
    let mut host = Command::new(env!("CARGO_BIN_EXE_cmux-tui-host"));
    host.args(["__terminal-host", "--bootstrap-stdio"])
        .env("MallocMaxMagazines", "1")
        .env("MallocNanoZone", "0")
        .env("CMUX_TUI_HOST_MALLOC", "MallocMaxMagazines,MallocNanoZone")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped());
    let mut host = host.spawn().unwrap();
    std::thread::sleep(Duration::from_millis(500));
    // A closed bootstrap pipe ends a waiting host.
    drop(host.stdin.take());
    let mut stderr = String::new();
    host.stderr.take().unwrap().read_to_string(&mut stderr).unwrap();
    let _ = host.wait();
    assert!(
        !stderr.lines().any(|line| line.to_ascii_lowercase().contains("malloc")),
        "the host wrote a malloc message: {stderr}"
    );
}
