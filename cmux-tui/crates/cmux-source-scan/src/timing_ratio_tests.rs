//! The rows of the timing-ratio check, in timing_ratio_rows.txt: the rows of cmuxterm-hq's
//! tools/agent-guards/test_rust_timing_ratio.py (hq#9512) and the review of hq#9478, each run on
//! a cmux-shaped checkout as the CLI scans one. F4 (no scan is not a clean scan) is below.

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

use super::*;
use crate::nextest::{FileTests, Profiles, eval_filter, parse_filter};

const ROWS: &str = include_str!("timing_ratio_rows.txt");
const PRELUDE: &str = "use std::time::{Duration, Instant};\n\nfn helper() -> Duration {\n    let t = Instant::now();\n    t.elapsed()\n}\n";

struct Row {
    verdict: String,
    what: String,
    kind: String,
    title: String,
    rust: String,
    bare: bool,
    nextest: Option<String>,
}

fn rows() -> Vec<Row> {
    let mut out: Vec<Row> = Vec::new();
    let mut section = "rust";
    for line in ROWS.lines() {
        if let Some(head) = line.strip_prefix("=== ") {
            let parts: Vec<&str> = head.splitn(4, " :: ").collect();
            assert_eq!(parts.len(), 4, "a row head is `VERDICT :: WHAT :: KIND :: TITLE`: {head}");
            out.push(Row {
                verdict: parts[0].to_string(),
                what: parts[1].to_string(),
                kind: parts[2].to_string(),
                title: parts[3].to_string(),
                rust: String::new(),
                bare: false,
                nextest: None,
            });
            section = "rust";
            continue;
        }
        let Some(row) = out.last_mut() else {
            continue;
        };
        match line {
            "--- rust" => section = "rust",
            "--- bare" => {
                section = "rust";
                row.bare = true;
            }
            "--- nextest" => {
                section = "nextest";
                row.nextest.get_or_insert_with(String::new);
            }
            _ if section == "nextest" => {
                let toml = row.nextest.get_or_insert_with(String::new);
                toml.push_str(line);
                toml.push('\n');
            }
            _ => {
                row.rust.push_str(line);
                row.rust.push('\n');
            }
        }
    }
    out
}

/// A temporary cmux-shaped checkout, removed on drop.
struct Checkout(PathBuf);

impl Checkout {
    fn new() -> Checkout {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let n = NEXT.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir()
            .join(format!("cmux-source-scan-timing-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).expect("make the checkout");
        Checkout(root)
    }

    fn write(&self, rel: &str, text: &str) {
        let path = self.0.join(rel);
        std::fs::create_dir_all(path.parent().expect("a parent")).expect("make the dir");
        std::fs::write(path, text).expect("write");
    }

    /// Crate `demo` with tests/timing.rs, and cmux-tui/.config/nextest.toml when given.
    fn demo(timing_rs: &str, nextest: Option<&str>) -> Checkout {
        let co = Checkout::new();
        co.write(
            "cmux-tui/crates/demo/Cargo.toml",
            "[package]\nname = \"demo\"\nversion = \"0.1.0\"\n",
        );
        co.write("cmux-tui/crates/demo/src/lib.rs", "pub fn work() {}\n");
        co.write("cmux-tui/crates/demo/tests/timing.rs", timing_rs);
        if let Some(toml) = nextest {
            co.write("cmux-tui/.config/nextest.toml", toml);
        }
        co
    }
}

impl Drop for Checkout {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Why a row fails, or None when the scan says what the row does.
fn judge_row(row: &Row) -> Option<String> {
    let timing_rs = if row.bare { row.rust.clone() } else { format!("{PRELUDE}{}", row.rust) };
    let co = Checkout::demo(&timing_rs, row.nextest.as_deref());
    let scan = match scan(&co.0, &[]) {
        Ok(scan) => scan,
        Err(error) => return Some(format!("scan failed: {error}")),
    };
    if !scan.unparsed.is_empty() {
        return Some(format!("does not parse: {:?}", scan.unparsed));
    }
    let lines: Vec<String> = scan.found.iter().map(ToString::to_string).collect();
    let shown = lines.join("\n");
    match row.verdict.as_str() {
        "flagged" => {
            let Some(hit) = lines.iter().find(|l| l.contains(&row.what)) else {
                return Some(format!("no finding names `{}`:\n{shown}", row.what));
            };
            // Exactly what the row names: one more finding fails it as a missing one does.
            if lines.len() != 1 {
                return Some(format!("found more than `{}`:\n{shown}", row.what));
            }
            (row.kind != "-" && !hit.contains(&row.kind))
                .then(|| format!("want kind {}, got {hit}", row.kind))
        }
        "clean" => (!lines.is_empty()).then(|| format!("flagged wrongly:\n{shown}")),
        "tests" => {
            let want: BTreeSet<&str> =
                row.what.split(',').filter(|n| !n.is_empty() && *n != "-").collect();
            let got: BTreeSet<&str> = scan.found.iter().map(|f| f.test.as_str()).collect();
            (got != want).then(|| format!("want {want:?}, got {got:?}:\n{shown}"))
        }
        other => Some(format!("no such verdict: {other}")),
    }
}

#[test]
fn every_row_is_judged_as_it_says() {
    let rows = rows();
    assert!(rows.len() >= 40, "the row table reads {} rows", rows.len());
    let failed: Vec<String> = rows
        .iter()
        .filter_map(|row| {
            judge_row(row)
                .map(|why| format!("{} ({} `{}`): {why}", row.title, row.verdict, row.what))
        })
        .collect();
    assert!(
        failed.is_empty(),
        "{} of {} rows failed:\n{}",
        failed.len(),
        rows.len(),
        failed.join("\n")
    );
}

/// #41567 review F1: a `flagged` row names the finding its source holds, so one more finding
/// fails it.
#[test]
fn a_flagged_row_fails_on_a_finding_it_does_not_name() {
    let row = Row {
        verdict: "flagged".to_string(),
        what: "p95 < BUDGET_MS".to_string(),
        kind: "percentile bound".to_string(),
        title: "a fixture".to_string(),
        rust: "#[test]\nfn two_bounds() {\n    let p95 = helper();\n    assert!(p95 < BUDGET_MS);\n    let (busy, idle) = (helper(), helper());\n    assert!(busy < idle * 4);\n}\n".to_string(),
        bare: false,
        nextest: None,
    };
    let why = judge_row(&row);
    assert!(
        why.as_deref().is_some_and(|w| w.contains("busy < idle * 4")),
        "busy < idle * 4 went unnamed: {why:?}"
    );
}

#[test]
fn a_finding_names_its_file_line_kind_test_and_comparison() {
    let source = format!(
        "{PRELUDE}\n#[test]\nfn t() {{\n    let p95_us = helper().as_micros();\n    assert!(\n        p95_us\n            < 5_000\n    );\n}}\n"
    );
    let found = scan_text("x.rs", &source, &|_: &TestId| true, &FileTests::Loose).expect("parses");
    assert_eq!(
        found.iter().map(ToString::to_string).collect::<Vec<_>>(),
        ["x.rs:12: percentile bound in default-run test `t`: p95_us < 5_000"]
    );
}

// hq#9512 F4: no scan is not a clean scan.

#[test]
fn a_missing_checkout_or_scan_root_is_an_error() {
    let co = Checkout::new();
    assert!(scan(&co.0, &[]).is_err(), "no cmux-tui/crates");
    assert!(scan(&co.0, &[co.0.join("no-such-dir")]).is_err(), "a missing root");
    assert!(scan(&co.0.join("no-such-checkout"), &[]).is_err(), "a missing checkout");
}

#[test]
fn an_empty_scan_root_is_an_error() {
    let co = Checkout::new();
    std::fs::create_dir_all(co.0.join("cmux-tui/crates/demo")).expect("dir");
    assert!(scan(&co.0, &[]).is_err());
}

#[test]
fn a_nextest_config_that_does_not_parse_is_an_error() {
    let co = Checkout::demo(
        PRELUDE,
        Some(
            "[[profile.default.overrides]]\nfilter = 'test(=a'\nthreads-required = 'num-test-threads'\n",
        ),
    );
    assert!(scan(&co.0, &[]).is_err());
}

// Review of cmux#41523, F2: an override whose `/regex/` does not compile read as matching no
// test, so the test it meant to run alone was judged as running beside others (or the reverse
// through `not`); the scan must fail as it does on a filter that does not parse.
#[test]
fn a_nextest_filter_with_a_bad_regex_is_an_error() {
    let co = Checkout::demo(
        PRELUDE,
        Some(
            "[[profile.default.overrides]]\nfilter = 'test(/timing(/)'\nthreads-required = 'num-test-threads'\n",
        ),
    );
    let error = scan(&co.0, &[]).expect_err("a bad regex is no clean scan");
    assert!(error.contains("is no regex"), "{error}");
}

// The filterset reader on its own: three-valued, nextest's default matchers.

#[test]
fn filtersets_match_as_nextest_reads_them() {
    let t = TestId {
        name: "inner::alone_case".into(),
        binary_id: Some("demo::timing".into()),
        binary: Some("timing".into()),
        package: Some("demo".into()),
        kind: Some("test".into()),
    };
    let eval = |f: &str| eval_filter_text(f, &t);
    assert_eq!(eval("test(alone)"), Some(true), "test() contains by default");
    assert_eq!(eval("test(=alone_case)"), Some(false), "= is the whole name");
    assert_eq!(eval("test(=inner::alone_case)"), Some(true));
    assert_eq!(eval("binary_id(demo::*)"), Some(true), "binary_id() globs by default");
    assert_eq!(eval("binary_id(demo)"), Some(false));
    assert_eq!(eval("package(demo) - test(/case$/)"), Some(false));
    assert_eq!(eval("kind(test) and not binary(=other)"), Some(true));
    assert_eq!(eval("deps(demo) | test(=x)"), None, "deps() is not known to a source scan");
    assert_eq!(eval("deps(demo) & test(=x)"), Some(false));
    assert_eq!(eval("all() + none()"), Some(true));
    assert!(parse_filter("test(=a) |").is_err());
    assert!(parse_filter("test(a").is_err());
    // Review of cmux#41523, F2: a regex that does not compile was a filter that matched nothing.
    assert!(parse_filter("test(/(unclosed/)").is_err(), "a bad regex is an error");
    assert!(parse_filter("not binary_id(/[/) | test(=a)").is_err());
}

fn eval_filter_text(text: &str, t: &TestId) -> Option<bool> {
    eval_filter(&parse_filter(text).expect("parses"), t)
}

#[test]
fn a_profile_with_one_test_thread_runs_every_test_alone() {
    let profiles = Profiles::parse("[profile.default]\ntest-threads = 1\n").expect("parses");
    assert!(!profiles.runs_beside_others(&TestId { name: "x".into(), ..TestId::default() }));
    let none = Profiles::parse("").expect("parses");
    assert!(none.runs_beside_others(&TestId { name: "x".into(), ..TestId::default() }));
}

#[test]
fn a_file_names_its_tests_by_crate_layout() {
    let co = Checkout::demo(PRELUDE, None);
    co.write("cmux-tui/crates/demo/src/hub/peer_tests.rs", "");
    co.write("cmux-tui/crates/demo/benches/b.rs", "");
    let root = co.0.canonicalize().expect("exists");
    let mut layout = Layout::default();
    let id = |layout: &mut Layout, rel: &str| -> Option<TestId> {
        match layout.file_tests(&root.join(rel), &root).expect("the checkout reads") {
            FileTests::NotRun => None,
            tests => Some(tests.id(&["m".to_string()], "f")),
        }
    };
    let lib = id(&mut layout, "cmux-tui/crates/demo/src/hub/peer_tests.rs").expect("runs");
    assert_eq!(lib.name, "hub::peer_tests::m::f");
    assert_eq!(lib.binary_id.as_deref(), Some("demo"));
    let integration = id(&mut layout, "cmux-tui/crates/demo/tests/timing.rs").expect("runs");
    assert_eq!(integration.name, "m::f");
    assert_eq!(integration.binary_id.as_deref(), Some("demo::timing"));
    assert!(id(&mut layout, "cmux-tui/crates/demo/benches/b.rs").is_none());
}

// Review of cmux#41567, F1: a wrapper macro (`dbg!`, `vec!`, a user macro over statements) hid a
// known miss from spread_bounds, so its ratchet over the tree judged nothing there.

/// The start_mode known miss with `from..=to` of its lines (from `let (g50` to its assert) put
/// through `wrap`, and the comparison spread_bounds should name.
fn wrapped_known_miss(wrap: impl Fn(&str) -> String) -> String {
    let row = KNOWN_MISSES[0].row;
    let from = row.find("    let (g50, g95, gmax)").expect("the row binds the spread");
    let assert = "    assert!(g50 < 500.0, \"p50 {g50} ms\");\n";
    let to = row.find(assert).expect("the row bounds g50") + assert.len();
    format!("{}{}{}", &row[..from], wrap(&row[from..to]), &row[to..])
}

#[test]
fn spread_bounds_reads_the_bodies_of_wrapper_macros() {
    let cases: [(&str, String, &str); 10] = [
        (
            "dbg!({ .. })",
            wrapped_known_miss(|b| format!("    dbg!({{\n{b}    }});\n")),
            "g50 < 500.0",
        ),
        (
            "vec![{ .. }]",
            wrapped_known_miss(|b| format!("    let _ = vec![{{\n{b}        0\n    }}];\n")),
            "g50 < 500.0",
        ),
        (
            "a user macro over statements",
            wrapped_known_miss(|b| format!("    measured! {{\n{b}    }}\n")),
            "g50 < 500.0",
        ),
        (
            "format!(.., {{ .. }})",
            wrapped_known_miss(|b| format!("    let _ = format!(\"{{:?}}\", {{\n{b}    }});\n")),
            "g50 < 500.0",
        ),
        (
            "dbg!(g50) as the bounded side",
            wrapped_known_miss(|b| b.replace("assert!(g50 < 500.0", "assert!(dbg!(g50) < 500.0")),
            "dbg!(g50) < 500.0",
        ),
        // Review of cmux#41581, F1: a spread binding whose initializer wraps the call.
        (
            "let (..) = dbg!(spread(..))",
            wrapped_known_miss(|b| b.replace("= spread(&mut gate)", "= dbg!(spread(&mut gate))")),
            "g50 < 500.0",
        ),
        (
            "let (..) = (spread(..))",
            wrapped_known_miss(|b| b.replace("= spread(&mut gate)", "= (spread(&mut gate))")),
            "g50 < 500.0",
        ),
        (
            "let (..) = *&spread(..).clone()",
            wrapped_known_miss(|b| {
                b.replace("= spread(&mut gate)", "= *&spread(&mut gate).clone()")
            }),
            "g50 < 500.0",
        ),
        (
            "let (..) = dbg!((spread(..)).to_owned())",
            wrapped_known_miss(|b| {
                b.replace("= spread(&mut gate)", "= dbg!((spread(&mut gate)).to_owned())")
            }),
            "g50 < 500.0",
        ),
        (
            "let (..): (f64, f64, f64) = spread(..)",
            wrapped_known_miss(|b| b.replace("gmax) = spread", "gmax): (f64, f64, f64) = spread")),
            "g50 < 500.0",
        ),
    ];
    let mut failed = Vec::new();
    for (what, row, cmp) in &cases {
        let found = spread_bounds("x.rs", row, &|_: &TestId| true, &FileTests::Loose)
            .unwrap_or_else(|e| panic!("{what}: does not parse: {e}\n{row}"));
        let texts: Vec<&str> = found.iter().map(|f| f.text.as_str()).collect();
        if texts != [*cmp] {
            failed.push(format!("{what}: want [{cmp}], got {texts:?}"));
        }
    }
    assert!(failed.is_empty(), "spread_bounds misses a wrapped known miss:\n{}", failed.join("\n"));
}
