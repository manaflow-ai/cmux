//! macOS process-scope scan tests that start a child process themselves. They live under a
//! `tests/` directory: the daemon's no-raw-spawn guard (scripts/cmux-next/check-no-raw-spawn.py)
//! covers product code, and this child is only the fork-before-exec state the scan must ignore.

use super::*;

#[test]
fn mac_close_on_exec_marker_does_not_claim_a_child_that_has_not_run_exec() {
    // A fork copies the parent's close-on-exec scope markers and keeps them until it runs exec.
    // On macOS the scan read every vnode descriptor, so such a child (or the parent itself) was
    // claimed by the scope, and an unfinalized scope SIGKILLs a claimed process at once. That
    // killed a fresh `/bin/sleep 300` test terminal before exec, the test tree lost its screen,
    // and app::tests::double_click_selects_a_complete_word panicked on its active_screen()
    // (macOS job 129821773453 of run 42808325625). Linux checks the fd flags for this; macOS
    // must check the close-on-exec status of each descriptor too.
    use std::os::unix::process::CommandExt as _;

    let scope = UnixProcessScope::prepare().unwrap();
    let registration = || ScopeRegistration {
        marker: scope.marker.clone(),
        file_marker: scope.file_marker,
        _marker_fd: Arc::clone(&scope._marker_fd),
        root: ProcessIdentity { pid: u32::MAX, started: 0 },
        tracked: scope.tracked.clone(),
        track_before_finalization: true,
        final_scan_gate: None,
    };

    // A bystander child held between fork and exec: its pre_exec blocks on a pipe, so it still
    // holds every close-on-exec descriptor of this process, the scope marker among them.
    let mut fds = [0; 2];
    assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
    let (release_read, release_write) = (fds[0], fds[1]);
    // Close-on-exec, so a child another test forks now does not keep the pipe open.
    for fd in fds {
        assert_eq!(unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) }, 0);
    }
    let mut command = std::process::Command::new("/usr/bin/true");
    unsafe {
        command.pre_exec(move || {
            libc::close(release_write);
            let mut byte = [0_u8; 1];
            let _ = libc::read(release_read, byte.as_mut_ptr().cast(), 1);
            Ok(())
        });
    }
    let mut child = command.spawn().unwrap();
    unsafe { libc::close(release_read) };
    let bystander = (0..200)
        .find_map(|_| {
            let identity = process_identity(child.id());
            if identity.is_none() {
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            identity
        })
        .expect("the bystander child is visible to the scan");
    let current = process_identity(std::process::id()).unwrap();

    let scanned = scan_registered_processes(&[registration()], ProcessScanCursor::default());

    // Let the bystander exec and exit before asserting, so a failure leaves no process behind. A
    // written byte releases it even if another test's fork still holds a copy of the write end.
    let release = [1_u8];
    assert_eq!(unsafe { libc::write(release_write, release.as_ptr().cast(), 1) }, 1);
    unsafe { libc::close(release_write) };
    let _ = child.wait();
    assert!(
        !scanned.matches.contains(&(0, bystander)),
        "a child that inherited a close-on-exec marker before exec is not a scope member"
    );
    assert!(
        !scanned.matches.contains(&(0, current)),
        "the process that holds a close-on-exec marker is not a scope member"
    );
}
