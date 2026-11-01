//! `server ensure --replace-unresponsive` (cx-jniyz): the app's "Restart
//! cmux-tui" button. A real owner process is frozen with SIGSTOP, so it keeps
//! its socket and accepts connections but never answers; the option stops it
//! (found through the socket's peer credentials) and starts a new owner. A
//! responsive owner is kept.
//!
//! An owner at its connection limit (issue 22311: a wedged owner whose 64
//! connection threads never end) refuses every new connection with a
//! `server.busy` line. A plain ensure must neither read that as no owner
//! (spawn a second one that loses the bind) nor fail as `server.unavailable`;
//! it reports `server.busy`, and the replace option replaces such an owner.

#![cfg(any(target_os = "linux", target_os = "macos"))]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::Value;

struct Fixture {
    dir: PathBuf,
    socket: PathBuf,
    session: String,
    /// An owner this test froze; killed on drop if the test fails before the
    /// option replaced it.
    frozen: Option<i32>,
}

impl Fixture {
    fn new(session: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = PathBuf::from("/tmp").join(format!("cmux-ru-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
        fs::create_dir(dir.join("home")).unwrap();
        Self { socket: dir.join("mux.sock"), session: session.into(), dir, frozen: None }
    }

    fn server(&self, action: &str, extra: &[&str]) -> Value {
        let (success, value) = self.run(action, extra);
        assert!(success, "server {action} {extra:?} failed: {value}");
        value
    }

    /// Whether a `server` command succeeded, and its result or JSON error
    /// (the last JSON line on stdout or stderr).
    fn run(&self, action: &str, extra: &[&str]) -> (bool, Value) {
        let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(["server", action, "--json", "--session", &self.session, "--socket"])
            .arg(&self.socket)
            .args(extra)
            .env("HOME", self.dir.join("home"))
            .env("CFFIXED_USER_HOME", self.dir.join("home"))
            .env("CMUX_TUI_STATE_DIR", self.dir.join("state"))
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"))
            .output()
            .unwrap();
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stream = if output.status.success() { &stdout } else { &stderr };
        let last = stream.lines().rfind(|line| line.starts_with('{')).unwrap_or_default();
        let value: Value = serde_json::from_str(last).unwrap_or_else(|_| {
            panic!("server {action} printed no JSON: stdout {stdout:?} stderr {stderr:?}")
        });
        (output.status.success(), value)
    }

    fn request(stream: &mut BufReader<UnixStream>, command: &str) -> Value {
        writeln!(stream.get_mut(), "{}", serde_json::json!({"id":1,"cmd":command})).unwrap();
        loop {
            let mut line = String::new();
            assert_ne!(stream.read_line(&mut line).unwrap(), 0, "closed during {command}");
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply["id"] == 1 {
                assert_eq!(reply["ok"], true, "{reply}");
                return reply["data"].clone();
            }
        }
    }

    /// Hold every permit ourselves before exercising ensure or Restart once.
    /// The initial ensure's socket can close before its worker releases the
    /// permit. Observe that release through the existing server counters,
    /// rather than retrying the operation under test after a lucky success.
    fn fill_connections(&self) -> Vec<BufReader<UnixStream>> {
        let connect = || {
            let stream = UnixStream::connect(&self.socket).unwrap();
            stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
            BufReader::new(stream)
        };
        let mut control = connect();
        let deadline = Instant::now() + Duration::from_secs(10);
        let limit = loop {
            let stats = Self::request(&mut control, "server-stats");
            if stats["connections"]["active"] == 1 {
                break usize::try_from(stats["connections"]["limit"].as_u64().unwrap()).unwrap();
            }
            assert!(Instant::now() < deadline, "initial clients did not retire: {stats}");
        };
        assert!((2..512).contains(&limit), "unexpected connection limit: {limit}");
        let mut held = vec![control];
        for _ in 1..limit {
            let mut stream = connect();
            Self::request(&mut stream, "identify");
            held.push(stream);
        }
        let stats = Self::request(&mut held[0], "server-stats");
        assert_eq!(stats["connections"]["active"], limit, "{stats}");

        let stream = UnixStream::connect(&self.socket).unwrap();
        // macOS can report EINVAL after the peer writes its refusal and
        // closes. The complete refusal is still readable in that case.
        let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
        let mut reader = BufReader::new(stream);
        let mut line = String::new();
        assert_ne!(reader.read_line(&mut line).unwrap(), 0);
        let refusal: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(refusal["protocol"], "cmux.protocol/2", "{refusal}");
        assert_eq!(refusal["type"], "refused", "{refusal}");
        assert_eq!(refusal["code"], "server.busy", "{refusal}");
        held
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        if let Some(pid) = self.frozen {
            // SAFETY: kill takes a pid and a signal; the pid is the owner this
            // test started and froze.
            unsafe { libc::kill(pid, libc::SIGKILL) };
        }
        let _ = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(["server", "stop", "--json", "--session", &self.session, "--socket"])
            .arg(&self.socket)
            .env("HOME", self.dir.join("home"))
            .env("CFFIXED_USER_HOME", self.dir.join("home"))
            .env("CMUX_TUI_STATE_DIR", self.dir.join("state"))
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"))
            .output();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

/// Whether `pid` exists and is not a zombie its new parent has yet to reap.
fn running(pid: i32) -> bool {
    // SAFETY: signal 0 only checks that the pid exists.
    if unsafe { libc::kill(pid, 0) } != 0 {
        return false;
    }
    #[cfg(target_os = "linux")]
    if let Ok(stat) = fs::read_to_string(format!("/proc/{pid}/stat"))
        && let Some((_, rest)) = stat.rsplit_once(')')
    {
        return rest.split_whitespace().next() != Some("Z");
    }
    #[cfg(target_os = "macos")]
    {
        /// `SZOMB` from `<sys/proc.h>`.
        const SZOMB: u32 = 5;
        // SAFETY: an all-zero proc_bsdinfo is a valid out-buffer.
        let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
        let size = i32::try_from(size_of::<libc::proc_bsdinfo>()).unwrap();
        // SAFETY: the out-buffer is valid for `size` bytes.
        let read = unsafe {
            libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, (&raw mut info).cast(), size)
        };
        if read == size {
            return info.pbi_status != SZOMB;
        }
    }
    true
}

fn pid_of(value: &Value) -> i32 {
    i32::try_from(value["pid"].as_u64().unwrap_or_else(|| panic!("no pid in {value}"))).unwrap()
}

#[test]
fn replace_unresponsive_stops_a_frozen_owner_and_starts_a_new_one() {
    let mut fixture = Fixture::new("replace-frozen");
    let first = fixture.server("ensure", &[]);
    let old = pid_of(&first);
    // SAFETY: kill takes a pid and a signal; the pid is the owner `ensure`
    // just reported for this test's private socket.
    assert_eq!(unsafe { libc::kill(old, libc::SIGSTOP) }, 0);
    fixture.frozen = Some(old);

    let replaced = fixture.server("ensure", &["--replace-unresponsive"]);
    assert_eq!(replaced["status"], "replaced", "{replaced}");
    assert_eq!(replaced["replaced_pid"], old, "{replaced}");
    let new = pid_of(&replaced);
    assert_ne!(new, old, "{replaced}");
    // The frozen owner is gone, not only replaced on the socket.
    assert!(!running(old), "the frozen owner {old} still runs");
    fixture.frozen = None;

    let status = fixture.server("status", &[]);
    assert_eq!(pid_of(&status), new, "{status}");
}

#[test]
fn replace_unresponsive_keeps_a_responsive_owner() {
    let fixture = Fixture::new("replace-responsive");
    let first = fixture.server("ensure", &[]);
    let again = fixture.server("ensure", &["--replace-unresponsive"]);
    assert_eq!(again["status"], "running", "{again}");
    assert_eq!(pid_of(&again), pid_of(&first), "{again}");
    assert!(again.get("replaced_pid").is_none(), "{again}");
}

#[test]
fn ensure_reports_an_owner_at_its_connection_limit_as_busy_and_adopts_it_later() {
    let fixture = Fixture::new("ensure-full");
    let first = fixture.server("ensure", &[]);
    let mut held = fixture.fill_connections();

    let (success, busy) = fixture.run("ensure", &[]);
    assert!(!success, "the saturated owner must not accept ensure: {busy}");
    assert_eq!(busy["code"], "server.busy", "{busy}");

    // One client leaves: the same owner serves the next ensure.
    held.pop();
    let again = fixture.server("ensure", &[]);
    assert_eq!(again["status"], "running", "{again}");
    assert_eq!(pid_of(&again), pid_of(&first), "{again}");
}

#[test]
fn replace_unresponsive_replaces_an_owner_at_its_connection_limit() {
    let fixture = Fixture::new("replace-full");
    let first = fixture.server("ensure", &[]);
    let old = pid_of(&first);
    let _held = fixture.fill_connections();

    let replaced = fixture.server("ensure", &["--replace-unresponsive"]);
    assert_eq!(replaced["status"], "replaced", "{replaced}");
    assert_eq!(replaced["replaced_pid"], old, "{replaced}");
    let new = pid_of(&replaced);
    assert_ne!(new, old, "{replaced}");
    assert!(!running(old), "the full owner {old} still runs");

    let status = fixture.server("status", &[]);
    assert_eq!(pid_of(&status), new, "{status}");
}

/// A frozen owner keeps its socket and accepts connections but never answers its identify. An
/// owner still restoring answers at once (`lifecycle_ready: false`), so this is not one: plain
/// `server ensure` reports it unavailable soon, which offers "Restart cmux-tui", instead of
/// waiting out the 120 s restore bound (restore journey, daemon-stop variant: no offer in 150 s).
/// macOS only: the owner's stopped state comes from `proc_pidinfo` (Linux keeps the restore wait).
#[cfg(target_os = "macos")]
#[test]
fn ensure_reports_a_frozen_owner_unavailable_without_waiting_out_the_restore_bound() {
    let mut fixture = Fixture::new("ensure-frozen");
    let old = pid_of(&fixture.server("ensure", &[]));
    // SAFETY: kill takes a pid and a signal; the pid is the owner `ensure`
    // just reported for this test's private socket.
    assert_eq!(unsafe { libc::kill(old, libc::SIGSTOP) }, 0);
    fixture.frozen = Some(old);

    let started = std::time::Instant::now();
    let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["server", "ensure", "--json", "--session", &fixture.session, "--socket"])
        .arg(&fixture.socket)
        .env("CMUX_TUI_STATE_DIR", fixture.dir.join("state"))
        .env("CMUX_TUI_CONFIG", fixture.dir.join("config.json"))
        .output()
        .unwrap();
    let took = started.elapsed();
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(!output.status.success(), "ensure succeeded on a frozen owner: {stdout}");
    // With --json, a CLI error is one JSON object on stderr (cli/wire.rs
    // print_local_error); stdout carries only a success.
    let stderr = String::from_utf8_lossy(&output.stderr);
    let error: Value = serde_json::from_str(stderr.trim())
        .unwrap_or_else(|_| panic!("stderr is not one JSON error: {stderr}"));
    assert_eq!(error["code"], "server.unavailable", "not reported unavailable: {stderr}");
    assert!(took < std::time::Duration::from_secs(60), "ensure waited {took:?} on a frozen owner");
}
