use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::Message as Frame;
use tokio_tungstenite::tungstenite::protocol::Role;

use super::{READ_AHEAD_FRAMES, read_ahead};

/// A dialer and the listener's side of one WebSocket.
async fn pair()
-> (WebSocketStream<tokio::io::DuplexStream>, WebSocketStream<tokio::io::DuplexStream>) {
    let (ours, theirs) = tokio::io::duplex(4 * 1024 * 1024);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
    (client, server)
}

/// RFD 0050 rule 3: a ping sent behind bulk frames the connection has not taken yet is answered
/// while they wait, and the frames still arrive whole and in order.
#[tokio::test]
async fn a_ping_behind_queued_bulk_frames_is_answered_while_they_wait() {
    let (mut client, server) = pair().await;
    let (_sink, source) = server.split();
    // The connection takes nothing until told to: every frame's hand-off waits.
    let (open_tx, open_rx) = tokio::sync::watch::channel(false);
    let (got_tx, mut got_rx) = tokio::sync::mpsc::unbounded_channel::<String>();
    let reader = tokio::spawn(async move {
        read_ahead(source, |frame| {
            let (mut open, got_tx) = (open_rx.clone(), got_tx.clone());
            async move {
                let _ = open.wait_for(|open| *open).await;
                if let Frame::Text(t) = frame {
                    let _ = got_tx.send(t.to_string());
                }
                true
            }
        })
        .await
    });
    let bulk = "x".repeat(16 * 1024);
    for n in 0..20 {
        client.send(Frame::Text(format!("{n}:{bulk}").into())).await.unwrap();
    }
    client.send(Frame::Ping(b"alive?".to_vec().into())).await.unwrap();
    let pong = tokio::time::timeout(Duration::from_secs(5), client.next())
        .await
        .expect("the ping behind 20 queued bulk frames went unanswered")
        .unwrap()
        .unwrap();
    assert_eq!(pong, Frame::Pong(b"alive?".to_vec().into()));
    assert!(got_rx.try_recv().is_err(), "no bulk frame was taken yet");

    open_tx.send(true).unwrap();
    for n in 0..20 {
        let line =
            tokio::time::timeout(Duration::from_secs(5), got_rx.recv()).await.unwrap().unwrap();
        assert_eq!(line, format!("{n}:{bulk}"), "in order, whole");
    }
    // A dialer gone without a close ends the read with its error.
    drop(client);
    let ended = tokio::time::timeout(Duration::from_secs(5), reader).await.unwrap().unwrap();
    assert!(ended.is_some(), "a reset is an error the caller logs");
}

/// Past its bound the reader stops, so a connection that takes nothing holds a bounded backlog
/// and the sender meets backpressure, as before.
#[tokio::test]
async fn the_read_ahead_stops_at_its_bound() {
    let (mut client, server) = pair().await;
    let (_sink, source) = server.split();
    let (read_tx, mut read_rx) = tokio::sync::mpsc::unbounded_channel::<()>();
    let counted = source.inspect(move |_| {
        let _ = read_tx.send(());
    });
    tokio::spawn(read_ahead(counted, |_| std::future::pending::<bool>()));
    for n in 0..READ_AHEAD_FRAMES + 50 {
        client.send(Frame::Text(n.to_string().into())).await.unwrap();
    }
    tokio::time::sleep(Duration::from_millis(200)).await;
    let mut read = 0;
    while read_rx.try_recv().is_ok() {
        read += 1;
    }
    // The one being handed off, plus the held frames.
    assert_eq!(read, READ_AHEAD_FRAMES + 1);
}

/// A connection that takes no more ends the read at once.
#[tokio::test]
async fn a_refused_frame_ends_the_read() {
    let (mut client, server) = pair().await;
    let (_sink, source) = server.split();
    client.send(Frame::Text("first".into())).await.unwrap();
    let ended =
        tokio::time::timeout(Duration::from_secs(5), read_ahead(source, |_| async { false }))
            .await
            .expect("the read did not end when the connection refused a frame");
    assert!(ended.is_none());
}
