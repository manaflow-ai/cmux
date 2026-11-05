//! The socket reader's bounds and the writer's end (`stream.rs`, manaflow-ai/cmuxterm-hq#2888).

use super::{Limits, read_lines, write_lines};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::{mpsc, oneshot};

const MAX: usize = 1024;
const LIMITS: Limits = Limits { line: MAX, small: 64 };
const WAIT: Duration = Duration::from_secs(10);

/// The client's end, what the server reads, the line that ends the connection, and the reader.
fn reader(
    lines: usize,
) -> (
    tokio::io::DuplexStream,
    mpsc::Receiver<String>,
    oneshot::Receiver<String>,
    tokio::task::JoinHandle<()>,
) {
    let (client, server) = tokio::io::duplex(4 * MAX);
    let (in_tx, in_rx) = mpsc::channel(lines);
    let (last_tx, last_rx) = oneshot::channel();
    let task = tokio::spawn(read_lines(server, in_tx, last_tx, LIMITS));
    (client, in_rx, last_rx, task)
}

fn too_large(line: &str) {
    let reply: serde_json::Value = serde_json::from_str(line).unwrap();
    assert!(reply["id"].is_null(), "{reply}");
    assert_eq!(reply["error"]["data"]["reason"], "message.too_large", "{reply}");
    assert_eq!(reply["error"]["data"]["limit"], MAX, "{reply}");
}

#[tokio::test]
async fn lines_up_to_the_limit_go_through_whole() {
    let (mut client, mut in_rx, _last, task) = reader(256);
    let at_limit = "x".repeat(MAX);
    // At the limit with a `\r\n` too: the `\r` is not part of the line.
    client.write_all(format!("{{}}\r\n{at_limit}\n{at_limit}\r\nlast").as_bytes()).await.unwrap();
    drop(client);
    assert_eq!(in_rx.recv().await.as_deref(), Some("{}"));
    assert_eq!(in_rx.recv().await.as_deref(), Some(at_limit.as_str()));
    assert_eq!(in_rx.recv().await.as_deref(), Some(at_limit.as_str()));
    assert_eq!(in_rx.recv().await.as_deref(), Some("last"));
    assert_eq!(in_rx.recv().await, None);
    task.await.unwrap();
}

#[tokio::test]
async fn a_longer_line_ends_the_connection_with_an_error_saying_why() {
    let (mut client, mut in_rx, last, task) = reader(256);
    let over = "x".repeat(MAX + 1);
    client.write_all(format!("{{}}\n{over}\n{{}}\n").as_bytes()).await.unwrap();
    assert_eq!(in_rx.recv().await.as_deref(), Some("{}"));
    // Nothing after it is read: the line itself, nor the request behind it.
    assert_eq!(in_rx.recv().await, None);
    task.await.unwrap();
    too_large(&last.await.expect("an error before the connection ends"));
}

#[tokio::test]
async fn one_byte_past_the_limit_is_refused_with_or_without_a_carriage_return() {
    for end in ["\n", "\r\n"] {
        let (mut client, mut in_rx, last, task) = reader(256);
        client.write_all(format!("{}{end}", "x".repeat(MAX + 1)).as_bytes()).await.unwrap();
        assert_eq!(in_rx.recv().await, None, "{end:?}");
        task.await.unwrap();
        too_large(&last.await.unwrap());
    }
}

/// The reader stops at the limit: a client that never sends a newline cannot make it keep
/// reading (and holding) more.
#[tokio::test]
async fn a_line_with_no_end_is_not_read_past_the_limit() {
    let (mut client, mut in_rx, _last, task) = reader(256);
    let endless = vec![b'x'; 64 * MAX];
    let wrote = tokio::time::timeout(WAIT, client.write_all(&endless))
        .await
        .expect("the reader stopped reading without closing");
    assert!(wrote.is_err(), "the reader read all of it");
    assert_eq!(in_rx.recv().await, None);
    task.await.unwrap();
}

/// A large line waits for the lines before it to be taken, so the server's inbound queue holds
/// one large line at most, not one per slot.
#[tokio::test]
async fn a_large_line_waits_until_the_lines_before_it_are_taken() {
    let (mut client, mut in_rx, _last, _task) = reader(4);
    let large = "y".repeat(LIMITS.small + 1);
    client.write_all(format!("a\nb\n{large}\n").as_bytes()).await.unwrap();
    // The small ones are in; the large one is not, while they wait.
    tokio::time::timeout(WAIT, async {
        while in_rx.len() < 2 {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    for _ in 0..100 {
        tokio::task::yield_now().await;
    }
    assert_eq!(in_rx.len(), 2);
    assert_eq!(in_rx.recv().await.as_deref(), Some("a"));
    assert_eq!(in_rx.len(), 1, "the large line went in before the lines before it were taken");
    assert_eq!(in_rx.recv().await.as_deref(), Some("b"));
    assert_eq!(in_rx.recv().await.as_deref(), Some(large.as_str()));
}

/// The writer's ends: what the client reads, the queue's sender (that request handlers hold),
/// the last line's sender, and the writer.
fn writer(
    buffer: usize,
) -> (
    tokio::io::DuplexStream,
    mpsc::Sender<String>,
    oneshot::Sender<String>,
    tokio::task::JoinHandle<()>,
) {
    let (client, server) = tokio::io::duplex(buffer);
    let (out_tx, out_rx) = mpsc::channel(16);
    let (last_tx, last_rx) = oneshot::channel();
    let task = tokio::spawn(write_lines(server, out_rx, last_rx));
    (client, out_tx, last_tx, task)
}

/// The last line goes out and the connection ends, though handlers still hold the queue.
#[tokio::test]
async fn the_last_line_ends_the_connection_while_handlers_hold_the_queue() {
    let (mut client, out_tx, last_tx, task) = writer(4 * MAX);
    out_tx.send("a\n".to_owned()).await.unwrap();
    let mut first = [0u8; 2];
    client.read_exact(&mut first).await.unwrap();
    assert_eq!(&first, b"a\n");
    last_tx.send("bye\n".to_owned()).unwrap();
    let mut rest = String::new();
    tokio::time::timeout(WAIT, client.read_to_string(&mut rest))
        .await
        .expect("the connection did not end")
        .unwrap();
    assert_eq!(rest, "bye\n");
    task.await.unwrap();
    drop(out_tx);
}

/// A line half written when the last one comes is finished first, so the client never reads a
/// cut line.
#[tokio::test]
async fn a_line_half_written_is_finished_before_the_last_one() {
    let (mut client, out_tx, last_tx, task) = writer(8);
    let long = format!("{}\n", "z".repeat(64));
    out_tx.send(long.clone()).await.unwrap();
    let mut some = [0u8; 8];
    client.read_exact(&mut some).await.unwrap();
    last_tx.send("bye\n".to_owned()).unwrap();
    let mut rest = String::new();
    tokio::time::timeout(WAIT, client.read_to_string(&mut rest)).await.unwrap().unwrap();
    assert_eq!(format!("{}{rest}", std::str::from_utf8(&some).unwrap()), format!("{long}bye\n"));
    task.await.unwrap();
    drop(out_tx);
}

/// A client that reads nothing still has its connection ended, within the wait.
#[tokio::test(start_paused = true)]
async fn a_client_that_reads_nothing_cannot_keep_the_connection_open() {
    let (_client, out_tx, last_tx, task) = writer(8);
    out_tx.send("x".repeat(MAX)).await.unwrap();
    tokio::task::yield_now().await;
    last_tx.send("bye\n".to_owned()).unwrap();
    tokio::time::timeout(WAIT, task).await.expect("the writer waited for the client").unwrap();
    drop(out_tx);
}

/// A reader that ends with no last line (the client closed its side) leaves the replies still
/// owed to go out.
#[tokio::test]
async fn replies_still_go_out_after_the_client_stops_sending() {
    let (mut client, out_tx, last_tx, task) = writer(4 * MAX);
    drop(last_tx);
    out_tx.send("reply\n".to_owned()).await.unwrap();
    drop(out_tx);
    let mut all = String::new();
    tokio::time::timeout(WAIT, client.read_to_string(&mut all)).await.unwrap().unwrap();
    assert_eq!(all, "reply\n");
    task.await.unwrap();
}
