use std::io;
use std::time::Duration;

use super::{ListenerStopped, accept_each};

/// Runs `accept_each` over `results` and returns the waits it asked for
/// and the connections it served.
fn run(results: Vec<io::Result<u32>>) -> (Vec<Duration>, Vec<u32>) {
    let mut results = results.into_iter();
    let (mut waits, mut served) = (Vec::new(), Vec::new());
    accept_each(|| results.next(), |wait| waits.push(wait), |stream| served.push(stream));
    (waits, served)
}

fn emfile() -> io::Result<u32> {
    Err(io::Error::from_raw_os_error(libc::EMFILE))
}

/// An accept that fails with EMFILE fails again at once until a
/// descriptor frees up: before, the listener thread retried with no
/// wait and ran at 100% CPU. Each such failure waits, longer each time;
/// a connection accepted in between starts the spacing over.
#[test]
fn a_persistent_accept_error_waits_longer_each_time() {
    let (waits, served) = run(vec![emfile(), emfile(), emfile(), emfile(), emfile()]);
    assert!(served.is_empty());
    assert_eq!(waits.len(), 5, "every EMFILE waits before the next accept: {waits:?}");
    assert!(waits[0] > Duration::ZERO, "{waits:?}");
    assert!(waits.windows(2).all(|pair| pair[1] > pair[0]), "{waits:?}");
    assert!(waits.iter().all(|wait| *wait <= Duration::from_secs(1)), "{waits:?}");

    let (waits, served) = run(vec![emfile(), emfile(), emfile(), Ok(7), emfile()]);
    assert_eq!(served, vec![7]);
    assert_eq!(waits.len(), 4, "{waits:?}");
    assert!(waits[3] < waits[2], "a served connection resets the spacing: {waits:?}");
}

/// A per-connection error ends with that connection, and the next
/// accept blocks: no wait.
#[test]
fn a_per_connection_accept_error_does_not_wait() {
    let aborted = || Err(io::Error::from(io::ErrorKind::ConnectionAborted));
    let (waits, served) = run(vec![aborted(), Ok(1), aborted()]);
    assert_eq!(served, vec![1]);
    assert!(waits.is_empty(), "{waits:?}");
}

#[test]
fn a_listener_that_panics_still_counts_as_stopped() {
    let (done, events) = std::sync::mpsc::channel();
    let stopped = ListenerStopped(done.clone());
    let thread = std::thread::spawn(move || {
        let _stopped = stopped;
        panic!("the OS refused a thread");
    });
    assert!(thread.join().is_err());
    assert_eq!(events.try_recv(), Ok(None));
    drop(done);
}
