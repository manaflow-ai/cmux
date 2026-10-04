//! Port forwards and browser proxy routes (cloud-app.md 3.5): `cloud.port.*`
//! and `cloud.browser.open`.
//!
//! [`Edge`] is the only writer of forward and route state; the op loop is
//! its only caller. One forward per (machine, port) and one proxy route per
//! machine. Each listens on 127.0.0.1 and a random port and carries bytes
//! through the machine's link ([`PortTunnel`]). A forward belongs to one
//! link generation: when that link goes down (or a new one replaces it) the
//! forward's listener and connections close and the record shows `down`.
//! Nothing is queued for a later link; `cloud.port.forward` opens a new
//! listener on the new link.

pub(crate) mod listener;
#[cfg(unix)]
mod loopback;
pub mod tunnel;

#[cfg(unix)]
pub use loopback::LoopbackTunnel;
pub use tunnel::{PortTunnel, TunnelAbort, TunnelConn, TunnelError, TunnelWrite};

use crate::connector::iface::Carrier;
use crate::fs::transfer::{OpenSshTransfer, Transfer};
use crate::link::LinkSupervisor;
use listener::{Handler, Listener, Session};
use std::collections::BTreeMap;
use std::net::TcpStream;
use std::sync::Arc;

mod ops;
pub(crate) use ops::{live_state_op, run, serves};

/// Forwards plus proxy routes one server keeps at most.
pub const MAX_LISTENERS: usize = 64;

pub(crate) struct Forward {
    pub(crate) listener: Option<Listener>,
    pub(crate) local_port: u16,
    pub(crate) generation: u64,
    pub(crate) down: Option<String>,
}

impl Forward {
    fn close(&mut self, reason: &str) {
        if let Some(mut listener) = self.listener.take() {
            listener.close();
        }
        if self.down.is_none() {
            self.down = Some(reason.to_owned());
        }
    }
}

/// Files transfers, forwards and proxy routes of this server.
pub struct Edge {
    pub(crate) tunnel: Arc<dyn PortTunnel>,
    pub(crate) transfer: Box<dyn Transfer>,
    pub(crate) forwards: BTreeMap<(String, u16), Forward>,
    pub(crate) proxies: BTreeMap<String, Forward>,
}

/// A tunnel for platforms without Unix sockets: every open fails.
#[cfg(not(unix))]
struct NoTunnel;

#[cfg(not(unix))]
impl PortTunnel for NoTunnel {
    fn open(&self, _: &Carrier, _: &str, _: u16) -> Result<TunnelConn, TunnelError> {
        Err(TunnelError::Unsupported("port forwarding needs a Unix link socket".into()))
    }
}

impl Edge {
    pub fn new(tunnel: Arc<dyn PortTunnel>, transfer: Box<dyn Transfer>) -> Self {
        Self { tunnel, transfer, forwards: BTreeMap::new(), proxies: BTreeMap::new() }
    }

    /// The real tunnel (`loopback-forward-v1` on the link socket) and the
    /// real transfer (OpenSSH with an in-memory key).
    pub fn real() -> Self {
        #[cfg(unix)]
        let tunnel: Arc<dyn PortTunnel> = Arc::new(LoopbackTunnel);
        #[cfg(not(unix))]
        let tunnel: Arc<dyn PortTunnel> = Arc::new(NoTunnel);
        Self::new(tunnel, Box::new(OpenSshTransfer::default()))
    }

    fn listeners(&self) -> usize {
        self.forwards.values().chain(self.proxies.values()).filter(|f| f.down.is_none()).count()
    }

    /// Closes every forward and route whose link generation is not the live
    /// one. Reads link state only; never blocks.
    pub(crate) fn reconcile(&mut self, links: &LinkSupervisor) {
        let live = |machine: &str| links.carrier(machine).map(|c| c.generation);
        for ((machine, _), forward) in &mut self.forwards {
            if forward.down.is_none() && live(machine) != Some(forward.generation) {
                forward.close("the link to the machine went down");
            }
        }
        for (machine, route) in &mut self.proxies {
            if route.down.is_none() && live(machine) != Some(route.generation) {
                route.close("the link to the machine went down");
            }
        }
    }

    /// A listener whose connections each open one stream to `host:port`.
    pub(crate) fn forward_handler(&self, carrier: &Carrier, host: &str, port: u16) -> Handler {
        let tunnel = Arc::clone(&self.tunnel);
        let carrier = carrier.clone();
        let host = host.to_owned();
        let identity = LinkIdentity::of(&carrier);
        Arc::new(move |tcp: TcpStream, session: &Session| {
            // A dead or replaced link fails the open: the connection closes,
            // nothing waits.
            if !identity.still(&carrier) {
                return;
            }
            if let Ok(conn) = tunnel.open(&carrier, &host, port) {
                session.splice(tcp, conn, Vec::new());
            }
        })
    }
}

/// The link socket file as it was when a forward or route opened. A new link
/// generation for the same machine binds a new socket file at the same path,
/// so a listener of an old generation compares the file identity before each
/// stream and never reaches the new link (the op loop closes it at the next
/// op). `None` when the file did not exist (fakes): then only the tunnel's
/// own open decides.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LinkIdentity(Option<(u64, u64)>);

impl LinkIdentity {
    pub fn of(carrier: &Carrier) -> Self {
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt as _;
            Self(std::fs::metadata(&carrier.socket).ok().map(|m| (m.dev(), m.ino())))
        }
        #[cfg(not(unix))]
        {
            let _ = carrier;
            Self(None)
        }
    }

    /// True while the socket file is the one this identity saw.
    pub fn still(&self, carrier: &Carrier) -> bool {
        self.0.is_none() || Self::of(carrier) == *self
    }
}

impl Drop for Edge {
    fn drop(&mut self) {
        for forward in self.forwards.values_mut().chain(self.proxies.values_mut()) {
            forward.close("the Cloud app server stopped");
        }
    }
}
