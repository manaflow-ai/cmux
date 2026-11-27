//! Sequential hedged TCP dials to one host, timed: the before/after bench for Braid slice B1
//! (RFD 0164). `CMUX_BRAID_LAST_GOOD=0` is the before arm (no last-good route).
//!
//! `cargo run -p cmux-remote --example braid_dial_bench -- HOST PORT [N]`; prints one line per
//! dial and a JSON summary. Run it inside the netns rig in
//! `crates/cmux-braid-path/bench/netns-dial.sh`, never against a person's network.

use std::time::{Duration, Instant};

use cmux_remote::provider::hedge::{HedgePolicy, connect_tcp};

#[tokio::main(flavor = "current_thread")]
async fn main() -> std::io::Result<()> {
    let mut args = std::env::args().skip(1);
    let host = args.next().unwrap_or_else(|| "braid-peer".to_owned());
    let port: u16 = args.next().and_then(|p| p.parse().ok()).unwrap_or(7443);
    let n: usize = args.next().and_then(|p| p.parse().ok()).unwrap_or(20);
    let mut times = Vec::with_capacity(n);
    for i in 0..n {
        let addresses: Vec<_> = tokio::net::lookup_host((host.as_str(), port)).await?.collect();
        let began = Instant::now();
        let stream = tokio::time::timeout(
            Duration::from_secs(10),
            connect_tcp(&host, port, &addresses, HedgePolicy::INTERNET),
        )
        .await
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::TimedOut, "10 s budget"))??;
        let took = began.elapsed();
        let peer = stream.peer_addr()?;
        drop(stream);
        println!("dial {i}: {:.1} ms via {peer}", took.as_secs_f64() * 1000.0);
        times.push(took);
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    times.sort();
    let at = |percent: usize| {
        let index = ((times.len() - 1) * percent + 50) / 100;
        times[index.min(times.len() - 1)].as_secs_f64() * 1000.0
    };
    let total: Duration = times.iter().sum();
    let mean =
        total.as_secs_f64() * 1000.0 / f64::from(u32::try_from(times.len()).unwrap_or(u32::MAX));
    let last_good = std::env::var("CMUX_BRAID_LAST_GOOD").map_or(true, |v| v.trim() != "0");
    println!(
        "{{\"last_good\":{last_good},\"n\":{n},\"p50_ms\":{:.1},\"p95_ms\":{:.1},\"max_ms\":{:.1},\"mean_ms\":{mean:.1}}}",
        at(50),
        at(95),
        at(100)
    );
    Ok(())
}
