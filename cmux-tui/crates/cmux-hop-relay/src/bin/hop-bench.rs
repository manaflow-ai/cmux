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
use std::path::PathBuf;
use std::time::Duration;

use anyhow::{anyhow, bail};
use cmux_hop_relay::bench::{
    MacConfig, Path, PhoneRun, TEST_ECHO, TEST_FRAMES, mac_serve, phone_handshake, phone_run,
    read_addr_file,
};
use serde_json::json;
use tokio::net::UdpSocket;

const HELP: &str = "\
hop-bench: phone and Mac ends for measuring a relay (cmux-hop-relay or a plain forwarder)

  hop-bench phone --mode plain|hop --relay ADDR [--ticket T] [--addr-file F]
                  --test echo|frames [--duration-s 20] [--interval-ms 100] [--label L]
      plain: send to the forwarder's phone port ADDR. hop: BIND on the PoP at ADDR and write the
      relayed address to --addr-file for the Mac end. Prints one JSON result line.
  hop-bench mac --mode plain|hop (--relay ADDR | --addr-file F) [--fps 60] [--frame-bytes 900]
                [--bulk-kbit 14000] [--bulk-bytes 1200]
      Serves until killed: echoes pings; on a frames START sends class-1 frames at --fps and bulk
      at --bulk-kbit beside them.
";

fn flag<'a>(args: &'a [String], name: &str) -> Option<&'a str> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).map(String::as_str)
}

fn parse<T: std::str::FromStr>(args: &[String], name: &str, default: T) -> anyhow::Result<T> {
    match flag(args, name) {
        None => Ok(default),
        Some(v) => v.parse().map_err(|_| anyhow!("bad value for {name}: {v}")),
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mode = flag(&args, "--mode").unwrap_or("hop");
    let hop = match mode {
        "hop" => true,
        "plain" => false,
        _ => bail!("--mode plain|hop"),
    };
    let sock = UdpSocket::bind("0.0.0.0:0").await?;
    match args.first().map(String::as_str) {
        Some("phone") => {
            let relay: SocketAddr =
                flag(&args, "--relay").ok_or_else(|| anyhow!("--relay"))?.parse()?;
            let mut path = if hop {
                let ticket = flag(&args, "--ticket").unwrap_or("hop-bench");
                let (path, relayed) = Path::bind(sock, relay, ticket.as_bytes()).await?;
                if let Some(file) = flag(&args, "--addr-file") {
                    let tmp = format!("{file}.tmp");
                    std::fs::write(&tmp, relayed.to_string())?;
                    std::fs::rename(&tmp, file)?;
                }
                eprintln!("hop-bench phone: bound, relayed {relayed}");
                path
            } else {
                Path::plain(sock, relay)
            };
            let test = match flag(&args, "--test").unwrap_or("echo") {
                "echo" => TEST_ECHO,
                "frames" => TEST_FRAMES,
                t => bail!("--test echo|frames, not {t}"),
            };
            phone_handshake(&mut path, Duration::from_secs(30)).await?;
            let run = PhoneRun {
                test,
                duration: Duration::from_secs(parse(&args, "--duration-s", 20)?),
                interval: Duration::from_millis(parse(&args, "--interval-ms", 100)?),
                ping_bytes: parse(&args, "--ping-bytes", 96)?,
            };
            let mut result = phone_run(&mut path, &run).await;
            if let Some(obj) = result.as_object_mut() {
                obj.insert("mode".into(), json!(mode));
                obj.insert("label".into(), json!(flag(&args, "--label")));
            }
            println!("{result}");
            Ok(())
        }
        Some("mac") => {
            let peer: SocketAddr = match (flag(&args, "--relay"), flag(&args, "--addr-file")) {
                (Some(r), _) => r.parse()?,
                (None, Some(f)) => {
                    read_addr_file(&PathBuf::from(f), Duration::from_secs(60)).await?
                }
                _ => bail!("--relay or --addr-file"),
            };
            let mut path = if hop { Path::hop(sock, peer) } else { Path::plain(sock, peer) };
            let cfg = MacConfig {
                fps: parse(&args, "--fps", 60)?,
                frame_bytes: parse(&args, "--frame-bytes", 900)?,
                bulk_kbit: parse(&args, "--bulk-kbit", 14_000)?,
                bulk_bytes: parse(&args, "--bulk-bytes", 1200)?,
            };
            eprintln!("hop-bench mac: {mode} to {peer}");
            mac_serve(&mut path, &cfg).await;
            Ok(())
        }
        _ => {
            print!("{HELP}");
            Ok(())
        }
    }
}
