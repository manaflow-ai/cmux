//! A remote sidecar's connections to the session socket never outlive the
//! daemon that accepted them (plans/cmux-next/identity.md section 3, the
//! remote bridge rule). An old sidecar binary sends no bridge mark, so the
//! only bound on that gap is this: when the daemon hands off or crashes,
//! every connection it accepted closes, the sidecar's monitor sees end of
//! file and the sidecar exits; a new sidecar from the new binary replaces it.
#![cfg(unix)]

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

struct Daemon {
    child: Option<Child>,
    socket: PathBuf,
    dir: PathBuf,
}

impl Daemon {
    fn start(dir: &Path) -> Self {
        let socket = dir.join("mux.sock");
        let child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(["--headless", "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(dir.join("state"))
            .env("CMUX_TUI_CONFIG", dir.join("config.json"))
            .env_remove("CMUX_LAUNCH_CREDENTIAL")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(15);
        while UnixStream::connect(&socket).is_err() {
            assert!(Instant::now() < deadline, "daemon did not create {}", socket.display());
            std::thread::sleep(Duration::from_millis(25));
        }
        Self { child: Some(child), socket, dir: dir.to_path_buf() }
    }

    /// End every terminal host this daemon started, so none outlives the
    /// test (hosts survive a daemon crash by design).
    fn close_terminals(&self) {
        let tree = request(&self.socket, serde_json::json!({"id": 900, "cmd": "list-workspaces"}));
        for workspace in tree["data"]["workspaces"].as_array().into_iter().flatten() {
            let _ = request(
                &self.socket,
                serde_json::json!({
                    "id": 901,
                    "cmd": "close-workspace",
                    "key": workspace["key"],
                    "end_terminals": true,
                }),
            );
        }
    }

    fn wait_exit(&mut self) {
        let mut child = self.child.take().unwrap();
        let deadline = Instant::now() + Duration::from_secs(15);
        while child.try_wait().unwrap().is_none() {
            assert!(Instant::now() < deadline, "daemon did not exit");
            std::thread::sleep(Duration::from_millis(25));
        }
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            if UnixStream::connect(&self.socket).is_ok() {
                self.close_terminals();
            }
            let _ = child.kill();
            let _ = child.wait();
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn scratch(name: &str) -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir =
        PathBuf::from("/tmp").join(format!("cmux-bridge-{name}-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// Open a connection the way a sidecar's bridge does: mark it first.
fn marked_connection(socket: &Path) -> UnixStream {
    let stream = UnixStream::connect(socket).unwrap();
    let mut writer = stream.try_clone().unwrap();
    writer.write_all(&cmux_tui_core::server::connection_origin::remote_bridge_mark_line()).unwrap();
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut reply = String::new();
    reader.read_line(&mut reply).unwrap();
    assert_eq!(
        cmux_tui_core::server::connection_origin::remote_bridge_mark_reply(&reply),
        cmux_tui_core::server::connection_origin::RemoteBridgeMarkReply::Accepted,
        "{reply}"
    );
    stream.set_read_timeout(Some(Duration::from_secs(15))).unwrap();
    stream
}

fn request(socket: &Path, value: serde_json::Value) -> serde_json::Value {
    let stream = UnixStream::connect(socket).unwrap();
    let mut writer = stream.try_clone().unwrap();
    writeln!(writer, "{value}").unwrap();
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap()
}

/// The connection reaches end of file (or a reset), never a timeout. A
/// daemon may send a last notice first; that is drained.
fn assert_closed(mut stream: UnixStream) {
    let mut buffer = [0_u8; 4096];
    loop {
        match stream.read(&mut buffer) {
            Ok(0) => return,
            Ok(_) => continue,
            Err(error) if error.kind() == std::io::ErrorKind::ConnectionReset => return,
            other => panic!("the bridge connection stayed open: {other:?}"),
        }
    }
}

#[test]
fn a_daemon_handoff_closes_every_bridge_connection() {
    let dir = scratch("handoff");
    let mut daemon = Daemon::start(&dir);
    let monitor = marked_connection(&daemon.socket);
    daemon.close_terminals();
    let identify = request(&daemon.socket, serde_json::json!({"id": 1, "cmd": "identify"}));
    let accepted = request(
        &daemon.socket,
        serde_json::json!({
            "id": 2,
            "cmd": "shutdown-daemon",
            "pid": identify["data"]["pid"],
            "generation": identify["data"]["generation"],
        }),
    );
    assert_eq!(accepted["ok"], true, "{accepted}");
    daemon.wait_exit();
    assert_closed(monitor);
}

#[test]
fn a_daemon_crash_and_restart_close_every_bridge_connection() {
    let dir = scratch("crash");
    let mut daemon = Daemon::start(&dir);
    let monitor = marked_connection(&daemon.socket);
    daemon.close_terminals();
    let mut child = daemon.child.take().unwrap();
    child.kill().unwrap();
    child.wait().unwrap();
    assert_closed(monitor);

    // A restart on the same path serves new connections only; the old one
    // never comes back.
    let _ = std::fs::remove_file(&daemon.socket);
    let restarted = Daemon::start(&dir);
    let fresh = marked_connection(&restarted.socket);
    drop(fresh);
    drop(restarted);
    drop(daemon);
}
