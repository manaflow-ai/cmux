//! The crate adds no process-wide test hook (cmux#41350): the test-hooks check of
//! cmux-source-scan (crates/cmux-source-scan/src/test_hooks.rs) over this crate's `src`, run by
//! `cargo test -p acpmux --lib`. Its rows and the property are in that crate.

use std::collections::BTreeSet;
use std::path::Path;
use std::time::Instant;

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
    let key = |f: &Finding| format!("{} {}", f.rel.trim_start_matches(SRC), f.name);
    let keys: BTreeSet<String> = found.iter().map(key).collect();
    let new: Vec<String> = found
        .iter()
        .filter(|f| !KNOWN.contains(&key(f).as_str()))
        .map(ToString::to_string)
        .collect();
    let gone: Vec<&&str> = KNOWN.iter().filter(|k| !keys.contains(**k)).collect();
    assert!(
        new.is_empty(),
        "process-wide test hooks: a parallel test can replace or clear another's hook (cmux#41350):\n{}",
        new.join("\n")
    );
    assert!(gone.is_empty(), "these KNOWN rows have no finding any more; take them out: {gone:?}");
}
