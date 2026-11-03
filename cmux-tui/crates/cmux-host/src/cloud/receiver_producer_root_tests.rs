//! Hosted root producer reads the original files and reaches the actual child.
//! HTTP answers are synthetic; install signatures, file fences and IPC are real.
use super::{Lifecycle, NOW, Server, setup_tweaked};
use crate::cloud::bootstrap_role::RoleBridge;
use crate::cloud::client::CloudClient;
use crate::cloud::wire::{AGENT_SOCKET, BOUND_FILE, INSTALL_KEY_FILE, STATE_DIR, WG_KEY_FILE};
use crate::config::Paths;
use std::fs;
use std::io::{BufRead as _, BufReader, Read as _, Write as _};
use std::os::fd::AsRawFd as _;
use std::os::unix::fs::{PermissionsExt as _, chown};
use std::os::unix::net::UnixListener;
use std::os::unix::process::CommandExt as _;
use std::process::{Command, Stdio};
use std::rc::Rc;
use std::sync::Arc;
use std::time::{Duration, Instant};

use base64::{Engine as _, engine::general_purpose::STANDARD};
use cmux_link::caller::RootOwnedDaemon;
use cmux_link::root_bootstrap::{Capability, Host, StopReceipt};
use serde_json::json;

#[path = "receiver_policy_retirement_root_tests.rs"]
mod policy_retirement;

const WORK_UID: u32 = 65534;

fn hosted_root() {
    assert_eq!(std::env::var("GITHUB_ACTIONS").as_deref(), Ok("true"));
    // SAFETY: geteuid has no preconditions.
    assert_eq!(unsafe { libc::geteuid() }, 0);
}

#[track_caller]
fn drive_until(host: &Host, mut condition: impl FnMut(bool) -> bool) {
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        if condition(host.drive().unwrap()) {
            return;
        }
        let left =
            deadline.checked_duration_since(Instant::now()).expect("root producer timed out");
        let wake = host.wake_set().unwrap();
        let mut fds = wake.fds();
        // SAFETY: WakeSet retains every initialized descriptor during poll.
        assert!(
            unsafe {
                libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, left.as_millis() as i32)
            } > 0
        );
    }
}

#[test]
#[ignore = "requires hosted Linux root; scripts/ci/verify-link-root-boundary.py"]
fn receiver_root_privileged_original_producer_renews_generation_after_each_child_attempt() {
    hosted_root();
    for observe_ready in [false, true] {
        let host = Arc::new(Host::new_native().unwrap());
        let agent = Agent::start();
        let daemon = Daemon::start(&host);
        let root = tempfile::tempdir().unwrap();
        let paths = Paths::new(root.path());
        let mut client = original_client(&paths, None);
        let original = identity_bytes(&paths);
        let mut role = RoleBridge::new(host.clone());
        let mut worker = role.start().unwrap();
        worker.enrolled();
        worker.drive();
        assert!(worker.publish_original(&paths, "instance-a", &mut client, NOW).unwrap());
        drive_until(&host, |sent| sent);
        let (mut reader, first_pid) = agent.reader(&daemon.child);
        let first = client
            .receiver_lifecycle(
                cmux_cloud_wire::CloudVmReceiverLifecycleParamsPhase::Read,
                None,
                None,
                NOW,
            )
            .unwrap();
        assert_eq!(first.phase, cmux_cloud_wire::CloudVmReceiverLifecycleResultPhase::Starting);
        if observe_ready {
            let reply = crate::cloud::receiver_files::reply(&paths, "instance-a", &mut client, NOW)
                .unwrap();
            reader.get_mut().write_all(format!("{reply}\n").as_bytes()).unwrap();
            drive_until(&host, |_| {
                worker.publish_original(&paths, "instance-a", &mut client, NOW).unwrap();
                worker.is_ready()
            });
        }
        // The pid was authenticated as this exact daemon's receiving child.
        // SAFETY: signal only that retained fixture child's authenticated pid,
        // including the attempt before READY; no unrelated process is used.
        assert_eq!(unsafe { libc::kill(first_pid, libc::SIGKILL) }, 0);
        drop(reader);
        drive_until(&host, |_| {
            worker.publish_original(&paths, "instance-a", &mut client, NOW).is_err()
        });
        assert!(!std::path::Path::new(&format!("/proc/{first_pid}/stat")).exists());
        let stopped = client
            .receiver_lifecycle(
                cmux_cloud_wire::CloudVmReceiverLifecycleParamsPhase::Read,
                None,
                None,
                NOW,
            )
            .unwrap();
        assert_eq!(stopped.phase, cmux_cloud_wire::CloudVmReceiverLifecycleResultPhase::Stopped);
        assert_eq!(stopped.generation, first.generation);
        assert!(worker.publish_original(&paths, "instance-a", &mut client, NOW).unwrap());
        drive_until(&host, |sent| sent);
        let (mut reader, second_pid) = agent.reader(&daemon.child);
        assert_ne!(first_pid, second_pid);
        let second = client
            .receiver_lifecycle(
                cmux_cloud_wire::CloudVmReceiverLifecycleParamsPhase::Read,
                None,
                None,
                NOW,
            )
            .unwrap();
        assert_eq!(second.phase, cmux_cloud_wire::CloudVmReceiverLifecycleResultPhase::Starting);
        assert_ne!(second.generation, first.generation);
        let reply =
            crate::cloud::receiver_files::reply(&paths, "instance-a", &mut client, NOW).unwrap();
        reader.get_mut().write_all(format!("{reply}\n").as_bytes()).unwrap();
        drive_until(&host, |_| {
            worker.publish_original(&paths, "instance-a", &mut client, NOW).unwrap();
            worker.is_ready()
        });
        let ready = client
            .receiver_lifecycle(
                cmux_cloud_wire::CloudVmReceiverLifecycleParamsPhase::Read,
                None,
                None,
                NOW,
            )
            .unwrap();
        assert_eq!(ready.phase, cmux_cloud_wire::CloudVmReceiverLifecycleResultPhase::Ready);
        assert_eq!(ready.generation, second.generation);
        assert_eq!(
            role.stop(Instant::now() + Duration::from_secs(8)).unwrap(),
            StopReceipt::Acknowledged
        );
        worker.retire(&mut client, NOW).unwrap();
        assert!(!std::path::Path::new(&format!("/proc/{second_pid}/stat")).exists());
        assert!(daemon.child.try_wait().unwrap().is_none());
        assert!(!cmux_link::entry_path::remote_entry_socket_path(&daemon.session).exists());
        assert!(
            identity_bytes(&paths) == original,
            "restart rotated the original protected identity"
        );
        assert!(!worker.publish_original(&paths, "instance-a", &mut client, NOW).unwrap());
    }
    println!("ROOT_BOUNDARY_EXECUTED native_original_generation_restart");
}

struct Daemon {
    child: Arc<RootOwnedDaemon>,
    _home: tempfile::TempDir,
    session: std::path::PathBuf,
}

impl Daemon {
    fn start(host: &Host) -> Self {
        let home = tempfile::Builder::new().prefix("rp-").tempdir().unwrap();
        chown(home.path(), Some(WORK_UID), Some(WORK_UID)).unwrap();
        let session = home.path().join("s.sock");
        let mut command = Command::new(
            std::env::var_os("CMUX_NATIVE_ROOT_BINARY").expect("hosted exact-source binary"),
        );
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
            .stderr(fs::File::create(home.path().join("daemon.log")).unwrap());
        let child = host.spawn(&mut command, WORK_UID).unwrap();
        drop(command);
        let daemon = Self { child, _home: home, session };
        drive_until(host, |_| host.capability() == Some(Capability::NativeReceiver));
        daemon
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if self.child.try_wait().unwrap().is_none() {
            // SAFETY: only our retained, unreaped test daemon, with no terminals.
            unsafe { libc::kill(self.child.id() as i32, libc::SIGKILL) };
        }
        let _ = self.child.wait();
    }
}

struct Agent {
    listener: UnixListener,
    directory: std::path::PathBuf,
}

impl Agent {
    fn start() -> Self {
        let path = std::path::Path::new(AGENT_SOCKET);
        let directory = path.parent().unwrap().to_owned();
        fs::create_dir(&directory).expect("never replace an existing VM agent");
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o755)).unwrap();
        let listener = UnixListener::bind(path).unwrap();
        chown(path, Some(0), Some(WORK_UID)).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o660)).unwrap();
        Self { listener, directory }
    }

    fn reader(&self, daemon: &RootOwnedDaemon) -> (BufReader<std::os::unix::net::UnixStream>, i32) {
        let mut poll =
            libc::pollfd { fd: self.listener.as_raw_fd(), events: libc::POLLIN, revents: 0 };
        // SAFETY: one live initialized descriptor is retained for this wait.
        assert!(unsafe { libc::poll(&raw mut poll, 1, 15_000) } > 0);
        let (stream, _) = self.listener.accept().unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(8))).unwrap();
        // SAFETY: ucred is a plain output buffer with its exact initialized size.
        let mut peer: libc::ucred = unsafe { std::mem::zeroed() };
        let mut length = size_of_val(&peer) as libc::socklen_t;
        // SAFETY: the live socket and correctly sized output pointers are valid.
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
        assert_eq!(length as usize, size_of_val(&peer));
        assert_eq!(peer.uid, WORK_UID);
        assert_ne!(peer.pid as u32, daemon.id());
        let stat = fs::read_to_string(format!("/proc/{}/stat", peer.pid)).unwrap();
        let fields = stat.rsplit_once(')').unwrap().1.split_whitespace().collect::<Vec<_>>();
        assert_eq!(fields[1].parse::<u32>().unwrap(), daemon.id());
        let mut reader = BufReader::new(stream);
        let mut request = String::new();
        reader.read_line(&mut request).unwrap();
        assert_eq!(request, "{\"op\":\"cloud.vm.network_policy\"}\n");
        (reader, peer.pid)
    }
}

impl Drop for Agent {
    fn drop(&mut self) {
        let _ = fs::remove_file(self.directory.join("agent.sock"));
        let _ = fs::remove_dir(&self.directory);
    }
}

fn original_client(paths: &Paths, after: Option<Rc<dyn Fn()>>) -> CloudClient<Server> {
    setup_tweaked(
        |_, _| {},
        |key, bound, wg| {
            for (name, value) in [
                (BOUND_FILE, serde_json::to_value(bound).unwrap()),
                (INSTALL_KEY_FILE, json!({"instance_id":"instance-a","pkcs8":key.pkcs8_base64url()})),
                (WG_KEY_FILE, json!({"instance_id":"instance-a","private_key":STANDARD.encode([9u8;32]),"public_key":wg})),
            ] {
                let path = paths.at(name);
                fs::create_dir_all(path.parent().unwrap()).unwrap();
                fs::write(&path, value.to_string()).unwrap();
                fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
            }
            fs::set_permissions(paths.at(STATE_DIR), fs::Permissions::from_mode(0o700)).unwrap();
        },
        after,
        |server| { server.lifecycle = Some(Rc::new(std::cell::RefCell::new(Lifecycle { phase: "idle".into(), generation: "0".repeat(64), counter: 0 }))); },
    ).0
}

fn identity_bytes(paths: &Paths) -> Vec<Vec<u8>> {
    [BOUND_FILE, INSTALL_KEY_FILE, WG_KEY_FILE]
        .iter()
        .map(|name| fs::read(paths.at(name)).unwrap())
        .collect()
}

#[test]
#[ignore = "requires hosted Linux root; scripts/ci/verify-link-root-boundary.py"]
fn receiver_root_privileged_original_producer_reaches_owned_child_without_export_or_rotation() {
    hosted_root();
    let host = Arc::new(Host::new_native().unwrap());
    let agent = Agent::start();
    let daemon = Daemon::start(&host);
    let root = tempfile::tempdir().unwrap();
    let paths = Paths::new(root.path());
    let mut client = original_client(&paths, None);
    let original = identity_bytes(&paths);
    let mut role = RoleBridge::new(host.clone());
    let mut worker = role.start().unwrap();
    worker.enrolled();
    worker.drive();
    assert!(worker.publish_original(&paths, "instance-a", &mut client, NOW).unwrap());
    drive_until(&host, |sent| sent);
    let (mut reader, pid) = agent.reader(&daemon.child);
    let entry = cmux_link::entry_path::remote_entry_socket_path(&daemon.session);
    assert!(entry.exists());
    // Leave the child policy read pending: root must cancel/reap through the
    // same private role whose producer read the original protected files.
    assert_eq!(
        role.stop(Instant::now() + Duration::from_secs(8)).unwrap(),
        StopReceipt::Acknowledged
    );
    assert!(!std::path::Path::new(&format!("/proc/{pid}/stat")).exists());
    assert!(!entry.exists());
    assert_eq!(reader.read(&mut [0]).unwrap(), 0);
    assert!(daemon.child.try_wait().unwrap().is_none());
    worker.retire(&mut client, NOW).unwrap();
    assert!(identity_bytes(&paths) == original, "producer rewrote original private identity");
    println!("ROOT_BOUNDARY_EXECUTED native_original_producer_chain");
}

#[test]
#[ignore = "requires hosted Linux root; scripts/ci/verify-link-root-boundary.py"]
fn receiver_root_privileged_original_producer_cannot_deliver_after_stop_during_cloud_read() {
    hosted_root();
    let host = Arc::new(Host::new_native().unwrap());
    let daemon = Daemon::start(&host);
    let root = tempfile::tempdir().unwrap();
    let paths = Paths::new(root.path());
    let stopping = host.clone();
    let mut client = original_client(
        &paths,
        Some(Rc::new(move || {
            // No frame has been published, so there is no receiving child to
            // acknowledge. Stop still fences the pending producer request.
            assert_eq!(
                stopping.quiesce(Instant::now() + Duration::from_secs(8)).unwrap(),
                StopReceipt::NoReceiver
            );
        })),
    );
    let original = identity_bytes(&paths);
    let mut role = RoleBridge::new(host.clone());
    let mut worker = role.start().unwrap();
    worker.enrolled();
    worker.drive();
    assert!(worker.publish_original(&paths, "instance-a", &mut client, NOW).is_err());
    worker.retire(&mut client, NOW).unwrap();
    assert!(!host.drive().unwrap(), "a canceled read published a new role");
    assert!(!cmux_link::entry_path::remote_entry_socket_path(&daemon.session).exists());
    assert!(daemon.child.try_wait().unwrap().is_none());
    assert!(identity_bytes(&paths) == original, "canceled producer rewrote identity");
    println!("ROOT_BOUNDARY_EXECUTED native_canceled_producer_read");
}
