//! Per-connection pacing of what the TCP stack sends.
//!
//! smoltcp releases a whole congestion window at once, and after a loss it
//! rewinds and resends the window at once (go-back-N). Into a shallow router
//! queue those bursts lose segments every round trip, and smoltcp recovers
//! slowly (no SACK, 1 s minimum RTO). smoltcp exposes neither its window nor
//! its RTT, but every segment passes through the driver both ways, so the
//! pacer measures them itself, per TCP connection:
//!
//! - RTT: one timed segment at a time, from its departure to the first ACK
//!   that covers it; a retransmission cancels the sample (Karn).
//! - Flight: highest sequence the stack emitted (queued here or on the wire)
//!   minus highest acknowledged. Queued packets count: smoltcp already spent
//!   its window on them, and a rate from the wire flight alone would starve.
//!
//! Each connection then leaves at `GAIN * max(flight, MIN_FLIGHT) / srtt`,
//! with earliest-departure times, so a window spreads over about half a
//! round trip instead of leaving in one burst. Connections queue
//! separately and the shortest queue goes first, so a keystroke on an
//! interactive connection never waits behind a bulk connection's window.
//! Order inside a connection is kept.
//!
//! Strict priority between classes (transport.md 12a): interactive
//! datagrams and every connection with a short queue and a small flight
//! first, then
//! media datagrams (any older than [`MEDIA_MAX_AGE`] are dropped, oldest
//! first: media must never queue behind a stall), then bulk: paced
//! connections with long queues and bulk datagrams. Nothing is dropped: the queues are
//! bounded by the connections' TCP windows, and past `MAX_QUEUED` packets
//! the driver leaves smoltcp's output in the device, which then blocks TCP.

use std::collections::{HashMap, VecDeque};
use std::net::IpAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use tokio::time::Instant;

/// Pacing gain over the measured rate (the usual slow-start pacing ratio).
const GAIN: f64 = 2.0;
/// The flight a connection is assumed to have at least, so a nearly idle
/// connection is never slowed: ten full-size segments.
const MIN_FLIGHT: u32 = 10 * 1200;
/// Departure credit a late connection may catch up on. Timers wake at
/// about 1 ms resolution; without credit a connection would send one packet
/// per wake, and the pace would be the timer's, not the network's.
const MAX_CREDIT: Duration = Duration::from_millis(2);
/// A connection with at most this many packets queued and less than
/// `MIN_FLIGHT` in flight is interactive: it leaves before media and bulk.
/// Every connection stays paced; the flight floor makes an interactive
/// connection's pace generous.
const INTERACTIVE_QUEUE: usize = 4;
/// Media datagrams older than this in the queue are dropped.
pub(crate) const MEDIA_MAX_AGE: Duration = Duration::from_millis(50);
/// Datagrams one class holds; past it media drops its oldest and the other
/// classes refuse the newest (datagrams are unreliable). Datagrams never
/// count toward [`MAX_QUEUED`], so a datagram flood cannot block the TCP
/// stack's output.
const MAX_DATAGRAMS: usize = 512;
/// Packets the pacer holds in all before smoltcp is blocked instead.
const MAX_QUEUED: usize = 4096;
/// A connection with nothing queued and no packet for this long is
/// forgotten (it closed, or it will measure afresh).
const FORGET_AFTER: Duration = Duration::from_secs(120);
const TCP: u8 = 6;

/// Local address and port, remote address and port.
type Flow = (IpAddr, u16, IpAddr, u16);

/// The parts of a TCP segment the pacer reads.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Segment {
    pub source: (IpAddr, u16),
    pub destination: (IpAddr, u16),
    pub seq: u32,
    pub ack: Option<u32>,
    /// Sequence space the segment occupies (payload, SYN and FIN).
    pub len: u32,
    pub reset: bool,
}

/// Parse the TCP segment in an IPv4 or IPv6 packet.
pub(crate) fn segment(packet: &[u8]) -> Option<Segment> {
    let (source, destination, protocol, header_len, total): (IpAddr, IpAddr, u8, usize, usize) =
        match packet.first()? >> 4 {
            4 if packet.len() >= 20 => {
                let source: [u8; 4] = packet[12..16].try_into().ok()?;
                let destination: [u8; 4] = packet[16..20].try_into().ok()?;
                let total = usize::from(u16::from_be_bytes([packet[2], packet[3]]));
                let header_len = usize::from(packet[0] & 0x0F) * 4;
                (source.into(), destination.into(), packet[9], header_len, total)
            }
            6 if packet.len() >= 40 => {
                let source: [u8; 16] = packet[8..24].try_into().ok()?;
                let destination: [u8; 16] = packet[24..40].try_into().ok()?;
                let total = 40 + usize::from(u16::from_be_bytes([packet[4], packet[5]]));
                (source.into(), destination.into(), packet[6], 40, total)
            }
            _ => return None,
        };
    let tcp = packet.get(header_len..total.min(packet.len()))?;
    if protocol != TCP || tcp.len() < 20 {
        return None;
    }
    let data_offset = usize::from(tcp[12] >> 4) * 4;
    let flags = tcp[13];
    let payload = tcp.len().checked_sub(data_offset)?;
    let syn_fin = u32::from(flags & 0x02 != 0) + u32::from(flags & 0x01 != 0);
    Some(Segment {
        source: (source, u16::from_be_bytes([tcp[0], tcp[1]])),
        destination: (destination, u16::from_be_bytes([tcp[2], tcp[3]])),
        seq: u32::from_be_bytes(tcp[4..8].try_into().ok()?),
        ack: (flags & 0x10 != 0).then(|| u32::from_be_bytes([tcp[8], tcp[9], tcp[10], tcp[11]])),
        len: u32::try_from(payload).ok()? + syn_fin,
        reset: flags & 0x04 != 0,
    })
}

/// `a` is after `b` in sequence space.
fn after(a: u32, b: u32) -> bool {
    (a.wrapping_sub(b) as i32) > 0
}

#[derive(Debug)]
struct Connection {
    queue: VecDeque<Vec<u8>>,
    /// Earliest departure of the next packet.
    next_free: Instant,
    /// Highest sequence end the stack emitted, and highest that left.
    snd_emitted: Option<u32>,
    snd_max: Option<u32>,
    snd_una: Option<u32>,
    /// Highest sequence end received from the peer.
    rcv_max: Option<u32>,
    timed: Option<(u32, Instant)>,
    srtt: Option<Duration>,
    last_seen: Instant,
}

impl Connection {
    fn new(now: Instant) -> Self {
        Self {
            queue: VecDeque::new(),
            next_free: now,
            snd_emitted: None,
            snd_max: None,
            snd_una: None,
            rcv_max: None,
            timed: None,
            srtt: None,
            last_seen: now,
        }
    }

    /// Bytes emitted and not yet acknowledged.
    fn flight(&self) -> u32 {
        match (self.snd_emitted, self.snd_una) {
            (Some(max), Some(una)) if after(max, una) => max.wrapping_sub(una),
            _ => 0,
        }
    }

    /// Whether the connection is interactive now (see `INTERACTIVE_QUEUE`).
    fn interactive(&self) -> bool {
        self.queue.len() <= INTERACTIVE_QUEUE && self.flight() < MIN_FLIGHT
    }

    /// Bytes per second, or `None` before the first RTT sample (unpaced).
    fn rate(&self) -> Option<f64> {
        let srtt = self.srtt?.as_secs_f64().max(1e-6);
        Some(GAIN * f64::from(self.flight().max(MIN_FLIGHT)) / srtt)
    }

    /// Record a segment the stack emitted; true when it carries sequence
    /// space never emitted before (not a retransmission or a keepalive).
    fn emitted(&mut self, segment: &Segment) -> bool {
        let end = segment.seq.wrapping_add(segment.len);
        let fresh = segment.len > 0 && self.snd_emitted.is_none_or(|max| after(end, max));
        if fresh {
            self.snd_emitted = Some(end);
        }
        fresh
    }

    fn sent(&mut self, segment: &Segment, len: usize, now: Instant) {
        self.last_seen = now;
        if segment.len > 0 {
            let end = segment.seq.wrapping_add(segment.len);
            if self.snd_max.is_none_or(|max| after(end, max)) {
                self.snd_max = Some(end);
                if self.timed.is_none() {
                    self.timed = Some((end, now));
                }
            } else if self.timed.is_some_and(|(timed, _)| !after(end, timed)) {
                // A retransmission: its ACK cannot be timed (Karn).
                self.timed = None;
            }
        }
        if let Some(rate) = self.rate() {
            let start = self.next_free.max(now.checked_sub(MAX_CREDIT).unwrap_or(now));
            self.next_free = start + Duration::from_secs_f64(len as f64 / rate);
        }
    }

    fn acked(&mut self, ack: u32, now: Instant) {
        self.last_seen = now;
        if self.snd_una.is_none_or(|una| after(ack, una)) {
            self.snd_una = Some(ack);
        }
        if let Some((timed, sent)) = self.timed
            && !after(timed, ack)
        {
            let sample = now - sent;
            self.srtt = Some(match self.srtt {
                Some(srtt) => (srtt * 7 + sample) / 8,
                None => sample,
            });
            self.timed = None;
        }
    }
}

/// The scheduling class of a datagram (transport.md 12a).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Priority {
    /// Control and terminal bytes: before everything else.
    Interactive,
    /// Remote desktop media: after interactive traffic, dropped when stale.
    Media,
    /// Everything that can wait: after media.
    Bulk,
}

/// Datagrams the datagram service dropped, by reason, since the tunnel
/// started. Shared between the driver and [`crate::WgNet::datagram_drops`].
#[derive(Debug, Default)]
pub(crate) struct DropCounters {
    pub(crate) media_stale: AtomicU64,
    pub(crate) media_full: AtomicU64,
    pub(crate) interactive_full: AtomicU64,
    pub(crate) bulk_full: AtomicU64,
    pub(crate) inbox_full: AtomicU64,
}

impl DropCounters {
    pub(crate) fn count(counter: &AtomicU64) {
        counter.fetch_add(1, Ordering::Relaxed);
    }
}

#[derive(Debug, Default)]
pub(crate) struct Pacer {
    /// Datagrams dropped (stale media, a full class queue).
    pub(crate) drops: Arc<DropCounters>,
    connections: HashMap<Flow, Connection>,
    /// Packets from the TCP stack that are not TCP (rare): first, unpaced.
    other: VecDeque<Vec<u8>>,
    /// Interactive datagrams: right after `other`, unpaced.
    interactive: VecDeque<Vec<u8>>,
    media: VecDeque<(Instant, Vec<u8>)>,
    bulk: VecDeque<Vec<u8>>,
    /// Earliest departure of the next bulk datagram: bulk datagrams are
    /// paced at the floor rate of a connection with the largest smoothed RTT.
    bulk_next_free: Option<Instant>,
    /// Packets from the TCP stack (connection queues and `other`).
    queued: usize,
}

impl Pacer {
    pub(crate) fn has_room(&self) -> bool {
        self.queued < MAX_QUEUED
    }

    /// The largest smoothed RTT among the connections, if any measured one.
    pub(crate) fn srtt(&self) -> Option<Duration> {
        self.connections.values().filter_map(|connection| connection.srtt).max()
    }

    pub(crate) fn has_queued(&self) -> bool {
        self.queued > 0
            || !self.interactive.is_empty()
            || !self.media.is_empty()
            || !self.bulk.is_empty()
    }

    /// Everything queued, unpaced and in order per connection (shutdown).
    pub(crate) fn drain(&mut self) -> Vec<Vec<u8>> {
        self.queued = 0;
        let mut packets: Vec<Vec<u8>> = self.other.drain(..).collect();
        packets.extend(self.interactive.drain(..));
        packets.extend(self.media.drain(..).map(|(_, packet)| packet));
        packets.extend(self.bulk.drain(..));
        for connection in self.connections.values_mut() {
            packets.extend(connection.queue.drain(..));
        }
        packets
    }

    /// Queue one datagram of the datagram service in its class, within the
    /// class bound (see [`MAX_DATAGRAMS`]).
    pub(crate) fn push_datagram(&mut self, packet: Vec<u8>, priority: Priority, now: Instant) {
        match priority {
            Priority::Interactive if self.interactive.len() < MAX_DATAGRAMS => {
                self.interactive.push_back(packet);
            }
            Priority::Bulk if self.bulk.len() < MAX_DATAGRAMS => self.bulk.push_back(packet),
            Priority::Interactive => DropCounters::count(&self.drops.interactive_full),
            Priority::Bulk => DropCounters::count(&self.drops.bulk_full),
            Priority::Media => {
                self.expire_media(now);
                if self.media.len() >= MAX_DATAGRAMS {
                    self.media.pop_front();
                    DropCounters::count(&self.drops.media_full);
                }
                self.media.push_back((now, packet));
            }
        }
    }

    /// Drop media datagrams older than [`MEDIA_MAX_AGE`], oldest first.
    fn expire_media(&mut self, now: Instant) {
        while self
            .media
            .front()
            .is_some_and(|(queued_at, _)| now.saturating_duration_since(*queued_at) > MEDIA_MAX_AGE)
        {
            self.media.pop_front();
            DropCounters::count(&self.drops.media_stale);
        }
    }

    /// Queue one packet the stack wants sent. True when it is new traffic
    /// (new sequence space, or not TCP), which keeps the session's timers
    /// running; a pure ACK, retransmission or keepalive is not.
    pub(crate) fn push(&mut self, packet: Vec<u8>, now: Instant) -> bool {
        self.queued += 1;
        let Some(segment) = segment(&packet) else {
            self.other.push_back(packet);
            return true;
        };
        let flow =
            (segment.source.0, segment.source.1, segment.destination.0, segment.destination.1);
        if !self.connections.contains_key(&flow) {
            self.connections.retain(|_, connection| {
                !connection.queue.is_empty() || now - connection.last_seen < FORGET_AFTER
            });
        }
        let connection = self.connections.entry(flow).or_insert_with(|| Connection::new(now));
        let fresh = connection.emitted(&segment);
        connection.queue.push_back(packet);
        fresh
    }

    /// A packet the stack received: its ACK feeds the sending connection.
    /// True when it is new traffic (new sequence space from the peer, or not
    /// TCP); a keepalive probe or a pure ACK is not.
    pub(crate) fn received(&mut self, packet: &[u8], now: Instant) -> bool {
        let Some(segment) = segment(packet) else { return true };
        let flow =
            (segment.destination.0, segment.destination.1, segment.source.0, segment.source.1);
        let Some(connection) = self.connections.get_mut(&flow) else {
            return segment.len > 0;
        };
        if let Some(ack) = segment.ack {
            connection.acked(ack, now);
        }
        let end = segment.seq.wrapping_add(segment.len);
        let fresh = segment.len > 0 && connection.rcv_max.is_none_or(|max| after(end, max));
        if fresh {
            connection.rcv_max = Some(end);
        }
        fresh
    }

    /// The next packet allowed to leave at `now`, by class (see the module
    /// documentation). `Err` holds the earliest time a queued packet may
    /// leave.
    pub(crate) fn pop(&mut self, now: Instant) -> Result<Option<Vec<u8>>, Instant> {
        if let Some(packet) = self.other.pop_front() {
            self.queued -= 1;
            return Ok(Some(packet));
        }
        if let Some(packet) = self.interactive.pop_front() {
            return Ok(Some(packet));
        }
        if let Some(packet) = self.pop_connection(now, true) {
            return Ok(Some(packet));
        }
        self.expire_media(now);
        if let Some((_, packet)) = self.media.pop_front() {
            return Ok(Some(packet));
        }
        if let Some(packet) = self.pop_connection(now, false) {
            return Ok(Some(packet));
        }
        let bulk_free = self.bulk_next_free.filter(|_| !self.bulk.is_empty());
        if !self.bulk.is_empty() && bulk_free.is_none_or(|free| free <= now) {
            let packet = self.bulk.pop_front().expect("non-empty");
            if let Some(srtt) = self.srtt() {
                let rate = GAIN * f64::from(MIN_FLIGHT) / srtt.as_secs_f64().max(1e-6);
                let start = bulk_free
                    .map_or(now, |free| free.max(now.checked_sub(MAX_CREDIT).unwrap_or(now)));
                self.bulk_next_free =
                    Some(start + Duration::from_secs_f64(packet.len() as f64 / rate));
            }
            return Ok(Some(packet));
        }
        let earliest = self
            .connections
            .values()
            .filter(|connection| !connection.queue.is_empty())
            .map(|connection| connection.next_free)
            .chain(bulk_free)
            .min();
        earliest.map_or(Ok(None), Err)
    }

    /// The head of the shortest eligible queue among the interactive or the
    /// bulk connections; both are paced.
    fn pop_connection(&mut self, now: Instant, interactive: bool) -> Option<Vec<u8>> {
        let flow = self
            .connections
            .iter()
            .filter(|(_, connection)| {
                !connection.queue.is_empty()
                    && connection.interactive() == interactive
                    && connection.next_free <= now
            })
            .min_by_key(|(_, connection)| connection.queue.len())
            .map(|(flow, _)| *flow)?;
        let connection = self.connections.get_mut(&flow).expect("chosen above");
        let packet = connection.queue.pop_front().expect("non-empty queue");
        let segment = segment(&packet).expect("queued as TCP");
        connection.sent(&segment, packet.len(), now);
        self.queued -= 1;
        Some(packet)
    }
}

#[cfg(test)]
#[path = "pacing_tests.rs"]
mod tests;
