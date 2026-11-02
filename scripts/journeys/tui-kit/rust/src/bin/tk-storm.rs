//! tk-storm: load_profiles.py's L1 CLI storm, compiled (cmux-ad 03:40Z). N workers share one
//! schedule (call n is due at start + n / rate) and run the L1 mix against a tagged build.
//!
//!   tk-storm --cli CMUX --socket DAEMON_SOCK --app-socket APP_SOCK --home HOME
//!            --workspace WS --pane PANE --terminal TERM [--workers 8] [--rate 100] [--duration 120]
//!            [--seed 7] --calls FILE.jsonl --summary FILE.json
//!
//! Every call is a calls.jsonl line {t_mono, t_wall, kind, ms, ok, worker[, error]} (load_profiles.py
//! Calls' shape). The summary has calls, failed, by_kind, load_seconds, achieved_per_s, ok_per_s,
//! asked_per_s, verdict ("ok", or "NOT RUN" below 95 % of the asked rate) and leftover_tabs (tabs the
//! workers made and did not close: the caller's teardown closes them). SIGTERM or SIGINT ends it at the
//! next call; exit 0 when it ran (even NOT RUN: the verdict says it), 2 on bad options.

use std::collections::BTreeMap;
use std::fs::File;
use std::io::{BufWriter, Write};
use std::process::ExitCode;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tuikit_load::args::Args;
use tuikit_load::jsonl::{Log, Value};
use tuikit_load::storm::{argv, Rng, Target};
use tuikit_load::sys;

const KNOWN: &[&str] = &[
    "cli",
    "socket",
    "app-socket",
    "home",
    "workspace",
    "pane",
    "terminal",
    "workers",
    "rate",
    "duration",
    "seed",
    "calls",
    "summary",
];

struct Shared {
    log: Mutex<Log>,
    by_kind: Mutex<BTreeMap<String, u64>>,
    leftover: Mutex<Vec<String>>,
    calls: AtomicU64,
    failed: AtomicU64,
}

fn need(a: &Args, name: &str) -> Result<String, String> {
    a.text(name)
        .map(str::to_string)
        .ok_or_else(|| format!("--{name} is required"))
}

fn main() -> ExitCode {
    let argv_in: Vec<String> = std::env::args().skip(1).collect();
    let parsed = Args::parse(&argv_in, &[]).and_then(|a| {
        if let Some(unknown) = a.names().find(|n| !KNOWN.contains(n)) {
            return Err(format!("unknown option --{unknown}"));
        }
        let target = Target {
            cli: need(&a, "cli")?,
            daemon_socket: need(&a, "socket")?,
            app_socket: need(&a, "app-socket")?,
            home: need(&a, "home")?,
            workspace: need(&a, "workspace")?,
            pane: need(&a, "pane")?,
            terminal: need(&a, "terminal")?,
        };
        let workers: usize = a.num("workers", 8)?;
        let rate: f64 = a.num("rate", 100.0)?;
        let duration: f64 = a.num("duration", 120.0)?;
        let seed: u64 = a.num("seed", 7)?;
        if workers == 0 || workers > 64 || rate.is_nan() || rate <= 0.0 {
            return Err("--workers is 1..64 and --rate above 0".into());
        }
        Ok((
            target,
            workers,
            rate,
            duration,
            seed,
            need(&a, "calls")?,
            need(&a, "summary")?,
        ))
    });
    let (target, workers, rate, duration, seed, calls_path, summary_path) = match parsed {
        Ok(p) => p,
        Err(e) => {
            eprintln!("tk-storm: {e}");
            return ExitCode::from(2);
        }
    };
    let log = match Log::open(Some(calls_path.as_str())) {
        Ok(log) => log,
        Err(e) => {
            eprintln!("tk-storm: {e}");
            return ExitCode::from(2);
        }
    };
    sys::install_signals(false);
    let shared = Arc::new(Shared {
        log: Mutex::new(log),
        by_kind: Mutex::new(BTreeMap::new()),
        leftover: Mutex::new(Vec::new()),
        calls: AtomicU64::new(0),
        failed: AtomicU64::new(0),
    });
    let next = Arc::new(AtomicU64::new(0));
    let start = sys::monotonic();
    let stop_at = if duration > 0.0 {
        start + duration
    } else {
        f64::INFINITY
    };
    let period = 1.0 / rate;
    let mut handles = Vec::new();
    for worker in 0..workers {
        let (shared, next, target) = (Arc::clone(&shared), Arc::clone(&next), target.clone());
        handles.push(std::thread::spawn(move || {
            run_worker(
                worker, seed, &target, &shared, &next, start, stop_at, period,
            );
        }));
    }
    for h in handles {
        let _ = h.join();
    }
    let end = sys::monotonic().min(stop_at);
    let span = (end - start).max(1e-9);
    let calls = shared.calls.load(Ordering::SeqCst);
    let failed = shared.failed.load(Ordering::SeqCst);
    let achieved = calls as f64 / span;
    let verdict = if achieved < 0.95 * rate {
        "NOT RUN"
    } else {
        "ok"
    };
    let mut summary = String::from("{");
    summary.push_str(&format!(
        "\"calls\": {calls}, \"failed\": {failed}, \"load_seconds\": {span:.3}, \"achieved_per_s\": {achieved:.2}, \
         \"ok_per_s\": {:.2}, \"asked_per_s\": {rate:.2}, \"workers\": {workers}, \"verdict\": \"{verdict}\", \
         \"engine\": \"rust\", \"by_kind\": {{",
        (calls - failed) as f64 / span
    ));
    if let Ok(kinds) = shared.by_kind.lock() {
        let parts: Vec<String> = kinds.iter().map(|(k, v)| format!("\"{k}\": {v}")).collect();
        summary.push_str(&parts.join(", "));
    }
    summary.push_str("}, \"leftover_tabs\": [");
    if let Ok(tabs) = shared.leftover.lock() {
        let parts: Vec<String> = tabs.iter().map(|t| format!("\"{t}\"")).collect();
        summary.push_str(&parts.join(", "));
    }
    summary.push_str("]}\n");
    if let Ok(mut log) = shared.log.lock() {
        log.flush();
    }
    let written = File::create(&summary_path).and_then(|f| {
        let mut w = BufWriter::new(f);
        w.write_all(summary.as_bytes())?;
        w.flush()
    });
    if let Err(e) = written {
        eprintln!("tk-storm: --summary {summary_path}: {e}");
        return ExitCode::from(1);
    }
    ExitCode::SUCCESS
}

#[allow(clippy::too_many_arguments, reason = "one worker's fixed inputs")]
fn run_worker(
    worker: usize,
    seed: u64,
    target: &Target,
    shared: &Shared,
    next: &AtomicU64,
    start: f64,
    stop_at: f64,
    period: f64,
) {
    let mut rng = Rng::new(seed.wrapping_mul(1000).wrapping_add(worker as u64));
    let mut mine: Vec<String> = Vec::new();
    loop {
        let n = next.fetch_add(1, Ordering::SeqCst);
        let due = start + n as f64 * period;
        if due >= stop_at {
            break;
        }
        loop {
            if sys::quit_requested() {
                break;
            }
            let left = due - sys::monotonic();
            if left <= 0.0 {
                break;
            }
            std::thread::sleep(Duration::from_secs_f64(left.min(0.05)));
        }
        if sys::quit_requested() || sys::monotonic() >= stop_at {
            break;
        }
        let mut kind = rng.pick();
        if kind == "tab.close" && mine.is_empty() {
            kind = "tab.create";
        }
        if kind == "tab.create" && mine.len() >= 3 {
            kind = "tab.close";
        }
        let close = if kind == "tab.close" && !mine.is_empty() {
            Some(mine.remove(0))
        } else {
            None
        };
        let tag = rng.below(1_000_000);
        let unit = rng.unit();
        let t0 = sys::monotonic();
        let w0 = sys::wall();
        let outcome = match argv(kind, target, worker, tag, close.as_deref(), unit) {
            Some(args) => target.cli(&args),
            None => target.rpc("snapshot.get"),
        };
        let ms = (sys::monotonic() - t0) * 1000.0;
        if let Some(tab) = outcome.tab_made.clone() {
            if kind == "tab.create" {
                mine.push(tab);
            }
        }
        if let (Some(tab), false) = (close.as_ref(), outcome.ok) {
            mine.insert(0, tab.clone()); // not closed: still this worker's
        }
        shared.calls.fetch_add(1, Ordering::SeqCst);
        if !outcome.ok {
            shared.failed.fetch_add(1, Ordering::SeqCst);
        }
        if let Ok(mut kinds) = shared.by_kind.lock() {
            *kinds.entry(kind.to_string()).or_insert(0) += 1;
        }
        let mut fields = vec![
            ("t_mono", Value::Num(t0, 6)),
            ("t_wall", Value::Num(w0, 6)),
            ("kind", Value::Str(kind.to_string())),
            ("ms", Value::Num(ms, 3)),
            ("ok", Value::Bool(outcome.ok)),
            ("worker", Value::Int(worker as i64)),
            ("mono", Value::Num(t0, 6)),
            ("wall", Value::Num(w0, 6)),
        ];
        if let Some(error) = outcome.error {
            fields.push(("error", Value::Str(error)));
        }
        if let Ok(mut log) = shared.log.lock() {
            log.event("call", fields);
        }
    }
    if let Ok(mut left) = shared.leftover.lock() {
        left.extend(mine);
    }
}
