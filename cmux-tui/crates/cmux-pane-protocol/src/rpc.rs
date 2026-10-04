//! Typed calls and subscriptions over any [`Transport`]. Both peers may
//! call: every [`Peer`] answers incoming calls through its [`Handler`] and
//! can issue its own. Ids are per connection; results may arrive in any
//! order.

use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use serde_json::{Value, json};
use tokio::sync::{Mutex, mpsc, oneshot};
use tokio::task::AbortHandle;

use crate::envelope::{AUTH_REPLY_ID, Envelope, Role};
use crate::error::{self, ErrorBody};
use crate::frame::Message;
use crate::op::Op;
use crate::transport::Transport;

pub type CallFuture = Pin<Box<dyn Future<Output = Result<Value, ErrorBody>> + Send>>;
pub type SubscribeResult = Result<mpsc::Receiver<EventItem>, ErrorBody>;

/// One event of a subscription. `gap` is set on the first event after the
/// sender dropped events because its queue was full.
#[derive(Debug, Clone, PartialEq)]
pub struct EventItem {
    pub data: Value,
    pub gap: bool,
}

impl EventItem {
    pub fn new(data: Value) -> Self {
        Self { data, gap: false }
    }
}

/// Feed a subscription from `source` through a bounded queue of `capacity`.
/// When the queue is full, events are dropped and the next one delivered
/// carries `gap` (wire decision 15), so a slow subscriber never stalls the
/// provider.
pub fn bounded_events(
    mut source: mpsc::Receiver<Value>,
    capacity: usize,
) -> mpsc::Receiver<EventItem> {
    let (tx, rx) = mpsc::channel(capacity.max(1));
    tokio::spawn(async move {
        let mut dropped = false;
        while let Some(data) = source.recv().await {
            match tx.try_send(EventItem { data, gap: dropped }) {
                Ok(()) => dropped = false,
                Err(mpsc::error::TrySendError::Full(_)) => dropped = true,
                Err(mpsc::error::TrySendError::Closed(_)) => return,
            }
        }
    });
    rx
}

/// Answers a peer's incoming calls and subscriptions.
pub trait Handler: Send + Sync + 'static {
    /// `gesture` is the call envelope's gesture token, if any.
    fn call(&self, op: String, params: Value, gesture: Option<String>) -> CallFuture;

    /// Start event stream `stream`; events are sent until the receiver
    /// closes or the peer unsubscribes.
    fn subscribe(&self, stream: String, filter: Option<Value>) -> SubscribeResult {
        let _ = filter;
        Err(ErrorBody::new(error::UNKNOWN_STREAM, format!("no event source for {stream}")))
    }

    /// Accept byte stream `stream` for `op`. No byte-stream ops are served
    /// in this slice, so the default refuses like an unknown call.
    fn open(&self, op: String, params: Option<Value>) -> Result<(), ErrorBody> {
        let _ = params;
        Err(ErrorBody::new(error::UNKNOWN_OP, format!("no stream handler for {op}")))
    }
}

/// A handler that refuses every call.
pub struct NoHandler;

impl Handler for NoHandler {
    fn call(&self, op: String, _params: Value, _gesture: Option<String>) -> CallFuture {
        Box::pin(
            async move { Err(ErrorBody::new(error::UNKNOWN_OP, format!("no handler for {op}"))) },
        )
    }
}

type Pending = Arc<Mutex<HashMap<u64, oneshot::Sender<Result<Value, ErrorBody>>>>>;

/// The calling side of a connection. Cloning shares it.
#[derive(Clone)]
pub struct Peer {
    tx: mpsc::Sender<Message>,
    next_id: Arc<AtomicU64>,
    pending: Pending,
    subscriptions: Arc<Mutex<HashMap<u64, mpsc::Sender<EventItem>>>>,
    /// Subscribe call id -> the channel to register when its `ok` arrives,
    /// before any later `ev` is read.
    pending_subs: Arc<Mutex<HashMap<u64, mpsc::Sender<EventItem>>>>,
}

/// Events of one subscription; dropping it does not unsubscribe, call
/// [`Peer::unsubscribe`].
pub struct Subscription {
    pub id: u64,
    pub events: mpsc::Receiver<EventItem>,
}

impl Peer {
    /// Run `transport` with `handler` answering incoming calls. The returned
    /// task ends when the transport closes; pending calls then fail.
    pub fn start(
        transport: Transport,
        role: Role,
        handler: Arc<dyn Handler>,
    ) -> (Self, tokio::task::JoinHandle<()>) {
        let peer = Self {
            tx: transport.tx.clone(),
            next_id: Arc::new(AtomicU64::new(AUTH_REPLY_ID + 1)),
            pending: Arc::default(),
            subscriptions: Arc::default(),
            pending_subs: Arc::default(),
        };
        let task = tokio::spawn(peer.clone().run(transport, role, handler));
        (peer, task)
    }

    pub async fn send(&self, envelope: &Envelope) -> bool {
        self.tx.send(Message::Text(envelope.encode())).await.is_ok()
    }

    fn closed() -> ErrorBody {
        ErrorBody::new(error::CLOSED, "connection closed").retryable()
    }

    pub async fn call(&self, op: &str, params: Value) -> Result<Value, ErrorBody> {
        self.call_with_gesture(op, params, None).await
    }

    /// Call `op` carrying a gesture token (decision 29).
    pub async fn call_with_gesture(
        &self,
        op: &str,
        params: Value,
        gesture: Option<String>,
    ) -> Result<Value, ErrorBody> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (reply_tx, reply_rx) = oneshot::channel();
        self.pending.lock().await.insert(id, reply_tx);
        let envelope = Envelope::Call { id, op: op.to_owned(), params, cap: None, gesture };
        if !self.send(&envelope).await {
            self.pending.lock().await.remove(&id);
            return Err(Self::closed());
        }
        reply_rx.await.unwrap_or_else(|_| Err(Self::closed()))
    }

    /// Call a declared op with typed params and result.
    pub async fn call_op<O: Op>(&self, params: &O::Params) -> Result<O::Result, ErrorBody> {
        let params = serde_json::to_value(params)
            .map_err(|e| ErrorBody::new(error::INVALID_PARAMS, e.to_string()))?;
        let value = self.call(O::NAME, params).await?;
        serde_json::from_value(value).map_err(|e| {
            ErrorBody::new(error::INVALID_RESULT, format!("result of {}: {e}", O::NAME))
        })
    }

    pub async fn subscribe(
        &self,
        stream: &str,
        filter: Option<Value>,
    ) -> Result<Subscription, ErrorBody> {
        let filter = match filter {
            None => None,
            Some(Value::Object(map)) => Some(map),
            Some(_) => {
                return Err(ErrorBody::new(error::INVALID_PARAMS, "filter must be an object"));
            }
        };
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (reply_tx, reply_rx) = oneshot::channel();
        let (events_tx, events) = mpsc::channel(64);
        self.pending.lock().await.insert(id, reply_tx);
        self.pending_subs.lock().await.insert(id, events_tx);
        if !self.send(&Envelope::Sub { id, stream: stream.to_owned(), filter, cap: None }).await {
            self.pending.lock().await.remove(&id);
            self.pending_subs.lock().await.remove(&id);
            return Err(Self::closed());
        }
        let value = reply_rx.await.unwrap_or_else(|_| Err(Self::closed()))?;
        let sub = value
            .get("sub")
            .and_then(Value::as_u64)
            .ok_or_else(|| ErrorBody::new(error::INVALID_RESULT, "no sub id"))?;
        Ok(Subscription { id: sub, events })
    }

    pub async fn unsubscribe(&self, sub: u64) {
        self.subscriptions.lock().await.remove(&sub);
        self.send(&Envelope::Unsub { sub }).await;
    }

    async fn run(self, mut transport: Transport, role: Role, handler: Arc<dyn Handler>) {
        let mut running: HashMap<u64, AbortHandle> = HashMap::new();
        let mut serving: HashMap<u64, AbortHandle> = HashMap::new();
        let next_sub = AtomicU64::new(1);
        while let Some(message) = transport.rx.recv().await {
            let Message::Text(text) = message else { continue };
            let envelope = match Envelope::decode(&text) {
                Ok(envelope) => envelope,
                Err(problem) => {
                    // Answer with the id when it is readable and in range,
                    // else with id 0 (G5); after auth, id 0 is not a refusal.
                    let id = serde_json::from_str::<Value>(&text)
                        .ok()
                        .and_then(|v| v.get("id")?.as_u64())
                        .filter(|id| (1..=crate::envelope::MAX_SAFE_INTEGER).contains(id))
                        .unwrap_or(AUTH_REPLY_ID);
                    self.send(&Envelope::error(
                        id,
                        ErrorBody::new(error::BAD_MESSAGE, problem.to_string()),
                    ))
                    .await;
                    continue;
                }
            };
            running.retain(|_, task| !task.is_finished());
            match envelope {
                Envelope::Ok { id, value } => {
                    let pending_sub = self.pending_subs.lock().await.remove(&id);
                    if let (Some(events), Some(sub)) =
                        (pending_sub, value.get("sub").and_then(Value::as_u64))
                    {
                        self.subscriptions.lock().await.insert(sub, events);
                    }
                    self.resolve(id, Ok(value)).await;
                }
                Envelope::Err { id, .. } => {
                    self.pending_subs.lock().await.remove(&id);
                    let body = envelope
                        .error_body()
                        .unwrap_or_else(|| ErrorBody::new(error::INTERNAL, ""));
                    self.resolve(id, Err(body)).await;
                }
                Envelope::Call { id, op, params, gesture, .. } => {
                    let future = handler.call(op, params, gesture);
                    let peer = self.clone();
                    let task = tokio::spawn(async move {
                        let reply = match future.await {
                            Ok(value) => Envelope::Ok { id, value },
                            Err(body) => Envelope::error(id, body),
                        };
                        peer.send(&reply).await;
                    });
                    running.insert(id, task.abort_handle());
                }
                Envelope::Cancel { id } => {
                    if let Some(task) = running.remove(&id) {
                        task.abort();
                        self.send(&Envelope::error(
                            id,
                            ErrorBody::new(error::CANCELLED, "cancelled"),
                        ))
                        .await;
                    }
                }
                Envelope::Sub { id, stream, filter, .. } => {
                    match handler.subscribe(stream, filter.map(Value::Object)) {
                        Ok(mut events) => {
                            let sub = next_sub.fetch_add(1, Ordering::Relaxed);
                            self.send(&Envelope::Ok { id, value: json!({ "sub": sub }) }).await;
                            let peer = self.clone();
                            let task = tokio::spawn(async move {
                                let mut seq = 0;
                                while let Some(EventItem { data, gap }) = events.recv().await {
                                    seq += 1;
                                    if !peer.send(&Envelope::Ev { sub, seq, data, gap }).await {
                                        return;
                                    }
                                }
                            });
                            serving.insert(sub, task.abort_handle());
                        }
                        Err(body) => {
                            self.send(&Envelope::error(id, body)).await;
                        }
                    }
                }
                Envelope::Unsub { sub } => {
                    if let Some(task) = serving.remove(&sub) {
                        task.abort();
                    }
                }
                Envelope::Ev { sub, data, gap, .. } => {
                    let sender = self.subscriptions.lock().await.get(&sub).cloned();
                    if let Some(sender) = sender {
                        let _ = sender.send(EventItem { data, gap }).await;
                    }
                }
                Envelope::Open { id, stream, op, params, .. } => {
                    let reply = if !role.peer_may_open(stream) {
                        Envelope::error(
                            id,
                            ErrorBody::new(
                                error::STREAM_ABORTED,
                                format!("stream id {stream} not usable"),
                            ),
                        )
                    } else {
                        match handler.open(op, params) {
                            Ok(()) => Envelope::Ok { id, value: Value::Null },
                            Err(body) => Envelope::error(id, body),
                        }
                    };
                    self.send(&reply).await;
                }
                // Handles, stream credit and ends, auth and bye belong to the
                // layers that own them, not to the call router.
                Envelope::Release { .. }
                | Envelope::Credit { .. }
                | Envelope::End { .. }
                | Envelope::Auth { .. }
                | Envelope::Bye => {}
            }
        }
        for task in running.values().chain(serving.values()) {
            task.abort();
        }
        self.pending.lock().await.clear();
        self.subscriptions.lock().await.clear();
    }

    async fn resolve(&self, id: u64, result: Result<Value, ErrorBody>) {
        if let Some(reply) = self.pending.lock().await.remove(&id) {
            let _ = reply.send(result);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transport::memory_pair;

    struct Echo;

    impl Handler for Echo {
        fn call(&self, op: String, params: Value, _gesture: Option<String>) -> CallFuture {
            Box::pin(async move {
                if op == "test.echo.slow" {
                    tokio::time::sleep(std::time::Duration::from_secs(30)).await;
                }
                Ok(json!({ "op": op, "params": params }))
            })
        }

        fn subscribe(&self, _stream: String, _filter: Option<Value>) -> SubscribeResult {
            let (tx, rx) = mpsc::channel(4);
            tokio::spawn(async move {
                for n in 0..3 {
                    let _ = tx.send(EventItem::new(json!({ "n": n }))).await;
                }
            });
            Ok(rx)
        }
    }

    #[tokio::test]
    async fn both_sides_call_and_subscribe() {
        let (a, b) = memory_pair();
        let (a, _) = Peer::start(a, Role::Connecting, Arc::new(Echo));
        let (b, _) = Peer::start(b, Role::Accepting, Arc::new(Echo));
        let reply = a.call("test.echo.say", json!({ "x": 1 })).await.unwrap();
        assert_eq!(reply, json!({ "op": "test.echo.say", "params": { "x": 1 } }));
        assert!(b.call("test.echo.say", json!({})).await.is_ok());
        let mut subscription = a.subscribe("test.echo.ticks", None).await.unwrap();
        for n in 0..3 {
            assert_eq!(subscription.events.recv().await, Some(EventItem::new(json!({ "n": n }))));
        }
    }

    #[tokio::test]
    async fn a_full_queue_drops_events_and_marks_the_next_one() {
        let (source_tx, source_rx) = mpsc::channel(16);
        let mut events = bounded_events(source_rx, 2);
        for n in 0..5 {
            source_tx.send(json!(n)).await.unwrap();
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        assert_eq!(events.recv().await, Some(EventItem::new(json!(0))));
        assert_eq!(events.recv().await, Some(EventItem::new(json!(1))));
        source_tx.send(json!(5)).await.unwrap();
        assert_eq!(events.recv().await, Some(EventItem { data: json!(5), gap: true }));
    }

    #[tokio::test]
    async fn out_of_order_results_and_close_fails_pending() {
        let (a, mut b) = memory_pair();
        let (a, _) = Peer::start(a, Role::Connecting, Arc::new(NoHandler));
        let first = tokio::spawn({
            let a = a.clone();
            async move { a.call("test.echo.first", json!({})).await }
        });
        let Some(Message::Text(first_call)) = b.recv().await else { panic!("no call") };
        let second = tokio::spawn({
            let a = a.clone();
            async move { a.call("test.echo.second", json!({})).await }
        });
        let Some(Message::Text(second_call)) = b.recv().await else { panic!("no call") };
        let Envelope::Call { id: second_id, .. } = Envelope::decode(&second_call).unwrap() else {
            panic!()
        };
        assert!(Envelope::decode(&first_call).is_ok());
        b.send(Message::Text(Envelope::Ok { id: second_id, value: json!(2) }.encode())).await;
        assert_eq!(second.await.unwrap(), Ok(json!(2)));
        drop(b);
        assert!(first.await.unwrap().unwrap_err().retryable);
    }
}
