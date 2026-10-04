//! The cloud link of one daemon (home-cloud-proxy.md, home-scale.md A7): the
//! session lease, the HTTP calls behind each command, and one shared upstream
//! socket per subscribed target with resume and reconnect.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

use super::CloudError;
use super::contract::{
    self, MAX_PAGE, MAX_TAIL, OpRequest, Target, history_data, inbox_list_data, mutation_data,
    read_body, read_value, require_conversation, snapshot_data,
};
use super::session::{CloudSession, SessionParams};
use super::stream::{CloudEvent, StreamAction, StreamState};

/// One HTTP reply: the status and the JSON body (`Null` when not JSON).
#[derive(Debug, Clone, PartialEq)]
pub struct HttpReply {
    pub status: u16,
    pub body: Value,
}

/// A transport failure before a reply arrived.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TransportError(pub String);

/// Why an upstream WebSocket could not open.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConnectError {
    /// Handshake answered 401: the token is not accepted.
    Unauthenticated,
    /// Handshake answered 403 or 404: the owner refuses this principal.
    Forbidden,
    Unavailable(String),
}

/// What one receive on an upstream socket produced.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WireRecv {
    Text(String),
    /// Nothing arrived within the timeout.
    Idle,
    Closed {
        code: Option<u16>,
    },
}

/// One open upstream WebSocket (`cmux.wire.v1`).
pub trait CloudWire: Send {
    fn send(&mut self, text: &str) -> Result<(), TransportError>;
    fn recv(&mut self, timeout: Duration) -> WireRecv;
}

/// The HTTP and WebSocket seam. Calls block; the daemon runs them off the
/// connection's request loop.
pub trait CloudBackend: Send + Sync {
    /// `POST url` with `authorization: Bearer <bearer>`, the JSON `body` and,
    /// when given, `x-cmux-client-version`.
    fn post(
        &self,
        url: &str,
        bearer: &str,
        client_version: Option<&str>,
        body: &Value,
    ) -> Result<HttpReply, TransportError>;
    /// Opens `url` with subprotocols `cmux.wire.v1, bearer.<bearer>`.
    fn connect(
        &self,
        url: &str,
        bearer: &str,
        client_version: Option<&str>,
    ) -> Result<Box<dyn CloudWire>, ConnectError>;
}

/// One reserved cloud request slot, released on drop.
pub struct RequestPermit(());

/// Receives every daemon event (the mux publishes it to subscribers).
pub type EventSink = Arc<dyn Fn(CloudEvent) + Send + Sync>;

/// Tunables; tests shorten the waits and fix the clock.
#[derive(Clone)]
pub struct ServiceOptions {
    /// How long a conversation socket stays open after its last subscriber.
    pub linger: Duration,
    pub backoff_min: Duration,
    pub backoff_max: Duration,
    /// How long one upstream receive waits before the driver rechecks its
    /// subscribers and the lease.
    pub poll: Duration,
    pub max_conversation_subscriptions: usize,
    /// Cloud HTTP requests the daemon runs at once; one more is refused with
    /// `cloud_unavailable` (retryable) instead of queueing.
    pub max_concurrent_requests: usize,
    /// Unix milliseconds.
    pub now_ms: Arc<dyn Fn() -> u64 + Send + Sync>,
}

impl Default for ServiceOptions {
    fn default() -> Self {
        Self {
            linger: Duration::from_secs(60),
            backoff_min: Duration::from_secs(1),
            backoff_max: Duration::from_secs(30),
            poll: Duration::from_secs(1),
            max_conversation_subscriptions: 64,
            max_concurrent_requests: 16,
            now_ms: Arc::new(|| {
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map(|elapsed| elapsed.as_millis() as u64)
                    .unwrap_or(0)
            }),
        }
    }
}

#[derive(Default)]
struct Lease {
    session: Option<CloudSession>,
    generation: u64,
    /// `expiring` was announced for this generation.
    expiring_sent: bool,
    /// A socket announced `expired` for this generation.
    expired_sent: bool,
}

struct Subscription {
    clients: BTreeSet<u64>,
    idle_since: Option<Instant>,
}

struct Inner {
    backend: Arc<dyn CloudBackend>,
    options: ServiceOptions,
    lease: Mutex<Lease>,
    subscriptions: Mutex<BTreeMap<Target, Subscription>>,
    sink: Mutex<Option<EventSink>>,
    /// Bumped on every lease change, unsubscribe and shutdown; drivers wait
    /// on it instead of sleeping, so every wait is cancellable.
    signal: Mutex<u64>,
    wake: Condvar,
    shutdown: AtomicBool,
}

/// The daemon's cloud link. Cheap to clone; all clones share one state.
#[derive(Clone)]
pub struct CloudConversations {
    inner: Arc<Inner>,
}

impl CloudConversations {
    pub fn new(backend: Arc<dyn CloudBackend>) -> Self {
        Self::with_options(backend, ServiceOptions::default())
    }

    pub fn with_options(backend: Arc<dyn CloudBackend>, options: ServiceOptions) -> Self {
        Self {
            inner: Arc::new(Inner {
                backend,
                options,
                lease: Mutex::new(Lease::default()),
                subscriptions: Mutex::new(BTreeMap::new()),
                sink: Mutex::new(None),
                signal: Mutex::new(0),
                wake: Condvar::new(),
                shutdown: AtomicBool::new(false),
            }),
        }
    }

    /// Where events go. Set once by the hosting mux.
    pub fn set_sink(&self, sink: EventSink) {
        *self.inner.sink.lock().unwrap() = Some(sink);
    }

    /// `cloud-session-set`: replaces the lease. Open sockets reconnect with
    /// the new token and resume.
    pub fn set_session(&self, params: SessionParams) -> Result<Value, CloudError> {
        let reply = {
            let mut lease = self.inner.lease.lock().unwrap();
            let session = CloudSession::new(params, lease.generation + 1)?;
            lease.generation = session.generation;
            lease.expiring_sent = false;
            lease.expired_sent = false;
            let reply = json!({
                "state": "active",
                "api_base_url": session.origin(),
                "expires_at": session.expires_at,
            });
            lease.session = Some(session);
            reply
        };
        self.inner.notify();
        Ok(reply)
    }

    /// `cloud-session-clear`.
    pub fn clear_session(&self) -> Value {
        {
            let mut lease = self.inner.lease.lock().unwrap();
            lease.session = None;
            lease.generation += 1;
        }
        self.inner.notify();
        json!({"state": "signed_out"})
    }

    /// `cloud-session-status`. Never returns the token.
    pub fn session_status(&self) -> Value {
        let now = (self.inner.options.now_ms)();
        let lease = self.inner.lease.lock().unwrap();
        match &lease.session {
            None => json!({"state": "signed_out"}),
            Some(session) => json!({
                "state": if session.is_expired(now) { "expired" } else { "active" },
                "api_base_url": session.origin(),
                "expires_at": session.expires_at,
            }),
        }
    }

    /// Reserves one of the daemon's concurrent cloud request slots.
    pub fn begin_request(&self) -> Result<RequestPermit, CloudError> {
        Ok(RequestPermit(()))
    }

    /// `cloud-inbox-list`.
    pub fn inbox_list(
        &self,
        limit: Option<u32>,
        include_archived: bool,
    ) -> Result<Value, CloudError> {
        let limit = limit.unwrap_or(MAX_PAGE);
        if !(1..=MAX_PAGE).contains(&limit) {
            return Err(CloudError::BadRequest(format!("limit must be 1-{MAX_PAGE}")));
        }
        let mut params = json!({"limit": limit});
        if include_archived {
            params["include_archived"] = json!(true);
        }
        let reply = self.post("/v1/read", &read_body("inbox.list", params))?;
        let (value, revision) = read_value(reply)?;
        inbox_list_data(value, revision)
    }

    /// `cloud-conversation-snapshot`.
    pub fn snapshot(&self, conversation: &str, tail: u32) -> Result<Value, CloudError> {
        require_conversation(conversation)?;
        if !(1..=MAX_TAIL).contains(&tail) {
            return Err(CloudError::BadRequest(format!("tail must be 1-{MAX_TAIL}")));
        }
        let body =
            read_body("conversation.snapshot", json!({"conversation": conversation, "tail": tail}));
        let (value, _) = read_value(self.post("/v1/read", &body)?)?;
        snapshot_data(&value)
    }

    /// `cloud-conversation-history`.
    pub fn history(
        &self,
        conversation: &str,
        before_seq: u64,
        limit: u32,
    ) -> Result<Value, CloudError> {
        require_conversation(conversation)?;
        if !(1..=MAX_PAGE).contains(&limit) {
            return Err(CloudError::BadRequest(format!("limit must be 1-{MAX_PAGE}")));
        }
        let body = read_body(
            "conversation.history",
            json!({"conversation": conversation, "before_seq": before_seq, "limit": limit}),
        );
        let (value, _) = read_value(self.post("/v1/read", &body)?)?;
        history_data(value)
    }

    /// `cloud-conversation-op`: forwards one op; never retried here.
    pub fn op(&self, request: &OpRequest) -> Result<Value, CloudError> {
        let body = contract::op_body(request)?;
        mutation_data(self.post("/v1/ops", &body)?)
    }

    /// Validates a command before it leaves the request loop, so shape
    /// errors answer at once and only network work runs elsewhere.
    pub fn check_op(&self, request: &OpRequest) -> Result<(), CloudError> {
        contract::op_body(request).map(|_| ())
    }

    fn post(&self, path: &str, body: &Value) -> Result<HttpReply, CloudError> {
        let session = self.inner.usable_session()?;
        let reply = self
            .inner
            .backend
            .post(
                &session.http_url(path),
                session.bearer(),
                session.client_version.as_deref(),
                body,
            )
            .map_err(|TransportError(detail)| CloudError::Unavailable(detail))?;
        if reply.status == 401 {
            self.inner.emit(CloudEvent::SessionNeeded {
                reason: "unauthenticated",
                expires_at: Some(session.expires_at),
            });
            return Err(CloudError::Unauthenticated);
        }
        Ok(reply)
    }

    /// `cloud-inbox-subscribe` / `cloud-conversation-subscribe` for `client`.
    pub fn subscribe(&self, client: u64, target: Target) -> Result<Value, CloudError> {
        if let Target::Conversation(id) = &target {
            require_conversation(id)?;
        }
        let start = {
            let mut subscriptions = self.inner.subscriptions.lock().unwrap();
            if let Some(subscription) = subscriptions.get_mut(&target) {
                subscription.clients.insert(client);
                subscription.idle_since = None;
                false
            } else {
                let conversations = subscriptions
                    .keys()
                    .filter(|target| matches!(target, Target::Conversation(_)))
                    .count();
                if matches!(target, Target::Conversation(_))
                    && conversations >= self.inner.options.max_conversation_subscriptions
                {
                    return Err(CloudError::daemon_reject(
                        "too_many_subscriptions",
                        "too many cloud conversation subscriptions",
                    ));
                }
                subscriptions.insert(
                    target.clone(),
                    Subscription { clients: BTreeSet::from([client]), idle_since: None },
                );
                true
            }
        };
        if start {
            let inner = self.inner.clone();
            let driver_target = target.clone();
            let spawned = std::thread::Builder::new()
                .name("mux-cloud-stream".into())
                .spawn(move || run_driver(&inner, driver_target));
            if let Err(error) = spawned {
                self.inner.subscriptions.lock().unwrap().remove(&target);
                return Err(CloudError::Unavailable(format!("stream thread: {error}")));
            }
        }
        let mut reply = json!({"state": if self.inner.session_ready() { "connecting" } else { "disconnected" }});
        if let Target::Conversation(id) = &target {
            reply["conversation"] = json!(id);
        }
        Ok(reply)
    }

    /// Ends `client`'s interest in `target`. The socket lingers (conversation)
    /// or closes when no client is left.
    pub fn unsubscribe(&self, client: u64, target: &Target) {
        {
            let mut subscriptions = self.inner.subscriptions.lock().unwrap();
            if let Some(subscription) = subscriptions.get_mut(target)
                && subscription.clients.remove(&client)
                && subscription.clients.is_empty()
            {
                subscription.idle_since = Some(Instant::now());
            }
        }
        self.inner.notify();
    }

    /// Ends every interest of a closed connection.
    pub fn client_closed(&self, client: u64) {
        {
            let mut subscriptions = self.inner.subscriptions.lock().unwrap();
            for subscription in subscriptions.values_mut() {
                if subscription.clients.remove(&client) && subscription.clients.is_empty() {
                    subscription.idle_since = Some(Instant::now());
                }
            }
        }
        self.inner.notify();
    }

    /// Whether `target` still has an upstream driver (tests and diagnostics).
    pub fn has_stream(&self, target: &Target) -> bool {
        self.inner.subscriptions.lock().unwrap().contains_key(target)
    }

    /// Stops every driver; used when the daemon exits.
    pub fn shutdown(&self) {
        self.inner.shutdown.store(true, Ordering::SeqCst);
        self.inner.notify();
    }
}

impl Inner {
    fn emit(&self, event: CloudEvent) {
        let sink = self.sink.lock().unwrap().clone();
        if let Some(sink) = sink {
            sink(event);
        }
    }

    fn notify(&self) {
        *self.signal.lock().unwrap() += 1;
        self.wake.notify_all();
    }

    /// Waits up to `timeout` for a signal newer than `seen`.
    fn wait(&self, seen: u64, timeout: Duration) {
        let guard = self.signal.lock().unwrap();
        if *guard != seen {
            return;
        }
        let _unused = self.wake.wait_timeout_while(guard, timeout, |signal| *signal == seen);
    }

    fn signal_now(&self) -> u64 {
        *self.signal.lock().unwrap()
    }

    fn session_ready(&self) -> bool {
        let now = (self.options.now_ms)();
        self.lease.lock().unwrap().session.as_ref().is_some_and(|session| !session.is_expired(now))
    }

    fn generation(&self) -> u64 {
        self.lease.lock().unwrap().generation
    }

    /// The lease for one call, announcing `expiring` once per lease.
    fn usable_session(&self) -> Result<CloudSession, CloudError> {
        let now = (self.options.now_ms)();
        let (result, event) = {
            let mut lease = self.lease.lock().unwrap();
            match lease.session.clone() {
                None => (
                    Err(CloudError::SignedOut),
                    Some(CloudEvent::SessionNeeded { reason: "missing", expires_at: None }),
                ),
                Some(session) if session.is_expired(now) => (
                    Err(CloudError::SessionExpired),
                    Some(CloudEvent::SessionNeeded {
                        reason: "expired",
                        expires_at: Some(session.expires_at),
                    }),
                ),
                Some(session) => {
                    let event = (session.is_expiring(now) && !lease.expiring_sent).then(|| {
                        lease.expiring_sent = true;
                        CloudEvent::SessionNeeded {
                            reason: "expiring",
                            expires_at: Some(session.expires_at),
                        }
                    });
                    (Ok(session), event)
                }
            }
        };
        if let Some(event) = event {
            self.emit(event);
        }
        result
    }

    /// The lease for an upstream socket. Unlike a command it never announces
    /// `missing` (a socket waits silently for a sign-in) and announces
    /// `expiring` and `expired` once per lease, not once per poll.
    fn stream_session(&self) -> Result<CloudSession, &'static str> {
        let now = (self.options.now_ms)();
        let (result, event) = {
            let mut lease = self.lease.lock().unwrap();
            match lease.session.clone() {
                None => (Err("signed_out"), None),
                Some(session) if session.is_expired(now) => {
                    let event = (!lease.expired_sent).then(|| {
                        lease.expired_sent = true;
                        CloudEvent::SessionNeeded {
                            reason: "expired",
                            expires_at: Some(session.expires_at),
                        }
                    });
                    (Err("unauthenticated"), event)
                }
                Some(session) => {
                    let event = (session.is_expiring(now) && !lease.expiring_sent).then(|| {
                        lease.expiring_sent = true;
                        CloudEvent::SessionNeeded {
                            reason: "expiring",
                            expires_at: Some(session.expires_at),
                        }
                    });
                    (Ok(session), event)
                }
            }
        };
        if let Some(event) = event {
            self.emit(event);
        }
        result
    }

    /// Whether the driver of `target` should stop, removing its entry when
    /// its last subscriber left more than `linger` ago.
    fn retire(&self, target: &Target) -> bool {
        if self.shutdown.load(Ordering::SeqCst) {
            return true;
        }
        let mut subscriptions = self.subscriptions.lock().unwrap();
        let Some(subscription) = subscriptions.get(target) else { return true };
        let expired =
            subscription.idle_since.is_some_and(|since| since.elapsed() >= self.options.linger);
        if subscription.clients.is_empty() && expired {
            subscriptions.remove(target);
            return true;
        }
        false
    }

    /// Time left before an idle subscription retires, capped at `cap`.
    fn idle_wait(&self, target: &Target, cap: Duration) -> Duration {
        let subscriptions = self.subscriptions.lock().unwrap();
        match subscriptions.get(target).and_then(|subscription| subscription.idle_since) {
            Some(since) => self.options.linger.saturating_sub(since.elapsed()).min(cap),
            None => cap,
        }
    }

    fn remove(&self, target: &Target) {
        self.subscriptions.lock().unwrap().remove(target);
    }
}

/// Emits a subscription state only when it changes.
struct StateReporter<'a> {
    inner: &'a Inner,
    target: Target,
    last: Option<(&'static str, Option<&'static str>)>,
}

impl StateReporter<'_> {
    fn report(&mut self, state: &'static str, reason: Option<&'static str>) {
        if self.last == Some((state, reason)) {
            return;
        }
        self.last = Some((state, reason));
        self.inner.emit(CloudEvent::SubscriptionState {
            target: self.target.clone(),
            state,
            reason,
        });
    }
}

/// How a connection ended.
enum Ended {
    Retired,
    Forbidden,
    /// Reconnect at once (the lease changed).
    Reconnect,
    /// Reconnect after the backoff.
    Dropped,
    /// Wait for a new lease (close code 4401).
    Unauthenticated,
}

fn run_driver(inner: &Arc<Inner>, target: Target) {
    let mut stream = StreamState::new(target.clone());
    let mut reporter = StateReporter { inner, target: target.clone(), last: None };
    let mut backoff = inner.options.backoff_min;
    let poll = inner.options.poll;
    loop {
        if inner.retire(&target) {
            break;
        }
        let seen = inner.signal_now();
        let session = match inner.stream_session() {
            Ok(session) => session,
            Err(reason) => {
                reporter.report("disconnected", Some(reason));
                inner.wait(seen, inner.idle_wait(&target, poll));
                continue;
            }
        };
        reporter.report("connecting", None);
        let url = session.ws_url(&target.wire_path());
        let wire = inner.backend.connect(&url, session.bearer(), session.client_version.as_deref());
        let ended = match wire {
            Err(ConnectError::Forbidden) => Ended::Forbidden,
            Err(ConnectError::Unauthenticated) => Ended::Unauthenticated,
            Err(ConnectError::Unavailable(_)) => Ended::Dropped,
            Ok(mut wire) => {
                stream.on_connect();
                pump(
                    inner,
                    &target,
                    &mut stream,
                    &mut reporter,
                    wire.as_mut(),
                    session.generation,
                    &mut backoff,
                )
            }
        };
        match ended {
            Ended::Retired => break,
            Ended::Forbidden => {
                inner.remove(&target);
                reporter.report("closed", Some("forbidden"));
                break;
            }
            Ended::Reconnect => {}
            Ended::Unauthenticated => {
                inner.emit(CloudEvent::SessionNeeded {
                    reason: "unauthenticated",
                    expires_at: Some(session.expires_at),
                });
                reporter.report("disconnected", Some("unauthenticated"));
                // Only a new lease (or unsubscribe or shutdown) helps.
                while inner.generation() == session.generation && !inner.retire(&target) {
                    let seen = inner.signal_now();
                    inner.wait(seen, inner.idle_wait(&target, poll));
                }
            }
            Ended::Dropped => {
                reporter.report("disconnected", Some("unavailable"));
                let until = Instant::now() + backoff;
                while Instant::now() < until
                    && inner.generation() == session.generation
                    && !inner.retire(&target)
                {
                    let seen = inner.signal_now();
                    inner.wait(
                        seen,
                        inner.idle_wait(&target, until.saturating_duration_since(Instant::now())),
                    );
                }
                backoff = (backoff * 2).min(inner.options.backoff_max);
            }
        }
    }
}

fn pump(
    inner: &Inner,
    target: &Target,
    stream: &mut StreamState,
    reporter: &mut StateReporter<'_>,
    wire: &mut dyn CloudWire,
    generation: u64,
    backoff: &mut Duration,
) -> Ended {
    loop {
        if inner.retire(target) {
            return Ended::Retired;
        }
        if inner.generation() != generation {
            return Ended::Reconnect;
        }
        // Announces `expiring` once per lease while a socket is open.
        if inner.stream_session().is_err() {
            return Ended::Reconnect;
        }
        match wire.recv(inner.idle_wait(target, inner.options.poll)) {
            WireRecv::Idle => {}
            WireRecv::Closed { code: Some(4401) } => return Ended::Unauthenticated,
            WireRecv::Closed { .. } => return Ended::Dropped,
            WireRecv::Text(text) => {
                for action in stream.on_text(&text) {
                    match action {
                        StreamAction::Send(frame) => {
                            if wire.send(&frame).is_err() {
                                return Ended::Dropped;
                            }
                        }
                        StreamAction::Emit(event) => inner.emit(event),
                        StreamAction::Live => {
                            *backoff = inner.options.backoff_min;
                            reporter.report("live", None);
                        }
                        StreamAction::Forbidden => return Ended::Forbidden,
                    }
                }
            }
        }
    }
}
