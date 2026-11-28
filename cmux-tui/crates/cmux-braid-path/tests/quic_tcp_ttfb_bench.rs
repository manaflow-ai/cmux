//! ask-26e17175d2: time to first byte of a QUIC-then-TCP fallback against racing the two with
//! [`race`] and with the per-network winner memory ([`race_remembered`]), on real loopback
//! sockets. Each leg's server answers the first byte after the round trips its protocol needs at
//! `RTT`: the QUIC leg (UDP) after 2 (1-RTT handshake, then the request), the TCP leg after 3
//! (TCP handshake, TLS 1.3, then the request). On the UDP-blocked network the UDP server drops
//! every datagram. The fallback is the same racer with one attempt in flight: QUIC alone until
//! its handshake timeout, then TCP.
//!
//! `cargo test -p cmux-braid-path --release --test quic_tcp_ttfb_bench -- --ignored --nocapture`
//! (`TTFB_BENCH_N`, default 200 connects per row; `TTFB_BENCH_RTT_MS`, default 30).

use std::io;
use std::net::SocketAddr;
use std::time::{Duration, Instant};

use cmux_braid_path::{Fingerprint, LastGood, RacePolicy, race, race_remembered};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream, UdpSocket};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
enum Leg {
    Quic(SocketAddr),
    Tcp(SocketAddr),
}

impl Leg {
    fn name(self) -> &'static str {
        match self {
            Leg::Quic(_) => "quic",
            Leg::Tcp(_) => "tcp",
        }
    }
}

impl cmux_braid_path::Leg for Leg {
    fn leg(&self) -> String {
        self.name().to_string()
    }
}

/// QUIC's handshake timeout before a fallback gives up on UDP (Chromium waits on the order of
/// its 300 to 500 ms alternate-job delay; 400 ms is the figure #57195's duress run used).
const QUIC_GIVE_UP: Duration = Duration::from_millis(400);

async fn udp_server(rtt: Duration, blocked: bool) -> SocketAddr {
    let socket = std::sync::Arc::new(UdpSocket::bind("127.0.0.1:0").await.unwrap());
    let addr = socket.local_addr().unwrap();
    tokio::spawn(async move {
        let mut buf = [0u8; 64];
        loop {
            let Ok((_, from)) = socket.recv_from(&mut buf).await else { return };
            if blocked {
                continue;
            }
            let socket = socket.clone();
            tokio::spawn(async move {
                tokio::time::sleep(rtt * 2).await;
                let _ = socket.send_to(b"b", from).await;
            });
        }
    });
    addr
}

async fn tcp_server(rtt: Duration) -> SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        loop {
            let Ok((mut stream, _)) = listener.accept().await else { return };
            tokio::spawn(async move {
                let mut b = [0u8; 1];
                if stream.read_exact(&mut b).await.is_err() {
                    return;
                }
                // The accept above is already the kernel's handshake on loopback: wait all 3
                // round trips here so the leg costs what TCP + TLS 1.3 + request cost at `rtt`.
                tokio::time::sleep(rtt * 3).await;
                let _ = stream.write_all(b"b").await;
            });
        }
    });
    addr
}

async fn first_byte(leg: Leg) -> io::Result<Leg> {
    match leg {
        Leg::Quic(addr) => {
            let socket = UdpSocket::bind("127.0.0.1:0").await?;
            socket.connect(addr).await?;
            socket.send(b"p").await?;
            let mut b = [0u8; 1];
            socket.recv(&mut b).await?;
        }
        Leg::Tcp(addr) => {
            let mut stream = TcpStream::connect(addr).await?;
            stream.set_nodelay(true)?;
            stream.write_all(b"p").await?;
            let mut b = [0u8; 1];
            stream.read_exact(&mut b).await?;
        }
    }
    Ok(leg)
}

fn policy(stagger: Duration, in_flight: usize) -> RacePolicy {
    RacePolicy {
        stagger,
        attempt_timeout: QUIC_GIVE_UP,
        last_attempt_timeout: Duration::from_secs(5),
        max_in_flight: in_flight,
        max_attempts: 2,
    }
}

#[derive(Clone, Copy)]
enum Mode {
    Fallback,
    RaceTogether,
    RaceStagger50,
    RaceCachedCold,
    RaceCachedWarm,
}

impl Mode {
    fn name(self) -> &'static str {
        match self {
            Mode::Fallback => "quic-then-tcp fallback",
            Mode::RaceTogether => "race, both at once",
            Mode::RaceStagger50 => "race, tcp 50 ms after quic",
            Mode::RaceCachedCold => "race + per-network cache, cold",
            Mode::RaceCachedWarm => "race + per-network cache, warm",
        }
    }
}

async fn row(network: &str, mode: Mode, legs: [Leg; 2], n: usize) {
    let key = Fingerprint::of(Some(std::net::Ipv4Addr::new(192, 0, 2, 7)), None);
    let warm: LastGood<Option<Fingerprint>, Leg> = LastGood::new(Duration::from_secs(3600));
    let mut ms = Vec::with_capacity(n);
    let mut wins = std::collections::BTreeMap::<&str, usize>::new();
    for _ in 0..n {
        let started = Instant::now();
        let won = match mode {
            Mode::Fallback => {
                race(&legs, policy(Duration::from_secs(3600), 1), first_byte).await.map(|w| w.value)
            }
            Mode::RaceTogether => {
                race(&legs, policy(Duration::ZERO, 2), first_byte).await.map(|w| w.value)
            }
            Mode::RaceStagger50 => {
                race(&legs, policy(Duration::from_millis(50), 2), first_byte).await.map(|w| w.value)
            }
            Mode::RaceCachedCold | Mode::RaceCachedWarm => {
                let cold = LastGood::new(Duration::from_secs(3600));
                let memory = if matches!(mode, Mode::RaceCachedWarm) { &warm } else { &cold };
                let lead = memory.get(&key).map(|r| r.connect);
                let p = policy(Duration::from_millis(50), 2).with_lead(lead);
                race_remembered(memory, key, &legs, p, first_byte).await.map(|(leg, _)| leg)
            }
        };
        let elapsed = started.elapsed().as_secs_f64() * 1000.0;
        let leg = won.expect("every row has a leg that answers");
        ms.push(elapsed);
        *wins.entry(leg.name()).or_default() += 1;
    }
    ms.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let q = |p: f64| ms[((ms.len() as f64 - 1.0) * p).round() as usize];
    println!(
        "TTFB | {network} | {} | n={n} | p50={:.1}ms | p99={:.1}ms | wins={wins:?}",
        mode.name(),
        q(0.5),
        q(0.99),
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "bench: real sockets, a few minutes"]
async fn quic_tcp_ttfb_bench() {
    let env = |k: &str, d: u64| std::env::var(k).ok().and_then(|v| v.parse().ok()).unwrap_or(d);
    let n = env("TTFB_BENCH_N", 200) as usize;
    let rtt = Duration::from_millis(env("TTFB_BENCH_RTT_MS", 30));
    println!("TTFB bench: rtt={rtt:?} quic_give_up={QUIC_GIVE_UP:?} n={n}");
    let tcp = tcp_server(rtt).await;
    for (network, blocked) in [("normal", false), ("udp-blocked", true)] {
        let quic = udp_server(rtt, blocked).await;
        let legs = [Leg::Quic(quic), Leg::Tcp(tcp)];
        for mode in [
            Mode::Fallback,
            Mode::RaceTogether,
            Mode::RaceStagger50,
            Mode::RaceCachedCold,
            Mode::RaceCachedWarm,
        ] {
            row(network, mode, legs, n).await;
        }
    }
}
