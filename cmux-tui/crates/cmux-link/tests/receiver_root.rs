//! Root-only cases run explicitly on hosted Linux, never on the user's Mac.
#![cfg(unix)]

use cmux_link::caller;
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;

#[test]
fn receiver_root_keeps_ordinary_same_user_and_parent_checks() {
    let (a, _b) = UnixStream::pair().unwrap();
    caller::verify(&a).unwrap();
    assert!(caller::verify_inherited_parent(a.as_raw_fd()).is_err());
}

#[cfg(target_os = "linux")]
mod linux {
    use super::*;
    use std::io::{Read, Write};
    use std::os::fd::OwnedFd;
    use std::os::unix::process::{CommandExt, ExitStatusExt};
    use std::process::{Command, Stdio};
    use std::time::Duration;

    use caller::RootOwnedDaemon;

    const FIXTURE: &str = "CMUX_RECEIVER_ROOT_FIXTURE";
    const WORK_UID: u32 = 65534;

    fn root() {
        // SAFETY: geteuid has no preconditions.
        assert_eq!(unsafe { libc::geteuid() }, 0, "run the hosted root boundary verifier");
    }

    #[test]
    #[ignore = "private re-exec fixture; not a standalone test"]
    fn receiver_root_fixture() {
        let Some(mode) = std::env::var_os(FIXTURE) else { return };
        if mode == "fd_probe" {
            let mut kind = 0_i32;
            let mut size = size_of_val(&kind) as libc::socklen_t;
            // SAFETY: correctly sized live output buffers; fd0 may be closed.
            let result = unsafe {
                libc::getsockopt(
                    0,
                    libc::SOL_SOCKET,
                    libc::SO_TYPE,
                    (&raw mut kind).cast(),
                    &raw mut size,
                )
            };
            assert!(result != 0 || kind != libc::SOCK_STREAM, "private stdin leaked across exec");
            return;
        }
        if mode == "legacy_transport" {
            // A lifetime-only recipient recognizes/seals the common v1
            // startup prefix, but cannot accept a Native role or private data.
            use std::os::fd::FromRawFd;
            // SAFETY: fcntl validates stdin and returns a fresh descriptor.
            let fd = unsafe { libc::fcntl(0, libc::F_DUPFD_CLOEXEC, 3) };
            assert!(fd >= 0);
            // SAFETY: fd is a new exclusively owned duplicate.
            let mut parent = unsafe { UnixStream::from_raw_fd(fd) };
            caller::verify_inherited_root_parent(parent.as_raw_fd()).unwrap();
            let mut prefix = [0; 4];
            parent.read_exact(&mut prefix).unwrap();
            assert_eq!(&prefix, b"CMR\x01");
            // SAFETY: seal this private inherited descriptor before any exec.
            assert_eq!(unsafe { libc::fcntl(0, libc::F_SETFD, libc::FD_CLOEXEC) }, 0);
            let (mut control, host) = UnixStream::pair().unwrap();
            cmux_unix_socket::descriptor::send(&parent, &[1], host.as_raw_fd()).unwrap();
            drop(host);
            // No role descriptor, and therefore no key, may reach v1 even
            // if a lifetime-only consumer stays connected indefinitely.
            assert_eq!(control.read(&mut [0]).unwrap(), 0);
            return;
        }
        if mode == "transport" || mode == "native_transport" || mode == "native_delayed_drain" {
            let mut daemon = cmux_link::root_bootstrap::Daemon::from_stdin()
                .unwrap()
                .expect("the spawner discarded its private root channel");
            if mode != "transport" {
                daemon.native_permit().expect("root Native startup was not recognized");
                let gate = (mode == "native_delayed_drain")
                    .then(|| std::env::var_os("CMUX_RECEIVER_DRAIN_GATE").unwrap());
                daemon
                    .attach_native(move |mut role, stop| {
                        role.set_nonblocking(false)?;
                        role.set_read_timeout(Some(Duration::from_secs(10)))?;
                        let mut payload = [0; 32];
                        role.read_exact(&mut payload)?;
                        assert_eq!(payload, [7; 32]);
                        let mut gate = gate.as_ref().map(UnixStream::connect).transpose()?;
                        if let Some(gate) = &mut gate {
                            // Queue READY without allowing it to stand for drain.
                            role.write_all(&[2])?;
                            gate.set_read_timeout(Some(Duration::from_secs(10)))?;
                            gate.write_all(&[0])?;
                        }
                        role.set_nonblocking(true)?;
                        let mut fds = [
                            libc::pollfd { fd: role.as_raw_fd(), events: libc::POLLIN, revents: 0 },
                            libc::pollfd { fd: stop.as_raw_fd(), events: libc::POLLIN, revents: 0 },
                        ];
                        // SAFETY: both sockets remain owned through the wait.
                        assert!(unsafe { libc::poll(fds.as_mut_ptr(), 2, 10_000) } > 0);
                        if let Some(gate) = &mut gate {
                            gate.write_all(&[1])?;
                            let mut release = [0];
                            gate.read_exact(&mut release)?;
                            assert_eq!(release, [1]);
                        }
                        Ok(())
                    })
                    .unwrap();
            }
            let probe = Command::new(std::env::current_exe().unwrap())
                .args(["--ignored", "--exact", "linux::receiver_root_fixture"])
                .env_clear()
                .env(FIXTURE, "fd_probe")
                .stdin(Stdio::inherit())
                .stdout(Stdio::null())
                .stderr(Stdio::inherit())
                .status()
                .unwrap();
            assert!(probe.success());
            daemon.wait().unwrap();
            return;
        }
        // SAFETY: dup returns a new descriptor, owned only by this stream.
        let fd = unsafe { libc::fcntl(0, libc::F_DUPFD_CLOEXEC, 3) };
        assert!(fd >= 0);
        use std::os::fd::FromRawFd;
        if mode == "unpriv_capture" {
            // SAFETY: fd is a newly duplicated, exclusively owned descriptor.
            let mut parent = unsafe { std::fs::File::from_raw_fd(fd) };
            let (child, inherited) = spawn("owned", false);
            let owner = RootOwnedDaemon::capture(child, WORK_UID);
            let (_, channel) = cmux_unix_socket::descriptor::receive(&inherited, 1).unwrap();
            let channel = UnixStream::from(channel.unwrap());
            channel.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
            caller::verify(&channel).unwrap();
            assert!(
                owner.verify(&channel).is_err(),
                "an unprivileged owner asserted root authority"
            );
            finish(owner, channel);
            parent.write_all(&[1]).unwrap();
            return;
        }
        if mode == "parent" || mode == "relay" {
            // SAFETY: fd is newly owned. File performs only the response
            // write, including when the caller supplies a datagram socket.
            let mut channel = unsafe { std::fs::File::from_raw_fd(fd) };
            let accepted = if mode == "relay" {
                let (mut child, mut peer) = spawn("parent", false);
                let mut accepted = [0; 2];
                peer.read_exact(&mut accepted).unwrap();
                assert!(child.wait().unwrap().success());
                accepted
            } else {
                [
                    u8::from(caller::verify_inherited_root_parent(channel.as_raw_fd()).is_ok()),
                    u8::from(caller::verify_inherited_parent(channel.as_raw_fd()).is_ok()),
                ]
            };
            channel.write_all(&accepted).unwrap();
            return;
        }
        // SAFETY: fd is the fresh owned descriptor returned by F_DUPFD_CLOEXEC.
        let inherited = unsafe { UnixStream::from_raw_fd(fd) };
        let (mut child, host) = UnixStream::pair().unwrap();
        cmux_unix_socket::descriptor::send(&inherited, &[1], host.as_raw_fd()).unwrap();
        drop(host);
        child.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        loop {
            let mut byte = [0];
            if child.read_exact(&mut byte).is_err() || byte == [b'x'] {
                return;
            }
            child.write_all(&byte).unwrap();
        }
    }

    fn command(mode: &str, inherited: OwnedFd, drop_uid: bool) -> std::process::Child {
        let mut command = Command::new(std::env::current_exe().unwrap());
        command
            .args(["--ignored", "--exact", "linux::receiver_root_fixture"])
            .env_clear()
            .env(FIXTURE, mode)
            .stdin(Stdio::from(inherited))
            .stdout(Stdio::null())
            .stderr(Stdio::inherit());
        if drop_uid {
            command.uid(WORK_UID).gid(WORK_UID);
        }
        command.spawn().unwrap()
    }

    fn spawn(mode: &str, drop_uid: bool) -> (std::process::Child, UnixStream) {
        let (host, inherited) = UnixStream::pair().unwrap();
        host.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let child = command(mode, OwnedFd::from(inherited), drop_uid);
        (child, host)
    }

    fn connected(uid: u32) -> (RootOwnedDaemon, UnixStream, UnixStream) {
        let (child, inherited) = spawn("owned", true);
        let child = RootOwnedDaemon::capture(child, uid);
        let (bytes, channel) = cmux_unix_socket::descriptor::receive(&inherited, 1).unwrap();
        assert_eq!(bytes, [1]);
        let channel = UnixStream::from(channel.unwrap());
        channel.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        (child, channel, inherited)
    }

    fn finish(child: RootOwnedDaemon, mut channel: UnixStream) {
        channel.write_all(b"x").unwrap();
        let mut eof = [0];
        assert_eq!(channel.read(&mut eof).unwrap(), 0);
        assert!(child.wait().unwrap().success());
        assert!(child.verify(&channel).is_err(), "an exited daemon retained bootstrap authority");
    }

    #[test]
    #[ignore = "requires Linux root; scripts/ci/verify-link-root-boundary.py"]
    fn receiver_root_privileged_authenticates_the_dropped_uid_owned_child() {
        root();
        let (child, mut channel, inherited) = connected(WORK_UID);
        assert!(caller::verify(&channel).is_err(), "ordinary same-user admission was widened");
        assert!(
            child.verify(&inherited).is_err(),
            "an inherited creator pid substituted for child"
        );
        child.verify(&channel).unwrap();
        channel.write_all(b"k").unwrap();
        let mut reply = [0];
        channel.read_exact(&mut reply).unwrap();
        assert_eq!(reply, [b'k']);
        finish(child, channel);
        println!("ROOT_BOUNDARY_EXECUTED owned_child_cross_uid");
    }

    #[test]
    #[ignore = "requires Linux root; scripts/ci/verify-link-root-boundary.py"]
    fn receiver_root_privileged_authenticates_only_the_actual_root_parent() {
        root();
        let (mut child, mut channel) = spawn("parent", true);
        let mut accepted = [0; 2];
        channel.read_exact(&mut accepted).unwrap();
        assert!(child.wait().unwrap().success());
        assert_eq!(accepted, [1, 0], "root parent refused or ordinary same-user check widened");
        let (mut child, mut channel) = spawn("relay", true);
        channel.read_exact(&mut accepted).unwrap();
        assert!(child.wait().unwrap().success());
        assert_eq!(accepted, [0, 1], "a non-root parent promoted its channel to root");
        let (host, inherited) = std::os::unix::net::UnixDatagram::pair().unwrap();
        host.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let mut child = command("parent", OwnedFd::from(inherited), true);
        assert_eq!(host.recv(&mut accepted).unwrap(), 2);
        assert!(child.wait().unwrap().success());
        assert_eq!(accepted, [0, 0], "a datagram descriptor became a bootstrap stream");
        let (self_socket, _other) = UnixStream::pair().unwrap();
        assert!(caller::verify_inherited_root_parent(self_socket.as_raw_fd()).is_err());
        println!("ROOT_BOUNDARY_EXECUTED inherited_root_parent");
    }

    #[test]
    #[ignore = "requires Linux root; scripts/ci/verify-link-root-boundary.py"]
    fn receiver_root_privileged_rejects_another_child_and_another_uid() {
        root();
        let (first, channel, _inherited) = connected(WORK_UID);
        let (second, other, _other_inherited) = connected(WORK_UID);
        assert!(first.verify(&other).is_err());
        let (wrong_uid, wrong, _wrong_inherited) = connected(WORK_UID - 1);
        assert!(wrong_uid.verify(&wrong).is_err());
        finish(first, channel);
        finish(second, other);
        finish(wrong_uid, wrong);
        let (mut unprivileged, mut channel) = spawn("unpriv_capture", true);
        let mut refused = [0];
        channel.read_exact(&mut refused).unwrap();
        assert!(unprivileged.wait().unwrap().success());
        assert_eq!(refused, [1]);
        println!("ROOT_BOUNDARY_EXECUTED unrelated_child_and_uid_refused");
    }

    #[test]
    #[ignore = "requires Linux root; scripts/ci/verify-link-root-boundary.py"]
    fn receiver_root_privileged_owner_drop_preserves_the_session_daemon() {
        root();
        let (child, mut channel, _inherited) = connected(WORK_UID);
        let pid = child.id();
        drop(child);
        channel.write_all(b"a").unwrap();
        let mut reply = [0];
        channel.read_exact(&mut reply).unwrap();
        assert_eq!(reply, [b'a'], "dropping the host owner killed the session daemon");
        channel.write_all(b"x").unwrap();
        let mut status = 0;
        // SAFETY: pid came from our actual unreaped child, not external state.
        assert_eq!(unsafe { libc::waitpid(pid as i32, &mut status, 0) }, pid as i32);
        assert!(libc::WIFEXITED(status));
        println!("ROOT_BOUNDARY_EXECUTED daemon_survives_owner_drop");
    }

    fn drive_until(host: &cmux_link::root_bootstrap::Host, condition: impl Fn(bool) -> bool) {
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        loop {
            let sent = host.drive().unwrap();
            if condition(sent) {
                return;
            }
            let left = deadline
                .checked_duration_since(std::time::Instant::now())
                .expect("private root transport did not progress");
            let wake = host.wake_set().unwrap();
            let mut fds = wake.fds();
            // SAFETY: WakeSet retains all initialized descriptors through poll.
            assert!(
                unsafe {
                    libc::poll(
                        fds.as_mut_ptr(),
                        fds.len() as libc::nfds_t,
                        left.as_millis().clamp(1, i32::MAX as u128) as i32,
                    )
                } > 0
            );
        }
    }

    #[test]
    #[ignore = "requires Linux root; scripts/ci/verify-link-root-boundary.py"]
    fn receiver_root_privileged_delivers_and_quiesces_the_post_start_role() {
        use cmux_link::root_bootstrap::{Capability, Host, StopReceipt};
        root();
        let host = Host::new().unwrap();
        let first = host.new_ticket().unwrap();
        let mut command = Command::new(std::env::current_exe().unwrap());
        command
            .args(["--ignored", "--exact", "linux::receiver_root_fixture"])
            .env_clear()
            .env(FIXTURE, "transport")
            .uid(WORK_UID)
            .gid(WORK_UID)
            .stdout(Stdio::null())
            .stderr(Stdio::inherit());
        let child = host.spawn(&mut command, WORK_UID).unwrap();
        drop(command);
        // The daemon is authenticated before any enrollment offer is made.
        drive_until(&host, |_| host.capability().is_some());
        assert_eq!(host.capability(), Some(Capability::LifetimeOnly));
        assert!(host.offer(&first));
        drive_until(&host, |sent| sent);
        assert_eq!(
            host.quiesce(std::time::Instant::now() + Duration::from_secs(2)).unwrap(),
            StopReceipt::Acknowledged
        );
        assert!(!host.offer(&first), "a late enrollment callback reopened a stopped role");
        let second = host.new_ticket().unwrap();
        assert!(host.offer(&second));
        drive_until(&host, |sent| sent);
        host.invalidate();
        assert!(!host.offer(&second));
        let third = host.new_ticket().unwrap();
        assert!(host.offer(&third));
        drive_until(&host, |sent| sent);
        assert_eq!(
            host.quiesce(std::time::Instant::now() + Duration::from_secs(2)).unwrap(),
            StopReceipt::Acknowledged
        );
        let replacement_ticket = host.new_ticket().unwrap();
        assert!(host.offer(&replacement_ticket));
        // The worker can observe EOF before LinuxPlatform handles the exit.
        // SAFETY: this is our still-owned, unreaped fixture child.
        assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGTERM) }, 0);
        assert_eq!(child.wait().unwrap().signal(), Some(libc::SIGTERM));
        assert!(host.drive().is_err());
        assert_eq!(host.capability(), None);
        host.daemon_exited();
        let mut command = Command::new(std::env::current_exe().unwrap());
        command
            .args(["--ignored", "--exact", "linux::receiver_root_fixture"])
            .env_clear()
            .env(FIXTURE, "transport")
            .uid(WORK_UID)
            .gid(WORK_UID)
            .stdout(Stdio::null())
            .stderr(Stdio::inherit());
        let replacement = host.spawn(&mut command, WORK_UID).unwrap();
        drop(command);
        drive_until(&host, |sent| sent);
        assert_eq!(
            host.quiesce(std::time::Instant::now() + Duration::from_secs(2)).unwrap(),
            StopReceipt::Acknowledged
        );
        assert!(!host.offer(&replacement_ticket));
        host.detach();
        assert!(replacement.wait().unwrap().success());
        println!("ROOT_BOUNDARY_EXECUTED channel_lifetime");
    }

    fn transport_command(mode: &str) -> Command {
        let mut command = Command::new(std::env::current_exe().unwrap());
        command
            .args(["--ignored", "--exact", "linux::receiver_root_fixture"])
            .env_clear()
            .env(FIXTURE, mode)
            .uid(WORK_UID)
            .gid(WORK_UID)
            .stdout(Stdio::null())
            .stderr(Stdio::inherit());
        command
    }

    #[test]
    #[ignore = "requires Linux root; scripts/ci/verify-link-root-boundary.py"]
    fn receiver_root_privileged_native_payload_requires_startup_support_and_current_child() {
        use cmux_link::root_bootstrap::{Capability, Host, StopReceipt};
        use zeroize::Zeroizing;
        root();
        let legacy = Host::new_native().unwrap();
        let ticket = legacy.new_ticket().unwrap();
        assert!(legacy.offer(&ticket));
        let mut command = transport_command("legacy_transport");
        let child = legacy.spawn(&mut command, WORK_UID).unwrap();
        drop(command);
        drive_until(&legacy, |_| legacy.capability().is_some());
        assert_eq!(legacy.capability(), Some(Capability::LifetimeOnly));
        assert!(legacy.prepare_native(&ticket).is_none());
        assert_eq!(
            legacy.quiesce(std::time::Instant::now() + Duration::from_secs(2)).unwrap(),
            StopReceipt::NoReceiver
        );
        legacy.detach();
        assert!(child.wait().unwrap().success());

        let host = Host::new_native().unwrap();
        let first = host.new_ticket().unwrap();
        assert!(host.offer(&first));
        let mut command = transport_command("native_transport");
        let child = host.spawn(&mut command, WORK_UID).unwrap();
        drop(command);
        drive_until(&host, |_| host.capability().is_some());
        assert_eq!(host.capability(), Some(Capability::NativeReceiver));
        let request = host.prepare_native(&first).unwrap();
        let stopped = host.prepare_native(&first).unwrap();
        assert!(host.publish_native(request, Zeroizing::new(vec![7; 32])));
        drive_until(&host, |sent| sent);
        assert_eq!(
            host.quiesce(std::time::Instant::now() + Duration::from_secs(2)).unwrap(),
            StopReceipt::Acknowledged
        );
        assert!(!host.publish_native(stopped, Zeroizing::new(vec![7; 32])));
        let next = host.new_ticket().unwrap();
        assert!(host.offer(&next));
        let old_target = host.prepare_native(&next).unwrap();
        // SAFETY: actual still-owned unreaped fixture child.
        assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGTERM) }, 0);
        assert_eq!(child.wait().unwrap().signal(), Some(libc::SIGTERM));
        assert!(host.drive().is_err());
        host.daemon_exited();
        let mut command = transport_command("native_transport");
        let replacement = host.spawn(&mut command, WORK_UID).unwrap();
        drop(command);
        drive_until(&host, |_| host.capability().is_some());
        assert!(!host.publish_native(old_target, Zeroizing::new(vec![7; 32])));
        let fresh = host.prepare_native(&next).unwrap();
        assert!(host.publish_native(fresh, Zeroizing::new(vec![7; 32])));
        drive_until(&host, |sent| sent);
        assert_eq!(
            host.quiesce(std::time::Instant::now() + Duration::from_secs(2)).unwrap(),
            StopReceipt::Acknowledged
        );
        host.detach();
        assert!(replacement.wait().unwrap().success());
        println!("ROOT_BOUNDARY_EXECUTED native_private_channel");
    }

    #[test]
    #[ignore = "requires Linux root; scripts/ci/verify-link-root-boundary.py"]
    fn receiver_root_privileged_new_ticket_waits_for_the_old_role_drain() {
        use cmux_link::root_bootstrap::{Capability, Host, NativeStatus, StopReceipt};
        use std::os::unix::fs::{PermissionsExt as _, chown};
        use std::os::unix::net::UnixListener;
        use std::sync::Arc;
        use std::time::Instant;
        use zeroize::Zeroizing;
        root();
        let directory = cmux_unix_socket::short_test_dir("rd");
        chown(directory.path(), Some(WORK_UID), Some(WORK_UID)).unwrap();
        let path = directory.path().join("gate");
        let listener = UnixListener::bind(&path).unwrap();
        chown(&path, Some(WORK_UID), Some(WORK_UID)).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        let host = Arc::new(Host::new_native().unwrap());
        let first = host.new_ticket().unwrap();
        assert!(host.offer(&first));
        let mut command = transport_command("native_delayed_drain");
        command.env("CMUX_RECEIVER_DRAIN_GATE", &path);
        let child = host.spawn(&mut command, WORK_UID).unwrap();
        drop(command);
        drive_until(&host, |_| host.capability() == Some(Capability::NativeReceiver));
        let stale = host.prepare_native(&first).unwrap();
        let request = host.prepare_native(&first).unwrap();
        assert!(host.publish_native(request, Zeroizing::new(vec![7; 32])));
        drive_until(&host, |sent| sent);
        let mut fd = libc::pollfd { fd: listener.as_raw_fd(), events: libc::POLLIN, revents: 0 };
        // SAFETY: one initialized, live listener descriptor is retained through poll.
        assert!(unsafe { libc::poll(&raw mut fd, 1, 10_000) } > 0);
        let (mut gate, _) = listener.accept().unwrap();
        gate.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let mut signal = [255];
        gate.read_exact(&mut signal).unwrap();
        assert_eq!(signal, [0]);
        let stopping = host.clone();
        let old = first.clone();
        let waiter = std::thread::spawn(move || {
            stopping.quiesce_native(&old, Instant::now() + Duration::from_secs(8))
        });
        gate.read_exact(&mut signal).unwrap();
        assert_eq!(signal, [1], "the old recipient has not observed stop");
        let next = host.new_ticket().unwrap();
        assert!(host.offer(&next));
        assert!(host.prepare_native(&next).is_none(), "new frame bypassed pending drain");
        assert!(!host.native_request_current(&stale));
        assert!(!host.publish_native(stale, Zeroizing::new(vec![7; 32])));
        assert!(host.advance_native(&first).is_none());
        assert!(!waiter.is_finished(), "READY was accepted as a drain receipt");
        gate.write_all(&[1]).unwrap();
        assert_eq!(waiter.join().unwrap().unwrap(), StopReceipt::Acknowledged);
        assert!(host.prepare_native(&next).is_some());
        assert_eq!(host.native_status(&next), Some(NativeStatus::Pending));
        assert_eq!(host.native_status(&first), None);
        host.detach();
        assert!(child.wait().unwrap().success());
        println!("ROOT_BOUNDARY_EXECUTED native_ticket_drain_barrier");
    }
}
