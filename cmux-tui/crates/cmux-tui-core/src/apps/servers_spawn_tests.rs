//! A server whose start fails part way leaves no process behind.

use super::*;

/// When a thread of a started server cannot start (a thread limit), the server process is
/// ended and reaped. Before, the spawn returned the error and dropped the child: the server
/// kept running unowned and became a zombie when it ended, one per failed start.
#[test]
fn a_server_whose_thread_cannot_start_is_reaped() {
    for nth in 1..=3 {
        fail_thread_start_for_test(nth);
        let spawned = ServerProcess::spawn(
            Path::new("/bin/sleep"),
            &["60".to_string()],
            &[],
            "reap-test",
            |_| {},
            |_| {},
            |_| {},
        );
        fail_thread_start_for_test(0);
        let Err(error) = spawned else {
            panic!("thread start {nth} was made to fail, but the spawn succeeded");
        };
        assert!(error.to_string().contains("thread start failed"), "{error}");
        let pid = last_spawned_pid_for_test().expect("the server process was started");
        let pid = libc::pid_t::try_from(pid).unwrap();
        let mut status = 0;
        // SAFETY: waitpid on this test's own child pid, WNOHANG: it only reads a status.
        let waited = unsafe { libc::waitpid(pid, &mut status, libc::WNOHANG) };
        if waited == 0 {
            // Still running and still our child: end it so the test leaves nothing behind.
            // SAFETY: our own unreaped child.
            unsafe { libc::kill(pid, libc::SIGKILL) };
            // SAFETY: as above; this blocks only until the killed child ends.
            unsafe { libc::waitpid(pid, &mut status, 0) };
        }
        assert_eq!(
            waited, -1,
            "thread start {nth} failed and the server process was left running, unreaped"
        );
    }
}
