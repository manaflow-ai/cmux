//! The cloud link of one daemon (home-cloud-proxy.md, home-scale.md A7): the
//! session lease, the HTTP calls behind each command, and one shared upstream
//! socket per subscribed target with resume and reconnect.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, PoisonError};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_cloud_wire::SnapshotBackoff;
use serde_json::{Value, json};

use super::CloudError;
use super::contract::{
    self, InboxOpRequest, MAX_PAGE, MAX_TAIL, OpRequest, Target, history_data, inbox_list_data,
    mutation_data, read_body, read_value, requests_list_data, require_agent, require_conversation,
    snapshot_data,
};
use super::session::{CloudSession, SessionParams};
use super::stream::{CloudEvent, StreamAction, StreamState};
use cmux_json::JsonSet as _;

/// One HTTP reply: the status and the JSON body (`Null` when not JSON).
#[derive(Debug, Clone, PartialEq)]
pub struct HttpReply {
    pub status: u16,
    pub body: Value,
}

/// One ranged read of a signed attachment URL.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RangeReply {
    pub status: u16,
    pub content_type: Option<String>,
    /// The whole object's size (from `Content-Range`, else `Content-Length` of a 200).
    pub total: Option<u64>,
    pub body: Vec<u8>,
}

/// The body of an attachment `PUT`: small bytes (a derived image), or a
/// staged file of `len` bytes that the backend streams from disk, so an
/// original of any size never sits in memory.
#[derive(Debug)]
pub enum PutBody {
    Bytes(Vec<u8>),
    File { file: std::fs::File, len: u64 },
}

impl PutBody {
    pub fn len(&self) -> u64 {
        match self {
            Self::Bytes(bytes) => bytes.len() as u64,
            Self::File { len, .. } => *len,
        }
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
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
    /// `POST url` with `authorization: Bearer <bearer>` (no Authorization
    /// header when `bearer` is `None`: a self-hosted server on the tailnet),
    /// the JSON `body` and, when given, `x-cmux-client-version`.
    fn post(
        &self,
        url: &str,
        bearer: Option<&str>,
        client_version: Option<&str>,
        body: &Value,
    ) -> Result<HttpReply, TransportError>;
    /// `GET url` with the bearer (the Chief brain's run reads, plain HTTP
    /// routes outside the op catalog). A backend without it answers that it
    /// cannot.
    fn get(
        &self,
        url: &str,
        bearer: Option<&str>,
        client_version: Option<&str>,
    ) -> Result<HttpReply, TransportError> {
        let _ = (url, bearer, client_version);
        Err(TransportError("this cloud backend sends no GET requests".into()))
    }
    /// Platform REST request with an install bearer supplied by the verified native app.
    /// The concrete backend never follows redirects for this request.
    fn platform(
        &self,
        method: &str,
        url: &str,
        bearer: &str,
        body: &Value,
    ) -> Result<HttpReply, TransportError> {
        let _ = (method, url, bearer, body);
        Err(TransportError("this cloud backend sends no platform requests".into()))
    }
    /// `PUT url` with `headers` and the raw `body`, no bearer: an attachment
    /// upload slot or a presigned object URL is its own credential.
    fn put(
        &self,
        url: &str,
        headers: &[(String, String)],
        body: PutBody,
    ) -> Result<HttpReply, TransportError> {
        let _ = (url, headers, body);
        Err(TransportError("this cloud backend sends no PUT requests".into()))
    }
    /// `GET url` for bytes `offset..offset+length` (one `Range`), no bearer:
    /// a signed attachment URL is its own credential.
    fn get_range(&self, url: &str, offset: u64, length: u64) -> Result<RangeReply, TransportError> {
        let _ = (url, offset, length);
        Err(TransportError("this cloud backend reads no byte ranges".into()))
    }
    /// Opens `url` with subprotocol `cmux.wire.v1` and the bearer in the
    /// `authorization` header (cx-dgsp; legacy subprotocol only for an old
    /// Worker); no Authorization header when `bearer` is `None`.
    fn connect(
        &self,
        url: &str,
        bearer: Option<&str>,
        client_version: Option<&str>,
    ) -> Result<Box<dyn CloudWire>, ConnectError>;
}

/// One reserved cloud request slot, released on drop.
pub struct RequestPermit {
    inner: Arc<Inner>,
}

impl Drop for RequestPermit {
    fn drop(&mut self) {
        self.inner.requests_in_flight.fetch_sub(1, Ordering::SeqCst);
    }
}

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
    /// How a stream asks again for a snapshot that did not decode.
    pub snapshot_backoff: SnapshotBackoff,
    /// API origins beyond the built-in cmux Cloud ones that a lease from a
    /// connection that is not the app may name (`CMUX_CLOUD_API_ORIGINS`).
    pub api_origins: Vec<String>,
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
            api_origins: std::env::var("CMUX_CLOUD_API_ORIGINS")
                .unwrap_or_default()
                .split(',')
                .map(str::trim)
                .filter(|entry| !entry.is_empty())
                .map(str::to_string)
                .collect(),
            snapshot_backoff: SnapshotBackoff::default(),
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
    /// The verified cmux app set the current lease (`cloud-lease-app-only-v1`):
    /// no other connection may replace or clear it.
    app_held: bool,
}

struct Subscription {
    /// The driver thread this entry started (unique per entry): a retired
    /// driver's late cleanup never touches the entry that replaced it.
    driver: u64,
    clients: BTreeSet<u64>,
    idle_since: Option<Instant>,
    /// The shared socket's current state, which a later subscriber is told.
    state: SocketState,
    /// Frames a client asked the driver to send on the socket (`run.live.get`,
    /// `typing`).
    outbox: Vec<String>,
    /// The client whose `cloud-conversation-typing` is on: the indicator is
    /// sent again after a reconnect (the owner turned it off when the old
    /// socket closed), and turned off when that client's connection closes.
    typing_by: Option<u64>,
    /// The clients whose `cloud-conversation-presence` is viewing: the
    /// person views while any does. Sent again after a reconnect, and off
    /// when the last one closes or unsubscribes.
    viewing: BTreeSet<u64>,
    /// The live socket's last `conversation-presence` set (none while no
    /// socket is live), replayed after a subscribe ([`CloudConversations::announce_state`]).
    presence: Option<CloudEvent>,
}

/// One `cloud-subscription-state`: the state, its reason and the account of
/// the lease the socket used.
#[derive(Debug, Clone, PartialEq, Eq)]
struct SocketState {
    state: &'static str,
    reason: Option<&'static str>,
    account: Option<String>,
}

impl SocketState {
    fn event(&self, target: &Target) -> CloudEvent {
        CloudEvent::SubscriptionState {
            target: target.clone(),
            state: self.state,
            reason: self.reason,
            account: self.account.clone(),
        }
    }

    /// The `cloud-*-subscribe` reply.
    fn reply(&self, target: &Target) -> Value {
        let mut reply = json!({"state": self.state});
        if let Some(reason) = self.reason {
            reply.set("reason", json!(reason));
        }
        if let Some(account) = &self.account {
            reply.set("account", json!(account));
        }
        if let Target::Conversation(id) = target {
            reply.set("conversation", json!(id));
        }
        reply
    }
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
    /// Cloud HTTP requests running now (bounded by `max_concurrent_requests`).
    requests_in_flight: AtomicUsize,
    /// Held across each presence cache change or replay and its emit, so the
    /// emits go out in cache order: a replay never follows the socket's empty
    /// set, nor an owner set newer than it. Taken before `subscriptions`; the
    /// sink only queues the event.
    presence_order: Mutex<()>,
    /// The next [`Subscription::driver`].
    next_driver: AtomicU64,
}

/// The daemon's cloud link. Cheap to clone; all clones share one state.
#[derive(Clone)]
pub struct CloudConversations {
    inner: Arc<Inner>,
}

/// Pages `CloudConversations::inbox_list_all` reads at most (200 entries each).
pub const MAX_INBOX_PAGES: usize = 50;
/// Wall time, from the start of the read, after which `inbox_list_all` asks for no
/// further page. With one more page's read (the transport's 20 s request
/// timeout) the read ends inside the app's 30 s Cloud request timeout, so the
/// request slot it holds is never left with a caller that gave up.
pub const INBOX_ALL_BUDGET: Duration = Duration::from_secs(8);
/// The owner's longest `inbox.list` cursor (ops-home-inbox.ts).
const MAX_INBOX_CURSOR: usize = 256;

/// The refusal text of a lease change from a connection that is not the app.
const APP_ONLY_LEASE: &str = "the cloud session lease belongs to the verified cmux app connection; only it may set or clear it";

fn check_lease_holder(lease: &Lease, by_app: bool) -> Result<(), CloudError> {
    if by_app || !lease.app_held || lease.session.is_none() {
        return Ok(());
    }
    Err(CloudError::Rejected {
        code: "forbidden".into(),
        message: APP_ONLY_LEASE.into(),
        retryable: false,
    })
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
                requests_in_flight: AtomicUsize::new(0),
                presence_order: Mutex::new(()),
                next_driver: AtomicU64::new(0),
            }),
        }
    }

    /// Where events go. Set once by the hosting mux.
    pub fn set_sink(&self, sink: EventSink) {
        *self.inner.sink.lock().unwrap_or_else(PoisonError::into_inner) = Some(sink);
    }

    /// `cloud-session-set`: replaces the lease. Open sockets reconnect with
    /// the new token and resume.
    pub fn set_session(&self, params: SessionParams) -> Result<Value, CloudError> {
        self.set_session_by(params, true)
    }

    /// `cloud-session-set` from a connection that is (`by_app`) or is not the
    /// verified cmux app. A lease the app set is the human's: any other
    /// connection is refused until the app clears it.
    pub fn set_session_by(&self, params: SessionParams, by_app: bool) -> Result<Value, CloudError> {
        let reply = {
            let mut lease = self.inner.lease.lock().unwrap_or_else(PoisonError::into_inner);
            check_lease_holder(&lease, by_app)?;
            // A self-hosted server is admitted by its tailnet origin
            // (CloudSession::new); a bearer lease from another connection
            // must name a known cmux Cloud origin.
            if !by_app && params.lease_auth()? == super::session::LeaseAuth::Bearer {
                super::session::check_known_origin(
                    &params.api_base_url,
                    &self.inner.options.api_origins,
                )?;
            }
            let session = CloudSession::new(params, lease.generation + 1)?;
            // A new app lease (sign-in, account switch), not a renewal of the same one:
            // the person's other clients (a page) list the inbox again.
            let fresh = by_app
                && !(lease.app_held
                    && lease.session.as_ref().is_some_and(|old| old.account == session.account));
            let fresh_account = fresh.then(|| session.account.clone());
            lease.generation = session.generation;
            lease.expiring_sent = false;
            lease.expired_sent = false;
            let reply = session.status("active");
            lease.session = Some(session);
            lease.app_held = by_app;
            (reply, fresh_account)
        };
        let (reply, fresh_account) = reply;
        self.inner.notify();
        if let Some(account) = fresh_account {
            self.inner.emit(CloudEvent::InboxReset { seq: 0, account });
        }
        Ok(reply)
    }

    /// `cloud-session-clear`.
    pub fn clear_session(&self) -> Value {
        self.clear_session_by(true).unwrap_or_else(|_| json!({"state": "signed_out"}))
    }

    /// `cloud-session-clear` from a connection that is (`by_app`) or is not
    /// the verified cmux app; refused like `set_session_by`.
    pub fn clear_session_by(&self, by_app: bool) -> Result<Value, CloudError> {
        {
            let mut lease = self.inner.lease.lock().unwrap_or_else(PoisonError::into_inner);
            check_lease_holder(&lease, by_app)?;
            lease.session = None;
            lease.app_held = false;
            lease.generation += 1;
        }
        self.inner.notify();
        Ok(json!({"state": "signed_out"}))
    }

    /// Whether the verified cmux app set the current lease
    /// (`cloud-lease-app-only-v1`): then only the app may use it.
    pub fn app_holds_lease(&self) -> bool {
        let lease = self.inner.lease.lock().unwrap_or_else(PoisonError::into_inner);
        lease.app_held && lease.session.is_some()
    }

    /// `cloud-session-status`. Never returns the token.
    pub fn session_status(&self) -> Value {
        let now = (self.inner.options.now_ms)();
        let lease = self.inner.lease.lock().unwrap_or_else(PoisonError::into_inner);
        match &lease.session {
            None => json!({"state": "signed_out"}),
            Some(session) => {
                session.status(if session.is_expired(now) { "expired" } else { "active" })
            }
        }
    }

    /// Reserves one of the daemon's concurrent cloud request slots.
    /// Over the limit it fails at once with `cloud_unavailable` (retryable),
    /// so a busy client cannot pile up threads or upstream requests.
    pub fn begin_request(&self) -> Result<RequestPermit, CloudError> {
        let limit = self.inner.options.max_concurrent_requests;
        self.inner
            .requests_in_flight
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |running| {
                (running < limit).then_some(running + 1)
            })
            .map_err(|_| {
                CloudError::Unavailable(format!("{limit} cloud requests are already running"))
            })?;
        Ok(RequestPermit { inner: self.inner.clone() })
    }

    /// `cloud-inbox-list`: one page of the inbox, `limit` entries (default
    /// 200) from `cursor` (the owner's `next_cursor` of the page before), with
    /// the owner's `next_cursor` (null on the last page). One page per call,
    /// so every reply is one bounded read; a client pages with the cursor.
    pub fn inbox_list(
        &self,
        limit: Option<u32>,
        include_archived: bool,
        cursor: Option<&str>,
    ) -> Result<Value, CloudError> {
        self.inbox_page(limit.unwrap_or(MAX_PAGE), include_archived, cursor)
    }

    /// The inbox for `home-inbox`'s Cloud rows: every page the owner has,
    /// following `next_cursor`, while `budget` lasts and for at most
    /// `MAX_INBOX_PAGES` pages (`budget` counts from the start of the read). An entry a later page lists again (its
    /// activity moved it while the pages were read) is kept once, where it
    /// was first listed. Any page's failure is the read's. The budget or the
    /// cap ends the read with the pages already read (`next_cursor` then
    /// names where it stopped, else null).
    pub fn inbox_list_all(
        &self,
        include_archived: bool,
        budget: Duration,
    ) -> Result<Value, CloudError> {
        let started = Instant::now();
        let mut entries: Vec<Value> = Vec::new();
        let mut seen: BTreeSet<String> = BTreeSet::new();
        let mut revision = Value::Null;
        let mut cursor: Option<String> = None;
        for page_index in 0..MAX_INBOX_PAGES {
            if page_index > 0 && started.elapsed() >= budget {
                break;
            }
            // Any page's failure is the read's: `home-inbox` answers `unavailable` and the
            // app keeps its last rows, where a partial list would drop the rest.
            let page = self.inbox_page(MAX_PAGE, include_archived, cursor.as_deref())?;
            if page_index == 0 {
                revision = page.get("revision").cloned().unwrap_or(Value::String(String::new()));
            }
            for entry in page.get("entries").and_then(Value::as_array).into_iter().flatten() {
                let id = entry.get("conversation").and_then(Value::as_str).map(str::to_owned);
                if id.is_none_or(|id| seen.insert(id)) {
                    entries.push(entry.clone());
                }
            }
            match page.get("next_cursor").and_then(Value::as_str) {
                // A cursor that does not move would read the same page forever.
                Some(next) if Some(next) != cursor.as_deref() => cursor = Some(next.to_owned()),
                _ => {
                    return Ok(
                        json!({"entries": entries, "revision": revision, "next_cursor": null}),
                    );
                }
            }
        }
        Ok(json!({"entries": entries, "revision": revision, "next_cursor": cursor}))
    }

    fn inbox_page(
        &self,
        limit: u32,
        include_archived: bool,
        cursor: Option<&str>,
    ) -> Result<Value, CloudError> {
        if !(1..=MAX_PAGE).contains(&limit) {
            return Err(CloudError::BadRequest(format!("limit must be 1-{MAX_PAGE}")));
        }
        let mut params = json!({"limit": limit});
        if include_archived {
            params.set("include_archived", json!(true));
        }
        if let Some(cursor) = cursor {
            if cursor.len() > MAX_INBOX_CURSOR {
                return Err(CloudError::BadRequest(format!(
                    "cursor is over {MAX_INBOX_CURSOR} bytes"
                )));
            }
            params.set("cursor", json!(cursor));
        }
        let reply = self.post("/v1/read", &read_body("inbox.list", params))?;
        let (value, revision) = read_value(reply)?;
        inbox_list_data(value, revision)
    }

    /// `cloud-requests-list`: the lease person's open message requests
    /// (`home.requests.list`), rows without a valid conversation id dropped.
    pub fn requests_list(&self) -> Result<Value, CloudError> {
        let reply = self.post("/v1/read", &read_body("home.requests.list", json!({})))?;
        let (value, _revision) = read_value(reply)?;
        requests_list_data(value)
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

    /// `cloud-conversation-thread`: `conversation.thread`, the owner's value
    /// unchanged (root, replies, has_more, thread).
    pub fn thread(
        &self,
        conversation: &str,
        root: &str,
        after_seq: Option<u64>,
        limit: Option<u32>,
    ) -> Result<Value, CloudError> {
        require_conversation(conversation)?;
        if root.is_empty() || root.len() > 128 {
            return Err(CloudError::BadRequest("root must be a message id".into()));
        }
        let mut params = json!({"conversation": conversation, "root": root});
        if let Some(after_seq) = after_seq {
            params.set("after_seq", json!(after_seq));
        }
        if let Some(limit) = limit {
            if !(1..=MAX_PAGE).contains(&limit) {
                return Err(CloudError::BadRequest(format!("limit must be 1-{MAX_PAGE}")));
            }
            params.set("limit", json!(limit));
        }
        let (value, _) =
            read_value(self.post("/v1/read", &read_body("conversation.thread", params))?)?;
        Ok(value)
    }

    /// `cloud-participant-avatar-get`: a Cloud participant's picture (the
    /// owner's `participant.avatar.get`: `{participant_id, avatar}`, the
    /// avatar with its base64 `data`, or null).
    pub fn participant_avatar(
        &self,
        participant: &str,
        conversation: Option<&str>,
    ) -> Result<Value, CloudError> {
        let valid = ["user_", "agent_"].iter().any(|prefix| {
            participant.strip_prefix(prefix).is_some_and(|rest| {
                (1..=64).contains(&rest.len())
                    && rest.bytes().all(|b| b.is_ascii_alphanumeric() || b"_.-".contains(&b))
            })
        });
        if !valid {
            return Err(CloudError::BadRequest(format!(
                "participant {participant:?} is not a person or Chief id"
            )));
        }
        let mut params = json!({"participant_id": participant});
        if let Some(conversation) = conversation {
            if !contract::valid_conversation_id(conversation) {
                return Err(CloudError::BadRequest(format!(
                    "conversation {conversation:?} is not a conversation id"
                )));
            }
            params.set("conversation", json!(conversation));
        }
        let body = read_body("participant.avatar.get", params);
        let (value, _) = read_value(self.post("/v1/read", &body)?)?;
        Ok(value)
    }

    /// The account (JWT `sub`) and Stack project (JWT `aud`) of the current
    /// person's lease, when its token carries both and is no chief token:
    /// the inputs of the person's Worker user id. Never the token.
    pub fn lease_person(&self) -> Option<(String, String)> {
        let lease = self.inner.lease.lock().unwrap_or_else(PoisonError::into_inner);
        let session = lease.session.as_ref()?;
        if session.agent.is_some() || session.is_tailscale() {
            return None;
        }
        Some((session.account.clone()?, session.audience.clone()?))
    }

    /// The origin and the person's user id (once `cloud-selfhost-info`
    /// learned it) of a self-hosted lease (`auth: "tailscale"`); `None` for
    /// a bearer lease or no lease.
    pub fn lease_selfhost(&self) -> Option<(String, Option<String>)> {
        let lease = self.inner.lease.lock().unwrap_or_else(PoisonError::into_inner);
        let session = lease.session.as_ref().filter(|session| session.is_tailscale())?;
        Some((session.origin().to_string(), session.account.clone()))
    }

    /// `cloud-selfhost-info`: `GET /v1/selfhost/info` of the self-hosted
    /// server (no Authorization header: it identifies the caller by
    /// Tailscale), `{kind: "selfhost", user_id, login, display_name,
    /// server_name}`. The person's `user_id` becomes the lease's account, so
    /// every later event is tagged with it; open sockets reconnect to carry
    /// it. Refused (`not_selfhost`) for a bearer lease.
    pub fn selfhost_info(&self) -> Result<Value, CloudError> {
        let session = self.inner.usable_session()?;
        if !session.is_tailscale() {
            return Err(CloudError::daemon_reject(
                "not_selfhost",
                "cloud-selfhost-info needs a self-hosted lease (auth \"tailscale\")",
            ));
        }
        let reply = self.get("/v1/selfhost/info")?;
        let not_selfhost =
            || CloudError::Unavailable("the server is not a cmux self-hosted server".into());
        if reply.status != 200 {
            return Err(match reply.status {
                404 => not_selfhost(),
                status => CloudError::Unavailable(format!("selfhost info answered HTTP {status}")),
            });
        }
        let body = &reply.body;
        let text = |name: &str| -> Option<String> {
            body.get(name)
                .and_then(Value::as_str)
                .filter(|value| value.len() <= 256)
                .map(str::to_string)
        };
        let user = text("user_id").filter(|user| valid_selfhost_user(user));
        let (Some("selfhost"), Some(user)) = (body.get("kind").and_then(Value::as_str), user)
        else {
            return Err(not_selfhost());
        };
        let mut info = json!({"kind": "selfhost", "user_id": user});
        for field in ["login", "display_name", "server_name"] {
            if let Some(value) = text(field) {
                info[field] = json!(value);
            }
        }
        let changed = {
            let mut lease = self.inner.lease.lock().unwrap_or_else(PoisonError::into_inner);
            let generation = lease.generation;
            match lease.session.as_mut() {
                Some(current)
                    if generation == session.generation
                        && current.is_tailscale()
                        && current.account.as_deref() != Some(user.as_str()) =>
                {
                    current.account = Some(user);
                    current.generation = generation + 1;
                    lease.generation = generation + 1;
                    true
                }
                _ => false,
            }
        };
        if changed {
            self.inner.notify();
        }
        Ok(info)
    }

    /// The leased chief's wake queue (`cloud-mux-subscribe`): the agent is
    /// the lease token's `agt` claim, so a client can never name another
    /// chief's queue. Refused for a person's session token.
    pub fn mux_target(&self) -> Result<Target, CloudError> {
        self.lease_agent().map(Target::Mux)
    }

    fn lease_agent(&self) -> Result<String, CloudError> {
        let session = self.inner.usable_session()?;
        session.agent.ok_or_else(|| {
            CloudError::daemon_reject(
                "mux_needs_chief",
                "the wake queue needs a chief token (cloud-session-set with the chief's token)",
            )
        })
    }

    /// `cloud-mux-ack`: the brain handled the wakes of `conversation` up to
    /// `seq`. `mux.ack` for the lease's own chief; the idempotency key names
    /// the wake row (`<conversation>:<seq>`), so a repeated ack is a replay.
    /// No `origin`: the Worker's origin schema has no agent value, and the
    /// chief is the token's `agt` claim (cx-59n8.17).
    pub fn mux_ack(&self, conversation: &str, seq: u64) -> Result<Value, CloudError> {
        require_conversation(conversation)?;
        let agent = self.lease_agent()?;
        let body = json!({
            "op": "mux.ack",
            "params": {"agent": agent, "conversation": conversation, "seq": seq},
            "idempotency_key": format!("mux-ack:{conversation}:{seq}"),
        });
        mutation_data(self.post("/v1/ops", &body)?)
    }

    /// `cloud-conversation-op`: forwards one op; never retried here.
    pub fn op(&self, request: &OpRequest) -> Result<Value, CloudError> {
        let body = contract::op_body(request)?;
        mutation_data(self.post("/v1/ops", &body)?)
    }

    /// `cloud-inbox-op`: the person's own pin or "marked unread" of one
    /// conversation (UserDO `inbox.pin`, `inbox.mark_unread`); the reply's
    /// `value` is the inbox entry. Never retried here.
    pub fn inbox_op(&self, request: &InboxOpRequest) -> Result<Value, CloudError> {
        let body = contract::inbox_op_body(request)?;
        mutation_data(self.post("/v1/ops", &body)?)
    }

    /// Validates a `cloud-inbox-op` before it leaves the request loop.
    pub fn check_inbox_op(&self, request: &InboxOpRequest) -> Result<(), CloudError> {
        contract::inbox_op_body(request).map(|_| ())
    }

    /// Validates a command before it leaves the request loop, so shape
    /// errors answer at once and only network work runs elsewhere.
    pub fn check_op(&self, request: &OpRequest) -> Result<(), CloudError> {
        contract::op_body(request).map(|_| ())
    }

    /// `cloud-conversation-runs`: a Chief's runs in a conversation, newest
    /// first (`GET /v1/chiefs/<agent>/runs`, members only), the owner's value
    /// unchanged (`runs`, `has_more`).
    pub fn chief_runs(
        &self,
        agent: &str,
        conversation: &str,
        before: Option<u64>,
        limit: Option<u32>,
    ) -> Result<Value, CloudError> {
        require_conversation(conversation)?;
        require_agent(agent)?;
        let mut path = format!("/v1/chiefs/{agent}/runs?conversation={conversation}");
        if let Some(before) = before {
            path.push_str(&format!("&before={before}"));
        }
        if let Some(limit) = limit {
            if !(1..=100).contains(&limit) {
                return Err(CloudError::BadRequest("limit must be 1-100".into()));
            }
            path.push_str(&format!("&limit={limit}"));
        }
        let (value, _) = read_value(self.get(&path)?)?;
        Ok(value)
    }

    /// `cloud-conversation-run`: one run of a Chief and its steps after
    /// `after_seq` (`GET /v1/chiefs/<agent>/runs/<run>`), the owner's value
    /// unchanged (`run`, `steps`, `has_more`).
    pub fn chief_run(
        &self,
        agent: &str,
        conversation: &str,
        run: &str,
        after_seq: Option<u64>,
    ) -> Result<Value, CloudError> {
        require_conversation(conversation)?;
        require_agent(agent)?;
        // The brain's run ids (`run_<n>`, CHIEF_BRAIN_PATH): never a dot segment in the path.
        let valid_run = run
            .strip_prefix("run_")
            .is_some_and(|n| (1..=15).contains(&n.len()) && n.bytes().all(|b| b.is_ascii_digit()));
        if !valid_run {
            return Err(CloudError::BadRequest("run must be a run id".into()));
        }
        let mut path = format!("/v1/chiefs/{agent}/runs/{run}?conversation={conversation}");
        if let Some(after_seq) = after_seq {
            path.push_str(&format!("&after_seq={after_seq}"));
        }
        let (value, _) = read_value(self.get(&path)?)?;
        Ok(value)
    }

    fn get(&self, path: &str) -> Result<HttpReply, CloudError> {
        let session = self.inner.usable_session()?;
        let reply = self
            .inner
            .backend
            .get(&session.http_url(path), session.bearer(), session.client_version.as_deref())
            .map_err(|TransportError(detail)| CloudError::Unavailable(detail))?;
        // A self-hosted server refuses a login it does not admit: no Stack
        // lease would help, so nothing is asked for.
        if reply.status == 401 && session.is_tailscale() {
            return Err(CloudError::Unauthenticated);
        }
        if reply.status == 401 {
            self.inner.emit(CloudEvent::SessionNeeded {
                reason: "unauthenticated",
                expires_at: Some(session.expires_at),
            });
            return Err(CloudError::Unauthenticated);
        }
        Ok(reply)
    }

    /// The lease's API origin (`https://host[:port]`), for checking URLs the owner returns.
    pub(crate) fn api_origin(&self) -> Result<String, CloudError> {
        Ok(self.inner.usable_session()?.http_url(""))
    }

    pub(crate) fn backend(&self) -> &Arc<dyn CloudBackend> {
        &self.inner.backend
    }

    pub(crate) fn post(&self, path: &str, body: &Value) -> Result<HttpReply, CloudError> {
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
        if reply.status == 401 && session.is_tailscale() {
            return Err(CloudError::Unauthenticated);
        }
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
        // A new socket starts `connecting` (or `disconnected` without a
        // usable lease); its driver reports every later change.
        let initial = self.inner.initial_state();
        let (start, reply) = {
            let mut subscriptions =
                self.inner.subscriptions.lock().unwrap_or_else(PoisonError::into_inner);
            if let Some(subscription) = subscriptions.get_mut(&target) {
                subscription.clients.insert(client);
                subscription.idle_since = None;
                (None, subscription.state.reply(&target))
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
                let reply = initial.reply(&target);
                let driver = self.inner.next_driver.fetch_add(1, Ordering::Relaxed);
                subscriptions.insert(
                    target.clone(),
                    Subscription {
                        driver,
                        clients: BTreeSet::from([client]),
                        idle_since: None,
                        state: initial,
                        outbox: Vec::new(),
                        typing_by: None,
                        viewing: BTreeSet::new(),
                        presence: None,
                    },
                );
                (Some(driver), reply)
            }
        };
        if let Some(driver) = start {
            let inner = self.inner.clone();
            let driver_target = target.clone();
            let spawned = std::thread::Builder::new()
                .name("mux-cloud-stream".into())
                .spawn(move || run_driver(&inner, driver_target, driver));
            if let Err(error) = spawned {
                self.inner
                    .subscriptions
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .remove(&target);
                return Err(CloudError::Unavailable(format!("stream thread: {error}")));
            }
        }
        Ok(reply)
    }

    /// `cloud-conversation-live` (`chief-live-v1`): asks the conversation's
    /// owner for its `run.live` snapshot on the shared socket
    /// (`run.live.get`); the answer arrives as a `cloud-conversation-live`
    /// event to every subscriber. Only a subscriber of the conversation asks;
    /// while the socket is down the request waits for it (the owner also sends
    /// the snapshot on every join).
    pub fn request_live(&self, client: u64, conversation: &str) -> Result<Value, CloudError> {
        require_conversation(conversation)?;
        let target = Target::Conversation(conversation.to_string());
        let mut subscriptions =
            self.inner.subscriptions.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(subscription) = subscriptions
            .get_mut(&target)
            .filter(|subscription| subscription.clients.contains(&client))
        else {
            return Err(CloudError::daemon_reject(
                "not_subscribed",
                "subscribe to the cloud conversation first",
            ));
        };
        let frame =
            json!({"t": "run.live.get", "type": "run.live.get", "conversation": conversation})
                .to_string();
        if !subscription.outbox.contains(&frame) {
            subscription.outbox.push(frame);
        }
        Ok(subscription.state.reply(&target))
    }

    /// `cloud-conversation-typing` (`cloud-conversation-typing-v1`): the
    /// lease's participant is typing (`on`) or stopped, as the owner's
    /// ephemeral `typing {on, conversation}` frame on the conversation's
    /// shared socket (the owner's `onFrame`, conversation-do.ts); the owner
    /// broadcasts it as `conversation-typing` and turns it off when the socket
    /// closes. Any client of this daemon may send it while some client
    /// subscribes the conversation (a Chief brain reads and writes on two
    /// connections), else `not_subscribed`. The newest state replaces one
    /// that has not gone out yet; it goes out once the socket is live, again
    /// after a reconnect while on, and off when `client` closes while on.
    pub fn typing(&self, client: u64, conversation: &str, on: bool) -> Result<Value, CloudError> {
        require_conversation(conversation)?;
        let target = Target::Conversation(conversation.to_string());
        let mut subscriptions =
            self.inner.subscriptions.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(subscription) =
            subscriptions.get_mut(&target).filter(|subscription| !subscription.clients.is_empty())
        else {
            return Err(CloudError::daemon_reject(
                "not_subscribed",
                "subscribe to the cloud conversation first",
            ));
        };
        subscription.typing_by = on.then_some(client);
        queue_typing(subscription, conversation, on);
        Ok(subscription.state.reply(&target))
    }

    /// `cloud-conversation-presence` (`cloud-conversation-presence-v1`):
    /// `client` views the conversation (`viewing`) or stopped, as the
    /// owner's ephemeral `presence.set {conversation, viewing}` frame on the
    /// shared socket; the person views while any client of this daemon
    /// does, so only a change of that goes out. Like `typing`: while some
    /// client subscribes the conversation (else `not_subscribed`), the
    /// newest state replaces one not yet sent, it goes out again after a
    /// reconnect while viewing, and off when the last viewing client
    /// closes or unsubscribes.
    pub fn presence(
        &self,
        client: u64,
        conversation: &str,
        viewing: bool,
    ) -> Result<Value, CloudError> {
        require_conversation(conversation)?;
        let target = Target::Conversation(conversation.to_string());
        let mut subscriptions =
            self.inner.subscriptions.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(subscription) =
            subscriptions.get_mut(&target).filter(|subscription| !subscription.clients.is_empty())
        else {
            return Err(CloudError::daemon_reject(
                "not_subscribed",
                "subscribe to the cloud conversation first",
            ));
        };
        let was_viewing = !subscription.viewing.is_empty();
        if viewing {
            subscription.viewing.insert(client);
        } else {
            subscription.viewing.remove(&client);
        }
        let now_viewing = !subscription.viewing.is_empty();
        if was_viewing != now_viewing {
            queue_presence(subscription, conversation, viewing);
        }
        Ok(subscription.state.reply(&target))
    }

    /// Emits `target`'s current socket state. The daemon calls it after it
    /// sent a subscribe reply: replies and events travel on different queues
    /// of a connection, so a change that raced the reply could otherwise
    /// arrive before it and leave the client on the reply's older state.
    /// The live socket's last presence set follows, so a page that lost
    /// events and subscribes again has the current set without a change.
    pub fn announce_state(&self, target: &Target) {
        let _order = self.inner.presence_order.lock().unwrap_or_else(PoisonError::into_inner);
        let events = self
            .inner
            .subscriptions
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(target)
            .map(|subscription| {
                // Only a live socket's set: a socket that is going away has none to tell.
                // `presence_order` orders this replay with the socket's end (which clears
                // the cache and emits the empty set) and with a newer owner set.
                let live = subscription.state.state == "live";
                (subscription.state.event(target), subscription.presence.clone().filter(|_| live))
            });
        if let Some((state, presence)) = events {
            self.inner.emit(state);
            if let Some(presence) = presence {
                self.inner.emit(presence);
            }
        }
    }

    /// Ends `client`'s interest in `target`. The socket lingers (conversation)
    /// or closes when no client is left.
    pub fn unsubscribe(&self, client: u64, target: &Target) {
        {
            let mut subscriptions =
                self.inner.subscriptions.lock().unwrap_or_else(PoisonError::into_inner);
            if let Some(subscription) = subscriptions.get_mut(target) {
                if subscription.clients.remove(&client) && subscription.clients.is_empty() {
                    subscription.idle_since = Some(Instant::now());
                }
                stop_viewing(subscription, target, client);
            }
        }
        self.inner.notify();
    }

    /// Ends every interest of a closed connection.
    pub fn client_closed(&self, client: u64) {
        {
            let mut subscriptions =
                self.inner.subscriptions.lock().unwrap_or_else(PoisonError::into_inner);
            for (target, subscription) in subscriptions.iter_mut() {
                if subscription.clients.remove(&client) && subscription.clients.is_empty() {
                    subscription.idle_since = Some(Instant::now());
                }
                // Its indicator ends with it (another subscriber may keep
                // the socket, so the owner's close-time off would not come).
                if subscription.typing_by == Some(client)
                    && let Target::Conversation(conversation) = target
                {
                    subscription.typing_by = None;
                    queue_typing(subscription, conversation, false);
                }
                stop_viewing(subscription, target, client);
            }
        }
        self.inner.notify();
    }

    /// Whether a connection (`is_app`: the verified cmux app) receives cloud
    /// events. While the app holds the lease, its events are the human's:
    /// only the app gets them. Without an app lease (a headless brain's own
    /// daemon, which reads events on a second connection) every trusted
    /// local stream does, as before.
    pub fn delivers_to(&self, is_app: bool) -> bool {
        is_app || !self.app_holds_lease()
    }

    /// Whether `target` still has an upstream driver (tests and diagnostics).
    pub fn has_stream(&self, target: &Target) -> bool {
        self.inner.subscriptions.lock().unwrap_or_else(PoisonError::into_inner).contains_key(target)
    }

    /// Stops every driver; used when the daemon exits.
    pub fn shutdown(&self) {
        self.inner.shutdown.store(true, Ordering::SeqCst);
        self.inner.notify();
    }
}

impl Inner {
    fn emit(&self, event: CloudEvent) {
        let sink = self.sink.lock().unwrap_or_else(PoisonError::into_inner).clone();
        if let Some(sink) = sink {
            sink(event);
        }
    }

    fn notify(&self) {
        *self.signal.lock().unwrap_or_else(PoisonError::into_inner) += 1;
        self.wake.notify_all();
    }

    /// Waits up to `timeout` for a signal newer than `seen`.
    fn wait(&self, seen: u64, timeout: Duration) {
        let guard = self.signal.lock().unwrap_or_else(PoisonError::into_inner);
        if *guard != seen {
            return;
        }
        let _unused = self.wake.wait_timeout_while(guard, timeout, |signal| *signal == seen);
    }

    fn signal_now(&self) -> u64 {
        *self.signal.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The state a socket that has not run yet reports first.
    fn initial_state(&self) -> SocketState {
        let now = (self.options.now_ms)();
        let lease = self.lease.lock().unwrap_or_else(PoisonError::into_inner);
        match &lease.session {
            None => {
                SocketState { state: "disconnected", reason: Some("signed_out"), account: None }
            }
            Some(session) if session.is_expired(now) => SocketState {
                state: "disconnected",
                reason: Some("unauthenticated"),
                account: session.account.clone(),
            },
            Some(session) => {
                SocketState { state: "connecting", reason: None, account: session.account.clone() }
            }
        }
    }

    /// The account of the current lease, expired or not.
    fn lease_account(&self) -> Option<String> {
        self.lease
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .session
            .as_ref()
            .and_then(|session| session.account.clone())
    }

    fn generation(&self) -> u64 {
        self.lease.lock().unwrap_or_else(PoisonError::into_inner).generation
    }

    /// The lease for one call, announcing `expiring` once per lease.
    fn usable_session(&self) -> Result<CloudSession, CloudError> {
        let now = (self.options.now_ms)();
        let (result, event) = {
            let mut lease = self.lease.lock().unwrap_or_else(PoisonError::into_inner);
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
            let mut lease = self.lease.lock().unwrap_or_else(PoisonError::into_inner);
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
        let mut subscriptions = self.subscriptions.lock().unwrap_or_else(PoisonError::into_inner);
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
    /// Unix milliseconds as the mirror counts them.
    fn now(&self) -> i64 {
        i64::try_from((self.options.now_ms)()).unwrap_or(i64::MAX)
    }

    fn idle_wait(&self, target: &Target, cap: Duration) -> Duration {
        let subscriptions = self.subscriptions.lock().unwrap_or_else(PoisonError::into_inner);
        match subscriptions.get(target).and_then(|subscription| subscription.idle_since) {
            Some(since) => self.options.linger.saturating_sub(since.elapsed()).min(cap),
            None => cap,
        }
    }

    /// A socket of `target` went live: an indicator that is on, and the
    /// person's viewing, go out again (the owner ended them when the
    /// previous socket closed).
    fn resend_ephemeral(&self, target: &Target) {
        let Target::Conversation(conversation) = target else { return };
        let mut subscriptions = self.subscriptions.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(subscription) = subscriptions.get_mut(target) else { return };
        if subscription.typing_by.is_some() {
            queue_typing(subscription, conversation, true);
        }
        if !subscription.viewing.is_empty() {
            queue_presence(subscription, conversation, true);
        }
    }

    /// The live socket's new owner set of `target`: kept for later
    /// subscribers and emitted, in order with replays (`presence_order`).
    /// A driver whose entry is gone or replaced shows nothing.
    fn show_presence(&self, target: &Target, driver: u64, event: CloudEvent) {
        let _order = self.presence_order.lock().unwrap_or_else(PoisonError::into_inner);
        if self.keep_presence(target, driver, Some(event.clone())) == Kept::Mine {
            self.emit(event);
        }
    }

    /// `driver`'s socket of `target` ended: nothing is kept, and the set it
    /// showed empties (`ended`), in order with replays (`presence_order`). A
    /// driver that retired after its entry was replaced keeps its hands off
    /// the replacement's set, and empties the clients only while the
    /// replacement has shown none.
    fn end_presence(&self, target: &Target, driver: u64, ended: Option<CloudEvent>) {
        let _order = self.presence_order.lock().unwrap_or_else(PoisonError::into_inner);
        if self.keep_presence(target, driver, None) == Kept::Replaced {
            return;
        }
        if let Some(event) = ended {
            self.emit(event);
        }
    }

    /// Keeps `target`'s last presence set for later subscribers (`None`: its
    /// socket is no longer live), when the entry is still `driver`'s.
    fn keep_presence(&self, target: &Target, driver: u64, presence: Option<CloudEvent>) -> Kept {
        let mut subscriptions = self.subscriptions.lock().unwrap_or_else(PoisonError::into_inner);
        match subscriptions.get_mut(target) {
            Some(subscription) if subscription.driver == driver => {
                subscription.presence = presence;
                Kept::Mine
            }
            Some(subscription) if subscription.presence.is_some() => Kept::Replaced,
            _ => Kept::Gone,
        }
    }

    /// The frames clients asked to send on `target`'s socket, taken.
    fn take_outbox(&self, target: &Target) -> Vec<String> {
        let mut subscriptions = self.subscriptions.lock().unwrap_or_else(PoisonError::into_inner);
        subscriptions.get_mut(target).map(|s| std::mem::take(&mut s.outbox)).unwrap_or_default()
    }

    fn remove(&self, target: &Target) {
        self.subscriptions.lock().unwrap_or_else(PoisonError::into_inner).remove(target);
    }
}

/// Whose entry [`Inner::keep_presence`] found: the driver's own, a
/// replacement that has shown a set, or none (gone, or a replacement that
/// has shown nothing yet).
#[derive(Debug, PartialEq, Eq)]
enum Kept {
    Mine,
    Replaced,
    Gone,
}

/// Records the shared socket's state for later subscribers and emits it to
/// subscribers whenever it changes.
struct StateReporter<'a> {
    inner: &'a Inner,
    target: Target,
    /// The driver it reports for ([`Subscription::driver`]).
    driver: u64,
    last: Option<SocketState>,
}

impl StateReporter<'_> {
    fn report(&mut self, state: &'static str, reason: Option<&'static str>, account: Option<&str>) {
        let next = SocketState { state, reason, account: account.map(str::to_string) };
        if self.last.as_ref() == Some(&next) {
            return;
        }
        if let Some(subscription) = self
            .inner
            .subscriptions
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get_mut(&self.target)
        {
            subscription.state = next.clone();
        }
        self.inner.emit(next.event(&self.target));
        self.last = Some(next);
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

/// Queues the owner's `typing` frame; the outbox holds at most one, the
/// newest state.
fn queue_typing(subscription: &mut Subscription, conversation: &str, on: bool) {
    subscription.outbox.retain(|frame| {
        !serde_json::from_str::<Value>(frame).is_ok_and(|frame| frame["t"] == "typing")
    });
    subscription
        .outbox
        .push(json!({"t": "typing", "on": on, "conversation": conversation}).to_string());
}

/// Queues the owner's `presence.set` frame; the outbox holds at most one,
/// the newest state.
fn queue_presence(subscription: &mut Subscription, conversation: &str, viewing: bool) {
    subscription.outbox.retain(|frame| {
        !serde_json::from_str::<Value>(frame).is_ok_and(|frame| frame["t"] == "presence.set")
    });
    subscription.outbox.push(
        json!({"t": "presence.set", "conversation": conversation, "viewing": viewing}).to_string(),
    );
}

/// `client` no longer views `target`: the person stops viewing when it was
/// the last (another subscriber may keep the socket open).
fn stop_viewing(subscription: &mut Subscription, target: &Target, client: u64) {
    if let Target::Conversation(conversation) = target
        && subscription.viewing.remove(&client)
        && subscription.viewing.is_empty()
    {
        queue_presence(subscription, conversation, false);
    }
}

fn run_driver(inner: &Arc<Inner>, target: Target, driver: u64) {
    let mut stream = StreamState::new(target.clone(), inner.options.snapshot_backoff);
    let mut reporter = StateReporter { inner, target: target.clone(), driver, last: None };
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
                reporter.report("disconnected", Some(reason), inner.lease_account().as_deref());
                inner.wait(seen, inner.idle_wait(&target, poll));
                continue;
            }
        };
        let account = session.account.as_deref();
        reporter.report("connecting", None, account);
        let url = session.ws_url(&target.wire_path());
        let wire = inner.backend.connect(&url, session.bearer(), session.client_version.as_deref());
        let ended = match wire {
            Err(ConnectError::Forbidden) => Ended::Forbidden,
            Err(ConnectError::Unauthenticated) => Ended::Unauthenticated,
            Err(ConnectError::Unavailable(_)) => Ended::Dropped,
            Ok(mut wire) => {
                stream.on_connect();
                let ended = pump(
                    inner,
                    &target,
                    &mut stream,
                    &mut reporter,
                    wire.as_mut(),
                    &session,
                    &mut backoff,
                );
                // The owner's `off` for anyone still typing could only come
                // on this socket.
                for event in stream.typing_ended() {
                    inner.emit(event.with_account(account));
                }
                // The owner sends who views again only to the next socket.
                inner.end_presence(
                    &target,
                    driver,
                    stream.presence_ended().map(|event| event.with_account(account)),
                );
                ended
            }
        };
        match ended {
            Ended::Retired => break,
            Ended::Forbidden => {
                reporter.report("closed", Some("forbidden"), account);
                inner.remove(&target);
                break;
            }
            Ended::Reconnect => {}
            // A self-hosted server that does not admit this login: no lease
            // to ask for; try again after the backoff (the owner may admit it).
            Ended::Unauthenticated if session.is_tailscale() => {
                reporter.report("disconnected", Some("unauthenticated"), account);
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
            Ended::Unauthenticated => {
                inner.emit(CloudEvent::SessionNeeded {
                    reason: "unauthenticated",
                    expires_at: Some(session.expires_at),
                });
                reporter.report("disconnected", Some("unauthenticated"), account);
                // Only a new lease (or unsubscribe or shutdown) helps.
                while inner.generation() == session.generation && !inner.retire(&target) {
                    let seen = inner.signal_now();
                    inner.wait(seen, inner.idle_wait(&target, poll));
                }
            }
            Ended::Dropped => {
                reporter.report("disconnected", Some("unavailable"), account);
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
    session: &CloudSession,
    backoff: &mut Duration,
) -> Ended {
    let account = session.account.as_deref();
    loop {
        if inner.retire(target) {
            return Ended::Retired;
        }
        if inner.generation() != session.generation {
            return Ended::Reconnect;
        }
        // Announces `expiring` once per lease while a socket is open.
        if inner.stream_session().is_err() {
            return Ended::Reconnect;
        }
        // A client's request on the socket (`run.live.get`, `typing`,
        // `presence.set`) goes out once the stream is live; a failed send
        // drops the socket, and the owner's join snapshot answers instead.
        if stream.is_live() {
            for frame in inner.take_outbox(target) {
                if wire.send(&frame).is_err() {
                    return Ended::Dropped;
                }
            }
        }
        let now = inner.now();
        // A snapshot that did not decode is asked for again when its backoff ends.
        for action in stream.snapshot_retry_due(now) {
            if let StreamAction::Send(frame) = action
                && wire.send(&frame).is_err()
            {
                return Ended::Dropped;
            }
        }
        let mut wait = inner.idle_wait(target, inner.options.poll);
        if let Some(at) = stream.snapshot_retry_at() {
            let until = u64::try_from(at.saturating_sub(now)).unwrap_or(0);
            wait = wait.min(Duration::from_millis(until));
        }
        match wire.recv(wait) {
            WireRecv::Idle => {}
            WireRecv::Closed { code: Some(4401) } => return Ended::Unauthenticated,
            WireRecv::Closed { .. } => return Ended::Dropped,
            WireRecv::Text(text) => {
                for action in stream.on_text(&text, inner.now()) {
                    match action {
                        StreamAction::Send(frame) => {
                            if wire.send(&frame).is_err() {
                                return Ended::Dropped;
                            }
                        }
                        StreamAction::Emit(event) => {
                            let event = event.with_account(account);
                            if matches!(event, CloudEvent::Presence { .. }) {
                                inner.show_presence(target, reporter.driver, event);
                            } else {
                                inner.emit(event);
                            }
                        }
                        StreamAction::Live => {
                            reporter.report("live", None, account);
                            inner.resend_ephemeral(target);
                        }
                        StreamAction::Drop => return Ended::Dropped,
                        StreamAction::Forbidden => return Ended::Forbidden,
                    }
                }
                // The backoff resets only when the stream works: a snapshot or
                // an event reached clients and no snapshot is failing. A
                // welcome alone, or a snapshot that keeps failing, keeps it,
                // so those reconnects slow down.
                if stream.take_progress() && stream.is_healthy() {
                    *backoff = inner.options.backoff_min;
                }
            }
        }
    }
}

/// A self-hosted server's user id (`user_ts_...`): `user_` and 6-80
/// characters of `[A-Za-z0-9_.-]` in all.
fn valid_selfhost_user(user: &str) -> bool {
    (6..=80).contains(&user.len())
        && user.starts_with("user_")
        && user.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"_.-".contains(&byte))
}

#[cfg(test)]
mod presence_order_tests {
    use super::*;
    use std::sync::mpsc;

    struct NoBackend;

    impl CloudBackend for NoBackend {
        fn post(
            &self,
            _: &str,
            _: Option<&str>,
            _: Option<&str>,
            _: &Value,
        ) -> Result<HttpReply, TransportError> {
            Err(TransportError("offline".into()))
        }
        fn connect(
            &self,
            _: &str,
            _: Option<&str>,
            _: Option<&str>,
        ) -> Result<Box<dyn CloudWire>, ConnectError> {
            Err(ConnectError::Unavailable("offline".into()))
        }
    }

    fn presence(viewing: bool) -> CloudEvent {
        let participants = if viewing { vec![("user_ana".to_string(), true)] } else { Vec::new() };
        CloudEvent::Presence { conversation: "conv_1".into(), participants, account: None }
    }

    fn entry(driver: u64, shown: Option<CloudEvent>) -> Subscription {
        Subscription {
            driver,
            clients: BTreeSet::from([1]),
            idle_since: None,
            state: SocketState { state: "live", reason: None, account: None },
            outbox: Vec::new(),
            typing_by: None,
            viewing: BTreeSet::new(),
            presence: shown,
        }
    }

    fn recording(service: &CloudConversations) -> Arc<Mutex<Vec<CloudEvent>>> {
        let emitted: Arc<Mutex<Vec<CloudEvent>>> = Arc::default();
        let log = emitted.clone();
        service.set_sink(Arc::new(move |event| log.lock().unwrap().push(event)));
        emitted
    }

    /// A driver that retires after a new subscribe replaced its entry
    /// (`retire` removes the entry before the driver cleans up) leaves the
    /// replacement's set alone; with no replacement, or one that has shown
    /// nothing yet, it empties the clients.
    #[test]
    fn a_retired_drivers_cleanup_never_erases_its_replacements_set() {
        let service = CloudConversations::new(Arc::new(NoBackend));
        let target = Target::Conversation("conv_1".into());
        let emitted = recording(&service);
        let entries = || service.inner.subscriptions.lock().unwrap();
        entries().insert(target.clone(), entry(1, Some(presence(true))));
        service.inner.end_presence(&target, 0, Some(presence(false)));
        assert!(emitted.lock().unwrap().is_empty(), "the replacement's set stands");
        assert_eq!(entries()[&target].presence, Some(presence(true)));
        // A replaced driver shows nothing either.
        service.inner.show_presence(&target, 0, presence(false));
        assert!(emitted.lock().unwrap().is_empty());
        entries().insert(target.clone(), entry(2, None));
        service.inner.end_presence(&target, 0, Some(presence(false)));
        assert_eq!(*emitted.lock().unwrap(), [presence(false)], "nothing newer to keep");
        entries().remove(&target);
        service.inner.end_presence(&target, 0, Some(presence(false)));
        assert_eq!(emitted.lock().unwrap().len(), 2, "no entry: the clients empty");
        // The driver's own entry: cleared and emptied.
        entries().insert(target.clone(), entry(3, Some(presence(true))));
        service.inner.end_presence(&target, 3, Some(presence(false)));
        assert_eq!(entries()[&target].presence, None);
        assert_eq!(emitted.lock().unwrap().len(), 3);
    }

    /// A replay that is mid-emit when the socket ends still goes out before
    /// the socket's empty set: the clients end on no viewers, never on the
    /// dead socket's set.
    #[test]
    fn a_replay_racing_the_socket_end_goes_out_before_the_empty_set() {
        let service = CloudConversations::new(Arc::new(NoBackend));
        let target = Target::Conversation("conv_1".into());
        service
            .inner
            .subscriptions
            .lock()
            .unwrap()
            .insert(target.clone(), entry(0, Some(presence(true))));
        let emitted: Arc<Mutex<Vec<CloudEvent>>> = Arc::default();
        let (paused_tx, paused) = mpsc::channel::<()>();
        let (resume, resume_rx) = mpsc::channel::<()>();
        let resume_rx = Mutex::new(resume_rx);
        let log = emitted.clone();
        service.set_sink(Arc::new(move |event| {
            let pause = matches!(event, CloudEvent::SubscriptionState { .. });
            log.lock().unwrap().push(event);
            // The replay pauses after the state, before its presence set.
            if pause {
                let _ = paused_tx.send(());
                let _ = resume_rx.lock().unwrap().recv();
            }
        }));
        let replay = {
            let (service, target) = (service.clone(), target.clone());
            std::thread::spawn(move || service.announce_state(&target))
        };
        paused.recv().unwrap();
        let (ended_tx, ended) = mpsc::channel::<()>();
        let end = {
            let (inner, target) = (service.inner.clone(), target.clone());
            std::thread::spawn(move || {
                inner.end_presence(&target, 0, Some(presence(false)));
                let _ = ended_tx.send(());
            })
        };
        assert!(
            ended.recv_timeout(Duration::from_millis(200)).is_err(),
            "the socket's end waits for the replay in flight"
        );
        resume.send(()).unwrap();
        replay.join().unwrap();
        end.join().unwrap();
        let emitted = emitted.lock().unwrap();
        assert!(matches!(emitted[0], CloudEvent::SubscriptionState { .. }));
        assert_eq!(emitted[1..], [presence(true), presence(false)]);
        // Nothing is kept for a later subscribe: the socket is gone.
        drop(emitted);
        assert!(service.inner.subscriptions.lock().unwrap()[&target].presence.is_none());
    }
}
