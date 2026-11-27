//! RED (security, coordinator 2026-10-04): a byte stream is a registered
//! remote client, so a kick, the link closing the dial (revocation) and the
//! daemon's shutdown each end it at once; a remote dial that does not send
//! its first line within the deadline is closed.

use std::io::{BufRead, BufReader, Read as _, Write as _};
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

use super::super::LinkVerifier;
use super::super::remote_entry::{RemoteEntryServer, serve_remote_entry_with};
use super::tests::{Home, test_mux};
use super::*;

const STAMP: &str = r#"{"link_peer":{"install":"inst_1","user":"42","team":"team_a"}}"#;

struct Entry {
    server: Option<RemoteEntryServer>,
    mux: Arc<Mux>,
    home: Home,
    _directory: cmux_unix_socket::TestDir,
}

fn entry(label: &str, deadline: Duration) -> Entry {
    let directory = cmux_unix_socket::short_test_dir("fsstream");
    let path = cmux_link::entry_path::remote_entry_socket_path(&directory.path().join("s.sock"));
    let mux = test_mux();
    let home = Home::new(label);
    let mut fs = home.entry();
    fs.first_line_deadline = deadline;
    let verifier: LinkVerifier = Arc::new(|_stream: &UnixStream| Ok(()));
    let server =
        serve_remote_entry_with(mux.clone(), &path, verifier, Arc::new(FsGate), fs, false).unwrap();
    Entry { server: Some(server), mux, home, _directory: directory }
}

/// A stamped dial (banner read, stamp sent).
fn dial(entry: &Entry) -> (UnixStream, BufReader<UnixStream>) {
    let path = entry.server.as_ref().unwrap().path().to_path_buf();
    let mut stream = UnixStream::connect(path).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut banner = String::new();
    reader.read_line(&mut banner).unwrap();
    stream.write_all(format!("{STAMP}\n").as_bytes()).unwrap();
    (stream, reader)
}

/// A dial with a write stream of 1 MB that has sent its first 1000 bytes.
fn start_write(entry: &Entry) -> (UnixStream, BufReader<UnixStream>) {
    let (mut stream, mut reader) = dial(entry);
    let line = entry.home.map(
        r#"{"id":1,"cmd":"fs.write","path":"/home/cmux/up.bin","mode":"create","stream":true,"size":1000000}"#,
    );
    stream.write_all(format!("{line}\n").as_bytes()).unwrap();
    let mut ready = String::new();
    reader.read_line(&mut ready).unwrap();
    assert!(ready.contains("\"ready\":true"), "{ready}");
    stream.write_all(&[7u8; 1000]).unwrap();
    (stream, reader)
}

fn remote_clients(mux: &Mux) -> Vec<u64> {
    let state = mux.control_clients.state.lock().unwrap();
    state
        .clients
        .iter()
        .filter(|(_, record)| matches!(record.transport, ClientTransport::Remote))
        .map(|(client, _)| *client)
        .collect()
}

/// Waits (test only) until `done` or 5 s.
fn wait_until(mut done: impl FnMut() -> bool) -> bool {
    let end = Instant::now() + Duration::from_secs(5);
    while Instant::now() < end {
        if done() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    done()
}

fn home_is_empty(entry: &Entry) -> bool {
    std::fs::read_dir(&entry.home.path).unwrap().next().is_none()
}

/// The read side sees the end of the dial (EOF or a reset) within 2 s.
fn assert_ends_at_once(reader: &mut BufReader<UnixStream>, since: Instant) {
    let mut byte = [0u8; 1];
    let read = reader.read(&mut byte);
    assert!(matches!(read, Ok(0) | Err(_)), "the dial is closed, got {read:?}");
    assert!(since.elapsed() < Duration::from_secs(2), "closed after {:?}", since.elapsed());
}

#[test]
fn a_running_stream_is_a_registered_remote_client_and_a_kick_ends_it() {
    let entry = entry("kick", FIRST_LINE_DEADLINE);
    let (_stream, mut reader) = start_write(&entry);
    assert!(wait_until(|| remote_clients(&entry.mux).len() == 1), "the stream is registered");
    let client = remote_clients(&entry.mux)[0];
    let start = Instant::now();
    assert!(super::super::disconnect_client(&entry.mux, client, false));
    assert_ends_at_once(&mut reader, start);
    assert!(wait_until(|| home_is_empty(&entry)), "no file and no temporary left");
}

#[test]
fn the_link_closing_the_dial_ends_the_stream_at_once() {
    let entry = entry("revoke", FIRST_LINE_DEADLINE);
    let (stream, reader) = start_write(&entry);
    assert!(wait_until(|| remote_clients(&entry.mux).len() == 1));
    let start = Instant::now();
    // Revocation: the link tears its splice down.
    stream.shutdown(std::net::Shutdown::Both).unwrap();
    drop((stream, reader));
    assert!(wait_until(|| remote_clients(&entry.mux).is_empty()), "the stream unregistered");
    assert!(start.elapsed() < Duration::from_secs(2), "ended after {:?}", start.elapsed());
    assert!(wait_until(|| home_is_empty(&entry)), "no file and no temporary left");
}

#[test]
fn the_daemon_shutting_down_its_entry_ends_a_running_stream_at_once() {
    let mut entry = entry("shutdown", FIRST_LINE_DEADLINE);
    let (_stream, mut reader) = start_write(&entry);
    assert!(wait_until(|| remote_clients(&entry.mux).len() == 1));
    let start = Instant::now();
    drop(entry.server.take());
    assert_ends_at_once(&mut reader, start);
    assert!(wait_until(|| home_is_empty(&entry)), "no file and no temporary left");
}

#[test]
fn a_dial_without_a_first_line_is_closed_at_the_deadline() {
    let entry = entry("deadline", Duration::from_millis(300));
    let (_stream, mut reader) = dial(&entry);
    let start = Instant::now();
    let mut byte = [0u8; 1];
    let read = reader.read(&mut byte);
    assert!(matches!(read, Ok(0) | Err(_)), "the silent dial is closed, got {read:?}");
    let elapsed = start.elapsed();
    assert!(elapsed < Duration::from_secs(3), "closed after {elapsed:?}, not at the deadline");
    assert!(remote_clients(&entry.mux).is_empty());
}

#[test]
fn a_first_line_within_the_deadline_is_served() {
    let entry = entry("in-time", Duration::from_secs(5));
    let (mut stream, mut reader) = dial(&entry);
    let line = entry.home.map(r#"{"id":9,"cmd":"fs.stat","path":"/home/cmux"}"#);
    stream.write_all(format!("{line}\n").as_bytes()).unwrap();
    let mut answer = String::new();
    reader.read_line(&mut answer).unwrap();
    let answer: Value = serde_json::from_str(&answer).unwrap();
    // Served (this test process installs no owner), not closed.
    assert_eq!(answer["id"], 9);
    assert_eq!(answer["error_code"], "fs.unavailable", "{answer}");
}

/// Link revocation (server-remote-conversations.md section 10): revoking the
/// install ends its running stream at once, and a new stream of that install
/// is refused before its first byte.
#[test]
fn revoking_the_install_ends_its_running_stream_at_once() {
    let entry = entry("revoke-install", FIRST_LINE_DEADLINE);
    let (_stream, mut reader) = start_write(&entry);
    assert!(wait_until(|| remote_clients(&entry.mux).len() == 1));
    let start = Instant::now();
    entry.mux.revoke_remote_install("inst_1").unwrap();
    assert_ends_at_once(&mut reader, start);
    assert!(wait_until(|| home_is_empty(&entry)), "no file and no temporary left");
    let (mut again, mut again_reader) = dial(&entry);
    let line = entry.home.map(
        r#"{"id":1,"cmd":"fs.write","path":"/home/cmux/up.bin","mode":"create","stream":true,"size":5}"#,
    );
    let _ = again.write_all(format!("{line}\n").as_bytes());
    let mut answer = String::new();
    let read = again_reader.read_line(&mut answer);
    assert!(matches!(read, Ok(0) | Err(_)), "a revoked install gets no stream, got {answer:?}");
    assert!(home_is_empty(&entry));
}
