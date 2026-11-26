//! An upload that runs past 60 s while the uploader's own receive window is
//! closed (cmux#57093). The phone uploads on a port with the 60 s user
//! timeout while the Mac's output to it piles up unread, so the phone's
//! receive window is zero for the whole upload. The Mac keeps acknowledging
//! the upload, so the connection must not be reset at 60 s.
//!
//! Before the vendored smoltcp patch, the phone dropped every Mac segment
//! past its closed window whole, ACK included: the upload stopped moving the
//! moment the window closed (3.5 MB of 40 MiB at about 15 s, nothing after)
//! and the Mac fell silent about 60 s later; the run never finished.
//!
//! LTE-shaped link: 36.5 ms each way (73 ms round trip) and a 550
//! datagram/s bottleneck (about 640 KB/s of payload, the rate the pair matrix
//! measured under lte duress). Paused clock: every duration is simulated.
//!
//! A measurement, not part of the default run:
//! `ZW_RUNS=12 cargo test -p cmux-wg --release --test zero_window_upload -- --ignored --nocapture`
//! prints one `ZW-ROW` line per run and a `ZW-SUMMARY` line.

use std::net::SocketAddr;
use std::time::Duration;

use cmux_wg::testing::config_pair;
use cmux_wg::testing::sim::{LinkProfile, SimNet};
use cmux_wg::{SocketPath, WgNet};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::time::Instant;

const CLIENT: &str = "192.0.2.110:51820";
const SERVER: &str = "192.0.2.111:51820";
/// A port with the ordinary 60 s user timeout, not the link port's 10 min.
const PORT: u16 = 7420;
/// What the Mac sends that the phone does not read during the upload: well
/// past every buffer between the socket and the app, so the window closes.
fn backlog_len() -> usize {
    std::env::var("ZW_BACKLOG").ok().and_then(|t| t.parse().ok()).unwrap_or(8 * 1024 * 1024)
}
const MIB: usize = 1024 * 1024;
/// A run that has not finished by then failed.
const LIMIT: Duration = Duration::from_secs(600);

fn addr(text: &str) -> SocketAddr {
    text.parse().expect("literal address")
}

fn lte() -> LinkProfile {
    LinkProfile {
        latency: Duration::from_micros(36_500),
        rate_pps: 550,
        queue: 64,
        ..LinkProfile::default()
    }
}

fn pattern(len: usize, salt: usize) -> Vec<u8> {
    (0..len).map(|index| ((index ^ salt).wrapping_mul(2_654_435_761) >> 13) as u8).collect()
}

/// One run: the phone uploads `upload` bytes while not reading the Mac's
/// backlog; then it reads the backlog. Ok is the simulated time to finish
/// both; Err says where it stopped.
async fn run(upload: usize) -> Result<Duration, String> {
    let sim = SimNet::new();
    sim.set_link(addr(CLIENT), addr(SERVER), lte());
    let configs = config_pair(addr(SERVER));
    let phone_path = SocketPath::new(sim.bind(addr(CLIENT)).unwrap(), Some(addr(SERVER)));
    let mac_path = SocketPath::new(sim.bind(addr(SERVER)).unwrap(), None);
    let phone = WgNet::start_with_underlay(configs.client, phone_path).unwrap();
    let mac = WgNet::start_with_underlay(configs.server, mac_path).unwrap();
    let mut listener = mac.listen(PORT).await.unwrap();
    let started = Instant::now();
    let dialed = phone.connect(SocketAddr::new(configs.server_v4, PORT)).await.unwrap();
    let accepted = listener.accept().await.unwrap();
    let (mut phone_read, mut phone_write) = tokio::io::split(dialed);
    let (mut mac_read, mut mac_write) = tokio::io::split(accepted);

    let sent = pattern(upload, 1);
    let backlog = pattern(backlog_len(), 2);
    let expected_backlog = backlog.clone();
    let expected_upload = sent.clone();

    let mac_out = tokio::spawn(async move {
        mac_write.write_all(&backlog).await.map_err(|error| format!("mac write: {error}"))
    });
    let moved = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let seen = moved.clone();
    let mac_in = tokio::spawn(async move {
        let mut received = vec![0u8; upload];
        let mut offset = 0;
        while offset < upload {
            match mac_read.read(&mut received[offset..]).await {
                Ok(0) => return Err(format!("upload ended at {offset} of {upload}")),
                Ok(count) => {
                    offset += count;
                    seen.store(offset, std::sync::atomic::Ordering::Relaxed);
                }
                Err(error) => return Err(format!("upload reset at {offset} of {upload}: {error}")),
            }
        }
        if received != expected_upload {
            return Err("upload arrived damaged".into());
        }
        Ok(())
    });

    let trace = std::env::var("ZW_TRACE").is_ok().then(|| {
        let sim = sim.clone();
        let seen = moved.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(5)).await;
                println!(
                    "ZW-TRACE t={:.0} uploaded={} phone_dgrams={} phone_bytes={} mac_dgrams={} mac_bytes={} dropped={}",
                    started.elapsed().as_secs_f64(),
                    seen.load(std::sync::atomic::Ordering::Relaxed),
                    sim.sent_from(addr(CLIENT)),
                    sim.sent_bytes_from(addr(CLIENT)),
                    sim.sent_from(addr(SERVER)),
                    sim.sent_bytes_from(addr(SERVER)),
                    sim.dropped(),
                );
            }
        })
    });
    let outcome = tokio::time::timeout(LIMIT, async {
        phone_write.write_all(&sent).await.map_err(|error| format!("phone write: {error}"))?;
        mac_in.await.map_err(|error| error.to_string())??;
        // Only now does the phone read what piled up.
        let mut got = vec![0u8; backlog_len()];
        phone_read.read_exact(&mut got).await.map_err(|error| format!("backlog read: {error}"))?;
        if got != expected_backlog {
            return Err("backlog arrived damaged".to_string());
        }
        mac_out.await.map_err(|error| error.to_string())??;
        Ok::<_, String>(started.elapsed())
    })
    .await
    .unwrap_or_else(|_| Err(format!("not finished in {LIMIT:?}")));
    if let Some(trace) = trace {
        trace.abort();
    }
    let failed_at = started.elapsed();
    phone.shutdown().await;
    mac.shutdown().await;
    let moved = moved.load(std::sync::atomic::Ordering::Relaxed);
    outcome.map_err(|error| {
        format!("{error} (at {:.1} s, {moved} of {upload} uploaded)", failed_at.as_secs_f64())
    })
}

#[tokio::test(start_paused = true)]
#[ignore = "measurement: run by hand, see the module comment"]
async fn an_upload_past_sixty_seconds_with_a_closed_window() {
    let runs: usize = std::env::var("ZW_RUNS").ok().and_then(|text| text.parse().ok()).unwrap_or(1);
    let mut failed = 0;
    let mut times = Vec::new();
    for index in 0..runs {
        // 40 to 51 MiB: each upload alone takes over 60 s on this link.
        let upload = (40 + index % 12) * MIB;
        match run(upload).await {
            Ok(elapsed) => {
                println!(
                    "ZW-ROW run={index} upload_mib={} ok secs={:.1}",
                    upload / MIB,
                    elapsed.as_secs_f64()
                );
                times.push(elapsed.as_secs_f64());
            }
            Err(error) => {
                println!("ZW-ROW run={index} upload_mib={} failed {error}", upload / MIB);
                failed += 1;
            }
        }
    }
    let range = if times.is_empty() {
        "-".to_string()
    } else {
        let low = times.iter().cloned().fold(f64::INFINITY, f64::min);
        let high = times.iter().cloned().fold(0.0, f64::max);
        format!("{low:.1}-{high:.1} s")
    };
    println!("ZW-SUMMARY failed={failed}/{runs} complete={range}");
    assert_eq!(failed, 0, "{failed} of {runs} uploads failed");
}
