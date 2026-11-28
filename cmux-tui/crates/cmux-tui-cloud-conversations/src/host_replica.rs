//! The host's read replica publisher (plans/cmux-next/object-sync/DESIGN.md
//! phase 3, backend `host-replica/wire.ts`). The Mac daemon owns its
//! host-homed streams; this module keeps the cloud's read-only copy current
//! and answers the ops the cloud forwards while the host is online.
//!
//! - The lease is the verified app's install token (`cloud-host-replica-set`):
//!   the install that enrolled the host is the only publisher. The daemon
//!   enrolls the host (`host.enroll`, idempotent per install), opens
//!   `/v1/wire/host/<host>` and publishes `host:<host>/session`: one
//!   snapshot after every connect, then one event per settled change, each
//!   carrying the whole new state (`effects.state`), in the daemon's own `seq`.
//!   The seq never goes back in one daemon, and a stream the replica does
//!   not hold (new, or purged) starts at the wall clock in milliseconds, so a
//!   reader's old cursor is always behind the first snapshot after a purge or
//!   a restart.
//! - Forwarded ops (`op` with `to` and `principal`) run through
//!   [`HostSource::apply`], which allows only a fixed list of ops and only for
//!   the token's own user; the answer goes back with the same `to`. A decided
//!   key answers again from memory and never runs twice.
//! - The per-host off switch (DESIGN.md L4) is `cloud-host-replica-clear`
//!   with `purge`: the replica forgets every stream (`replica.purge`) and the
//!   daemon drops the lease.
//! - A removed host (410 or close 4403) stays off for that install until the
//!   app clears the replica and leases again: a token refresh alone never
//!   enrolls a removed host again. A publisher replaced by another socket of
//!   the same install (close 4000) waits for a new lease instead of fighting it.
//!
//! Transport-agnostic like the rest of this crate: [`CloudBackend`] does the
//! HTTP and WebSocket I/O.

use std::fmt;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, PoisonError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::Deserialize;
use serde_json::{Value, json};
use zeroize::Zeroizing;

use super::CloudError;
use super::service::{CloudBackend, CloudWire, ConnectError, EventSink, WireRecv};
use super::session::{token_account, token_agent, token_claim, validate_api_base_url};
use cmux_json::JsonSet as _;

mod ask;
mod chief;
mod ops;
use ops::Decided;

/// The capability `identify` advertises when the publisher is installed.
pub const CLOUD_HOST_REPLICA_CAPABILITY: &str = "cloud-host-replica-v1";

/// The workspace list stream.
pub const SESSION_STREAM_SUFFIX: &str = "session";
/// The Home Chief chat stream (a450 logs/iphone-chief-DESIGN.md): published as
/// snapshots only, each the whole bounded copy, so it needs no event history.
pub const CHIEF_STREAM_SUFFIX: &str = "chief";

/// Decided keys kept for replays and reader snapshots.
const DECIDED_KEYS: usize = 256;
const MAX_TOKEN_CHARS: usize = 8192;
const MAX_NAME_CHARS: usize = 64;
const MAX_KEY_CHARS: usize = 128;
/// The backend stores one event up to 256 KiB and one snapshot up to 1 MiB;
/// a state above this is not sent (status `state_too_large`).
const MAX_STATE_BYTES: usize = 200 * 1024;

/// Why the host refused one forwarded op.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostOpRefusal {
    pub code: String,
    pub message: String,
    pub retryable: bool,
}

/// What the daemon offers the publisher: its state and its own command path.
pub trait HostSource: Send + Sync {
    /// The state of `host:<h>/session` now (the read-only cloud copy).
    fn session_state(&self) -> Value;
    /// The Home Chief chat copy (`host:<h>/chief`), when this host has one.
    fn chief_state(&self) -> Option<Value> {
        None
    }
    /// Runs one forwarded op for the cloud user `user`; only an allowlisted
    /// op runs, with its params checked by the daemon's own catalog.
    fn apply(
        &self,
        op: &str,
        params: &Value,
        idempotency_key: &str,
        user: &str,
    ) -> Result<Value, HostOpRefusal>;
}

/// `cloud-host-replica-set` params.
#[derive(Deserialize)]
pub struct HostReplicaParams {
    pub api_base_url: String,
    /// The app's install token; moved into a zeroizing buffer.
    pub install_token: String,
    /// Token expiry, Unix milliseconds.
    pub expires_at: u64,
    #[serde(default)]
    pub client_version: Option<String>,
    /// The host's name in the team directory.
    pub host_name: String,
}

impl fmt::Debug for HostReplicaParams {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("HostReplicaParams")
            .field("api_base_url", &self.api_base_url)
            .field("install_token", &"[redacted]")
            .field("expires_at", &self.expires_at)
            .field("host_name", &self.host_name)
            .finish()
    }
}

#[derive(Clone)]
pub struct HostReplicaOptions {
    pub backoff_min: Duration,
    pub backoff_max: Duration,
    /// How long one upstream receive waits before the driver rechecks the
    /// lease and its pending changes.
    pub poll: Duration,
    /// A change is published once nothing changed for this long...
    pub settle: Duration,
    /// ...or this long after the first unpublished change.
    pub max_delay: Duration,
    /// How long `replica.purge` waits for `replica.purged`.
    pub purge_timeout: Duration,
    /// How long before the lease ends the daemon asks for a new one
    /// (`cloud-host-replica-needed` with `expiring`).
    pub refresh_lead: Duration,
    /// How long before an unanswered ask is sent again.
    pub reask: Duration,
    /// Unix milliseconds.
    pub now_ms: Arc<dyn Fn() -> u64 + Send + Sync>,
    /// Platform reported at enrollment.
    pub platform: &'static str,
}

impl Default for HostReplicaOptions {
    fn default() -> Self {
        Self {
            backoff_min: Duration::from_secs(1),
            backoff_max: Duration::from_secs(30),
            poll: Duration::from_millis(250),
            settle: Duration::from_millis(250),
            max_delay: Duration::from_secs(2),
            purge_timeout: Duration::from_secs(10),
            refresh_lead: Duration::from_secs(120),
            reask: Duration::from_secs(30),
            now_ms: Arc::new(|| {
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map_or(0, |elapsed| u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX))
            }),
            platform: if cfg!(target_os = "macos") { "macos" } else { "linux" },
        }
    }
}

struct Lease {
    origin: String,
    token: Zeroizing<String>,
    expires_at: u64,
    client_version: Option<String>,
    host_name: String,
    user: String,
    install: String,
    generation: u64,
}

impl Lease {
    fn new(params: HostReplicaParams, generation: u64) -> Result<Self, CloudError> {
        let origin = validate_api_base_url(&params.api_base_url)?;
        let token = Zeroizing::new(params.install_token);
        if token.is_empty()
            || token.len() > MAX_TOKEN_CHARS
            || !token.bytes().all(|b| b.is_ascii_graphic())
        {
            return Err(CloudError::BadRequest(format!(
                "install_token must be 1-{MAX_TOKEN_CHARS} visible ASCII characters"
            )));
        }
        if params.expires_at == 0 {
            return Err(CloudError::BadRequest("expires_at must be Unix milliseconds".into()));
        }
        let name = params.host_name.trim().to_string();
        if name.is_empty() || name.chars().count() > MAX_NAME_CHARS {
            return Err(CloudError::BadRequest(format!(
                "host_name must be 1-{MAX_NAME_CHARS} characters"
            )));
        }
        // A chief token never publishes a host (the backend refuses it too).
        if token_agent(&token).is_some() {
            return Err(CloudError::daemon_reject(
                "forbidden",
                "a chief token cannot publish a host",
            ));
        }
        let user = token_account(&token).ok_or_else(|| {
            CloudError::BadRequest("install_token has no readable user (sub)".into())
        })?;
        let install = token_claim(&token, "inst").ok_or_else(|| {
            CloudError::BadRequest("install_token is not an install token (no inst)".into())
        })?;
        Ok(Self {
            origin,
            token,
            expires_at: params.expires_at,
            client_version: params.client_version,
            host_name: name,
            user,
            install,
            generation,
        })
    }

    fn url(&self, path: &str, websocket: bool) -> String {
        if !websocket {
            return format!("{}{path}", self.origin);
        }
        let origin = if let Some(rest) = self.origin.strip_prefix("https://") {
            format!("wss://{rest}")
        } else if let Some(rest) = self.origin.strip_prefix("http://") {
            format!("ws://{rest}")
        } else {
            self.origin.clone()
        };
        format!("{origin}{path}")
    }
}

/// What the driver reports (`cloud-host-replica-status`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Phase {
    Off,
    Connecting,
    Online,
    /// 401: the app must lease a new token.
    Unauthenticated,
    /// 403/404/410: this install is not the host's publisher, or the host
    /// was removed from the team.
    Forbidden,
    Purging,
    Backoff,
    /// Close 4000: another socket of this install publishes the host now.
    Replaced,
}

impl Phase {
    fn name(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::Connecting => "connecting",
            Self::Online => "online",
            Self::Unauthenticated => "unauthenticated",
            Self::Forbidden => "forbidden",
            Self::Purging => "purging",
            Self::Backoff => "backoff",
            Self::Replaced => "replaced",
        }
    }
}

struct State {
    lease: Option<Lease>,
    /// The lease generation the driver stopped on (401, 403, 410), and why.
    blocked: Option<(u64, Phase)>,
    /// Set by `clear(purge: true)`; the driver purges, then drops the lease.
    purge: bool,
    phase: Phase,
    host: Option<String>,
    seq: u64,
    published_seq: u64,
    last_error: Option<String>,
    /// The install whose host the cloud removed (410, close 4403): its
    /// leases stay blocked until `clear`.
    removed_install: Option<String>,
    /// The last purge ended without the cloud's confirmation (the cloud
    /// refused this install): the cloud drops a removed host's copy itself.
    purge_unconfirmed: bool,
    /// The driver thread runs (the capability is advertised only then).
    running: bool,
    /// When the last ask went, in Unix ms: `[expiring, unauthenticated]`.
    asked: [Option<u64>; 2],
    /// The last lease generation given; only goes up.
    generations: u64,
}

struct Inner {
    backend: Arc<dyn CloudBackend>,
    options: HostReplicaOptions,
    state: Mutex<State>,
    wake: Condvar,
    /// Bumped by every lease change and shutdown.
    signal: AtomicU64,
    changed: AtomicBool,
    shutdown: AtomicBool,
    next_tx: AtomicU64,
    /// Where `cloud-host-replica-needed` goes (the mux's event bus).
    sink: Mutex<Option<EventSink>>,
}

/// The daemon's host replica publisher.
pub struct HostReplica {
    inner: Arc<Inner>,
    driver: Mutex<Option<JoinHandle<()>>>,
}

impl HostReplica {
    pub fn new(backend: Arc<dyn CloudBackend>) -> Self {
        Self::with_options(backend, HostReplicaOptions::default())
    }

    pub fn with_options(backend: Arc<dyn CloudBackend>, options: HostReplicaOptions) -> Self {
        Self {
            inner: Arc::new(Inner {
                backend,
                options,
                state: Mutex::new(State {
                    lease: None,
                    blocked: None,
                    purge: false,
                    phase: Phase::Off,
                    host: None,
                    seq: 0,
                    published_seq: 0,
                    last_error: None,
                    removed_install: None,
                    purge_unconfirmed: false,
                    running: false,
                    asked: [None; 2],
                    generations: 0,
                }),
                wake: Condvar::new(),
                signal: AtomicU64::new(0),
                changed: AtomicBool::new(false),
                shutdown: AtomicBool::new(false),
                next_tx: AtomicU64::new(1),
                sink: Mutex::new(None),
            }),
            driver: Mutex::new(None),
        }
    }

    /// Starts the driver thread once.
    pub fn start(&self, source: Arc<dyn HostSource>) -> std::io::Result<()> {
        let mut driver = self.driver.lock().unwrap_or_else(PoisonError::into_inner);
        if driver.is_some() {
            return Ok(());
        }
        let inner = self.inner.clone();
        *driver =
            Some(std::thread::Builder::new().name("mux-host-replica".into()).spawn(move || {
                Driver {
                    inner,
                    source,
                    decided: Decided::default(),
                    decided_for: None,
                    last_state: None,
                    was_online: false,
                    chief_seq: 0,
                    chief_last: None,
                }
                .run();
            })?);
        self.inner.lock().running = true;
        Ok(())
    }

    /// Where the publisher asks for a new lease (`cloud-host-replica-needed`).
    pub fn set_sink(&self, sink: EventSink) {
        *self.inner.sink.lock().unwrap_or_else(PoisonError::into_inner) = Some(sink);
    }

    /// The driver thread runs.
    pub fn running(&self) -> bool {
        self.inner.lock().running
    }

    /// The app's install token lease; replaces any earlier one.
    pub fn set_lease(&self, params: HostReplicaParams) -> Result<Value, CloudError> {
        {
            let mut state = self.inner.lock();
            let lease = Lease::new(params, 0)?;
            // A renewal (same user, install and origin) swaps the token in place: the
            // open socket stays (HostDO closes it at its own token's expiry, and the
            // next connect uses the new token). Anything else is a new lease.
            let renewal = state.lease.as_ref().is_some_and(|old| {
                old.user == lease.user && old.install == lease.install && old.origin == lease.origin
            });
            let generation = match state.lease.as_ref() {
                Some(old) if renewal => old.generation,
                _ => {
                    state.generations += 1;
                    state.generations
                }
            };
            let lease = Lease { generation, ..lease };
            // Another user or install is another publisher: enroll again (the
            // seq stays, it never goes back).
            if state
                .lease
                .as_ref()
                .is_some_and(|old| old.user != lease.user || old.install != lease.install)
            {
                state.host = None;
            }
            let removed = state.removed_install.as_deref() == Some(lease.install.as_str());
            state.lease = Some(lease);
            state.purge = false;
            state.purge_unconfirmed = false;
            if removed {
                // A token refresh does not bring a removed host back.
                state.blocked = Some((generation, Phase::Forbidden));
                state.phase = Phase::Forbidden;
                state.last_error = Some(
                    "the cloud removed this host; clear the replica and lease again to enroll it again"
                        .into(),
                );
            } else {
                state.blocked = None;
                state.last_error = None;
            }
        }
        self.inner.poke();
        Ok(self.status())
    }

    /// Drops the lease. With `purge`, the replica first forgets every stream
    /// (the host's off switch); the lease is dropped when that is confirmed.
    pub fn clear(&self, purge: bool) -> Value {
        {
            let mut state = self.inner.lock();
            // Clearing is the explicit user action that may enroll a removed host again.
            state.removed_install = None;
            state.purge_unconfirmed = false;
            if purge && state.lease.is_some() {
                state.purge = true;
                state.blocked = None;
            } else {
                state.lease = None;
                state.purge = false;
                // The next lease may be another user's: it enrolls again.
                state.host = None;
            }
        }
        self.inner.poke();
        self.status()
    }

    pub fn status(&self) -> Value {
        let state = self.inner.lock();
        let mut status = json!({ "state": state.phase.name() });
        if let Some(lease) = &state.lease {
            status.set("api_base_url", json!(lease.origin));
            status.set("expires_at", json!(lease.expires_at));
            status.set("host_name", json!(lease.host_name));
        }
        if let Some(host) = &state.host {
            status.set("host", json!(host));
            status.set("stream", json!(stream_of(host)));
            status.set("seq", json!(state.published_seq));
        }
        if state.purge {
            status.set("purge_pending", json!(true));
        }
        if state.purge_unconfirmed {
            status.set("purge_unconfirmed", json!(true));
        }
        if let Some(error) = &state.last_error {
            status.set("last_error", json!(error));
        }
        status
    }

    /// The daemon's session state changed; the next settled change is published.
    pub fn mark_changed(&self) {
        self.inner.changed.store(true, Ordering::Release);
    }

    pub fn shutdown(&self) {
        self.inner.shutdown.store(true, Ordering::Release);
        self.inner.poke();
        if let Some(driver) = self.driver.lock().unwrap_or_else(PoisonError::into_inner).take() {
            let _ = driver.join();
        }
    }
}

impl Drop for HostReplica {
    /// Signals the driver and does not join it: the last owner of the daemon
    /// may be the driver thread itself (it holds the daemon while it reads).
    fn drop(&mut self) {
        self.inner.shutdown.store(true, Ordering::Release);
        self.inner.poke();
    }
}

impl Inner {
    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn poke(&self) {
        let _state = self.lock();
        self.signal.fetch_add(1, Ordering::AcqRel);
        self.wake.notify_all();
    }

    /// Waits up to `timeout` for a lease change or shutdown.
    fn wait(&self, seen: u64, timeout: Option<Duration>) {
        let state = self.lock();
        let unchanged = |_: &mut State| {
            self.signal.load(Ordering::Acquire) == seen && !self.shutdown.load(Ordering::Acquire)
        };
        match timeout {
            Some(timeout) => drop(self.wake.wait_timeout_while(state, timeout, unchanged)),
            None => drop(self.wake.wait_while(state, unchanged)),
        }
    }

    fn set_phase(&self, phase: Phase, error: Option<String>) {
        let mut state = self.lock();
        state.phase = phase;
        if error.is_some() {
            state.last_error = error;
        }
    }

    fn tx(&self) -> String {
        format!(
            "tx-host-{}-{}",
            (self.options.now_ms)(),
            self.next_tx.fetch_add(1, Ordering::AcqRel)
        )
    }
}

fn stream_of(host: &str) -> String {
    format!("host:{host}/{SESSION_STREAM_SUFFIX}")
}

fn chief_stream_of(host: &str) -> String {
    format!("host:{host}/{CHIEF_STREAM_SUFFIX}")
}

/// How one connection ended.
enum Ended {
    /// Reconnect after a backoff.
    Dropped(String),
    /// The lease changed or the daemon stops: start over at once.
    LeaseChanged,
    /// The purge is confirmed and the lease dropped.
    Purged,
    /// A close code that waits for a new lease (4000, 4401, 4403).
    Blocked(Phase),
}

struct Driver {
    inner: Arc<Inner>,
    source: Arc<dyn HostSource>,
    decided: Decided,
    /// The user and install the decided keys belong to.
    decided_for: Option<(String, String)>,
    /// The state last published on this connection: an unchanged state
    /// publishes no event.
    last_state: Option<String>,
    /// The last connection reached `online` (the backoff starts over).
    was_online: bool,
    /// The Chief stream's own seq (snapshots only) and its last published state.
    chief_seq: u64,
    chief_last: Option<String>,
}

/// The lease fields one connection uses (the token stays zeroizing).
struct Use {
    generation: u64,
    expires_at: u64,
    token: Zeroizing<String>,
    client_version: Option<String>,
    host_name: String,
    user: String,
    install: String,
    enroll_url: String,
    ws_url: Box<dyn Fn(&str) -> String + Send>,
}

impl Driver {
    fn run(mut self) {
        let mut backoff = self.inner.options.backoff_min;
        loop {
            if self.inner.shutdown.load(Ordering::Acquire) {
                return;
            }
            let seen = self.inner.signal.load(Ordering::Acquire);
            let Some(lease) = self.current() else {
                // No lease (off), or a blocked one (its phase stays): wait for a change.
                let refused = {
                    let mut state = self.inner.lock();
                    if state.lease.is_none() {
                        state.phase = Phase::Off;
                    }
                    state.lease.is_some() && state.phase == Phase::Unauthenticated
                };
                if refused {
                    // No app connection may have heard the ask: ask again until a lease comes.
                    self.inner.wait(seen, Some(self.inner.options.reask));
                    // A new lease or a clear woke the wait: it is not refused any more.
                    if self.inner.signal.load(Ordering::Acquire) == seen {
                        self.inner.need("unauthenticated");
                    }
                } else {
                    self.inner.wait(seen, None);
                }
                continue;
            };
            let identity = (lease.user.clone(), lease.install.clone());
            if self.decided_for.as_ref() != Some(&identity) {
                // Decided keys belong to one user and install.
                self.decided = Decided::default();
                self.decided_for = Some(identity);
            }
            self.was_online = false;
            let ended = self.connect_once(&lease);
            if self.was_online {
                backoff = self.inner.options.backoff_min;
            }
            match ended {
                Ok(Ended::Purged | Ended::LeaseChanged) => {
                    backoff = self.inner.options.backoff_min;
                }
                Ok(Ended::Dropped(why)) => {
                    self.inner.set_phase(Phase::Backoff, Some(why));
                    self.inner.wait(seen, Some(backoff));
                    backoff = (backoff * 2).min(self.inner.options.backoff_max);
                }
                Ok(Ended::Blocked(blocked)) | Err(blocked) => {
                    // The old token expired (HostDO closes 4401), but the app already
                    // renewed it in place: connect again with the new one.
                    let renewed = blocked == Phase::Unauthenticated
                        && self.inner.lock().lease.as_ref().is_some_and(|l| {
                            l.generation == lease.generation && *l.token != *lease.token
                        });
                    if renewed {
                        backoff = self.inner.options.backoff_min;
                        continue;
                    }
                    if blocked == Phase::Unauthenticated {
                        self.inner.need("unauthenticated");
                    }
                    // Wait for a new lease (or a clear) before trying again. A purge
                    // of a host this install may no longer reach has nothing to keep:
                    // a refused or removed host's replica is the backend's to drop.
                    let retry_purge = {
                        let mut state = self.inner.lock();
                        state.phase = blocked;
                        let same =
                            state.lease.as_ref().is_some_and(|l| l.generation == lease.generation);
                        if state.purge && same && blocked == Phase::Forbidden {
                            // The cloud refuses this install, so it cannot confirm the purge.
                            state.lease = None;
                            state.purge = false;
                            state.purge_unconfirmed = true;
                            state.phase = Phase::Off;
                        } else if same {
                            state.blocked = Some((lease.generation, blocked));
                        }
                        // A purge still pending after another publisher took the socket
                        // (4000) tries again after a backoff; a refused token waits for a
                        // new lease like any other (see `current`).
                        state.purge && same && blocked == Phase::Replaced
                    };
                    if retry_purge {
                        self.inner.wait(seen, Some(backoff));
                        backoff = (backoff * 2).min(self.inner.options.backoff_max);
                    }
                }
            }
        }
    }

    /// The lease to use now, unless there is none or it is blocked.
    fn current(&self) -> Option<Use> {
        let state = self.inner.lock();
        let lease = state.lease.as_ref()?;
        if let Some((generation, why)) = state.blocked
            && generation == lease.generation
            // A pending purge retries a replaced socket, never a refused token.
            && !(state.purge && why != Phase::Unauthenticated)
        {
            return None;
        }
        let ws_origin = lease.url("", true);
        Some(Use {
            generation: lease.generation,
            expires_at: lease.expires_at,
            token: lease.token.clone(),
            client_version: lease.client_version.clone(),
            host_name: lease.host_name.clone(),
            user: lease.user.clone(),
            install: lease.install.clone(),
            enroll_url: lease.url("/v1/ops", false),
            ws_url: Box::new(move |path| format!("{ws_origin}{path}")),
        })
    }

    fn lease_changed(&self, generation: u64) -> bool {
        if self.inner.shutdown.load(Ordering::Acquire) {
            return true;
        }
        let state = self.inner.lock();
        state.lease.as_ref().map(|l| l.generation) != Some(generation)
    }

    /// Enrolls (once per lease user and install), connects and serves one
    /// connection. `Err` is a phase that waits for a new lease.
    fn connect_once(&mut self, lease: &Use) -> Result<Ended, Phase> {
        self.inner.set_phase(Phase::Connecting, None);
        self.inner.need_if_expiring(lease.expires_at);
        let host = match self.host(lease) {
            Ok(host) => host,
            Err(Err(phase)) => return Err(phase),
            Err(Ok(why)) => return Ok(Ended::Dropped(why)),
        };
        let url = (lease.ws_url)(&format!("/v1/wire/host/{host}"));
        let wire = match self.inner.backend.connect(
            &url,
            Some(lease.token.as_str()),
            lease.client_version.as_deref(),
        ) {
            Ok(wire) => wire,
            Err(ConnectError::Unauthenticated) => return Err(Phase::Unauthenticated),
            Err(ConnectError::Forbidden) => {
                // The host is gone (410) or no longer ours (403): it stays off
                // for this install until the app clears the replica.
                self.forget_removed_host(lease);
                return Err(Phase::Forbidden);
            }
            Err(ConnectError::Unavailable(why)) => return Ok(Ended::Dropped(why)),
        };
        Ok(self.serve(lease, &host, wire))
    }

    fn forget_removed_host(&self, lease: &Use) {
        let mut state = self.inner.lock();
        state.host = None;
        state.removed_install = Some(lease.install.clone());
    }

    /// The host id: the stored one, or `host.enroll` (idempotent per install).
    /// `Err(Ok(why))` retries after a backoff, `Err(Err(phase))` waits for a lease.
    fn host(&self, lease: &Use) -> Result<String, Result<String, Phase>> {
        {
            let state = self.inner.lock();
            if let Some(host) = &state.host {
                return Ok(host.clone());
            }
        }
        let body = json!({
            "op": "host.enroll",
            "params": { "name": lease.host_name, "platform": self.inner.options.platform },
            "idempotency_key": format!("host-enroll:{}:{}", lease.install, self.inner.tx()),
            "origin": "script",
        });
        let reply = self
            .inner
            .backend
            .post(
                &lease.enroll_url,
                Some(lease.token.as_str()),
                lease.client_version.as_deref(),
                &body,
            )
            .map_err(|error| Ok(format!("host.enroll: {}", error.0)))?;
        match reply.status {
            200 => {}
            401 => return Err(Err(Phase::Unauthenticated)),
            403 => return Err(Err(Phase::Forbidden)),
            status => return Err(Ok(format!("host.enroll answered HTTP {status}"))),
        }
        let id = reply.body["value"]["id"].as_str().filter(|id| valid_host_id(id));
        let Some(id) = id else {
            let code = reply.body["error"]["code"].as_str().unwrap_or("invalid reply").to_string();
            return Err(Ok(format!("host.enroll: {code}")));
        };
        let mut state = self.inner.lock();
        if state.host.as_deref() != Some(id) {
            state.published_seq = 0;
        }
        state.host = Some(id.to_string());
        Ok(id.to_string())
    }

    fn serve(&mut self, lease: &Use, host: &str, mut wire: Box<dyn CloudWire>) -> Ended {
        let stream = stream_of(host);
        let poll = self.inner.options.poll;
        // Welcome first: where the replica stands.
        let deadline = Instant::now() + self.inner.options.backoff_max.max(poll * 4);
        let heads = loop {
            if self.lease_changed(lease.generation) && !self.inner.lock().purge {
                return Ended::LeaseChanged;
            }
            match wire.recv(poll) {
                WireRecv::Text(text) => {
                    let frame: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
                    if frame["t"] == "welcome" && frame["role"] == "publisher" {
                        break frame["heads"].clone();
                    }
                }
                WireRecv::Idle if Instant::now() < deadline => {}
                WireRecv::Idle => return Ended::Dropped("no welcome".into()),
                WireRecv::Closed { code } => return self.closed(lease, code),
            }
        };
        if self.inner.lock().purge {
            return self.purge(lease, &mut *wire);
        }
        {
            let mut state = self.inner.lock();
            // A stream the replica does not hold starts at the wall clock, so
            // it is ahead of any cursor a reader kept from before a purge.
            let floor = match heads[&stream].as_u64() {
                Some(head) => head,
                None => (self.inner.options.now_ms)(),
            };
            state.seq = state.seq.max(floor);
        }
        let chief = chief_stream_of(host);
        let chief_floor = heads[&chief].as_u64().unwrap_or_else(|| (self.inner.options.now_ms)());
        self.chief_seq = self.chief_seq.max(chief_floor);
        self.chief_last = None;
        // A snapshot after every connect: the replica holds exactly this state.
        self.inner.changed.store(false, Ordering::Release);
        if let Err(why) = self.publish(lease, &stream, &mut *wire, true) {
            return Ended::Dropped(why);
        }
        if let Err(why) = self.publish_chief(&chief, &mut *wire, true) {
            return Ended::Dropped(why);
        }
        self.inner.set_phase(Phase::Online, None);
        self.was_online = true;
        let mut first_change: Option<Instant> = None;
        let mut last_change = Instant::now();
        loop {
            if self.inner.shutdown.load(Ordering::Acquire) {
                return Ended::LeaseChanged;
            }
            if self.inner.lock().purge {
                return self.purge(lease, &mut *wire);
            }
            if self.lease_changed(lease.generation) {
                return Ended::LeaseChanged;
            }
            let expires_at = self.inner.lock().lease.as_ref().map_or(0, |l| l.expires_at);
            self.inner.need_if_expiring(expires_at);
            if self.inner.changed.swap(false, Ordering::AcqRel) {
                last_change = Instant::now();
                first_change.get_or_insert(last_change);
            }
            if let Some(first) = first_change {
                let now = Instant::now();
                let options = &self.inner.options;
                if now >= last_change + options.settle || now >= first + options.max_delay {
                    first_change = None;
                    if let Err(why) = self.publish(lease, &stream, &mut *wire, false) {
                        return Ended::Dropped(why);
                    }
                    if let Err(why) = self.publish_chief(&chief, &mut *wire, false) {
                        return Ended::Dropped(why);
                    }
                }
            }
            match wire.recv(poll) {
                WireRecv::Text(text) => {
                    let frame_stream = serde_json::from_str::<Value>(&text)
                        .ok()
                        .and_then(|f| f["stream"].as_str().map(str::to_owned));
                    let target = if frame_stream.as_deref() == Some(chief.as_str()) {
                        &chief
                    } else {
                        &stream
                    };
                    if let Err(why) = self.on_frame(lease, target, &mut *wire, &text) {
                        return Ended::Dropped(why);
                    }
                }
                WireRecv::Idle => {}
                WireRecv::Closed { code } => return self.closed(lease, code),
            }
        }
    }

    /// How a close ends the connection: 4000 (replaced by another socket of
    /// this install), 4401 (token) and 4403 (host removed) wait for a lease.
    fn closed(&self, lease: &Use, code: Option<u16>) -> Ended {
        match code {
            Some(4000) => Ended::Blocked(Phase::Replaced),
            Some(4401) => Ended::Blocked(Phase::Unauthenticated),
            Some(4403) => {
                self.forget_removed_host(lease);
                Ended::Blocked(Phase::Forbidden)
            }
            _ => closed(code),
        }
    }

    /// Publishes the current state: a snapshot, or an event at the next seq.
    /// An unchanged state publishes no event; a state above
    /// `MAX_STATE_BYTES` publishes nothing (status `last_error`).
    fn publish(
        &mut self,
        lease: &Use,
        stream: &str,
        wire: &mut dyn CloudWire,
        snapshot: bool,
    ) -> Result<(), String> {
        let state = self.source.session_state();
        let text = state.to_string();
        if !snapshot && self.last_state.as_deref() == Some(text.as_str()) {
            return Ok(());
        }
        if text.len() > MAX_STATE_BYTES {
            self.inner
                .set_phase(Phase::Online, Some(format!("state_too_large: {} bytes", text.len())));
            return Ok(());
        }
        let (seq, frame) = {
            let mut guard = self.inner.lock();
            if snapshot {
                // A snapshot always moves to a new seq, so it replaces the tail.
                guard.seq += 1;
                let seq = guard.seq;
                (
                    seq,
                    json!({ "t": "publish", "stream": stream, "snapshot": {
                    "t": "snapshot", "stream": stream, "seq": seq, "state": state, "decided": [] } }),
                )
            } else {
                guard.seq += 1;
                let seq = guard.seq;
                (
                    seq,
                    json!({ "t": "publish", "stream": stream, "event": {
                    "t": "event", "stream": stream, "seq": seq, "tx": self.inner.tx(),
                    "op": "host.session.update", "params": {},
                    "actor": { "kind": "install", "user": lease.user, "install": lease.install },
                    "origin": "script", "at": (self.inner.options.now_ms)(),
                    "effects": { "state": state, "writes": [] } } }),
                )
            }
        };
        wire.send(&frame.to_string()).map_err(|error| error.0)?;
        self.inner.lock().published_seq = seq;
        self.last_state = Some(text);
        Ok(())
    }

    fn on_frame(
        &mut self,
        lease: &Use,
        stream: &str,
        wire: &mut dyn CloudWire,
        text: &str,
    ) -> Result<(), String> {
        let Ok(frame) = serde_json::from_str::<Value>(text) else { return Ok(()) };
        let is_chief = stream.ends_with(&format!("/{CHIEF_STREAM_SUFFIX}"));
        match frame["t"].as_str() {
            Some("snapshot.request") if is_chief => {
                self.chief_snapshot_request(stream, wire, &frame)
            }
            Some("snapshot.request") => {
                if let Some(to) = frame["to"].as_str() {
                    // A reader's pending keys: only the host knows its decided keys.
                    let pending: Vec<&str> = frame["pending"]
                        .as_array()
                        .map(|keys| keys.iter().filter_map(Value::as_str).take(1000).collect())
                        .unwrap_or_default();
                    let decided: Vec<Value> = pending
                        .iter()
                        .filter_map(|key| {
                            self.decided.get(key).map(|a| json!({ "idempotency_key": key, "ok": a.ok, "sequence": a.sequence }))
                        })
                        .collect();
                    // The state published at `published_seq` (each event carries
                    // the whole state), so the seq and the state agree.
                    let seq = self.inner.lock().published_seq;
                    let Some(state) = self
                        .last_state
                        .as_deref()
                        .and_then(|t| serde_json::from_str::<Value>(t).ok())
                    else {
                        return Ok(());
                    };
                    let answer = json!({ "t": "snapshot", "to": to, "stream": stream, "seq": seq,
                        "state": state, "decided": decided });
                    return wire.send(&answer.to_string()).map_err(|error| error.0);
                }
                // The replica's own request (a gap or a long tail): a new snapshot.
                self.publish(lease, stream, wire, true)
            }
            Some("op") => self.on_op(lease, stream, wire, &frame),
            Some("error") => {
                let code = frame["code"].as_str().unwrap_or("error");
                self.inner.set_phase(Phase::Online, Some(format!("replica refused: {code}")));
                Ok(())
            }
            _ => Ok(()),
        }
    }
}

fn closed(code: Option<u16>) -> Ended {
    Ended::Dropped(match code {
        Some(code) => format!("closed {code}"),
        None => "closed".into(),
    })
}

/// `host_` and 20 lowercase letters or digits (the backend's host id).
pub fn valid_host_id(id: &str) -> bool {
    id.strip_prefix("host_").is_some_and(|rest| {
        rest.len() == 20 && rest.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
    })
}
