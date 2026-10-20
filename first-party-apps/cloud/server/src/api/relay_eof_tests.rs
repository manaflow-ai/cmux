//! A host disconnect must remain visible after a pending scope lookup consumes EOF.
use super::{ControlPlane, HostRelay};
use std::io::Cursor;
use std::sync::mpsc;
use std::time::Duration;

#[test]
fn cloud_scope_parent_eof_stays_closed_for_subsequent_requests_and_loop() {
    let (mut relay, waker) =
        HostRelay::new(Cursor::new(Vec::<u8>::new()), Vec::new()).into_inbox().expect("host inbox");
    let (done, result) = mpsc::channel();
    let worker = std::thread::spawn(move || {
        let first = relay.session().is_err();
        let second = relay.session().is_err();
        let ended = matches!(relay.next_step(), Ok(None));
        let _ = done.send((first, second, ended));
    });
    // Keep a link's wake sender alive, as the real serve loop does. EOF must
    // end both requests and the loop without waiting for that sender to close.
    let observed = result.recv_timeout(Duration::from_secs(2));
    drop(waker);
    worker.join().expect("relay worker");
    assert_eq!(
        observed.expect("host EOF was consumed and a subsequent read hung"),
        (true, true, true)
    );
}
