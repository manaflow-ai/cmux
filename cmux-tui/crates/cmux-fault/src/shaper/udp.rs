//! The datagram twin of [`super::Shaper`]: a UDP relay that plays a phone's link between a phone
//! side socket and a host's UDP port, for the phone's real transport (cmux-mobile-link over UDP).
//!
//! Same profiles, same seed rule, a datagram's model instead of TCP's:
//!
//! - **rate**: a datagram leaves after the one before it has serialized, per direction; a backlog
//!   past the bearer's buffer is tail-dropped;
//! - **delay and jitter**: `rtt_ms / 2` plus a seeded draw in `0..=jitter_ms`, and nothing holds a
//!   datagram behind another, so jitter reorders;
//! - **loss**: dropped, never retransmitted (the protocol above owns recovery);
//! - **blackout** ([`UdpShaper::blackout`]): nothing sent or arriving in the window gets through,
//!   either way; the addresses are the same after;
//! - **rebind** ([`UdpShaper::rebind`]): the host sees the phone from a new source port, with no
//!   event on the phone (a NAT rebinding); what the host sends to the old port is lost. For a
//!   wifi to cellular move with an OS event, the phone side opens a new socket and the relay
//!   answers whichever address spoke last; call `rebind` too so the host also sees a new address;
//! - **one-way loss** ([`UdpShaper::one_way_loss`]): every datagram one way is dropped for a while;
//! - **a step** ([`UdpShaper::set_profile`]): the link's numbers change from now;
//! - **internet down** ([`UdpShaper::internet_down`]): the phone's second path, through the
//!   internet ([`UdpShaper::open_internet_path`], a second relay to its own upstream such as a
//!   STUN or TURN server), blackholes every datagram either way, while the LAN path (the relay's
//!   own address) keeps the profile's numbers. Both paths share the radio link.
//!
//! Each direction draws from its own stream of the seed, so one seed is one link.

use std::cmp::Reverse;
use std::collections::BinaryHeap;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use cmux_scope::Scope;
use serde::Serialize;
use tokio::net::UdpSocket;
use tokio::sync::{mpsc, watch};
use tokio::time::Instant;

use super::{LinkProfile, QUEUE_SEGMENTS, SEGMENT, lane, lane_mut, lock, lost};
use crate::rng::Rng;
use crate::trace::Trace;

/// Which way a datagram goes: up is phone to host.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Way {
    Up,
    Down,
}

impl Way {
    fn lane(self) -> usize {
        match self {
            Self::Up => 0,
            Self::Down => 1,
        }
    }
}

/// What crossed the relay, each way.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
pub struct UdpCounters {
    pub up_datagrams: u64,
    pub down_datagrams: u64,
    pub up_bytes: u64,
    pub down_bytes: u64,
    /// Lost, dropped by a fault or tail-dropped, by the way they went.
    pub up_dropped: u64,
    pub down_dropped: u64,
}

#[derive(Default)]
struct Counting {
    datagrams: [AtomicU64; 2],
    bytes: [AtomicU64; 2],
    dropped: [AtomicU64; 2],
}

struct Air {
    profile: LinkProfile,
    free_at: [Instant; 2],
    dark: Option<(Instant, Instant)>,
    cut: [Option<Instant>; 2],
    /// The internet path is dead: everything on it is dropped.
    internet_down: bool,
}

impl Air {
    fn blocked(&self, index: usize, at: Instant, internet: bool) -> bool {
        self.dark.is_some_and(|(from, until)| from <= at && at < until)
            || lane(&self.cut, index).is_some_and(|until| at < until)
            || (internet && self.internet_down)
    }

    /// When a datagram handed over now arrives, or `None` when it never does.
    fn schedule(
        &mut self,
        bytes: usize,
        index: usize,
        rng: &mut Rng,
        internet: bool,
    ) -> Option<Instant> {
        let now = Instant::now();
        let down = index == 1;
        // Draw before deciding, so a fault never shifts the stream for the datagrams after it.
        let jitter = match self.profile.jitter_ms {
            0 => 0,
            most => rng.range(0, most),
        };
        let gone = lost(rng, self.profile.loss_percent);
        let start = (*lane(&self.free_at, index)).max(now);
        if start.saturating_duration_since(now)
            > self.profile.serialize(QUEUE_SEGMENTS * SEGMENT, down)
        {
            return None;
        }
        let left = start + self.profile.serialize(bytes, down);
        *lane_mut(&mut self.free_at, index) = left;
        if gone || self.blocked(index, left, internet) {
            return None;
        }
        Some(left + self.profile.one_way() + Duration::from_millis(jitter))
    }
}

struct Shared {
    /// One radio link: both paths share it.
    air: Arc<Mutex<Air>>,
    /// This relay is the internet path, not the LAN.
    internet: bool,
    near: Arc<UdpSocket>,
    far: Mutex<Arc<UdpSocket>>,
    /// The phone side's address: whichever spoke last.
    phone: Mutex<Option<SocketAddr>>,
    upstream: SocketAddr,
    counting: Counting,
    /// Bumped by each rebind: the old far socket's reader stops and the socket closes.
    generation: watch::Sender<u64>,
}

type Queue = mpsc::UnboundedSender<(Instant, Vec<u8>)>;

pub struct UdpShaper {
    shared: Arc<Shared>,
    down: Queue,
    down_rng: Arc<Mutex<Rng>>,
    scope: Arc<Scope>,
    trace: Trace,
    seed: u64,
}

/// Spawns one path's relay tasks on `scope` (readers and deliveries); returns its down queue.
fn spawn_path(
    scope: &Arc<Scope>,
    shared: &Arc<Shared>,
    mut up_rng: Rng,
    down_rng: Arc<Mutex<Rng>>,
    far: Arc<UdpSocket>,
) -> Queue {
    let (up, up_queue) = mpsc::unbounded_channel();
    let (down, down_queue) = mpsc::unbounded_channel();
    scope
        .spawn_until_cancelled("udp shaper up deliver", deliver(shared.clone(), Way::Up, up_queue));
    scope.spawn_until_cancelled(
        "udp shaper down deliver",
        deliver(shared.clone(), Way::Down, down_queue),
    );
    scope.spawn_until_cancelled("udp shaper up read", {
        let shared = shared.clone();
        async move {
            let mut buffer = vec![0_u8; 64 * 1024];
            while let Ok((n, from)) = shared.near.recv_from(&mut buffer).await {
                *lock(&shared.phone) = Some(from);
                let datagram = buffer.get(..n).unwrap_or_default().to_vec();
                if !hand_over(&shared, Way::Up, datagram, &mut up_rng, &up) {
                    return;
                }
            }
        }
    });
    read_far(scope, shared.clone(), down.clone(), down_rng, far, 0);
    down
}

impl UdpShaper {
    /// A relay on a free loopback port to the host's `upstream` UDP port, with `profile`'s link.
    pub async fn start(
        upstream: SocketAddr,
        profile: LinkProfile,
        seed: u64,
        trace: &Trace,
    ) -> std::io::Result<Self> {
        let near = Arc::new(UdpSocket::bind("127.0.0.1:0").await?);
        let far = Arc::new(UdpSocket::bind("127.0.0.1:0").await?);
        trace.note(format!("udp shaper {} v{} seed {seed}", profile.name, profile.version));
        let now = Instant::now();
        let air = Air {
            profile,
            free_at: [now, now],
            dark: None,
            cut: [None, None],
            internet_down: false,
        };
        let shared = Arc::new(Shared {
            air: Arc::new(Mutex::new(air)),
            internet: false,
            near,
            far: Mutex::new(far.clone()),
            phone: Mutex::new(None),
            upstream,
            counting: Counting::default(),
            generation: watch::channel(0).0,
        });
        let scope = Arc::new(Scope::new("cmux-fault udp shaper"));
        let mut root = Rng::new(seed);
        let up_rng = root.split(1);
        let down_rng = Arc::new(Mutex::new(root.split(2)));
        let down = spawn_path(&scope, &shared, up_rng, down_rng.clone(), far);
        Ok(Self { shared, down, down_rng, scope, trace: trace.clone(), seed })
    }

    /// Opens the phone's second path, through the internet to `upstream` (a STUN or TURN
    /// server, a relay), on a free loopback port, and returns where the phone side sends. It
    /// shares the radio link with the LAN path and dies with [`UdpShaper::internet_down`].
    pub async fn open_internet_path(&self, upstream: SocketAddr) -> std::io::Result<SocketAddr> {
        let near = Arc::new(UdpSocket::bind("127.0.0.1:0").await?);
        let far = Arc::new(UdpSocket::bind("127.0.0.1:0").await?);
        let addr = near.local_addr()?;
        let shared = Arc::new(Shared {
            air: self.shared.air.clone(),
            internet: true,
            near,
            far: Mutex::new(far.clone()),
            phone: Mutex::new(None),
            upstream,
            counting: Counting::default(),
            generation: watch::channel(0).0,
        });
        let mut root = Rng::new(self.seed);
        let up_rng = root.split(3);
        let down_rng = Arc::new(Mutex::new(root.split(4)));
        spawn_path(&self.scope, &shared, up_rng, down_rng, far);
        self.trace.note(format!("udp shaper internet path {addr}"));
        Ok(addr)
    }

    /// The internet path dies now (and stays dead): every datagram on it, either way, is
    /// dropped. The LAN path keeps flowing.
    pub fn internet_down(&self) {
        self.trace.note("fault udp internet-down");
        lock(&self.shared.air).internet_down = true;
    }

    /// Where the phone side sends.
    pub fn addr(&self) -> SocketAddr {
        self.shared.near.local_addr().unwrap_or_else(|_| SocketAddr::from(([127, 0, 0, 1], 0)))
    }

    /// The address the host sees the phone at now.
    pub fn phone_addr_at_host(&self) -> std::io::Result<SocketAddr> {
        lock(&self.shared.far).local_addr()
    }

    pub fn seed(&self) -> u64 {
        self.seed
    }

    pub fn counters(&self) -> UdpCounters {
        let counting = &self.shared.counting;
        let load = |counter: &AtomicU64| counter.load(Ordering::SeqCst);
        UdpCounters {
            up_datagrams: load(&counting.datagrams[0]),
            down_datagrams: load(&counting.datagrams[1]),
            up_bytes: load(&counting.bytes[0]),
            down_bytes: load(&counting.bytes[1]),
            up_dropped: load(&counting.dropped[0]),
            down_dropped: load(&counting.dropped[1]),
        }
    }

    pub fn reset_counters(&self) {
        let counting = &self.shared.counting;
        for counter in counting.datagrams.iter().chain(&counting.bytes).chain(&counting.dropped) {
            counter.store(0, Ordering::SeqCst);
        }
    }

    /// Nothing gets through either way from now for `duration`; returns when the link is back.
    pub fn blackout(&self, duration: Duration) -> Instant {
        let now = Instant::now();
        let until = now + duration;
        self.trace.note(format!("fault udp blackout {} ms", duration.as_millis()));
        lock(&self.shared.air).dark = Some((now, until));
        until
    }

    /// Every datagram going `way` is dropped from now for `duration`; returns when it flows.
    pub fn one_way_loss(&self, way: Way, duration: Duration) -> Instant {
        let until = Instant::now() + duration;
        self.trace.note(format!("fault udp one-way loss {way:?} {} ms", duration.as_millis()));
        *lane_mut(&mut lock(&self.shared.air).cut, way.lane()) = Some(until);
        until
    }

    /// The link's numbers change from now (a step from wifi to a worse link, or back).
    pub fn set_profile(&self, profile: LinkProfile) {
        self.trace.note(format!("fault udp profile {} v{}", profile.name, profile.version));
        lock(&self.shared.air).profile = profile;
    }

    pub fn profile(&self) -> LinkProfile {
        lock(&self.shared.air).profile.clone()
    }

    /// The host sees the phone from a new source port from now (a NAT rebinding); the old port
    /// is closed, so what the host sends to it is lost. Returns the new address.
    pub async fn rebind(&self) -> std::io::Result<SocketAddr> {
        let far = Arc::new(UdpSocket::bind("127.0.0.1:0").await?);
        let addr = far.local_addr()?;
        *lock(&self.shared.far) = far.clone();
        let mut generation = 0;
        self.shared.generation.send_modify(|value| {
            *value += 1;
            generation = *value;
        });
        self.trace.note(format!("fault udp rebind {addr}"));
        read_far(
            &self.scope,
            self.shared.clone(),
            self.down.clone(),
            self.down_rng.clone(),
            far,
            generation,
        );
        Ok(addr)
    }
}

/// Reads the host's datagrams on `far` until a rebind replaces it (`generation` moves on).
fn read_far(
    scope: &Arc<Scope>,
    shared: Arc<Shared>,
    down: Queue,
    rng: Arc<Mutex<Rng>>,
    far: Arc<UdpSocket>,
    generation: u64,
) {
    let mut changed = shared.generation.subscribe();
    scope.spawn_until_cancelled("udp shaper down read", async move {
        let mut buffer = vec![0_u8; 64 * 1024];
        loop {
            let received = tokio::select! {
                received = far.recv_from(&mut buffer) => received,
                _ = changed.wait_for(|now| *now != generation) => return,
            };
            let Ok((n, from)) = received else { return };
            if from != shared.upstream {
                continue;
            }
            let datagram = buffer.get(..n).unwrap_or_default().to_vec();
            let queued = {
                let mut rng = lock(&rng);
                hand_over(&shared, Way::Down, datagram, &mut rng, &down)
            };
            if !queued {
                return;
            }
        }
    });
}

impl Drop for UdpShaper {
    fn drop(&mut self) {
        self.scope.token().cancel();
    }
}

/// Counts a datagram and queues it for its arrival, or counts the drop. False once the relay is
/// shutting down.
fn hand_over(shared: &Shared, way: Way, datagram: Vec<u8>, rng: &mut Rng, queue: &Queue) -> bool {
    let index = way.lane();
    let counting = &shared.counting;
    lane(&counting.datagrams, index).fetch_add(1, Ordering::SeqCst);
    lane(&counting.bytes, index).fetch_add(datagram.len() as u64, Ordering::SeqCst);
    let at = lock(&shared.air).schedule(datagram.len(), index, rng, shared.internet);
    match at {
        Some(at) => queue.send((at, datagram)).is_ok(),
        None => {
            lane(&counting.dropped, index).fetch_add(1, Ordering::SeqCst);
            true
        }
    }
}

/// Sends each queued datagram at its arrival time, earliest first (jitter reorders), unless a
/// fault that started while it was on the air drops it there.
async fn deliver(
    shared: Arc<Shared>,
    way: Way,
    mut queue: mpsc::UnboundedReceiver<(Instant, Vec<u8>)>,
) {
    let mut waiting: BinaryHeap<Reverse<(Instant, u64, Vec<u8>)>> = BinaryHeap::new();
    let mut order = 0_u64;
    loop {
        let next = waiting.peek().map(|Reverse((at, _, _))| *at);
        let due = async {
            match next {
                Some(at) => tokio::time::sleep_until(at).await,
                None => std::future::pending().await,
            }
        };
        tokio::select! {
            item = queue.recv() => {
                let Some((at, datagram)) = item else { return };
                order += 1;
                waiting.push(Reverse((at, order, datagram)));
            }
            () = due => {
                let Some(Reverse((_, _, datagram))) = waiting.pop() else { continue };
                if lock(&shared.air).blocked(way.lane(), Instant::now(), shared.internet) {
                    lane(&shared.counting.dropped, way.lane()).fetch_add(1, Ordering::SeqCst);
                    continue;
                }
                let sent = match way {
                    Way::Up => {
                        let far = lock(&shared.far).clone();
                        far.send_to(&datagram, shared.upstream).await
                    }
                    Way::Down => {
                        let Some(phone) = *lock(&shared.phone) else { continue };
                        shared.near.send_to(&datagram, phone).await
                    }
                };
                // A refused send (nothing listening yet) is a lost datagram, as on the air.
                if sent.is_err() {
                    lane(&shared.counting.dropped, way.lane()).fetch_add(1, Ordering::SeqCst);
                }
            }
        }
    }
}

#[cfg(test)]
#[path = "udp_tests.rs"]
mod tests;
