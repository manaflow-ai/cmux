use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};

use super::*;

#[test]
fn connection_limit_probe_bounds_a_peer_that_never_terminates_its_line() {
    use std::io::Read;
    use std::sync::mpsc;

    let (client, mut server) = UnixStream::pair().unwrap();
    let (finished, wait) = mpsc::channel();
    let sender = std::thread::spawn(move || {
        // Send beyond identify's existing response limit, then keep the
        // connection open. Restart must reject the malformed response
        // without depending on the peer's EOF or treating it as silence.
        let bytes = (16 * 1024 * 1024 + 2) as u64;
        let sent = io::copy(&mut io::repeat(b'x').take(bytes), &mut server);
        let _ = wait.recv();
        sent
    });
    let result = probe(Box::new(client), Instant::now() + PROBE_DEADLINE);
    finished.send(()).unwrap();
    assert_eq!(sender.join().unwrap().unwrap(), (16 * 1024 * 1024 + 2) as u64);
    assert!(matches!(result, Probe::Answered), "oversized input is not an unresponsive owner");
}

#[test]
fn connection_limit_probe_keeps_a_peer_that_sends_a_partial_line() {
    use std::sync::mpsc;

    let (client, mut server) = UnixStream::pair().unwrap();
    let (finished, wait) = mpsc::channel();
    server.write_all(b"{").unwrap();
    let sent = std::thread::spawn(move || {
        let _ = wait.recv();
        drop(server);
    });
    let result = probe(Box::new(client), Instant::now() + Duration::from_millis(100));
    finished.send(()).unwrap();
    sent.join().unwrap();
    assert!(
        matches!(result, Probe::Answered),
        "partial protocol data must not authorize replacement"
    );
}

#[test]
fn connection_limit_recovery_gets_a_full_identify_deadline() {
    let dir = tempfile::tempdir_in("/tmp").unwrap();
    let spec = super::super::recovery_tests::owner_spec(dir.path().join("owner.sock"));
    let listener = UnixListener::bind(&spec.socket).unwrap();
    let (initial, first_peer) = UnixStream::pair().unwrap();
    let server = std::thread::spawn(move || {
        let mut first = BufReader::new(first_peer);
        first.read_line(&mut String::new()).unwrap();
        // Deliberate protocol latency, not readiness synchronization: the
        // refusal arrives just before the overall busy deadline expires.
        std::thread::sleep(PROBE_DEADLINE - Duration::from_secs(2));
        writeln!(
            first.get_mut(),
            r#"{{"protocol":"cmux.protocol/2","type":"refused","code":"server.busy"}}"#
        )
        .unwrap();
        drop(first);

        let (stream, _) = listener.accept().unwrap();
        let mut recovered = BufReader::new(stream);
        recovered.read_line(&mut String::new()).unwrap();
        // A recovered owner's valid response may take longer than the
        // remaining busy budget, but much less than one identify deadline.
        std::thread::sleep(Duration::from_secs(3));
        let _ = writeln!(recovered.get_mut(), r#"{{"id":1,"ok":true}}"#);
    });
    let stuck = unresponsive(&spec, Box::new(initial));
    server.join().unwrap();
    assert!(!stuck, "Restart must keep an owner that recovers near the busy deadline");
}
