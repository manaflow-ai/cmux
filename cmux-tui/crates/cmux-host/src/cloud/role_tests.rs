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

/// A `github_token` or `handoff_report` line is answered on its own connection; an unbound
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
    // A hand-off report (acpmux, `daemon/cloud_handoff.rs`) is answered the same way.
    let report =
        ask("{\"handoff_report\": {\"session\": \"s1\", \"turn\": 1, \"status\": \"running\"}}\n");
    assert_eq!(report["error"]["code"], "vm.unbound");
    let bad =
        ask("{\"handoff_report\": {\"session\": \"s1\", \"turn\": 0, \"status\": \"running\"}}\n");
    assert_eq!(bad["error"]["code"], "request.invalid");
    let mut control = ours;
    control.write_all(b"stop\n").unwrap();
    let result = thread.join();
    assert!(result.is_ok(), "the worker thread panicked");
    result.unwrap().unwrap();
}

/// A fake daemon socket that answers `identify` with `reply` (one write per item,
/// `gap` apart), then holds the connection open for `hold`.
fn fake_daemon(
    replies: Vec<Vec<u8>>,
    gap: Duration,
    hold: Duration,
) -> (tempfile::TempDir, std::path::PathBuf) {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("daemon.sock");
    let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
    std::thread::spawn(move || {
        let Ok((mut stream, _)) = listener.accept() else { return };
        for reply in replies {
            if stream.write_all(&reply).is_err() {
                return;
            }
            std::thread::sleep(gap);
        }
        std::thread::sleep(hold);
    });
    (dir, socket)
}

/// HQ#5351 item 3: a byte every 100 ms beat the per-read timeout forever, so
/// the poll thread never got its answer. The whole identify keeps one deadline.
#[test]
fn identify_from_a_daemon_that_drips_bytes_ends_at_its_deadline() {
    let (_dir, socket) =
        fake_daemon(vec![b"{".to_vec(); 100], Duration::from_millis(100), Duration::ZERO);
    let (tx, rx) = std::sync::mpsc::channel();
    let started = Instant::now();
    std::thread::spawn(move || {
        let _ = tx.send(super::query_identify(&socket, Duration::from_millis(300)).is_err());
    });
    let refused = rx.recv_timeout(Duration::from_secs(3)).expect("identify outlived its deadline");
    assert!(refused);
    assert!(started.elapsed() < Duration::from_secs(2));
}

/// HQ#5351 item 3: a daemon line with no newline was read without a cap. The
/// identify gives up once the line is over `MAX_LINE`, not at its read timeout.
#[test]
fn identify_stops_reading_a_line_over_max_line() {
    let (_dir, socket) =
        fake_daemon(vec![vec![b'x'; 1024 * 1024]], Duration::ZERO, Duration::from_secs(6));
    let started = Instant::now();
    assert!(super::query_identify(&socket, Duration::from_secs(5)).is_err());
    // Without the cap the read waits out the whole 5 s timeout.
    let elapsed = started.elapsed();
    assert!(elapsed < Duration::from_millis(2500), "read past MAX_LINE: {elapsed:?}");
}

/// A complete, valid reply just over `MAX_LINE` is refused too, even when its
/// newline arrives in the read that crosses the cap.
#[test]
fn identify_refuses_a_whole_reply_over_max_line() {
    let head = b"{\"ok\":true,\"data\":{\"pad\":\"";
    let tail = b"\"}}\n";
    let mut reply = head.to_vec();
    reply.resize(super::MAX_LINE + 100 - tail.len(), b'x');
    reply.extend_from_slice(tail);
    let (_dir, socket) = fake_daemon(vec![reply], Duration::ZERO, Duration::from_secs(1));
    assert!(super::query_identify(&socket, Duration::from_secs(3)).is_err());
}

/// HQ#5351 item 3: the activity stream kept an unfinished line past `MAX_LINE`
/// and rescanned it on every read. Over the cap the stream counts as dropped.
#[test]
fn a_line_over_max_line_ends_the_stream() {
    let (mut ours, mut theirs) = UnixStream::pair().unwrap();
    theirs.set_nonblocking(true).unwrap();
    let mut buf = Vec::new();
    ours.write_all(b"{\"ok\":true}\nxx").unwrap();
    let (lines, open) = super::read_lines(&mut theirs, &mut buf);
    assert_eq!(lines, vec!["{\"ok\":true}".to_owned()]);
    assert!(open);
    let writer = std::thread::spawn(move || {
        let _ = ours.write_all(&vec![b'x'; 2 * super::MAX_LINE]);
        ours
    });
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let (lines, open) = super::read_lines(&mut theirs, &mut buf);
        assert!(lines.is_empty());
        if !open {
            break;
        }
        assert!(Instant::now() < deadline, "the stream stayed open past MAX_LINE");
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(buf.len() <= 2 * super::MAX_LINE + 4096);
    drop(theirs);
    let _ = writer.join();
}
