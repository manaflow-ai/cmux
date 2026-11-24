//! hop-bench: phone and Mac ends that measure a relay without the link client.
//!
//! The Mac end answers pings and, on START, sends a 60 fps class-1 frame
//! stream with a bulk stream beside it. The phone end measures:
//!
//! - `echo`: one ping per `interval` (keystroke cadence). An unanswered ping
//!   is sent again after `max(200 ms, 2 x srtt)`, as the TCP inside the tunnel
//!   would; its RTT runs from the first send to the first echo, which is what
//!   the person typing waits.
//! - `frames`: each delivered frame's delay (send to arrival), and the age of
//!   the newest frame the phone holds, sampled every 1/60 s. The age is the
//!   honest number under latest-wins: a dropped stale frame does not count as
//!   fast, it leaves the held frame older.
//!
//! Ends speak plain UDP (to a forwarder: today's TURN) or hop/1 (to the PoP).
//! Both ends run on one host in netlab, so the wall clock is shared.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};
use tokio::net::UdpSocket;
use tokio::time::Instant;

use crate::leg::HopLeg;
use crate::wire;

pub const K_HELLO: u8 = 1;
pub const K_START: u8 = 2;
pub const K_PING: u8 = 3;
pub const K_ECHO: u8 = 4;
pub const K_FRAME: u8 = 5;
pub const K_BULK: u8 = 6;
pub const K_STOP: u8 = 7;

pub const TEST_ECHO: u32 = 1;
pub const TEST_FRAMES: u32 = 2;

/// The bench's state key for frames (an opaque per-session id on a real link).
const FRAME_KEY: u32 = 1;
const HEADER: usize = 4 + 1 + 4 + 8 + 4;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Msg {
    pub kind: u8,
    pub id: u32,
    pub stamp: u64,
    pub extra: u32,
}

impl Msg {
    /// Shaped like a WireGuard data message (type 4, three zero bytes), so a
    /// plain relay leg classes it by size as it would real tunnel traffic.
    pub fn encode(&self, size: usize) -> Vec<u8> {
        let mut out = vec![4, 0, 0, 0, self.kind];
        out.extend_from_slice(&self.id.to_be_bytes());
        out.extend_from_slice(&self.stamp.to_be_bytes());
        out.extend_from_slice(&self.extra.to_be_bytes());
        out.resize(size.max(HEADER), 0);
        out
    }

    pub fn decode(bytes: &[u8]) -> Option<Self> {
        let ([4, 0, 0, 0, kind], rest) = bytes.split_first_chunk::<5>()? else {
            return None;
        };
        let (id, rest) = rest.split_first_chunk::<4>()?;
        let (stamp, rest) = rest.split_first_chunk::<8>()?;
        let (extra, _) = rest.split_first_chunk::<4>()?;
        Some(Self {
            kind: *kind,
            id: u32::from_be_bytes(*id),
            stamp: u64::from_be_bytes(*stamp),
            extra: u32::from_be_bytes(*extra),
        })
    }

    fn class_and_tag(&self) -> (u8, Option<(u32, u32)>) {
        match self.kind {
            K_FRAME => (wire::CLASS_STATE, Some((FRAME_KEY, self.id))),
            K_PING | K_ECHO => (wire::CLASS_INPUT, None),
            K_BULK => (wire::CLASS_BULK, None),
            _ => (wire::CLASS_CONTROL, None),
        }
    }
}

pub fn wall_ns() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| u64::try_from(d.as_nanos()).unwrap_or(u64::MAX))
        .unwrap_or(0)
}

/// One end's path to the other: plain datagrams to `peer`, or a hop/1 leg.
pub struct Path {
    sock: UdpSocket,
    peer: SocketAddr,
    leg: Option<HopLeg>,
    buf: Vec<u8>,
}

impl Path {
    pub fn plain(sock: UdpSocket, peer: SocketAddr) -> Self {
        Self { sock, peer, leg: None, buf: vec![0; 65_536] }
    }

    pub fn hop(sock: UdpSocket, peer: SocketAddr) -> Self {
        Self { sock, peer, leg: Some(HopLeg::new(Instant::now())), buf: vec![0; 65_536] }
    }

    /// BIND on the PoP at `pop` with `ticket`: the relayed address.
    pub async fn bind(
        sock: UdpSocket,
        pop: SocketAddr,
        ticket: &[u8],
    ) -> anyhow::Result<(Self, SocketAddr)> {
        let mut buf = vec![0_u8; 2048];
        for _ in 0..50 {
            sock.send_to(&wire::encode_bind(ticket), pop).await?;
            if let Ok(Ok((n, from))) =
                tokio::time::timeout(Duration::from_millis(200), sock.recv_from(&mut buf)).await
                && from == pop
            {
                let got = buf.get(..n).unwrap_or_default();
                if let Some((relayed, _)) = wire::decode_bind_ok(got) {
                    return Ok((Self::hop(sock, pop), relayed));
                }
                if let Some(code) = wire::decode_error(got) {
                    anyhow::bail!("BIND refused: error {code}");
                }
            }
        }
        anyhow::bail!("no BIND_OK from {pop}")
    }

    pub fn send(&mut self, msg: Msg, size: usize) {
        let bytes = msg.encode(size);
        match &mut self.leg {
            Some(leg) => {
                let (class, tag) = msg.class_and_tag();
                leg.push(class, tag, &bytes, Instant::now());
            }
            None => {
                let _ = self.sock.try_send_to(&bytes, self.peer);
            }
        }
    }

    pub async fn flush(&mut self) {
        let now = Instant::now();
        if let Some(leg) = &mut self.leg {
            leg.on_timeout(now);
            while let Some(d) = leg.poll_transmit(now) {
                let _ = self.sock.send_to(&d, self.peer).await;
            }
        }
    }

    pub fn wake(&self) -> Option<Instant> {
        self.leg.as_ref().and_then(HopLeg::poll_timeout)
    }

    /// Waits for one datagram (or `until`) and returns the messages it carried.
    pub async fn recv(&mut self, until: Instant) -> Vec<Msg> {
        let until = self.wake().map_or(until, |w| w.min(until));
        let got = tokio::select! {
            got = self.sock.recv_from(&mut self.buf) => got.ok(),
            () = tokio::time::sleep_until(until) => None,
        };
        let Some((n, from)) = got else { return Vec::new() };
        if from != self.peer {
            return Vec::new();
        }
        let datagram = self.buf.get(..n).unwrap_or_default();
        match &mut self.leg {
            Some(leg) => leg
                .handle(datagram, Instant::now())
                .iter()
                .filter_map(|r| Msg::decode(&r.bytes))
                .collect(),
            None => Msg::decode(datagram).into_iter().collect(),
        }
    }

    pub fn leg_stats(&self) -> Option<Value> {
        self.leg.as_ref().map(|l| crate::server::stats_json(&l.stats()))
    }
}

pub fn percentile(sorted: &[f64], p: f64) -> Option<f64> {
    if sorted.is_empty() {
        return None;
    }
    let rank = ((p / 100.0) * sorted.len() as f64).ceil() as usize;
    sorted.get(rank.clamp(1, sorted.len()) - 1).map(|v| (v * 10.0).round() / 10.0)
}

fn summary(mut v: Vec<f64>) -> Value {
    v.sort_by(f64::total_cmp);
    json!({"n": v.len(), "p50": percentile(&v, 50.0), "p95": percentile(&v, 95.0),
           "p99": percentile(&v, 99.0), "max": v.last().map(|x| (x * 10.0).round() / 10.0)})
}

pub struct PhoneRun {
    pub test: u32,
    pub duration: Duration,
    pub interval: Duration,
    pub ping_bytes: usize,
}

/// Waits until the Mac's HELLO arrives through the relay.
pub async fn phone_handshake(path: &mut Path, deadline: Duration) -> anyhow::Result<()> {
    let end = Instant::now() + deadline;
    let mut next_hello = Instant::now();
    while Instant::now() < end {
        if Instant::now() >= next_hello {
            path.send(Msg { kind: K_HELLO, id: 0, stamp: wall_ns(), extra: 0 }, 64);
            next_hello = Instant::now() + Duration::from_millis(200);
        }
        path.flush().await;
        if path.recv(next_hello).await.iter().any(|m| m.kind == K_HELLO) {
            return Ok(());
        }
    }
    anyhow::bail!("no HELLO from the Mac end through the relay")
}

pub async fn phone_run(path: &mut Path, run: &PhoneRun) -> Value {
    let nonce = u32::try_from(wall_ns() % u64::from(u32::MAX)).unwrap_or(1);
    let duration_ms = u64::try_from(run.duration.as_millis()).unwrap_or(u64::MAX);
    for _ in 0..3 {
        path.send(Msg { kind: K_START, id: run.test, stamp: duration_ms, extra: nonce }, 64);
        path.flush().await;
    }
    let result =
        if run.test == TEST_ECHO { echo(path, run).await } else { frames(path, run).await };
    for _ in 0..3 {
        path.send(Msg { kind: K_STOP, id: run.test, stamp: 0, extra: nonce }, 64);
        path.flush().await;
    }
    result
}

async fn echo(path: &mut Path, run: &PhoneRun) -> Value {
    struct Ping {
        first: Instant,
        last: Instant,
        sends: u32,
        rtt: Option<f64>,
    }
    let start = Instant::now();
    let stop_sending = start + run.duration;
    let give_up = stop_sending + Duration::from_secs(5);
    let mut pings: Vec<Ping> = Vec::new();
    let mut next_ping = start;
    let mut srtt: Option<f64> = None;
    loop {
        let now = Instant::now();
        if now >= give_up || (now >= stop_sending && pings.iter().all(|p| p.rtt.is_some())) {
            break;
        }
        if now >= next_ping && now < stop_sending {
            let id = u32::try_from(pings.len()).unwrap_or(u32::MAX);
            path.send(Msg { kind: K_PING, id, stamp: wall_ns(), extra: 0 }, run.ping_bytes);
            pings.push(Ping { first: now, last: now, sends: 1, rtt: None });
            next_ping += run.interval;
        }
        let rto = Duration::from_secs_f64((2.0 * srtt.unwrap_or(200.0) / 1000.0).max(0.2));
        let mut next_rto = give_up;
        for (id, p) in pings.iter_mut().enumerate() {
            if p.rtt.is_some() {
                continue;
            }
            let due = p.last + rto * (1 << p.sends.saturating_sub(1).min(4));
            if now >= due {
                let id = u32::try_from(id).unwrap_or(u32::MAX);
                path.send(
                    Msg { kind: K_PING, id, stamp: wall_ns(), extra: p.sends },
                    run.ping_bytes,
                );
                p.last = now;
                p.sends += 1;
            } else {
                next_rto = next_rto.min(due);
            }
        }
        path.flush().await;
        let until = if now < stop_sending { next_ping.min(next_rto) } else { next_rto };
        for m in path.recv(until).await {
            if m.kind != K_ECHO {
                continue;
            }
            if let Some(p) = pings.get_mut(m.id as usize)
                && p.rtt.is_none()
            {
                let rtt = Instant::now().duration_since(p.first).as_secs_f64() * 1000.0;
                p.rtt = Some(rtt);
                srtt = Some(srtt.map_or(rtt, |s| 0.875 * s + 0.125 * rtt));
            }
        }
    }
    let rtts: Vec<f64> = pings.iter().filter_map(|p| p.rtt).collect();
    let lost = pings.len() - rtts.len();
    let resends: u32 = pings.iter().map(|p| p.sends - 1).sum();
    json!({"test": "echo", "sent": pings.len(), "lost": lost, "app_resends": resends,
           "rtt_ms": summary(rtts), "leg": path.leg_stats()})
}

async fn frames(path: &mut Path, run: &PhoneRun) -> Value {
    let start = Instant::now();
    let end = start + run.duration + Duration::from_millis(500);
    let tick = Duration::from_micros(16_667);
    let mut next_sample = start + Duration::from_millis(500);
    let mut newest: Option<(u32, u64)> = None;
    let mut delays = Vec::new();
    let mut ages = Vec::new();
    let mut bulk_bytes = 0_u64;
    let mut highest_sent = 0_u32;
    let mut first_bulk: Option<Instant> = None;
    while Instant::now() < end {
        path.flush().await;
        for m in path.recv(next_sample.min(end)).await {
            let now_ns = wall_ns();
            match m.kind {
                K_FRAME => {
                    delays.push(now_ns.saturating_sub(m.stamp) as f64 / 1e6);
                    highest_sent = highest_sent.max(m.id);
                    if newest.is_none_or(|(id, _)| m.id > id) {
                        newest = Some((m.id, m.stamp));
                    }
                }
                K_BULK => {
                    first_bulk.get_or_insert_with(Instant::now);
                    bulk_bytes += u64::from(m.extra);
                }
                _ => {}
            }
        }
        let now = Instant::now();
        if now >= next_sample {
            // Sample only once frames flow, and not past the Mac's stream.
            if let Some((_, stamp)) = newest
                && now < start + run.duration
            {
                ages.push(wall_ns().saturating_sub(stamp) as f64 / 1e6);
            }
            next_sample += tick;
        }
    }
    let secs = first_bulk.map_or(0.0, |t| Instant::now().duration_since(t).as_secs_f64());
    json!({"test": "frames", "frames_delivered": delays.len(), "highest_frame": highest_sent,
           "delay_ms": summary(delays), "age_ms": summary(ages),
           "bulk_kbit": if secs > 0.0 { (bulk_bytes as f64 * 8.0 / 1000.0 / secs).round() } else { 0.0 },
           "leg": path.leg_stats()})
}

pub struct MacConfig {
    pub fps: u32,
    pub frame_bytes: usize,
    pub bulk_kbit: u64,
    pub bulk_bytes: usize,
}

/// Serves forever: HELLO every 200 ms, echoes, and START's streams.
pub async fn mac_serve(path: &mut Path, cfg: &MacConfig) {
    let mut next_hello = Instant::now();
    let mut stream_until: Option<Instant> = None;
    let mut last_nonce = None;
    let mut next_frame = Instant::now();
    let mut frame_id = 0_u32;
    let mut bulk_at = Instant::now();
    let frame_every = Duration::from_secs_f64(1.0 / f64::from(cfg.fps.max(1)));
    let bulk_per_sec = cfg.bulk_kbit as f64 * 1000.0 / 8.0;
    let mut bulk_credit = 0.0_f64;
    loop {
        let now = Instant::now();
        if now >= next_hello {
            path.send(Msg { kind: K_HELLO, id: 0, stamp: wall_ns(), extra: 0 }, 64);
            next_hello = now + Duration::from_millis(200);
        }
        if let Some(until) = stream_until {
            if now >= until {
                stream_until = None;
            } else {
                while next_frame <= now {
                    frame_id += 1;
                    path.send(
                        Msg { kind: K_FRAME, id: frame_id, stamp: wall_ns(), extra: 0 },
                        cfg.frame_bytes,
                    );
                    next_frame += frame_every;
                }
                bulk_credit += now.duration_since(bulk_at).as_secs_f64() * bulk_per_sec;
                bulk_at = now;
                let size = cfg.bulk_bytes.max(HEADER);
                while bulk_credit >= size as f64 {
                    bulk_credit -= size as f64;
                    let extra = u32::try_from(size).unwrap_or(0);
                    path.send(Msg { kind: K_BULK, id: 0, stamp: wall_ns(), extra }, size);
                }
            }
        }
        path.flush().await;
        let mut until = next_hello;
        if stream_until.is_some() {
            until = until.min(next_frame).min(Instant::now() + Duration::from_millis(2));
        }
        for m in path.recv(until).await {
            match m.kind {
                K_PING => {
                    path.send(Msg { kind: K_ECHO, ..m }, 96);
                }
                K_START if last_nonce != Some(m.extra) => {
                    last_nonce = Some(m.extra);
                    if m.id == TEST_FRAMES {
                        let now = Instant::now();
                        stream_until = Some(now + Duration::from_millis(m.stamp));
                        next_frame = now;
                        bulk_at = now;
                        bulk_credit = 0.0;
                    }
                }
                K_STOP => stream_until = None,
                _ => {}
            }
        }
    }
}

/// Reads the relayed address the phone end wrote, waiting for it.
pub async fn read_addr_file(path: &PathBuf, wait: Duration) -> anyhow::Result<SocketAddr> {
    let end = Instant::now() + wait;
    loop {
        if let Ok(text) = std::fs::read_to_string(path)
            && let Ok(addr) = text.trim().parse()
        {
            return Ok(addr);
        }
        if Instant::now() >= end {
            anyhow::bail!("no relayed address in {}", path.display());
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}
