//! The connect time of `cmux carrier serve`'s socket connections, on the
//! same stand-in platform, real relay and real daemon as `carrier_serve.rs`:
//! from `connect(2)` on the served socket to the daemon's first answer, for
//! the first connection and the ones after it. It asserts only that every
//! connection is answered; it prints the times (and the connect log) so one
//! harness gives the before and after of a serve change:
//! `cargo test -p cmux-tui --test carrier_serve_timing -- --nocapture`.
#![cfg(target_os = "linux")]

mod carrier_support;

use std::io::{BufReader, Write};
use std::os::unix::net::UnixStream;
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::AtomicUsize;
use std::time::{Duration, Instant};

use carrier_support::*;
use serde_json::Value;

/// Connections after the first.
const LATER: usize = 20;

#[test]
fn serve_connection_connect_times() {
    let world = world(200, Arc::new(AtomicUsize::new(0)));
    let socket = world.dir.path().join("carrier.sock");
    let mut child = Command::new(BIN)
        .args(["carrier", "serve", "--machine", MACHINE, "--deadline-ms", "30000"])
        .args(["--socket", socket.to_str().unwrap()])
        .args(["--cloud-api", &format!("http://{}", world.platform)])
        .env_clear()
        .env("HOME", world.dir.path())
        .env("CMUX_CLOUD_ACCESS_TOKEN", TOKEN)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stderr = BufReader::new(child.stderr.take().unwrap());
    let ready: Value = serde_json::from_str(&line(&mut stderr)).unwrap();
    assert_eq!(ready["ok"], true, "{ready}");

    // Each connection stays open, as an upload's or a chat's would while
    // the next one starts.
    let mut open = Vec::new();
    let mut times = Vec::new();
    for id in 0..=LATER {
        let started = Instant::now();
        let stream = UnixStream::connect(&socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(40))).unwrap();
        let mut conn = BufReader::new(stream);
        let sent = format!("{{\"cmd\":\"identify\",\"id\":{id}}}\n");
        conn.get_mut().write_all(sent.as_bytes()).unwrap();
        assert_eq!(line(&mut conn), sent, "connection {id} reached the daemon");
        times.push(started.elapsed());
        let served: Value = serde_json::from_str(&line(&mut stderr)).unwrap();
        assert_eq!(served["ok"], true, "{served}");
        open.push(conn);
    }
    let mut later: Vec<_> = times[1..].iter().map(Duration::as_secs_f64).collect();
    later.sort_by(f64::total_cmp);
    let pick = |q: f64| later[((later.len() - 1) as f64 * q).round() as usize] * 1000.0;
    eprintln!(
        "carrier-serve-timing first_ms={:.1} later_p50_ms={:.1} later_p95_ms={:.1} later_max_ms={:.1} later_n={}",
        times[0].as_secs_f64() * 1000.0,
        pick(0.5),
        pick(0.95),
        pick(1.0),
        later.len()
    );
    let log = world.dir.path().join(".local/state/cmux-tui/sessions/carrier/connect.log");
    for entry in std::fs::read_to_string(log).unwrap_or_default().lines() {
        eprintln!("carrier-serve-timing log: {entry}");
    }
    drop(open);
    drop(child.stdin.take());
    assert_eq!(wait(&mut child, Duration::from_secs(20)), Some(0));
}
