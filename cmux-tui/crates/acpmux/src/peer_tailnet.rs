//! Part of `Peer` (`peer.rs`). The opt-in tailnet path (`Via::Tailnet`, `tailnet_carrier.rs`,
//! RFD 0164 "Tailnet carrier", slice T6).
//!
//! The setting `CMUX_TAILNET_CARRIER` is off by default; off, nothing here calls tailscale and
//! the peer has no tailnet path. On, the peer's configured host is matched against the cached
//! `tailscale status` snapshot ([`crate::tailnet_carrier::route_for`]): when it names one online
//! node of this tailnet whose path the mode offers, the peer gains a [`Via::Tailnet`] path that
//! dials that node's tailnet address at the peer's listener port, joins the cold-connect race and
//! the probe set like every other path, and carries the session only when the selector finds it
//! faster. A snapshot that stops offering it (the path went through DERP under `direct-only`, the
//! node went offline, the setting's host changed) takes the path out again.

use super::Peer;
use super::carriers::BoxDuplex;
use crate::no_panic::LockExt;
use crate::peer_paths::Via;
use crate::tailnet_carrier::{Mode, Route, Snapshots, route_for};
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Duration;

/// How long the very first status read may delay a cold connect.
const FIRST_READ_WAIT: Duration = Duration::from_millis(200);
/// How often the watcher reads the snapshot (a path that flipped to DERP is demoted then).
const WATCH_EVERY: Duration = Duration::from_secs(10);

pub(super) struct State {
    mode: Mode,
    snaps: Option<Arc<Snapshots>>,
    route: Option<Route>,
    watching: bool,
}

impl State {
    pub(super) fn from_env() -> Self {
        Self::with(Mode::from_env(), None)
    }

    /// `mode` over `snaps` (the installed CLI's when None).
    pub(super) fn with(mode: Mode, snaps: Option<Arc<Snapshots>>) -> Self {
        Self { mode, snaps, route: None, watching: false }
    }
}

impl Peer {
    /// The host the peer is configured with: an ssh destination's host or the URL's.
    fn tailnet_host(&self) -> Option<String> {
        if let Some((destination, _)) = self.ssh_parts() {
            return Some(destination.rsplit('@').next()?.to_owned());
        }
        let uri: tokio_tungstenite::tungstenite::http::Uri = self.url.parse().ok()?;
        uri.host().map(str::to_owned)
    }

    /// The port of the peer's listener, the same one its ssh tunnel or URL names.
    fn tailnet_port(&self) -> Option<u16> {
        if let Some((_, port)) = self.ssh_parts() {
            return Some(port);
        }
        let uri: tokio_tungstenite::tungstenite::http::Uri = self.url.parse().ok()?;
        uri.port_u16().or(match uri.scheme_str() {
            Some("wss") => Some(443),
            Some("ws") => Some(80),
            _ => None,
        })
    }

    /// The route the last snapshot gave this peer (memory only).
    pub(super) fn tailnet_route(&self) -> Option<Route> {
        self.tailnet.lock_or_recover().route
    }

    /// Read the snapshot and keep this peer's tailnet path in step with it. `wait` bounds an
    /// await of tailscale: None is the cold connect's (a first read only, briefly; else memory).
    /// Under [`Mode::Off`] it returns at once and tailscale is never called.
    pub(super) async fn refresh_tailnet(self: &Arc<Self>, wait: Option<Duration>) {
        let (mode, snaps) = {
            let state = self.tailnet.lock_or_recover();
            (state.mode, state.snaps.clone())
        };
        if mode == Mode::Off {
            return;
        }
        let snaps = snaps.unwrap_or_else(Snapshots::global);
        let wait = wait.unwrap_or(if snaps.loaded() { Duration::ZERO } else { FIRST_READ_WAIT });
        let status = snaps.get(wait).await;
        let route = status.and_then(|status| {
            let host = self.tailnet_host()?;
            // A URL that already names the tailnet node is that path itself.
            if self.ssh_parts().is_none()
                && let Some(node) = status.peers.iter().find(|n| {
                    host.parse::<std::net::IpAddr>().is_ok_and(|ip| n.ips.contains(&ip))
                        || n.dns_name.eq_ignore_ascii_case(&host)
                })
            {
                let _ = node;
                return None;
            }
            route_for(&status, &host, mode)
        });
        self.apply_tailnet_route(route);
    }

    /// Make the path set match `route`.
    pub(super) fn apply_tailnet_route(self: &Arc<Self>, route: Option<Route>) {
        let before = std::mem::replace(&mut self.tailnet.lock_or_recover().route, route);
        if before == route {
            return;
        }
        match route {
            Some(route) => {
                let added = self.with_paths(|paths| {
                    let added = paths.add(Via::Tailnet);
                    paths.set_tailnet_relayed(route.relayed());
                    added
                });
                if added {
                    tracing::info!(peer = %self.name, hint = ?route.path, "a tailnet path to this machine is a candidate");
                    if self.link().is_ready() {
                        if self.probing.load(Ordering::SeqCst) {
                            self.scope.spawn_named(
                                "peer-tailnet-probe",
                                self.clone().probe(Via::Tailnet),
                            );
                        } else {
                            self.start_probes();
                        }
                    }
                }
            }
            None => {
                let switch = self.with_paths(|paths| paths.remove(Via::Tailnet));
                if switch.is_some() {
                    tracing::info!(peer = %self.name, "the tailnet path to this machine is no longer offered");
                }
                self.after_switch(switch.flatten().map(Some));
            }
        }
    }

    /// Re-read the snapshot every [`WATCH_EVERY`] until the peer stops; once per peer.
    pub(super) fn watch_tailnet(self: &Arc<Self>) {
        {
            let mut state = self.tailnet.lock_or_recover();
            if state.mode == Mode::Off || state.watching {
                return;
            }
            state.watching = true;
        }
        let peer = self.clone();
        self.scope.spawn_named("peer-tailnet-watch", async move {
            let mut stopped = peer.stop_changed.subscribe();
            loop {
                tokio::select! {
                    () = tokio::time::sleep(WATCH_EVERY) => {}
                    _ = stopped.changed() => return,
                }
                if *stopped.borrow() {
                    return;
                }
                peer.refresh_tailnet(Some(Duration::from_secs(3))).await;
            }
        });
    }

    /// A raw stream to the peer's listener at its tailnet address.
    pub(super) async fn tailnet_stream(&self) -> Result<(BoxDuplex, String), String> {
        let route =
            self.tailnet_route().ok_or_else(|| "no tailnet path to this machine".to_owned())?;
        let port = self.tailnet_port().ok_or_else(|| "the peer URL names no port".to_owned())?;
        let tcp = tokio::net::TcpStream::connect(std::net::SocketAddr::new(route.ip, port))
            .await
            .map_err(|e| format!("tailnet {}:{port}: {e}", route.ip))?;
        let _ = tcp.set_nodelay(true);
        // Host `localhost:port`, as on the other direct paths: the listener's Host rule.
        Ok((Box::new(tcp), format!("ws://localhost:{port}")))
    }
}
