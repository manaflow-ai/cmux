use super::*;
use base64::Engine;

#[cfg(unix)]
#[test]
fn workflow_lock_wait_does_not_delay_runtime_shutdown() {
    use std::future::Future as _;
    use std::os::fd::AsRawFd;

    let dir = cmux_unix_socket::short_test_dir("workflow-bg-shutdown");
    let path = dir.path().join("task.lock");
    let runner = std::fs::File::create(&path).unwrap();
    // SAFETY: the test owns this descriptor and holds it until after the shutdown check.
    assert_eq!(unsafe { libc::flock(runner.as_raw_fd(), libc::LOCK_EX) }, 0);
    let (shutdown, stopped) = std::sync::mpsc::channel();
    let daemon = std::thread::spawn(move || {
        let runtime = tokio::runtime::Builder::new_current_thread().build().unwrap();
        runtime.block_on(async {
            let mut wait = std::pin::pin!(workflow_bg_wait_lock(path));
            // Start the actual lock wait before dropping its future and the runtime.
            std::future::poll_fn(|cx| {
                assert!(wait.as_mut().poll(cx).is_pending());
                std::task::Poll::Ready(())
            })
            .await;
        });
        drop(runtime);
        let _ = shutdown.send(());
    });
    let shutdown_before_exit = stopped.recv_timeout(std::time::Duration::from_secs(5));
    // Release before joining or asserting: the old blocking-pool implementation must also
    // be able to clean up after its bounded failure, rather than hanging the test process.
    drop(runner);
    daemon.join().unwrap();
    assert!(shutdown_before_exit.is_ok(), "daemon shutdown waited for the machine task");
}

fn result(data: &[u8]) -> Value {
    let dir = cmux_unix_socket::short_test_dir("workflow-bg-result");
    let mut spool = bg_run::Spool::create_with_retention(dir.path(), "task", 1024, true).unwrap();
    spool.write(data).unwrap();
    drop(spool);
    let record =
        Record { id: "task".into(), ended_at: Some(1), exit_code: Some(0), ..Record::default() };
    workflow_bg_output(dir.path(), &record).unwrap()
}

#[test]
fn workflow_output_decodes_utf8_once_across_read_boundaries() {
    let text = format!("{}🦀tail", "x".repeat((OUTPUT_DEFAULT - 1) as usize));
    let view = result(text.as_bytes());
    assert_eq!(view["text"], text);
    assert_eq!(
        base64::engine::general_purpose::STANDARD.decode(view["data"].as_str().unwrap()).unwrap(),
        text.as_bytes()
    );
    assert_eq!(view["fromByte"], 0);
    assert_eq!(view["nextByte"], text.len());
}

#[test]
fn workflow_output_keeps_complete_binary_data() {
    let bytes: Vec<u8> = (0..(OUTPUT_DEFAULT as usize * 3 + 5)).map(|i| (i % 256) as u8).collect();
    let view = result(&bytes);
    assert_eq!(
        base64::engine::general_purpose::STANDARD.decode(view["data"].as_str().unwrap()).unwrap(),
        bytes
    );
    assert_eq!(view["text"], String::from_utf8_lossy(&bytes).as_ref());
    assert_eq!(view["totalBytes"], bytes.len());
    assert_eq!(view["nextByte"], bytes.len());
    assert_eq!(view["skippedBytes"], 0);
}
