use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};

use super::*;

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
