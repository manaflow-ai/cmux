//! `remote_stream_bench --perf-suite`: the three workloads of the cmux-wg
//! layer study (small messages, screen frames, bulk) through one cmux-wg TCP
//! connection over loopback UDP, every datagram through the bench's shaped
//! link at one fixed setting ([`RTT_MS`], [`LOSS_PCT`]). Prints one JSON
//! object, `{"rows": [...]}`, whose rows the perf cron's `wg-stream` part
//! stores and compares (scripts/cmux-next/perf-cron.py; cmux-tui/scripts/
//! wg-stream-perf-linux.sh runs it).
//!
//! Each row is lower-is-better, as the cron reads every row: frame p95 in ms
//! (small and frames), CPU µs per MB of payload delivered (all three, both
//! ends, from `getrusage`), and bulk as ms per GiB. `<workload>.mbit_s` is
//! payload Mbit/s, stored and shown but not judged (higher is better there);
//! bulk's is judged through `bulk.ms_per_gib`. A row's `target` is its
//! budget: today's value with headroom (see [`Limit`]), so a regression past
//! it shows on the cron's issue even before the 10 % rule against the last
//! good run.
//!
//! The shaped link is the bench's in-process delay line, not kernel netem:
//! kernel netem needs root, `unshare -n` and `sch_netem`, which the cron's
//! Linux runners do not offer.

use std::io;
use std::sync::Arc;

use tokio::time::Instant;

use super::{Clock, Record, Shared, args_from, lock, run_wg_tcp};

/// Round trip added by the shaped link, half each way.
pub(crate) const RTT_MS: u64 = 2;
/// Loss on each datagram of the shaped link, percent.
pub(crate) const LOSS_PCT: f64 = 0.0;
/// Bumped when a workload or the setting changes, so the cron rebases the
/// rows instead of comparing two configurations.
const VERSION: u32 = 1;
const BULK_BYTES: usize = 200_000_000;

struct Workload {
    name: &'static str,
    frame_bytes: usize,
    keyframe_bytes: usize,
    seconds: u64,
    bulk_bytes: usize,
}

const WORKLOADS: [Workload; 3] = [
    // 60 messages a second of 200 B (keystrokes, chat deltas).
    Workload { name: "small", frame_bytes: 200, keyframe_bytes: 200, seconds: 8, bulk_bytes: 0 },
    // A screen share: 60 fps of 3,500 B after a 200 KB first frame.
    Workload {
        name: "frames",
        frame_bytes: 3_500,
        keyframe_bytes: 200_000,
        seconds: 8,
        bulk_bytes: 0,
    },
    // 200 MB on a fresh stream (a file, a scrollback dump).
    Workload {
        name: "bulk",
        frame_bytes: 0,
        keyframe_bytes: 0,
        seconds: 0,
        bulk_bytes: BULK_BYTES,
    },
];

/// A row's budget: `<row>` at most `ceiling` (lower is better).
struct Limit {
    row: &'static str,
    ceiling: f64,
}

/// Measured on 2026-11-20 on the cron's Linux runner class (the PR that added
/// this file has the run); each budget leaves headroom over that value: frame
/// p95 and CPU per MB at about 2x, bulk at about 0.6x the Mbit/s.
const LIMITS: [Limit; 6] = [
    Limit { row: "small.p95_ms", ceiling: 10.0 },
    Limit { row: "frames.p95_ms", ceiling: 10.0 },
    Limit { row: "small.cpu_us_per_mb", ceiling: 2_000_000.0 },
    Limit { row: "frames.cpu_us_per_mb", ceiling: 200_000.0 },
    Limit { row: "bulk.cpu_us_per_mb", ceiling: 20_000.0 },
    Limit { row: "bulk.ms_per_gib", ceiling: 20_000.0 },
];

/// What one workload measured.
struct Measured {
    p95_ms: Option<f64>,
    cpu_us_per_mb: Option<f64>,
    mbit_s: Option<f64>,
}

pub(crate) async fn run() -> io::Result<()> {
    let mut rows = Vec::new();
    for workload in &WORKLOADS {
        let measured = measure(workload).await?;
        let mut push = |metric: &str, unit: &str, value: Option<f64>| {
            if let Some(value) = value.filter(|v| v.is_finite()) {
                rows.push(row(workload.name, metric, unit, value));
            }
        };
        if workload.bulk_bytes == 0 {
            push("p95_ms", "ms", measured.p95_ms);
        } else {
            push("ms_per_gib", "ms/GiB", measured.mbit_s.filter(|m| *m > 0.0).map(ms_per_gib));
        }
        push("cpu_us_per_mb", "us/MB", measured.cpu_us_per_mb);
        push("mbit_s", "Mbit/s", measured.mbit_s);
        eprintln!(
            "wg-stream {}: p95 {:?} ms, {:?} Mbit/s, {:?} CPU us/MB",
            workload.name, measured.p95_ms, measured.mbit_s, measured.cpu_us_per_mb
        );
    }
    println!(
        "{{\"setting\":{{\"rtt_ms\":{RTT_MS},\"loss_pct\":{LOSS_PCT},\"link\":\"in-process\"}},\"rows\":[{}]}}",
        rows.join(",")
    );
    Ok(())
}

async fn measure(workload: &Workload) -> io::Result<Measured> {
    let flags = [
        ("--path", "wg-tcp".to_owned()),
        ("--rtt-ms", RTT_MS.to_string()),
        ("--loss-pct", LOSS_PCT.to_string()),
        ("--fps", "60".to_owned()),
        ("--frame-bytes", workload.frame_bytes.to_string()),
        ("--keyframe-bytes", workload.keyframe_bytes.to_string()),
        ("--seconds", workload.seconds.to_string()),
        ("--bulk-bytes", workload.bulk_bytes.to_string()),
    ];
    let args = args_from(flags.into_iter().flat_map(|(flag, value)| [flag.to_owned(), value]));
    let record: Shared = Arc::default();
    let clock = Arc::new(Clock(Instant::now()));
    let cpu_before = cpu_seconds();
    run_wg_tcp(&args, clock, record.clone()).await?;
    let cpu = cpu_seconds().zip(cpu_before).map(|(after, before)| after - before);
    let mut record = lock(&record);
    let (bytes, mbit_s) = if workload.bulk_bytes == 0 {
        let bytes = stream_bytes(&record, workload);
        (bytes, Some(bytes * 8.0 / workload.seconds.max(1) as f64 / 1e6))
    } else {
        // A transfer cut at the bench's 60 s limit shows as low Mbit/s; its
        // CPU is still divided by the whole size, the bytes it was asked for.
        (workload.bulk_bytes as f64, record.bulk_mbit_s)
    };
    Ok(Measured {
        p95_ms: p95_ms(&mut record.frame_us),
        cpu_us_per_mb: cpu.filter(|_| bytes > 0.0).map(|cpu| cpu * 1e6 / (bytes / 1e6)),
        mbit_s,
    })
}

/// Payload bytes the viewer received in the stream: the first frame and
/// every frame after it.
fn stream_bytes(record: &Record, workload: &Workload) -> f64 {
    let first = if record.first_frame_us.is_some() { workload.keyframe_bytes } else { 0 };
    (first + record.frame_us.len() * workload.frame_bytes) as f64
}

fn p95_ms(values: &mut [u64]) -> Option<f64> {
    values.sort_unstable();
    let index = ((values.len().checked_sub(1)?) as f64 * 0.95).round() as usize;
    values.get(index).map(|us| *us as f64 / 1000.0)
}

/// How long one GiB takes at `mbit_s`.
fn ms_per_gib(mbit_s: f64) -> f64 {
    (1u64 << 30) as f64 * 8.0 / (mbit_s * 1e6) * 1000.0
}

fn row(workload: &str, metric: &str, unit: &str, value: f64) -> String {
    let name = format!("{workload}.{metric}");
    let target = LIMITS
        .iter()
        .find(|limit| limit.row == name)
        .map_or_else(|| "null".to_owned(), |limit| format!("{}", limit.ceiling));
    format!(
        "{{\"name\":\"wg_stream.{name}\",\"p50\":{value:.4},\"p95\":{value:.4},\"unit\":\"{unit}\",\
         \"target\":{target},\"version\":{VERSION}}}"
    )
}

/// User and system CPU seconds this process has used, both bench ends and
/// the runtime's threads together.
#[cfg(unix)]
fn cpu_seconds() -> Option<f64> {
    let mut usage = std::mem::MaybeUninit::<libc::rusage>::zeroed();
    // SAFETY: getrusage writes one rusage into the pointer it is given, which
    // points at a zeroed rusage this frame owns.
    let status = unsafe { libc::getrusage(libc::RUSAGE_SELF, usage.as_mut_ptr()) };
    if status != 0 {
        return None;
    }
    // SAFETY: zeroed is a valid rusage, and getrusage succeeded.
    let usage = unsafe { usage.assume_init() };
    let seconds = |t: libc::timeval| t.tv_sec as f64 + t.tv_usec as f64 / 1e6;
    Some(seconds(usage.ru_utime) + seconds(usage.ru_stime))
}

#[cfg(not(unix))]
fn cpu_seconds() -> Option<f64> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn p95_of_none_is_none() {
        assert_eq!(p95_ms(&mut []), None);
        assert_eq!(p95_ms(&mut [3_000, 1_000, 2_000]), Some(3.0));
    }

    #[test]
    fn a_gib_at_8590_mbit_takes_a_second() {
        assert!((ms_per_gib(8_589.934_592) - 1000.0).abs() < 0.01);
    }

    #[test]
    fn every_limit_names_a_row_the_suite_prints() {
        for limit in &LIMITS {
            let (workload, metric) = limit.row.split_once('.').unwrap_or_default();
            let known = WORKLOADS.iter().find(|w| w.name == workload);
            assert!(known.is_some(), "{}", limit.row);
            assert!(["p95_ms", "cpu_us_per_mb", "ms_per_gib"].contains(&metric), "{}", limit.row);
        }
    }
}
