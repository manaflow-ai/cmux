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

/// One binding of the name `Lock`: an import (`use`) or a definition (`type` or `struct`), of a
/// std or tokio `Mutex` (a serializer) or of something that is none (an RwLock, a plain struct).
#[derive(Clone, Copy, Debug)]
enum Binding {
    Use(Kind),
    Def(Kind),
}

/// What a binding of `Lock` is.
#[derive(Clone, Copy, Debug)]
enum Kind {
    StdMutex,
    TokioMutex,
    RwLock,
    Plain,
}

impl Binding {
    fn serializes(self) -> bool {
        let (Self::Use(lock) | Self::Def(lock)) = self;
        matches!(lock, Kind::StdMutex | Kind::TokioMutex)
    }

    fn item(self) -> &'static str {
        match self {
            Self::Use(Kind::StdMutex) => "use std::sync::Mutex as Lock;",
            Self::Use(Kind::TokioMutex) => "use tokio::sync::Mutex as Lock;",
            Self::Use(Kind::RwLock) => "use std::sync::RwLock as Lock;",
            Self::Use(Kind::Plain) => "use crate::plain::Plain as Lock;",
            Self::Def(Kind::StdMutex) => "type Lock = std::sync::Mutex<()>;",
            Self::Def(Kind::TokioMutex) => "type Lock = tokio::sync::Mutex<()>;",
            Self::Def(Kind::RwLock) => "type Lock = std::sync::RwLock<()>;",
            Self::Def(Kind::Plain) => "struct Lock;",
        }
    }

    /// The serializer's type as the module holding this binding writes it.
    fn written(self) -> &'static str {
        match self {
            Self::Use(_) => "Lock<()>",
            Self::Def(_) => "Lock",
        }
    }
}

/// A shape: how the first and the second binding bind the name.
type Shape = (fn(Kind) -> Binding, fn(Kind) -> Binding);

/// The class of review of cmux#41693 F1 and cmux#41707 F1: a name the file binds two ways, in two
/// modules, is a serializer if and only if every binding of it is one. Every shape (use+use,
/// def+def, use+def, def+use), split two ways (the root and its `mod tests`, two sibling
/// modules), with every pair of bindings; the serializer sits beside the first binding.
#[test]
fn a_name_bound_two_ways_serializes_iff_every_binding_does() {
    let locks = [Kind::StdMutex, Kind::TokioMutex, Kind::RwLock, Kind::Plain];
    let shapes: [Shape; 4] = [
        (Binding::Use, Binding::Use),
        (Binding::Def, Binding::Def),
        (Binding::Use, Binding::Def),
        (Binding::Def, Binding::Use),
    ];
    let marker = "#[cfg(test)]\ntype ReadHook = Arc<dyn Fn(String) -> bool + Send + Sync>;\n\
        // test-hook-allow: serialized by HOOK_TEST, which both tests that set it hold until they clear it\n\
        #[cfg(test)]\nstatic READ_HOOK: OnceLock<Mutex<Option<ReadHook>>> = OnceLock::new();\n";
    let mut cells = 0;
    let mut wrong = Vec::new();
    for (first_of, second_of) in shapes {
        for a in locks {
            for b in locks {
                let (first, second) = (first_of(a), second_of(b));
                let serializer =
                    format!("#[cfg(test)]\nstatic HOOK_TEST: {} = Lock::new(());", first.written());
                let (one, two) = (first.item(), second.item());
                let layouts = [
                    format!("{one}\n{serializer}\n#[cfg(test)]\nmod tests {{\n{two}\n}}\n"),
                    format!("mod a {{\n{one}\n{serializer}\n}}\nmod b {{\n{two}\n}}\n"),
                ];
                for layout in layouts {
                    let source = format!("{layout}{marker}");
                    let found: Vec<String> = judge_source(&format!("{SRC}hub/watches.rs"), &source)
                        .iter()
                        .map(ToString::to_string)
                        .collect();
                    let refused =
                        found.iter().any(|f| f.contains("no `static HOOK_TEST: Mutex<()>`"));
                    let expect = first.serializes() && second.serializes();
                    cells += 1;
                    if refused == expect || (expect && !found.is_empty()) {
                        wrong.push(format!(
                            "{first:?} + {second:?}: expected {}, found {found:#?}\n{source}",
                            if expect { "serialized" } else { "refused" }
                        ));
                    }
                }
            }
        }
    }
    assert_eq!(cells, 128, "4 shapes x 16 pairs x 2 layouts");
    assert!(
        wrong.is_empty(),
        "{} of {cells} cells judged wrong:\n{}",
        wrong.len(),
        wrong.join("\n")
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
