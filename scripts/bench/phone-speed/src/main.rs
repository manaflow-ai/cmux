//! Deterministic work budgets for the production phone terminal projection.
use cmux_terminal_projection::{Projection, Segment};
use std::{collections::BTreeMap, env, fs, hint::black_box, path::Path, process::Command};

const CASES: [&str; 6] = [
    "echo-100",
    "echo-10000",
    "stream-100",
    "stream-10000",
    "rotate-100",
    "rotate-10000",
];
const BASELINE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/baseline.tsv");

fn byte_count(segments: &[Segment]) -> usize {
    segments
        .iter()
        .map(|s| match s {
            Segment::Paint(b) | Segment::Reset(b) | Segment::Raw(b) => b.len(),
            Segment::Alternate(_) => 0,
        })
        .sum()
}

// This symbol is the Callgrind collection boundary. Setup and process startup
// are deliberately outside it; keep it out of line even with optimization.
#[inline(never)]
fn phone_icount_measured(p: &mut Projection, operation: &str) -> usize {
    let mut bytes = 0;
    for i in 0..10 {
        let output = match operation {
            "echo" => p.feed(b"x", true),
            "stream" => p.feed(
                b"\x1b[32mcompiled crate\x1b[0m with a long output line for the phone viewport\r\n",
                true,
            ),
            "rotate" => p.set_viewport(
                if i % 2 == 0 { 116 } else { 54 },
                if i % 2 == 0 { 16 } else { 38 },
            ),
            _ => unreachable!(),
        };
        bytes += black_box(byte_count(&output));
    }
    black_box(bytes)
}

fn run_case(case: &str) -> Result<(), String> {
    if !CASES.contains(&case) {
        return Err(format!("unknown case: {case}"));
    }
    let (operation, history) = case.split_once('-').unwrap();
    let history: usize = history.parse().unwrap();
    let mut p = Projection::new(120, 40, history + 100);
    drop(p.set_viewport(54, 38));
    for _ in 0..history {
        drop(p.feed(b"\x1b[32mcompile\x1b[0m a long terminal line that wraps at the phone's columns but fits on the Mac\r\n", false));
    }
    drop(p.feed(b"$ ", true));
    crabgrind::callgrind::start_instrumentation();
    let output = phone_icount_measured(&mut p, operation);
    crabgrind::callgrind::stop_instrumentation();
    if output == 0 {
        return Err(format!("{case}: workload produced no terminal output"));
    }
    println!("{case}: {output} terminal bytes");
    Ok(())
}

fn parse_total(output: &str) -> Result<u64, String> {
    // Callgrind may put summary before totals. Both represent the same run;
    // prefer totals and reject empty/disabled instrumentation.
    ["totals:", "summary:"]
        .into_iter()
        .find_map(|prefix| {
            output
                .lines()
                .find_map(|line| line.strip_prefix(prefix))
                .and_then(|v| v.split_whitespace().next()?.parse::<u64>().ok())
                .filter(|n| *n > 0)
        })
        .ok_or_else(|| "Callgrind returned no positive instruction count".into())
}

fn within_budget(actual: u64, baseline: u64) -> bool {
    baseline > 0 && actual > 0 && u128::from(actual) * 100 <= u128::from(baseline) * 110
}

fn read_baseline() -> Result<BTreeMap<String, u64>, String> {
    let text = fs::read_to_string(BASELINE).map_err(|e| format!("baseline: {e}"))?;
    let mut result = BTreeMap::new();
    for line in text
        .lines()
        .filter(|s| !s.starts_with('#') && !s.is_empty())
    {
        let (name, count) = line.split_once('\t').ok_or("invalid baseline row")?;
        let count = count.parse::<u64>().map_err(|_| "invalid baseline count")?;
        if !CASES.contains(&name) || count == 0 || result.insert(name.into(), count).is_some() {
            return Err(format!("invalid or duplicate baseline case: {name}"));
        }
    }
    if result.len() != CASES.len() {
        return Err("baseline does not contain every case".into());
    }
    Ok(result)
}

fn measure(case: &str, scratch: &Path) -> Result<u64, String> {
    let output = scratch.join(format!("{case}.callgrind"));
    let status = Command::new("valgrind")
        .args([
            "--tool=callgrind",
            "--instr-atstart=no",
            "--collect-atstart=no",
            "--toggle-collect=*phone_icount_measured*",
            "--dump-instr=no",
            "--quiet",
        ])
        .arg(format!("--callgrind-out-file={}", output.display()))
        .arg(env::current_exe().map_err(|e| e.to_string())?)
        .args(["case", case])
        .status()
        .map_err(|e| format!("valgrind: {e}"))?;
    if !status.success() {
        return Err(format!("{case}: Callgrind child failed: {status}"));
    }
    parse_total(&fs::read_to_string(output).map_err(|e| e.to_string())?)
}

fn check(update: bool) -> Result<(), String> {
    // Never silently rebaseline in CI, including when a baseline is missing.
    if update && env::var_os("CI").is_some() {
        return Err("baseline updates are not allowed in CI".into());
    }
    let baseline = if update {
        BTreeMap::new()
    } else {
        read_baseline()?
    };
    let scratch = env::temp_dir().join(format!("cmux-phone-speed-{}", std::process::id()));
    fs::create_dir(&scratch).map_err(|e| e.to_string())?;
    let mut measured = BTreeMap::new();
    let mut failures = Vec::new();
    for case in CASES {
        let count = measure(case, &scratch)?;
        println!("{case}\t{count} Ir / 10 operations");
        if !update && !within_budget(count, baseline[case]) {
            failures.push(format!("{case}: {count} exceeds {} + 10%", baseline[case]));
        }
        measured.insert(case, count);
    }
    // A large session must not make each interaction grow with its history.
    for operation in ["echo", "stream", "rotate"] {
        let small = measured[format!("{operation}-100").as_str()];
        let large = measured[format!("{operation}-10000").as_str()];
        if u128::from(large) * 100 > u128::from(small) * 120 {
            failures.push(format!(
                "{operation}: long history exceeds small history + 20% ({large}/{small})"
            ));
        }
    }
    if !failures.is_empty() {
        return Err(failures.join("\n"));
    }
    if update {
        let rows = measured
            .iter()
            .map(|(case, n)| format!("{case}\t{n}\n"))
            .collect::<String>();
        fs::write(
            BASELINE,
            format!(
                "# Callgrind Ir, 10 operations per case. See README.md for provenance.\n{rows}"
            ),
        )
        .map_err(|e| e.to_string())?;
    }
    // This directory was created exclusively by this process.
    fs::remove_dir_all(scratch).map_err(|e| e.to_string())?;
    println!("PASS: deterministic terminal work budgets; physical-device calibration pending");
    Ok(())
}

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    let result = match args.as_slice() {
        [mode, case] if mode == "case" => run_case(case),
        [mode] if mode == "check" => check(false),
        [mode] if mode == "update" => check(true),
        _ => Err("usage: cmux-phone-speed check | update | case NAME".into()),
    };
    if let Err(e) = result {
        eprintln!("phone-speed: {e}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn doubled_work_fails_budget() {
        assert!(within_budget(110, 100));
        assert!(!within_budget(111, 100));
        assert!(!within_budget(200, 100));
        assert!(!within_budget(0, 100));
        assert!(!within_budget(100, 0));
    }
    #[test]
    fn missing_collection_is_failure() {
        assert!(parse_total("summary: 0\ntotals: 0\n").is_err());
        assert!(parse_total("events: Ir\n").is_err());
        assert_eq!(parse_total("summary: 0\ntotals: 42\n").unwrap(), 42);
    }
}
