//! The broker is an inherited parent channel, never a public credential socket.
#![cfg(unix)]

use std::io::{BufRead as _, BufReader, Read as _, Write as _};
use std::net::Shutdown;
use std::os::fd::{AsRawFd as _, OwnedFd};
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt as _;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::Duration;

const HOST: &str = "host_00000000000000000001";

struct Link {
    child: Child,
    home: tempfile::TempDir,
    socket: PathBuf,
    broker: UnixStream,
}

impl Link {
    fn start() -> Self {
        let home = cmux_unix_socket::short_test_dir("cb");
        let state = home.path().join("link");
        let initialized = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(["link", "init", "--install", "inst_cloud_broker", "--port", "0", "--state-dir"])
            .arg(&state)
            .env_clear()
            .env("HOME", home.path())
            .output()
            .unwrap();
        assert!(initialized.status.success());
        let (broker, inherited) = UnixStream::pair().unwrap();
        broker.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let (ready, inherited_ready) = UnixStream::pair().unwrap();
        ready.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let fd = inherited_ready.as_raw_fd();
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .args(["link", "serve", "--cloud-broker-fd", "0", "--state-dir"])
            .arg(&state)
            .arg("--ready-fd")
            .arg(fd.to_string())
            .env_clear()
            .env("HOME", home.path())
            .stdin(Stdio::from(OwnedFd::from(inherited)))
            .stdout(Stdio::null())
            .stderr(std::fs::File::create(home.path().join("link.log")).unwrap());
        // SAFETY: only this child's readiness descriptor loses CLOEXEC.
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
        drop(inherited_ready);
        let mut link = Self { child, home, socket: PathBuf::new(), broker };
        let mut line = String::new();
        let count = BufReader::new(ready).read_line(&mut line).unwrap();
        assert_ne!(count, 0, "{}", link.log());
        let value: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(value["event"], "link-ready");
        link.socket = value["socket"].as_str().unwrap().into();
        link
    }

    fn log(&self) -> String {
        std::fs::read_to_string(self.home.path().join("link.log")).unwrap()
    }
}

impl Drop for Link {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[test]
fn cloud_broker_inherited_channel_serves_the_real_link_and_parent_eof_stops_it() {
    let mut link = Link::start();
    let client = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["link", "dial", "--host", HOST, "--service", "ssh", "--socket"])
        .arg(&link.socket)
        .env_clear()
        .env("HOME", link.home.path())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut line = String::new();
    BufReader::new(&link.broker).read_line(&mut line).unwrap();
    let request: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(
        request,
        serde_json::json!({
            "version": 1, "id": 1, "op": "cloud.machine.connect_info", "host": HOST
        })
    );
    writeln!(
        link.broker,
        "{}",
        serde_json::json!({
            "version": 1, "id": 1, "error": { "code": "cloud.machine.not_found" }
        })
    )
    .unwrap();
    let output = client.wait_with_output().unwrap();
    assert_eq!(output.status.code(), Some(2));
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&output.stderr).unwrap()["error_code"],
        "unknown_host"
    );
    link.broker.shutdown(Shutdown::Write).unwrap();
    assert_eq!(link.broker.read(&mut [0]).unwrap(), 0, "parent EOF must end the link");
}
