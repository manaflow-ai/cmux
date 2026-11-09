//! Requests and notifications a peer link sends twice, once on each of two paths, while its
//! active path is in doubt (`peer_dual.rs` on the sending side). Both copies carry the same
//! `_meta.acpmux.dualId`: the first copy to arrive runs, and a repeat on the other connection
//! is answered with the first one's answer, so the request runs once whichever path delivered
//! it. A repeated notification is dropped.
//!
//! Who may use it, and what it serves:
//! - Only a peer daemon's own link (the WebSocket listener's `PeerToken` connections) carries a
//!   `dualId`; on any other connection (the Web, a paired machine, an in-process carrier such as
//!   the mesh relay) it is ignored, and the request runs as any other (`Conn::dual_principal`).
//! - Each entry is keyed by that principal and the `dualId`, and bound to the request it was
//!   made for (a digest of its method and params): a repeat is served the cached answer only
//!   when the same principal sends the same request, which was authorized as a whole when its
//!   first copy ran. Anything else runs through the full request path.
//! - Only requests whose effect is not bound to the connection that runs it ([`dual_safe`]):
//!   neither a `session/load` nor an attach, nor a prompt that carries a cloud turn prepared on
//!   one connection or whose caller reads its reply on that connection, nor one forwarded for
//!   another client (`via`). A cancel's own part on each connection (the preparations made
//!   there) runs on both copies (`requests::cancel_on_connection`).
//!
//! Bounded: at most [`MOST`] keys, each kept [`KEEP_FOR`] after its answer; the oldest go first.

use crate::rpc::RpcError;
use serde_json::Value;
use std::collections::{HashMap, VecDeque};
use std::hash::{Hash, Hasher};
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::watch;

/// The principal of a peer daemon's own link (`Conn::dual_principal`): its peer token is the
/// proof, and every holder of it is the same principal.
pub(crate) const PEER_LINK: &str = "peerToken";
/// The feature a daemon lists in `initialize` when it takes `dualId`.
pub const FEATURE: &str = "dualSend";
/// The longest `dualId` taken; a longer one is ignored (the request runs as usual).
const MAX_KEY: usize = 128;
/// Keys kept at most.
const MOST: usize = 4096;
/// How long a key is kept after its answer: a repeat comes within one path's lag of the first.
const KEEP_FOR: Duration = Duration::from_secs(120);

/// What the first copy of a request ended with.
#[derive(Debug, Clone)]
pub(super) enum Outcome {
    Answer(Result<Value, RpcError>),
    /// Its answer went out as bytes already (a shared session list, `list_reply.rs`): a repeat
    /// runs the read itself.
    RunAgain,
}

/// Whether this copy runs the request or waits on the first.
pub(super) enum Seen {
    First(First),
    Repeat(watch::Receiver<Option<Outcome>>),
}

/// The first copy's handle: [`First::finish`] publishes its outcome to any repeat.
pub(super) struct First {
    key: Key,
    tx: watch::Sender<Option<Outcome>>,
}

impl First {
    pub(super) fn finish(self, outcome: Outcome) {
        self.tx.send_replace(Some(outcome));
        if let Some(entry) = book().entries.get_mut(&self.key) {
            entry.done_at = Some(Instant::now());
        }
    }
}

/// An entry's key: the principal that sent it and its `dualId`.
type Key = (String, String);

struct Entry {
    tx: watch::Sender<Option<Outcome>>,
    /// The request it was made for (`digest`): a repeat must be the same request.
    digest: u64,
    done_at: Option<Instant>,
    /// Copies that arrived under this key.
    copies: u32,
}

#[derive(Default)]
struct Book {
    entries: HashMap<Key, Entry>,
    order: VecDeque<Key>,
}

static BOOK: LazyLock<Mutex<Book>> = LazyLock::new(Default::default);

fn book() -> std::sync::MutexGuard<'static, Book> {
    BOOK.lock().unwrap_or_else(|e| e.into_inner())
}

/// The methods a peer link sends on two paths: each runs once whichever copy came first, and
/// none has an effect bound to the connection that ran it. A `session/load`, an attach or a
/// subscription replays or subscribes on its own connection: the copy that lost would get the
/// first one's answer with nothing streamed to it, so those go only on the link's chosen path
/// (`peer_dual.rs`), and a `dualId` on one is ignored here.
pub const METHODS: [&str; 4] = [
    crate::rpc::method::SESSION_PROMPT,
    crate::rpc::method::SESSION_CANCEL,
    crate::rpc::method::MUX_WAIT,
    crate::rpc::method::MUX_STATS,
];

/// Whether request or notification `method` with `params` may go on two paths: on the list
/// ([`METHODS`]), and with nothing in it bound to the connection that runs it. The sender
/// (`peer_dual.rs`) and this daemon decide by the same rule, so what is copied is what is
/// deduplicated.
pub fn dual_safe(method: &str, params: &Value) -> bool {
    if !METHODS.contains(&method) {
        return false;
    }
    let mux = params.pointer("/_meta/acpmux");
    // Forwarded for another client (the Web, a paired machine): held to that client's rules,
    // which are not the link's.
    if mux.and_then(|m| m.get("via")).is_some() {
        return false;
    }
    if method == crate::rpc::method::SESSION_PROMPT {
        // A cloud turn is prepared on one connection and runs only there (`validate_prepared`).
        if params.get("cloud_turn").is_some() {
            return false;
        }
        // Its caller reads the reply on the connection it asked on (`lane_report_reads.rs`).
        let reads_reply = crate::cli::output::READS_REPLY_META;
        if mux.and_then(|m| m.get(reads_reply)).and_then(Value::as_bool) == Some(true) {
            return false;
        }
    }
    true
}

/// The book's key and digest for a request or notification `method` that `principal` sent
/// with `params`: None when the connection may not use a `dualId`, the request may not go on
/// two paths ([`dual_safe`]), or it has no usable `dualId`.
pub(crate) fn key_for(
    principal: Option<&str>,
    method: &str,
    params: Option<&Value>,
) -> Option<(Key, u64)> {
    let principal = principal?;
    let params = params?;
    if !dual_safe(method, params) {
        return None;
    }
    let key = key_of(Some(params))?;
    Some(((principal.to_owned(), key), digest(method, params)))
}

/// What a request is, without its `dualId`: both copies of one have the same.
fn digest(method: &str, params: &Value) -> u64 {
    let mut params = params.clone();
    if let Some(mux) = params.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
        mux.remove("dualId");
    }
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    method.hash(&mut hasher);
    params.to_string().hash(&mut hasher);
    hasher.finish()
}

/// The `dualId` of a request's or notification's params, if it has a usable one.
pub(super) fn key_of(params: Option<&Value>) -> Option<String> {
    let key = params?.pointer("/_meta/acpmux/dualId")?.as_str()?;
    (!key.is_empty() && key.len() <= MAX_KEY).then(|| key.to_owned())
}

impl Book {
    fn prune(&mut self, now: Instant) {
        while let Some(oldest) = self.order.front() {
            let expired = self.entries.get(oldest).is_none_or(|entry| {
                entry.done_at.is_some_and(|at| now.duration_since(at) > KEEP_FOR)
            });
            if !expired && self.order.len() <= MOST {
                break;
            }
            if let Some(oldest) = self.order.pop_front() {
                self.entries.remove(&oldest);
            }
        }
    }
}

impl Book {
    /// None for a key known for another request: it runs as any request does.
    fn admit(&mut self, key: Key, digest: u64, now: Instant) -> Option<Seen> {
        self.prune(now);
        if let Some(entry) = self.entries.get_mut(&key) {
            if entry.digest != digest {
                return None;
            }
            entry.copies = entry.copies.saturating_add(1);
            return Some(Seen::Repeat(entry.tx.subscribe()));
        }
        let tx = watch::Sender::new(None);
        let entry = Entry { tx: tx.clone(), digest, done_at: None, copies: 1 };
        self.entries.insert(key.clone(), entry);
        self.order.push_back(key.clone());
        Some(Seen::First(First { key, tx }))
    }
}

/// A request with key and digest `seen` ([`key_for`]) arrived: the first copy runs it, a
/// repeat waits on the first. None: it runs as any request does.
pub(super) fn admit((key, digest): (Key, u64)) -> Option<Seen> {
    book().admit(key, digest, Instant::now())
}

/// A notification with key and digest `seen` arrived: false for a repeat only.
pub(super) fn first_notification(seen: (Key, u64)) -> bool {
    match admit(seen) {
        Some(Seen::First(first)) => {
            first.finish(Outcome::RunAgain);
            true
        }
        Some(Seen::Repeat(_)) => false,
        None => true,
    }
}

/// A repeat's answer: the first copy's, once it has one. None when the first was dropped
/// (its key evicted before it answered) or answered as bytes: the repeat runs the request.
pub(super) async fn first_answer(
    mut first: watch::Receiver<Option<Outcome>>,
) -> Option<Result<Value, RpcError>> {
    let outcome = first.wait_for(Option::is_some).await.ok()?.clone()?;
    match outcome {
        Outcome::Answer(answer) => Some(answer),
        Outcome::RunAgain => None,
    }
}

/// Before a request runs: Ok with the handle of the first copy (None without a dual id) to run
/// it, or Err with the first copy's answer for a repeat to send as is.
pub(super) async fn before_run(
    dual: Option<Seen>,
) -> Result<Option<First>, Result<Value, RpcError>> {
    match dual {
        Some(Seen::Repeat(first)) => match first_answer(first).await {
            Some(answer) => Err(answer),
            None => Ok(None),
        },
        Some(Seen::First(first)) => Ok(Some(first)),
        None => Ok(None),
    }
}

/// The first copy answered `answer`, or None when its answer went out as bytes.
pub(super) fn finish(first: Option<First>, answer: Option<&Result<Value, RpcError>>) {
    if let Some(first) = first {
        first.finish(answer.map_or(Outcome::RunAgain, |a| Outcome::Answer(a.clone())));
    }
}

/// The reply to request `id` that answered `answer`.
pub(super) fn reply(id: Value, answer: Result<Value, RpcError>) -> crate::rpc::Message {
    match answer {
        Ok(v) => crate::rpc::Message::ok(id, v),
        Err(e) => crate::rpc::Message::err(id, e),
    }
}

#[cfg(test)]
mod tests {
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
        let store =
            crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
        let hub = crate::hub::Hub::new(config, store);
        let home = tempfile::tempdir().unwrap();
        let peer_auth = super::super::peer_auth::PeerAuth::create(home.path()).unwrap();
        let peer_token = std::fs::read_to_string(peer_auth.path()).unwrap().trim().to_owned();
        let auth =
            super::super::WsAuth { local_app: None, peer: Some(std::sync::Arc::new(peer_auth)) };
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
        let (mut a, mut b) =
            (connect(Some(peer_token.clone())).await, connect(Some(peer_token)).await);
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
        let plain = json!({"jsonrpc": "2.0", "id": 8, "method": crate::rpc::method::MUX_STATS, "params": {}});
        a.send(Frame::Text(plain.to_string().into())).await.unwrap();
        assert!(answer(&mut a, 8).await.get("id").is_some());
    }

    type Ws = tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >;

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
}
