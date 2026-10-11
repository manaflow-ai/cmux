//! `rdhost client`: Linux test client measuring glass-to-glass latency per PROTOCOL.md.
//! One sample: send INPUT key tap at t0 -> first decoded frame whose marker equals the
//! expected counter at t1. Next input after a match or 1000 ms (loss), then a uniform
//! random 40..160 ms wait so samples do not lock to the frame cadence.

use crate::args::Opts;
use crate::client_rx::{read_loop, MarkerSeen, Rx, RxState};
use crate::clock::{ms, now_ns, Rng};
use crate::proto::{self, Hello, HostStats, Input, VideoHeader};
use crate::stats::summarize;
use crate::sysinfo::process_cpu_s;
use crate::Res;
use std::io::Write;
use std::net::{Shutdown, TcpStream};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

const LOSS_NS: u64 = 1_000_000_000;
const PING_EVERY: Duration = Duration::from_millis(250);

struct Sample {
    t0: u64,
    seq: u32,
    seen: MarkerSeen,
}

fn send(w: &Mutex<TcpStream>, ty: u8, payload: &[u8]) -> Res<()> {
    let mut s = w.lock().map_err(|_| "writer poisoned")?;
    proto::write_msg(&mut *s, ty, payload)?;
    Ok(())
}

/// Waits on the receive state until `done` holds, the stream ended, or `deadline_ns` passes.
fn wait_for<'a>(rx: &'a Rx, deadline_ns: u64, done: impl Fn(&RxState) -> bool) -> Res<MutexGuard<'a, RxState>> {
    let mut g = rx.st.lock().map_err(|_| "rx poisoned")?;
    loop {
        let now = now_ns();
        if done(&g) || g.ended.is_some() || now >= deadline_ns {
            return Ok(g);
        }
        g = rx.cv.wait_timeout(g, Duration::from_nanos(deadline_ns - now)).map_err(|_| "rx poisoned")?.0;
    }
}

pub fn run(opts: &Opts) -> Res<()> {
    let addr = opts.str_or("addr", "127.0.0.1:7400");
    let workload = opts.str_or("workload", "marker");
    let samples: usize = opts.num_or("samples", 300)?;
    let warmup: usize = opts.num_or("warmup", 5)?;
    let idle_secs: u64 = opts.num_or("idle-secs", 30)?;
    let keycode: u32 = opts.num_or("keycode", 38)?;
    let hello = Hello {
        max_fps: opts.num_or("max-fps", 60)?,
        bitrate_kbps: opts.num_or("bitrate-kbps", 8000)?,
        workload: workload.clone(),
        capture: opts.str_or("capture", "damage"),
        client: "linux-openh264".into(),
        ..Hello::default()
    };
    let utc_start = std::process::Command::new("date").args(["-u", "+%Y-%m-%dT%H:%M:%SZ"]).output().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()).unwrap_or_default();

    let stream = TcpStream::connect(&addr)?;
    stream.set_nodelay(true)?;
    let writer = Arc::new(Mutex::new(stream.try_clone()?));
    send(&writer, proto::HELLO, serde_json::to_string(&hello)?.as_bytes())?;
    let rx = Arc::new(Rx::new());
    let reader = {
        let (rx, rd) = (Arc::clone(&rx), stream.try_clone()?);
        std::thread::spawn(move || read_loop(rd, &rx))
    };
    let (stop_tx, stop_rx) = mpsc::channel::<()>();
    let pinger = {
        let w = Arc::clone(&writer);
        std::thread::spawn(move || {
            while let Err(RecvTimeoutError::Timeout) = stop_rx.recv_timeout(PING_EVERY) {
                if send(&w, proto::PING, &now_ns().to_le_bytes()).is_err() {
                    break;
                }
            }
        })
    };

    // The first frame is a full IDR; wait until its marker decodes.
    {
        let g = wait_for(&rx, now_ns() + 15_000_000_000, |s| s.marker.is_some())?;
        if g.marker.is_none() {
            return Err(format!("no marker decoded within 15 s (ended: {:?}, frames: {})", g.ended, g.frames).into());
        }
    }

    let mut rng = Rng::new(now_ns());
    let mut taken: Vec<Sample> = Vec::new();
    let mut losses = 0usize;
    let mut window_start = None;
    let total = if workload == "idle" { 0 } else { warmup + samples };
    for i in 0..total {
        if i == warmup {
            window_start = Some(snapshot(&rx));
        }
        let base = rx.st.lock().map_err(|_| "rx poisoned")?.marker.map_or(0, |m| m.value);
        let expected = base.wrapping_add(1);
        let seq = i as u32 + 1;
        let t0 = now_ns();
        let input = Input { seq, kind: proto::INPUT_KEY_TAP, x: 0, y: 0, code: keycode, t_client_send_ns: t0 };
        send(&writer, proto::INPUT, &input.encode())?;
        let g = wait_for(&rx, t0 + LOSS_NS, |s| s.marker.is_some_and(|m| m.value == expected))?;
        let hit = g.marker.filter(|m| m.value == expected);
        let ended = g.ended.clone();
        drop(g);
        if i >= warmup {
            match hit {
                Some(seen) => taken.push(Sample { t0, seq, seen }),
                None => losses += 1,
            }
        }
        if let Some(reason) = ended {
            return Err(format!("stream ended during sampling: {reason}").into());
        }
        std::thread::sleep(Duration::from_millis(rng.range(40, 160)));
    }
    if workload == "idle" {
        // Settle (the IDR and any redraw), then measure the quiet window.
        std::thread::sleep(Duration::from_secs(2));
        window_start = Some(snapshot(&rx));
        std::thread::sleep(Duration::from_secs(idle_secs));
    }
    let start = window_start.unwrap_or_else(|| snapshot(&rx));
    let end = snapshot(&rx);

    let _ = send(&writer, proto::BYE, b"done");
    drop(stop_tx);
    let _ = pinger.join();
    let _ = stream.shutdown(Shutdown::Both);
    let _ = reader.join();

    let st = rx.st.lock().map_err(|_| "rx poisoned")?;
    let report = report(&st, &hello, &addr, &utc_start, &taken, losses, &start, &end);
    let text = serde_json::to_string_pretty(&report)?;
    match opts.get("out") {
        Some(path) => std::fs::write(path, &text)?,
        None => std::io::stdout().write_all(text.as_bytes())?,
    }
    Ok(())
}

struct Snap {
    t_ns: u64,
    cpu_s: f64,
    bytes: u64,
    frames: u64,
    decode_n: usize,
    stats_n: usize,
}

fn snapshot(rx: &Rx) -> Snap {
    let (bytes, frames, decode_n, stats_n) = rx.st.lock().map(|s| (s.bytes, s.frames, s.decode_ms.len(), s.host_stats.len())).unwrap_or_default();
    Snap { t_ns: now_ns(), cpu_s: process_cpu_s(), bytes, frames, decode_n, stats_n }
}

#[allow(clippy::too_many_arguments)]
fn report(st: &RxState, hello: &Hello, addr: &str, utc: &str, taken: &[Sample], losses: usize, a: &Snap, b: &Snap) -> serde_json::Value {
    let secs = (b.t_ns - a.t_ns) as f64 / 1e9;
    // Host clock offset from the lowest-RTT ping (exactly 0 on loopback).
    let offset = st.pongs.iter().min_by(|x, y| x.0.total_cmp(&y.0)).map_or(0, |p| p.1);
    let to_client = |t_host: u64| t_host as i64 - offset;
    let g2g: Vec<f64> = taken.iter().map(|s| ms(s.seen.t_decoded_ns - s.t0)).collect();
    let rel = |s: &Sample, t: u64| (to_client(t) - s.t0 as i64) as f64 / 1e6;
    let pick = |f: &dyn Fn(&Sample, &VideoHeader) -> Option<f64>| -> Vec<f64> { taken.iter().filter_map(|s| f(s, &s.seen.header)).collect() };
    let input_to_damage = pick(&|s, h| (h.t_damage_ns > 0).then(|| rel(s, h.t_damage_ns)));
    let input_to_capture = pick(&|s, h| Some(rel(s, h.t_capture_ns)));
    let capture_to_encoded = pick(&|_, h| Some(ms(h.t_encoded_ns.saturating_sub(h.t_capture_ns))));
    let encoded_to_decoded = pick(&|s, h| Some((s.seen.t_decoded_ns as i64 - to_client(h.t_encoded_ns)) as f64 / 1e6));
    let seq_ok = taken.iter().filter(|s| s.seen.header.last_input_seq >= s.seq).count();
    let window_stats: &[HostStats] = st.host_stats.get(a.stats_n..b.stats_n).unwrap_or(&[]);
    let col = |f: &dyn Fn(&HostStats) -> Option<f64>| -> Vec<f64> { window_stats.iter().filter_map(f).collect() };
    serde_json::json!({
        "utc_start": utc,
        "addr": addr,
        "hello": hello,
        "ack": st.ack,
        "samples": taken.len(),
        "losses": losses,
        "g2g_ms": summarize(&g2g),
        "breakdown_ms": {
            "note": "host stamps mapped to client clock with the min-RTT ping offset (exact on loopback)",
            "input_to_damage": summarize(&input_to_damage),
            "input_to_capture_done": summarize(&input_to_capture),
            "capture_to_encoded": summarize(&capture_to_encoded),
            "encoded_to_decoded": summarize(&encoded_to_decoded),
            "frames_with_last_input_seq_ok": seq_ok,
        },
        "window_s": secs,
        "video": {
            "bytes_per_s": (b.bytes - a.bytes) as f64 / secs,
            "kbit_per_s": (b.bytes - a.bytes) as f64 * 8.0 / 1000.0 / secs,
            "frames_per_s": (b.frames - a.frames) as f64 / secs,
            "keyframes_total": st.keyframes,
            "idr_without_sps": st.idr_without_sps,
            "decode_errors": st.decode_errors,
        },
        "rtt_ms": summarize(&st.pongs.iter().map(|p| p.0).collect::<Vec<_>>()),
        "decode_ms": summarize(st.decode_ms.get(a.decode_n..b.decode_n).unwrap_or(&[])),
        "client_cpu_pct": (b.cpu_s - a.cpu_s) / secs * 100.0,
        "host": {
            "cpu_pct_process": summarize(&col(&|h| h.cpu_pct_process)),
            "cpu_pct_system": summarize(&col(&|h| h.cpu_pct_system)),
            "bytes_per_s": summarize(&col(&|h| Some(h.bytes as f64))),
            "frames_per_s": summarize(&col(&|h| Some(h.frames as f64))),
            "capture_ms_p50": summarize(&col(&|h| h.capture_ms_p50)),
            "convert_ms_p50": summarize(&col(&|h| h.convert_ms_p50)),
            "encode_ms_p50": summarize(&col(&|h| h.encode_ms_p50)),
            "damage_to_send_ms_p50": summarize(&col(&|h| h.damage_to_send_ms_p50)),
            "inject_to_damage_ms_p50": summarize(&col(&|h| h.input_inject_to_damage_ms_p50)),
        },
        "g2g_ms_raw": g2g,
    })
}
