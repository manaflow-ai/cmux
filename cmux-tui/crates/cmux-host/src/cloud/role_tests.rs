//! The Linux worker's poll loop, driven for real under a temporary root.

use std::io::Write;
use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::time::{Duration, Instant};

use super::Worker;
use crate::cloud::wire::AGENT_SOCKET;
use crate::config::Paths;

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
        let mut worker =
            Worker::new(worker_paths, "vm-1".to_owned(), None, theirs, Arc::default())?;
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

/// A `github_token` line is answered on its own connection; an unbound
/// machine and a malformed ask are refusals, and the worker keeps going.
#[test]
fn github_token_asks_get_one_reply_line() {
    use std::io::{BufRead, BufReader};
    let root = tempfile::tempdir().unwrap();
    let paths = Paths::new(root.path());
    let (ours, theirs) = UnixStream::pair().unwrap();
    let worker_paths = paths.clone();
    let thread = std::thread::spawn(move || {
        let mut worker =
            Worker::new(worker_paths, "vm-1".to_owned(), None, theirs, Arc::default())?;
        worker.run()
    });
    let socket = paths.at(AGENT_SOCKET);
    let deadline = Instant::now() + Duration::from_secs(10);
    while !socket.exists() {
        assert!(Instant::now() < deadline, "the agent socket never appeared");
        std::thread::sleep(Duration::from_millis(10));
    }
    let ask = |line: &str| -> serde_json::Value {
        let mut client = UnixStream::connect(&socket).unwrap();
        client.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        client.write_all(line.as_bytes()).unwrap();
        let mut reply = String::new();
        BufReader::new(client).read_line(&mut reply).unwrap();
        serde_json::from_str(&reply).unwrap()
    };
    let unbound =
        ask("{\"github_token\": {\"repo\": \"o/r\", \"permissions\": {\"contents\": \"read\"}}}\n");
    assert_eq!(unbound["ok"], false);
    assert_eq!(unbound["error"]["code"], "vm.unbound");
    let invalid = ask(
        "{\"github_token\": {\"repo\": \"no-slash\", \"permissions\": {\"contents\": \"read\"}}}\n",
    );
    assert_eq!(invalid["error"]["code"], "request.invalid");
    let mut control = ours;
    control.write_all(b"stop\n").unwrap();
    let result = thread.join();
    assert!(result.is_ok(), "the worker thread panicked");
    result.unwrap().unwrap();
}
