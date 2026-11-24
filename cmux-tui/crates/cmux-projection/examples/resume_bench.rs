//! The resume benchmark (RFD 0007, open question 3): what a resume costs when the Mac sends the
//! whole manifest over its uplink, and when the machine fetches the stored revision instead.
//!
//!     resume_bench ENTRIES [--uplink-mbit M] [--store-rtt-ms N] [--skip-before]
//!
//! One synthetic folder of ENTRIES entries (dirs of 40 files, nested three deep, names of a
//! build tree). `before` is the resume today: the encoded manifest goes through a loopback TCP
//! socket paced to M megabits/s (default 6, Leo's uplink: 71 MB in 85-130 s is 4.4-6.7 Mbit/s)
//! and the receiver decodes it. `after` is the resume with a revision: the pieces come from a
//! loopback HTTP server that stands in for the store (each GET waits N ms first, default 30, for
//! the round trip to a data center), over the same code the machine runs (`revision::assemble`).
//! Both end with the same decoded manifest, checked equal. One JSON line goes to stdout.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_projection::manifest::{Item, Kind, Manifest};
use cmux_projection::peers::Http;
use cmux_projection::revision::{self, Store};

const GRANT: &str = "csg_bench";

fn items(entries: usize) -> Vec<Item> {
    let mut out = Vec::with_capacity(entries);
    let mut n = 0usize;
    'all: for a in 0.. {
        for b in 0..40 {
            for c in 0..40 {
                for f in 0..40 {
                    if out.len() >= entries {
                        break 'all;
                    }
                    n += 1;
                    out.push(Item {
                        path: format!(
                            "pkg{a:04}/mod{b:02}/lib{c:02}/file-{f:02}-{:x}.js",
                            n * 2654435761 % 0xffff
                        ),
                        kind: Kind::File,
                        mode: 0o644,
                        size: (n as u64 * 7919) % 90_000,
                        mtime_ns: 1_700_000_000_000_000_000 + (n as i64) * 1_000_003,
                        link: None,
                    });
                }
            }
        }
    }
    out
}

fn store(pieces: Arc<std::collections::HashMap<String, Vec<u8>>>, rtt: Duration) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        for conn in listener.incoming().flatten() {
            let pieces = Arc::clone(&pieces);
            std::thread::spawn(move || serve(conn, &pieces, rtt));
        }
    });
    format!("http://127.0.0.1:{port}")
}

fn serve(conn: TcpStream, pieces: &std::collections::HashMap<String, Vec<u8>>, rtt: Duration) {
    let mut reader = BufReader::new(conn.try_clone().unwrap());
    let mut writer = conn;
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line).unwrap_or(0) == 0 {
            return;
        }
        let sha = line
            .split_whitespace()
            .nth(1)
            .and_then(|p| p.rsplit('/').next())
            .unwrap_or("")
            .to_owned();
        let mut authed = false;
        loop {
            let mut header = String::new();
            if reader.read_line(&mut header).unwrap_or(0) == 0 {
                return;
            }
            if header.trim().is_empty() {
                break;
            }
            authed |=
                header.to_ascii_lowercase().starts_with("authorization:") && header.contains(GRANT);
        }
        std::thread::sleep(rtt);
        let reply = match pieces.get(&sha) {
            Some(bytes) if authed => {
                let mut head =
                    format!("HTTP/1.1 200 OK\r\ncontent-length: {}\r\n\r\n", bytes.len())
                        .into_bytes();
                head.extend_from_slice(bytes);
                head
            }
            _ => b"HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\n\r\n".to_vec(),
        };
        if writer.write_all(&reply).is_err() {
            return;
        }
    }
}

/// `bytes` through a loopback socket at `mbit` megabits/s, decoded on the far side.
fn before(bytes: &[u8], mbit: f64) -> anyhow::Result<Manifest> {
    let listener = TcpListener::bind("127.0.0.1:0")?;
    let addr = listener.local_addr()?;
    let total = bytes.len();
    let receiver = std::thread::spawn(move || -> anyhow::Result<Manifest> {
        let (mut conn, _) = listener.accept()?;
        let mut got = Vec::with_capacity(total);
        conn.read_to_end(&mut got)?;
        Manifest::decode(&got)
    });
    let mut conn = TcpStream::connect(addr)?;
    let started = Instant::now();
    let per_second = mbit * 1_000_000.0 / 8.0;
    let mut sent = 0usize;
    for chunk in bytes.chunks(64 * 1024) {
        conn.write_all(chunk)?;
        sent += chunk.len();
        let due = Duration::from_secs_f64(sent as f64 / per_second);
        if let Some(wait) = due.checked_sub(started.elapsed()) {
            std::thread::sleep(wait);
        }
    }
    drop(conn);
    receiver.join().map_err(|_| anyhow::anyhow!("receiver panicked"))?
}

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let entries: usize = args.first().and_then(|a| a.parse().ok()).unwrap_or(1_170_000);
    let flag = |name: &str| {
        args.iter()
            .position(|a| a == name)
            .and_then(|at| args.get(at + 1))
            .and_then(|v| v.parse::<f64>().ok())
    };
    let mbit = flag("--uplink-mbit").unwrap_or(6.0);
    let rtt = Duration::from_millis(flag("--store-rtt-ms").unwrap_or(30.0) as u64);
    let skip_before = args.iter().any(|a| a == "--skip-before");

    let manifest = Manifest::build(1, items(entries))?;
    let encoded = manifest.encode()?;

    let started = Instant::now();
    let split = revision::split(&manifest)?;
    let split_ms = started.elapsed().as_millis();
    let stored: usize = split.pieces.iter().map(|piece| piece.bytes.len()).sum();
    let origin = store(
        Arc::new(split.pieces.iter().map(|p| (p.sha256.clone(), p.bytes.clone())).collect()),
        rtt,
    );

    let started = Instant::now();
    let http = Http::new()?;
    let fetched =
        revision::assemble(&split.root, &Store { origin, grant: GRANT.into(), http: &http })?;
    let after_ms = started.elapsed().as_millis();
    anyhow::ensure!(fetched == manifest, "the fetched revision differs from the manifest");

    let before_ms = if skip_before {
        None
    } else {
        let started = Instant::now();
        let sent = before(&encoded, mbit)?;
        anyhow::ensure!(sent == manifest, "the sent manifest differs");
        Some(started.elapsed().as_millis())
    };
    println!(
        "{}",
        serde_json::json!({
            "entries": manifest.len(),
            "manifest_bytes": encoded.len(),
            "pieces": split.pieces.len(),
            "stored_bytes": stored,
            "split_ms": split_ms,
            "uplink_mbit": mbit,
            "store_rtt_ms": rtt.as_millis(),
            "before_ms": before_ms,
            "after_ms": after_ms,
        })
    );
    Ok(())
}
