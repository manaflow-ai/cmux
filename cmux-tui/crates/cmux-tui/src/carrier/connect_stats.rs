//! `cmux carrier connect-stats [--log PATH] [--machine vm_…] [--json]`: the Mac's own connect
//! numbers, read from the dial's `carrier.phases` lines in its connect log ([`super::route_log`]).
//!
//! RFD 0223 row 1 and 2 (cmuxterm-hq `docs/rfd/0223-autocloud-tailscale.md`): no Mac-side connect
//! number existed, only server-side ones. Every app dial already appends one phases line per attempt
//! ([`super::contract::phases_line`]); this reads them back as p50 and p95 per step, split by
//! - `phase` (`connect`, `reconnect`, `stream`),
//! - warm or cold: a running machine's relay allocates its lane at once, a paused one waits out
//!   its resume in `parked_ms`, so an attempt with `parked_ms` at or past [`COLD_PARKED_MS`] is
//!   a cold connect (row 2) and the rest are warm (row 1),
//! - and any `net=` and `region=` tags the line carries (absent today: `-`).
//!
//! Failed attempts count in `n` and `failed`; the percentiles are of the `ok` attempts only.

use std::collections::BTreeMap;
use std::path::PathBuf;

/// A `parked_ms` at or past this is a paused machine's resume, not a running one's lane wait.
pub(super) const COLD_PARKED_MS: u64 = 1_000;

/// One `carrier.phases` line.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Attempt {
    pub machine: String,
    pub phase: String,
    pub ok: bool,
    pub net: String,
    pub region: String,
    /// `ticket`, `relay`, `parked`, `handshake`, `mux`, `total`, in [`STEPS`] order.
    pub ms: [u64; 6],
}

/// The steps a summary reports, in the phases line's order, then the whole attempt.
pub(super) const STEPS: [&str; 6] = ["ticket", "relay", "parked", "handshake", "mux", "total"];

/// The attempt of one connect log line, or None for any other line or a phases line missing a step.
pub(super) fn parse_line(line: &str) -> Option<Attempt> {
    let rest = line.trim().strip_prefix("carrier.phases ")?;
    let fields: BTreeMap<&str, &str> = rest.split(' ').filter_map(|f| f.split_once('=')).collect();
    let num = |key: &str| fields.get(key).and_then(|v| v.parse::<u64>().ok());
    let ms = [
        num("ticket_ms")?,
        num("relay_ms")?,
        num("parked_ms")?,
        num("handshake_ms")?,
        num("mux_ms")?,
        num("ms")?,
    ];
    let tag = |key: &str| fields.get(key).map_or("-", |v| v).to_owned();
    Some(Attempt {
        machine: tag("machine"),
        phase: tag("phase"),
        ok: fields.get("outcome") == Some(&"ok"),
        net: tag("net"),
        region: tag("region"),
        ms,
    })
}

/// One group's numbers.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Group {
    pub phase: String,
    /// `warm` or `cold`.
    pub start: &'static str,
    pub net: String,
    pub region: String,
    pub n: usize,
    pub failed: usize,
    /// Per step in [`STEPS`] order: (p50, p95) of the ok attempts; None with none ok.
    pub steps: [Option<(u64, u64)>; 6],
}

/// Nearest-rank percentile `p` (0 to 100) of sorted `values`.
pub(super) fn percentile(sorted: &[u64], p: u64) -> Option<u64> {
    if sorted.is_empty() {
        return None;
    }
    let rank = (p as usize * sorted.len()).div_ceil(100).max(1);
    sorted.get(rank - 1).copied()
}

/// The attempts grouped by phase, warm or cold, net and region, in that order.
pub(super) fn summarize(attempts: &[Attempt]) -> Vec<Group> {
    let mut groups: BTreeMap<(String, &'static str, String, String), Vec<&Attempt>> =
        BTreeMap::new();
    for attempt in attempts {
        let start = if attempt.ms[2] >= COLD_PARKED_MS { "cold" } else { "warm" };
        let key = (attempt.phase.clone(), start, attempt.net.clone(), attempt.region.clone());
        groups.entry(key).or_default().push(attempt);
    }
    groups
        .into_iter()
        .map(|((phase, start, net, region), members)| {
            let ok: Vec<&&Attempt> = members.iter().filter(|a| a.ok).collect();
            let steps = std::array::from_fn(|i| {
                let mut values: Vec<u64> = ok.iter().map(|a| a.ms[i]).collect();
                values.sort_unstable();
                Some((percentile(&values, 50)?, percentile(&values, 95)?))
            });
            Group {
                phase,
                start,
                net,
                region,
                n: members.len(),
                failed: members.len() - ok.len(),
                steps,
            }
        })
        .collect()
}

/// The groups as a table: one row per group, `p50/p95` per step in ms.
pub(super) fn render_text(groups: &[Group]) -> String {
    let mut out = format!(
        "{:<10} {:<5} {:<6} {:<10} {:>5} {:>6}",
        "phase", "start", "net", "region", "n", "failed"
    );
    for step in STEPS {
        out.push_str(&format!(" {:>15}", format!("{step} p50/p95")));
    }
    out.push('\n');
    for g in groups {
        out.push_str(&format!(
            "{:<10} {:<5} {:<6} {:<10} {:>5} {:>6}",
            g.phase, g.start, g.net, g.region, g.n, g.failed
        ));
        for step in g.steps {
            let cell = step.map_or_else(|| "-".to_owned(), |(p50, p95)| format!("{p50}/{p95}"));
            out.push_str(&format!(" {cell:>15}"));
        }
        out.push('\n');
    }
    out
}

/// The groups as one JSON document (`{"groups":[…]}`), each step `{"p50":…,"p95":…}` or null.
pub(super) fn render_json(groups: &[Group]) -> serde_json::Value {
    let groups: Vec<serde_json::Value> = groups
        .iter()
        .map(|g| {
            let steps: serde_json::Map<String, serde_json::Value> = STEPS
                .iter()
                .zip(g.steps)
                .map(|(name, step)| {
                    let value = step.map_or(
                        serde_json::Value::Null,
                        |(p50, p95)| serde_json::json!({"p50": p50, "p95": p95}),
                    );
                    ((*name).to_owned(), value)
                })
                .collect();
            serde_json::json!({
                "phase": g.phase, "start": g.start, "net": g.net, "region": g.region,
                "n": g.n, "failed": g.failed, "ms": steps,
            })
        })
        .collect();
    serde_json::json!({ "groups": groups, "cold_parked_ms": COLD_PARKED_MS })
}

struct Args {
    log: Option<PathBuf>,
    machine: Option<String>,
    json: bool,
}

fn parse_args(args: &[String]) -> Option<Args> {
    let (verb, rest) = args.split_first()?;
    if verb != "connect-stats" {
        return None;
    }
    let mut parsed = Args { log: None, machine: None, json: false };
    let mut rest = rest.iter();
    while let Some(flag) = rest.next() {
        match flag.as_str() {
            "--log" if parsed.log.is_none() => parsed.log = Some(PathBuf::from(rest.next()?)),
            "--machine" if parsed.machine.is_none() => parsed.machine = Some(rest.next()?.clone()),
            "--json" if !parsed.json => parsed.json = true,
            _ => return None,
        }
    }
    Some(parsed)
}

/// `cmux carrier connect-stats …`: the exit code.
pub(super) fn run(args: &[String]) -> i32 {
    let Some(args) = parse_args(args) else {
        eprintln!("usage: cmux carrier connect-stats [--log PATH] [--machine vm_…] [--json]");
        return 2;
    };
    let Some(path) = args.log.or_else(super::route_log::default_path) else {
        eprintln!(
            "cmux carrier connect-stats: no state directory, so no connect log; pass --log PATH"
        );
        return 2;
    };
    let text = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(error) => {
            eprintln!("cmux carrier connect-stats: cannot read {}: {error}", path.display());
            return 1;
        }
    };
    let attempts: Vec<Attempt> = text
        .lines()
        .filter_map(parse_line)
        .filter(|a| args.machine.as_ref().is_none_or(|m| &a.machine == m))
        .collect();
    let groups = summarize(&attempts);
    if args.json {
        println!("{}", render_json(&groups));
    } else {
        print!("{}", render_text(&groups));
    }
    0
}

#[cfg(test)]
#[path = "connect_stats_tests.rs"]
mod tests;
