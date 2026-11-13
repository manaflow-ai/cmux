//! A few rows of each cmux-source-scan check, through its public API, so `cargo test -p acpmux
//! --lib` (which PR CI runs) is red when a rule breaks: `cargo test -p cmux-source-scan`, which
//! holds every row, is not in PR CI. The rows are in source_scan_smoke_rows.txt. Also holds the
//! timing check's KNOWN_MISSES: each row stays a miss, and the tree holds exactly the instances
//! of the shape marked `in_tree`.

use std::path::{Path, PathBuf};

use cmux_source_scan::nextest::FileTests;
use cmux_source_scan::rows::unmatched;
use cmux_source_scan::test_hooks::judge_source;
use cmux_source_scan::timing_ratio::{KNOWN_MISSES, Scan, scan_text, scan_with, spread_bounds};

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

/// What the row's check says, or None when it says what the row does: a refused or flagged row
/// holds exactly the one finding it names, so a missing finding, another one, or a second copy
/// of the named one (#42341 F1) fails it.
fn judge(row: &Row) -> Option<String> {
    // Each finding, and whether it is the one the row names.
    let found: Vec<(bool, String)> = match row.check.as_str() {
        "test_hooks" => judge_source(HOOKS_REL, &row.source)
            .iter()
            .map(|f| (f.name == row.what && f.why.contains(&row.words), f.to_string()))
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
        .map(|f| (f.text == row.what && f.kind == row.words, f.to_string()))
        .collect(),
        other => return Some(format!("no check `{other}`")),
    };
    let named: &[()] = match row.verdict.as_str() {
        "refused" | "flagged" => &[()],
        "passes" | "clean" => &[],
        other => return Some(format!("no verdict `{other}`")),
    };
    let left = unmatched(named, &found, |(), (hit, _)| *hit);
    let all: Vec<&String> = found.iter().map(|(_, f)| f).collect();
    if !left.missing.is_empty() {
        return Some(format!("no finding `{} {}`; found {all:?}", row.what, row.words));
    }
    (!left.extra.is_empty()).then(|| {
        let extra: Vec<&String> = left.extra.iter().map(|(_, f)| f).collect();
        if named.is_empty() {
            format!("found {extra:?}")
        } else {
            format!("found more than `{} {}`: {extra:?}", row.what, row.words)
        }
    })
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

/// What is wrong with the tree's scan against the KNOWN_MISSES sites marked `in_tree`: one line
/// each, none when the scan parsed every file and holds exactly them, each as many times as it
/// is listed (a second instance of a site is new, #42341 F1).
fn tree_drift(scan: &Scan, known: &[String]) -> Vec<String> {
    let sites: Vec<String> =
        scan.found.iter().map(|f| format!("{} {} {}", f.rel, f.test, f.text)).collect();
    let left = unmatched(known, &sites, |k, s| k == s);
    let new: Vec<&String> = left.extra;
    let gone: Vec<&String> = left.missing;
    let mut out = Vec::new();
    if !scan.unparsed.is_empty() {
        out.push(format!(
            "files the scan could not parse, so it judged them no further: {:?}",
            scan.unparsed
        ));
    }
    if !new.is_empty() {
        out.push(format!(
            "a new instance of a shape the timing check misses (KNOWN_MISSES in \
             cmux-source-scan/src/timing_ratio.rs): bound a timing the check reads, or move the \
             bound to an #[ignore]d test: {new:?}"
        ));
    }
    if !gone.is_empty() {
        out.push(format!(
            "these KNOWN_MISSES sites are gone from the tree; set their in_tree to false: {gone:?}"
        ));
    }
    out
}

#[test]
fn the_tree_holds_no_new_instance_of_a_known_miss() {
    let checkout = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
    let roots: Vec<PathBuf> = vec![checkout.join("cmux-tui/crates")];
    let scan = scan_with(&checkout, &roots, spread_bounds).expect("cmux-tui/crates scans");
    let known: Vec<String> =
        KNOWN_MISSES.iter().filter(|m| m.in_tree).map(|m| m.site.to_string()).collect();
    let drift = tree_drift(&scan, &known);
    assert!(drift.is_empty(), "{}", drift.join("\n"));
}

fn row(check: &str, verdict: &str, what: &str, words: &str, source: &str) -> Row {
    Row {
        check: check.to_string(),
        verdict: verdict.to_string(),
        what: what.to_string(),
        words: words.to_string(),
        title: "a fixture".to_string(),
        source: source.to_string(),
    }
}

/// #41567 review F1: a row names the one finding its source holds, so a finding it does not
/// name fails it, as a missing one does.
#[test]
fn a_row_fails_on_a_finding_it_does_not_name() {
    let hooks = row(
        "test_hooks",
        "refused",
        "H",
        "closure",
        "type A = Mutex<Option<B>>;\ntype B = Box<dyn Fn()>;\nstatic H: A = Mutex::new(None);\nstatic G: A = Mutex::new(None);\n",
    );
    let why = judge(&hooks);
    assert!(why.as_deref().is_some_and(|w| w.contains(": G: ")), "G went unnamed: {why:?}");
    let timing = row(
        "timing",
        "flagged",
        "p95 < BUDGET_MS",
        "percentile bound",
        "#[test]\nfn two_bounds() {\n    let p95 = helper();\n    assert!(p95 < BUDGET_MS);\n    let (busy, idle) = (helper(), helper());\n    assert!(busy < idle * 4);\n}\n",
    );
    let why = judge(&timing);
    assert!(
        why.as_deref().is_some_and(|w| w.contains("busy < idle * 4")),
        "busy < idle * 4 went unnamed: {why:?}"
    );
}

/// #42341 review F1: a row names its finding once, so a second static of the same name on the
/// same line (another module's) fails it.
#[test]
fn a_row_fails_on_a_second_copy_of_its_finding() {
    let hooks = row(
        "test_hooks",
        "refused",
        "H",
        "closure",
        "type A = std::sync::OnceLock<fn(bool)>;\nstatic H: A = A::new(); mod m { static H: super::A = super::A::new(); }\n",
    );
    let why = judge(&hooks);
    assert!(why.as_deref().is_some_and(|w| w.contains("found more")), "the second H: {why:?}");
}

/// #42341 review F1: the tree holds exactly the instances of each known miss, so a second
/// instance of a known site (the same test and comparison again) fails the ratchet.
#[test]
fn the_tree_check_fails_on_a_second_instance_of_a_known_site() {
    let instance = |line| cmux_source_scan::timing_ratio::Finding {
        rel: "cmux-tui/crates/demo/tests/timing.rs".to_string(),
        line,
        kind: "spread bound",
        test: "t".to_string(),
        text: "g50 < 500.0".to_string(),
    };
    let scan = Scan { found: vec![instance(3), instance(4)], files: 1, ..Scan::default() };
    let known = ["cmux-tui/crates/demo/tests/timing.rs t g50 < 500.0".to_string()];
    let drift = tree_drift(&scan, &known);
    assert!(!drift.is_empty(), "a second instance of a known site passed");
}

/// #41567 review F2: a file the scan could not parse was judged no further, so the tree check
/// fails naming it rather than reading it as clean.
#[test]
fn the_tree_check_fails_on_a_file_it_could_not_parse() {
    let scan = Scan {
        unparsed: vec!["cmux-tui/crates/demo/src/broken.rs: expected `;`".to_string()],
        files: 1,
        ..Scan::default()
    };
    let drift = tree_drift(&scan, &[]);
    assert!(drift.iter().any(|d| d.contains("demo/src/broken.rs")), "drift: {drift:?}");
}
