//! Cold-connect bench for the acpmux peer stack: how many round trips one fresh `ws://` peer
//! link costs, and how long it takes at a 50 ms RTT.
//!
//! Hub A mirrors hub B (`add_peer(.., wait = true)`) through a delay proxy that holds every
//! chunk 25 ms each way and logs it (who sent what, when it would reach the other side). The
//! proxy cannot delay the kernel's TCP handshake, so one RTT for the SYN is added to the total
//! and shown as its own row. The log is the breakdown: each flight that waits on an answer is
//! one round trip.
//!
//! `cargo test -p acpmux --test acpmux_all peer_cold_connect_bench -- --ignored --nocapture`
//! Knobs: `COLD_RTT_MS` (default 50), `COLD_RUNS` (default 5), and `NO_EARLY` for the raw
//! listener compatibility check. Prints `COLDCONNECT {json}`.

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process =
    daemon_env::Process::deny().keep(&["COLD_RTT_MS", "COLD_RUNS", "NO_EARLY"]);

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{WsAuth, bind_ws, serve_ws_with};
use futures_util::{SinkExt, StreamExt};
use serde_json::json;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio_tungstenite::tungstenite::Message as WsFrame;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

fn hub() -> Arc<Hub> {
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

#[derive(Clone, Debug)]
struct Event {
    /// Milliseconds since the client's connect, when the chunk reaches its destination.
    at_ms: f64,
    down: bool,
    what: String,
}

fn describe(bytes: &[u8]) -> String {
    let text = String::from_utf8_lossy(bytes);
    if text.starts_with("GET ") {
        "HTTP upgrade request".into()
    } else if text.starts_with("HTTP/1.1 101") {
        "HTTP 101".into()
    } else {
        // A WebSocket frame: the JSON-RPC method or id is readable unmasked on the way down; up
        // frames are masked, so only their size is shown.
        let json = text.find('{').map(|i| text[i..].chars().take(60).collect::<String>());
        match json {
            Some(j) => format!("ws frame {} B {j}", bytes.len()),
            None => format!("ws frame {} B", bytes.len()),
        }
    }
}

/// A proxy to `upstream` holding each chunk `one_way` in each direction, logging arrivals.
async fn proxy(
    upstream: std::net::SocketAddr,
    one_way: Duration,
) -> (u16, Arc<Mutex<Vec<Event>>>, Arc<Mutex<Option<Instant>>>) {
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let log: Arc<Mutex<Vec<Event>>> = Arc::default();
    let t0: Arc<Mutex<Option<Instant>>> = Arc::default();
    let (log2, t02) = (log.clone(), t0.clone());
    tokio::spawn(async move {
        while let Ok((client, _)) = l.accept().await {
            t02.lock().unwrap().get_or_insert_with(Instant::now);
            let server = TcpStream::connect(upstream).await.unwrap();
            let (cr, cw) = client.into_split();
            let (sr, sw) = server.into_split();
            pump(cr, sw, false, one_way, log2.clone(), t02.clone());
            pump(sr, cw, true, one_way, log2.clone(), t02.clone());
        }
    });
    (port, log, t0)
}

/// Copy `reader` to `writer`, each chunk released `one_way` after it was read; log it on release.
fn pump(
    mut reader: tokio::net::tcp::OwnedReadHalf,
    mut writer: tokio::net::tcp::OwnedWriteHalf,
    down: bool,
    one_way: Duration,
    log: Arc<Mutex<Vec<Event>>>,
    t0: Arc<Mutex<Option<Instant>>>,
) {
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<(Instant, Vec<u8>)>();
    tokio::spawn(async move {
        let mut buf = vec![0u8; 65536];
        while let Ok(n) = reader.read(&mut buf).await {
            if n == 0 {
                break;
            }
            let _ = tx.send((Instant::now() + one_way, buf[..n].to_vec()));
        }
    });
    tokio::spawn(async move {
        while let Some((due, chunk)) = rx.recv().await {
            tokio::time::sleep_until(due.into()).await;
            let start = t0.lock().unwrap().unwrap();
            log.lock().unwrap().push(Event {
                at_ms: due.duration_since(start).as_secs_f64() * 1e3,
                down,
                what: describe(&chunk),
            });
            if writer.write_all(&chunk).await.is_err() {
                break;
            }
        }
    });
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "bench: run by hand"]
async fn cold_connect_round_trips() {
    let rtt: u64 = std::env::var("COLD_RTT_MS").ok().and_then(|v| v.parse().ok()).unwrap_or(50);
    let runs: usize = std::env::var("COLD_RUNS").ok().and_then(|v| v.parse().ok()).unwrap_or(5);
    let home = std::env::temp_dir().join(format!("cold-connect-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let auth = PeerAuth::create(&home).unwrap();
    let peer_token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&home)).unwrap();
    let b = hub();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let upstream = l.local_addr().unwrap();
    tokio::spawn(serve_ws_with(
        b,
        l,
        "tok".into(),
        WsAuth { local_app: None, peer: Some(Arc::new(auth)) },
    ));
    let mut totals = Vec::new();
    for run in 0..runs {
        let (port, log, t0) = proxy(upstream, Duration::from_millis(rtt / 2)).await;
        let a = hub();
        let started = Instant::now();
        a.add_peer(
            &format!("far{run}"),
            &format!("ws://127.0.0.1:{port}"),
            Some("tok".into()),
            Some(peer_token.clone()),
            true,
        )
        .await
        .unwrap();
        let ready = started.elapsed().as_secs_f64() * 1e3;
        let row = a.peers().into_iter().next().unwrap();
        assert_eq!(row["connected"], true, "the link must be up when add_peer returns: {row}");
        // The TCP handshake is the one round trip the proxy cannot shape.
        let total = ready + rtt as f64;
        totals.push(total);
        if run == 0 {
            let first = t0.lock().unwrap().unwrap();
            println!(
                "breakdown at {rtt} ms RTT (ms after the client's connect; +{rtt} ms TCP handshake not shaped):"
            );
            println!("  {:>7.1}  TCP SYN/SYN-ACK (modelled, 1 RTT = {rtt} ms)", 0.0);
            let _ = first;
            for e in log.lock().unwrap().iter() {
                println!(
                    "  {:>7.1}  {} {}",
                    e.at_ms + rtt as f64,
                    if e.down { "<-" } else { "->" },
                    e.what
                );
            }
            println!("  {:>7.1}  peer ready (add_peer wait)", total);
        }
        println!(
            "COLDCONNECT {{\"rtt_ms\":{rtt},\"run\":{run},\"total_ms\":{total:.1},\"round_trips\":{:.2}}}",
            total / rtt as f64
        );
    }
    totals.sort_by(f64::total_cmp);
    let percentile = |percent: usize| {
        let rank = (totals.len() * percent).div_ceil(100).saturating_sub(1);
        totals.get(rank).copied().unwrap_or_default()
    };
    let p50 = percentile(50);
    let p95 = percentile(95);
    println!(
        "COLDCONNECT summary {{\"p50_ms\":{p50:.1},\"p95_ms\":{p95:.1},\"p50_rtt\":{:.2},\"p95_rtt\":{:.2},\"runs\":{runs},\"rtt_ms\":{rtt}}}",
        p50 / rtt as f64,
        p95 / rtt as f64
    );
}

/// What the listener does with an `initialize` frame written right behind the upgrade request:
/// it must answer 101 and then the frame, in that order.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_listener_answers_an_initialize_sent_with_the_upgrade() {
    let _ = tracing_subscriber::fmt().with_env_filter("warn").with_test_writer().try_init();
    let home = std::env::temp_dir().join(format!("cold-early-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let auth = PeerAuth::create(&home).unwrap();
    let peer_token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&home)).unwrap();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let addr = l.local_addr().unwrap();
    tokio::spawn(serve_ws_with(
        hub(),
        l,
        "tok".into(),
        WsAuth { local_app: None, peer: Some(Arc::new(auth)) },
    ));
    let mut s = TcpStream::connect(addr).await.unwrap();
    // The request tungstenite's client writes, captured instead of hand-rolled.
    let request = {
        use tokio_tungstenite::tungstenite::client::IntoClientRequest;
        let mut req = format!("ws://{addr}/").into_client_request().unwrap();
        req.headers_mut().insert("authorization", "Bearer tok".parse().unwrap());
        req.headers_mut()
            .insert(acpmux::server::peer_auth::HEADER, peer_token.trim().parse().unwrap());
        let (near, mut far) = tokio::io::duplex(8192);
        tokio::spawn(async move {
            let _ = tokio_tungstenite::client_async(req, near).await;
        });
        let mut head = Vec::new();
        let mut byte = [0u8; 1];
        while !head.ends_with(b"\r\n\r\n") {
            far.read_exact(&mut byte).await.unwrap();
            head.push(byte[0]);
        }
        String::from_utf8(head).unwrap()
    };
    let line = r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}"#;
    let mut bytes = request.clone().into_bytes();
    if std::env::var_os("NO_EARLY").is_none() {
        bytes.extend(acpmux::peer_link::masked_text_frame(line.as_bytes()));
    }
    s.write_all(&bytes).await.unwrap();
    let mut got = Vec::new();
    let mut buf = [0u8; 8192];
    let read = async {
        loop {
            let n = s.read(&mut buf).await.unwrap();
            if n == 0 {
                break;
            }
            got.extend_from_slice(&buf[..n]);
            if String::from_utf8_lossy(&got).contains("\"id\":1") {
                break;
            }
        }
    };
    let _ = tokio::time::timeout(Duration::from_secs(5), read).await;
    let text = String::from_utf8_lossy(&got);
    assert!(text.starts_with("HTTP/1.1 101"), "reply {} B: {text}\nrequest:\n{request}", got.len());
    assert!(text.contains("\"id\":1"), "no answer behind the 101: {text}");
}

/// A listener from before early initialize used tungstenite directly. It rejects the first
/// upgrade when the client writes a frame behind it, then accepts the retry without those bytes.
async fn old_listener() -> (u16, Arc<Mutex<Vec<String>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let attempts = Arc::new(Mutex::new(Vec::new()));
    let seen = attempts.clone();
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            match tokio_tungstenite::accept_async(stream).await {
                Err(error) => {
                    seen.lock().unwrap().push(format!("rejected: {error}"));
                }
                Ok(mut ws) => {
                    seen.lock().unwrap().push("accepted".into());
                    while let Some(Ok(frame)) = ws.next().await {
                        let WsFrame::Text(text) = frame else { continue };
                        let Ok(Message::Request { id, method: m, .. }) = Message::parse(&text)
                        else {
                            continue;
                        };
                        let result = match m.as_str() {
                            method::INITIALIZE => json!({
                                "protocolVersion": 1,
                                "_meta": {"acpmux": {"build": "old", "origin": "peer", "features": []}}
                            }),
                            method::MUX_WATCH => json!({"sessions": []}),
                            _ => json!({}),
                        };
                        let line = Message::ok(id, result).to_line();
                        if ws.send(WsFrame::Text(line.trim_end().to_owned().into())).await.is_err()
                        {
                            break;
                        }
                    }
                    break;
                }
            }
        }
    });
    (port, attempts)
}

/// A new client retries an old tungstenite listener after its early frame is rejected. The
/// successful second upgrade has no frame behind the request, so its first frame is initialize.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_new_client_falls_back_to_an_old_listener_without_early_bytes_on_retry() {
    let (port, attempts) = old_listener().await;
    let a = hub();
    a.add_peer("old-listener", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), None, true)
        .await
        .unwrap();
    let attempts = attempts.lock().unwrap().clone();
    assert_eq!(attempts.len(), 2, "one rejected early attempt and one retry: {attempts:?}");
    assert!(
        attempts[0].starts_with("rejected:"),
        "old listener accepted early bytes: {attempts:?}"
    );
    assert_eq!(attempts[1], "accepted", "the retry must upgrade without early bytes: {attempts:?}");
    assert_eq!(a.peers()[0]["connected"], true, "{attempts:?}");
}

/// An old client that waits for the upgrade before sending initialize remains compatible with
/// the new listener. This is the other half of the lockstep pair.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_old_client_without_early_bytes_connects_to_a_new_listener() {
    let home = std::env::temp_dir().join(format!("cold-old-client-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let auth = PeerAuth::create(&home).unwrap();
    let peer_token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&home)).unwrap();
    let listener = bind_ws("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(serve_ws_with(
        hub(),
        listener,
        "tok".into(),
        WsAuth { local_app: None, peer: Some(Arc::new(auth)) },
    ));

    let mut request = format!("ws://{addr}/").into_client_request().unwrap();
    request.headers_mut().insert("authorization", "Bearer tok".parse().unwrap());
    request
        .headers_mut()
        .insert(acpmux::server::peer_auth::HEADER, peer_token.trim().parse().unwrap());
    let (mut ws, _) = tokio_tungstenite::connect_async(request).await.unwrap();
    let initialize = Message::request(
        1,
        method::INITIALIZE,
        json!({"protocolVersion": 1, "clientInfo": {"name": "old-peer"}}),
    )
    .to_line();
    ws.send(WsFrame::Text(initialize.trim_end().to_owned().into())).await.unwrap();
    let response = loop {
        let frame = tokio::time::timeout(Duration::from_secs(5), ws.next())
            .await
            .expect("new listener did not answer old client")
            .expect("new listener closed")
            .unwrap();
        let WsFrame::Text(text) = frame else { continue };
        let message = Message::parse(&text).unwrap();
        if matches!(&message, Message::Response { id, .. } if *id == 1) {
            break message;
        }
    };
    match response {
        Message::Response { result: Some(result), error: None, .. } => {
            assert_eq!(result["protocolVersion"], 1, "{result}");
        }
        other => panic!("old client initialize failed: {other:?}"),
    }
}
