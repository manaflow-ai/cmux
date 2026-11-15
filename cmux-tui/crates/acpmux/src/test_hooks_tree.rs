//! The crate adds no process-wide test hook (cmux#41350): the test-hooks check of
//! cmux-source-scan (crates/cmux-source-scan/src/test_hooks.rs) over this crate's `src`, run by
//! `cargo test -p acpmux --lib`. Its rows and the property are in that crate.

use std::path::Path;
use std::time::Instant;

use cmux_source_scan::rows::unmatched;
use cmux_source_scan::source::rust_files;
use cmux_source_scan::test_hooks::{Finding, judge_tree};

const SRC: &str = "cmux-tui/crates/acpmux/src/";

/// The statics this check refuses that are not fixed yet, `path NAME` from `src/`: each is to be
/// fixed or marked. A new finding fails this test, and so does a row whose static no longer has
/// one (take the row out). Empty since the check follows paths into the crate's other files.
const KNOWN: &[&str] = &[];

#[test]
fn the_crate_adds_no_process_wide_test_hook() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    let started = Instant::now();
    // A source the check cannot read fails here, naming it, rather than reading as clean.
    let files = rust_files(&dir.join("src")).unwrap_or_else(|e| panic!("{e}")).len();
    let found = judge_tree(dir).unwrap_or_else(|e| panic!("{e}"));
    eprintln!("test hooks: {files} files, {} findings in {:?}", found.len(), started.elapsed());
    for finding in &found {
        eprintln!("{finding}");
    }
    let drift = tree_drift(&found, KNOWN);
    assert!(drift.is_empty(), "{}", drift.join("\n"));
}

/// What is wrong with the crate's findings against KNOWN: one line each, none when they agree.
/// Each KNOWN row stands for one finding, so a second finding with its key is new (#42341 F1).
fn tree_drift(found: &[Finding], known: &[&str]) -> Vec<String> {
    let key = |f: &Finding| format!("{} {}", f.rel.trim_start_matches(SRC), f.name);
    let left = unmatched(known, found, |k, f| *k == key(f));
    let new: Vec<String> = left.extra.iter().map(ToString::to_string).collect();
    let gone: Vec<&&str> = left.missing;
    let mut out = Vec::new();
    if !new.is_empty() {
        out.push(format!(
            "process-wide test hooks: a parallel test can replace or clear another's hook (cmux#41350):\n{}",
            new.join("\n")
        ));
    }
    if !gone.is_empty() {
        out.push(format!("these KNOWN rows have no finding any more; take them out: {gone:?}"));
    }
    out
}

/// #42341 review F1: a KNOWN row stands for one finding, so a second finding with its key (a
/// static of the same name in another module of the file) fails the check.
#[test]
fn a_known_row_covers_one_finding_not_two() {
    let finding = |line| Finding {
        rel: format!("{SRC}hub/x.rs"),
        line,
        name: "HOOK".to_string(),
        why: "a closure in a process-wide cell".to_string(),
    };
    let drift = tree_drift(&[finding(3), finding(9)], &["hub/x.rs HOOK"]);
    assert!(drift.iter().any(|d| d.contains("hub/x.rs:9:")), "the second HOOK passed: {drift:?}");
}
