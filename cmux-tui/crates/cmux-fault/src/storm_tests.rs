use super::Storm;
use crate::clock::WallClock;
use crate::disk::DiskFault;
use crate::load::{CpuLoad, RamLoad};
use crate::proxy::Proxy;
use crate::runs::Runs;
use crate::trace::Trace;
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::time::timeout;

/// A line echo server: the stand-in for any daemon a storm runs against.
async fn line_echo() -> std::net::SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        while let Ok((socket, _)) = listener.accept().await {
            tokio::spawn(async move {
                let (read, mut write) = socket.into_split();
                let mut lines = BufReader::new(read).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    if write.write_all(format!("{line}\n").as_bytes()).await.is_err() {
                        return;
                    }
                }
            });
        }
    });
    addr
}

/// One client connection and what it may legally hear: numbers it sent, in order, each once.
struct Conn {
    lines: tokio::io::Lines<BufReader<tokio::net::tcp::OwnedReadHalf>>,
    write: tokio::net::tcp::OwnedWriteHalf,
    sent: u64,
    heard: u64,
}

const STEP: Duration = Duration::from_millis(5);

/// One scenario step: (re)connect, send the next number, read what came back. Never blocks past
/// a few `STEP`s, whatever the storm did. A reply out of order, doubled or never sent breaks it.
async fn step(addr: std::net::SocketAddr, conn: &mut Option<Conn>) -> Result<(), String> {
    if conn.is_none() {
        let Ok(Ok(stream)) = timeout(STEP * 2, TcpStream::connect(addr)).await else {
            return Ok(());
        };
        let (read, write) = stream.into_split();
        *conn = Some(Conn { lines: BufReader::new(read).lines(), write, sent: 0, heard: 0 });
    }
    let Some(live) = conn.as_mut() else { return Ok(()) };
    let next = live.sent + 1;
    match timeout(STEP, live.write.write_all(format!("{next}\n").as_bytes())).await {
        Ok(Ok(())) => live.sent = next,
        Ok(Err(_)) => {
            *conn = None;
            return Ok(());
        }
        Err(_) => return Ok(()),
    }
    loop {
        match timeout(STEP, live.lines.next_line()).await {
            Err(_) => return Ok(()),
            Ok(Ok(Some(line))) => {
                let n: u64 = line.parse().map_err(|_| format!("garbled reply {line:?}"))?;
                if n != live.heard + 1 || n > live.sent {
                    return Err(format!(
                        "reply {n} after {} (sent {}): lost, doubled or reordered",
                        live.heard, live.sent
                    ));
                }
                live.heard = n;
            }
            Ok(_) => {
                *conn = None;
                return Ok(());
            }
        }
    }
}

/// Recovery once healed: a fresh connection echoes within 2 s.
async fn recovers(addr: std::net::SocketAddr) -> Result<Duration, String> {
    let started = Instant::now();
    let deadline = Duration::from_secs(2);
    while started.elapsed() < deadline {
        if let Ok(Ok(stream)) = timeout(Duration::from_millis(200), TcpStream::connect(addr)).await
        {
            let (read, mut write) = stream.into_split();
            let mut lines = BufReader::new(read).lines();
            if write.write_all(b"healed\n").await.is_ok()
                && let Ok(Ok(Some(line))) =
                    timeout(Duration::from_millis(500), lines.next_line()).await
                && line == "healed"
            {
                return Ok(started.elapsed());
            }
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    Err(format!("no echo {} ms after the storm healed", deadline.as_millis()))
}

/// The CPU load per core a storm run adds (`CMUX_FAULT_STORM_CPU_TIMES`, default 2; RFD 0124's
/// duress legs use 10).
fn cpu_times() -> usize {
    std::env::var("CMUX_FAULT_STORM_CPU_TIMES").ok().and_then(|n| n.parse().ok()).unwrap_or(2)
}

#[test]
fn a_storm_of_net_disk_cpu_ram_and_clock_faults_breaks_no_stream_and_heals()
-> Result<(), crate::Failed> {
    let ticks: u64 =
        std::env::var("CMUX_FAULT_STORM_TICKS").ok().and_then(|n| n.parse().ok()).unwrap_or(200);
    Runs::new(
        "storm line echo",
        "cargo test -p cmux-fault --lib a_storm_of_net_disk_cpu_ram_and_clock_faults",
    )
    // Each run loads every core; two at once is already well past the cores.
    .at_most_parallel(2)
    .run(|seed, trace| {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .map_err(|e| e.to_string())?;
        runtime.block_on(async {
            let dir = std::env::temp_dir().join(format!(
                "cmux-fault-storm-{}-{seed}-{}",
                std::process::id(),
                Instant::now().elapsed().as_nanos()
            ));
            std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
            let proxy = Proxy::start(line_echo().await, trace).await.map_err(|e| e.to_string())?;
            let disk = DiskFault::new(&dir, trace);
            let cpu = CpuLoad::cores_times(cpu_times(), trace);
            let mut ram = RamLoad::with_ceiling(64 << 20, trace);
            let clock = WallClock::new(trace);
            let addr = proxy.addr();
            let mut conn = None;
            let report = Storm::new(seed, trace)
                .proxy(&proxy)
                .disk(&disk)
                .cpu(&cpu)
                .ram(&mut ram)
                .clock(&clock)
                .run("line echo", ticks, Duration::from_millis(1), async |_| {
                    step(addr, &mut conn).await
                })
                .await?;
            let recovered = recovers(addr).await?;
            let spun = cpu.spins();
            drop(cpu);
            drop(disk);
            let _ = std::fs::remove_dir(&dir);
            for kind in ["net", "disk", "cpu", "ram", "clock"] {
                if report.flips.get(kind).copied().unwrap_or(0) == 0 {
                    return Err(format!("{kind} never moved in {ticks} ticks"));
                }
            }
            if spun == 0 {
                return Err("the cpu load never ran".into());
            }
            eprintln!("{} recovered_ms={}", report.duress_line("line echo"), recovered.as_millis());
            Ok(())
        })
    })
}

/// On a paused tokio clock a tick costs no real time: 10,000 ticks 10 s apart is 27.8 hours of
/// timers, plus a day of wall-clock jumps per tick at most, in well under a second of real time.
async fn day_storm(seed: u64) -> (super::Report, Duration) {
    let trace = Trace::new();
    let dir = std::env::temp_dir();
    let disk =
        DiskFault::new(&dir.join(format!("cmux-fault-day-{}-{seed}", std::process::id())), &trace);
    let clock = WallClock::new(&trace);
    let started = tokio::time::Instant::now();
    let report = Storm::new(seed, &trace)
        .clock(&clock)
        .run("day", 10_000, Duration::from_secs(10), async |tick| {
            // Monotonic time never jumps with the wall clock: tick N is at N x 10 s.
            let at = started.elapsed();
            if at == Duration::from_secs(tick * 10) {
                Ok(())
            } else {
                Err(format!("tick {tick} at {at:?}"))
            }
        })
        .await
        .unwrap();
    drop(disk);
    (report, started.elapsed())
}

#[tokio::test(start_paused = true)]
async fn a_paused_storm_ticks_a_day_in_moments_and_its_seed_replays_it() {
    let real = Instant::now();
    let (first, virtual_time) = day_storm(7).await;
    assert!(virtual_time >= Duration::from_secs(27 * 3600), "{virtual_time:?}");
    assert!(real.elapsed() < Duration::from_secs(10), "took {:?} real", real.elapsed());
    assert!(first.flips.get("clock").copied().unwrap_or(0) > 4_000, "{:?}", first.flips);
    let (again, _) = day_storm(7).await;
    assert_eq!(first.fingerprint, again.fingerprint, "a seed did not replay its storm");
    let (other, _) = day_storm(8).await;
    assert_ne!(first.fingerprint, other.fingerprint, "two seeds made one storm");
}
