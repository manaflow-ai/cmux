//! `cas-seed`: opt-in VM seeding of the public tier (hq `docs/design/cold-storage-and-shared-tier.md`,
//! P2). Nothing runs it by default; it listens or connects only when a person or a fleet job runs
//! it, and a seeder answers only public ids, only to its own region, and only within its upload cap.
//!
//! ```text
//! cas-seed serve --dir D --region R --listen ADDR [--rate BYTES_PER_S] [--burst BYTES]
//! cas-seed fetch --dir D --region R --entry ENTRY.json [--peer REGION@HOST:PORT ...]
//!                [--floor-dir PUBLIC_DIR] [--out DIR] [--timeout-ms N]
//! ```
//!
//! `serve` caps uploads at 4 MiB/s with a 16 MiB burst unless told otherwise. `fetch` takes the
//! entry (one `index.json` item, from an index the caller trusts), asks the region's peers in
//! order, then `--floor-dir` (a public tier directory standing in for the mirror shard and R2),
//! adopts the entry so this tier seeds it too, and with `--out` rebuilds its tree, checking every
//! file. It prints its stats as JSON.

use cmux_cas::assemble::assemble;
use cmux_cas::public::{Entry, Public};
use cmux_cas::seed::{Peer, Seeder, UploadCap, Want, fetch};
use cmux_cas::{Id, Manifest};
use std::net::TcpListener;
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::atomic::AtomicBool;
use std::time::Duration;

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("cas-seed: {e}");
            ExitCode::from(2)
        }
    }
}

fn run() -> Result<(), String> {
    let mut args = std::env::args().skip(1);
    let cmd = args.next().ok_or("a command: serve or fetch")?;
    let (mut dir, mut region, mut listen, mut entry) = (None, None, None, None);
    let (mut rate, mut burst) = (4u64 << 20, 16u64 << 20);
    let (mut peers, mut floor_dir, mut out, mut timeout) = (Vec::new(), None, None, 2000u64);
    while let Some(a) = args.next() {
        let mut val = || args.next().ok_or_else(|| format!("{a} needs a value"));
        match a.as_str() {
            "--dir" => dir = Some(PathBuf::from(val()?)),
            "--region" => region = Some(val()?),
            "--listen" => listen = Some(val()?),
            "--rate" => rate = val()?.parse().map_err(|_| "--rate needs bytes a second")?,
            "--burst" => burst = val()?.parse().map_err(|_| "--burst needs bytes")?,
            "--entry" => entry = Some(PathBuf::from(val()?)),
            "--peer" => peers.push(val()?.parse::<Peer>()?),
            "--floor-dir" => floor_dir = Some(PathBuf::from(val()?)),
            "--out" => out = Some(PathBuf::from(val()?)),
            "--timeout-ms" => {
                timeout = val()?.parse().map_err(|_| "--timeout-ms needs a number")?
            }
            _ => return Err(format!("unknown option {a}")),
        }
    }
    let public = Public::new(dir.ok_or("--dir is required")?);
    let region = region.ok_or("--region is required")?;
    match cmd.as_str() {
        "serve" => {
            let listen = listen.ok_or("--listen ADDR")?;
            let listener = TcpListener::bind(&listen).map_err(|e| format!("{listen}: {e}"))?;
            let seeder = Seeder::new(public, region.clone(), UploadCap::new(rate, burst))
                .map_err(|e| e.to_string())?;
            eprintln!(
                "cas-seed: serving region {region} on {} at {rate} B/s, burst {burst} B",
                listener.local_addr().map_err(|e| e.to_string())?
            );
            seeder.serve(listener, &AtomicBool::new(false));
        }
        "fetch" => {
            let path = entry.ok_or("--entry ENTRY.json")?;
            let bytes = std::fs::read(&path).map_err(|e| format!("{}: {e}", path.display()))?;
            let entry: Entry = serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
            let floor_tier = floor_dir.map(Public::new);
            let mut floor = |want: Want, id: &Id| -> cmux_cas::Result<Vec<u8>> {
                let tier = floor_tier.as_ref().ok_or("no peer had it and no --floor-dir")?;
                match want {
                    Want::Manifest => tier.manifest_bytes(id),
                    Want::Chunk => tier.store().file(id),
                }
            };
            let stats =
                fetch(&public, &entry, &region, &peers, Duration::from_millis(timeout), &mut floor)
                    .map_err(|e| e.to_string())?;
            if let Some(out) = out {
                let m = Manifest::from_bytes(
                    &public.manifest_bytes(&entry.manifest).map_err(|e| e.to_string())?,
                    &entry.manifest,
                )
                .map_err(|e| e.to_string())?;
                assemble(public.store(), &m, &out).map_err(|e| e.to_string())?;
            }
            let dropped: Vec<String> =
                stats.dropped.iter().map(|(a, why)| format!("{a}: {why}")).collect();
            println!(
                "{}",
                serde_json::json!({
                    "held": stats.held,
                    "peer_items": stats.peer_items,
                    "peer_bytes": stats.peer_bytes,
                    "floor_items": stats.floor_items,
                    "floor_bytes": stats.floor_bytes,
                    "skipped_region": stats.skipped_region,
                    "dropped": dropped,
                })
            );
        }
        other => return Err(format!("unknown command {other}")),
    }
    Ok(())
}
