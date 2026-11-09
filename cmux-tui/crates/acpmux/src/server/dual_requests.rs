//! Requests and notifications a peer link sends twice, once on each of two paths, while its
//! active path is in doubt (`peer_dual.rs` on the sending side). Both copies carry the same
//! `_meta.acpmux.dualId`: the first copy to arrive runs, and a repeat on the other connection
//! is answered with the first one's answer, so the request runs once whichever path delivered
//! it. A repeated notification is dropped.
//!
//! Bounded: at most [`MOST`] keys, each kept [`KEEP_FOR`] after its answer; the oldest go first.

use crate::rpc::RpcError;
use serde_json::Value;
use std::collections::{HashMap, VecDeque};
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::watch;

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
    key: String,
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

struct Entry {
    tx: watch::Sender<Option<Outcome>>,
    done_at: Option<Instant>,
    /// Copies that arrived under this key.
    copies: u32,
}

#[derive(Default)]
struct Book {
    entries: HashMap<String, Entry>,
    order: VecDeque<String>,
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

/// The `dualId` of a request's or notification's params, if it has a usable one and `method`
/// is one sent on two paths ([`METHODS`]).
pub(crate) fn key_for(method: &str, params: Option<&Value>) -> Option<String> {
    if !METHODS.contains(&method) {
        return None;
    }
    key_of(params)
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
    fn admit(&mut self, key: String, now: Instant) -> Seen {
        self.prune(now);
        if let Some(entry) = self.entries.get_mut(&key) {
            entry.copies = entry.copies.saturating_add(1);
            return Seen::Repeat(entry.tx.subscribe());
        }
        let tx = watch::Sender::new(None);
        self.entries.insert(key.clone(), Entry { tx: tx.clone(), done_at: None, copies: 1 });
        self.order.push_back(key.clone());
        Seen::First(First { key, tx })
    }
}

/// A request with `dualId` `key` arrived: the first copy runs it, a repeat waits on the first.
pub(super) fn admit(key: String) -> Seen {
    book().admit(key, Instant::now())
}

/// A notification with `dualId` `key` arrived: true for the first copy only.
pub(super) fn first_notification(key: String) -> bool {
    match admit(key) {
        Seen::First(first) => {
            first.finish(Outcome::RunAgain);
            true
        }
        Seen::Repeat(_) => false,
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

    #[tokio::test]
    async fn the_second_copy_answers_with_the_first_ones_answer() {
        let key = format!("book-{}", uuid::Uuid::now_v7());
        let Seen::First(first) = admit(key.clone()) else { panic!("the first copy runs") };
        let Seen::Repeat(repeat) = admit(key.clone()) else { panic!("the second waits") };
        let waiting = tokio::spawn(first_answer(repeat));
        first.finish(Outcome::Answer(Ok(json!({"ran": 1}))));
        assert_eq!(waiting.await.unwrap(), Some(Ok(json!({"ran": 1}))));
        // A third copy, after the answer, gets it at once.
        let Seen::Repeat(late) = admit(key) else { panic!("still known") };
        assert_eq!(first_answer(late).await, Some(Ok(json!({"ran": 1}))));
    }

    #[test]
    fn a_notification_sent_twice_is_taken_once() {
        let key = format!("note-{}", uuid::Uuid::now_v7());
        assert!(first_notification(key.clone()));
        assert!(!first_notification(key));
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
        for n in 0..MOST + 50 {
            let _first = book.admit(format!("bound-{n}"), now);
        }
        assert_eq!(book.entries.len(), MOST + 1, "the oldest go first");
        assert!(!book.entries.contains_key("bound-0"));
        // Answered keys go once they are older than KEEP_FOR.
        for entry in book.entries.values_mut() {
            entry.done_at = Some(now);
        }
        let _ = book.admit("late".into(), now + KEEP_FOR + Duration::from_secs(1));
        assert_eq!(book.entries.len(), 1);
    }

    /// The daemon's own listener: the same request with one dual id, on two connections (two
    /// paths of one peer link), is answered on both with one answer, from one run.
    #[tokio::test]
    async fn a_request_on_two_connections_runs_once_and_both_get_its_answer() {
        let mut config = Config::default();
        config.store.mode = StoreMode::Memory;
        let store =
            crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
        let hub = crate::hub::Hub::new(config, store);
        let listener = super::super::bind_ws("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(super::super::serve_ws_with(hub, listener, TOKEN.into(), Default::default()));
        let connect = || async move {
            let mut req = format!("ws://127.0.0.1:{port}").into_client_request().unwrap();
            req.headers_mut().insert("authorization", format!("Bearer {TOKEN}").parse().unwrap());
            tokio_tungstenite::connect_async(req).await.unwrap().0
        };
        let (mut a, mut b) = (connect().await, connect().await);
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
        assert_eq!(book().entries.get(&key).map(|e| e.copies), Some(2));
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
