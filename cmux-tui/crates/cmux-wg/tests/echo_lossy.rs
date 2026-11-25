//! A keystroke's echo on a lossy cellular path: 80 ms round trip, 1 % random
//! loss each way, one 12-byte frame every 20 ms for a minute (netlab
//! `wificell.sh`'s probe). Prints the echo's p50, p99 and longest gap between
//! arrivals for each ultra choice. The clock is Tokio's paused clock.

use std::io;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::task::{Context, Poll};
use std::time::Duration;

use cmux_transport::PathId;
use cmux_wg::testing::config_pair;
use cmux_wg::testing::sim::{LinkProfile, SimNet};
use cmux_wg::{Origin, Received, SocketPath, UltraChoice, Underlay, WgNet};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::time::Instant;

const CLIENT: &str = "192.0.2.110:51820";
const SERVER: &str = "192.0.2.111:51820";
const ONE_WAY: Duration = Duration::from_millis(40);
const RTT_MS: f64 = 80.0;
const FRAMES: usize = 3000;
const INTERVAL: Duration = Duration::from_millis(20);
const FRAME: usize = 12;

static METERED: AtomicBool = AtomicBool::new(true);

fn addr(text: &str) -> SocketAddr {
    text.parse().expect("literal address")
}

/// Drops each datagram it sends with probability `percent`/100 (seeded), once
/// `armed` is set, as netem's `loss` does: handshake and repair data too.
struct Netem<U> {
    inner: U,
    state: u64,
    per_mille: u64,
    armed: &'static AtomicBool,
    dropped: &'static AtomicU64,
}

impl<U: Underlay> Netem<U> {
    fn outgoing(&mut self, send: impl Fn(&mut U)) {
        self.state = self.state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        if self.armed.load(Ordering::Relaxed) && (self.state >> 33) % 1000 < self.per_mille {
            self.dropped.fetch_add(1, Ordering::Relaxed);
            return;
        }
        send(&mut self.inner);
    }
}

impl<U: Underlay> Underlay for Netem<U> {
    fn send(&mut self, datagram: &[u8]) {
        self.outgoing(|inner| inner.send(datagram));
    }
    fn send_on(&mut self, path: PathId, datagram: &[u8]) {
        self.outgoing(|inner| inner.send_on(path, datagram));
    }
    fn flush(&mut self) {
        self.inner.flush();
    }
    fn backlogged(&self) -> bool {
        self.inner.backlogged()
    }
    fn poll_flush(&mut self, cx: &mut Context<'_>) -> Poll<()> {
        self.inner.poll_flush(cx)
    }
    fn poll_recv(&mut self, cx: &mut Context<'_>, buffer: &mut [u8]) -> Poll<io::Result<Received>> {
        self.inner.poll_recv(cx, buffer)
    }
    fn authenticated(&mut self, origin: Origin) {
        self.inner.authenticated(origin);
    }
    fn has_peer(&self) -> bool {
        self.inner.has_peer()
    }
    fn peer_hint(&self) -> Option<SocketAddr> {
        self.inner.peer_hint()
    }
}

struct Result {
    p50: f64,
    p99: f64,
    max: f64,
    max_gap: f64,
    gaps_over_200: usize,
}

async fn run(choice: UltraChoice, seed: u64) -> Result {
    static ARMED: AtomicBool = AtomicBool::new(false);
    static DROPPED: AtomicU64 = AtomicU64::new(0);
    ARMED.store(false, Ordering::Relaxed);
    let sim = SimNet::new();
    sim.set_link(
        addr(CLIENT),
        addr(SERVER),
        LinkProfile { latency: ONE_WAY, ..Default::default() },
    );
    let configs = config_pair(addr(SERVER));
    let netem = |inner, salt: u64| Netem {
        inner,
        state: seed ^ salt,
        per_mille: 10,
        armed: &ARMED,
        dropped: &DROPPED,
    };
    let server_path = netem(SocketPath::new(sim.bind(addr(SERVER)).unwrap(), None), 1);
    let server = WgNet::start_with_choice(configs.server, server_path, choice).unwrap();
    let mut listener = server.listen(7000).await.unwrap();
    tokio::spawn(async move {
        while let Some(mut stream) = listener.accept().await {
            tokio::spawn(async move {
                let mut buffer = [0u8; 4096];
                loop {
                    match stream.read(&mut buffer).await {
                        Ok(0) | Err(_) => break,
                        Ok(n) => {
                            if stream.write_all(&buffer[..n]).await.is_err() {
                                break;
                            }
                        }
                    }
                }
            });
        }
    });
    let client_path =
        netem(SocketPath::new(sim.bind(addr(CLIENT)).unwrap(), Some(addr(SERVER))), 2);
    let client = WgNet::start_with_choice(configs.client, client_path, choice).unwrap();
    let stream = client.connect(SocketAddr::new(configs.server_v4, 7000)).await.unwrap();
    let (mut reader, mut writer) = tokio::io::split(stream);
    // Warm up on a clean link so the RTT is measured and Auto is off, then the loss starts.
    for _ in 0..50 {
        writer.write_all(&[0u8; FRAME]).await.unwrap();
        reader.read_exact(&mut [0u8; FRAME]).await.unwrap();
        tokio::time::sleep(INTERVAL).await;
    }
    ARMED.store(true, Ordering::Relaxed);

    let started = Instant::now();
    let write = tokio::spawn(async move {
        let mut tick = tokio::time::interval(INTERVAL);
        for index in 0..FRAMES {
            tick.tick().await;
            let mut frame = [0u8; FRAME];
            frame[..4].copy_from_slice(&(index as u32).to_be_bytes());
            let sent = started.elapsed().as_micros() as u64;
            frame[4..8].copy_from_slice(&(sent as u32).to_be_bytes());
            writer.write_all(&frame).await.unwrap();
        }
        writer
    });
    let mut rtts = Vec::new();
    let mut gaps = Vec::new();
    let mut last: Option<Instant> = None;
    let mut buffer = [0u8; FRAME];
    for _ in 0..FRAMES {
        tokio::time::timeout(Duration::from_secs(30), reader.read_exact(&mut buffer))
            .await
            .expect("echo within 30 s")
            .expect("read");
        let now = Instant::now();
        let sent = u32::from_be_bytes(buffer[4..8].try_into().unwrap());
        let elapsed = started.elapsed().as_micros() as u32;
        rtts.push(f64::from(elapsed.wrapping_sub(sent)) / 1000.0);
        if let Some(last) = last {
            gaps.push((now - last).as_secs_f64() * 1000.0);
        }
        last = Some(now);
    }
    let _ = write.await;
    let stats = (client.ultra_stats(), server.ultra_stats());
    eprintln!(
        "  dropped {} datagrams; client {:?}; server {:?}",
        DROPPED.load(Ordering::Relaxed),
        stats.0,
        stats.1
    );
    client.shutdown().await;
    server.shutdown().await;
    rtts.sort_by(f64::total_cmp);
    let at = |q: f64| rtts[((rtts.len() as f64 * q) as usize).min(rtts.len() - 1)];
    Result {
        p50: at(0.5),
        p99: at(0.99),
        max: *rtts.last().unwrap(),
        max_gap: gaps.iter().copied().fold(0.0, f64::max),
        gaps_over_200: gaps.iter().filter(|gap| **gap > 200.0).count(),
    }
}

#[tokio::test(start_paused = true)]
async fn echo_at_80ms_and_one_percent_loss() {
    let cases: [(&str, UltraChoice); 4] = [
        ("off", UltraChoice::Off),
        ("auto (metered)", UltraChoice::Auto { metered: Some(&METERED) }),
        ("auto", UltraChoice::AUTO),
        ("always", UltraChoice::ALWAYS),
    ];
    let only = std::env::var("ECHO_CASE").ok();
    for (name, choice) in cases {
        if only.as_deref().is_some_and(|only| !name.starts_with(only)) {
            continue;
        }
        let (mut p50, mut p99) = (Vec::new(), Vec::new());
        let (mut max, mut gaps, mut over) = (0f64, 0f64, 0);
        for seed in 1..=6 {
            let r = run(choice, seed * 7919).await;
            p50.push(r.p50);
            p99.push(r.p99);
            max = max.max(r.max);
            gaps = gaps.max(r.max_gap);
            over += r.gaps_over_200;
        }
        eprintln!(
            "{name:16} echo p50 per seed {:?} ms; p99 per seed {:?} ms; worst echo {max:.0} ms; longest gap {gaps:.0} ms; gaps over 200 ms: {over} of 6 runs (target p99 {:.0})",
            p50.iter().map(|p| p.round()).collect::<Vec<_>>(),
            p99.iter().map(|p| p.round()).collect::<Vec<_>>(),
            RTT_MS + 50.0
        );
        if name.starts_with("auto") {
            // The Auto floor: no loss was seen yet, and the echo still holds RTT+50.
            assert!(p99.iter().all(|p| *p <= RTT_MS + 50.0), "{name}: p99 {p99:?} over RTT+50");
        }
    }
}
