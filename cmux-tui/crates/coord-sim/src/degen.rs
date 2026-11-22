//! `coord-sim degen --case NAME [--coordinators N --rate X] --out RUN_DIR`: one degenerate case
//! under load, against a scratch acpmux daemon this process starts (its own HOME, its own socket,
//! never the person's), with a stand-in ACP agent as its only harness.
//!
//! Cases (each one names the invariant its verdict checks):
//!
//! | case           | what happens                                                               | invariant |
//! | ---            | ---                                                                        | --- |
//! | burst          | 50k events in one write into one chat, then 20 chats burst at once         | no loss, no dup, bounded latency, bounded RSS |
//! | reconnect      | readers close their socket hard every 200 ms mid-stream and resync         | no loss, no dup after resync |
//! | daemon-restart | the daemon (by the pid started here) stops and starts mid-stream           | recovery, bounded gap, no loss, no dup |
//! | full-disk      | the daemon's home on a small filesystem that fills mid-stream              | bounded failure, no corruption, recovery |
//! | slow-link      | readers behind a 64 KB/s, 300 ms proxy (`degen/proxy.rs`)                  | bounded RSS, fast reader not held back |
//! | fanout         | one message to 200 sessions at once (`acpmux send`)                        | every session answers, bounded latency |
//! | sidebar-10k    | 10,000 sessions on disk; list latency, paging, memory, one change's cost   | bounded latency, O(1) change |
//!
//! The daemon is started here until the shared driver (`drive.rs`) lands; every case takes the
//! same `--acpmux BIN` and `--fake-agent PATH` (acpmux's `tests/fake_agent.py`).
//!
//! RUN_DIR holds raw samples, one JSON object per line, `t_ms` since the case started:
//! - `events.ndjson`: one per record a reader got: `reader`, `session`, `seq`, `kind`, `src`
//!   (`page`: in an attach reply; `live`: a `_acpmux/event` notification), `attach` (the reader's
//!   attachment number, from 1).
//! - `ops.ndjson`: one per operation the case did: `op`, `ms` (its latency), `ok`, and fields of
//!   its own (`session`, `bytes`, `detail`).
//! - `proc.ndjson`: the daemon every 100 ms, from its own gauges (`_acpmux/status`): `rss_kb`,
//!   `hwm_kb` (its peak), `queues` (bytes queued per connection).
//! - `verdict.json`: `case`, `pass`, `invariants` (`name`, `pass`, `value`, `bound`), `numbers`.
//!
//! The last stdout line is the verdict: `VERDICT <case> PASS|FAIL <invariant>=<value> ...`. A failing
//! verdict is also this command's error (exit 1), after RUN_DIR is complete.

mod cases;
mod daemon;
mod proxy;
mod rpc;
mod run;
mod sidebar;

use crate::{flag, flag_or};
pub use run::Run;

/// What every case is handed: the run directory, the daemon recipe, and the load knobs.
pub struct Ctx {
    pub run: Run,
    pub recipe: daemon::Recipe,
    pub coordinators: u32,
    pub rate: f64,
    pub args: Vec<String>,
}

impl Ctx {
    pub fn num<T: std::str::FromStr>(&self, name: &str, default: T) -> Result<T, String> {
        flag_or(&self.args, name, default)
    }

    /// An event count, times `--rate` (1 by default): `--rate 2` streams twice as many.
    pub fn scaled(&self, name: &str, default: u64) -> Result<u64, String> {
        let n: u64 = self.num(name, default)?;
        Ok(((n as f64) * self.rate).round().max(1.0) as u64)
    }
}

pub const CASES: [&str; 7] =
    ["burst", "reconnect", "daemon-restart", "full-disk", "slow-link", "fanout", "sidebar-10k"];

pub fn run(args: &[String]) -> Result<(), String> {
    if args.iter().any(|a| a == "--proxy") {
        return proxy::run_cli(args);
    }
    let case = flag(args, "--case")
        .ok_or_else(|| format!("--case is required: {}|all", CASES.join("|")))?;
    let out = flag(args, "--out").ok_or("--out RUN_DIR is required")?;
    if case == "all" {
        return all(args, std::path::Path::new(out));
    }
    let recipe = daemon::Recipe::from_args(args)?;
    let mut ctx = Ctx {
        run: Run::create(std::path::Path::new(out))?,
        recipe,
        coordinators: flag_or(args, "--coordinators", 1)?,
        rate: flag_or(args, "--rate", 1.0)?,
        args: args.to_vec(),
    };
    let verdict = match case {
        "burst" => cases::burst(&mut ctx),
        "reconnect" => cases::reconnect(&mut ctx),
        "daemon-restart" => cases::daemon_restart(&mut ctx),
        "full-disk" => cases::full_disk(&mut ctx),
        "slow-link" => cases::slow_link(&mut ctx),
        "fanout" => cases::fanout(&mut ctx),
        "sidebar-10k" => sidebar::sidebar(&mut ctx),
        other => return Err(format!("unknown case {other:?}: {}", CASES.join("|"))),
    };
    let verdict = match verdict {
        Ok(v) => v,
        Err(e) => {
            // The case could not finish: that is its verdict too, with the reason.
            let mut v = run::Verdict::new(case);
            v.check("case_ran", false, e.clone(), "the case runs to its end");
            v
        }
    };
    ctx.run.finish(&verdict)
}

/// `--case all`: every case in its own process (so one that hangs cannot hold the rest), each into
/// RUN_DIR/<case>, killed after `--case-timeout` seconds (default 1200). Prints every VERDICT line,
/// then `SUMMARY pass=N fail=M`; an error when any case failed or wrote no verdict.
fn all(args: &[String], out: &std::path::Path) -> Result<(), String> {
    let only: Option<Vec<String>> =
        flag(args, "--cases").map(|c| c.split(',').map(str::to_owned).collect());
    let limit = std::time::Duration::from_secs(flag_or(args, "--case-timeout", 1200)?);
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    // Every other argument goes to each case as it is.
    let mut rest = Vec::new();
    let mut it = args.iter();
    while let Some(a) = it.next() {
        if matches!(a.as_str(), "--case" | "--out" | "--cases" | "--case-timeout") {
            it.next();
        } else {
            rest.push(a.clone());
        }
    }
    let (mut pass, mut fail) = (0, Vec::new());
    for case in CASES.iter().filter(|c| only.as_ref().is_none_or(|o| o.iter().any(|x| x == *c))) {
        let dir = out.join(case);
        let t = std::time::Instant::now();
        // A `cmux_process::Child` leads its own process group, and dropping it ends the group: a
        // case past its time goes with the daemon and agents it started.
        let mut child = cmux_process::Command::new(&exe)
            .args(["degen", "--case", case, "--out"])
            .arg(&dir)
            .args(&rest)
            .spawn()
            .map_err(|e| format!("{case}: {e}"))?;
        let status = child.wait_timeout(limit).map_err(|e| format!("{case}: {e}"))?;
        drop(child);
        let secs = t.elapsed().as_secs();
        let verdict = std::fs::read_to_string(dir.join("verdict.json")).ok();
        match (status, verdict) {
            (Some(s), Some(_)) if s.success() => pass += 1,
            (None, _) => {
                println!("VERDICT {case} FAIL !case_timeout={secs}s");
                fail.push(case.to_string());
            }
            (_, None) => {
                println!("VERDICT {case} FAIL !no_verdict exit={status:?}");
                fail.push(case.to_string());
            }
            _ => fail.push(case.to_string()),
        }
        println!("CASE {case} took {secs} s");
    }
    println!("SUMMARY pass={pass} fail={} {}", fail.len(), fail.join(","));
    if fail.is_empty() { Ok(()) } else { Err(format!("failed: {}", fail.join(","))) }
}
