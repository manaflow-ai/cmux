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
    use std::os::unix::process::CommandExt;
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
}
