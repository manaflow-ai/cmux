use super::*;
use crate::config::{Config, StoreMode};
use futures_util::{SinkExt, StreamExt};
use serde_json::json;
use tokio_tungstenite::tungstenite::Message as Frame;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

const TOKEN: &str = "0123456789abcdef";

fn stamped(id: &str) -> Value {
    json!({"_meta": {"acpmux": {"dualId": id}}})
}

fn seen(principal: &str, id: &str) -> (Key, u64) {
    key_for(Some(principal), crate::rpc::method::MUX_STATS, Some(&stamped(id))).unwrap()
}

#[tokio::test]
async fn the_second_copy_answers_with_the_first_ones_answer() {
    let id = format!("book-{}", uuid::Uuid::now_v7());
    let Some(Seen::First(first)) = admit(seen(PEER_LINK, &id)) else { panic!("it runs") };
    let Some(Seen::Repeat(repeat)) = admit(seen(PEER_LINK, &id)) else { panic!("it waits") };
    let waiting = tokio::spawn(first_answer(repeat));
    first.finish(Outcome::Answer(Ok(json!({"ran": 1}))));
    assert_eq!(waiting.await.unwrap(), Some(Ok(json!({"ran": 1}))));
    // A third copy, after the answer, gets it at once.
    let Some(Seen::Repeat(late)) = admit(seen(PEER_LINK, &id)) else { panic!("known") };
    assert_eq!(first_answer(late).await, Some(Ok(json!({"ran": 1}))));
}

#[test]
fn a_notification_sent_twice_is_taken_once() {
    let id = format!("note-{}", uuid::Uuid::now_v7());
    assert!(first_notification(seen(PEER_LINK, &id)));
    assert!(!first_notification(seen(PEER_LINK, &id)));
}

/// One `dualId` from two principals is two entries: neither is served the other's answer.
/// The same principal and id on another request is no repeat either: it runs.
#[test]
fn the_same_dual_id_from_another_principal_or_request_is_not_a_repeat() {
    let id = format!("who-{}", uuid::Uuid::now_v7());
    assert!(matches!(admit(seen("a", &id)), Some(Seen::First(_))));
    assert!(matches!(admit(seen("b", &id)), Some(Seen::First(_))));
    assert!(matches!(admit(seen("a", &id)), Some(Seen::Repeat(_))));
    let other = key_for(Some("a"), crate::rpc::method::MUX_WAIT, Some(&stamped(&id)));
    assert!(admit(other.unwrap()).is_none(), "another request under a known key runs");
    // A connection with no principal (the Web, a paired machine) uses no book at all.
    assert!(key_for(None, crate::rpc::method::MUX_STATS, Some(&stamped(&id))).is_none());
}

/// What a request carries decides, not only its method: one bound to its connection, or
/// forwarded for another client, is never deduplicated (nor copied, `peer_dual.rs`).
#[test]
fn a_request_bound_to_its_connection_takes_no_dual_id() {
    use crate::rpc::method;
    let id = json!({"dualId": "n:1:1"});
    let prompt = json!({"sessionId": "s", "_meta": {"acpmux": id}});
    assert!(dual_safe(method::SESSION_PROMPT, &prompt));
    let meta = |extra: Value| {
        let mut mux = id.clone();
        if let (Some(mux), Some(extra)) = (mux.as_object_mut(), extra.as_object()) {
            mux.extend(extra.clone());
        }
        json!({"sessionId": "s", "_meta": {"acpmux": mux}})
    };
    let cloud = json!({"sessionId": "s", "cloud_turn": {"purpose": "execute"},
            "_meta": {"acpmux": id}});
    for (m, params) in [
        (method::SESSION_PROMPT, cloud),
        (method::SESSION_PROMPT, meta(json!({"readsReply": true}))),
        (method::SESSION_PROMPT, meta(json!({"via": "web"}))),
        (method::SESSION_CANCEL, meta(json!({"via": "device"}))),
        (method::SESSION_LOAD, prompt.clone()),
        (method::SESSION_RESUME, prompt.clone()),
        (method::MUX_ATTACH, prompt.clone()),
    ] {
        assert!(!dual_safe(m, &params), "{m} {params}");
        assert!(key_for(Some(PEER_LINK), m, Some(&params)).is_none(), "{m} {params}");
    }
}

#[test]
fn a_long_or_missing_key_is_no_key() {
    assert_eq!(
        key_of(Some(&json!({"_meta": {"acpmux": {"dualId": "a:1:2"}}}))),
        Some("a:1:2".into())
    );
    assert_eq!(
        key_of(Some(&json!({"_meta": {"acpmux": {"dualId": "x".repeat(MAX_KEY + 1)}}}))),
        None
    );
    assert_eq!(key_of(Some(&json!({}))), None);
    assert_eq!(key_of(None), None);
}

#[test]
fn the_book_stays_bounded_and_forgets_old_answers() {
    let mut book = Book::default();
    let now = Instant::now();
    let key = |n: &str| (PEER_LINK.to_owned(), n.to_owned());
    for n in 0..MOST + 50 {
        let _first = book.admit(key(&format!("bound-{n}")), 0, now);
    }
    assert_eq!(book.entries.len(), MOST + 1, "the oldest go first");
    assert!(!book.entries.contains_key(&key("bound-0")));
    // Answered keys go once they are older than KEEP_FOR.
    for entry in book.entries.values_mut() {
        entry.done_at = Some(now);
    }
    let _ = book.admit(key("late"), 0, now + KEEP_FOR + Duration::from_secs(1));
    assert_eq!(book.entries.len(), 1);
}

/// The daemon's own listener: the same request with one dual id, on two peer-token
/// connections (two paths of one peer link), is answered on both with one answer, from one
/// run. A Web client that replays that dual id gets no cached answer: its request runs as
/// any of its requests does, and the book never sees it.
#[tokio::test]
async fn a_request_on_two_connections_runs_once_and_both_get_its_answer() {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = crate::hub::Hub::new(config, store);
    let home = tempfile::tempdir().unwrap();
    let peer_auth = super::super::peer_auth::PeerAuth::create(home.path()).unwrap();
    let peer_token = std::fs::read_to_string(peer_auth.path()).unwrap().trim().to_owned();
    let auth = super::super::WsAuth { local_app: None, peer: Some(std::sync::Arc::new(peer_auth)) };
    let listener = super::super::bind_ws("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(super::super::serve_ws_with(hub, listener, TOKEN.into(), auth));
    let connect = |peer: Option<String>| async move {
        let mut req = format!("ws://127.0.0.1:{port}").into_client_request().unwrap();
        req.headers_mut().insert("authorization", format!("Bearer {TOKEN}").parse().unwrap());
        if let Some(token) = peer {
            req.headers_mut().insert(super::super::peer_auth::HEADER, token.parse().unwrap());
        }
        tokio_tungstenite::connect_async(req).await.unwrap().0
    };
    let (mut a, mut b) = (connect(Some(peer_token.clone())).await, connect(Some(peer_token)).await);
    // Each connection's `initialize` answer says whether it is the peer principal: a stale
    // peer token is served as the Web, which still lists `dualSend` but is no principal.
    let mut stale = connect(Some("stale-token".into())).await;
    for (ws, principal) in [(&mut a, true), (&mut stale, false)] {
        let init = json!({"jsonrpc": "2.0", "id": 1, "method": crate::rpc::method::INITIALIZE,
                "params": {"protocolVersion": 1, "_meta": {"acpmux": {"observer": true}}}});
        ws.send(Frame::Text(init.to_string().into())).await.unwrap();
        let reply = answer(ws, 1).await;
        let mux = &reply["result"]["_meta"]["acpmux"];
        assert_eq!(mux["dualPrincipal"], json!(principal), "{reply}");
        let features = mux["features"].as_array().unwrap();
        assert!(features.iter().any(|f| f == FEATURE), "{reply}");
    }
    let key = format!("wire-{}", uuid::Uuid::now_v7());
    let line = json!({"jsonrpc": "2.0", "id": 7, "method": crate::rpc::method::MUX_STATS,
            "params": {"_meta": {"acpmux": {"dualId": key}}}})
    .to_string();
    a.send(Frame::Text(line.clone().into())).await.unwrap();
    b.send(Frame::Text(line.into())).await.unwrap();
    let (first, second) = (answer(&mut a, 7).await, answer(&mut b, 7).await);
    assert!(first.get("result").is_some() || first.get("error").is_some(), "{first}");
    assert_eq!(first.get("result"), second.get("result"));
    assert_eq!(first.get("error"), second.get("error"));
    // Both copies arrived under the one key: the first ran, the second took its answer.
    let entry = (PEER_LINK.to_owned(), key.clone());
    assert_eq!(book().entries.get(&entry).map(|e| e.copies), Some(2));
    // A Web client holding the peer's dual id: its request runs, outside the book.
    let mut web = connect(None).await;
    let replay = json!({"jsonrpc": "2.0", "id": 9, "method": crate::rpc::method::MUX_STATS,
            "params": {"_meta": {"acpmux": {"dualId": key}}}});
    web.send(Frame::Text(replay.to_string().into())).await.unwrap();
    assert!(answer(&mut web, 9).await.get("id").is_some());
    assert_eq!(book().entries.get(&entry).map(|e| e.copies), Some(2), "not a repeat");
    // A request without a dual id is untouched by the book.
    let plain =
        json!({"jsonrpc": "2.0", "id": 8, "method": crate::rpc::method::MUX_STATS, "params": {}});
    a.send(Frame::Text(plain.to_string().into())).await.unwrap();
    assert!(answer(&mut a, 8).await.get("id").is_some());
}

type Ws =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn answer(ws: &mut Ws, id: u64) -> Value {
    loop {
        let frame = tokio::time::timeout(std::time::Duration::from_secs(10), ws.next())
            .await
            .expect("an answer comes")
            .unwrap()
            .unwrap();
        if let Frame::Text(text) = frame {
            let v: Value = serde_json::from_str(text.as_str()).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }
}
