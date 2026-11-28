// The crash ratchet keeps this crate at zero production panics.
#![cfg_attr(
    not(test),
    deny(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::panic,
        clippy::unreachable,
        clippy::todo,
        clippy::unimplemented,
        clippy::exit,
        clippy::indexing_slicing
    )
)]

use std::net::SocketAddr;
use std::time::Duration;

use anyhow::{Context, anyhow, bail};
use cmux_hop_relay::forward::Forwarder;
use cmux_hop_relay::server::{Pop, PopConfig, serve_health};
use cmux_hop_relay::ticket::{TicketAuthority, unix_now};

const HELP: &str = "\
cmux-hop-relay: hop/1 UDP relay PoP (docs/cmux-next/relay-pop-hop.md)

  cmux-hop-relay serve --bind ADDR (--secret-file F | --open) [--public-ip IP]
                       [--leg-rate-kbit N] [--lifetime-s N] [--health ADDR] [--stats-every-ms N]
      BIND allocations on ADDR; each gets a relayed UDP port on --public-ip (default ADDR's IP).
      --open takes any ticket (netlab only). --leg-rate-kbit drains the phone leg at N kbit/s
      (0: unlimited) so R5 coalescing engages under congestion. --health serves per-leg stats
      as JSON; --stats-every-ms logs one `hop-relay stats {json}` line per allocation.
  cmux-hop-relay ticket --secret-file F --session S [--ttl-s N]
  cmux-hop-relay forward --phone ADDR --mac ADDR
      Plain UDP forwarder (today's TURN data plane), the bench's BEFORE.
";

fn args() -> Vec<String> {
    std::env::args().skip(1).collect()
}

fn flag<'a>(args: &'a [String], name: &str) -> Option<&'a str> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).map(String::as_str)
}

fn parse<T: std::str::FromStr>(args: &[String], name: &str, default: T) -> anyhow::Result<T> {
    match flag(args, name) {
        None => Ok(default),
        Some(v) => v.parse().map_err(|_| anyhow!("bad value for {name}: {v}")),
    }
}

fn secret(args: &[String]) -> anyhow::Result<Vec<u8>> {
    let path = flag(args, "--secret-file").ok_or_else(|| anyhow!("--secret-file or --open"))?;
    let text = std::fs::read_to_string(path).with_context(|| format!("read {path}"))?;
    Ok(text.trim().as_bytes().to_vec())
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = args();
    match args.first().map(String::as_str) {
        Some("serve") => {
            let bind: SocketAddr = parse(&args, "--bind", "0.0.0.0:3479".parse()?)?;
            let authority = if args.iter().any(|a| a == "--open") {
                eprintln!("cmux-hop-relay: OPEN MODE (--open): any ticket binds; development only");
                TicketAuthority::open()
            } else {
                TicketAuthority::hmac(secret(&args)?)?
            };
            let config = PopConfig {
                bind,
                public_ip: parse(&args, "--public-ip", bind.ip())?,
                authority,
                leg_rate_kbit: parse(&args, "--leg-rate-kbit", 0)?,
                lifetime: Duration::from_secs(parse(&args, "--lifetime-s", 600)?),
                max_allocations: parse(&args, "--max-allocations", 4096)?,
                stats_every: Duration::from_millis(parse(&args, "--stats-every-ms", 0)?),
            };
            let pop = Pop::bind(config.clone()).await.with_context(|| format!("bind {bind}"))?;
            let health_scope = cmux_scope::Scope::new("cmux-hop-relay main");
            if let Some(health) = flag(&args, "--health") {
                let listener = tokio::net::TcpListener::bind(health)
                    .await
                    .with_context(|| format!("bind {health}"))?;
                health_scope.spawn_until_cancelled(
                    "hop-relay health",
                    serve_health(listener, pop.reports()),
                );
            }
            eprintln!(
                "cmux-hop-relay listening on {} (relayed ports on {}, phone leg {} kbit/s)",
                pop.local_addr()?,
                config.public_ip,
                config.leg_rate_kbit
            );
            tokio::select! {
                r = pop.run() => r?,
                _ = tokio::signal::ctrl_c() => {}
            }
            Ok(())
        }
        Some("ticket") => {
            let authority = TicketAuthority::hmac(secret(&args)?)?;
            let session = flag(&args, "--session").ok_or_else(|| anyhow!("--session"))?;
            let ttl: u64 = parse(&args, "--ttl-s", 3600)?;
            println!("{}", authority.issue(session, unix_now()? + ttl)?);
            Ok(())
        }
        Some("forward") => {
            let phone: SocketAddr =
                flag(&args, "--phone").ok_or_else(|| anyhow!("--phone"))?.parse()?;
            let mac: SocketAddr = flag(&args, "--mac").ok_or_else(|| anyhow!("--mac"))?.parse()?;
            let f = Forwarder::bind(phone, mac).await?;
            eprintln!(
                "cmux-hop-relay forward: phone {} <-> mac {}",
                f.phone_addr()?,
                f.mac_addr()?
            );
            tokio::select! {
                r = f.run() => r?,
                _ = tokio::signal::ctrl_c() => {}
            }
            Ok(())
        }
        Some("help" | "--help" | "-h") | None => {
            print!("{HELP}");
            Ok(())
        }
        Some(other) => bail!("unknown command {other}\n{HELP}"),
    }
}
