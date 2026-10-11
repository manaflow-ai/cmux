//! `ping`, `tcp`, and `probe` over an up [`Tunnel`]. Each writes JSON lines
//! to `out` and flushes after every line.

use std::collections::HashMap;
use std::io::{self, Write};
use std::net::{Ipv4Addr, SocketAddrV4};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::json;

use crate::tunnel::{TcpStatus, Tunnel, TunnelError};

const POLL_SLICE: Duration = Duration::from_millis(5);

fn millis(duration: Duration) -> f64 {
    (duration.as_secs_f64() * 1_000_000.0).round() / 1_000.0
}

pub fn wall_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |since| since.as_millis() as u64)
}

fn line(out: &mut dyn Write, value: serde_json::Value) -> io::Result<()> {
    writeln!(out, "{value}")?;
    out.flush()
}

#[derive(Debug, Clone, Copy)]
pub struct PingOptions {
    pub count: u16,
    pub timeout: Duration,
    pub interval: Duration,
}

/// Echo `count` times, one at a time. Returns how many replies came.
pub fn ping(
    tunnel: &mut Tunnel,
    destination: Ipv4Addr,
    options: PingOptions,
    out: &mut dyn Write,
) -> Result<u16, TunnelError> {
    let mut rtts = Vec::new();
    for seq in 1..=options.count {
        let start = Instant::now();
        tunnel.send_echo(destination, seq)?;
        let mut rtt = None;
        while rtt.is_none() && start.elapsed() < options.timeout {
            tunnel.poll(POLL_SLICE.min(options.timeout.saturating_sub(start.elapsed())))?;
            if tunnel.take_echo_replies(destination).contains(&seq) {
                rtt = Some(start.elapsed());
            }
        }
        match rtt {
            Some(rtt) => {
                rtts.push(rtt);
                line(out, json!({ "seq": seq, "rttMs": millis(rtt) }))?;
            }
            None => line(out, json!({ "seq": seq, "timeout": true }))?,
        }
        if seq < options.count {
            tunnel.poll_until(start + options.interval)?;
        }
    }
    let received = rtts.len() as u16;
    let mut summary = json!({
        "summary": true,
        "peer": destination.to_string(),
        "sent": options.count,
        "received": received,
    });
    if let (Some(min), Some(max)) = (rtts.iter().min(), rtts.iter().max()) {
        let total: Duration = rtts.iter().sum();
        summary["minMs"] = json!(millis(*min));
        summary["avgMs"] = json!(millis(total / u32::from(received)));
        summary["maxMs"] = json!(millis(*max));
    }
    line(out, summary)?;
    Ok(received)
}

/// Connect, optionally send `send` plus a newline and read the first line.
/// Returns whether it connected (and, with `send`, got a line).
pub fn tcp(
    tunnel: &mut Tunnel,
    remote: SocketAddrV4,
    send: Option<&str>,
    timeout: Duration,
    out: &mut dyn Write,
) -> Result<bool, TunnelError> {
    let start = Instant::now();
    let handle = tunnel.tcp_open(remote)?;
    let status = loop {
        let status = tunnel.tcp_status(handle);
        if status != TcpStatus::Pending || start.elapsed() >= timeout {
            break status;
        }
        tunnel.poll(POLL_SLICE)?;
    };
    let connect = start.elapsed();
    let mut result = json!({ "peer": remote.to_string() });
    match status {
        TcpStatus::Connected => result["connectMs"] = json!(millis(connect)),
        TcpStatus::Failed => {
            result["error"] = json!("refused");
            result["ms"] = json!(millis(connect));
        }
        TcpStatus::Pending => {
            result["error"] = json!("timeout");
            result["ms"] = json!(millis(connect));
        }
    }
    if status != TcpStatus::Connected {
        tunnel.tcp_remove(handle);
        line(out, result)?;
        return Ok(false);
    }
    let mut ok = true;
    if let Some(text) = send {
        let payload = format!("{text}\n");
        let mut offset = 0;
        let read_start = Instant::now();
        let mut received = Vec::new();
        let mut first_line = None;
        while read_start.elapsed() < timeout {
            if offset < payload.len() {
                offset += tunnel.tcp_send(handle, &payload.as_bytes()[offset..])?;
            }
            tunnel.poll(POLL_SLICE)?;
            tunnel.tcp_recv(handle, &mut received);
            if let Some(end) = received.iter().position(|byte| *byte == b'\n') {
                first_line = Some(
                    String::from_utf8_lossy(&received[..end]).trim_end_matches('\r').to_string(),
                );
                break;
            }
            if tunnel.tcp_eof(handle) {
                break;
            }
        }
        result["sent"] = json!(text);
        match first_line {
            Some(text) => {
                result["received"] = json!(text);
                result["roundTripMs"] = json!(millis(read_start.elapsed()));
            }
            None if !received.is_empty() => {
                // EOF or timeout after a partial line: report what came.
                result["received"] = json!(String::from_utf8_lossy(&received));
                result["partial"] = json!(true);
            }
            None => {
                result["receiveTimeout"] = json!(true);
                ok = false;
            }
        }
    }
    tunnel.tcp_close(handle);
    tunnel.poll(POLL_SLICE)?;
    tunnel.tcp_remove(handle);
    line(out, result)?;
    Ok(ok)
}

#[derive(Debug, Clone, Copy)]
pub struct ProbeOptions {
    pub interval: Duration,
    pub duration: Duration,
    pub attempt_timeout: Duration,
}

/// Start a connect attempt every `interval` for `duration`; attempts overlap.
/// One line per attempt as it resolves: `{"t","ok","ms"}` (plus `error`).
/// `t` is wall-clock ms at the attempt's start. Lines can come out of `t`
/// order when a slow attempt resolves after a later fast one. Returns
/// (attempts, ok).
pub fn probe(
    tunnel: &mut Tunnel,
    remote: SocketAddrV4,
    options: ProbeOptions,
    out: &mut dyn Write,
) -> Result<(u64, u64), TunnelError> {
    struct Attempt {
        wall: u64,
        started: Instant,
    }
    let start = Instant::now();
    let mut next = start;
    let mut inflight: HashMap<smoltcp::iface::SocketHandle, Attempt> = HashMap::new();
    let (mut attempts, mut successes) = (0u64, 0u64);
    loop {
        let now = Instant::now();
        let running = now.duration_since(start) < options.duration;
        if !running && inflight.is_empty() {
            break;
        }
        if running && now >= next {
            next += options.interval;
            attempts += 1;
            let wall = wall_ms();
            match tunnel.tcp_open(remote) {
                Ok(handle) => {
                    inflight.insert(handle, Attempt { wall, started: now });
                }
                Err(error) => line(
                    out,
                    json!({ "t": wall, "ok": false, "ms": 0.0, "error": error.to_string() }),
                )?,
            }
        }
        let until_next =
            if running { next.saturating_duration_since(Instant::now()) } else { POLL_SLICE };
        tunnel.poll(until_next.min(POLL_SLICE))?;
        let mut done = Vec::new();
        for (handle, attempt) in &inflight {
            let elapsed = attempt.started.elapsed();
            let outcome = match tunnel.tcp_status(*handle) {
                TcpStatus::Connected => Some((true, None)),
                TcpStatus::Failed => Some((false, Some("refused"))),
                TcpStatus::Pending if elapsed >= options.attempt_timeout => {
                    Some((false, Some("timeout")))
                }
                TcpStatus::Pending => None,
            };
            if let Some((ok, error)) = outcome {
                let mut value = json!({ "t": attempt.wall, "ok": ok, "ms": millis(elapsed) });
                if let Some(error) = error {
                    value["error"] = json!(error);
                }
                line(out, value)?;
                successes += u64::from(ok);
                done.push(*handle);
            }
        }
        for handle in done {
            inflight.remove(&handle);
            tunnel.tcp_remove(handle);
        }
    }
    line(out, json!({ "summary": true, "attempts": attempts, "ok": successes }))?;
    Ok((attempts, successes))
}
