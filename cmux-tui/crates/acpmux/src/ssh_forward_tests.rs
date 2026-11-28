/// Item C: a forward's ssh, once dropped, is killed and reaped: no defunct child stays
/// behind while the move goes on (`kill(pid, 0)` still finds a zombie).
#[cfg(unix)]
#[tokio::test]
async fn a_dropped_child_is_reaped_not_left_defunct() {
    let mut child =
        tokio::process::Command::new("sleep").arg("60").kill_on_drop(true).spawn().unwrap();
    let pid = child.id().unwrap() as libc::pid_t;
    super::reap(&mut child);
    // SAFETY: signal 0 only checks that the pid exists.
    let alive = unsafe { libc::kill(pid, 0) } == 0;
    assert!(!alive, "the killed child {pid} is still in the process table");
}

/// On a runtime, the wait for a killed child runs off the worker (`spawn_blocking`), and the
/// child is still reaped, not left defunct.
#[cfg(unix)]
#[tokio::test(flavor = "current_thread")]
async fn a_child_reaped_off_the_worker_leaves_no_zombie() {
    let child = tokio::process::Command::new("sleep").arg("60").kill_on_drop(true).spawn().unwrap();
    let pid = child.id().unwrap() as libc::pid_t;
    super::reap_off_worker(child);
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
    // SAFETY: signal 0 only checks that the pid exists.
    while unsafe { libc::kill(pid, 0) } == 0 {
        assert!(
            std::time::Instant::now() < deadline,
            "the killed child {pid} is still in the process table"
        );
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
}
