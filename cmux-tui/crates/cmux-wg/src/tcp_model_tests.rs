//! Model-based test of the tunnel TCP ([`crate::tcp_stack::TcpStack`]) over a
//! lossy link, checked by [`crate::testing::tcp_oracle`].
//!
//! Two stacks, a client and a server, exchange IP packets through a seeded
//! channel that drops, duplicates, delays and so reorders them. A seeded
//! workload drives the two streams at once: writes of random sizes in both
//! directions, reads into random buffer sizes (and sometimes none for a
//! while, so the window closes), then a half-close or a full close (dropping
//! the stream) on each side at a random point. Every write, read, EOF and
//! error is reported to the oracle, which checks it at once; at the end every
//! reader whose peer shut down must hold every byte and EOF, and both stacks
//! must have let go of the connection, all within a bound of simulated time.
//!
//! The clock is Tokio's paused clock, so a run's minutes of retransmission
//! timeouts take milliseconds. A failure prints its seed; replay it with
//! `CMUX_WG_TCP_MODEL_SEED=<seed>`. `CMUX_WG_TCP_MODEL_SEEDS=<n>` runs more
//! seeds (default [`DEFAULT_SEEDS`]) and `CMUX_WG_TCP_MODEL_FIRST=<n>` starts
//! elsewhere. The stacks pick their initial sequence numbers at random, so a
//! seed fixes the channel and the workload, not the ISN.

use std::cmp::Reverse;
use std::collections::BinaryHeap;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll, Waker};
use std::time::Duration;

use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::sync::{Notify, mpsc, oneshot};

use crate::config::InterfaceAddress;
use crate::error::WgError;
use crate::stream::WgStream;
use crate::tcp_stack::{Accepted, TcpStack};
use crate::testing::tcp_oracle::{End, StreamOracle, Violation};

const DEFAULT_SEEDS: u64 = 48;
const PORT: u16 = 7000;
const MTU: u16 = 1380;
/// Simulated time a run may take before it counts as a hang. The loss rate
/// tops out at 12%, where a handful of back-to-back RTOs on one segment
/// already cost tens of seconds.
const HANG_BOUND: Duration = Duration::from_secs(600);
/// Largest stream one side writes.
const MAX_STREAM_BYTES: usize = 384 * 1024;

const CLIENT_IP: Ipv4Addr = Ipv4Addr::new(10, 200, 0, 1);
const SERVER_IP: Ipv4Addr = Ipv4Addr::new(10, 200, 0, 2);

/// SplitMix64: small, seedable, good enough to pick fates.
#[derive(Clone)]
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        z ^ (z >> 31)
    }

    /// Uniform in `0..n` (`n > 0`).
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }

    /// Uniform in `low..=high`.
    fn range(&mut self, low: u64, high: u64) -> u64 {
        low + self.below(high - low + 1)
    }

    fn chance(&mut self, probability: f64) -> bool {
        (self.next() >> 11) as f64 / (1u64 << 53) as f64 * 1.0 < probability
    }
}

/// How the link treats every packet, both directions.
#[derive(Debug, Clone, Copy)]
struct Link {
    loss: f64,
    duplicate: f64,
    /// Fixed one-way delay.
    delay: Duration,
    /// Extra delay drawn per packet in `0..=jitter`; packets overtake each
    /// other when it exceeds their spacing.
    jitter: Duration,
}

impl Link {
    fn draw(rng: &mut Rng) -> Self {
        let loss = match rng.below(4) {
            0 => 0.0,
            1 => 0.01,
            2 => 0.05,
            _ => 0.12,
        };
        Self {
            loss,
            duplicate: if rng.chance(0.5) { 0.03 } else { 0.0 },
            delay: Duration::from_millis(rng.range(1, 40)),
            jitter: Duration::from_millis(if rng.chance(0.5) { rng.range(1, 30) } else { 0 }),
        }
    }
}

/// How one side ends its write side.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Ending {
    /// `shutdown()`, then keep reading to EOF.
    HalfClose,
    /// Drop the stream after the last write: no more reads.
    Drop,
    /// Abort the connection (the stack resets it, as `abort_conns` does when
    /// a mesh peer goes away). The peer must see an error, never an EOF.
    Abort,
}

/// One side's script.
#[derive(Debug, Clone, Copy)]
struct Script {
    total: usize,
    /// Largest single write.
    max_write: usize,
    /// Largest single read buffer.
    max_read: usize,
    /// Chance a step reads at all (a slow reader closes the window).
    read_chance: f64,
    ending: Ending,
    /// Bytes the peer must have read before this side ends (0: whenever).
    /// Lets one side half-close long before the other finishes sending.
    end_after_peer: usize,
}

impl Script {
    fn draw(rng: &mut Rng) -> Self {
        let total = match rng.below(5) {
            0 => 0,
            1 => rng.range(1, 2_000) as usize,
            _ => rng.range(1, MAX_STREAM_BYTES as u64) as usize,
        };
        let max_write = [1, 100, 1_400, 16 * 1024, 70_000][rng.below(5) as usize];
        let max_read = [1, 512, 4_096, 64 * 1024][rng.below(4) as usize];
        Self {
            total,
            max_write,
            max_read,
            read_chance: [1.0, 0.5, 0.2][rng.below(3) as usize],
            ending: match rng.below(100) {
                0..10 => Ending::Abort,
                10..35 => Ending::Drop,
                _ => Ending::HalfClose,
            },
            end_after_peer: 0,
        }
    }
}

#[derive(Debug, Clone, Copy)]
struct Scenario {
    link: Link,
    scripts: [Script; 2],
}

impl Scenario {
    fn draw(seed: u64) -> Self {
        let mut rng = Rng(seed);
        let link = Link::draw(&mut rng);
        let mut scripts = [Script::draw(&mut rng), Script::draw(&mut rng)];
        // Keep at least one side reading to the end, or the run has
        // nothing to check past the writes.
        if scripts.iter().all(|script| script.ending != Ending::HalfClose) {
            scripts[1].ending = Ending::HalfClose;
        }
        // A dropping side may wait for the peer's bytes first, as a request
        // and response would; a half-closing one may close early.
        for index in 0..2 {
            let peer_total = scripts[1 - index].total;
            if peer_total > 0 && rng.chance(0.3) {
                scripts[index].end_after_peer = rng.range(1, peer_total as u64) as usize;
            }
        }
        Self { link, scripts }
    }
}

/// A packet in flight.
#[derive(PartialEq, Eq, PartialOrd, Ord)]
struct InFlight {
    due: Duration,
    /// Send order, so equal due times keep FIFO order.
    order: u64,
    to_server: bool,
    packet: Vec<u8>,
}

struct Channel {
    link: Link,
    rng: Rng,
    queue: BinaryHeap<Reverse<InFlight>>,
    order: u64,
    sent: u64,
    dropped: u64,
    duplicated: u64,
    resets: u64,
}

impl Channel {
    fn send(&mut self, now: Duration, to_server: bool, packet: Vec<u8>) {
        self.sent += 1;
        if tracing() {
            eprintln!(
                "{now:>12?} {} {}",
                if to_server { "c->s" } else { "s->c" },
                describe(&packet)
            );
        }
        if is_reset(&packet) {
            self.resets += 1;
        }
        if self.rng.chance(self.link.loss) {
            self.dropped += 1;
            return;
        }
        let copies = if self.rng.chance(self.link.duplicate) { 2 } else { 1 };
        self.duplicated += copies - 1;
        for _ in 0..copies {
            let jitter = self.link.jitter.as_micros() as u64;
            let extra =
                Duration::from_micros(if jitter == 0 { 0 } else { self.rng.range(0, jitter) });
            self.order += 1;
            self.queue.push(Reverse(InFlight {
                due: now + self.link.delay + extra,
                order: self.order,
                to_server,
                packet: packet.clone(),
            }));
        }
    }

    fn next_due(&self) -> Option<Duration> {
        self.queue.peek().map(|Reverse(flight)| flight.due)
    }

    fn pop_due(&mut self, now: Duration) -> Option<InFlight> {
        if self.next_due()? > now {
            return None;
        }
        self.queue.pop().map(|Reverse(flight)| flight)
    }
}

fn tracing() -> bool {
    std::env::var_os("CMUX_WG_TCP_MODEL_TRACE").is_some()
}

/// An IPv4 TCP packet's flags, sequence numbers and payload length.
fn describe(packet: &[u8]) -> String {
    let header = usize::from(packet.first().copied().unwrap_or(0) & 0x0f) * 4;
    let Some(tcp) = packet.get(header..) else { return "short".into() };
    if tcp.len() < 20 {
        return "short".into();
    }
    let word = |at: usize| u32::from_be_bytes([tcp[at], tcp[at + 1], tcp[at + 2], tcp[at + 3]]);
    let flags = tcp[13];
    let names: String = [(0x02, 'S'), (0x10, '.'), (0x01, 'F'), (0x04, 'R'), (0x08, 'P')]
        .iter()
        .filter(|(bit, _)| flags & bit != 0)
        .map(|(_, name)| *name)
        .collect();
    let data = tcp.len() - usize::from(tcp[12] >> 4) * 4;
    let window = u16::from_be_bytes([tcp[14], tcp[15]]);
    format!("[{names}] seq {} ack {} len {data} win {window}", word(4), word(8))
}

/// Whether an IPv4 TCP packet has RST set.
fn is_reset(packet: &[u8]) -> bool {
    let header = usize::from(packet.first().copied().unwrap_or(0) & 0x0f) * 4;
    packet.get(9) == Some(&6) && packet.get(header + 13).is_some_and(|flags| flags & 0x04 != 0)
}

/// One side's stream and where its script stands.
struct Side {
    end: End,
    script: Script,
    rng: Rng,
    /// The bytes this side writes, generated up front.
    data: Vec<u8>,
    written: usize,
    stream: Option<WgStream>,
    ended: bool,
    reading: bool,
    /// The script ended in an abort the harness has yet to carry out.
    abort: bool,
}

impl Side {
    fn new(end: End, script: Script, seed: u64) -> Self {
        let mut rng = Rng(seed ^ if end == End::Client { 0xc11e } else { 0x5e7e });
        let data = (0..script.total).map(|_| rng.next() as u8).collect();
        Self {
            end,
            script,
            rng,
            data,
            written: 0,
            stream: None,
            ended: false,
            reading: true,
            abort: false,
        }
    }

    fn status(&self) -> String {
        format!(
            "[wrote {}/{}, ended {}, reading {}, stream {:?}]",
            self.written,
            self.data.len(),
            self.ended,
            self.reading,
            self.stream.as_ref().map(|stream| (
                stream.leftover.len(),
                stream.inbound.len(),
                stream.inbound.is_closed()
            ))
        )
    }

    /// Whether this side has nothing left to do but read.
    fn done(&self, oracle: &StreamOracle) -> bool {
        self.ended && (!self.reading || oracle.saw_eof(self.end))
    }

    /// One step of the script. Returns whether anything happened.
    fn act(&mut self, oracle: &mut StreamOracle, cx: &mut Context<'_>) -> Result<bool, Violation> {
        let Some(stream) = self.stream.as_mut() else { return Ok(false) };
        let mut acted = false;
        // Writes: a few per step, each of a random size.
        for _ in 0..4 {
            if self.written == self.data.len() {
                break;
            }
            let remaining = self.data.len() - self.written;
            let size = self.rng.range(1, remaining.min(self.script.max_write) as u64) as usize;
            let chunk = &self.data[self.written..self.written + size];
            match Pin::new(&mut *stream).poll_write(cx, chunk) {
                Poll::Ready(Ok(count)) => {
                    oracle.wrote(self.end, &chunk[..count])?;
                    self.written += count;
                    acted = true;
                }
                Poll::Ready(Err(error)) => {
                    oracle.error(self.end, &format!("write: {error}"))?;
                    self.reading = false;
                    self.ended = true;
                    self.stream = None;
                    return Ok(true);
                }
                Poll::Pending => break,
            }
        }
        // Reads: maybe none this step.
        if self.reading && !oracle.saw_eof(self.end) && self.rng.chance(self.script.read_chance) {
            for _ in 0..1024 {
                let size = self.rng.range(1, self.script.max_read as u64) as usize;
                let mut buffer = vec![0u8; size];
                let mut read = ReadBuf::new(&mut buffer);
                match Pin::new(&mut *stream).poll_read(cx, &mut read) {
                    Poll::Ready(Ok(())) if read.filled().is_empty() => {
                        oracle.eof(self.end)?;
                        acted = true;
                        break;
                    }
                    Poll::Ready(Ok(())) => {
                        oracle.read(self.end, read.filled())?;
                        acted = true;
                    }
                    Poll::Ready(Err(error)) => {
                        oracle.error(self.end, &format!("read: {error}"))?;
                        self.reading = false;
                        break;
                    }
                    Poll::Pending => break,
                }
            }
        }
        // End once every byte is written and this side has read what its
        // script waits for.
        if !self.ended && self.written == self.data.len() {
            let (read, _) = oracle.progress(self.end);
            if read >= self.script.end_after_peer || oracle.saw_eof(self.end) || !self.reading {
                match self.script.ending {
                    Ending::HalfClose => match Pin::new(&mut *stream).poll_shutdown(cx) {
                        Poll::Ready(Ok(())) => {
                            oracle.shutdown(self.end);
                            self.ended = true;
                            acted = true;
                        }
                        Poll::Ready(Err(error)) => {
                            oracle.error(self.end, &format!("shutdown: {error}"))?;
                        }
                        Poll::Pending => {}
                    },
                    Ending::Abort => {
                        // The harness aborts once both ends hold their
                        // streams, then drops this one.
                        self.reading = false;
                        self.ended = true;
                        self.abort = true;
                        acted = true;
                    }
                    Ending::Drop => {
                        // Dropping the stream closes the write side once the
                        // queued writes are in, like `close(2)`.
                        oracle.shutdown(self.end);
                        self.stream = None;
                        self.reading = false;
                        self.ended = true;
                        acted = true;
                    }
                }
            }
        }
        Ok(acted)
    }
}

/// What a run saw, for the failure message.
#[derive(Debug)]
struct Outcome {
    elapsed: Duration,
    sent: u64,
    dropped: u64,
    duplicated: u64,
    resets: u64,
}

fn stack(own: Ipv4Addr) -> TcpStack {
    let addresses = [InterfaceAddress { address: IpAddr::V4(own), prefix: 32 }];
    TcpStack::new(&addresses, MTU, Arc::new(Notify::new()), false)
        .unwrap_or_else(|error| panic!("stack: {error}"))
}

fn to_duration(delay: Option<Duration>) -> Duration {
    delay.unwrap_or(Duration::MAX)
}

/// Run one seed to completion or to its first violation.
async fn run(seed: u64) -> Result<Outcome, String> {
    let scenario = Scenario::draw(seed);
    let start = tokio::time::Instant::now();
    let now = || tokio::time::Instant::now() - start;
    let mut client = stack(CLIENT_IP);
    let mut server = stack(SERVER_IP);
    let mut channel = Channel {
        link: scenario.link,
        rng: Rng(seed.rotate_left(17) ^ 0x11_4e),
        queue: BinaryHeap::new(),
        order: 0,
        sent: 0,
        dropped: 0,
        duplicated: 0,
        resets: 0,
    };
    let aborts = scenario.scripts.iter().any(|script| script.ending == Ending::Abort);
    let mut oracle = StreamOracle::new(aborts);
    let mut sides = [
        Side::new(End::Client, scenario.scripts[0], seed),
        Side::new(End::Server, scenario.scripts[1], seed),
    ];
    let mut accept: mpsc::Receiver<Accepted> =
        server.begin_listen(PORT).map_err(|error| format!("listen: {error}"))?;
    let (reply, mut connected): (_, oneshot::Receiver<Result<WgStream, WgError>>) =
        oneshot::channel();
    client.begin_connect(
        IpAddr::V4(CLIENT_IP),
        SocketAddr::new(IpAddr::V4(SERVER_IP), PORT),
        None,
        reply,
    );
    let waker = Waker::noop();
    let mut cx = Context::from_waker(waker);
    let mut opened = [false, false];
    let mut released = false;
    let mut last_states: (Option<String>, Option<String>) = (None, None);

    loop {
        let elapsed = now();
        if elapsed > HANG_BOUND {
            return Err(format!(
                "hang: not finished after {HANG_BOUND:?} (client read {:?}, server read {:?}, \
                 client {}, server {}, client conns {}, server conns {})",
                oracle.progress(End::Client),
                oracle.progress(End::Server),
                sides[0].status(),
                sides[1].status(),
                client.conns.len(),
                server.conns.len(),
            ));
        }
        let mut busy = false;
        // Deliver what is due.
        while let Some(flight) = channel.pop_due(elapsed) {
            let target = if flight.to_server { &mut server } else { &mut client };
            target.push_rx(flight.packet, None);
            busy = true;
        }
        busy |= client.step();
        busy |= server.step();
        // Hand-offs.
        if !opened[0] {
            match connected.try_recv() {
                Ok(Ok(stream)) => {
                    sides[0].stream = Some(stream);
                    opened[0] = true;
                }
                Ok(Err(error)) => return Err(format!("connect failed: {error}")),
                Err(oneshot::error::TryRecvError::Empty) => {}
                Err(oneshot::error::TryRecvError::Closed) => {
                    return Err("connect reply dropped".into());
                }
            }
        }
        if !opened[1]
            && let Ok((stream, _)) = accept.try_recv()
        {
            sides[1].stream = Some(stream);
            opened[1] = true;
        }
        for side in &mut sides {
            busy |= side.act(&mut oracle, &mut cx).map_err(|violation| violation.to_string())?;
        }
        for (side, stack) in sides.iter_mut().zip([&mut client, &mut server]) {
            if side.abort && opened.iter().all(|opened| *opened) {
                stack.abort_conns(|_| true);
                side.abort = false;
                side.stream = None;
            }
        }
        if busy {
            busy |= client.step();
            busy |= server.step();
        }
        while let Some(packet) = client.pop_tx() {
            channel.send(elapsed, true, packet);
            busy = true;
        }
        while let Some(packet) = server.pop_tx() {
            channel.send(elapsed, false, packet);
            busy = true;
        }

        if tracing() {
            let state = |stack: &TcpStack| {
                stack.conns.first().map(|conn| {
                    let socket = stack.sockets.get::<smoltcp::socket::tcp::Socket>(conn.handle);
                    socket.state().to_string()
                })
            };
            let states = (state(&client), state(&server));
            if states != last_states {
                eprintln!("{elapsed:>12?} states client {:?} server {:?}", states.0, states.1);
                last_states = states;
            }
        }
        let finished =
            opened.iter().all(|opened| *opened) && sides.iter().all(|side| side.done(&oracle));
        if finished && !released {
            // Both scripts are over: the owners let go, as a program would.
            oracle
                .finish([sides[0].reading, sides[1].reading])
                .map_err(|violation| violation.to_string())?;
            for side in &mut sides {
                side.stream = None;
            }
            released = true;
            busy = true;
        }
        if released && client.conns.is_empty() && server.conns.is_empty() {
            return Ok(Outcome {
                elapsed,
                sent: channel.sent,
                dropped: channel.dropped,
                duplicated: channel.duplicated,
                resets: channel.resets,
            });
        }

        // Advance the clock: a millisecond while things move (so the
        // workload keeps acting between packets), else to the next event.
        let step = if busy {
            Duration::from_millis(1)
        } else {
            let next = to_duration(client.poll_delay())
                .min(to_duration(server.poll_delay()))
                .min(channel.next_due().map_or(Duration::MAX, |due| due.saturating_sub(elapsed)))
                .min(Duration::from_millis(10));
            next.max(Duration::from_micros(100))
        };
        tokio::time::advance(step).await;
    }
}

fn env_u64(name: &str) -> Option<u64> {
    std::env::var(name).ok().and_then(|value| value.parse().ok())
}

#[tokio::test(start_paused = true)]
async fn tunnel_tcp_delivers_every_byte_once_in_order_over_a_lossy_link() {
    let seeds: Vec<u64> = match env_u64("CMUX_WG_TCP_MODEL_SEED") {
        Some(seed) => vec![seed],
        None => {
            let first = env_u64("CMUX_WG_TCP_MODEL_FIRST").unwrap_or(0);
            let count = env_u64("CMUX_WG_TCP_MODEL_SEEDS").unwrap_or(DEFAULT_SEEDS);
            (first..first + count).collect()
        }
    };
    let mut failures = Vec::new();
    let (mut runs, mut simulated, mut sent, mut dropped, mut duplicated, mut resets) =
        (0, Duration::ZERO, 0, 0, 0, 0);
    for seed in seeds {
        match run(seed).await {
            Ok(outcome) => {
                if env_u64("CMUX_WG_TCP_MODEL_VERBOSE").is_some() {
                    eprintln!("seed {seed}: ok {outcome:?} {:?}", Scenario::draw(seed));
                }
                runs += 1;
                simulated += outcome.elapsed;
                sent += outcome.sent;
                dropped += outcome.dropped;
                duplicated += outcome.duplicated;
                resets += outcome.resets;
            }
            Err(failure) => {
                eprintln!(
                    "seed {seed} FAILED: {failure}\n  scenario: {:?}\n  replay: \
                     CMUX_WG_TCP_MODEL_SEED={seed} cargo test -p cmux-wg --lib tcp_model",
                    Scenario::draw(seed)
                );
                failures.push(seed);
            }
        }
    }
    eprintln!(
        "tcp model: {runs} seeds passed, {simulated:?} simulated, {sent} packets sent, \
         {dropped} dropped, {duplicated} duplicated, {resets} RST segments"
    );
    assert!(failures.is_empty(), "failing seeds: {failures:?}");
}
