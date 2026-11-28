//! The rows of the visible-only check, in visible_only_rows.txt, and its ratchet.

use super::*;
use crate::rows::unmatched;

const REL: &str = "cmux-tui/crates/demo/src/ui/rail.rs";
const ROWS: &str = include_str!("visible_only_rows.txt");

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

/// Why a row fails, or None when the check judges it as the row says: a `flags` row's findings
/// are exactly the ones it names, each once.
fn judge_row(args: &str, source: &str) -> Option<String> {
    let found = match judge_source(REL, source) {
        Ok(found) => found,
        Err(e) => return Some(format!("does not parse: {e}")),
    };
    let (kind, rest) = args.split_once(' ').unwrap_or((args, ""));
    let named: Vec<(usize, String)> = match kind {
        "passes" => Vec::new(),
        "flags" => rest
            .split(" & ")
            .map(|one| {
                let (line, kind) = one.split_once(' ').expect("`LINE KIND`");
                (line.parse().expect("a row's line number"), kind.to_string())
            })
            .collect(),
        _ => return Some(format!("no such row kind: {args}")),
    };
    let left =
        unmatched(&named, &found, |(line, kind), f| f.line == *line && f.kind.to_string() == *kind);
    (!left.is_empty()).then(|| {
        format!("named but not found {:?}; found but not named {:#?}", left.missing, left.extra)
    })
}

/// A row's `flags LINE KIND [& LINE KIND]` names each hit it expects once: `flags 2 walk` is one
/// walk on line 2. A walk inside another walk's closure is that walk's per-item work, not a second
/// hit (visible_only_rows.txt "a walk nested in a draw fn's closure ..."). A review read that row as
/// two walks and could not run cargo; fleet job 795d2a78cba04f7bf9bad48b ran this at 833109a0:
/// 27 passed, `visible-only: ok`.
#[test]
fn every_row_is_judged_as_it_says() {
    let rows = rows();
    assert!(rows.len() >= 10, "the row table reads {} rows", rows.len());
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

/// A `render*` fn outside a `ui`/`tui` module that names no ratatui prints text (a CLI table):
/// not a draw fn. In a `ui` module it is one.
#[test]
fn a_render_fn_is_a_draw_fn_in_ui_code_only() {
    let source = "fn render(rows: &[Row]) -> String {\n    rows.iter().map(|r| r.to_string()).collect()\n}\n";
    let cli = judge_source("cmux-tui/crates/demo/src/cli/ls.rs", source).expect("parses");
    assert!(cli.is_empty(), "{cli:#?}");
    let ui = judge_source("cmux-tui/crates/demo/src/tui/list.rs", source).expect("parses");
    assert_eq!(ui.len(), 1, "{ui:#?}");
}

#[test]
fn test_paths_are_not_judged() {
    for rel in [
        "cmux-tui/crates/demo/src/ui/tests.rs",
        "cmux-tui/crates/demo/src/ui/sidebar_tests.rs",
        "cmux-tui/crates/demo/tests/rail.rs",
        "cmux-tui/crates/demo/src/app/tests/rail.rs",
        "cmux-tui/crates/demo/benches/rail.rs",
    ] {
        assert!(is_test_path(rel), "{rel}");
    }
    assert!(!is_test_path("cmux-tui/crates/demo/src/ui/sidebar.rs"));
}

fn hit(rel: &str, func: &str, kind: Kind) -> Finding {
    Finding { rel: rel.into(), line: 1, func: func.into(), kind, text: String::new() }
}

/// The ratchet: a new fn, or one more hit in a listed fn, fails; so does a row above what its fn
/// has now (the list only shrinks); a row under a root the run did not read is left alone.
#[test]
fn the_ratchet_fails_on_growth_and_on_a_stale_row() {
    let known = parse_known(
        "# comment\n\na.rs draw walks=2 clones=1 :: small\nb.rs draw_list walks=1 clones=0 :: small\n",
    )
    .expect("parses");
    let all = |_: &str| true;
    let same = [
        hit("a.rs", "draw", Kind::Walk),
        hit("a.rs", "draw", Kind::Walk),
        hit("a.rs", "draw", Kind::Clone),
        hit("b.rs", "draw_list", Kind::Walk),
    ];
    assert!(ratchet(&same, &known, &all).is_empty());

    let mut grown = same.to_vec();
    grown.push(hit("a.rs", "draw", Kind::Clone));
    let out = ratchet(&grown, &known, &all);
    assert!(out.len() == 1 && out[0].starts_with("new: a.rs `draw`"), "{out:#?}");
    assert!(
        out[0].contains("bound it to the viewport") || out[0].contains("Bound it to the viewport")
    );

    let mut fresh = same.to_vec();
    fresh.push(hit("c.rs", "draw_rows", Kind::Walk));
    let out = ratchet(&fresh, &known, &all);
    assert!(out.len() == 1 && out[0].starts_with("new: c.rs `draw_rows`"), "{out:#?}");

    let fewer = &same[1..];
    let out = ratchet(fewer, &known, &all);
    assert!(out.len() == 1 && out[0].contains("lower the row to walks=1 clones=1"), "{out:#?}");
    let gone = &same[..3];
    let out = ratchet(gone, &known, &all);
    assert!(out.len() == 1 && out[0].contains("take the row out"), "{out:#?}");
    assert!(ratchet(gone, &known, &|rel: &str| rel != "b.rs").is_empty());
}

#[test]
fn a_known_row_says_why_and_counts_both_kinds() {
    assert!(parse_known("a.rs draw walks=1 clones=0 ::  \n").is_err());
    assert!(parse_known("a.rs draw walks=1 :: small\n").is_err());
    assert!(parse_known("a.rs draw walks=x clones=0 :: small\n").is_err());
}

/// The ratchet as checked in parses, names each fn once, and every row says why.
#[test]
fn the_known_list_parses() {
    let known = parse_known(KNOWN).unwrap_or_else(|e| panic!("{e}"));
    assert!(!known.is_empty());
    let mut keys: Vec<(&str, &str)> =
        known.iter().map(|k| (k.rel.as_str(), k.func.as_str())).collect();
    keys.sort_unstable();
    let before = keys.len();
    keys.dedup();
    assert_eq!(before, keys.len(), "a fn has two rows");
}
