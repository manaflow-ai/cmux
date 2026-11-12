//! The rows of the test-hooks check, in test_hooks_rows.txt: every row of
//! check-test-hooks.test.sh (the python check this replaces), the rows of the reviews of #41427
//! and #41383, and a fixed sample of the property's generated chains; then the property itself
//! (run by hand). acpmux's own tree is judged by acpmux's tests (`src/test_hooks_tree.rs` there).

use std::path::Path;

use super::*;
use crate::source::rust_files;

const SRC: &str = "cmux-tui/crates/acpmux/src/";
const ROWS: &str = include_str!("test_hooks_rows.txt");
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
    for path in rust_files(dir) {
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

/// A crate of several files: `judge_tree` follows a path of the crate (`crate::`, `super::`,
/// `self::`, a module declared as a file, a `use` or a re-export of one) into the file that
/// defines it, and judges what it finds there as if it were written in place.
#[test]
fn the_tree_follows_paths_into_other_files() {
    let files: &[(&str, &str)] = &[
        (
            "lib.rs",
            "mod a;\nmod b;\nmod c;\nmod e;\nuse std::sync::{LazyLock, Mutex, OnceLock};\n\
             use crate::a::Plain;\n\
             static OK_USE: Mutex<Option<Plain>> = Mutex::new(None);\n\
             static OK_PATH: LazyLock<crate::a::Plain> = LazyLock::new(Default::default);\n\
             static OK_TESTS_USE: Mutex<Option<crate::e::Holder>> = Mutex::new(None);\n\
             static OK_GENERIC: Mutex<crate::a::Wrap<u8>> = Mutex::new(crate::a::Wrap { inner: 0 });\n\
             static BAD_PATH: Mutex<Option<crate::a::Hooky>> = Mutex::new(None);\n\
             static BAD_NO_FILE: OnceLock<crate::nope::X> = OnceLock::new();\n\
             static BAD_REEXPORT: Mutex<Option<b::Again>> = Mutex::new(None);\n\
             static BAD_ARG: Mutex<Option<crate::a::Wrap<Box<dyn Fn() + Send>>>> = Mutex::new(None);\n\
             #[cfg(unix)]\nuse crate::a::Plain as Pick;\n#[cfg(windows)]\nuse crate::a::Hooky as Pick;\n\
             static BAD_ONE_CFG: Mutex<Option<Pick>> = Mutex::new(None);\n\
             mod inline {\n    use super::a::Hooky;\n    \
             static BAD_INLINE: std::sync::Mutex<Option<Hooky>> = std::sync::Mutex::new(None);\n}\n",
        ),
        (
            "a.rs",
            "pub struct Plain { at: u64, name: String, next: Option<Box<Plain>> }\n\
             pub struct Hooky { run: Box<dyn Fn() + Send> }\n\
             pub struct Wrap<T> { pub inner: T }\n",
        ),
        ("b.rs", "pub use crate::a::Hooky as Again;\n"),
        (
            "c.rs",
            "mod d;\nuse self::d::Inner;\nuse std::sync::Mutex;\n\
             static BAD_CHILD: Mutex<Option<Inner>> = Mutex::new(None);\n\
             static OK_CHILD: Mutex<Option<d::Calm>> = Mutex::new(None);\n",
        ),
        // The tests module's `use super::Calm` comes back to the top's `use f::Calm`: no cycle.
        (
            "e.rs",
            "mod f;\nuse f::Calm;\npub struct Holder { c: Calm }\nmod tests {\n    use super::Calm;\n}\n",
        ),
        ("e/f.rs", "pub struct Calm(u8);\n"),
        (
            "c/d.rs",
            "pub struct Inner(super::super::a::Hooky);\npub struct Calm(crate::a::Plain);\n",
        ),
    ];
    let dir = std::env::temp_dir().join(format!(
        "cmux-source-scan-tree-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    for (rel, text) in files {
        let path = dir.join("src").join(rel);
        std::fs::create_dir_all(path.parent().expect("a parent")).expect("mkdir");
        std::fs::write(&path, text).expect("write");
    }
    let found = judge_tree(&dir);
    std::fs::remove_dir_all(&dir).expect("remove the tree this test wrote");
    let why = |name: &str| found.iter().find(|f| f.name == name).map(|f| f.why.clone());
    for name in ["OK_USE", "OK_PATH", "OK_TESTS_USE", "OK_GENERIC", "OK_CHILD"] {
        assert_eq!(why(name), None, "{name}: {found:#?}");
    }
    for name in ["BAD_PATH", "BAD_REEXPORT", "BAD_ARG", "BAD_ONE_CFG", "BAD_INLINE", "BAD_CHILD"] {
        assert!(
            why(name).is_some_and(|w| w.starts_with("a closure in a process-wide cell")),
            "{name}: {found:#?}"
        );
    }
    assert!(
        why("BAD_NO_FILE").is_some_and(|w| w.contains("unresolved: its type names crate::nope::X")),
        "{found:#?}"
    );
    // One file alone still calls each of these unresolved.
    let alone = judge_source(&format!("{SRC}lib.rs"), files[0].1);
    assert!(
        alone.iter().any(|f| f.name == "OK_USE" && f.why.starts_with("unresolved")),
        "{alone:#?}"
    );
}
