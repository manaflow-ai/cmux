//! A few rows of each cmux-source-scan check, through its public API, so `cargo test -p acpmux
//! --lib` (which PR CI runs) is red when a rule breaks: `cargo test -p cmux-source-scan`, which
//! holds every row, is not in PR CI. The rows are in source_scan_smoke_rows.txt. Also holds the
//! timing check's KNOWN_MISSES: each row stays a miss, and the tree holds exactly the instances
//! of the shape marked `in_tree`.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use cmux_source_scan::nextest::FileTests;
use cmux_source_scan::test_hooks::judge_source;
use cmux_source_scan::timing_ratio::{KNOWN_MISSES, scan_text, scan_with, spread_bounds};

const ROWS: &str = include_str!("source_scan_smoke_rows.txt");
const HOOKS_REL: &str = "cmux-tui/crates/acpmux/src/smoke.rs";
const TIMING_REL: &str = "cmux-tui/crates/demo/tests/timing.rs";
const PRELUDE: &str = "use std::time::{Duration, Instant};\n\nfn helper() -> Duration {\n    let t = Instant::now();\n    t.elapsed()\n}\n";

struct Row {
    check: String,
    verdict: String,
    what: String,
    words: String,
    title: String,
    source: String,
}

fn rows() -> Vec<Row> {
    let mut out: Vec<Row> = Vec::new();
    for line in ROWS.lines() {
        if let Some(head) = line.strip_prefix("=== ") {
            let parts: Vec<&str> = head.splitn(4, " :: ").collect();
            assert_eq!(parts.len(), 4, "a row head is `CHECK VERDICT :: WHAT :: WORDS :: TITLE`");
            let (check, verdict) = parts[0].split_once(' ').unwrap_or((parts[0], ""));
            out.push(Row {
                check: check.to_string(),
                verdict: verdict.to_string(),
                what: parts[1].to_string(),
                words: parts[2].to_string(),
                title: parts[3].to_string(),
                source: String::new(),
            });
        } else if let Some(row) = out.last_mut() {
            row.source.push_str(line);
            row.source.push('\n');
        }
    }
    out
}

/// What the row's check says, or None when it says what the row does.
fn judge(row: &Row) -> Option<String> {
    let found: Vec<String> = match row.check.as_str() {
        "test_hooks" => judge_source(HOOKS_REL, &row.source)
            .iter()
            .filter(|f| {
                row.verdict != "refused" || (f.name == row.what && f.why.contains(&row.words))
            })
            .map(ToString::to_string)
            .collect(),
        "timing" => match scan_text(
            TIMING_REL,
            &format!("{PRELUDE}{}", row.source),
            &|_| true,
            &FileTests::Loose,
        ) {
            Ok(found) => found,
            Err(error) => return Some(format!("does not parse: {error}")),
        }
        .iter()
        .filter(|f| row.verdict != "flagged" || (f.text == row.what && f.kind == row.words))
        .map(ToString::to_string)
        .collect(),
        other => return Some(format!("no check `{other}`")),
    };
    match row.verdict.as_str() {
        "refused" | "flagged" if found.is_empty() => {
            Some(format!("no finding `{} {}`", row.what, row.words))
        }
        "passes" | "clean" if !found.is_empty() => Some(format!("found {found:?}")),
        "refused" | "flagged" | "passes" | "clean" => None,
        other => Some(format!("no verdict `{other}`")),
    }
}

#[test]
fn the_source_scan_checks_judge_their_smoke_rows() {
    let rows = rows();
    let count = |check: &str, verdict: &str| {
        rows.iter().filter(|r| r.check == check && r.verdict == verdict).count()
    };
    for (check, verdict) in [
        ("test_hooks", "refused"),
        ("test_hooks", "passes"),
        ("timing", "flagged"),
        ("timing", "clean"),
    ] {
        assert!(count(check, verdict) >= 3, "fewer than 3 `{check} {verdict}` rows");
    }
    let wrong: Vec<String> = rows
        .iter()
        .filter_map(|row| {
            judge(row).map(|why| format!("{} {} ({}): {why}", row.check, row.verdict, row.title))
        })
        .collect();
    assert!(wrong.is_empty(), "rows of cmux-source-scan judged otherwise:\n{}", wrong.join("\n"));
}

#[test]
fn each_known_miss_of_the_timing_check_stays_a_miss() {
    assert!(!KNOWN_MISSES.is_empty());
    for miss in KNOWN_MISSES {
        let rel = miss.site.split(' ').next().unwrap_or_default();
        let caught =
            scan_text(rel, miss.row, &|_| true, &FileTests::Loose).expect("the row parses");
        assert!(
            caught.is_empty(),
            "the timing check now catches a KNOWN_MISSES row ({}): take it out of KNOWN_MISSES \
             and the shape's ratchet, and keep the row as a flagged row: {caught:?}",
            miss.site
        );
        let shape =
            spread_bounds(rel, miss.row, &|_| true, &FileTests::Loose).expect("the row parses");
        assert_eq!(
            shape.len(),
            1,
            "the row of {} is not of the shape spread_bounds counts: {shape:?}",
            miss.site
        );
    }
}

#[test]
fn the_tree_holds_no_new_instance_of_a_known_miss() {
    let checkout = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
    let roots: Vec<PathBuf> = vec![checkout.join("cmux-tui/crates")];
    let scan = scan_with(&checkout, &roots, spread_bounds).expect("cmux-tui/crates scans");
    let sites: BTreeSet<String> =
        scan.found.iter().map(|f| format!("{} {} {}", f.rel, f.test, f.text)).collect();
    let known: BTreeSet<String> =
        KNOWN_MISSES.iter().filter(|m| m.in_tree).map(|m| m.site.to_string()).collect();
    let new: Vec<&String> = sites.difference(&known).collect();
    let gone: Vec<&String> = known.difference(&sites).collect();
    assert!(
        new.is_empty(),
        "a new instance of a shape the timing check misses (KNOWN_MISSES in \
         cmux-source-scan/src/timing_ratio.rs): bound a timing the check reads, or move the bound \
         to an #[ignore]d test: {new:?}"
    );
    assert!(
        gone.is_empty(),
        "these KNOWN_MISSES sites are gone from the tree; set their in_tree to false: {gone:?}"
    );
}
