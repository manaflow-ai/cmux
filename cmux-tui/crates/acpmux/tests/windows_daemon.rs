//! acpmux on Windows, through its CLI and its socket only: the daemon binds
//! its `cmux::local_socket` socket and answers `acpmux status`, a second
//! daemon on the same home stops at the start lock, the first start saves a
//! random WebSocket token, `acpmux shutdown` stops it and removes the socket,
//! and a peer of another user is refused by the daemon and by the CLI.
#![cfg(windows)]

use serde_json::Value;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::time::{Duration, Instant};

fn scratch(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("amxw-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

fn acpmux(exe: &Path, home: &Path) -> Command {
    let mut cmd = Command::new(exe);
    cmd.env("ACPMUX_HOME", home)
        .env("ACPMUX_CATALOG_FETCH", "0")
        .env("ACPMUX_REGISTRY_FETCH", "0")
        .env_remove("ACPMUX_SOCKET")
        .env_remove("ACPMUX_LOCAL_ROUTER")
        .stdin(Stdio::null());
    cmd
}

/// Held by every test that starts processes: a child inherits each
/// inheritable handle of this process, so a test's pipe must not reach the
/// daemon another test starts at the same moment.
static SPAWNS: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn spawns() -> std::sync::MutexGuard<'static, ()> {
    SPAWNS.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn exe() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_acpmux"))
}

/// A daemon this test started; killed if the test ends early.
struct Daemon {
    child: Child,
    log: PathBuf,
}

impl Daemon {
    fn start(exe: &Path, home: &Path, log: PathBuf) -> Self {
        // Its log lines go to stdout, its errors to stderr: both to `log`.
        let out = std::fs::File::create(&log).unwrap();
        let err = out.try_clone().unwrap();
        let child = acpmux(exe, home)
            .args(["daemon", "run", "--memory", "--listen", "127.0.0.1:0", "--log", "info"])
            .stdout(out)
            .stderr(err)
            .spawn()
            .expect("spawn acpmux daemon run");
        Self { child, log }
    }

    fn log(&self) -> String {
        std::fs::read_to_string(&self.log).unwrap_or_default()
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn status(exe: &Path, home: &Path) -> Value {
    let out = acpmux(exe, home).args(["--json", "status"]).output().expect("run acpmux status");
    assert!(out.status.success(), "acpmux status failed: {}", text(&out));
    serde_json::from_slice(&out.stdout)
        .unwrap_or_else(|e| panic!("status JSON: {e}: {}", text(&out)))
}

fn text(out: &Output) -> String {
    format!(
        "exit {:?}\nstdout: {}\nstderr: {}",
        out.status.code(),
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    )
}

/// `acpmux status` until the daemon with `pid` answers it over the socket.
fn wait_ready(exe: &Path, home: &Path, daemon: &mut Daemon) -> Value {
    let deadline = Instant::now() + Duration::from_secs(60);
    loop {
        if let Some(code) = daemon.child.try_wait().unwrap() {
            panic!("the daemon exited ({code}) before it was ready:\n{}", daemon.log());
        }
        let v = status(exe, home);
        if v.get("pid").and_then(Value::as_u64) == Some(u64::from(daemon.child.id())) {
            return v;
        }
        assert!(
            Instant::now() < deadline,
            "the daemon never answered status: {v}\n{}",
            daemon.log()
        );
        std::thread::sleep(Duration::from_millis(200));
    }
}

#[test]
fn the_daemon_serves_its_socket_holds_its_lock_and_stops() {
    let _spawns = spawns();
    let exe = exe();
    let home = scratch("life");
    // No daemon yet: status says so and starts none.
    let v = status(&exe, &home);
    assert_eq!(v.get("running"), Some(&Value::Bool(false)), "{v}");

    let log = std::env::temp_dir().join(format!("amxw-life-{}.log", std::process::id()));
    let mut daemon = Daemon::start(&exe, &home, log);
    let v = wait_ready(&exe, &home, &mut daemon);
    let socket = home.join("acpmux.sock");
    assert_eq!(v.get("socket").and_then(Value::as_str), Some(socket.to_str().unwrap()), "{v}");
    assert!(std::fs::symlink_metadata(&socket).is_ok(), "no socket file at {}", socket.display());

    // The first start saved a random 48-hex WebSocket token.
    let config: Value =
        serde_json::from_str(&std::fs::read_to_string(home.join("config.json")).unwrap()).unwrap();
    let token = config.pointer("/websocket/token").and_then(Value::as_str).unwrap_or_default();
    assert!(
        token.len() == 48 && token.bytes().all(|b| b.is_ascii_hexdigit()),
        "saved token is not 48 hex characters: {token:?}"
    );

    // The raw socket speaks newline-delimited JSON-RPC.
    let mut stream = cmux::local_socket::connect_same_user(&socket).expect("connect");
    stream
        .write_all(b"{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"_acpmux/status\",\"params\":{}}\n")
        .unwrap();
    let line = read_line(&mut stream, Duration::from_secs(30));
    let reply: Value = serde_json::from_str(&line).unwrap_or_else(|e| panic!("{e}: {line}"));
    assert_eq!(reply.get("id"), Some(&Value::from(7)), "{reply}");
    assert_eq!(
        reply.pointer("/result/pid").and_then(Value::as_u64),
        Some(u64::from(daemon.child.id())),
        "{reply}"
    );
    drop(stream);

    // A second daemon on the same home stops at the start lock.
    let second = acpmux(&exe, &home)
        .args(["daemon", "run", "--memory", "--listen", "127.0.0.1:0"])
        .output()
        .expect("run a second daemon");
    assert!(!second.status.success(), "a second daemon started: {}", text(&second));
    assert!(
        String::from_utf8_lossy(&second.stderr).contains("another acpmux daemon holds"),
        "the second daemon did not stop at the lock: {}",
        text(&second)
    );
    // The first one still serves.
    let v = status(&exe, &home);
    assert_eq!(v.get("pid").and_then(Value::as_u64), Some(u64::from(daemon.child.id())), "{v}");

    // `acpmux shutdown` stops it and removes the socket.
    let out = acpmux(&exe, &home).arg("shutdown").output().expect("run acpmux shutdown");
    assert!(out.status.success(), "acpmux shutdown failed: {}", text(&out));
    let deadline = Instant::now() + Duration::from_secs(30);
    let code = loop {
        if let Some(code) = daemon.child.try_wait().unwrap() {
            break code;
        }
        assert!(Instant::now() < deadline, "the daemon did not stop:\n{}", daemon.log());
        std::thread::sleep(Duration::from_millis(100));
    };
    assert!(code.success(), "the daemon exited with {code}:\n{}", daemon.log());
    assert!(std::fs::symlink_metadata(&socket).is_err(), "the socket file stayed");
    let v = status(&exe, &home);
    assert_eq!(v.get("running"), Some(&Value::Bool(false)), "{v}");
    let _ = std::fs::remove_dir_all(&home);
}

/// One line from `stream`, within `timeout`.
fn read_line(stream: &mut cmux::local_socket::Stream, timeout: Duration) -> String {
    stream.set_read_timeout(Some(timeout)).unwrap();
    let mut bytes = Vec::new();
    let mut byte = [0u8; 1];
    while stream.read(&mut byte).expect("read a reply line") == 1 && byte[0] != b'\n' {
        bytes.push(byte[0]);
    }
    String::from_utf8(bytes).unwrap()
}

/// Shared with the LocalService peer: a folder both users may enter (the
/// hosted step makes it and grants Everyone access).
const OTHER_USER_DIR: &str = r"C:\amx-peer";

/// The daemon runs as this user; a peer of another user (LocalService, from
/// a scheduled task the hosted step starts) connects twice: `acpmux status`
/// refuses the socket because another user owns it, and a raw connect that
/// skips that check is closed by the daemon before any reply.
#[test]
#[ignore = "hosted Windows runner only: the step starts the LocalService peer"]
fn other_user_peer_is_refused() {
    let dir = Path::new(OTHER_USER_DIR);
    let home = dir.join("home");
    std::fs::create_dir_all(&home).unwrap();
    // The peer runs this copy: the build folder may be closed to it.
    let peer_exe = dir.join("acpmux.exe");
    std::fs::copy(exe(), &peer_exe).unwrap();
    let mut daemon = Daemon::start(&exe(), &home, dir.join("daemon.log"));
    wait_ready(&exe(), &home, &mut daemon);
    std::fs::write(dir.join("ready"), b"1").unwrap();
    let done = dir.join("child-done");
    let deadline = Instant::now() + Duration::from_secs(90);
    while !done.exists() {
        assert!(
            Instant::now() < deadline,
            "the LocalService peer never finished:\n{}",
            daemon.log()
        );
        std::thread::sleep(Duration::from_millis(200));
    }
    let child = std::fs::read_to_string(&done).unwrap();
    assert!(child.contains("cli: refused"), "the CLI used another user's socket: {child}");
    assert!(child.contains("raw: closed"), "the daemon answered another user: {child}");
    let log = daemon.log();
    assert!(
        log.contains("refused: owned by or running as another user"),
        "the daemon did not log the refusal:\n{log}"
    );
}

/// The LocalService peer's body (run by the hosted step's scheduled task).
#[test]
#[ignore = "run by the hosted runner's LocalService scheduled task"]
fn other_user_child() {
    let dir = Path::new(OTHER_USER_DIR);
    let home = dir.join("home");
    let socket = home.join("acpmux.sock");
    let identity = cmux::local_socket::win::current_identity().unwrap();
    let mut report = format!("user: {}\n", identity.user_sid);
    let out = Command::new(dir.join("acpmux.exe"))
        .args(["--json", "status"])
        .env("ACPMUX_HOME", &home)
        .env_remove("ACPMUX_SOCKET")
        .output();
    match out {
        // The daemon runs, so "not running" is the CLI's refusal of a
        // socket file another user owns.
        Ok(out) => match serde_json::from_slice::<Value>(&out.stdout) {
            Ok(v) if v.get("running") == Some(&Value::Bool(false)) => {
                report.push_str(&format!("cli: refused ({})\n", v["error"]));
            }
            _ => report.push_str(&format!("cli: unexpected: {}\n", text(&out))),
        },
        Err(e) => report.push_str(&format!("cli: did not run: {e}\n")),
    }
    match cmux::local_socket::connect(&socket) {
        Ok(mut stream) => {
            let _ = stream.write_all(
                b"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"_acpmux/status\",\"params\":{}}\n",
            );
            let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
            let mut buf = [0u8; 256];
            match stream.read(&mut buf) {
                Ok(0) | Err(_) => report.push_str("raw: closed\n"),
                Ok(n) => report
                    .push_str(&format!("raw: answered: {}\n", String::from_utf8_lossy(&buf[..n]))),
            }
        }
        Err(e) => report.push_str(&format!("raw: connect failed: {e}\n")),
    }
    std::fs::write(dir.join("child-done"), report).unwrap();
}

/// An anonymous pipe whose ends are both inheritable: (read, write).
fn inheritable_pipe() -> (std::fs::File, std::fs::File) {
    use std::os::windows::io::FromRawHandle;
    use windows_sys::Win32::Security::SECURITY_ATTRIBUTES;
    let attributes = SECURITY_ATTRIBUTES {
        nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: std::ptr::null_mut(),
        bInheritHandle: 1,
    };
    let (mut read, mut write) = (std::ptr::null_mut(), std::ptr::null_mut());
    // SAFETY: valid out-pointers and attributes.
    let ok = unsafe {
        windows_sys::Win32::System::Pipes::CreatePipe(&mut read, &mut write, &attributes, 0)
    };
    assert_ne!(ok, 0, "CreatePipe: {}", std::io::Error::last_os_error());
    // SAFETY: both handles were just created and are owned here.
    unsafe { (std::fs::File::from_raw_handle(read), std::fs::File::from_raw_handle(write)) }
}

/// Stops inheritance of `file`'s handle by later children.
fn not_inheritable(file: &std::fs::File) {
    use std::os::windows::io::AsRawHandle;
    // SAFETY: a handle this test owns.
    unsafe {
        windows_sys::Win32::Foundation::SetHandleInformation(
            file.as_raw_handle(),
            windows_sys::Win32::Foundation::HANDLE_FLAG_INHERIT,
            0,
        )
    };
}

/// Reads `file` to its end on a thread; None if it did not end in `timeout`
/// (another process still holds the write end).
fn read_to_end_within(mut file: std::fs::File, timeout: Duration) -> Option<Vec<u8>> {
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let _ = file.read_to_end(&mut bytes);
        let _ = tx.send(bytes);
    });
    rx.recv_timeout(timeout).ok()
}

/// `acpmux daemon start` with no daemon starts one detached
/// (CreateProcessW): it reads the daemon's ready line on an inherited pipe
/// and reports it; the daemon outlives the CLI, logs to daemon.log and
/// inherits no handle but the ones it was given (a pipe the CLI inherited
/// from this test reaches end of file once the CLI exits).
#[test]
fn daemon_start_launches_a_detached_daemon_through_a_handle_list() {
    let _spawns = spawns();
    let exe = exe();
    let home = scratch("start");
    let (probe_read, probe_write) = inheritable_pipe();
    not_inheritable(&probe_read);
    let started = Instant::now();
    let out =
        acpmux(&exe, &home).args(["daemon", "start"]).output().expect("run acpmux daemon start");
    let took = started.elapsed();
    drop(probe_write);
    assert!(out.status.success(), "acpmux daemon start failed: {}", text(&out));
    // The ready line ended the wait, not the 8 s start budget.
    assert!(took < Duration::from_secs(8), "daemon start took {took:?}: {}", text(&out));
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    let pid: u64 = stdout
        .lines()
        .next()
        .and_then(|l| l.split(" pid ").nth(1))
        .and_then(|rest| rest.split_whitespace().next())
        .and_then(|p| p.parse().ok())
        .unwrap_or_else(|| panic!("no pid in the status: {stdout}"));
    // The CLI has exited; the daemon still answers.
    let v = status(&exe, &home);
    assert_eq!(v.get("pid").and_then(Value::as_u64), Some(pid), "{v}");
    let handles_kept = read_to_end_within(probe_read, Duration::from_secs(10));
    let log = std::fs::read_to_string(home.join("daemon.log")).unwrap_or_default();
    let out = acpmux(&exe, &home).arg("shutdown").output().expect("run acpmux shutdown");
    assert!(out.status.success(), "acpmux shutdown failed: {}", text(&out));
    assert!(
        handles_kept.is_some(),
        "the detached daemon inherited a handle it was not given (the probe pipe stayed open)"
    );
    assert!(log.contains("acpmux ready"), "daemon.log has no ready line:\n{log}");
    let deadline = Instant::now() + Duration::from_secs(30);
    while status(&exe, &home).get("running") != Some(&Value::Bool(false)) {
        assert!(Instant::now() < deadline, "the started daemon did not stop");
        std::thread::sleep(Duration::from_millis(200));
    }
    let _ = std::fs::remove_dir_all(&home);
}

/// 32 bytes as hex: what the app makes at each launch.
const PERSON_KEY: &str = "5e1f0c2a9b8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f";

/// `daemon run --person-key-fd H --ready-fd H2` with inherited handles, as
/// the app starts it: the ready line arrives on its handle, and over the
/// socket the key enrolls (via the spawn key) while another key does not.
#[test]
fn daemon_run_reads_its_person_key_and_writes_ready_on_inherited_handles() {
    let _spawns = spawns();
    let exe = exe();
    let home = scratch("person");
    let (key_read, mut key_write) = inheritable_pipe();
    not_inheritable(&key_write);
    let (ready_read, ready_write) = inheritable_pipe();
    not_inheritable(&ready_read);
    use std::os::windows::io::AsRawHandle;
    let key_handle = (key_read.as_raw_handle() as isize).to_string();
    let ready_handle = (ready_write.as_raw_handle() as isize).to_string();
    key_write.write_all(PERSON_KEY.as_bytes()).unwrap();
    drop(key_write);
    let log = std::env::temp_dir().join(format!("amxw-person-{}.log", std::process::id()));
    let out = std::fs::File::create(&log).unwrap();
    let err = out.try_clone().unwrap();
    let child = acpmux(&exe, &home)
        .args(["daemon", "run", "--memory", "--listen", "127.0.0.1:0", "--log", "info"])
        .args(["--person-key-fd", &key_handle, "--ready-fd", &ready_handle])
        .stdout(out)
        .stderr(err)
        .spawn()
        .expect("spawn acpmux daemon run");
    let daemon = Daemon { child, log };
    drop(key_read);
    drop(ready_write);
    let line = read_to_end_within(ready_read, Duration::from_secs(60))
        .unwrap_or_else(|| panic!("no ready line (the handle stayed open):\n{}", daemon.log()));
    let ready: Value = serde_json::from_slice(&line).unwrap_or_else(|e| {
        panic!("ready line {e}: {:?}\n{}", String::from_utf8_lossy(&line), daemon.log())
    });
    assert_eq!(ready.get("ready"), Some(&Value::Bool(true)), "{ready}");
    assert_eq!(
        ready.get("pid").and_then(Value::as_u64),
        Some(u64::from(daemon.child.id())),
        "{ready}"
    );

    let socket = home.join("acpmux.sock");
    let enroll = |key: &str| -> Value {
        let mut stream = cmux::local_socket::connect_same_user(&socket).expect("connect");
        let line = serde_json::json!({"jsonrpc": "2.0", "id": 1, "method": "_acpmux/person_enroll", "params": {"key": key}});
        stream.write_all(format!("{line}\n").as_bytes()).unwrap();
        let reply = read_line(&mut stream, Duration::from_secs(30));
        serde_json::from_str(&reply).unwrap_or_else(|e| panic!("{e}: {reply}"))
    };
    let ok = enroll(PERSON_KEY);
    assert_eq!(ok.pointer("/result/via").and_then(Value::as_str), Some("spawn"), "{ok}");
    let other = enroll(&"0".repeat(64));
    assert!(other.get("error").is_some(), "another key enrolled: {other}");
    drop(daemon);
    let _ = std::fs::remove_dir_all(&home);
}

/// True when `path` is owned by this user and its protected access list
/// grants only this user (the SDK's owner-only check reads any file).
fn owner_only(path: &Path) -> bool {
    let me = cmux::local_socket::win::current_identity().unwrap().user_sid;
    cmux::local_socket::win::directory_is_owner_only(path, &me)
        .unwrap_or_else(|e| panic!("read the access list of {}: {e}", path.display()))
}

/// What the daemon writes (mode 0600 / 0700 on Unix) is owner-only on
/// Windows: config.json with its token, the per-launch LocalApp and peer
/// token files and their run folder, and daemon.log of a started daemon.
#[test]
fn the_daemon_writes_its_state_owner_only() {
    let _spawns = spawns();
    let exe = exe();
    let home = scratch("acl");
    let out =
        acpmux(&exe, &home).args(["daemon", "start"]).output().expect("run acpmux daemon start");
    assert!(out.status.success(), "acpmux daemon start failed: {}", text(&out));
    let checked = [
        home.join("config.json"),
        home.join("daemon.log"),
        home.join("run"),
        home.join("run").join("localapp.token"),
        home.join("run").join("peer.token"),
    ];
    let wide: Vec<String> = checked
        .iter()
        .filter(|p| !p.exists() || !owner_only(p))
        .map(|p| p.display().to_string())
        .collect();
    let out = acpmux(&exe, &home).arg("shutdown").output().expect("run acpmux shutdown");
    assert!(out.status.success(), "acpmux shutdown failed: {}", text(&out));
    assert!(wide.is_empty(), "missing or not owner-only: {wide:?}");
    let _ = std::fs::remove_dir_all(&home);
}

/// `acpmux harness add` writes an owner-only profile that loads; once
/// Everyone may change the file, `harness list` refuses it with the reason
/// and the fix (a profile runs a program with the user's rights).
#[test]
fn a_profile_another_user_can_change_is_refused() {
    let _spawns = spawns();
    let exe = exe();
    let home = scratch("profile");
    let config = home.join("xdg");
    let run = |args: &[&str]| -> Output {
        acpmux(&exe, &home).env("XDG_CONFIG_HOME", &config).args(args).output().expect("run acpmux")
    };
    let out = run(&["harness", "add", "winecho", "--command", r"C:\Windows\System32\cmd.exe"]);
    assert!(out.status.success(), "harness add failed: {}", text(&out));
    let file = config.join("cmux").join("harnesses").join("winecho.toml");
    assert!(owner_only(&file), "the written profile is not owner-only: {}", file.display());
    let list = |out: Output| -> Value {
        assert!(out.status.success(), "harness list failed: {}", text(&out));
        serde_json::from_slice(&out.stdout).unwrap_or_else(|e| panic!("{e}: {}", text(&out)))
    };
    let v = list(run(&["--json", "harness", "list"]));
    let ids = |v: &Value| -> Vec<String> {
        v["harnesses"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|h| h["id"].as_str().map(str::to_owned))
            .collect()
    };
    assert!(ids(&v).contains(&"winecho".to_owned()), "the owner-only profile did not load: {v}");

    let granted = Command::new("icacls")
        .arg(&file)
        .args(["/grant", "*S-1-1-0:(M)"])
        .output()
        .expect("run icacls");
    assert!(granted.status.success(), "icacls failed: {}", text(&granted));
    let v = list(run(&["--json", "harness", "list"]));
    assert!(!ids(&v).contains(&"winecho".to_owned()), "a profile Everyone can change loaded: {v}");
    let diagnostics = v["diagnostics"].to_string();
    assert!(
        diagnostics.contains("another user (S-1-1-0) can change this file")
            && diagnostics.contains("icacls"),
        "no refusal with its fix: {diagnostics}"
    );
    let _ = std::fs::remove_dir_all(&home);
}

/// Two `acpmux daemon start` at once on a new home: both succeed and name
/// the same daemon (the second start's daemon loses the lock and exits;
/// its client must still open the shared daemon.log and connect).
#[test]
fn two_starts_at_once_share_one_daemon() {
    let _spawns = spawns();
    let exe = exe();
    let home = scratch("twostart");
    let start = || {
        acpmux(&exe, &home)
            .args(["daemon", "start"])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("spawn acpmux daemon start")
    };
    let (first, second) = (start(), start());
    let outs = [first.wait_with_output().unwrap(), second.wait_with_output().unwrap()];
    let pids: Vec<String> = outs
        .iter()
        .map(|out| {
            assert!(out.status.success(), "a concurrent daemon start failed: {}", text(out));
            let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
            stdout
                .split(" pid ")
                .nth(1)
                .and_then(|r| r.split_whitespace().next())
                .unwrap_or_default()
                .to_owned()
        })
        .collect();
    let out = acpmux(&exe, &home).arg("shutdown").output().expect("run acpmux shutdown");
    assert!(out.status.success(), "acpmux shutdown failed: {}", text(&out));
    assert!(!pids[0].is_empty() && pids[0] == pids[1], "two daemons answered: {pids:?}");
    let _ = std::fs::remove_dir_all(&home);
}
