use std::io::{BufRead as _, BufReader, Write as _};
use std::net::SocketAddr;
use std::os::fd::{AsRawFd as _, OwnedFd};
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt as _;
use std::process::{Child, Command, Stdio};
use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use cmux_link::overlay_addr::overlay_address;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt as _, AsyncWriteExt as _};

pub const HOST: &str = "host_11111111111111111111";
pub const INSTALL: &str = "inst_native";
pub const MESH: &str = "mesh_00000000000000000000000000";

pub struct TaskGuard<T>(pub tokio::task::JoinHandle<T>);
impl<T> Drop for TaskGuard<T> {
    fn drop(&mut self) {
        self.0.abort();
    }
}

pub fn bootstrap(key: [u8; 32], server: [u8; 32], endpoint: SocketAddr) -> Value {
    json!({"version": 2, "install": INSTALL, "team": format!("team_{}", "a".repeat(20)),
        "mesh": MESH, "tenant": "tenant_a", "ipv4_cidr": "10.200.0.0/20",
        "device": format!("dev_{}", "0".repeat(26)), "private_key": STANDARD.encode(key),
        "tunnel": {"id": format!("tun_{}", "0".repeat(26)), "meshId": MESH,
            "deviceId": format!("dev_{}", "0".repeat(26)), "endpointHost": endpoint.ip().to_string(),
            "endpointPort": endpoint.port(), "serverPublicKey": STANDARD.encode(server),
            "interfaceAddress": "10.200.0.1/32", "meshAddress": "10.200.0.1",
            "allowedIps": ["10.200.0.0/20", "fdcc::/64"], "mtu": 1280, "persistentKeepaliveSeconds": 25}})
}

pub struct Link {
    pub home: tempfile::TempDir,
    child: Child,
    channel: Option<UnixStream>,
    readiness: Option<UnixStream>,
}
impl Drop for Link {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Link {
    pub fn start(bootstrap: Value) -> Self {
        let home = cmux_unix_socket::short_test_dir("ncg");
        let state = home.path().join("native");
        let (parent, inherited) = UnixStream::pair().unwrap();
        parent.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let (readiness, inherited_ready) = UnixStream::pair().unwrap();
        readiness.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let ready_fd = inherited_ready.as_raw_fd();
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .args(["link", "serve", "--native-cloud-broker-fd", "0", "--state-dir"])
            .arg(state)
            .arg("--ready-fd")
            .arg(ready_fd.to_string())
            .env_clear()
            .env("HOME", home.path())
            .stdin(Stdio::from(OwnedFd::from(inherited)))
            .stdout(Stdio::null())
            .stderr(std::fs::File::create(home.path().join("link.log")).unwrap());
        // SAFETY: only the child's owned readiness fd loses CLOEXEC.
        unsafe {
            command.pre_exec(move || {
                let flags = libc::fcntl(ready_fd, libc::F_GETFD);
                if flags < 0 || libc::fcntl(ready_fd, libc::F_SETFD, flags & !libc::FD_CLOEXEC) < 0
                {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let child = command.spawn().unwrap();
        drop(command);
        drop(inherited_ready);
        let mut link = Self { home, child, channel: None, readiness: Some(readiness) };
        let (_, fd) = cmux_unix_socket::descriptor::receive(&parent, 1).unwrap();
        let mut channel = UnixStream::from(fd.unwrap());
        writeln!(channel, "{bootstrap}").unwrap();
        link.channel = Some(channel);
        link
    }
    pub fn ready(&mut self) -> (tokio::net::UnixStream, String) {
        let mut line = String::new();
        BufReader::new(self.readiness.take().unwrap()).read_line(&mut line).unwrap();
        assert!(
            !line.is_empty(),
            "link never became ready: {}",
            std::fs::read_to_string(self.home.path().join("link.log")).unwrap()
        );
        let ready: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(ready["native"], true);
        let channel = self.channel.take().unwrap();
        channel.set_nonblocking(true).unwrap();
        (
            tokio::net::UnixStream::from_std(channel).unwrap(),
            ready["socket"].as_str().unwrap().to_string(),
        )
    }
}

pub async fn broker(channel: tokio::net::UnixStream, key: [u8; 32]) {
    let mut channel = tokio::io::BufReader::new(channel);
    loop {
        let mut line = String::new();
        if channel.read_line(&mut line).await.unwrap() == 0 {
            return;
        }
        let call: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(call["host"], HOST);
        let value = if call["op"] == "cloud.machine.connect_info" {
            json!({"host": HOST, "machine": "vm_11111111111111111111", "epoch": 1, "state": "running",
                "network": {"tenant": "tenant_a", "mesh": MESH, "ipv4_cidr": "10.200.0.0/20", "ipv4": "10.200.0.2"},
                "peer": {"wg_public_key": STANDARD.encode(key), "overlay_address": overlay_address(HOST).to_string(), "vpc_endpoint": null, "public_ipv6": null},
                "gateway": null, "services": ["ssh"], "revision": "1"})
        } else {
            assert_eq!(call["op"], "cloud.machine.link_token");
            assert_eq!(call["services"], json!(["ssh"]));
            json!({"host": HOST, "token": "one-native-dial", "expires_at": 9999999999999_i64, "epoch": 1, "services": ["ssh"]})
        };
        let mut answer =
            serde_json::to_vec(&json!({"version": 1, "id": call["id"], "value": value})).unwrap();
        answer.push(b'\n');
        channel.get_mut().write_all(&answer).await.unwrap();
    }
}
