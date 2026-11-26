//! A reconnect after the live path dies, timed: the before/after bench for Braid slice B3
//! (RFD 0164, the standby pool from race losers). One run is one first dial and one reconnect,
//! in a fresh process (an empty last-good memory and pool, as a first attach has):
//! 1. dial `HOST PORT` with `connect_tcp`, timed;
//! 2. wait 1.5 s, long enough for the race's slower loser to connect and be kept;
//! 3. black-hole the winner's address family here (`iptables`/`ip6tables` OUTPUT DROP to PORT),
//!    drop the live socket, and dial again, timed; then lift the black hole.
//!
//! `CMUX_BRAID_STANDBY=0` is the before arm. Prints one JSON line. Run it as root inside the
//! netns rig `crates/cmux-braid-path/bench/netns-standby.sh`, never on a person's machine.

use std::process::Command;
use std::time::{Duration, Instant};

use cmux_remote::provider::hedge::{HedgePolicy, connect_tcp};

fn black_hole(v6: bool, port: u16, on: bool) -> std::io::Result<()> {
    let tool = if v6 { "ip6tables" } else { "iptables" };
    let port = port.to_string();
    let action = if on { "-A" } else { "-D" };
    let status = Command::new(tool)
        .args([action, "OUTPUT", "-p", "tcp", "--dport", &port, "-j", "DROP"])
        .status()?;
    if status.success() { Ok(()) } else { Err(std::io::Error::other(format!("{tool} failed"))) }
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> std::io::Result<()> {
    let mut args = std::env::args().skip(1);
    let host = args.next().unwrap_or_else(|| "braid-peer".to_owned());
    let port: u16 = args.next().and_then(|p| p.parse().ok()).unwrap_or(7443);
    let budget = Duration::from_secs(10);
    let addresses: Vec<_> = tokio::net::lookup_host((host.as_str(), port)).await?.collect();
    let began = Instant::now();
    let live =
        tokio::time::timeout(budget, connect_tcp(&host, port, &addresses, HedgePolicy::INTERNET))
            .await
            .map_err(|_| std::io::Error::new(std::io::ErrorKind::TimedOut, "10 s budget"))??;
    let first = began.elapsed();
    let first_via = live.peer_addr()?;
    tokio::time::sleep(Duration::from_millis(1500)).await;
    black_hole(first_via.is_ipv6(), port, true)?;
    drop(live);
    let began = Instant::now();
    let again =
        tokio::time::timeout(budget, connect_tcp(&host, port, &addresses, HedgePolicy::INTERNET))
            .await;
    let reconnect = began.elapsed();
    black_hole(first_via.is_ipv6(), port, false)?;
    let (ok, via) = match again {
        Ok(Ok(stream)) => (true, stream.peer_addr().map(|a| a.to_string()).unwrap_or_default()),
        _ => (false, String::new()),
    };
    let standby = std::env::var("CMUX_BRAID_STANDBY").map_or(true, |v| v.trim() != "0");
    println!(
        "{{\"standby\":{standby},\"first_ms\":{:.1},\"first_via\":\"{first_via}\",\"reconnect_ok\":{ok},\"reconnect_ms\":{:.1},\"reconnect_via\":\"{via}\"}}",
        first.as_secs_f64() * 1000.0,
        reconnect.as_secs_f64() * 1000.0
    );
    Ok(())
}
