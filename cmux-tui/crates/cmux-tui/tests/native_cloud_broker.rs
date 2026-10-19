//! Native keys cross only a child-created channel; legacy identity files are not authority.
#![cfg(unix)]

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use std::io::{BufRead as _, BufReader, Read as _, Write as _};
use std::net::Shutdown;
use std::os::fd::{AsRawFd as _, OwnedFd};
use std::os::unix::fs::PermissionsExt as _;
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt as _;
use std::process::{Child, Command, Stdio};
use std::time::Duration;

struct ChildGuard(Child);
impl Drop for ChildGuard {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[test]
fn native_cloud_broker_descriptor_transfer_uses_the_child_key_without_loading_legacy_state() {
    let home = cmux_unix_socket::short_test_dir("ncb");
    let state = home.path().join("native");
    std::fs::create_dir(&state).unwrap();
    std::fs::set_permissions(&state, std::fs::Permissions::from_mode(0o700)).unwrap();
    for name in ["config.json", "peers.json", "private.key"] {
        std::fs::write(state.join(name), b"legacy-must-not-be-read").unwrap();
    }
    let (parent, inherited) = UnixStream::pair().unwrap();
    parent.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let (ready, inherited_ready) = UnixStream::pair().unwrap();
    ready.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let ready_fd = inherited_ready.as_raw_fd();
    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
    command
        .args(["link", "serve", "--native-cloud-broker-fd", "0", "--state-dir"])
        .arg(&state)
        .arg("--ready-fd")
        .arg(ready_fd.to_string())
        .env_clear()
        .env("HOME", home.path())
        .stdin(Stdio::from(OwnedFd::from(inherited)))
        .stdout(Stdio::null())
        .stderr(std::fs::File::create(home.path().join("link.log")).unwrap());
    // SAFETY: only this child's readiness descriptor loses CLOEXEC.
    unsafe {
        command.pre_exec(move || {
            let flags = libc::fcntl(ready_fd, libc::F_GETFD);
            if flags < 0 || libc::fcntl(ready_fd, libc::F_SETFD, flags & !libc::FD_CLOEXEC) < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let child = ChildGuard(command.spawn().unwrap());
    drop(command);
    drop(inherited_ready);
    let (version, descriptor) =
        cmux_unix_socket::descriptor::receive(&parent, 1).unwrap_or_else(|error| {
            panic!("{error}: {}", std::fs::read_to_string(home.path().join("link.log")).unwrap())
        });
    assert_eq!(version, [1]);
    let mut channel = UnixStream::from(descriptor.expect("child-created channel"));
    channel.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    assert_eq!(cmux_link::caller::peer_pid(channel.as_raw_fd()).unwrap(), Some(child.0.id()));
    // SAFETY: F_GETFD reads flags of this owned, valid socket descriptor.
    assert_ne!(unsafe { libc::fcntl(channel.as_raw_fd(), libc::F_GETFD) } & libc::FD_CLOEXEC, 0);
    writeln!(
        channel,
        "{}",
        serde_json::json!({
            "version": 2, "install": "inst_native", "team": format!("team_{}", "a".repeat(20)),
            "mesh": format!("mesh_{}", "0".repeat(26)), "private_key": STANDARD.encode([7u8; 32]),
            "tenant": "tenant_a", "ipv4_cidr": "10.128.0.0/20", "device": format!("dev_{}", "0".repeat(26)),
            "tunnel": {"id": format!("tun_{}", "0".repeat(26)), "meshId": format!("mesh_{}", "0".repeat(26)),
                "deviceId": format!("dev_{}", "0".repeat(26)), "endpointHost": "203.0.113.30", "endpointPort": 51820,
                "serverPublicKey": STANDARD.encode([3u8; 32]), "interfaceAddress": "100.64.0.1/32", "meshAddress": "10.128.0.10",
                "allowedIps": ["10.128.0.0/20"], "mtu": 1280, "persistentKeepaliveSeconds": 25},
        })
    )
    .unwrap();
    let mut line = String::new();
    BufReader::new(ready).read_line(&mut line).unwrap();
    let result: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(result["event"], "link-ready");
    assert_eq!(result["native"], true);
    let secret = x25519_dalek::StaticSecret::from([7u8; 32]);
    assert_eq!(
        result["wg_public_key"],
        STANDARD.encode(x25519_dalek::PublicKey::from(&secret).as_bytes())
    );
    for name in ["config.json", "peers.json", "private.key"] {
        assert_eq!(std::fs::read(state.join(name)).unwrap(), b"legacy-must-not-be-read");
    }
    channel.shutdown(Shutdown::Write).unwrap();
    assert_eq!(channel.read(&mut [0]).unwrap(), 0);
    assert!(
        !std::fs::read_to_string(home.path().join("link.log"))
            .unwrap()
            .contains(&STANDARD.encode([7u8; 32]))
    );
}
