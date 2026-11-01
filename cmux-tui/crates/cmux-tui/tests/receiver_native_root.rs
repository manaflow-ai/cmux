//! The real daemon and receiving child, under the hosted root/work-uid boundary.
#![cfg(target_os = "linux")]

use std::io::{BufRead as _, Read as _};
use std::os::fd::{AsRawFd as _, RawFd};
use std::os::unix::fs::{PermissionsExt as _, chown};
use std::os::unix::net::UnixListener;
use std::os::unix::process::CommandExt as _;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::time::{Duration, Instant};

use base64::{
    Engine as _,
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
};
use cmux_host::cloud::private_bootstrap::NativeBootstrap;
use cmux_link::caller::RootOwnedDaemon;
use cmux_link::root_bootstrap::{Capability, Host, StopReceipt};
use serde_json::json;
use zeroize::Zeroizing;

const WORK_UID: u32 = 65534;

fn ready(fd: RawFd, budget: Duration) {
    let mut poll = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
    // SAFETY: one initialized descriptor lives through this bounded wait.
    assert!(unsafe { libc::poll(&raw mut poll, 1, budget.as_millis() as i32) } > 0);
}

fn drive_until(host: &Host, condition: impl Fn(bool) -> bool) {
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        if condition(host.drive().unwrap()) {
            return;
        }
        let left = deadline.checked_duration_since(Instant::now()).expect("root startup timed out");
        let wake = host.wake_set().unwrap();
        let mut fds = wake.fds();
        // SAFETY: WakeSet retains all initialized descriptors during poll.
        assert!(
            unsafe {
                libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, left.as_millis() as i32)
            } > 0
        );
    }
}

struct Daemon {
    child: Arc<RootOwnedDaemon>,
    home: cmux_unix_socket::TestDir,
    session: PathBuf,
}

impl Daemon {
    fn start(host: &Host) -> Self {
        Self::with_capability(host, Capability::NativeReceiver)
    }

    fn with_capability(host: &Host, capability: Capability) -> Self {
        let home = cmux_unix_socket::short_test_dir("nroot");
        chown(home.path(), Some(WORK_UID), Some(WORK_UID)).unwrap();
        let session = home.path().join("s.sock");
        // The launcher copies this exact-source binary to its traversable
        // private artifact directory. No installed app or user daemon is used.
        let binary = std::env::var_os("CMUX_NATIVE_ROOT_BINARY").expect("hosted launcher binary");
        let mut command = Command::new(binary);
        command
            .args(["--headless", "--socket"])
            .arg(&session)
            .arg("--state")
            .arg(home.path().join("state.json"))
            .current_dir(home.path())
            .env_clear()
            .env("HOME", home.path())
            .env("CMUX_TUI_CONFIG", home.path().join("config.json"))
            .env("CMUX_TUI_STATE_DIR", home.path().join("daemon"))
            .gid(WORK_UID)
            .uid(WORK_UID)
            .stdout(Stdio::null())
            .stderr(std::fs::File::create(home.path().join("daemon.log")).unwrap());
        let child = host.spawn(&mut command, WORK_UID).unwrap();
        let daemon = Self { child, home, session };
        drop(command);
        drive_until(host, |_| host.capability() == Some(capability));
        daemon
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if self.child.try_wait().unwrap().is_none() {
            // SAFETY: this is our retained, unreaped test daemon. It owns no
            // user terminals; production RootOwnedDaemon drop never signals it.
            unsafe { libc::kill(self.child.id() as i32, libc::SIGKILL) };
        }
        let _ = self.child.wait();
    }
}

struct Agent {
    listener: UnixListener,
    directory: PathBuf,
    path: PathBuf,
}

impl Agent {
    fn start() -> Self {
        let path = PathBuf::from(cmux_host::cloud::wire::AGENT_SOCKET);
        let directory = path.parent().unwrap().to_owned();
        // Never remove an existing system agent or borrow another test's path.
        std::fs::create_dir(&directory).expect("hosted runner must have no existing VM agent");
        std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o755)).unwrap();
        let listener = UnixListener::bind(&path).unwrap();
        chown(&path, Some(0), Some(WORK_UID)).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o660)).unwrap();
        Self { listener, directory, path }
    }
}

impl Drop for Agent {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
        let _ = std::fs::remove_dir(&self.directory);
    }
}

fn install_public_key() -> String {
    let install = cmux_server_core::install_key::InstallKey::generate(
        &cmux_server_core::install_key::SystemRandom::new(),
    )
    .unwrap()
    .public_jwk();
    let mut point = vec![4];
    for name in ["x", "y"] {
        point.extend_from_slice(&URL_SAFE_NO_PAD.decode(install[name].as_str().unwrap()).unwrap());
    }
    STANDARD.encode(point)
}

/// Synthetic test WG material and the public contract-vector signing key only.
/// Decode exercises the same strict private frame as production; no secret
/// factory or private-key export is added to the agent API for this fixture.
fn frame() -> Zeroizing<Vec<u8>> {
    let (private, public) = cmux_wg::testing::random_keypair();
    let vector: serde_json::Value =
        serde_json::from_str(include_str!("../../../../schemas/link-token/native.json")).unwrap();
    let header = serde_json::to_vec(&json!({
        "version":2,"generation":"a".repeat(64),
        "binding": {
            "machine":"vm_00000000000000000004", "host":"host_00000000000000000002",
            "epoch":4, "user":"user_00000000000000000004", "install":"inst_00000000000000000004",
            "team":"team_00000000000000000001", "env":"dev", "wg_public_key":STANDARD.encode(public),
            "install_public_key":install_public_key()
        },
        "keyset":{"version":"0123456789abcdef","keys":{"test-k1":{"kty":"OKP","crv":"Ed25519","alg":"EdDSA","kid":"test-k1","x":vector["public_key"]}}}
    })).unwrap();
    let mut bytes = Zeroizing::new((header.len() as u32).to_be_bytes().to_vec());
    bytes.extend_from_slice(&header);
    bytes.extend_from_slice(&private);
    drop(NativeBootstrap::decode(&bytes).unwrap());
    bytes
}

fn hosted_root() {
    assert_eq!(std::env::var("GITHUB_ACTIONS").as_deref(), Ok("true"));
    // SAFETY: geteuid has no preconditions.
    assert_eq!(unsafe { libc::geteuid() }, 0);
}

fn policy_reader(
    listener: &UnixListener,
    daemon: &RootOwnedDaemon,
) -> (std::io::BufReader<std::os::unix::net::UnixStream>, i32) {
    ready(listener.as_raw_fd(), Duration::from_secs(15));
    let (stream, _) = listener.accept().unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    // SAFETY: ucred is plain output data with its exact initialized length.
    let mut peer: libc::ucred = unsafe { std::mem::zeroed() };
    let mut length = size_of_val(&peer) as libc::socklen_t;
    // SAFETY: the socket and correctly sized output pointers are live.
    assert_eq!(
        unsafe {
            libc::getsockopt(
                stream.as_raw_fd(),
                libc::SOL_SOCKET,
                libc::SO_PEERCRED,
                (&raw mut peer).cast(),
                &raw mut length,
            )
        },
        0
    );
    assert_eq!(peer.uid, WORK_UID);
    assert_ne!(
        peer.pid as u32,
        daemon.id(),
        "the daemon fetched in place of its owned receiving child"
    );
    let stat = std::fs::read_to_string(format!("/proc/{}/stat", peer.pid)).unwrap();
    let fields = stat.rsplit_once(')').unwrap().1.split_whitespace().collect::<Vec<_>>();
    assert_eq!(
        fields[1].parse::<u32>().unwrap(),
        daemon.id(),
        "the source reader is not the actual daemon's child"
    );
    let mut reader = std::io::BufReader::new(stream);
    let mut request = String::new();
    reader.read_line(&mut request).unwrap();
    assert_eq!(request, "{\"op\":\"cloud.vm.network_policy\"}\n");
    (reader, peer.pid)
}

#[test]
#[ignore = "requires hosted Linux root; scripts/ci/verify-link-root-boundary.py"]
fn receiver_root_privileged_native_chain_cancels_a_pending_original_policy_read() {
    hosted_root();
    let host = Host::new_native().unwrap();
    let agent = Agent::start();
    let daemon = Daemon::start(&host);
    for _ in 0..2 {
        let ticket = host.new_ticket().unwrap();
        assert!(host.offer(&ticket));
        let request = host.prepare_native(&ticket).expect("current actual Native daemon");
        assert!(host.publish_native(request, frame()));
        drive_until(&host, |sent| sent);
        let (mut reader, pid) = policy_reader(&agent.listener, &daemon.child);
        let entry = cmux_link::entry_path::remote_entry_socket_path(&daemon.session);
        assert!(entry.exists(), "entry was not installed before private child startup");
        // Leave the original-root source read pending. Stop must cancel startup,
        // remove ingress and reap the actual link before root acknowledges.
        assert_eq!(
            host.quiesce(Instant::now() + Duration::from_secs(8)).unwrap(),
            StopReceipt::Acknowledged
        );
        assert!(
            !Path::new(&format!("/proc/{pid}/stat")).exists(),
            "root acknowledged an unreaped receiving child"
        );
        assert!(!entry.exists());
        assert!(
            daemon.child.try_wait().unwrap().is_none(),
            "stopping reception killed the session daemon"
        );
        let mut byte = [0];
        assert_eq!(reader.read(&mut byte).unwrap(), 0, "the canceled source remained connected");
    }
    let log = std::fs::read_to_string(daemon.home.path().join("daemon.log")).unwrap();
    assert!(log.contains("token verifier mode control_plane: authenticated root startup"));
    println!("ROOT_BOUNDARY_EXECUTED native_pending_policy_chain");
}

#[path = "receiver_native_root/encrypted.rs"]
mod encrypted;

#[path = "receiver_native_root/inspection.rs"]
mod inspection;
