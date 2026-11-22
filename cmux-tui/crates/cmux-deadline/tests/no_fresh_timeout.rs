//! A file that uses `cmux_deadline` takes every timeout from its deadline: a fresh
//! `timeout = <expr> + <const>` there is the stacked-margin bug the type exists for
//! (leo-workspace `tools/test_no_fresh_timeout.py`, the same rule for `tools/`).
//!
//! The scan reads every `.rs` file under `cmux-tui/crates` that names `cmux_deadline` and fails
//! on a line that gives a timeout or wait its own margin: `let timeout = wait + 5s`,
//! `control_timeout: x + GRACE`, `tokio::time::timeout(wait + Duration::from_secs(5), ..)`.
//! Take it from the deadline instead (`d.timeout(..)`, `d.sub(cap)`). A line that must keep one
//! says why after `// fresh-timeout-ok:`.

use std::path::{Path, PathBuf};

use regex::Regex;

const ALLOW: &str = "// fresh-timeout-ok:";

fn patterns() -> [Regex; 2] {
    // The added term: a `Duration::from_*(..)`, a CONSTANT or a number.
    let term = r"(?:Duration::from_\w+\(|\b[A-Z][A-Z0-9_]{2,}\b|\b\d)";
    [
        // A timeout or wait named and given `.. + term`.
        Regex::new(&format!(
            r"(?i)\b\w*(?:timeout|wait)\w*\s*(?::\s*[\w:<>]+\s*)?(?:=|:)\s*[^=;][^;]*?\+\s*{term}"
        ))
        .unwrap(),
        // A timeout call handed `.. + term`.
        Regex::new(&format!(r"\btimeout\(\s*[^;]*?\+\s*{term}")).unwrap(),
    ]
}

/// The lines of `source` that add a fresh margin, as (1-based line, text).
fn findings(source: &str) -> Vec<(usize, String)> {
    let patterns = patterns();
    source
        .lines()
        .enumerate()
        .filter(|(_, line)| {
            let code = line.trim_start();
            !code.starts_with("//") && !line.contains(ALLOW)
        })
        .filter(|(_, line)| patterns.iter().any(|p| p.is_match(line)))
        .map(|(i, line)| (i + 1, line.trim().to_owned()))
        .collect()
}

fn rust_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name();
        if path.is_dir() {
            if name != "target" && name != "node_modules" {
                rust_files(&path, out);
            }
        } else if path.extension().is_some_and(|e| e == "rs") {
            out.push(path);
        }
    }
}

#[test]
fn no_file_that_uses_a_deadline_adds_a_fresh_timeout() {
    let crates = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
    let mut files = Vec::new();
    rust_files(crates, &mut files);
    let this = Path::new(file!()).file_name().unwrap();
    let mut bad = Vec::new();
    let mut read = 0;
    for file in files {
        if file.file_name() == Some(this) {
            continue;
        }
        let Ok(source) = std::fs::read_to_string(&file) else { continue };
        if !source.contains("cmux_deadline") {
            continue;
        }
        read += 1;
        for (line, text) in findings(&source) {
            bad.push(format!("{}:{line}: {text}", file.display()));
        }
    }
    assert!(read > 0, "no file uses cmux_deadline: the scan read nothing");
    assert!(
        bad.is_empty(),
        "a fresh timeout in a deadline'd file; take it from the Deadline (d.timeout, d.sub) or \
         say why after `{ALLOW}`:\n{}",
        bad.join("\n")
    );
}

#[test]
fn the_scan_finds_the_stacked_margin_shapes() {
    for bad in [
        "let timeout = wait + Duration::from_secs(5);",
        "let ticket_timeout: Duration = parent + GRACE;",
        "        control_timeout: config.control_timeout + Duration::from_millis(500),",
        "tokio::time::timeout(wait + Duration::from_secs(5), read).await",
        "let wait = left + 600;",
    ] {
        assert_eq!(findings(bad).len(), 1, "missed: {bad}");
    }
}

#[test]
fn the_scan_passes_what_takes_from_the_deadline() {
    for good in [
        "let timeout = deadline.timeout(Some(CAP), FLOOR, Duration::ZERO);",
        "tokio::time::timeout(deadline.remaining(), read).await",
        "let step = deadline.sub(Duration::from_secs(5));",
        "// let timeout = wait + Duration::from_secs(5);",
        "let timeout = wait + Duration::from_secs(5); // fresh-timeout-ok: the child's own exit",
        "attempts = attempts + 1;",
        "if timeout == other + 1 {",
    ] {
        assert!(findings(good).is_empty(), "flagged: {good}");
    }
}
