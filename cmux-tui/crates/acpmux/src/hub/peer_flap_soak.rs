//! Linux soak harness for the peer-list flap path.
//!
//! This is deliberately an ignored test: it runs the same finite workload on
//! a before and after revision, then prints the watcher-event and resource
//! deltas for the PR's Performance table.  Set `ACPMUX_PEER_FLAP_SOAK_SECS`
//! and `ACPMUX_PEER_FLAP_INTERVAL_SECS` for a short smoke run.

use super::*;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::peer::{Peer, PeerNotice};
    use serde_json::{Value, json};
    use std::path::Path;
    use std::sync::Arc;
    use std::time::Duration;

    const PEERS: usize = 30;
    const ROWS_PER_PEER: usize = 20;

    #[derive(Debug)]
    struct Sample {
        flaps: usize,
        events: u64,
        events_per_flap: Vec<u64>,
        cpu_seconds: f64,
        peak_rss_mb: u64,
    }

    fn env_secs(key: &str, default: u64) -> u64 {
        std::env::var(key)
            .ok()
            .and_then(|v| v.parse().ok())
            .filter(|v: &u64| *v > 0)
            .unwrap_or(default)
    }

    fn rss_mb() -> u64 {
        std::fs::read_to_string("/proc/self/status")
            .ok()
            .and_then(|text| {
                text.lines().find_map(|line| {
                    line.strip_prefix("VmRSS:")?.split_whitespace().next()?.parse::<u64>().ok()
                })
            })
            .unwrap_or(0)
            / 1024
    }

    fn cpu_seconds() -> f64 {
        // `timeval`'s field types differ between glibc and musl; keep the
        // conversion explicit so the harness builds on either Linux pool.
        let mut usage = std::mem::MaybeUninit::<libc::rusage>::zeroed();
        // SAFETY: getrusage fully initializes the supplied rusage structure.
        let ok = unsafe { libc::getrusage(libc::RUSAGE_SELF, usage.as_mut_ptr()) } == 0;
        if !ok {
            return 0.0;
        }
        // SAFETY: getrusage returned success above.
        let usage = unsafe { usage.assume_init() };
        let user_seconds: f64 = usage.ru_utime.tv_sec as _;
        let user_micros: f64 = usage.ru_utime.tv_usec as _;
        let system_seconds: f64 = usage.ru_stime.tv_sec as _;
        let system_micros: f64 = usage.ru_stime.tv_usec as _;
        user_seconds + user_micros / 1_000_000.0 + system_seconds + system_micros / 1_000_000.0
    }

    fn row(peer: usize, session: usize) -> Value {
        json!({
            "sessionId": format!("s{session}"),
            "name": format!("lane-{peer}-{session}"),
            "status": if session.is_multiple_of(2) { "closed" } else { "running" },
            "createdAt": 1,
            "updatedAt": 1
        })
    }

    fn setup() -> Arc<Hub> {
        let mut cfg = Config::default();
        cfg.store.mode = crate::config::StoreMode::Memory;
        Hub::new(cfg.clone(), crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap())
    }

    async fn sample() -> Sample {
        let hub = setup();
        let mut watcher = hub.events.subscribe();
        let mut peers = Vec::with_capacity(PEERS);
        for peer_no in 0..PEERS {
            let name = format!("flap-{peer_no}");
            let peer = Peer::new(&name, "ws://127.0.0.1:9", None, None, hub.peer_notices.clone());
            let generation = peer.generation;
            hub.peers.lock().unwrap().insert(name.clone(), peer.clone());
            let rows = (0..ROWS_PER_PEER).map(|s| row(peer_no, s)).collect();
            hub.apply_peer_notice(&name, generation, PeerNotice::Sessions(rows));
            peers.push((name, generation, peer));
        }
        // Drop setup announcements before measuring flaps.
        while watcher.try_recv().is_ok() {}
        let start_cpu = cpu_seconds();
        let mut peak = rss_mb();
        let flap_secs = env_secs("ACPMUX_PEER_FLAP_INTERVAL_SECS", 17 * 60);
        let duration_secs = env_secs("ACPMUX_PEER_FLAP_SOAK_SECS", 60 * 60);
        let flaps = (duration_secs / flap_secs) as usize;
        let mut events_per_flap = Vec::with_capacity(flaps);
        let mut total_events = 0;
        let return_after = Duration::from_secs(env_secs("ACPMUX_PEER_RETURN_SECS", 1));
        let started = tokio::time::Instant::now();
        let deadline = started + Duration::from_secs(duration_secs);
        for flap in 0..flaps {
            tokio::time::sleep_until(started + Duration::from_secs(flap_secs * (flap as u64 + 1)))
                .await;
            let mut settled = peers.iter().map(|(_, _, p)| p.settled()).collect::<Vec<_>>();
            for (name, generation, _) in &peers {
                hub.peer_notices
                    .send((name.clone(), *generation, PeerNotice::Disconnected("soak flap".into())))
                    .await
                    .unwrap();
            }
            for rx in &mut settled {
                rx.changed().await.unwrap();
            }
            peak = peak.max(rss_mb());
            tokio::time::sleep(return_after).await;
            for (peer_no, (name, generation, _)) in peers.iter().enumerate() {
                let rows = (0..ROWS_PER_PEER).map(|s| row(peer_no, s)).collect();
                hub.peer_notices
                    .send((name.clone(), *generation, PeerNotice::Sessions(rows)))
                    .await
                    .unwrap();
                hub.peer_notices
                    .send((name.clone(), *generation, PeerNotice::Connected))
                    .await
                    .unwrap();
            }
            for rx in &mut settled {
                rx.changed().await.unwrap();
            }
            // Simulate a watcher that keeps up with the stream while retaining
            // event counts; lag is itself a useful soak signal and is counted.
            let mut count = 0;
            loop {
                match watcher.try_recv() {
                    Ok(_) => count += 1,
                    Err(tokio::sync::broadcast::error::TryRecvError::Empty) => break,
                    Err(tokio::sync::broadcast::error::TryRecvError::Lagged(n)) => count += n,
                    Err(tokio::sync::broadcast::error::TryRecvError::Closed) => break,
                }
            }
            events_per_flap.push(count);
            total_events += count;
            peak = peak.max(rss_mb());
        }
        // Keep the process alive until the configured one-hour window even if
        // processing the final flap took longer than its return delay.
        tokio::time::sleep_until(deadline).await;
        let mut events = 0;
        loop {
            match watcher.try_recv() {
                Ok(_) => events += 1,
                Err(tokio::sync::broadcast::error::TryRecvError::Empty) => break,
                Err(tokio::sync::broadcast::error::TryRecvError::Lagged(n)) => events += n,
                Err(tokio::sync::broadcast::error::TryRecvError::Closed) => break,
            }
        }
        total_events += events;
        Sample {
            flaps,
            events: total_events,
            events_per_flap,
            cpu_seconds: cpu_seconds() - start_cpu,
            peak_rss_mb: peak,
        }
    }

    #[tokio::test]
    #[ignore = "one-hour Linux soak; run explicitly on before and after revisions"]
    async fn flapping_peers_soak_reports_watcher_events_cpu_and_rss() {
        let sample = sample().await;
        eprintln!(
            "peer-flap-soak flaps={} events={} events_per_flap={:?} cpu_seconds={:.3} peak_rss_mb={}",
            sample.flaps,
            sample.events,
            sample.events_per_flap,
            sample.cpu_seconds,
            sample.peak_rss_mb
        );
        assert!(sample.flaps > 0, "set ACPMUX_PEER_FLAP_SOAK_SECS above interval");
    }
}
