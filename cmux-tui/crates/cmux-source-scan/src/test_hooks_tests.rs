//! The rows of the test-hooks check, in test_hooks_rows.txt: every row of
//! check-test-hooks.test.sh (the python check this replaces), the rows of the reviews of #41427
//! and #41383, and a fixed sample of the property's generated chains; then the property itself
//! (run by hand). acpmux's own tree is judged by acpmux's tests (`src/test_hooks_tree.rs` there).

use std::path::Path;

use super::*;
use crate::rows::unmatched;
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

/// Why a row fails, or None when the check judges it as the row says. A `refused` row names the
/// findings its source holds, `LINE [WORDS]` each, joined by ` & `: the check must find exactly
/// those, each once, so a second copy of one fails the row as a missing one does (#42341 F1).
fn judge_row(args: &str, source: &str) -> Option<String> {
    let (kind, rest) = args.split_once(' ').unwrap_or((args, ""));
    let (first, rest) = rest.split_once(' ').unwrap_or((rest, ""));
    let (file, text) = match kind {
        "chain" => ("chain.rs".to_string(), format!("{CHAIN_PRELUDE}{source}")),
        _ => (first.to_string(), source.to_string()),
    };
    let found: Vec<String> =
        judge_source(&format!("{SRC}{file}"), &text).iter().map(ToString::to_string).collect();
    let at = |line: &str| format!("{SRC}{file}:{line}:");
    let ok = match (kind, first) {
        ("passes", _) | ("chain", "passes") => found.is_empty(),
        // A chain carries only the python check's verdict, not the findings.
        ("chain", "refused") => !found.is_empty(),
        ("refused", _) => {
            let named: Vec<(String, &str)> = rest
                .split(" & ")
                .map(|one| {
                    let (line, words) = one.split_once(' ').unwrap_or((one, ""));
                    line.parse::<usize>().expect("a row's line number");
                    (at(line), words)
                })
                .collect();
            let left = unmatched(&named, &found, |(head, words), f| {
                f.starts_with(head.as_str()) && f.contains(words)
            });
            if !left.is_empty() {
                return Some(format!(
                    "named but not found {:?}; found but not named {:#?}",
                    left.missing, left.extra
                ));
            }
            true
        }
        // Nothing at the line: no finding there at all, so any() is the whole claim.
        ("clear", _) => {
            let line = rest.split(' ').next().unwrap_or("");
            !found.iter().any(|f| f.starts_with(&at(line)))
        }
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

/// #41567 review F1: a `refused` row names the finding its source holds, so one more finding
/// (another line, or other words) fails it.
#[test]
fn a_refused_row_fails_on_a_finding_it_does_not_name() {
    let two = "pub static A: std::sync::OnceLock<fn(bool)> = std::sync::OnceLock::new();\npub static B: std::sync::OnceLock<fn(bool)> = std::sync::OnceLock::new();\n";
    let why = judge_row("refused text.rs 1 closure", two);
    assert!(why.as_deref().is_some_and(|w| w.contains("text.rs:2:")), "B went unnamed: {why:?}");
}

/// #42341 review F1: two matching statics on one line are two findings. A row that names one
/// fails on the second, though both start `text.rs:1:` and hold `closure`.
#[test]
fn a_refused_row_fails_on_a_second_copy_of_its_finding() {
    let two = "pub static A: std::sync::OnceLock<fn(bool)> = std::sync::OnceLock::new(); pub static B: std::sync::OnceLock<fn(bool)> = std::sync::OnceLock::new();\n";
    let why = judge_row("refused text.rs 1 closure", two);
    assert!(why.as_deref().is_some_and(|w| w.contains(": B: ")), "B went unnamed: {why:?}");
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
    for path in rust_files(dir).expect("the chains directory") {
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
    let found = judge_tree(&dir).expect("the tree this test wrote reads");
    std::fs::remove_dir_all(&dir).expect("remove the tree this test wrote");
    // Exactly these findings, each once: an OK_ static found, or a BAD_ one found twice, fails.
    let closure = "a closure in a process-wide cell";
    let named: &[(&str, &str)] = &[
        ("BAD_PATH", closure),
        ("BAD_REEXPORT", closure),
        ("BAD_ARG", closure),
        ("BAD_ONE_CFG", closure),
        ("BAD_INLINE", closure),
        ("BAD_CHILD", closure),
        ("BAD_NO_FILE", "unresolved: its type names crate::nope::X"),
    ];
    let left = unmatched(named, &found, |(name, why), f| f.name == *name && f.why.contains(why));
    assert!(left.is_empty(), "{left:#?}\nof {found:#?}");
    // One file alone still calls each of these unresolved.
    let alone = judge_source(&format!("{SRC}lib.rs"), files[0].1);
    let ok_use: Vec<&Finding> = alone.iter().filter(|f| f.name == "OK_USE").collect();
    assert!(ok_use.len() == 1 && ok_use[0].why.starts_with("unresolved"), "{alone:#?}");
}
