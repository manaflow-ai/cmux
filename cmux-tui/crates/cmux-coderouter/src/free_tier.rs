//! The free-tier device lease (cx-ds09i): while no account bearer is set, the
//! relay gets a short-lived `aud inference` token for this device from the
//! hosted model router, proven with App Attest by the cmux app.
//!
//! The relay owns the whole flow (Lawrence 2026-10-12: product logic lives in
//! the daemon, the app owns only platform APIs). The app is an attestation
//! provider: it keeps one admin connection open (`attest_provider`) and
//! answers two requests on it, `attest` and `assert`, each over a 32-byte hash
//! the relay builds from a server challenge. The app never sees a token.
//!
//! Rules (security review conditions, hq-84 2026-10-12):
//! - the provider's origin must be a known cmux API origin ([`known_origin`]);
//!   the token is sent only there;
//! - the provider passes a peer check ([`provider_peer_allowed`]);
//! - one provider at a time, one request at a time (the assertion counter
//!   must grow);
//! - the token lives in memory only ([`Secret`]), never in status or logs,
//!   and is dropped when the provider's connection ends;
//! - the lease starts at the first data-plane request with no account
//!   bearer, never at launch; that request waits at most [`FIRST_WAIT`].
//!
//! Server side: backend/apps/api/src/inference/free.ts.

use crate::Secret;
use axum::{body::Body, http::StatusCode, response::Response};
use base64::Engine as _;
use cmux_json::JsonSet as _;
use serde::Serialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::AsyncWriteExt;
use tokio::sync::{mpsc, oneshot};

/// The only purpose the app signs for.
pub const PURPOSE: &str = "cmux.free-tier.v1";

/// The production cmux API: the only origin a release relay in a release app takes.
const PRODUCTION_ORIGIN: &str = "https://cloud-api.cmux.dev";
/// Staging and the dev Worker: only for a DEV build (a debug relay, or a relay
/// inside a `com.cmuxterm.app.debug*` app, the bundle id the DEV channels use).
const DEV_ORIGINS: &[&str] =
    &["https://cloud-api-staging.cmux.dev", "https://cmux-api-development.debussy.workers.dev"];

/// Whether this relay belongs to a DEV build (module docs of [`DEV_ORIGINS`]).
fn dev_build() -> bool {
    static DEV: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *DEV.get_or_init(|| {
        cfg!(debug_assertions)
            || containing_bundle_id().is_some_and(|id| id.starts_with("com.cmuxterm.app.debug"))
    })
}

/// The CFBundleIdentifier of the .app that contains this executable, if any.
fn containing_bundle_id() -> Option<String> {
    let exe = std::env::current_exe().ok()?.canonicalize().ok()?;
    let bundle = exe.ancestors().find(|p| p.extension().is_some_and(|e| e == "app"))?;
    let plist = bundle.join("Contents").join("Info.plist");
    #[cfg(target_os = "macos")]
    {
        let out = std::process::Command::new("/usr/bin/plutil")
            .args(["-extract", "CFBundleIdentifier", "raw", "-o", "-"])
            .arg(&plist)
            .stdin(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .output()
            .ok()?;
        let id = String::from_utf8(out.stdout).ok()?.trim().to_owned();
        (out.status.success() && !id.is_empty()).then_some(id)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = plist;
        None
    }
}

/// Longest wait of the request that starts a lease.
pub const FIRST_WAIT: Duration = Duration::from_secs(20);
/// Renew this long before the token's expiry.
const RENEW_MARGIN_S: u64 = 90;
/// One provider request (an attestation asks Apple's server).
const PROVIDER_WAIT: Duration = Duration::from_secs(15);
/// A deployment with the free tier off is asked again after this.
const SERVICE_OFF_RETRY: Duration = Duration::from_secs(6 * 3600);
/// Waits after a network or server failure, the last one repeating.
const RETRY_DELAYS: [u64; 6] = [2, 5, 15, 30, 60, 120];

/// What the free tier can do now (status, and the app's Settings caption).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum FreeState {
    /// The setting is off, or no provider is connected.
    Off,
    /// Ready to start a lease at the next request.
    Idle,
    Checking,
    Active,
    UsedThisMonth,
    Unsupported,
    NotVerified,
    ServiceOff,
    Backoff,
    /// The app's key-id store (the Mac's Keychain) refused access: no lease
    /// until the provider registers again or the setting changes.
    StoreFailed,
}

/// Whether `origin` (an origin string, any trailing slash) is a known cmux API
/// origin: production always, staging and the dev Worker only in a DEV build. Debug builds also take `CMUX_ROUTER_FREE_TEST_ORIGIN`, a loopback
/// origin for the relay's own tests; release builds never read it.
pub fn known_origin(origin: &str) -> Option<String> {
    let origin = origin.trim_end_matches('/');
    if origin == PRODUCTION_ORIGIN || (DEV_ORIGINS.contains(&origin) && dev_build()) {
        return Some(origin.to_owned());
    }
    #[cfg(debug_assertions)]
    if let Ok(test) = std::env::var("CMUX_ROUTER_FREE_TEST_ORIGIN") {
        let test = test.trim_end_matches('/');
        if origin == test && test.starts_with("http://127.0.0.1:") {
            return Some(origin.to_owned());
        }
    }
    None
}

/// The provider's register request.
#[derive(Debug, Clone, serde::Deserialize)]
pub struct Register {
    pub version: u32,
    pub platform: String,
    pub origin: String,
    pub enabled: bool,
    #[serde(default)]
    pub managed: bool,
    #[serde(default)]
    pub has_key: bool,
    /// The app has a signed-in account: no free lease then, even while the
    /// relay has no account bearer yet (a restart, a renewal gap).
    #[serde(default)]
    pub signed_in: bool,
}

struct Provider {
    generation: u64,
    /// Fired when a newer provider replaces this one: its connection ends.
    replaced: tokio::sync::Notify,
    out: mpsc::UnboundedSender<String>,
    pending: Mutex<HashMap<u64, oneshot::Sender<Value>>>,
    next_id: AtomicU64,
}

struct Token {
    bearer: Secret<String>,
    expires_at: u64,
    month: String,
}

struct Inner {
    provider: Option<Arc<Provider>>,
    origin: Option<String>,
    platform: String,
    enabled: bool,
    managed: bool,
    has_key: bool,
    signed_in: bool,
    token: Option<Token>,
    state: FreeState,
    until_ms: Option<u64>,
    retry_at: Option<Instant>,
    failures: usize,
}

/// The relay's free-tier lease (one per relay process).
pub struct FreeTier {
    inner: Mutex<Inner>,
    /// Serializes leases: one provider request at a time.
    lease: tokio::sync::Mutex<()>,
    generations: AtomicU64,
    http: reqwest::Client,
}

#[derive(Debug)]
enum LeaseError {
    /// The app's error code.
    App(String),
    /// The cmux API refused: status and error code.
    Server(u16, String),
    /// No answer from the API, or a malformed one.
    Network,
    /// The provider left or did not answer in time.
    Gone,
}

fn unix_now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn unix_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// UTC year and month (YYYY-MM) of a Unix time, the server's grant month.
fn utc_month(secs: u64) -> String {
    let (year, month, _) = civil(secs / 86_400);
    format!("{year:04}-{month:02}")
}

/// Unix milliseconds of the first instant of the next UTC month.
fn next_month_ms(secs: u64) -> u64 {
    let (year, month, _) = civil(secs / 86_400);
    let (year, month) = if month == 12 { (year + 1, 1) } else { (year, month + 1) };
    days_from_civil(year, month, 1) * 86_400_000
}

/// Days since 1970-01-01 to (year, month, day), proleptic Gregorian (H. Hinnant).
fn civil(days: u64) -> (u64, u64, u64) {
    let z = days + 719_468;
    let era = z / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + u64::from(month <= 2);
    (year, month, day)
}

fn days_from_civil(year: u64, month: u64, day: u64) -> u64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = year / 400;
    let yoe = year - era * 400;
    let mp = if month > 2 { month - 3 } else { month + 9 };
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

impl FreeTier {
    pub fn new(http: reqwest::Client) -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new(Inner {
                provider: None,
                origin: None,
                platform: String::new(),
                enabled: false,
                managed: false,
                has_key: false,
                signed_in: false,
                token: None,
                state: FreeState::Off,
                until_ms: None,
                retry_at: None,
                failures: 0,
            }),
            lease: tokio::sync::Mutex::new(()),
            generations: AtomicU64::new(0),
            http,
        })
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Status view: never the token.
    pub fn view(&self) -> Value {
        let inner = self.lock();
        json!({
            "state": inner.state,
            "until_ms": inner.until_ms,
            "provider": inner.provider.is_some(),
            "enabled": inner.enabled,
            "managed": inner.managed,
        })
    }

    /// Drops the token (relay shutdown).
    pub fn drop_token(&self) {
        let mut inner = self.lock();
        inner.token = None;
        if inner.state == FreeState::Active {
            Self::set_state(&mut inner, FreeState::Idle, None);
        }
    }

    /// Drops the token only while it is still `bearer` (the API refused it;
    /// a newer token from a concurrent lease stays).
    pub fn drop_token_if(&self, bearer: &str) {
        let mut inner = self.lock();
        if inner.token.as_ref().is_none_or(|token| token.bearer.expose() != bearer) {
            return;
        }
        inner.token = None;
        if inner.state == FreeState::Active {
            Self::set_state(&mut inner, FreeState::Idle, None);
        }
    }

    fn set_state(inner: &mut Inner, state: FreeState, until_ms: Option<u64>) {
        if inner.state == state && inner.until_ms == until_ms {
            return;
        }
        inner.state = state;
        inner.until_ms = until_ms;
        if let Some(provider) = &inner.provider {
            let event = json!({"event": "free_state", "state": state, "until_ms": until_ms});
            let _ = provider.out.send(event.to_string());
        }
    }

    /// Serves one provider connection after the register line and the peer
    /// check. A newer provider replaces this one; its end clears only its own state.
    pub async fn serve_provider<R, W>(
        self: Arc<Self>,
        register: Register,
        mut lines: tokio::io::Lines<R>,
        mut write: W,
    ) -> anyhow::Result<()>
    where
        R: tokio::io::AsyncBufRead + Unpin,
        W: tokio::io::AsyncWrite + Unpin + Send + 'static,
    {
        let refuse = |why: &str| json!({"error": why}).to_string();
        let Some(origin) = known_origin(&register.origin) else {
            write.write_all(format!("{}\n", refuse("provider origin refused")).as_bytes()).await?;
            return Ok(());
        };
        if register.version != 1 || !matches!(register.platform.as_str(), "mac" | "ios") {
            write.write_all(format!("{}\n", refuse("provider refused")).as_bytes()).await?;
            return Ok(());
        }
        let generation = self.generations.fetch_add(1, Ordering::Relaxed) + 1;
        let (out, mut outgoing) = mpsc::unbounded_channel::<String>();
        let provider = Arc::new(Provider {
            generation,
            replaced: tokio::sync::Notify::new(),
            out,
            pending: Mutex::new(HashMap::new()),
            next_id: AtomicU64::new(1),
        });
        {
            let mut inner = self.lock();
            // The old provider's connection ends (its serve loop waits on `replaced`).
            if let Some(old) = inner.provider.replace(provider.clone()) {
                old.replaced.notify_one();
            }
            if inner.origin.as_deref() != Some(origin.as_str()) {
                inner.token = None;
            }
            inner.origin = Some(origin);
            inner.platform = register.platform.clone();
            inner.has_key = register.has_key;
            inner.signed_in = register.signed_in;
            inner.retry_at = None;
            inner.failures = 0;
            Self::apply_setting(&mut inner, register.enabled, register.managed, true);
            if register.signed_in {
                Self::set_state(&mut inner, FreeState::Off, None);
            }
        }
        // The provider line comes after the registration is applied: when the app reads it, the
        // relay's state already reflects this registration (its events follow through the writer).
        // A write error (the app went away right now) ends this provider like an EOF does: never
        // an early return that leaves a dead connection registered with a live token.
        let line = format!("{}\n", json!({"provider": true, "pid": std::process::id()}));
        if write.write_all(line.as_bytes()).await.is_err() {
            self.end_provider(&provider);
            return Ok(());
        }
        let writer = tokio::spawn(async move {
            while let Some(line) = outgoing.recv().await {
                if write.write_all(format!("{line}\n").as_bytes()).await.is_err() {
                    break;
                }
            }
            let _ = write.shutdown().await;
        });
        loop {
            let line = tokio::select! {
                line = lines.next_line() => line,
                () = provider.replaced.notified() => break,
            };
            let Ok(Some(line)) = line else { break };
            let Ok(message) = serde_json::from_str::<Value>(&line) else { continue };
            if let Some(id) = message.get("id").and_then(Value::as_u64) {
                let waiter = provider
                    .pending
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .remove(&id);
                if let Some(waiter) = waiter {
                    let _ = waiter.send(message);
                }
            } else if let Some(enabled) = message.get("enabled").and_then(Value::as_bool) {
                let managed = message.get("managed").and_then(Value::as_bool).unwrap_or(false);
                let signed_in = message.get("signed_in").and_then(Value::as_bool).unwrap_or(false);
                let mut inner = self.lock();
                if inner.provider.as_ref().is_some_and(|p| p.generation == generation) {
                    inner.signed_in = signed_in;
                    Self::apply_setting(&mut inner, enabled, managed, false);
                    if signed_in {
                        // The account bearer serves this Mac now: no free token, no lease.
                        inner.token = None;
                        Self::set_state(&mut inner, FreeState::Off, None);
                    }
                }
            }
        }
        self.end_provider(&provider);
        writer.abort();
        Ok(())
    }

    /// The provider's connection ended: when it is still the registered one, drop it with the
    /// free token (the token never outlives its provider) and report off. Pending waiters see a
    /// closed channel (Gone).
    fn end_provider(&self, provider: &Provider) {
        {
            let mut inner = self.lock();
            if inner.provider.as_ref().is_some_and(|p| p.generation == provider.generation) {
                inner.provider = None;
                inner.token = None;
                inner.state = FreeState::Off;
                inner.until_ms = None;
            }
        }
        provider.pending.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clear();
    }

    fn apply_setting(inner: &mut Inner, enabled: bool, managed: bool, registered: bool) {
        inner.enabled = enabled;
        inner.managed = managed;
        if !enabled {
            inner.token = None;
            Self::set_state(inner, FreeState::Off, None);
        } else if registered || matches!(inner.state, FreeState::Off | FreeState::StoreFailed) {
            // A new provider registration asks again after any refusal state.
            Self::set_state(inner, FreeState::Idle, None);
        }
    }

    /// The live free token for `origin`, without a lease. Never while the
    /// setting is off or an account is signed in.
    fn live(inner: &Inner, now: u64) -> Option<(String, String)> {
        if !inner.enabled || inner.signed_in {
            return None;
        }
        let token = inner.token.as_ref()?;
        if token.expires_at <= now + RENEW_MARGIN_S || token.month != utc_month(now) {
            return None;
        }
        Some((inner.origin.clone()?, token.bearer.expose().clone()))
    }

    /// The origin and bearer for a request with no account bearer: the live
    /// free token, or a new one from a lease. Err: the response to send.
    /// The lease runs in its own task: a request that stops waiting (the 20 s
    /// limit, or its client left) never cancels a lease half way, so the
    /// lease always records its token and state.
    pub async fn bearer(self: &Arc<Self>) -> Result<(String, String), Box<Response<Body>>> {
        if let Some(found) = Self::live(&self.lock(), unix_now()) {
            return Ok(found);
        }
        self.admissible()?;
        let this = self.clone();
        let lease = tokio::spawn(async move {
            let _lease = this.lease.lock().await;
            if let Some(found) = Self::live(&this.lock(), unix_now()) {
                return Ok(found);
            }
            this.admissible()?;
            this.run_lease().await
        });
        match tokio::time::timeout(FIRST_WAIT, lease).await {
            Ok(Ok(result)) => result,
            _ => Err(refusal(FreeState::Backoff)),
        }
    }

    /// Whether a lease may run now; else the refusal for the current state.
    fn admissible(&self) -> Result<(), Box<Response<Body>>> {
        let inner = self.lock();
        if inner.provider.is_none() {
            return Err(Box::new(crate::json_error(
                StatusCode::SERVICE_UNAVAILABLE,
                "router.no_upstream",
                "the cmux model router is not connected; open cmux",
            )));
        }
        if inner.signed_in {
            return Err(Box::new(crate::json_error(
                StatusCode::SERVICE_UNAVAILABLE,
                "router.no_upstream",
                "the cmux model router is not connected; open cmux",
            )));
        }
        if !inner.enabled {
            return Err(refusal(FreeState::Off));
        }
        let now_ms = unix_now() * 1000;
        match inner.state {
            FreeState::UsedThisMonth if inner.until_ms.is_some_and(|until| until > now_ms) => {
                Err(refusal(inner.state))
            }
            FreeState::Unsupported | FreeState::NotVerified | FreeState::StoreFailed => {
                Err(refusal(inner.state))
            }
            FreeState::ServiceOff | FreeState::Backoff
                if inner.retry_at.is_some_and(|at| at > Instant::now()) =>
            {
                Err(refusal(inner.state))
            }
            _ => Ok(()),
        }
    }

    async fn run_lease(&self) -> Result<(String, String), Box<Response<Body>>> {
        let (origin, provider, has_key, platform) = {
            let mut inner = self.lock();
            Self::set_state(&mut inner, FreeState::Checking, None);
            let (Some(origin), Some(provider)) = (inner.origin.clone(), inner.provider.clone())
            else {
                return Err(refusal(FreeState::Off));
            };
            (origin, provider, inner.has_key, inner.platform.clone())
        };
        let result = self.lease_steps(&origin, &provider, has_key, &platform).await;
        let mut inner = self.lock();
        // The provider changed while the lease ran: its answers do not count.
        if inner.provider.as_ref().is_none_or(|p| p.generation != provider.generation) {
            return Err(refusal(FreeState::Off));
        }
        // The setting turned off, or an account signed in, while the lease ran:
        // its token is dropped, never stored.
        if !inner.enabled || inner.signed_in {
            inner.token = None;
            Self::set_state(&mut inner, FreeState::Off, None);
            return Err(refusal(FreeState::Off));
        }
        let now = unix_now();
        match result {
            Ok((token, expires_at)) => {
                let bearer = token.expose().clone();
                inner.token = Some(Token { bearer: token, expires_at, month: utc_month(now) });
                inner.has_key = true;
                inner.failures = 0;
                inner.retry_at = None;
                Self::set_state(&mut inner, FreeState::Active, Some(expires_at * 1000));
                Ok((origin, bearer))
            }
            Err(error) => {
                let state = match &error {
                    LeaseError::App(code) if code == "unsupported" => FreeState::Unsupported,
                    LeaseError::App(code) if code == "disabled" => FreeState::Off,
                    LeaseError::App(code) if code == "store_failed" => FreeState::StoreFailed,
                    LeaseError::Server(_, code) if code == "free.not_configured" => {
                        inner.retry_at = Some(Instant::now() + SERVICE_OFF_RETRY);
                        FreeState::ServiceOff
                    }
                    LeaseError::Server(_, code) if code == "free.device_used" => {
                        FreeState::UsedThisMonth
                    }
                    LeaseError::Server(403, code)
                        if code == "free.attestation" || code == "free.devicecheck" =>
                    {
                        FreeState::NotVerified
                    }
                    _ => {
                        let delay = RETRY_DELAYS[inner.failures.min(RETRY_DELAYS.len() - 1)];
                        inner.failures += 1;
                        inner.retry_at = Some(Instant::now() + Duration::from_secs(delay));
                        FreeState::Backoff
                    }
                };
                // Backoff names its retry time, so a reader can wait for it (no fixed sleep).
                let until = match state {
                    FreeState::UsedThisMonth => Some(next_month_ms(now)),
                    FreeState::Backoff => Some(
                        unix_now_ms()
                            + inner.retry_at.map_or(0, |at| {
                                at.saturating_duration_since(Instant::now()).as_millis() as u64
                            }),
                    ),
                    _ => None,
                };
                tracing::info!(
                    "free tier lease: {}",
                    match &error {
                        LeaseError::App(code) => format!("app {code}"),
                        LeaseError::Server(status, code) => format!("api {status} {code}"),
                        LeaseError::Network => "api unreachable".to_owned(),
                        LeaseError::Gone => "provider gone".to_owned(),
                    }
                );
                Self::set_state(&mut inner, state, until);
                Err(refusal(state))
            }
        }
    }

    /// challenge -> assert -> /token; on a refused assertion (a new month) or
    /// an invalid key, attest one fresh key; with no key yet, attest the app's
    /// first key.
    async fn lease_steps(
        &self,
        origin: &str,
        provider: &Provider,
        has_key: bool,
        platform: &str,
    ) -> Result<(Secret<String>, u64), LeaseError> {
        let mut fresh = false;
        if has_key {
            let challenge = self.challenge(origin).await?;
            match provider.ask("assert", &challenge, None).await {
                Ok(reply) => {
                    let body = json!({
                        "key_id": field(&reply, "key_id")?,
                        "challenge": challenge,
                        "assertion": base64url(&field(&reply, "assertion")?),
                    });
                    match self.post_token(origin, "/v1/inference/free/token", &body).await {
                        // The grant's month ended (or the key is unknown): a fresh key, because
                        // App Attest refuses a second attestation of a key in a later launch
                        // (DCError.invalidKey, probe 1012-230124-237471 on macOS 27.0.1).
                        Err(LeaseError::Server(403, code)) if code == "free.assertion" => {
                            fresh = true;
                        }
                        other => return other,
                    }
                }
                Err(LeaseError::App(code)) if code == "invalid_key" => {
                    fresh = true;
                }
                Err(error) => return Err(error),
            }
        }
        loop {
            let challenge = self.challenge(origin).await?;
            let reply = match provider.ask("attest", &challenge, Some(fresh)).await {
                Ok(reply) => reply,
                Err(LeaseError::App(code)) if code == "invalid_key" && !fresh => {
                    fresh = true;
                    continue;
                }
                Err(error) => return Err(error),
            };
            // The app holds an attested key from here on: if the /attest reply is lost after the
            // server stored the grant, the next lease asserts first and spends no second grant.
            {
                let mut inner = self.lock();
                if inner.provider.as_ref().is_some_and(|p| p.generation == provider.generation) {
                    inner.has_key = true;
                }
            }
            let body = json!({
                "platform": platform,
                "key_id": field(&reply, "key_id")?,
                "attestation": base64url(&field(&reply, "attestation")?),
                "device_token": field(&reply, "device_token")?,
                "challenge": challenge,
            });
            return self.post_token(origin, "/v1/inference/free/attest", &body).await;
        }
    }

    async fn challenge(&self, origin: &str) -> Result<String, LeaseError> {
        let reply = self.post(origin, "/v1/inference/free/challenge", &json!({})).await?;
        let challenge =
            reply.get("challenge").and_then(Value::as_str).ok_or(LeaseError::Network)?;
        if challenge.is_empty() || challenge.len() > 256 {
            return Err(LeaseError::Network);
        }
        Ok(challenge.to_owned())
    }

    async fn post_token(
        &self,
        origin: &str,
        path: &str,
        body: &Value,
    ) -> Result<(Secret<String>, u64), LeaseError> {
        let reply = self.post(origin, path, body).await?;
        let token = reply.get("token").and_then(Value::as_str).ok_or(LeaseError::Network)?;
        let expires_ms =
            reply.get("expires_at").and_then(Value::as_u64).ok_or(LeaseError::Network)?;
        if token.is_empty() || token.len() > 8192 || token.contains(['\r', '\n']) {
            return Err(LeaseError::Network);
        }
        Ok((Secret::new(token.to_owned()), expires_ms / 1000))
    }

    async fn post(&self, origin: &str, path: &str, body: &Value) -> Result<Value, LeaseError> {
        let answer = self
            .http
            .post(format!("{origin}{path}"))
            .json(body)
            .timeout(Duration::from_secs(15))
            .send()
            .await
            .map_err(|_| LeaseError::Network)?;
        let status = answer.status().as_u16();
        let value: Value = answer.json().await.unwrap_or(Value::Null);
        if (200..300).contains(&status) {
            return Ok(value);
        }
        let code = value
            .pointer("/error/code")
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .chars()
            .filter(|c| c.is_ascii_alphanumeric() || *c == '.' || *c == '_')
            .take(64)
            .collect();
        Err(if status >= 500 && status != 503 {
            LeaseError::Network
        } else {
            LeaseError::Server(status, code)
        })
    }
}

impl Provider {
    /// One request to the app; the relay holds the lease lock, so only one is open.
    async fn ask(
        &self,
        req: &str,
        challenge: &str,
        fresh: Option<bool>,
    ) -> Result<Value, LeaseError> {
        let hash = Sha256::digest(challenge.as_bytes());
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let mut request = json!({
            "id": id,
            "req": req,
            "purpose": PURPOSE,
            "client_data_hash": base64::engine::general_purpose::STANDARD.encode(hash),
        });
        if let Some(fresh) = fresh {
            request.set("fresh_key", json!(fresh));
        }
        let (tx, rx) = oneshot::channel();
        self.pending.lock().unwrap_or_else(std::sync::PoisonError::into_inner).insert(id, tx);
        if self.out.send(request.to_string()).is_err() {
            return Err(LeaseError::Gone);
        }
        let reply = match tokio::time::timeout(PROVIDER_WAIT, rx).await {
            Ok(Ok(reply)) => reply,
            _ => {
                self.pending.lock().unwrap_or_else(std::sync::PoisonError::into_inner).remove(&id);
                return Err(LeaseError::Gone);
            }
        };
        if let Some(code) = reply.get("error").and_then(Value::as_str) {
            let code = match code {
                "unsupported" | "invalid_key" | "disabled" | "refused" | "busy"
                | "store_failed" => code,
                _ => "failed",
            };
            return Err(LeaseError::App(code.to_owned()));
        }
        Ok(reply)
    }
}

/// A string field of a provider reply: base64 text, bounded.
/// The same bytes as unpadded base64url. The token route decodes only base64url
/// (home-core device-proof b64u), so a standard-base64 proof from the app would
/// be refused there and every renewal would fall back to a fresh key.
fn base64url(value: &str) -> String {
    value.trim_end_matches('=').replace('+', "-").replace('/', "_")
}

fn field(reply: &Value, name: &str) -> Result<String, LeaseError> {
    let value = reply.get(name).and_then(Value::as_str).ok_or(LeaseError::App("failed".into()))?;
    if value.is_empty()
        || value.len() > 16_384
        || !value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'+' | b'/' | b'=' | b'-' | b'_'))
    {
        return Err(LeaseError::App("failed".into()));
    }
    Ok(value.to_owned())
}

/// The data-plane answer when no free token can be had (no vendor names).
fn refusal(state: FreeState) -> Box<Response<Body>> {
    let (status, code, message) = match state {
        FreeState::UsedThisMonth => (
            StatusCode::FORBIDDEN,
            "free.device_used",
            "This Mac already used its free AI access this month. Sign in to continue.",
        ),
        FreeState::Unsupported | FreeState::NotVerified => (
            StatusCode::UNAUTHORIZED,
            "free.sign_in_required",
            "This Mac cannot be verified for free AI access. Sign in to use AI models.",
        ),
        FreeState::ServiceOff => (
            StatusCode::SERVICE_UNAVAILABLE,
            "free.unavailable",
            "Free AI access is not available now. Sign in to use AI models.",
        ),
        FreeState::StoreFailed => (
            StatusCode::UNAUTHORIZED,
            "free.store_failed",
            "This Mac's Keychain refused access. Sign in to use AI models.",
        ),
        FreeState::Off => {
            (StatusCode::UNAUTHORIZED, "free.sign_in_required", "Sign in to use AI models.")
        }
        _ => (
            StatusCode::SERVICE_UNAVAILABLE,
            "free.unavailable",
            "Free AI access could not be checked. Try again in a moment.",
        ),
    };
    Box::new(crate::json_error(status, code, message))
}

/// The peer of one admin connection, read from the whole socket when it is
/// accepted, before the connection is split into read and write halves: the
/// facts [`provider_peer_allowed`] needs. Reading them is cheap; the app check
/// runs only when the connection asks to be the provider. Only
/// [`ProviderPeer::of_unix`] can make a peer that passes. Neither Clone nor
/// Copy: a peer read for one connection cannot be given to another
/// (`serve_with_admin` is public).
pub struct ProviderPeer {
    same_user: bool,
    #[cfg(target_os = "macos")]
    token: Option<cmux_link::app_caller::PeerToken>,
}

impl ProviderPeer {
    /// A peer that is never the provider: for a host that cannot read its
    /// peer's user and audit token. The Windows admin socket passes it, so
    /// Windows refuses `attest_provider` (providers are mac and ios only).
    pub fn refused() -> Self {
        Self {
            same_user: false,
            #[cfg(target_os = "macos")]
            token: None,
        }
    }

    /// The peer of an accepted unix socket: its user and, on macOS, its
    /// audit token.
    #[cfg(unix)]
    pub fn of_unix(stream: &tokio::net::UnixStream) -> Self {
        // SAFETY: geteuid has no preconditions.
        let own = unsafe { libc::geteuid() };
        Self {
            same_user: stream.peer_cred().is_ok_and(|cred| cred.uid() == own),
            #[cfg(target_os = "macos")]
            token: {
                use std::os::fd::AsRawFd;
                cmux_link::app_caller::peer_token(stream.as_raw_fd())
            },
        }
    }
}

/// Whether the peer of an admin connection may be the attestation provider:
/// the same user always; on a Team-signed macOS build also the signed cmux app
/// that contains this relay (cmux-link prover A, named by the audit token). A
/// DEV (ad-hoc) build checks the user only: a wrong provider can only deny the
/// free tier, never forge a proof (the API checks the attestation).
pub fn provider_peer_allowed(peer: &ProviderPeer) -> bool {
    if !peer.same_user {
        return false;
    }
    #[cfg(target_os = "macos")]
    if cmux_link::app_caller::signed_app_build() {
        let Some(token) = peer.token.as_ref() else {
            return false;
        };
        return cmux_link::app_caller::verify_containing_app(token).is_ok();
    }
    true
}

#[cfg(test)]
mod peer_tests {
    use super::*;

    #[test]
    fn a_peer_the_host_cannot_read_is_never_the_provider() {
        assert!(!provider_peer_allowed(&ProviderPeer::refused()));
    }

    /// Off macOS there is no app check: a same-user peer read at accept,
    /// before the split, may be the provider.
    #[cfg(all(unix, not(target_os = "macos")))]
    #[tokio::test]
    async fn a_same_user_unix_peer_read_at_accept_may_be_the_provider() {
        let (stream, _other) = tokio::net::UnixStream::pair().expect("socket pair");
        let peer = ProviderPeer::of_unix(&stream);
        let (_read, _write) = stream.into_split();
        assert!(provider_peer_allowed(&peer));
    }
}
