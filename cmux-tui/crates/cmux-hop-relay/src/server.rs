//! The PoP: BIND allocations on one control port, one relayed UDP port each.
//!
//! ```text
//! phone ==hop/1 Leg (control port)==> PoP ==relayed port: plain WireGuard, or hop/1==> Mac
//! ```
//!
//! Each allocation is a task that owns its relayed socket and both legs. The
//! phone leg's egress drains through a token bucket at `leg_rate_kbit`, so a
//! backlog builds in the leg's class queue (where R5 supersedes stale class-1
//! records and coalesces the rest) and not in a router's FIFO downstream.

use std::collections::{BTreeMap, HashMap};
use std::net::{IpAddr, SocketAddr};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use cmux_scope::Scope;
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, UdpSocket};
use tokio::sync::mpsc;
use tokio::time::Instant;

use crate::leg::{HopLeg, LegStats};
use crate::ticket::TicketAuthority;
use crate::wire;

#[derive(Clone)]
pub struct PopConfig {
    /// The control port phones BIND to and their leg runs on.
    pub bind: SocketAddr,
    /// The address relayed ports bind on and BIND_OK reports.
    pub public_ip: IpAddr,
    pub authority: TicketAuthority,
    /// Phone-leg egress rate; 0 sends as fast as the leg offers.
    pub leg_rate_kbit: u64,
    /// An allocation with no traffic for this long is released.
    pub lifetime: Duration,
    pub max_allocations: usize,
    /// How often each live allocation logs its stats line (0: never).
    pub stats_every: Duration,
}

impl PopConfig {
    pub fn lab(bind: SocketAddr) -> Self {
        Self {
            bind,
            public_ip: bind.ip(),
            authority: TicketAuthority::open(),
            leg_rate_kbit: 0,
            lifetime: Duration::from_secs(600),
            max_allocations: 1024,
            stats_every: Duration::ZERO,
        }
    }
}

enum ToAlloc {
    Phone(Vec<u8>),
    Rebind(SocketAddr),
}

struct Handle {
    tx: mpsc::Sender<ToAlloc>,
    phone: SocketAddr,
    relayed: SocketAddr,
    generation: u64,
}

#[derive(Default)]
struct Registry {
    by_addr: HashMap<SocketAddr, Vec<u8>>,
    by_session: HashMap<Vec<u8>, Handle>,
    next_generation: u64,
}

/// Every live allocation's last report, by relayed port.
pub type Reports = Arc<Mutex<BTreeMap<u16, Value>>>;

pub struct Pop {
    control: Arc<UdpSocket>,
    config: PopConfig,
    registry: Arc<Mutex<Registry>>,
    reports: Reports,
    /// Owns every allocation task; dropped with the PoP.
    scope: Scope,
}

impl Pop {
    pub async fn bind(config: PopConfig) -> std::io::Result<Self> {
        Ok(Self {
            control: Arc::new(UdpSocket::bind(config.bind).await?),
            config,
            registry: Arc::default(),
            reports: Arc::default(),
            scope: Scope::new("cmux-hop-relay pop"),
        })
    }

    pub fn local_addr(&self) -> std::io::Result<SocketAddr> {
        self.control.local_addr()
    }

    pub fn reports(&self) -> Reports {
        Arc::clone(&self.reports)
    }

    pub async fn run(self) -> std::io::Result<()> {
        let mut buf = vec![0_u8; 65_536];
        loop {
            let (n, from) = self.control.recv_from(&mut buf).await?;
            let Some(datagram) = buf.get(..n) else { continue };
            if let Some(ticket) = wire::decode_bind(datagram) {
                let reply = self.bind_allocation(ticket, from).await;
                let _ = self.control.send_to(&reply, from).await;
                continue;
            }
            let tx = {
                let registry = self.registry.lock().unwrap_or_else(PoisonError::into_inner);
                registry
                    .by_addr
                    .get(&from)
                    .and_then(|s| registry.by_session.get(s))
                    .map(|h| h.tx.clone())
            };
            match tx {
                Some(tx) => {
                    // A full channel drops: the leg repairs it like any loss.
                    let _ = tx.try_send(ToAlloc::Phone(datagram.to_vec()));
                }
                None if wire::is_hop(datagram) => {
                    let _ = self
                        .control
                        .send_to(&wire::encode_error(wire::E_NO_ALLOCATION), from)
                        .await;
                }
                None => {}
            }
        }
    }

    async fn bind_allocation(&self, ticket: &[u8], from: SocketAddr) -> Vec<u8> {
        let Ok(session) = self.config.authority.verify(ticket) else {
            return wire::encode_error(wire::E_BAD_TICKET);
        };
        let lifetime = u32::try_from(self.config.lifetime.as_secs()).unwrap_or(u32::MAX);
        {
            let mut guard = self.registry.lock().unwrap_or_else(PoisonError::into_inner);
            let registry = &mut *guard;
            if let Some(handle) = registry.by_session.get_mut(&session) {
                // Same ticket: the same allocation, possibly from a new address (roam).
                if handle.phone != from {
                    registry.by_addr.remove(&handle.phone);
                    handle.phone = from;
                    registry.by_addr.insert(from, session.clone());
                    let _ = handle.tx.try_send(ToAlloc::Rebind(from));
                }
                return wire::encode_bind_ok(handle.relayed, lifetime);
            }
            if registry.by_session.len() >= self.config.max_allocations {
                return wire::encode_error(wire::E_CAPACITY);
            }
        }
        let relayed = match UdpSocket::bind(SocketAddr::new(self.config.public_ip, 0)).await {
            Ok(s) => s,
            Err(_) => return wire::encode_error(wire::E_CAPACITY),
        };
        let Ok(relayed_addr) = relayed.local_addr() else {
            return wire::encode_error(wire::E_CAPACITY);
        };
        let (tx, rx) = mpsc::channel(4096);
        let generation = {
            let mut registry = self.registry.lock().unwrap_or_else(PoisonError::into_inner);
            // A second BIND for the session raced this one: answer with the winner.
            if let Some(handle) = registry.by_session.get(&session) {
                return wire::encode_bind_ok(handle.relayed, lifetime);
            }
            registry.next_generation += 1;
            let generation = registry.next_generation;
            registry.by_addr.insert(from, session.clone());
            registry.by_session.insert(
                session.clone(),
                Handle { tx, phone: from, relayed: relayed_addr, generation },
            );
            generation
        };
        let alloc = Allocation {
            session,
            generation,
            phone: from,
            mac: None,
            control: Arc::clone(&self.control),
            relayed: Arc::new(relayed),
            relayed_addr,
            phone_leg: HopLeg::new(Instant::now()),
            mac_leg: None,
            bucket: Bucket::new(self.config.leg_rate_kbit),
            counters: Counters::default(),
            config: self.config.clone(),
            registry: Arc::clone(&self.registry),
            reports: Arc::clone(&self.reports),
        };
        self.scope.spawn_until_cancelled("hop-relay allocation", alloc.run(rx));
        wire::encode_bind_ok(relayed_addr, lifetime)
    }
}

/// Serves the reports as JSON on every connection (any request, one answer).
pub async fn serve_health(listener: TcpListener, reports: Reports) {
    let scope = Scope::new("cmux-hop-relay health");
    loop {
        let Ok((mut stream, _)) = listener.accept().await else { continue };
        let reports = Arc::clone(&reports);
        scope.spawn_until_cancelled("hop-relay health answer", async move {
            let mut scratch = [0_u8; 1024];
            let _ =
                tokio::time::timeout(Duration::from_millis(200), stream.read(&mut scratch)).await;
            let body = {
                let reports = reports.lock().unwrap_or_else(PoisonError::into_inner);
                json!({"ok": true, "allocations": reports.values().cloned().collect::<Vec<_>>()})
                    .to_string()
            };
            let head = format!(
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
                body.len()
            );
            let _ = stream.write_all(head.as_bytes()).await;
            let _ = stream.write_all(body.as_bytes()).await;
        });
    }
}

/// Token bucket for the phone leg's egress. Tokens may go negative by one
/// datagram; the leg is polled again once they are back to zero.
struct Bucket {
    bytes_per_sec: f64,
    tokens: f64,
    burst: f64,
    at: Instant,
}

impl Bucket {
    fn new(rate_kbit: u64) -> Self {
        let bytes_per_sec = rate_kbit as f64 * 1000.0 / 8.0;
        // 5 ms of the rate, at least two full datagrams.
        let burst = (bytes_per_sec * 0.005).max(3000.0);
        Self { bytes_per_sec, tokens: burst, burst, at: Instant::now() }
    }

    fn unlimited(&self) -> bool {
        self.bytes_per_sec <= 0.0
    }

    fn refill(&mut self, now: Instant) {
        if self.unlimited() {
            return;
        }
        let dt = now.saturating_duration_since(self.at).as_secs_f64();
        self.tokens = (self.tokens + dt * self.bytes_per_sec).min(self.burst);
        self.at = now;
    }

    fn ready(&self) -> bool {
        self.unlimited() || self.tokens >= 0.0
    }

    fn spend(&mut self, bytes: usize) {
        if !self.unlimited() {
            self.tokens -= bytes as f64;
        }
    }

    /// When the tokens are back to zero.
    fn ready_at(&self, now: Instant) -> Instant {
        if self.ready() {
            return now;
        }
        now + Duration::from_secs_f64(-self.tokens / self.bytes_per_sec)
    }
}

#[derive(Default)]
struct Counters {
    plain_from_mac: u64,
    plain_to_mac: u64,
    phone_datagrams: u64,
    rebinds: u64,
}

struct Allocation {
    session: Vec<u8>,
    generation: u64,
    phone: SocketAddr,
    mac: Option<SocketAddr>,
    control: Arc<UdpSocket>,
    relayed: Arc<UdpSocket>,
    relayed_addr: SocketAddr,
    phone_leg: HopLeg,
    /// Set once the Mac sends hop/1 to the relayed port.
    mac_leg: Option<HopLeg>,
    bucket: Bucket,
    counters: Counters,
    config: PopConfig,
    registry: Arc<Mutex<Registry>>,
    reports: Reports,
}

impl Allocation {
    async fn run(mut self, mut rx: mpsc::Receiver<ToAlloc>) {
        let mut buf = vec![0_u8; 65_536];
        let mut last_heard = Instant::now();
        let mut next_report = Instant::now() + self.report_every();
        loop {
            let now = Instant::now();
            let wake = self.next_wake(now).min(last_heard + self.config.lifetime).min(next_report);
            tokio::select! {
                msg = rx.recv() => {
                    let Some(msg) = msg else { break };
                    last_heard = Instant::now();
                    match msg {
                        ToAlloc::Phone(datagram) => self.on_phone(&datagram, last_heard),
                        ToAlloc::Rebind(addr) => {
                            self.phone = addr;
                            self.counters.rebinds += 1;
                        }
                    }
                }
                got = self.relayed.recv_from(&mut buf) => {
                    if let Ok((n, from)) = got && let Some(datagram) = buf.get(..n) {
                        last_heard = Instant::now();
                        self.mac = Some(from);
                        self.on_mac(datagram, last_heard);
                    }
                }
                () = tokio::time::sleep_until(wake) => {}
            }
            let now = Instant::now();
            if now >= last_heard + self.config.lifetime {
                break;
            }
            self.flush(now).await;
            if now >= next_report {
                self.report(true);
                next_report = now + self.report_every();
            }
        }
        self.release();
    }

    fn report_every(&self) -> Duration {
        if self.config.stats_every.is_zero() {
            Duration::from_secs(1)
        } else {
            self.config.stats_every
        }
    }

    fn on_phone(&mut self, datagram: &[u8], now: Instant) {
        self.counters.phone_datagrams += 1;
        for record in self.phone_leg.handle(datagram, now) {
            match &mut self.mac_leg {
                Some(leg) => leg.push(record.class, record.tag, &record.bytes, now),
                None => {
                    if let Some(mac) = self.mac {
                        // Plain Mac: the record is a WireGuard datagram as the phone sent it.
                        let _ = self.relayed.try_send_to(&record.bytes, mac);
                        self.counters.plain_to_mac += 1;
                    }
                }
            }
        }
    }

    fn on_mac(&mut self, datagram: &[u8], now: Instant) {
        if wire::is_hop(datagram) {
            let leg = self.mac_leg.get_or_insert_with(|| HopLeg::new(now));
            for record in leg.handle(datagram, now) {
                self.phone_leg.push(record.class, record.tag, &record.bytes, now);
            }
        } else {
            self.counters.plain_from_mac += 1;
            self.phone_leg.push(wire::plain_class(datagram), None, datagram, now);
        }
    }

    fn next_wake(&self, now: Instant) -> Instant {
        let far = now + Duration::from_secs(3600);
        let mut wake = self.phone_leg.poll_timeout().unwrap_or(far);
        if let Some(leg) = &self.mac_leg {
            wake = wake.min(leg.poll_timeout().unwrap_or(far));
        }
        if self.phone_leg.has_pending() {
            wake = wake.min(self.bucket.ready_at(now));
        }
        wake
    }

    async fn flush(&mut self, now: Instant) {
        if let (Some(leg), Some(mac)) = (&mut self.mac_leg, self.mac) {
            leg.on_timeout(now);
            while let Some(datagram) = leg.poll_transmit(now) {
                let _ = self.relayed.send_to(&datagram, mac).await;
            }
        }
        self.phone_leg.on_timeout(now);
        self.bucket.refill(now);
        while self.bucket.ready() {
            let Some(datagram) = self.phone_leg.poll_transmit(now) else { break };
            self.bucket.spend(datagram.len() + 28);
            let _ = self.control.send_to(&datagram, self.phone).await;
        }
    }

    fn report(&self, log: bool) {
        let report = json!({
            "relayed": self.relayed_addr.to_string(),
            "phone": self.phone.to_string(),
            "mac": self.mac.map(|m| m.to_string()),
            "mac_mode": if self.mac_leg.is_some() { "hop" } else { "plain" },
            "leg_rate_kbit": self.config.leg_rate_kbit,
            "phone_leg": stats_json(&self.phone_leg.stats()),
            "mac_leg": self.mac_leg.as_ref().map(|l| stats_json(&l.stats())),
            "plain_from_mac": self.counters.plain_from_mac,
            "plain_to_mac": self.counters.plain_to_mac,
            "phone_datagrams": self.counters.phone_datagrams,
            "rebinds": self.counters.rebinds,
        });
        if log && !self.config.stats_every.is_zero() {
            eprintln!("hop-relay stats {report}");
        }
        self.reports
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(self.relayed_addr.port(), report);
    }

    fn release(&self) {
        self.report(true);
        self.reports
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(&self.relayed_addr.port());
        let mut registry = self.registry.lock().unwrap_or_else(PoisonError::into_inner);
        if registry.by_session.get(&self.session).is_some_and(|h| h.generation == self.generation)
            && let Some(handle) = registry.by_session.remove(&self.session)
        {
            registry.by_addr.remove(&handle.phone);
        }
    }
}

/// RFD 0142 Phase 0's link_stat fields for one leg.
pub fn stats_json(s: &LegStats) -> Value {
    json!({
        "rtt_ms": s.rtt_ms,
        "loss_permille": s.loss_permille,
        "peer_loss_permille": s.peer_loss_permille,
        "sent": s.sent,
        "resent": s.resent,
        "repaired": s.repaired,
        "received": s.received,
        "nacks_sent": s.nacks_sent,
        "parity_sent": s.parity_sent,
        "fec_recovered": s.fec_recovered,
        "superseded": s.superseded,
        "coalesced": s.coalesced,
        "dropped": s.dropped,
        "queued_bytes": s.queued_bytes,
    })
}
