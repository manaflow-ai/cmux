use std::panic::Location;
use std::time::Duration;

use cmux_threads::blocking::{self, BlockingKind, BlockingMode};

use super::*;

fn row(name: &str) -> Option<cmux_threads::ThreadInfo> {
    cmux_threads::snapshot().into_iter().find(|row| row.name == name)
}

#[test]
fn echo_thread_is_user_interactive_and_disallows_blocking() {
    let name = "echo-thread-test-qos";
    let handle = spawn(name, move || {
        let row = row(name).expect("an echo thread is registered while it runs");
        (row.declared, blocking::is_blocking_disallowed())
    })
    .unwrap();
    let (declared, disallowed) = handle.join().unwrap();
    assert_eq!(declared, ThreadQos::UserInteractive);
    assert!(disallowed, "an echo thread disallows blocking before its body runs");
    assert!(row(name).is_none(), "the row is gone once the thread is joined");
}

#[test]
fn a_blocking_call_on_an_echo_thread_is_a_recorded_site() {
    // Record mode on this thread: the recorded site is what this test checks,
    // and a Debug build panics at it otherwise (`CMUX_DAEMON_BLOCKING`).
    let site = spawn("echo-thread-test-site", || {
        blocking::with_mode(BlockingMode::Record, || {
            let site = Location::caller();
            cmux_threads::checked::sync::sleep(Duration::ZERO);
            site
        })
    })
    .unwrap()
    .join()
    .unwrap();
    let snapshot = blocking::snapshot();
    let recorded = snapshot
        .sites
        .iter()
        .find(|row| row.file == site.file() && row.line == site.line() + 1)
        .expect("the sleep on an echo thread is a recorded site");
    assert!(recorded.kinds.contains(BlockingKind::Sleep));
}

#[cfg(unix)]
#[test]
fn a_host_stream_reader_reads_its_own_descriptor_without_a_violation() {
    use std::io::{Read as _, Write as _};

    let (mut peer, stream) = crate::terminal_host_runtime::HostStream::pair().unwrap();
    let name = "echo-thread-test-own-stream";
    let reader = spawn_host_stream_reader(name, stream, move |own| {
        let qos = row(name).map(|row| row.declared);
        let mut bytes = Vec::new();
        own.read_to_end(&mut bytes).map(|_| (qos, bytes))
    })
    .unwrap();
    peer.write_all(b"echo").unwrap();
    drop(peer);
    let (qos, bytes) = reader.join().unwrap().unwrap();
    assert_eq!(qos, Some(ThreadQos::UserInteractive));
    assert_eq!(bytes, b"echo");
    let own_file = file!().replace("echo_thread_tests.rs", "echo_thread.rs");
    assert!(
        blocking::snapshot().sites.iter().all(|site| site.file != own_file),
        "reads of the thread's own descriptor are allowed: {:?}",
        blocking::snapshot()
    );
}

#[cfg(unix)]
#[test]
fn an_own_host_stream_scope_writes_its_descriptor_with_blocking_disallowed() {
    use std::io::{Read as _, Write as _};

    let (mut peer, stream) = crate::terminal_host_runtime::HostStream::pair().unwrap();
    let disallowed = with_own_host_stream(&stream, |own| {
        own.write_all(b"echo").unwrap();
        blocking::is_blocking_disallowed()
    });
    assert!(disallowed, "the output loop runs with blocking disallowed");
    assert!(!blocking::is_blocking_disallowed(), "the scope restores the thread");
    drop(stream);
    let mut bytes = Vec::new();
    peer.read_to_end(&mut bytes).unwrap();
    assert_eq!(bytes, b"echo");
    let own_file = file!().replace("echo_thread_tests.rs", "echo_thread.rs");
    assert!(
        blocking::snapshot().sites.iter().all(|site| site.file != own_file),
        "writes to the thread's own descriptor are allowed: {:?}",
        blocking::snapshot()
    );
}
