//! The host loop: register, hold the signaling socket, admit and answer
//! dials, and serve each link's channels.

use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use cnx_link::api::{ApiClient, DeviceRegistration, IceCache, IceServer};
use cnx_link::dial::{self, SessionEvents};
use cnx_link::signaling::{SignalEnvelope, SignalPayload};
use cnx_link::{DialOptions, LinkConfig, SignalingClient, Timeline, TransportKind};

use crate::auth::{Tokens, claims};
use crate::config::{HostConfig, ServiceConfig};
use crate::control::{self, Event};
use crate::services::{self, Peer};

/// How the host answers dials on one signaling connection.
#[derive(Clone)]
pub struct AnswerContext {
    /// Only phones of this Stack user are admitted.
    pub owner_user_id: String,
    pub services: Arc<ServiceConfig>,
    /// ICE servers; `None` fetches `GET /v1/ice` per session.
    pub ice: IceSource,
    pub include_loopback: bool,
    pub exclude_cgnat: bool,
}

#[derive(Clone)]
pub enum IceSource {
    Fixed(Vec<IceServer>),
    /// `GET /v1/ice` with a current access token (the signaling socket
    /// outlives any one token), cached while the credentials have half
    /// their lifetime left and refreshed ahead of the next dial, so an
    /// answer never waits on an HTTP round trip.
    Api {
        base_url: String,
        tokens: Arc<Tokens>,
        cache: Arc<IceCache>,
    },
}

/// A signaling socket up at least this long reconnects after `QUICK_RECONNECT`.
const LONG_LIVED: Duration = Duration::from_secs(20);
const QUICK_RECONNECT: Duration = Duration::from_millis(150);

/// How long an answer waits for `GET /v1/ice` when nothing is cached.
const ICE_BUDGET: Duration = Duration::from_secs(5);

impl IceSource {
    pub fn api(base_url: String, tokens: Arc<Tokens>) -> Self {
        Self::Api { base_url, tokens, cache: Arc::new(IceCache::new()) }
    }

    /// The servers and whether they came from the cache.
    async fn servers(&self) -> (Vec<IceServer>, bool) {
        match self {
            Self::Fixed(servers) => (servers.clone(), true),
            Self::Api { base_url, tokens, cache } => {
                if let Some(servers) = cache.fresh() {
                    return (servers, true);
                }
                let token = match tokens.access_token().await {
                    Ok(token) => token,
                    Err(error) => {
                        tracing::warn!("no access token for GET /v1/ice ({error:#}); host candidates only");
                        return (Vec::new(), false);
                    }
                };
                cache.get(&ApiClient::new(base_url, &token), ICE_BUDGET).await
            }
        }
    }

    /// Measurement support (`CNX_BASELINE`): fetch per answer, as before the cache.
    async fn servers_uncached(&self) -> (Vec<IceServer>, bool) {
        if let Self::Api { cache, .. } = self {
            cache.clear();
        }
        self.servers().await
    }

    /// Keep the cache filled while the host runs: fetch now, then again
    /// whenever it is about to go stale.
    fn keep_fresh(&self) -> Option<tokio::task::JoinHandle<()>> {
        let Self::Api { .. } = self else { return None };
        let source = self.clone();
        Some(tokio::spawn(async move {
            loop {
                let (servers, _) = source.servers().await;
                let wait = if servers.is_empty() { Duration::from_secs(30) } else { Duration::from_secs(60) };
                tokio::time::sleep(wait).await;
            }
        }))
    }
}

/// When a phone first registered (`GET /v1/me/devices` `createdAt`), for the
/// pairing prompt. Every phone that may dial is the Mac owner's own device.
fn registration_lookup(base_url: String, tokens: Arc<Tokens>) -> crate::pairing::RegistrationLookup {
    Arc::new(move |phone: String| {
        let (base_url, tokens) = (base_url.clone(), Arc::clone(&tokens));
        Box::pin(async move {
            let token = tokens.access_token().await.ok()?;
            let devices = ApiClient::new(&base_url, &token).my_devices().await.ok()?;
            devices
                .into_iter()
                .find(|d| d.device_id.eq_ignore_ascii_case(&phone) && d.kind != "mac")
                .and_then(|d| d.created_at)
                .and_then(|at| crate::pairing::epoch_millis(&at))
        })
    })
}

/// Run until the process is stopped, reconnecting with backoff. Returns `Ok` only when
/// the owner removed this Mac (`removed`): registering again would undo that.
pub async fn run(config: HostConfig) -> Result<()> {
    let tokens = Arc::new(Tokens::new(config.tokens.clone()));
    let mut services = config.services.clone();
    if let Some(pairing) = services.pairing.as_mut() {
        pairing.registration = Some(registration_lookup(config.base_url.clone(), Arc::clone(&tokens)));
    }
    let services = Arc::new(services);
    // One ICE cache for the life of the process (reconnects keep it).
    let ice = IceSource::api(config.base_url.clone(), Arc::clone(&tokens));
    if crate::notify::enabled() {
        tokio::spawn(crate::notify::run(
            config.base_url.clone(),
            config.device_id.clone(),
            Arc::clone(&tokens),
            config.services.acpmux.clone(),
        ));
    }
    let mut backoff = Duration::from_secs(1);
    loop {
        control::emit(&Event::Connecting);
        let started = std::time::Instant::now();
        let reason = match connect_once(&config, &tokens, &services, &ice).await {
            Ok(reason) if removed(&reason) => {
                // Registering again would undo the owner's removal: stop for good.
                tracing::warn!(reason, "this Mac was removed from the account's devices; stopping");
                control::emit(&Event::Removed);
                return Ok(());
            }
            Ok(reason) => {
                tracing::warn!(reason, "signaling ended; reconnecting");
                // A socket that was up for a while and then reset (every Worker
                // deploy resets all sockets) comes back at once, so a phone
                // dialing now finds the Mac; quick repeated failures back off.
                backoff =
                    if started.elapsed() > LONG_LIVED { QUICK_RECONNECT } else { Duration::from_secs(1) };
                reason
            }
            Err(error) => {
                tracing::warn!("connection attempt failed: {error:#}");
                // Only a refusal of the token itself marks it refused; a network error or a
                // server error keeps it (the supervising app would otherwise refresh on every retry).
                if unauthorized(&error) {
                    tokens.invalidate().await;
                }
                backoff = (backoff * 2).min(Duration::from_secs(60));
                format!("{error:#}")
            }
        };
        control::emit(&Event::Waiting { reason, retry_in_seconds: backoff.as_secs() });
        tokio::time::sleep(backoff).await;
    }
}

async fn connect_once(
    config: &HostConfig,
    tokens: &Arc<Tokens>,
    services: &Arc<ServiceConfig>,
    ice: &IceSource,
) -> Result<String> {
    let token = tokens.access_token().await.context("access token")?;
    let owner = config
        .owner_user_id
        .clone()
        .or_else(|| claims(&token).sub)
        .context("the access token has no sub; set CNX_OWNER_USER_ID")?;
    let api = ApiClient::new(&config.base_url, &token);
    let device = api
        .register_device(&DeviceRegistration {
            device_id: config.device_id.clone(),
            kind: "mac".into(),
            name: config.device_name.clone(),
            team_id: config.team_id.clone(),
            wg_public_key: None,
        })
        .await
        .context("POST /v1/devices")?;
    tracing::info!(device = %device, "registered");
    let signaling = SignalingClient::connect(&config.base_url, &token, &config.team_id, &config.device_id)
        .await
        .context("signaling connect")?;
    tracing::info!(device_id = config.device_id, "signaling connected");
    control::emit(&Event::Online { device_id: config.device_id.clone(), team_id: config.team_id.clone() });
    let context = AnswerContext {
        owner_user_id: owner,
        services: Arc::clone(services),
        ice: ice.clone(),
        include_loopback: config.include_loopback,
        exclude_cgnat: config.exclude_cgnat,
    };
    let refresher = if std::env::var_os("CNX_BASELINE").is_some() { None } else { ice.keep_fresh() };
    let reason = serve_signaling(signaling, context).await;
    if let Some(task) = refresher {
        task.abort();
    }
    Ok(reason)
}

/// hostd's exit status after the owner removed this Mac (`removed`): a supervisor must not restart it.
pub const EXIT_REMOVED: i32 = 78;

/// Whether the signaling socket closed because the owner removed this device
/// (`DELETE /v1/devices/:id` closes it with 4002 `removed`, PROTOCOL.md).
pub fn removed(reason: &str) -> bool {
    reason.starts_with("signaling closed by server: 4002 ")
}

/// Whether `error` is the backend refusing the access token (HTTP 401 from the API or
/// the signaling upgrade).
pub fn unauthorized(error: &anyhow::Error) -> bool {
    error.chain().any(|cause| {
        if let Some(cnx_link::api::ApiError::Status { status, .. }) =
            cause.downcast_ref::<cnx_link::api::ApiError>()
        {
            return *status == 401;
        }
        if let Some(cnx_link::signaling::SignalingError::Connect(message)) =
            cause.downcast_ref::<cnx_link::signaling::SignalingError>()
        {
            return message.contains("401");
        }
        false
    })
}

/// Answer every admitted dial on `signaling` until it closes; returns the
/// close reason.
pub async fn serve_signaling(signaling: SignalingClient, context: AnswerContext) -> String {
    let mut events = signaling.events();
    loop {
        let session = tokio::select! {
            session = signaling.next_session() => match session {
                Some(session) => session,
                None => return signaling.closed_reason().unwrap_or_else(|| "signaling closed".into()),
            },
            event = events.recv() => match event {
                Ok(cnx_link::signaling::SignalingEvent::Disconnected(reason)) => return reason,
                Ok(cnx_link::signaling::SignalingEvent::Error { code, message, session_id }) => {
                    tracing::debug!(code, message, ?session_id, "backend error");
                    continue;
                }
                Ok(_) | Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(_) => return "signaling closed".into(),
            },
        };
        let envelope = session.first;
        let Some(kind) = TransportKind::for_first_signal(&envelope.payload) else { continue };
        if !admitted(&envelope, &context.owner_user_id) {
            tracing::warn!(from = envelope.from, user = ?envelope.from_user_id, "refusing a dial from another user");
            signaling.unsubscribe(&envelope.session_id);
            let _ = signaling.send_signal(
                &envelope.from,
                &envelope.session_id,
                SignalPayload::Bye { reason: "not_admitted".into() },
            );
            continue;
        }
        let session_events = SessionEvents {
            session: session.events,
            backend: signaling.events(),
            session_id: envelope.session_id.clone(),
        };
        tokio::spawn(answer_session(signaling.clone(), envelope, session_events, kind, context.clone()));
    }
}

/// v1 admission (PROTOCOL.md): the dialing phone belongs to the Mac's own
/// Stack user, as stamped by the backend in `fromUserId`. Missing means deny.
pub fn admitted(envelope: &SignalEnvelope, owner_user_id: &str) -> bool {
    envelope.from_user_id.as_deref() == Some(owner_user_id)
}

async fn answer_session(
    signaling: SignalingClient,
    first: SignalEnvelope,
    events: SessionEvents,
    kind: TransportKind,
    context: AnswerContext,
) {
    let peer = Peer { device_id: first.from.clone(), session_id: first.session_id.clone() };
    let session_id = first.session_id.clone();
    let timeline = Timeline::new();
    timeline.mark("offer_received");
    let baseline = std::env::var_os("CNX_BASELINE").is_some();
    let (ice_servers, cached) =
        if baseline { context.ice.servers_uncached().await } else { context.ice.servers().await };
    timeline.mark(if cached { "ice_servers_cached" } else { "ice_servers_fetched" });
    let options = DialOptions {
        ice_servers,
        include_loopback: context.include_loopback,
        exclude_cgnat: context.exclude_cgnat,
        timeline: timeline.clone(),
        stock_ice_waits: baseline,
        ..DialOptions::default()
    };
    let connected = match dial::answer(&signaling, first, events, &options, LinkConfig::default()).await {
        Ok(connected) => connected,
        Err(error) => {
            tracing::warn!(session_id, ?kind, %error, timings = %timeline.summary(), "answer failed");
            return;
        }
    };
    let path = *connected.path.borrow();
    tracing::info!(session_id, ?kind, ?path, phone = peer.device_id, timings = %timeline.summary(), "link up");
    control::emit(&Event::PhoneUp {
        session_id: session_id.clone(),
        phone_device_id: peer.device_id.clone(),
        transport: control::transport_name(kind).into(),
        path: control::path_name(path).into(),
    });
    let mut paths = connected.path.clone();
    let path_session = session_id.clone();
    let path_watch = tokio::spawn(async move {
        while paths.changed().await.is_ok() {
            let path = *paths.borrow_and_update();
            control::emit(&Event::PhonePath {
                session_id: path_session.clone(),
                path: control::path_name(path).into(),
            });
        }
    });
    let auth = Arc::new(crate::pairing::LinkAuth::default());
    // The owner removed this phone (Settings > Mobile > Remove): end its link now.
    let mut drops = control::drops();
    let removable = connected.link.clone();
    let phone = peer.device_id.to_lowercase();
    let drop_watch = tokio::spawn(async move {
        loop {
            match drops.recv().await {
                Ok(id) if id == phone => {
                    removable.close("removed");
                    return;
                }
                Ok(_) | Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
                Err(_) => return,
            }
        }
    });
    let mut first = true;
    while let Some(incoming) = connected.link.accept().await {
        if first {
            first = false;
            timeline.mark("first_channel");
            tracing::info!(session_id, timings = %timeline.summary(), "first channel");
        }
        // In open order: a channel opened after `auth` waits for it. One
        // `auth` runs at a time per link.
        if incoming.service == "auth" && context.services.pairing.is_some() && !auth.try_begin() {
            tokio::spawn(services::refuse(incoming, "busy", "this iPhone's pairing is already running"));
            continue;
        }
        if incoming.service == "auth" && context.services.pairing.is_none() {
            auth.begin();
        }
        tokio::spawn(services::serve(
            Arc::clone(&context.services),
            peer.clone(),
            Arc::clone(&auth),
            incoming,
        ));
    }
    let reason = connected.link.closed().await;
    path_watch.abort();
    drop_watch.abort();
    tracing::info!(session_id, reason, "link down");
    control::emit(&Event::PhoneDown { session_id, reason });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_4002_close_is_a_removal() {
        assert!(removed("signaling closed by server: 4002 removed"));
        assert!(!removed("signaling closed by server: 4000 replaced"));
        assert!(!removed("signaling closed by server: 4001 moved"));
        assert!(!removed("signaling read failed: 4002"));
        assert!(!removed("signaling socket closed"));
    }

    #[test]
    fn only_a_401_marks_the_token_refused() {
        let refused =
            anyhow::Error::new(cnx_link::api::ApiError::Status { status: 401, body: String::new() })
                .context("POST /v1/devices");
        assert!(unauthorized(&refused));
        let upgrade = anyhow::Error::new(cnx_link::signaling::SignalingError::Connect(
            "HTTP error: 401 Unauthorized".into(),
        ));
        assert!(unauthorized(&upgrade));
        let server = anyhow::Error::new(cnx_link::api::ApiError::Status { status: 502, body: String::new() });
        assert!(!unauthorized(&server));
        assert!(!unauthorized(&anyhow::Error::new(cnx_link::api::ApiError::Http("dns".into()))));
        assert!(!unauthorized(&anyhow::anyhow!("the app sent no access token")));
    }
}
