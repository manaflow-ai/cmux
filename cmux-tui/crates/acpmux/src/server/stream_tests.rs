//! The socket reader's bounds and the writer's end (`stream.rs`, manaflow-ai/cmuxterm-hq#2888).

use super::{Limits, read_lines, v2_upgrade, write_lines};
use acpmux_book::index::SummaryIndex;
use acpmux_core::life::V2;
use serde_json::json;
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
    let task = tokio::spawn(async move {
        read_lines(server, in_tx, last_tx, LIMITS, None).await;
    });
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

/// The Cloud carrier's header names a person on the carrier socket only (`carrier.rs`): an HTTP
/// upgrade that carries it on the daemon's own socket ends the connection, and nothing it sent
/// reaches the server, the JSON-RPC line after it included.
#[tokio::test]
async fn an_http_upgrade_with_the_carrier_header_ends_the_connection() {
    let (mut client, mut in_rx, last, task) = reader(256);
    let head = concat!(
        "GET / HTTP/1.1\r\n",
        "Host: carrier\r\n",
        "Upgrade: websocket\r\n",
        "Connection: Upgrade\r\n",
        "x-acpmux-carrier: {\"vmk\":\"owner\",\"sub\":\"u\",\"team\":\"t\"}\r\n",
        "\r\n",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}\n",
    );
    client.write_all(head.as_bytes()).await.unwrap();
    assert_eq!(in_rx.recv().await, None);
    task.await.unwrap();
    let reply: serde_json::Value =
        serde_json::from_str(&last.await.expect("an error before the connection ends")).unwrap();
    assert_eq!(reply["error"]["data"]["reason"], "carrier.wrong_socket", "{reply}");
    // A JSON-RPC first line is no HTTP request.
    for line in ["{\"jsonrpc\":\"2.0\"}", "GET", "get / HTTP/1.1", "GET / HTTP/1.1 x"] {
        assert!(!super::http_request_line(line), "{line}");
    }
    assert!(super::http_request_line("POST /x HTTP/1.0\r"));
}

#[test]
fn v2_upgrade_requires_every_requested_surface() {
    let (hub, writer) = acpmux_core::hub::Hub::new(SummaryIndex::new());
    let v2 = V2::with_surfaces(hub, writer, ["list".to_owned()].into_iter().collect());
    let line = serde_json::to_string(&json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "_acpmux/v2",
        "params": {"protocol": 2, "surfaces": ["list"]}
    }))
    .unwrap();
    assert!(v2_upgrade(&line, &v2).is_some());
    let line = serde_json::to_string(&json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "_acpmux/v2",
        "params": {"protocol": 2, "surfaces": ["list", "chat"]}
    }))
    .unwrap();
    assert!(v2_upgrade(&line, &v2).is_none());
}

fn upgrade_line(surfaces: serde_json::Value) -> String {
    crate::rpc::Message::request(1, "_acpmux/v2", json!({"protocol": 2, "surfaces": surfaces}))
        .to_line()
}

#[test]
fn upgrade_rejects_malformed_or_non_stream_surfaces() {
    let (hub, writer) = acpmux_core::hub::Hub::new(SummaryIndex::new());
    let v2 = V2::with_surfaces(hub, writer, ["list".into(), "books".into()].into_iter().collect());
    for surfaces in [json!([]), json!(["list", 2]), json!(["books"]), json!("list")] {
        assert!(v2_upgrade(&upgrade_line(surfaces), &v2).is_none());
    }
}

#[tokio::test]
async fn upgrade_is_only_the_first_line_and_preserves_v1_eof() {
    let (hub, writer) = acpmux_core::hub::Hub::new(SummaryIndex::new());
    let v2 = V2::new(hub, writer);
    let (mut client, server) = tokio::io::duplex(4 * MAX);
    let (tx, mut rx) = mpsc::channel(16);
    let (last, _last_rx) = oneshot::channel();
    let upgrade = upgrade_line(json!(["list"]));
    client.write_all(format!("{{}}\n{upgrade}tail").as_bytes()).await.unwrap();
    client.shutdown().await.unwrap();
    assert!(read_lines(server, tx, last, LIMITS, Some(&v2)).await.is_none());
    assert_eq!(rx.recv().await.as_deref(), Some("{}"));
    assert_eq!(rx.recv().await.as_deref(), Some(upgrade.trim_end()));
    assert_eq!(rx.recv().await.as_deref(), Some("tail"));
}

#[tokio::test]
async fn enabled_upgrade_keeps_http_and_oversize_first_line_errors() {
    for (line, reason) in [
        ("GET / HTTP/1.1\r\n".into(), "carrier.wrong_socket"),
        (format!("{}\n", "x".repeat(MAX + 1)), "message.too_large"),
    ] {
        let (hub, writer) = acpmux_core::hub::Hub::new(SummaryIndex::new());
        let v2 = V2::new(hub, writer);
        let (mut client, server) = tokio::io::duplex(4 * MAX);
        let (tx, mut rx) = mpsc::channel(16);
        let (last, last_rx) = oneshot::channel();
        client.write_all(line.as_bytes()).await.unwrap();
        assert!(read_lines(server, tx, last, LIMITS, Some(&v2)).await.is_none());
        assert!(rx.recv().await.is_none());
        let reply: serde_json::Value = serde_json::from_str(&last_rx.await.unwrap()).unwrap();
        assert_eq!(
            reply.pointer("/error/data/reason").and_then(serde_json::Value::as_str),
            Some(reason)
        );
    }
}

async fn v2_frame(reader: &mut (impl tokio::io::AsyncRead + Unpin)) -> acpmux_core::wire::Frame {
    let mut header = [0; 4];
    reader.read_exact(&mut header).await.unwrap();
    let mut bytes = vec![0; u32::from_be_bytes(header) as usize];
    reader.read_exact(&mut bytes).await.unwrap();
    let mut encoded = header.to_vec();
    encoded.extend(bytes);
    acpmux_core::wire::Frame::from_encoded(&encoded).unwrap()
}

#[tokio::test]
async fn upgrade_read_ahead_reaches_hello_then_list_window() {
    use acpmux_core::wire::{Frame, FrameKind};
    tokio::time::timeout(WAIT, async {
        let (hub, writer) = acpmux_core::hub::Hub::new(SummaryIndex::new());
        let v2 = V2::new(hub, writer);
        let (mut client, server) = tokio::io::duplex(8192);
        let (rd, wr) = tokio::io::split(server);
        let (tx, _rx) = mpsc::channel(16);
        let (last, _last_rx) = oneshot::channel();
        let task = tokio::spawn(async move {
            let upgrade = read_lines(rd, tx, last, LIMITS, Some(&v2)).await.unwrap();
            upgrade.serve(wr, &v2, "test".into()).await.unwrap();
        });
        let hello = Frame::json(
            FrameKind::Request,
            &json!({
                "method":"hello", "params":{"clientKind":"test", "protocol":2}
            }),
        )
        .unwrap();
        let mut combined = upgrade_line(json!(["list"])).into_bytes();
        combined.extend(hello.encode());
        client.write_all(&combined).await.unwrap();
        let mut reply = Vec::new();
        loop {
            let byte = client.read_u8().await.unwrap();
            if byte == b'\n' {
                break;
            }
            reply.push(byte);
        }
        let reply: serde_json::Value = serde_json::from_slice(&reply).unwrap();
        assert_eq!(reply.pointer("/result/upgrade"), Some(&json!(true)));
        assert_eq!(v2_frame(&mut client).await.kind, FrameKind::Hello);
        let sub = Frame::json(
            FrameKind::Request,
            &json!({
                "method":"sub", "params":{"sid":"s", "stream":"list"}
            }),
        )
        .unwrap();
        client.write_all(&sub.encode()).await.unwrap();
        let window = v2_frame(&mut client).await;
        assert_eq!(window.kind, FrameKind::Window);
        assert_eq!(
            window.decode_json::<serde_json::Value>().unwrap().get("sid"),
            Some(&json!("s"))
        );
        drop(client);
        task.await.unwrap();
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn trigger_admission_cannot_be_followed_by_an_upgrade() {
    let (hub, writer) = acpmux_core::hub::Hub::new(SummaryIndex::new());
    let v2 = V2::new(hub, writer);
    let (mut client, server) = tokio::io::duplex(4 * MAX);
    let (tx, mut rx) = mpsc::channel(16);
    let (last, _last_rx) = oneshot::channel();
    let trigger = crate::rpc::Message::request(1, "trigger/chat.ensure", json!({})).to_line();
    let upgrade = upgrade_line(json!(["list"]));
    client.write_all(format!("{trigger}{upgrade}").as_bytes()).await.unwrap();
    client.shutdown().await.unwrap();
    assert!(read_lines(server, tx, last, LIMITS, Some(&v2)).await.is_none());
    assert_eq!(rx.recv().await.as_deref(), Some(trigger.trim_end()));
    assert_eq!(rx.recv().await.as_deref(), Some(upgrade.trim_end()));
}

#[test]
fn upgrade_canonicalizes_repeated_surfaces() {
    let (hub, writer) = acpmux_core::hub::Hub::new(acpmux_book::index::SummaryIndex::new());
    let v2 = V2::with_surfaces(hub, writer, ["list".into(), "chat".into()].into_iter().collect());
    let (_, surfaces) =
        v2_upgrade(&upgrade_line(json!(["chat", "list", "chat", "list"])), &v2).unwrap();
    assert_eq!(surfaces, ["list", "chat"]);
}

#[cfg(unix)]
#[tokio::test]
async fn hello_run_id_matches_status_on_a_second_connection() {
    use acpmux_core::wire::{Frame, FrameKind, HelloReply};
    use std::sync::Arc;
    use tokio::io::AsyncBufReadExt;
    tokio::time::timeout(WAIT, async {
        let mut config = crate::config::Config::default();
        config.store.mode = crate::config::StoreMode::Memory;
        let store =
            crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
        let hub = crate::hub::Hub::new(config, store);
        let (list, writer) = acpmux_core::hub::Hub::new(SummaryIndex::new());
        let v2 = Arc::new(V2::new(list, writer));
        let (mut client, server) = tokio::net::UnixStream::pair().unwrap();
        let upgraded = tokio::spawn(super::serve_stream(
            hub.clone(),
            server,
            None,
            false,
            crate::sender_harness::SocketPeer::Unknown,
            Some(v2),
        ));
        let hello = Frame::json(
            FrameKind::Request,
            &json!({
                "method":"hello", "params":{"clientKind":"test", "protocol":2}
            }),
        )
        .unwrap();
        let mut combined = upgrade_line(json!(["list"])).into_bytes();
        combined.extend(hello.encode());
        client.write_all(&combined).await.unwrap();
        // Keep any read-ahead in this reader: it includes hello's framed reply.
        let mut client = tokio::io::BufReader::new(client);
        let mut line = String::new();
        client.read_line(&mut line).await.unwrap();
        let reply: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(reply.pointer("/result/upgrade"), Some(&json!(true)));
        let frame = v2_frame(&mut client).await;
        assert_eq!(frame.kind, FrameKind::Hello);
        let hello: HelloReply = frame.decode_json().unwrap();

        let (mut status_client, server) = tokio::net::UnixStream::pair().unwrap();
        let status_task = tokio::spawn(super::serve_stream(
            hub.clone(),
            server,
            None,
            false,
            crate::sender_harness::SocketPeer::Unknown,
            None,
        ));
        status_client
            .write_all(
                crate::rpc::Message::request(1, crate::rpc::method::MUX_STATUS, json!({}))
                    .to_line()
                    .as_bytes(),
            )
            .await
            .unwrap();
        let mut status_client = tokio::io::BufReader::new(status_client);
        let status = loop {
            line.clear();
            assert_ne!(status_client.read_line(&mut line).await.unwrap(), 0);
            let reply: serde_json::Value = serde_json::from_str(&line).unwrap();
            if reply.get("id") == Some(&json!(1)) {
                break reply;
            }
        };
        assert_eq!(status.pointer("/result/personInstance"), Some(&json!(hello.daemon_id)));
        assert_eq!(hello.daemon_id, hub.run_id());
        drop(client);
        drop(status_client);
        upgraded.await.unwrap();
        status_task.await.unwrap();
    })
    .await
    .unwrap();
}
