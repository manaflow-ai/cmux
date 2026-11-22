//! The real carrier port of a frame link: a local stream socket stands in
//! for the link's carrier. Reads happen only when asked (at most the asked
//! bytes), writes are reported when the socket took them, and every
//! result wakes the serve loop instead of being polled.

use cmux_cloud::connector::port::{CarrierPort, PortEvent, PortOpener, UnixPortOpener};
use cmux_cloud::link::LinkWake;
use std::io::{Read as _, Write as _};
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::mpsc::{Receiver, channel};
use std::time::Duration;

const WAIT: Duration = Duration::from_secs(5);

fn socket_path(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-cloud-port-{}-{name}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("c.sock");
    let _ = std::fs::remove_file(&path);
    path
}

fn waker() -> (LinkWake, Receiver<()>) {
    let (tx, rx) = channel();
    let tx = std::sync::Mutex::new(tx);
    let wake: LinkWake = Arc::new(move || {
        let _ = tx.lock().unwrap().send(());
    });
    (wake, rx)
}

/// Events until one arrives (each wait bounded by [`WAIT`]).
fn events(port: &mut dyn CarrierPort, woke: &Receiver<()>) -> Vec<PortEvent> {
    loop {
        let events = port.take_events();
        if !events.is_empty() {
            return events;
        }
        woke.recv_timeout(WAIT).expect("the port woke the loop");
    }
}

#[test]
fn reads_only_what_was_asked_and_reports_writes_and_the_end() {
    let path = socket_path("rw");
    let listener = UnixListener::bind(&path).unwrap();
    let (wake, woke) = waker();
    let mut port = UnixPortOpener.open(&path, Some(wake)).unwrap();
    let (mut carrier, _) = listener.accept().unwrap();

    carrier.write_all(b"hello world").unwrap();
    port.read(5);
    assert_eq!(events(&mut *port, &woke), vec![PortEvent::Read(b"hello".to_vec())]);
    port.read(64);
    assert_eq!(events(&mut *port, &woke), vec![PortEvent::Read(b" world".to_vec())]);

    port.write(b"abc".to_vec());
    assert_eq!(events(&mut *port, &woke), vec![PortEvent::Wrote(3)]);
    let mut got = [0u8; 3];
    carrier.read_exact(&mut got).unwrap();
    assert_eq!(&got, b"abc");

    drop(carrier);
    port.read(64);
    assert_eq!(events(&mut *port, &woke), vec![PortEvent::Read(Vec::new())], "end of stream");
    port.shutdown();
}

#[test]
fn shutdown_ends_a_read_that_waits() {
    let path = socket_path("shutdown");
    let listener = UnixListener::bind(&path).unwrap();
    let (wake, woke) = waker();
    let mut port = UnixPortOpener.open(&path, Some(wake)).unwrap();
    let (_carrier, _) = listener.accept().unwrap();
    port.read(64);
    port.shutdown();
    // The blocked read returns (end of stream or an error); it never hangs.
    let got = events(&mut *port, &woke);
    assert!(
        matches!(got.as_slice(), [PortEvent::Read(bytes)] if bytes.is_empty())
            || matches!(got.as_slice(), [PortEvent::Closed(_)]),
        "{got:?}"
    );
}

#[test]
fn a_missing_socket_is_an_open_error() {
    let path = socket_path("missing");
    assert!(UnixPortOpener.open(&path, None).is_err());
}
