//! A closed original policy must end its pinned process before root can resume.
use super::{Agent, Daemon, NOW, drive_until, hosted_root, identity_bytes, original_client};
use crate::cloud::bootstrap_role::RoleBridge;
use crate::config::Paths;
use cmux_cloud_wire::CloudVmReceiverLifecycleParamsPhase as Phase;
use cmux_link::root_bootstrap::{Host, StopReceipt};
use std::io::{self, Write as _};
use std::os::fd::AsRawFd as _;
use std::sync::Arc;
use std::time::{Duration, Instant};

fn progress_for(
    host: &Host,
    budget: Duration,
    mut condition: impl FnMut() -> bool,
) -> io::Result<bool> {
    let deadline = Instant::now() + budget;
    loop {
        host.drive()?;
        if condition() {
            return Ok(true);
        }
        let Some(left) = deadline.checked_duration_since(Instant::now()) else { return Ok(false) };
        let wake = host.wake_set()?;
        let mut fds = wake.fds();
        // SAFETY: WakeSet retains all initialized descriptors through this poll.
        let count = unsafe {
            libc::poll(
                fds.as_mut_ptr(),
                fds.len() as libc::nfds_t,
                left.as_millis().clamp(1, i32::MAX as u128) as i32,
            )
        };
        if count == 0 {
            return Ok(false);
        }
        if count < 0 && io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
            return Err(io::Error::last_os_error());
        }
    }
}

#[test]
#[ignore = "requires hosted Linux root; scripts/ci/verify-link-root-boundary.py"]
fn receiver_root_privileged_original_producer_replaces_a_policy_retired_child() {
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
    let (mut reader, first_pid) = agent.reader(&daemon.child);
    let first = client.receiver_lifecycle(Phase::Read, None, None, NOW).unwrap();
    let reply =
        crate::cloud::receiver_files::reply(&paths, "instance-a", &mut client, NOW).unwrap();
    assert_eq!(reply["value"]["policy"]["receiver_generation"], first.generation);
    reader.get_mut().write_all(format!("{reply}\n").as_bytes()).unwrap();
    drive_until(&host, |_| {
        worker.publish_original(&paths, "instance-a", &mut client, NOW).unwrap();
        worker.is_ready()
    });
    drop(reader);
    client.receiver_lifecycle(Phase::End, Some(first.generation.clone()), None, NOW).unwrap();
    // Wait for the actual process's scheduled renewal, without changing its
    // timer or replacing the original protected-policy producer.
    let mut fd = libc::pollfd { fd: agent.listener.as_raw_fd(), events: libc::POLLIN, revents: 0 };
    // SAFETY: one initialized, live listener descriptor remains owned through poll.
    assert!(unsafe { libc::poll(&raw mut fd, 1, 30_000) } > 0, "policy renewal never requested");
    let (mut reader, renewing_pid) = agent.reader(&daemon.child);
    assert_eq!(renewing_pid, first_pid);
    let closed =
        crate::cloud::receiver_files::reply(&paths, "instance-a", &mut client, NOW).unwrap();
    assert!(closed["value"]["policy"]["receiver_generation"].is_null());
    reader.get_mut().write_all(format!("{closed}\n").as_bytes()).unwrap();
    drop(reader);
    let mut failure = None;
    let recovered = progress_for(&host, Duration::from_secs(30), || {
        match worker.publish_original(&paths, "instance-a", &mut client, NOW) {
            Ok(_) => false,
            Err(error) => {
                failure = Some(error);
                true
            }
        }
    })
    .unwrap();
    let mut replacement_pid = None;
    if recovered {
        assert_eq!(failure.as_deref(), Some("Native receiving attempt ended"));
        assert!(!std::path::Path::new(&format!("/proc/{first_pid}/stat")).exists());
        assert!(worker.publish_original(&paths, "instance-a", &mut client, NOW).unwrap());
        drive_until(&host, |sent| sent);
        let (mut reader, pid) = agent.reader(&daemon.child);
        assert_ne!(pid, first_pid);
        replacement_pid = Some(pid);
        let next = client.receiver_lifecycle(Phase::Read, None, None, NOW).unwrap();
        assert_ne!(next.generation, first.generation);
        let reply =
            crate::cloud::receiver_files::reply(&paths, "instance-a", &mut client, NOW).unwrap();
        assert_eq!(reply["value"]["policy"]["receiver_generation"], next.generation);
        reader.get_mut().write_all(format!("{reply}\n").as_bytes()).unwrap();
        drive_until(&host, |_| {
            worker.publish_original(&paths, "instance-a", &mut client, NOW).unwrap();
            worker.is_ready()
        });
    }
    // Also clean the deliberately failing baseline before its intended assertion.
    // A stuck renewal may need the daemon's bounded owned-child kill/reap path.
    assert_eq!(
        role.stop(Instant::now() + Duration::from_secs(20)).unwrap(),
        StopReceipt::Acknowledged
    );
    worker.retire(&mut client, NOW).unwrap();
    for pid in std::iter::once(first_pid).chain(replacement_pid) {
        assert!(!std::path::Path::new(&format!("/proc/{pid}/stat")).exists());
    }
    assert!(daemon.child.try_wait().unwrap().is_none());
    assert!(!cmux_link::entry_path::remote_entry_socket_path(&daemon.session).exists());
    assert!(identity_bytes(&paths) == original, "policy retirement rotated protected keys");
    assert!(recovered, "retired policy never replaced its original receiving process");
    println!("ROOT_BOUNDARY_EXECUTED native_original_policy_retirement");
}
