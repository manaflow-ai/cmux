//! The socket reader's line bound (`stream.rs`, manaflow-ai/cmuxterm-hq#2888).

use super::read_lines;
use tokio::io::AsyncWriteExt;
use tokio::sync::mpsc;

const MAX: usize = 1024;

/// The client's end, what the server reads, what goes back, the sender the connection's server
/// holds while it serves, and the reader.
fn reader(max: usize) -> Reader {
    reader_with_room(max, 16)
}

type Reader = (
    tokio::io::DuplexStream,
    mpsc::Receiver<String>,
    mpsc::Receiver<String>,
    mpsc::Sender<String>,
    tokio::task::JoinHandle<()>,
);

/// [`reader`] whose outbound queue holds `room` lines.
fn reader_with_room(max: usize, room: usize) -> Reader {
    let (client, server) = tokio::io::duplex(4 * MAX);
    let (in_tx, in_rx) = mpsc::channel(256);
    let (out_tx, out_rx) = mpsc::channel(room);
    let task = tokio::spawn(read_lines(server, in_tx, out_tx.downgrade(), max));
    (client, in_rx, out_rx, out_tx, task)
}

#[tokio::test]
async fn lines_up_to_the_limit_go_through_whole() {
    let (mut client, mut in_rx, _out_rx, _out_tx, task) = reader(MAX);
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
    let (mut client, mut in_rx, mut out_rx, _out_tx, task) = reader(MAX);
    let over = "x".repeat(MAX + 1);
    client.write_all(format!("{{}}\n{over}\n{{}}\n").as_bytes()).await.unwrap();
    assert_eq!(in_rx.recv().await.as_deref(), Some("{}"));
    // Nothing after it is read: the line itself, nor the request behind it.
    assert_eq!(in_rx.recv().await, None);
    task.await.unwrap();
    let line = out_rx.recv().await.expect("an error before the connection ends");
    let reply: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert!(reply["id"].is_null(), "{reply}");
    assert_eq!(reply["error"]["data"]["reason"], "message.too_large", "{reply}");
    assert_eq!(reply["error"]["data"]["limit"], MAX, "{reply}");
}

/// The reader stops at the limit: a client that never sends a newline cannot make it keep
/// reading (and holding) more.
#[tokio::test]
async fn a_line_with_no_end_is_not_read_past_the_limit() {
    let (mut client, mut in_rx, _out_rx, _out_tx, task) = reader(MAX);
    let endless = vec![b'x'; 64 * MAX];
    let wrote =
        tokio::time::timeout(std::time::Duration::from_secs(10), client.write_all(&endless))
            .await
            .expect("the reader stopped reading without closing");
    assert!(wrote.is_err(), "the reader read all of it");
    assert_eq!(in_rx.recv().await, None);
    task.await.unwrap();
}

#[tokio::test]
async fn one_byte_past_the_limit_is_refused_with_or_without_a_carriage_return() {
    for end in ["\n", "\r\n"] {
        let (mut client, mut in_rx, mut out_rx, _out_tx, task) = reader(MAX);
        client.write_all(format!("{}{end}", "x".repeat(MAX + 1)).as_bytes()).await.unwrap();
        assert_eq!(in_rx.recv().await, None, "{end:?}");
        task.await.unwrap();
        let reply: serde_json::Value = serde_json::from_str(&out_rx.recv().await.unwrap()).unwrap();
        assert_eq!(reply["error"]["data"]["reason"], "message.too_large", "{end:?}: {reply}");
    }
}

/// A client too far behind to take the error still has its connection ended: the reader never
/// waits for room.
#[tokio::test]
async fn a_full_outbound_queue_does_not_keep_the_connection_open() {
    let (mut client, mut in_rx, _out_rx, out_tx, task) = reader_with_room(MAX, 1);
    out_tx.try_send("unread\n".to_owned()).unwrap();
    client.write_all(format!("{}\n", "x".repeat(MAX + 1)).as_bytes()).await.unwrap();
    tokio::time::timeout(std::time::Duration::from_secs(10), task)
        .await
        .expect("the reader waited for room")
        .unwrap();
    assert_eq!(in_rx.recv().await, None);
}
