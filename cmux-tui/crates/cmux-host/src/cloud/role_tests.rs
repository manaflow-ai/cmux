//! The Linux worker's poll loop, driven for real under a temporary root.

use std::io::Write;
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

use super::Worker;
use crate::cloud::wire::AGENT_SOCKET;
use crate::config::Paths;

/// Exercise the real agent socket and client reply routing without starting
/// network jobs or polling for readiness. Unbound agents must answer closed.
#[test]
fn vm_receiver_client_socket_refuses_unbound_and_caller_identity() {
    use std::io::{BufRead, BufReader};
    let root = tempfile::tempdir().unwrap();
    let paths = Paths::new(root.path());
    let (_control, theirs) = UnixStream::pair().unwrap();
    let mut worker = Worker::new(paths.clone(), "vm-1".into(), None, theirs).unwrap();
    worker.listener = Some(worker.serve_socket().unwrap());
    let mut first = UnixStream::connect(paths.at(AGENT_SOCKET)).unwrap();
    let mut second = UnixStream::connect(paths.at(AGENT_SOCKET)).unwrap();
    first.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
    second.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
    first.write_all(b"{\"op\":\"cloud.vm.network_policy\"}\n").unwrap();
    second
        .write_all(b"{\"op\":\"cloud.vm.network_policy\",\"machine\":\"caller-chosen\"}\n")
        .unwrap();
    worker.accept();
    assert_eq!(worker.clients.len(), 2);
    worker.read_clients(&[0, 1]);
    for stream in [first, second] {
        let mut line = String::new();
        BufReader::new(stream).read_line(&mut line).unwrap();
        let reply: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(
            reply,
            serde_json::json!({"ok":false,"error":"cloud.vm.network_policy.unavailable"})
        );
    }
    assert!(worker.live.is_none());
}

#[test]
fn vm_receiver_client_socket_discards_reply_after_its_write_deadline() {
    use std::io::Read;
    let root = tempfile::tempdir().unwrap();
    let (_control, theirs) = UnixStream::pair().unwrap();
    let mut worker = Worker::new(Paths::new(root.path()), "vm-1".into(), None, theirs).unwrap();
    let (mut caller, stream) = UnixStream::pair().unwrap();
    stream.set_nonblocking(true).unwrap();
    caller.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
    worker.clients.push(super::Client {
        stream,
        buf: Vec::new(),
        output: b"stale authority must not arrive\n".to_vec(),
        sent: 0,
        eof: false,
        write_deadline: Some(0),
    });
    assert!(!worker.read_clients(&[0]));
    assert!(worker.clients.is_empty());
    let mut bytes = Vec::new();
    caller.read_to_end(&mut bytes).unwrap();
    assert!(bytes.is_empty());
}

/// dev-e2e on sh-584ab926a57d (2026-10-08): the first client of the agent
/// socket killed the worker (`index out of bounds` in the poll loop: a client
/// accepted in this pass was read with the revents of the previous pass), so
/// no report followed the first one. The worker must take clients, read
/// their lines, and still stop cleanly.
#[test]
fn agent_socket_clients_never_stop_the_worker() {
    let root = tempfile::tempdir().unwrap();
    let paths = Paths::new(root.path());
    let (ours, theirs) = UnixStream::pair().unwrap();
    let worker_paths = paths.clone();
    let thread = std::thread::spawn(move || {
        let mut worker = Worker::new(worker_paths, "vm-1".to_owned(), None, theirs)?;
        worker.run()
    });
    let socket = paths.at(AGENT_SOCKET);
    let deadline = Instant::now() + Duration::from_secs(10);
    while !socket.exists() {
        assert!(Instant::now() < deadline, "the agent socket never appeared");
        std::thread::sleep(Duration::from_millis(10));
    }
    for _ in 0..3 {
        let mut client = UnixStream::connect(&socket).unwrap();
        client.write_all(b"{\"activity\": {\"active_sessions\": 1}}\n").unwrap();
        drop(client);
        std::thread::sleep(Duration::from_millis(50));
    }
    let mut control = ours;
    control.write_all(b"stop\n").unwrap();
    let result = thread.join();
    assert!(result.is_ok(), "the worker thread panicked");
    result.unwrap().unwrap();
}
