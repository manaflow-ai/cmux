//! The fault drill's carrier session: one real Cloud dial ([`super::client::dial`], the
//! first-dial state machine every carrier dial runs, with its relay-then-ssh routes and the
//! session's own reconnect), seen through the three things the drill needs of it
//! ([`CarrierSession`]): which carrier the session is on now, a `cmux.protocol/2` line stream
//! to the machine's daemon on it (a mux control stream, what `cmux carrier dial` bridges to its
//! stdio), and the kill of one carrier inside the running session
//! ([`super::source::CarrierRoutes::kill`]), after which the session resumes on the next route.
//!
//! No second dial loop and no second session protocol: the drill drives this one dial, and the
//! failover it records is the session's own. Only the probe's gated fault switch makes one
//! (`cli/cloud_start_chat/fault.rs`, after [`super::fault::probe_gate`]).

use std::sync::Arc;

use async_trait::async_trait;
use cmux_remote::bridge::OpenedMuxControl;
use cmux_remote::connection::ClientConnection;
use cmux_remote::service::ServiceMultiplexer;
use tokio::io::{AsyncBufRead, AsyncWrite, BufReader};
use tokio::time::Instant;
use zeroize::Zeroizing;

use super::fault::Route;
use super::source::{CarrierRoutes, CurrentRoute};
use super::{answer, client, contract, noise_key, route_log, ssh};

/// A `cmux.protocol/2` line stream to the machine's daemon over the session: lines written to
/// `writer` go to the daemon, its answers and pushes come on `reader`. Dropping it ends the
/// stream's pump.
pub(crate) struct Lines {
    pub reader: Box<dyn AsyncBufRead + Send + Unpin>,
    pub writer: Box<dyn AsyncWrite + Send + Unpin>,
    pump: Option<tokio::task::AbortHandle>,
}

impl Lines {
    /// `pump`, when there is one, is the task carrying the stream: aborted with it.
    pub(crate) fn new(
        reader: Box<dyn AsyncBufRead + Send + Unpin>,
        writer: Box<dyn AsyncWrite + Send + Unpin>,
        pump: Option<tokio::task::AbortHandle>,
    ) -> Self {
        Self { reader, writer, pump }
    }
}

impl Drop for Lines {
    fn drop(&mut self) {
        if let Some(pump) = self.pump.take() {
            pump.abort();
        }
    }
}

/// One running carrier session, as the drill drives it.
#[async_trait]
pub(crate) trait CarrierSession: Send + Sync {
    /// The carrier the session is on now (`None` before any connected).
    fn route(&self) -> Option<Route>;
    /// A new line stream to the daemon on the session, on whatever carrier carries it.
    async fn lines(&self) -> Result<Lines, String>;
    /// Kills every `route` carrier of the session: the session goes on over another one or
    /// ends. Answers how many it killed (0: the session has no such carrier).
    async fn kill(&self, route: Route) -> usize;
}

/// What the drill's dial needs: the machine, the cmux API and the signed-in app's credential
/// for it (`auth.token`), and the dial's one deadline.
pub(crate) struct DialSpec {
    pub machine: String,
    pub api: String,
    pub token: Zeroizing<String>,
    pub team: Option<String>,
    pub deadline: Instant,
}

/// The connect log's route word for the carrier the session is on (`relay:0`, `ssh:0`).
pub(crate) fn route_of(current: &str) -> Option<Route> {
    match current.split(':').next() {
        Some("relay") => Some(Route::Relay),
        Some("ssh") => Some(Route::Ssh),
        _ => None,
    }
}

struct Session {
    connection: Arc<ClientConnection>,
    multiplexer: Arc<ServiceMultiplexer>,
    routes: Arc<CarrierRoutes>,
    current: Arc<CurrentRoute>,
    /// Owns each `lines` call's pump; the session's drop cancels them.
    pumps: cmux_scope::Scope,
}

impl Drop for Session {
    fn drop(&mut self) {
        self.pumps.token().cancel();
        let (connection, multiplexer) = (self.connection.clone(), self.multiplexer.clone());
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            runtime.spawn(async move {
                multiplexer.shutdown().await;
                let _ = connection.close().await;
            });
        }
    }
}

#[async_trait]
impl CarrierSession for Session {
    fn route(&self) -> Option<Route> {
        route_of(self.current.get())
    }

    async fn lines(&self) -> Result<Lines, String> {
        let mux = OpenedMuxControl::open(&self.multiplexer).await.map_err(|error| {
            let tried = self.route().map(Route::name);
            mux_open_failure(&error.to_string(), self.connection.last_failure().as_deref(), tried)
        })?;
        let (ours, theirs) = tokio::io::duplex(1 << 20);
        let (their_reader, their_writer) = tokio::io::split(theirs);
        let pump = self.pumps.spawn_until_cancelled("drill mux pump", async move {
            let _ = mux.bridge(their_reader, their_writer).await;
        });
        let (reader, writer) = tokio::io::split(ours);
        Ok(Lines::new(
            Box::new(BufReader::new(reader)),
            Box::new(writer),
            Some(pump.abort_handle()),
        ))
    }

    async fn kill(&self, route: Route) -> usize {
        self.routes.kill(route).await
    }
}

/// The failure of a stream the session could not open. A session whose resume gave up is
/// closed, and its mux open says only `connection is closed`: the reason its last resume
/// failed is said after it, as the connect log's `why=` codes (on `tried`, the route the
/// session last moved to, for a code whose text names none), so the drill's record names the
/// step that ran out the resume window (cloud-carrier-ssh-failover, 2026-11-27 run
/// 46061527895, read nothing more). Codes only: never a host or a credential.
pub(crate) fn mux_open_failure(
    error: &str,
    last_resume: Option<&str>,
    tried: Option<&'static str>,
) -> String {
    let mut text = format!("the daemon did not open a mux control stream: {error}");
    if let Some(why) = last_resume.and_then(|detail| contract::why_codes_on(detail, tried)) {
        text.push_str(&format!(" (last resume: why={why})"));
    }
    text
}

/// Dials the machine of `spec` the way `cmux carrier dial` does (this device's carrier key,
/// the ssh route when this device has it, every attempt's lines in the connect log), and
/// answers its session.
pub(crate) async fn dial(spec: DialSpec) -> Result<Arc<dyn CarrierSession>, String> {
    if spec.team.as_deref().is_some_and(|team| !contract::valid_team(team)) {
        return Err("the app's team is not a cmux team id".into());
    }
    let api = crate::cli::secure_cloud_origin(spec.api.trim())?;
    let source = answer::HttpSource::new(api, answer::Credential::Value(spec.token), spec.team)?;
    let identity = noise_key::device_identity()?;
    let log_path = route_log::default_path();
    let phases_path = log_path.clone();
    let plan = client::DialPlan {
        machine: spec.machine,
        source: Arc::new(source),
        identity,
        deadline: spec.deadline,
        prefetched: Arc::new(answer::Prefetched::default()),
        log: Arc::new(move |line| {
            if let Some(path) = &log_path {
                route_log::append(path, &line);
            }
        }),
        phases: Arc::new(move |line| {
            if let Some(path) = &phases_path {
                route_log::append(path, &line);
            }
        }),
        fresh_sessions: contract::FreshSessions::default(),
        progress: None,
        ssh: Arc::new(ssh::SshSetup::from_env(None)),
        ssh_refusal: ssh::SshRefusal::default(),
        drill: true,
    };
    let dialed = client::dial(&plan)
        .await
        .map_err(|failure| format!("{}: {}", failure.step.error_code(), failure.detail))?;
    let client::Dialed { connection, multiplexer, mux, routes, current, .. } = dialed;
    // Each of the drill's streams opens its own mux control stream.
    mux.close().await;
    Ok(Arc::new(Session {
        connection,
        multiplexer,
        routes,
        current,
        pumps: cmux_scope::Scope::new("carrier drill session"),
    }))
}

#[cfg(test)]
#[path = "drill_dial_tests.rs"]
mod tests;
