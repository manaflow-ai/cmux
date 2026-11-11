//! The rows of the test-hooks check, in test_hooks_check_rows.txt: every row of
//! check-test-hooks.test.sh (the python check this replaces), the rows of the reviews of #41427
//! and #41383, and a fixed sample of the property's generated chains; then the property itself
//! (run by hand) and the crate's own tree.

use std::collections::BTreeSet;
use std::path::Path;
use std::time::Instant;

use super::*;

const SRC: &str = "cmux-tui/crates/acpmux/src/";
const ROWS: &str = include_str!("test_hooks_check_rows.txt");
const CHAIN_PRELUDE: &str =
    "struct Cached { at: u64 }\ntype Leaf = fn(u8);\ntrait Callback { type Hook; }\n";

/// The rows: (the `===` line's arguments, its title, its source).
fn rows() -> Vec<(String, String, String)> {
    let mut out: Vec<(String, String, String)> = Vec::new();
    for line in ROWS.lines() {
        if let Some(head) = line.strip_prefix("=== ") {
            let (args, title) =
                head.split_once(" :: ").expect("a row names its title after ` :: `");
            out.push((args.to_string(), title.to_string(), String::new()));
        } else if let Some((_, _, source)) = out.last_mut() {
            source.push_str(line);
            source.push('\n');
        }
    }
    out
}

/// Why a row fails, or None when the check judges it as the row says.
fn judge_row(args: &str, source: &str) -> Option<String> {
    let mut parts = args.splitn(4, ' ');
    let kind = parts.next().unwrap_or("");
    let first = parts.next().unwrap_or("");
    let line: usize = parts.next().map_or(0, |l| l.parse().expect("a row's line number"));
    let words = parts.next().unwrap_or("");
    let (file, text) = match kind {
        "chain" => ("chain.rs".to_string(), format!("{CHAIN_PRELUDE}{source}")),
        _ => (first.to_string(), source.to_string()),
    };
    let found: Vec<String> =
        judge_source(&format!("{SRC}{file}"), &text).iter().map(ToString::to_string).collect();
    let at = format!("{SRC}{file}:{line}:");
    let ok = match (kind, first) {
        ("passes", _) | ("chain", "passes") => found.is_empty(),
        ("chain", "refused") => !found.is_empty(),
        ("refused", _) => found.iter().any(|f| f.starts_with(&at) && f.contains(words)),
        ("clear", _) => !found.iter().any(|f| f.starts_with(&at)),
        _ => return Some(format!("no such row kind: {args}")),
    };
    (!ok).then(|| format!("found {found:#?}"))
}

#[test]
fn every_row_is_judged_as_it_says() {
    let rows = rows();
    assert!(rows.len() > 50, "the row table reads {} rows", rows.len());
    let failed: Vec<String> = rows
        .iter()
        .filter_map(|(args, title, source)| {
            judge_row(args, source).map(|why| format!("{title} ({args}): {why}"))
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

/// The property, run by hand: ACPMUX_TEST_HOOKS_CHAINS names a directory of generated chains,
/// `N.rs` each with `N.base` holding 1 when the python check refused it. Writes `N.new` (1 when
/// this check refuses) and fails on a chain the python check refused that this one passes.
#[test]
#[ignore = "run by hand with ACPMUX_TEST_HOOKS_CHAINS (see the PR)"]
fn generated_chains_base_refuses_implies_this_refuses() {
    let Some(dir) = std::env::var_os("ACPMUX_TEST_HOOKS_CHAINS") else {
        return;
    };
    let dir = Path::new(&dir);
    let (mut total, mut base, mut new, mut both, mut base_only) = (0, 0, 0, 0, Vec::new());
    for path in sources(dir) {
        let text = std::fs::read_to_string(&path).expect("chain");
        let refused = !judge_source(&format!("{SRC}chain.rs"), &text).is_empty();
        let base_refused =
            std::fs::read_to_string(path.with_extension("base")).expect("base verdict").trim()
                == "1";
        std::fs::write(path.with_extension("new"), if refused { "1" } else { "0" })
            .expect("write verdict");
        total += 1;
        base += usize::from(base_refused);
        new += usize::from(refused);
        both += usize::from(base_refused && refused);
        if base_refused && !refused {
            base_only.push(path.display().to_string());
        }
    }
    eprintln!(
        "property: {total} chains: python refused {base}, syn refused {new}, both {both}, syn only {}, python only {}",
        new - both,
        base_only.len()
    );
    assert!(
        base_only.is_empty(),
        "chains the python check refused and this one passes: {base_only:#?}"
    );
}

/// The statics the crate held when this check replaced check-test-hooks.py, `path NAME` from
/// `src/`: each is to be fixed or marked. A new finding fails this test, and so does a row whose
/// static no longer has one (take the row out).
const KNOWN: &[&str] = &[
    "agent_host/link.rs RECEIPTS",
    "daemon/router_owner.rs ROUTER",
    "folder_instructions.rs SWAP_HOOK",
    "harness_fixture.rs LOADED",
    "harness_fixture.rs EMPTY",
    "hub/transfer_in.rs SWEEP_PAUSE",
    "route_probe.rs LAST",
    "server/chats/team_audit.rs HELD",
    "server/dual_requests.rs BOOK",
    "shadow_admission.rs KEPT",
    "store/journal_store/meta.rs SETTLE_HOLD",
    "vault.rs LOADED",
];

#[test]
fn the_crate_adds_no_process_wide_test_hook() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    let started = Instant::now();
    let files = sources(&dir.join("src")).len();
    let found = judge_tree(dir);
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
