//! Supervisor tests of run cancel (app-op-routing.md "Op cancel"): a caller
//! that cancels or closes its connection gets `cmux.op.cancelled` once, and
//! the server gets `op.cancel` when no other caller waits for the op.

use super::*;
use crate::apps::runs::Caller;

type Answer = Result<Value, super::super::super::supervisor::ApiError>;

/// An installed on-demand server app `cmux/cncl` and its marker file.
fn cancel_fixture(name: &str) -> (Fixture, PathBuf) {
    let root = temp_dir();
    let marker = root.0.join(format!("{name}.marker"));
    write_fake_server(&root.0.join("servers"));
    write_server_app(
        &root.0.join("bundled"),
        "cncl",
        native_server(&marker, json!({ "start": "onDemand" })),
    );
    let f = fixture_with(&[], Duration::from_secs(60), root);
    f.install("cmux/cncl");
    (f, marker)
}

/// Runs `op` for `client`'s request `request` and returns its answers.
fn run_for(
    f: &Fixture,
    op: &str,
    key: Option<&str>,
    client: u64,
    request: Value,
) -> Receiver<Answer> {
    let (tx, rx) = channel();
    let mut run = run_request("cmux/cncl", op, key.map(str::to_string), Origin::Cli, None);
    run.caller = Some(Caller { client, request });
    f.supervisor.run(run, Box::new(move |r| tx.send(r).unwrap()));
    rx
}

/// The lines the server received, parsed.
fn server_lines(marker: &Path) -> Vec<Value> {
    let path = marker.with_extension("marker.lines");
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect()
}

/// Waits until the server received `count` lines and returns them.
fn wait_lines(marker: &Path, count: usize) -> Vec<Value> {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let lines = server_lines(marker);
        if lines.len() >= count {
            return lines;
        }
        assert!(Instant::now() < deadline, "server lines {lines:?}, want {count}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn cancels(marker: &Path) -> Vec<Value> {
    server_lines(marker).into_iter().filter(|l| l["type"] == "op.cancel").collect()
}

fn assert_cancelled(rx: &Receiver<Answer>) {
    let error = rx.recv_timeout(Duration::from_secs(10)).unwrap().unwrap_err();
    assert_eq!(error.code, "cmux.op.cancelled");
    assert!(!error.retryable);
}

/// No further answer comes (a cancelled caller is answered once).
fn assert_silent(rx: &Receiver<Answer>) {
    assert!(rx.recv_timeout(Duration::from_millis(300)).is_err(), "a second answer came");
}

#[test]
fn a_cancel_request_sends_op_cancel_and_answers_the_caller_once() {
    let (f, marker) = cancel_fixture("request");
    let rx = run_for(&f, "cncl.hang", Some("k1"), 9, json!("r1"));
    let op_id = wait_lines(&marker, 1)[0]["id"].clone();
    f.supervisor.cancel_request(9, &json!("r1"));
    assert_cancelled(&rx);
    wait_lines(&marker, 2);
    assert_eq!(cancels(&marker), vec![json!({ "type": "op.cancel", "id": op_id })]);
    // The server's own cmux.op.cancelled answer is not a second answer.
    assert_silent(&rx);
    // A second cancel sends nothing; the server still serves.
    f.supervisor.cancel_request(9, &json!("r1"));
    let ping = run_for(&f, "cncl.ping", None, 9, json!("r2"));
    assert_eq!(
        ping.recv_timeout(Duration::from_secs(10)).unwrap().unwrap(),
        json!({ "value": { "served": true } })
    );
    assert_eq!(cancels(&marker).len(), 1);
}

#[test]
fn a_closed_connection_cancels_only_its_own_runs() {
    let (f, marker) = cancel_fixture("closed");
    let mine = run_for(&f, "cncl.hang", Some("a"), 9, json!(1));
    let other = run_for(&f, "cncl.hang", Some("b"), 10, json!(1));
    wait_lines(&marker, 2);
    f.supervisor.disconnect(9);
    assert_cancelled(&mine);
    wait_lines(&marker, 3);
    let sent = cancels(&marker);
    assert_eq!(sent.len(), 1);
    let first = server_lines(&marker).into_iter().find(|l| l["idempotency_key"] == "a").unwrap();
    assert_eq!(sent[0]["id"], first["id"]);
    assert_silent(&other);
    f.supervisor.cancel_request(10, &json!(1));
    assert_cancelled(&other);
}

#[test]
fn a_shared_key_op_is_cancelled_when_its_last_caller_cancels() {
    let (f, marker) = cancel_fixture("shared");
    let first = run_for(&f, "cncl.hang", Some("same"), 9, json!("x"));
    let second = run_for(&f, "cncl.hang", Some("same"), 10, json!("y"));
    // The same key runs one op.
    wait_lines(&marker, 1);
    std::thread::sleep(Duration::from_millis(200));
    assert_eq!(server_lines(&marker).len(), 1);
    f.supervisor.cancel_request(9, &json!("x"));
    assert_cancelled(&first);
    std::thread::sleep(Duration::from_millis(200));
    assert!(cancels(&marker).is_empty(), "another caller still waits");
    assert_silent(&second);
    f.supervisor.cancel_request(10, &json!("y"));
    assert_cancelled(&second);
    wait_lines(&marker, 2);
    assert_eq!(cancels(&marker).len(), 1);
    // A same-key retry after the cancel runs again.
    let retry = run_for(&f, "cncl.hang", Some("same"), 9, json!("z"));
    let lines = wait_lines(&marker, 3);
    assert_eq!(lines[2]["type"], "op");
    assert_ne!(lines[2]["id"], lines[0]["id"]);
    f.supervisor.cancel_request(9, &json!("z"));
    assert_cancelled(&retry);
}

#[test]
fn unknown_and_finished_requests_cancel_nothing() {
    let (f, marker) = cancel_fixture("finished");
    f.supervisor.cancel_request(9, &json!("nope"));
    let done = run_for(&f, "cncl.ping", None, 9, json!("p"));
    assert!(done.recv_timeout(Duration::from_secs(10)).unwrap().is_ok());
    f.supervisor.cancel_request(9, &json!("p"));
    f.supervisor.disconnect(9);
    std::thread::sleep(Duration::from_millis(200));
    assert!(cancels(&marker).is_empty());
    assert_silent(&done);
}
