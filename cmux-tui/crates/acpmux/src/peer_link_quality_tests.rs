//! A slow link is slow, not dead (`peer_link_quality.rs`): the real link loop (`Peer::serve`)
//! over an emulated network, on the runtime's paused clock. The network between the two ends
//! delays each write by half a round trip with jitter, and models TCP under loss: a lost
//! segment arrives one retransmission timeout later (doubled each time it is lost again), and
//! nothing behind it arrives before it (head-of-line blocking).
//!
//! `cargo test -p acpmux --lib link_quality_tests -- --nocapture` prints the before and after
//! table the PR quotes.

use super::*;
use std::sync::atomic::AtomicBool;
use tokio::io::{AsyncReadExt, AsyncWriteExt, DuplexStream};
use tokio::time::Instant;
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::protocol::Role;

/// One emulated network: round trip, jitter (a share of it), loss per segment, and a switch
/// that drops everything (a dead link).
#[derive(Clone)]
struct Net {
    rtt: Duration,
    jitter: f64,
    loss: f64,
    dead: Arc<AtomicBool>,
    seed: u64,
}

/// xorshift64*: deterministic, so a run gives the same numbers every time.
struct Rng(u64);

impl Rng {
    fn unit(&mut self) -> f64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        (self.0.wrapping_mul(0x2545_F491_4F6C_DD1D) >> 11) as f64 / (1u64 << 53) as f64
    }
}

impl Net {
    fn new(rtt_ms: u64, loss: f64, seed: u64) -> Self {
        Self {
            rtt: Duration::from_millis(rtt_ms),
            jitter: 0.10,
            loss,
            dead: Arc::new(AtomicBool::new(false)),
            seed,
        }
    }

    /// TCP's retransmission timeout on this path: Linux's 200 ms floor, else the round trip
    /// plus four deviations (the jitter, as a mean deviation about half its span).
    fn tcp_rto(&self) -> Duration {
        let var = self.rtt.mul_f64(self.jitter / 2.0);
        (self.rtt + var * 4).max(Duration::from_millis(200))
    }

    /// Copies `from` to `to` one way, each write delayed as the network would.
    fn pipe<R, W>(&self, mut from: R, mut to: W, seed: u64)
    where
        R: tokio::io::AsyncRead + Unpin + Send + 'static,
        W: tokio::io::AsyncWrite + Unpin + Send + 'static,
    {
        let (tx, mut rx) = mpsc::unbounded_channel::<(Instant, Vec<u8>)>();
        let net = self.clone();
        tokio::spawn(async move {
            let mut rng = Rng(seed | 1);
            let mut last = Instant::now();
            let mut buf = vec![0u8; 1 << 16];
            loop {
                let n = match from.read(&mut buf).await {
                    Ok(0) | Err(_) => return,
                    Ok(n) => n,
                };
                if net.dead.load(Ordering::SeqCst) {
                    continue;
                }
                let half = net.rtt / 2;
                let mut delay = half.mul_f64(1.0 + net.jitter * (rng.unit() * 2.0 - 1.0));
                let mut rto = net.tcp_rto();
                while rng.unit() < net.loss {
                    delay += rto;
                    rto *= 2;
                }
                // In order: nothing overtakes a segment still being retransmitted.
                last = last.max(Instant::now() + delay);
                if tx.send((last, buf[..n].to_vec())).is_err() {
                    return;
                }
            }
        });
        let dead = self.dead.clone();
        tokio::spawn(async move {
            while let Some((at, bytes)) = rx.recv().await {
                tokio::time::sleep_until(at).await;
                if dead.load(Ordering::SeqCst) {
                    continue;
                }
                if to.write_all(&bytes).await.is_err() {
                    return;
                }
            }
        });
    }

    /// A WebSocket pair across this network: the client end, and a peer that reads every frame
    /// (which answers each ping) and says nothing else.
    async fn link(&self, n: u64) -> (WebSocketStream<DuplexStream>, tokio::task::JoinHandle<()>) {
        use futures_util::StreamExt;
        let (ours, near) = tokio::io::duplex(1 << 20);
        let (far, theirs) = tokio::io::duplex(1 << 20);
        let (near_r, near_w) = tokio::io::split(near);
        let (far_r, far_w) = tokio::io::split(far);
        self.pipe(near_r, far_w, self.seed ^ (n * 2 + 1).wrapping_mul(0x9E37_79B9));
        self.pipe(far_r, near_w, self.seed ^ (n * 2 + 2).wrapping_mul(0x9E37_79B9));
        let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
        let mut server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
        let answering = tokio::spawn(async move { while server.next().await.is_some() {} });
        (client, answering)
    }
}

/// What one run of the link loop over a [`Net`] saw.
#[derive(Debug, Default)]
struct Run {
    /// Links dropped while the network still carried every byte, late or not.
    false_downs: u32,
    /// Links dialed again after a drop (each drop redials here: the dial itself always opens).
    redials: u32,
    /// From the network going dead to the link dropping.
    found_dead_in: Option<Duration>,
    /// The tier shown at the end (before the network died, when it did).
    tier: Option<crate::peer_link_quality::Tier>,
}

/// Runs links to one peer over `net` for `run_for` (paused time), redialing each drop after the
/// backoff's first step and a round trip of dial, with a request out every `request_every` (a
/// person typing or chatting). With `dead_at`, the network stops carrying anything then, and
/// the run ends when the link drops.
async fn run(
    net: &Net,
    adaptive: bool,
    run_for: Duration,
    request_every: Option<Duration>,
    dead_at: Option<Duration>,
) -> Run {
    let (tx, _notices) = mpsc::channel(1024);
    let mut peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
    {
        let timings = &mut Arc::get_mut(&mut peer).expect("only this test holds it").timings;
        // No handshake here: the stand-in only answers pings.
        timings.handshake = Duration::from_secs(3_600);
        timings.rtt_adaptive = adaptive;
    }
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let start = Instant::now();
    let end = start + run_for;
    let requests = request_every.map(|every| {
        let peer = peer.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval_at(Instant::now() + every, every);
            loop {
                tick.tick().await;
                let line = "{}".to_owned();
                let _ = peer.out.try_send(Outbound { epoch: peer.link_epoch(), key: None, line });
            }
        })
    });
    let killed = dead_at.map(|at| {
        let dead = net.dead.clone();
        tokio::spawn(async move {
            tokio::time::sleep(at).await;
            dead.store(true, Ordering::SeqCst);
            Instant::now()
        })
    });
    let mut out = Run::default();
    let mut n = 0;
    loop {
        let (client, answering) = net.link(n).await;
        n += 1;
        let served = tokio::time::timeout_at(end, peer.serve(client, &mut out_rx)).await;
        answering.abort();
        let Ok(served) = served else { break };
        assert!(served.is_err(), "only a drop ends a link here: {served:?}");
        if net.dead.load(Ordering::SeqCst) {
            let killed = killed.expect("dead only when killed").await.unwrap();
            out.found_dead_in = Some(killed.elapsed());
            break;
        }
        out.tier = peer.with_quality(|q| q.tier());
        out.false_downs += 1;
        out.redials += 1;
        tokio::time::sleep(Backoff::BASE + net.rtt * 2).await;
    }
    if out.found_dead_in.is_none() {
        out.tier = peer.with_quality(|q| q.tier());
    }
    if let Some(requests) = requests {
        requests.abort();
    }
    out
}

/// One person's request every 5 s: typing into a chat, a prompt, a list read.
const REQUEST_EVERY: Duration = Duration::from_secs(5);
/// Virtual time each link runs for its false-drop count.
const RUN_FOR: Duration = Duration::from_secs(5 * 60);

/// The numbers: links at 20, 150, 400 and 800 ms with 10 % jitter and 0, 2 and 5 % loss, five
/// minutes each, before (fixed 2 s probe, fixed 6 s silence floor) and after (both scaled to
/// the measured round trip). Then each network dies after a minute: how long until the link
/// is let go, with requests going out and with none.
#[tokio::test(start_paused = true)]
async fn a_slow_link_is_not_dropped_and_a_dead_one_is_still_found() {
    let minutes = RUN_FOR.as_secs_f64() / 60.0;
    println!(
        "| RTT | loss | false downs/min before | after | redials before | after | dead found, requests (s) before | after | dead found, idle (s) before | after | tier |"
    );
    println!("|---|---|---|---|---|---|---|---|---|---|---|");
    let mut seed = 7u64;
    for rtt in [20u64, 150, 400, 800] {
        for loss in [0.0, 0.02, 0.05] {
            seed += 1;
            let mut row = Vec::new();
            for adaptive in [false, true] {
                let net = Net::new(rtt, loss, seed);
                let steady = run(&net, adaptive, RUN_FOR, Some(REQUEST_EVERY), None).await;
                let net = Net::new(rtt, loss, seed);
                let busy = run(
                    &net,
                    adaptive,
                    Duration::from_secs(3_600),
                    Some(REQUEST_EVERY),
                    Some(Duration::from_secs(60)),
                )
                .await;
                let net = Net::new(rtt, loss, seed);
                let idle = run(
                    &net,
                    adaptive,
                    Duration::from_secs(3_600),
                    None,
                    Some(Duration::from_secs(60)),
                )
                .await;
                row.push((steady, busy, idle));
            }
            let (before, after) = (&row[0], &row[1]);
            let secs = |r: &Run| {
                r.found_dead_in.map_or("-".to_owned(), |d| format!("{:.1}", d.as_secs_f64()))
            };
            println!(
                "| {rtt} ms | {:.0} % | {:.2} | {:.2} | {} | {} | {} | {} | {} | {} | {} |",
                loss * 100.0,
                f64::from(before.0.false_downs) / minutes,
                f64::from(after.0.false_downs) / minutes,
                before.0.redials,
                after.0.redials,
                secs(&before.1),
                secs(&after.1),
                secs(&before.2),
                secs(&after.2),
                after.0.tier.map_or("-", crate::peer_link_quality::Tier::as_str),
            );
            // A dead link is still found within the stated bound: the silence floor's 12 s
            // ceiling plus one ping interval, and within today's 8 s when the link is under
            // about 700 ms.
            let bound = if rtt < 700 { Duration::from_secs(8) } else { Duration::from_secs(14) };
            for found in [&after.1, &after.2] {
                let found = found.found_dead_in.expect("a dead link is found");
                assert!(found <= bound, "{rtt} ms, {loss}: {found:?}");
            }
            assert!(after.0.false_downs <= before.0.false_downs, "{rtt} ms, {loss}");
        }
    }
}
