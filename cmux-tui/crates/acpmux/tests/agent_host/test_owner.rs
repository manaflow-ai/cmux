//! A host a test started ends with that test's process (`daemon/owner_exit.rs`): hosts outlive their
//! daemon on purpose, so a test killed before its teardown left its hosts and their stand-in
//! harnesses running for days (about 23 on one lane VM, 2026-11-03).

use super::*;

/// Ends the harness group if the test fails before the host ended it.
struct HarnessGroup(Option<u32>);

impl Drop for HarnessGroup {
    fn drop(&mut self) {
        if let Some(pgid) = self.0.and_then(|p| i32::try_from(p).ok()) {
            // SAFETY: a signal to the group this test's host started; ESRCH once it is gone.
            unsafe { libc::killpg(pgid, libc::SIGKILL) };
        }
    }
}

fn group_gone(pgid: u32) -> bool {
    let Ok(pgid) = i32::try_from(pgid) else { return true };
    // SAFETY: signal 0 only asks whether the group exists.
    unsafe { libc::killpg(pgid, 0) != 0 }
}

#[tokio::test]
async fn a_host_ends_with_the_test_process_that_started_it() {
    let dir = scratch("towner");
    // Stands in for the test process: killed as a test is, with no teardown.
    let mut owner = std::process::Command::new("sleep").arg("600").spawn().expect("sleep");
    // The hermetic environment (`daemon_env::tokio_command`), as a daemon's host launch gives.
    let mut host = daemon_env::tokio_command(&dir, daemon_env::Agents::StandIn)
        .arg(agent_host::HOST_ARG)
        .env("ACPMUX_TEST_OWNER_PID", owner.id().to_string())
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .expect("start the host");
    let (mut stdin, mut stdout) = (host.stdin.take().unwrap(), host.stdout.take().unwrap());
    agent_host::write_frame(&mut stdin, &spec(&dir, "s-towner")).await.unwrap();
    let record = match agent_host::read_frame(&mut stdout).await.unwrap() {
        Some(agent_host::BootstrapReply::Ready { record }) => record,
        other => panic!("the host did not start: {other:?}"),
    };
    let _group = HarnessGroup(record.harness_pid);
    let lock = live_lock(&dir, &record);

    // It keeps running while the test process runs.
    assert!(
        tokio::time::timeout(Duration::from_millis(500), host.wait()).await.is_err(),
        "the host ended while its test process ran"
    );
    owner.kill().unwrap();
    owner.wait().unwrap();

    // Gone within a few seconds, and its harness with it.
    tokio::time::timeout(
        Duration::from_secs(5),
        tokio::task::spawn_blocking(move || {
            // SAFETY: flock on a descriptor this test owns; it returns when the host exits.
            assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) }, 0);
        }),
    )
    .await
    .expect("the host ended once its test process exited")
    .unwrap();
    let pgid = record.harness_pid.expect("the harness group");
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while !group_gone(pgid) {
        assert!(std::time::Instant::now() < deadline, "the harness outlived its host");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let _ = std::fs::remove_dir_all(&dir);
}
