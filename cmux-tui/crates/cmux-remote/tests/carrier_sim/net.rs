//! The simulated carrier network: in-memory [`FrameLink`] pairs on two routes (the relay the
//! session starts on and the one a carrier swap moves it to), opened through a [`LinkGroup`]
//! as the relay provider opens them, with the faults a real carrier has.
//!
//! A link is ordered and lossless while it is up, as a WebSocket over TCP is: a frame is never
//! dropped or reordered inside one link. The faults are the ones a carrier shows:
//!
//! - **cut**: every link on the route closes at once and what it still held is lost (a relay
//!   restart, a TCP reset);
//! - **freeze**: nothing moves, one way or both, sockets open; what was sent waits and arrives
//!   when the freeze ends, as TCP retransmits it (a dropped network, a sleeping laptop);
//! - **down**: the route takes no new link while it lasts (the network is gone, or the relay
//!   has no daemon registered);
//! - **slow**: every frame's latency is multiplied.
//!
//! Reorder happens where it can: across lanes (each lane has its own link with its own
//! latency) and across generations (a frozen old link delivers late, after the session has
//! moved on).

use std::collections::VecDeque;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use bytes::Bytes;
use cmux_remote::crypto::NetworkPeer;
use cmux_remote::daemon::{InboundLink, RemoteDaemon};
use cmux_remote::link::{FrameLink, LinkError};
use cmux_remote::provider::{
    CarrierEvidence, LinkGroup, LinkRequest, ProviderCapabilities, ProviderError,
};
use tokio::sync::watch;
use tokio::time::Instant;

use crate::rng::Rng;

/// The frame size the e2e tests' links allow (`session_expiry_e2e.rs`).
pub const MAXIMUM_FRAME_BYTES: usize = 65_535;

pub fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// What a route does to its links right now.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Conditions {
    /// Client to daemon frames wait.
    pub frozen_up: bool,
    /// Daemon to client frames wait.
    pub frozen_down: bool,
    /// New links are refused.
    pub down: bool,
    /// Latency multiplier (1 is normal).
    pub slow: u32,
}

/// One direction of one link: frames with the time each may arrive, in order.
struct Direction {
    state: Mutex<DirectionState>,
    changed: watch::Sender<u64>,
}

#[derive(Default)]
struct DirectionState {
    queue: VecDeque<(Instant, Bytes)>,
    /// Cut: nothing more arrives, what was queued is lost.
    cut: bool,
    /// The sender closed: what was queued still arrives, then the end.
    finished: bool,
    last_at: Option<Instant>,
}

impl Direction {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            state: Mutex::new(DirectionState::default()),
            changed: watch::channel(0).0,
        })
    }

    fn poke(&self) {
        self.changed.send_modify(|n| *n = n.wrapping_add(1));
    }

    fn cut(&self) {
        {
            let mut s = lock(&self.state);
            s.cut = true;
            s.queue.clear();
        }
        self.poke();
    }

    fn finish(&self) {
        lock(&self.state).finished = true;
        self.poke();
    }
}

/// A route: one relay (or the network under it), with its links and their conditions.
pub struct Route {
    pub name: &'static str,
    conditions: watch::Sender<Conditions>,
    links: Mutex<Vec<(Arc<Direction>, Arc<Direction>)>>,
    rng: Mutex<Rng>,
    /// Base one-way latency range, ms.
    latency_ms: (u64, u64),
    pub opened: Mutex<u64>,
    /// The run's trace: each link's end, and which side ended it.
    trace: Arc<Mutex<Vec<String>>>,
    born: Instant,
}

impl Route {
    pub fn new(
        name: &'static str,
        rng: Rng,
        latency_ms: (u64, u64),
        trace: Arc<Mutex<Vec<String>>>,
    ) -> Arc<Self> {
        Arc::new(Self {
            name,
            conditions: watch::channel(Conditions { slow: 1, ..Conditions::default() }).0,
            links: Mutex::new(Vec::new()),
            rng: Mutex::new(rng),
            latency_ms,
            opened: Mutex::new(0),
            trace,
            born: Instant::now(),
        })
    }

    pub fn conditions(&self) -> Conditions {
        *self.conditions.borrow()
    }

    pub fn set(&self, f: impl FnOnce(&mut Conditions)) {
        self.conditions.send_modify(f);
    }

    /// Close every link on the route; what they held is lost.
    pub fn cut(&self) {
        self.note(format!("{} cut", self.name));
        let links = std::mem::take(&mut *lock(&self.links));
        for (up, down) in links {
            up.cut();
            down.cut();
        }
    }

    fn note(&self, what: String) {
        lock(&self.trace).push(format!("{:?} {what}", self.born.elapsed()));
    }

    fn latency(&self) -> Duration {
        let (lo, hi) = self.latency_ms;
        let ms = lock(&self.rng).range(lo, hi);
        Duration::from_millis(ms * u64::from(self.conditions().slow.max(1)))
    }

    /// A new link pair: the client's end and the daemon's.
    fn pair(self: &Arc<Self>, label: String) -> (SimLink, SimLink) {
        let up = Direction::new();
        let down = Direction::new();
        lock(&self.links).push((up.clone(), down.clone()));
        *lock(&self.opened) += 1;
        let client = SimLink {
            description: format!("sim {} {label} client", self.name),
            route: self.clone(),
            outgoing: up.clone(),
            incoming: down.clone(),
            upward: true,
        };
        let daemon = SimLink {
            description: format!("sim {} {label} daemon", self.name),
            route: self.clone(),
            outgoing: down,
            incoming: up,
            upward: false,
        };
        (client, daemon)
    }
}

pub struct SimLink {
    description: String,
    route: Arc<Route>,
    outgoing: Arc<Direction>,
    incoming: Arc<Direction>,
    /// This end sends client to daemon.
    upward: bool,
}

impl SimLink {
    fn frozen(&self, c: &Conditions, outgoing: bool) -> bool {
        // The direction a frame travels: up when the client's end sends it.
        if self.upward == outgoing { c.frozen_up } else { c.frozen_down }
    }
}

#[async_trait]
impl FrameLink for SimLink {
    fn description(&self) -> &str {
        &self.description
    }

    fn maximum_frame_bytes(&self) -> usize {
        MAXIMUM_FRAME_BYTES
    }

    async fn send(&self, frame: Bytes) -> Result<(), LinkError> {
        if frame.len() > MAXIMUM_FRAME_BYTES {
            return Err(LinkError::FrameTooLarge {
                actual: frame.len(),
                maximum: MAXIMUM_FRAME_BYTES,
            });
        }
        let latency = self.route.latency();
        {
            let mut s = lock(&self.outgoing.state);
            if s.cut {
                return Err(LinkError::Transport("sim: carrier cut".into()));
            }
            if s.finished {
                return Err(LinkError::Closed);
            }
            // In order: never before the frame ahead of it.
            let at = (Instant::now() + latency).max(s.last_at.unwrap_or_else(Instant::now));
            s.last_at = Some(at);
            s.queue.push_back((at, frame));
        }
        self.outgoing.poke();
        Ok(())
    }

    async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
        let mut changed = self.incoming.changed.subscribe();
        let mut conditions = self.route.conditions.subscribe();
        loop {
            let wait = {
                let mut s = lock(&self.incoming.state);
                if s.cut {
                    return Err(LinkError::Transport("sim: carrier cut".into()));
                }
                let frozen = self.frozen(&conditions.borrow_and_update(), false);
                match s.queue.front() {
                    _ if frozen => None,
                    Some((at, _)) if *at <= Instant::now() => {
                        return Ok(s.queue.pop_front().map(|(_, frame)| frame));
                    }
                    Some((at, _)) => Some(*at),
                    None if s.finished => return Ok(None),
                    None => None,
                }
            };
            changed.borrow_and_update();
            tokio::select! {
                _ = changed.changed() => {}
                _ = conditions.changed() => {}
                () = async {
                    match wait {
                        Some(at) => tokio::time::sleep_until(at).await,
                        None => std::future::pending().await,
                    }
                } => {}
            }
        }
    }

    async fn close(&self) -> Result<(), LinkError> {
        self.route.note(format!("{} closed", self.description));
        self.outgoing.finish();
        self.incoming.cut();
        Ok(())
    }
}

/// The daemon a route reaches now: none while it is down (crashed, restarting).
pub type DaemonSlot = Arc<Mutex<Option<Arc<RemoteDaemon>>>>;

/// The client's carrier: opens each lane's link on the active route and hands the daemon's end
/// to the daemon as the relay does (`NetworkPeer::Relay`, a trusted carrier as the machine's
/// own relay slot is).
pub struct SimGroup {
    pub routes: [Arc<Route>; 2],
    /// Which route new links take (a carrier swap moves it).
    pub active: Arc<Mutex<usize>>,
    pub daemon: DaemonSlot,
    evidence: CarrierEvidence,
    /// Accept tasks per daemon incarnation, aborted when it dies.
    pub accepts: Arc<Mutex<Vec<tokio::task::JoinHandle<()>>>>,
    /// The run's trace: each link the daemon refuses, with why.
    trace: Arc<Mutex<Vec<String>>>,
    start: Instant,
    /// The route each generation's links take: the first link's, as one relay connection group
    /// opens every lane of a generation through its one endpoint. A swap moves the next one.
    pinned: Mutex<Option<(u64, usize)>>,
}

impl SimGroup {
    pub fn new(
        routes: [Arc<Route>; 2],
        active: Arc<Mutex<usize>>,
        daemon: DaemonSlot,
        accepts: Arc<Mutex<Vec<tokio::task::JoinHandle<()>>>>,
        trace: Arc<Mutex<Vec<String>>>,
    ) -> Self {
        Self {
            routes,
            active,
            daemon,
            evidence: CarrierEvidence::Relay { provider: "sim".into() },
            accepts,
            trace,
            start: Instant::now(),
            pinned: Mutex::new(None),
        }
    }
}

impl SimGroup {
    /// The group a new session dials: `cmux carrier dial` opens a connection group of its own.
    pub fn for_new_session(&self) -> Arc<Self> {
        Arc::new(Self {
            routes: self.routes.clone(),
            active: self.active.clone(),
            daemon: self.daemon.clone(),
            evidence: self.evidence.clone(),
            accepts: self.accepts.clone(),
            trace: self.trace.clone(),
            start: self.start,
            pinned: Mutex::new(None),
        })
    }
}

#[async_trait]
impl LinkGroup for SimGroup {
    fn description(&self) -> &str {
        "sim carrier"
    }

    fn capabilities(&self) -> ProviderCapabilities {
        ProviderCapabilities::MULTI_STREAM
    }

    fn evidence(&self) -> &CarrierEvidence {
        &self.evidence
    }

    async fn open(&self, request: LinkRequest) -> Result<Box<dyn FrameLink>, ProviderError> {
        let index = {
            let mut pinned = lock(&self.pinned);
            match *pinned {
                Some((generation, index)) if generation == request.generation => index,
                _ => {
                    let index = *lock(&self.active);
                    *pinned = Some((request.generation, index));
                    index
                }
            }
        };
        let route = self.routes[index].clone();
        route.note(format!("{} open {:?} g{}", route.name, request.lane, request.generation));
        // A dial takes one round trip before it can fail or succeed.
        tokio::time::sleep(route.latency() * 2).await;
        // Both fail as the relay provider fails them: a carrier error the client retries
        // (`relay_connect_error`, and a retryable relay refusal in `relay_operation_rejection`).
        if route.conditions().down {
            return Err(ProviderError::Link(LinkError::Transport(format!(
                "sim: {} is down",
                route.name
            ))));
        }
        let Some(daemon) = lock(&self.daemon).clone() else {
            return Err(ProviderError::Link(LinkError::Transport(format!(
                "sim: no daemon registered on {}",
                route.name
            ))));
        };
        let (client, server) = route.pair(format!("{:?} g{}", request.lane, request.generation));
        let (trace, start, label) =
            (self.trace.clone(), self.start, format!("{:?} g{}", request.lane, request.generation));
        let task = tokio::spawn(async move {
            if let Err(e) = daemon
                .accept(InboundLink::trusted_network(Box::new(server), NetworkPeer::Relay))
                .await
            {
                lock(&trace).push(format!("{:?} daemon refused {label}: {e}", start.elapsed()));
            }
        });
        lock(&self.accepts).push(task);
        Ok(Box::new(client))
    }

    async fn close(&self) -> Result<(), ProviderError> {
        Ok(())
    }
}
