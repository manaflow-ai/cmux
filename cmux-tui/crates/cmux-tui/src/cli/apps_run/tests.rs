//! `cmux apps run` against a fake daemon: Ctrl-C sends cancel-request,
//! waits at most 3 s for cmux.op.cancelled, exits 130; a second Ctrl-C
//! exits at once.

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, DuplexStream};
use tokio::sync::mpsc;

use super::*;

struct FakeInterrupts(mpsc::UnboundedReceiver<()>);

impl Interrupts for FakeInterrupts {
    async fn next(&mut self) {
        if self.0.recv().await.is_none() {
            std::future::pending::<()>().await;
        }
    }
}

fn op() -> AppOp {
    AppOp {
        app: "cmux/cloud".into(),
        op: "cloud.machine.list".into(),
        args: json!({"team": "t1"}),
        idempotency_key: Some("k1".into()),
    }
}

/// The daemon side of the connection.
struct Daemon {
    lines: tokio::io::Lines<BufReader<tokio::io::ReadHalf<DuplexStream>>>,
    writer: tokio::io::WriteHalf<DuplexStream>,
}

impl Daemon {
    async fn read(&mut self) -> Value {
        let line = self.lines.next_line().await.unwrap().expect("a request line");
        serde_json::from_str(&line).unwrap()
    }

    async fn write(&mut self, value: Value) {
        self.writer.write_all(format!("{value}\n").as_bytes()).await.unwrap();
    }

    /// Answer the CLI's `identify`, with or without the cancel-request
    /// capability.
    async fn handshake(&mut self, cancel_request: bool) {
        let identify = self.read().await;
        assert_eq!(identify["cmd"], "identify");
        let mut capabilities = vec![json!("session-journal-v1")];
        if cancel_request {
            capabilities.push(json!(CANCEL_REQUEST_CAPABILITY));
        }
        self.write(json!({"id": identify["id"], "ok": true,
            "data": {"capabilities": capabilities}}))
        .await;
    }
}

/// The injected cancel bound for the tests (the CLI uses CANCEL_WAIT).
const TEST_WAIT: Duration = Duration::from_millis(200);

fn start_with(
    cancel_wait: Duration,
) -> (tokio::task::JoinHandle<Outcome>, Daemon, mpsc::UnboundedSender<()>) {
    let (client, server) = tokio::io::duplex(64 * 1024);
    let (press, presses) = mpsc::unbounded_channel();
    let run = tokio::spawn(async move {
        run_app_op(client, &op(), FakeInterrupts(presses), cancel_wait).await
    });
    let (reader, writer) = tokio::io::split(server);
    (run, Daemon { lines: BufReader::new(reader).lines(), writer }, press)
}

fn start() -> (tokio::task::JoinHandle<Outcome>, Daemon, mpsc::UnboundedSender<()>) {
    start_with(TEST_WAIT)
}

/// RED: the first Ctrl-C sends the generic cancel-request for the run on the
/// same connection; the run's cmux.op.cancelled answer ends it with 130.
#[tokio::test]
async fn the_first_ctrl_c_sends_cancel_request_and_the_cancelled_answer_exits_130() {
    let (run, mut daemon, press) = start();
    daemon.handshake(true).await;
    let request = daemon.read().await;
    assert_eq!(request["cmd"], "apps-run");
    assert_eq!(request["app"], "cmux/cloud");
    assert_eq!(request["op"], "cloud.machine.list");
    assert_eq!(request["args"], json!({"team": "t1"}));
    assert_eq!(request["idempotency_key"], "k1");
    press.send(()).unwrap();
    let cancel = daemon.read().await;
    assert_eq!(cancel["cmd"], "cancel-request");
    assert_eq!(cancel["target"], request["id"]);
    assert_ne!(cancel["id"], request["id"]);
    daemon.write(json!({"id": cancel["id"], "ok": true, "data": {}})).await;
    daemon
        .write(json!({"id": request["id"], "ok": false, "error": "cancelled",
            "error_code": "cmux.op.cancelled", "retryable": false}))
        .await;
    let outcome = run.await.unwrap();
    assert_eq!(outcome, Outcome::Cancelled { confirmed: true });
    let (stdout, stderr, code) = report(&outcome, OutputMode::Human);
    assert_eq!((stdout, code), (None, EXIT_CANCELLED));
    assert!(stderr.unwrap().contains(messages().cancelled));
}

/// RED: with no answer the wait ends after the injected bound, still 130.
#[tokio::test]
async fn an_unconfirmed_cancel_ends_after_three_seconds_with_130() {
    let (run, mut daemon, press) = start();
    daemon.handshake(true).await;
    let _request = daemon.read().await;
    press.send(()).unwrap();
    let cancel = daemon.read().await;
    assert_eq!(cancel["cmd"], "cancel-request");
    let started = std::time::Instant::now();
    let outcome = run.await.unwrap();
    assert_eq!(outcome, Outcome::Cancelled { confirmed: false });
    let waited = started.elapsed();
    assert!(waited >= TEST_WAIT / 2 && waited < TEST_WAIT * 20, "waited {waited:?}");
    assert_eq!(report(&outcome, OutputMode::Human).2, EXIT_CANCELLED);
}

#[tokio::test]
async fn a_second_ctrl_c_exits_at_once() {
    // A long bound: only the second Ctrl-C can end the wait in time.
    let (run, mut daemon, press) = start_with(Duration::from_secs(60));
    daemon.handshake(true).await;
    let _request = daemon.read().await;
    let started = std::time::Instant::now();
    press.send(()).unwrap();
    press.send(()).unwrap();
    let outcome = run.await.unwrap();
    assert_eq!(outcome, Outcome::Interrupted);
    assert!(started.elapsed() < Duration::from_secs(10));
    assert_eq!(report(&outcome, OutputMode::Human).2, EXIT_CANCELLED);
}

#[tokio::test]
async fn an_answer_is_printed_and_other_lines_are_skipped() {
    let (run, mut daemon, _press) = start();
    daemon.handshake(true).await;
    let request = daemon.read().await;
    daemon.write(json!({"event": "apps-changed"})).await;
    daemon.write(json!({"id": "other", "ok": true, "data": {"x": 0}})).await;
    daemon.write(json!({"id": request["id"], "ok": true, "data": {"machines": []}})).await;
    let outcome = run.await.unwrap();
    let (stdout, stderr, code) = report(&outcome, OutputMode::Human);
    assert_eq!((stdout.as_deref(), stderr, code), (Some("{\"machines\":[]}"), None, 0));

    let (run, mut daemon, _press) = start();
    daemon.handshake(true).await;
    let request = daemon.read().await;
    daemon
        .write(json!({"id": request["id"], "ok": false, "error": "no such machine",
            "error_code": "cmux.cloud.not_found"}))
        .await;
    let (_, stderr, code) = report(&run.await.unwrap(), OutputMode::Human);
    assert_eq!(code, 1);
    assert!(stderr.unwrap().contains("cmux.cloud.not_found"));

    let (run, daemon, _press) = start();
    drop(daemon);
    let outcome = run.await.unwrap();
    assert_eq!(outcome, Outcome::Closed);
    assert_eq!(report(&outcome, OutputMode::Human).2, 3);
}

#[test]
fn the_arguments_are_app_op_and_json_args() {
    let args = |list: &[&str]| list.iter().map(|value| (*value).to_string()).collect::<Vec<_>>();
    let parsed = parse(&args(&["cmux/cloud", "cloud.machine.list"]), None).unwrap();
    assert_eq!(parsed.args, json!({}));
    let parsed =
        parse(&args(&["cmux/cloud", "op", "--args", "{\"a\":1}"]), Some("k".into())).unwrap();
    assert_eq!((parsed.args, parsed.idempotency_key), (json!({"a": 1}), Some("k".into())));
    for bad in [&["cmux/cloud"][..], &["cmux/cloud", "op", "--args", "[1]"], &["a", "b", "--x", "y"]] {
        assert!(parse(&args(bad), None).is_err(), "{bad:?}");
    }
    assert_eq!(VERB, ["apps", "run"]);
}

/// Without the cancel-request capability the first Ctrl-C closes the
/// connection (the supervisor then cancels the op) and reports an
/// unconfirmed cancel, 130.
#[tokio::test]
async fn without_the_capability_ctrl_c_closes_the_connection() {
    let (run, mut daemon, press) = start();
    daemon.handshake(false).await;
    let request = daemon.read().await;
    assert_eq!(request["cmd"], "apps-run");
    assert!(request.get("origin").is_none(), "the CLI never sends an origin");
    press.send(()).unwrap();
    let outcome = run.await.unwrap();
    assert_eq!(outcome, Outcome::Cancelled { confirmed: false });
    assert!(daemon.lines.next_line().await.unwrap().is_none(), "no cancel-request, connection closed");
    let (_, stderr, code) = report(&outcome, OutputMode::Human);
    assert_eq!(code, EXIT_CANCELLED);
    assert_eq!(stderr.as_deref(), Some(messages().cancel_unconfirmed));
}

#[test]
fn errors_the_cli_meets_by_design_say_what_to_do() {
    let answer = json!({"id": "x", "ok": false, "error": "needs a gesture",
        "error_code": "apps.gesture_required", "error_details": {"op": "cloud.machine.delete"},
        "retryable": false});
    let (_, stderr, code) = report(&Outcome::Answer(answer), OutputMode::Human);
    let stderr = stderr.unwrap();
    assert_eq!(code, 1);
    assert!(stderr.contains("apps.gesture_required"), "{stderr}");
    assert!(stderr.contains(messages().gesture_required), "{stderr}");
    assert!(stderr.contains("cloud.machine.delete"), "{stderr}");
}
