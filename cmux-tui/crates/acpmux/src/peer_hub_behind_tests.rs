//! A hub that is behind on its notices holds up no link (`peer_notice_outbox.rs`): every link
//! keeps reading its peer's frames and writing its pings while the hub takes nothing at all.
//! Each link used to await the hub's one shared queue inside its serve loop, so a full queue
//! stopped every link's reads and pings together.

use super::*;
use futures_util::{SinkExt, StreamExt};
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::Message as Frame;
use tokio_tungstenite::tungstenite::protocol::Role;

const LINKS: usize = 4;

#[tokio::test(start_paused = true)]
async fn links_keep_pinging_while_the_hub_takes_no_notice() {
    // The hub's queue, never read: held from applying anything for the whole test.
    let (hub, _held) = mpsc::channel(16);
    let mut serving = Vec::new();
    let mut pings = Vec::new();
    let mut floods = Vec::new();
    for n in 0..LINKS {
        let mut peer = Peer::new(&format!("p{n}"), "ws://127.0.0.1:9", None, None, hub.clone());
        // No handshake here: the stand-in only floods and answers.
        Arc::get_mut(&mut peer).expect("only this test holds it").timings.handshake =
            Duration::from_secs(3_600);
        let ping_every = peer.timings.ping_every;
        let (ours, theirs) = tokio::io::duplex(1 << 16);
        let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
        let server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
        let (mut write, mut read) = server.split();
        let (seen_tx, seen) = mpsc::unbounded_channel();
        // The peer: counts each ping the link writes (tungstenite answers it with a pong).
        pings.push((seen, ping_every));
        tokio::spawn(async move {
            while let Some(Ok(frame)) = read.next().await {
                if matches!(frame, Frame::Ping(_)) && seen_tx.send(()).is_err() {
                    return;
                }
            }
        });
        // ... and sends its rows' changes, far faster than a held hub takes them.
        floods.push(tokio::spawn(async move {
            let mut seq = 0_u64;
            loop {
                for _ in 0..50 {
                    seq += 1;
                    let line = serde_json::json!({
                        "jsonrpc": "2.0",
                        "method": method::MUX_SESSION_CHANGED,
                        "params": {
                            "session": {"sessionId": format!("s{}", seq % 3), "state": "running"},
                            "kind": "status",
                            "seq": seq,
                        },
                    });
                    if write.send(Frame::Text(line.to_string().into())).await.is_err() {
                        return;
                    }
                }
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        }));
        let mut out_rx = peer.out_rx.lock().await.take().unwrap();
        let link = peer.clone();
        serving.push(tokio::spawn(async move { link.serve(client, &mut out_rx).await }));
    }
    // Twenty ping intervals: each link writes every ping, in order, and stays up.
    let rounds = 20;
    for round in 1..=rounds {
        for (n, (seen, ping_every)) in pings.iter_mut().enumerate() {
            tokio::time::timeout(*ping_every * 2, seen.recv())
                .await
                .unwrap_or_else(|_| panic!("link {n} missed ping {round} while the hub was held"))
                .expect("the peer reads on");
        }
    }
    for (n, link) in serving.iter().enumerate() {
        assert!(!link.is_finished(), "link {n} stayed up");
    }
    serving.iter().for_each(tokio::task::JoinHandle::abort);
    floods.iter().for_each(tokio::task::JoinHandle::abort);
}
