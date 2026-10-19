//! Admission and lifetime of an explicitly configured daemon-owned link.
#![cfg(unix)]

use std::io::{Read as _, Write as _};
use std::os::fd::AsRawFd as _;
use std::os::unix::process::CommandExt as _;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::Duration;

struct Daemon {
    child: Child,
    home: tempfile::TempDir,
    session: PathBuf,
    state: PathBuf,
}

impl Daemon {
    fn start() -> Self {
        let home = cmux_unix_socket::short_test_dir("sl");
        let session = home.path().join("s.sock");
        let state = home.path().join("link");
        let initialized = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(["link", "init", "--install", "inst_supervised", "--port", "0", "--state-dir"])
            .arg(&state)
            .env_clear()
            .env("HOME", home.path())
            .output()
            .unwrap();
        assert!(initialized.status.success(), "{}", String::from_utf8_lossy(&initialized.stderr));
        let (mut read, write) = std::io::pipe().unwrap();
        let fd = write.as_raw_fd();
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .args(["--headless", "--link-entry", "--supervised-link-state"])
            .arg(&state)
            .arg("--socket")
            .arg(&session)
            .arg("--state")
            .arg(home.path().join("daemon.json"))
            .arg("--owner-ready-fd")
            .arg(fd.to_string())
            .env_clear()
            .env("HOME", home.path())
            .env("CMUX_TUI_CONFIG", home.path().join("config.json"))
            .env("CMUX_TUI_STATE_DIR", home.path().join("daemon"))
            .env("CMUX_LINK_TOKEN_VERIFIER", "deny_all")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(std::fs::File::create(home.path().join("daemon.log")).unwrap());
        // SAFETY: only the inherited readiness descriptor loses CLOEXEC in
        // this child. The daemon claims it and closes it after signaling.
        unsafe {
            command.pre_exec(move || {
                let flags = libc::fcntl(fd, libc::F_GETFD);
                if flags < 0 || libc::fcntl(fd, libc::F_SETFD, flags & !libc::FD_CLOEXEC) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let child = command.spawn().unwrap();
        let daemon = Self { child, home, session, state };
        drop(write);
        let mut ready = [0];
        read.read_exact(&mut ready).unwrap_or_else(|error| {
            panic!("daemon readiness: {error}: {}", daemon.log());
        });
        assert_eq!(ready, [b'1'], "{}", daemon.log());
        daemon
    }

    fn log(&self) -> String {
        std::fs::read_to_string(self.home.path().join("daemon.log")).unwrap_or_default()
    }

    fn link_status(&self) -> serde_json::Value {
        let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(["link", "status", "--state-dir"])
            .arg(&self.state)
            .env_clear()
            .env("HOME", self.home.path())
            .output()
            .unwrap();
        assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
        serde_json::from_slice(&output.stdout).unwrap()
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[test]
fn supervised_link_starts_the_existing_identity_as_a_distinct_child() {
    let daemon = Daemon::start();
    let status = daemon.link_status();
    assert_eq!(status["running"], true, "{status}: {}", daemon.log());
    assert_eq!(status["install"], "inst_supervised");
    let pid = status["pid"].as_u64().expect("live link pid");
    assert_ne!(pid, u64::from(daemon.child.id()));
    assert!(daemon.log().contains("mode deny_all"), "{}", daemon.log());
}

#[test]
fn supervised_link_remote_entry_refuses_another_process_of_the_same_user() {
    let daemon = Daemon::start();
    assert_eq!(daemon.link_status()["running"], true, "{}", daemon.log());
    let path = cmux_link::entry_path::remote_entry_socket_path(&daemon.session);
    let mut stream = cmux_unix_socket::connect(&path).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let _ = stream.write_all(b"{\"link_peer\":{\"install\":\"inst_forged\",\"user\":\"user_forged\",\"team\":\"team_forged\"}}\n");
    let mut byte = [0];
    match stream.read(&mut byte) {
        Ok(0) => {}
        Err(error)
            if matches!(
                error.kind(),
                std::io::ErrorKind::ConnectionReset | std::io::ErrorKind::BrokenPipe
            ) => {}
        result => panic!("a process other than the daemon's link reached the entry: {result:?}"),
    }
}

#[test]
fn supervised_link_cannot_read_bootstrap_configuration_from_an_ordinary_pipe() {
    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["link", "serve", "--supervised"])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let _ = child.stdin.take().unwrap().write_all(b"{\"verifier\":\"control_plane\"}\n");
    assert!(!child.wait().unwrap().success());
}
