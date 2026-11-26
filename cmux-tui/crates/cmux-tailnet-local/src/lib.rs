//! Read-only client for the system `tailscaled` LocalAPI, in pure Rust (no
//! Go, no libtailscale). It answers one question for the connection race:
//! for a peer's tailnet address, is the tailnet path direct right now, or
//! would it ride a relay (DERP or a peer relay)? A tailnet candidate is
//! worth offering when it is direct; through DERP it usually loses to a
//! path cmux owns.
//!
//! Layers:
//! - [`model`]: sans-I/O parse of `/localapi/v0/status`, `prefs` and
//!   `profiles/current` into a [`TailnetView`] with a [`PeerPath`] per peer.
//! - [`http`]: sans-I/O HTTP/1.1 (one GET, a bounded response).
//! - [`transport`]: where the LocalAPI listens on each OS (Unix socket, the
//!   macOS app's loopback port and same-user token, the Windows pipe) and
//!   one bounded call to it.
//! - [`cli`]: fallback to `tailscale status --json`.
//! - [`TailnetLocal`]: a cached snapshot for hot paths. `snapshot()` and
//!   `path_hint()` never wait on tailscaled; a background thread refreshes.
//!
//! Only GET on status, prefs, profiles/current and whois is possible: the
//! endpoint set is closed ([`http::Endpoint`]).
//!
//! Prior art: `acpmux::tailnet` reads the same status through the CLI for
//! discovery and WhoIs (an extra process per call, about 100 ms); the
//! embedded node (`cmux-tailnet`) has its own LocalAPI and links Go.
//!
//! iOS: the Tailscale app's LocalAPI lives in its sandbox and no other app
//! can reach it, so on iOS every call returns [`Error::Unavailable`] and the
//! host side has to supply path hints (for example by sending its own view,
//! which [`parse_status`] accepts with [`Source::Supplied`]).

pub mod cli;
pub mod http;
pub mod model;
mod snapshot;
pub mod transport;

pub use model::{
    ControlKind, ExitNode, Peer, PeerPath, Profile, SelfNode, Source, TailnetName, TailnetView,
    is_tailnet_ip, parse_prefs_control, parse_profile, parse_status,
};
pub use snapshot::{Fetcher, SnapshotConfig, TailnetLocal};
pub use transport::{Limits, Target};

use std::fmt;
use std::net::IpAddr;

use http::Endpoint;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Error {
    /// No way to reach tailscaled here (iOS, nothing installed).
    Unavailable(&'static str),
    /// The LocalAPI refused this user (403).
    Denied,
    Status(u16),
    Timeout,
    TooLarge,
    Io(String),
    Http(String),
    Parse(String),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unavailable(why) => write!(f, "tailscaled unavailable: {why}"),
            Self::Denied => f.write_str("tailscaled LocalAPI: access denied"),
            Self::Status(s) => write!(f, "tailscaled LocalAPI: HTTP {s}"),
            Self::Timeout => f.write_str("tailscaled LocalAPI: timed out"),
            Self::TooLarge => f.write_str("tailscaled LocalAPI: response too large"),
            Self::Io(e) => write!(f, "tailscaled LocalAPI: {e}"),
            Self::Http(e) => write!(f, "tailscaled LocalAPI: bad HTTP: {e}"),
            Self::Parse(e) => write!(f, "tailscaled LocalAPI: bad JSON: {e}"),
        }
    }
}

impl std::error::Error for Error {}

/// A connected LocalAPI: the first discovered target that answered status.
#[derive(Clone, Debug)]
pub struct LocalApi {
    target: Target,
    limits: Limits,
}

impl LocalApi {
    pub fn new(target: Target, limits: Limits) -> Self {
        Self { target, limits }
    }

    pub fn target(&self) -> &Target {
        &self.target
    }

    pub fn get(&self, endpoint: &Endpoint) -> Result<Vec<u8>, Error> {
        transport::get(&self.target, endpoint, &self.limits)
    }

    pub fn status(&self) -> Result<TailnetView, Error> {
        parse_status(&self.get(&Endpoint::Status)?, self.target.source())
    }

    /// Prefs' control server; `Unknown` when this user may not read prefs.
    pub fn control(&self) -> ControlKind {
        self.get(&Endpoint::Prefs)
            .and_then(|b| parse_prefs_control(&b))
            .unwrap_or(ControlKind::Unknown)
    }

    /// The current login profile; `None` when not readable (tailscaled
    /// answers 403 to a user who is not root or the operator).
    pub fn profile(&self) -> Option<Profile> {
        self.get(&Endpoint::ProfileCurrent).ok().and_then(|b| parse_profile(&b).ok())
    }

    /// Raw `whois` JSON for an address (`apitype.WhoIsResponse`).
    pub fn whois_json(&self, addr: IpAddr) -> Result<Vec<u8>, Error> {
        self.get(&Endpoint::WhoIs(addr.to_string()))
    }
}

/// Status, prefs and profile from the first target that answers; else the
/// CLI's status. Bounded by `limits.timeout` per call.
pub fn fetch_view(limits: &Limits) -> Result<TailnetView, Error> {
    fetch_view_with(limits, None).map(|(view, _)| view)
}

/// As [`fetch_view`], reusing `previous`'s prefs and profile when the node's
/// identity (state, node id, tailnet) has not changed: one call instead of
/// three on the steady path. Returns the target that answered.
pub fn fetch_view_with(
    limits: &Limits,
    previous: Option<&TailnetView>,
) -> Result<(TailnetView, Option<Target>), Error> {
    let mut last_err = None;
    for target in transport::discover() {
        let api = LocalApi::new(target, limits.clone());
        match api.status() {
            Ok(view) => {
                let view = match previous.filter(|p| p.identity_key() == view.identity_key()) {
                    Some(prev) => view.with_extras(prev.control.clone(), prev.profile.clone()),
                    None => {
                        let control = api.control();
                        view.with_extras(control, api.profile())
                    }
                };
                return Ok((view, Some(api.target)));
            }
            Err(e) => last_err = Some(e),
        }
    }
    match cli::cli_status(limits).and_then(|b| parse_status(&b, Source::Cli)) {
        Ok(view) => Ok((view, None)),
        Err(cli_err) => Err(last_err.unwrap_or(cli_err)),
    }
}
