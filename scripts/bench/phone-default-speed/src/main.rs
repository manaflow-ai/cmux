//! Deterministic default Mac-grid Ghostty terminal-core work budgets.
use ghostty_vt::{Callbacks, CellWidth, ColorSpec, RenderFrame, RenderState, Terminal};
use std::{collections::BTreeMap, env, fs, hint::black_box, path::Path, process::Command};

const CASES: [&str; 4] = [
    "primary-100",
    "primary-10000",
    "alternate-100",
    "alternate-10000",
];
const BASELINE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/baseline.tsv");

// Collection starts after seeding history and ends before teardown. The same
// pinned libghostty terminal core backs the app; Metal/UIKit are not exercised.
#[inline(never)]
fn phone_default_measured(
    terminal: &mut Terminal,
    render: &mut RenderState,
    operation: &str,
) -> (usize, RenderFrame) {
    let mut characters = 0;
    let mut last_frame = None;
    for iteration in 0..10 {
        match operation {
            "primary" => {
                terminal.vt_write(b"\x1b[32mcompile\x1b[0m crate: unicode \xe7\x95\x8c \r\n")
            }
            "alternate" => terminal.vt_write(if iteration % 2 == 0 {
                b"\x1b[12;1H\x1b[2K\x1b[36mfull-screen editor: changed \xe7\x95\x8c line\x1b[0m"
            } else {
                b"\x1b[12;1H\x1b[2K\x1b[35mfull-screen editor: another \xe7\x95\x8c line\x1b[0m"
            }),
            _ => unreachable!(),
        }
        render
            .update(terminal)
            .expect("production Ghostty render update");
        let frame = render.build_frame().expect("production Ghostty frame");
        assert_eq!(frame.size, (120, 40));
        // Real protocol render commands, rather than a substitute parser.
        let runs = frame.runs();
        characters += black_box(
            runs.iter()
                .flatten()
                .map(|run| run.text.len())
                .sum::<usize>(),
        );
        last_frame = Some(frame);
    }
    (black_box(characters), last_frame.expect("measured frame"))
}

fn run_case(case: &str) -> Result<(), String> {
    if !CASES.contains(&case) {
        return Err(format!("unknown case: {case}"));
    }
    let (operation, lines) = case.split_once('-').unwrap();
    let lines: usize = lines.parse().unwrap();
    let mut terminal = Terminal::new(120, 40, usize::MAX, Callbacks::default())
        .map_err(|e| format!("terminal: {e:?}"))?;
    let mut render = RenderState::new().map_err(|e| format!("render: {e:?}"))?;
    // The constructor takes a byte budget, not a row count. Retain the entire
    // bounded fixture, and fill the viewport before seeding the named history.
    for _ in 0..lines + 39 {
        terminal.vt_write(
            b"\x1b[32mcompile\x1b[0m previous terminal output at the unchanged Mac grid\r\n",
        );
    }
    assert_eq!(
        terminal.scrollback_rows(),
        lines,
        "retained fixture history"
    );
    if operation == "alternate" {
        terminal.vt_write(b"\x1b[?1049h\x1b[2J\x1b[Hfull-screen editor");
    }
    render
        .update(&mut terminal)
        .map_err(|e| format!("initial update: {e:?}"))?;
    drop(
        render
            .build_frame()
            .map_err(|e| format!("initial frame: {e:?}"))?,
    );
    crabgrind::callgrind::start_instrumentation();
    let (output, frame) = phone_default_measured(&mut terminal, &mut render, operation);
    crabgrind::callgrind::stop_instrumentation();
    if output == 0 {
        return Err(format!("{case}: workload produced no terminal output"));
    }
    // Validate the actual final measured snapshot after collection has stopped.
    // A no-op decoder/update must not pass simply because it did less work.
    let rows = frame.styled_rows();
    let text: Vec<String> = rows
        .iter()
        .map(|row| row.iter().map(|cell| cell.text.as_str()).collect())
        .collect();
    match operation {
        "primary" => {
            assert_eq!(
                text.iter()
                    .filter(|line| line.contains("compile crate: unicode 界"))
                    .count(),
                10
            );
            assert!(rows
                .iter()
                .any(|row| row[0].text == "c" && row[0].fg == ColorSpec::Palette(2)));
        }
        "alternate" => {
            assert!(text[11].contains("full-screen editor: another 界 line"));
            assert_eq!(rows[11][0].fg, ColorSpec::Palette(5));
            assert_eq!(frame.cursor.expect("alternate cursor").y, 11);
        }
        _ => unreachable!(),
    }
    assert!(rows
        .iter()
        .flat_map(|row| row.iter())
        .any(|cell| cell.text == "界" && cell.width == CellWidth::Wide));
    println!("{case}: {output} render-command bytes");
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
            "--toggle-collect=*phone_default_measured*",
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
    let scratch = env::temp_dir().join(format!("cmux-phone-default-speed-{}", std::process::id()));
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
    for operation in ["primary", "alternate"] {
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
        _ => Err("usage: cmux-phone-default-speed check | update | case NAME".into()),
    };
    if let Err(e) = result {
        eprintln!("phone-default-speed: {e}");
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
