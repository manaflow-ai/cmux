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
use std::time::{Duration, SystemTime, UNIX_EPOCH};

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

    /// Takes every connection the owner accepts until it refuses one at its
    /// connection limit; the owner holds a permit for each until it closes.
    fn fill_connections(&self) -> Vec<UnixStream> {
        let mut held = Vec::new();
        loop {
            assert!(held.len() < 512, "the owner never refused a connection");
            let stream = UnixStream::connect(&self.socket).unwrap();
            // macOS refuses the timeout (EINVAL) once the owner has closed a
            // refused connection; its refusal line is still readable.
            let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            // The refusal may close the socket before this write lands.
            let _ = writeln!(&stream, r#"{{"id":1,"cmd":"identify"}}"#);
            loop {
                let mut line = String::new();
                assert_ne!(reader.read_line(&mut line).unwrap(), 0, "closed after {}", held.len());
                let reply: Value = serde_json::from_str(&line).unwrap();
                if reply["type"] == "refused" {
                    assert_eq!(reply["code"], "server.busy", "{reply}");
                    return held;
                }
                if reply["id"] == 1 {
                    break;
                }
            }
            held.push(stream);
        }
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

    // Not `server.unavailable` ("did not become ready"), and no second owner.
    // A permit of an earlier command's connection may free only after the
    // fill: then this ensure is served, and the fill tops up and asks again.
    let busy = (0..3)
        .find_map(|_| match fixture.run("ensure", &[]) {
            (false, failure) => Some(failure),
            (true, _) => {
                held.extend(fixture.fill_connections());
                None
            }
        })
        .expect("the full owner served every ensure");
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
    let mut held = fixture.fill_connections();

    // As above: a late-freed permit answers the probe, and the owner is kept.
    let replaced = (0..3)
        .find_map(|_| {
            let result = fixture.server("ensure", &["--replace-unresponsive"]);
            if result["status"] == "running" {
                held.extend(fixture.fill_connections());
                return None;
            }
            Some(result)
        })
        .expect("the full owner answered every replace probe");
    assert_eq!(replaced["status"], "replaced", "{replaced}");
    assert_eq!(replaced["replaced_pid"], old, "{replaced}");
    let new = pid_of(&replaced);
    assert_ne!(new, old, "{replaced}");
    assert!(!running(old), "the full owner {old} still runs");

    let status = fixture.server("status", &[]);
    assert_eq!(pid_of(&status), new, "{status}");
}
