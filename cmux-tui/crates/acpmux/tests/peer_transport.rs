//! PEER-ORIGIN-TRANSPORT, client side: a daemon never sends its peer's peer
//! token over plain `ws://` to a host that is not loopback; it connects
//! without it (and is served as Web), and its peer listing says so.

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const PEER_TOKEN: &str = "abababababababababababababababababababababababababababababababab";

/// A listener on every address that records each request head and
/// refuses it.
async fn recorder() -> (u16, Arc<Mutex<Vec<String>>>) {
    let l = tokio::net::TcpListener::bind("0.0.0.0:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let heads: Arc<Mutex<Vec<String>>> = Arc::default();
    let seen = heads.clone();
    tokio::spawn(async move {
        while let Ok((mut s, _)) = l.accept().await {
            let mut buf = vec![0u8; 8192];
            let mut n = 0;
            while n < buf.len() {
                match s.read(&mut buf[n..]).await {
                    Ok(0) | Err(_) => break,
                    Ok(k) => n += k,
                }
                if buf[..n].windows(4).any(|w| w == b"\r\n\r\n") {
                    break;
                }
            }
            seen.lock().unwrap().push(String::from_utf8_lossy(&buf[..n]).to_lowercase());
            let _ = s.write_all(b"HTTP/1.1 403 Forbidden\r\ncontent-length: 0\r\n\r\n").await;
        }
    });
    (port, heads)
}

/// This machine's address on its default route, without sending a packet.
fn own_address() -> Option<std::net::IpAddr> {
    let s = std::net::UdpSocket::bind("0.0.0.0:0").ok()?;
    s.connect("192.0.2.1:9").ok()?;
    let ip = s.local_addr().ok()?.ip();
    (!ip.is_loopback() && !ip.is_unspecified()).then_some(ip)
}

fn hub() -> Arc<Hub> {
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

#[tokio::test]
async fn the_peer_token_never_crosses_plain_ws_to_a_host_that_is_not_loopback() {
    let Some(ip) = own_address() else {
        assert!(std::env::var_os("CI").is_none(), "CI needs a non-loopback address");
        eprintln!("skipped: this machine has no non-loopback address");
        return;
    };
    let (port, heads) = recorder().await;
    let a = hub();
    // A plain ws:// peer on another address: no peer token on the wire.
    let far = format!("ws://{ip}:{port}/");
    a.add_peer("far", &far, Some("tok".into()), Some(PEER_TOKEN.into()), true).await.unwrap();
    let far_heads: Vec<String> = heads.lock().unwrap().drain(..).collect();
    assert!(!far_heads.is_empty(), "the peer connected");
    for h in &far_heads {
        assert!(h.contains("authorization: bearer tok"), "{h}");
        assert!(!h.contains("x-acpmux-peer-token"), "the peer token crossed: {h}");
        assert!(!h.contains(PEER_TOKEN), "{h}");
    }
    let listing = a.peers();
    assert_eq!(listing[0]["peerTokenWithheld"], true, "{listing:?}");
    // The same listener on loopback: the token goes.
    a.add_peer(
        "near",
        &format!("ws://127.0.0.1:{port}/"),
        Some("tok".into()),
        Some(PEER_TOKEN.into()),
        true,
    )
    .await
    .unwrap();
    let near_heads: Vec<String> = heads.lock().unwrap().drain(..).collect();
    assert!(
        near_heads.iter().any(|h| h.contains(&format!("x-acpmux-peer-token: {PEER_TOKEN}"))),
        "{near_heads:?}"
    );
}
