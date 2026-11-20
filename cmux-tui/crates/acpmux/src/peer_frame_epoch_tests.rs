use super::*;
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::{Message as Frame, protocol::Role};

/// A frame admitted on a link that went down is dropped when `serve` dequeues it, even
/// when its sender woke only after the next link opened; one admitted on the live link
/// goes out.
#[tokio::test]
async fn a_frame_tagged_with_an_ended_link_never_goes_out_on_the_next() {
    let (tx, _rx) = mpsc::channel(8);
    let peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
    let stale = peer.link_epoch();
    peer.link_ended();
    let frame = |epoch, line: &str| Outbound { epoch, key: None, line: line.to_owned() };
    peer.out.send(frame(stale, r#"{"jsonrpc":"2.0","method":"stale"}"#)).await.unwrap();
    let live = peer.link_epoch();
    peer.out.send(frame(live, r#"{"jsonrpc":"2.0","method":"live"}"#)).await.unwrap();

    let (ours, theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let mut server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let link = peer.clone();
    let serving = tokio::spawn(async move { link.serve(client, &mut out_rx).await });

    let mut seen = Vec::new();
    while !seen.iter().any(|t: &String| t.contains("\"live\"")) {
        let frame = tokio::time::timeout(Duration::from_secs(5), server.next())
            .await
            .expect("the live frame goes out")
            .expect("the link stays open")
            .unwrap();
        if let Frame::Text(text) = frame {
            seen.push(text.to_string());
        }
    }
    assert!(!seen.iter().any(|t| t.contains("\"stale\"")), "a stale frame went out: {seen:?}");
    serving.abort();
}

/// Review of #24797 at f2e68a4: a peer's request was refused with a send that had no time
/// limit, so a peer that asks and never reads held the link's loop, pings and all, for good.
#[tokio::test]
async fn a_peer_that_asks_and_never_reads_loses_the_link() {
    let (tx, _rx) = mpsc::channel(8);
    let mut peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
    let timings = &mut Arc::get_mut(&mut peer).expect("only this test holds it").timings;
    timings.ping_every = Duration::from_millis(200);
    timings.ping_misses = 2;
    timings.send = Duration::from_millis(400);
    let (ours, theirs) = tokio::io::duplex(1024);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let mut server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let link = peer.clone();
    let serving = tokio::spawn(async move { link.serve(client, &mut out_rx).await });
    let asking = tokio::spawn(async move {
        for i in 0u64.. {
            let ask = Message::request(json!(i), method::MUX_GITHUB_ACTION, json!({})).to_line();
            if server.send(Frame::Text(ask.trim_end().to_owned().into())).await.is_err() {
                break;
            }
        }
    });
    let ended = tokio::time::timeout(Duration::from_secs(10), serving)
        .await
        .expect("the link ends instead of hanging");
    assert!(ended.unwrap().is_err());
    asking.abort();
}
