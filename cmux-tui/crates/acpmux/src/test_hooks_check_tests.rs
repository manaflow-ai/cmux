//! The rows of the test-hooks check: every row of check-test-hooks.test.sh (the python check this
//! replaces), the two tokenizer findings of the reviews of #41427 and #41383, a fixed sample of the
//! property's generated chains, and the crate's own tree.

use std::collections::BTreeSet;
use std::path::Path;
use std::time::Instant;

use super::*;

const SRC: &str = "cmux-tui/crates/acpmux/src/";

fn findings(file: &str, text: &str) -> Vec<String> {
    let text = text.strip_prefix('\n').unwrap_or(text);
    judge_source(&format!("{SRC}{file}"), text).iter().map(ToString::to_string).collect()
}

/// The check refuses `file`, naming its `line` (with `word` in that finding).
#[track_caller]
fn refused(file: &str, line: usize, word: &str, text: &str) {
    let found = findings(file, text);
    let at = format!("{SRC}{file}:{line}:");
    assert!(
        found.iter().any(|f| f.starts_with(&at) && f.contains(word)),
        "{file}:{line} must be refused (naming {word:?}); found {found:#?}"
    );
}

#[track_caller]
fn passes(file: &str, text: &str) {
    let found = findings(file, text);
    assert!(found.is_empty(), "{file} must pass; found {found:#?}");
}

#[test]
fn production_caches_per_thread_hooks_and_a_serializer_pass() {
    passes(
        "lib.rs",
        r#"
use regex::Regex;
use std::collections::HashMap;
struct Cached { at: u64 }
struct Watch;
static CACHE: std::sync::Mutex<Option<Cached>> = std::sync::Mutex::new(None);
static WATCHES: LazyLock<Mutex<HashMap<String, Watch>>> = LazyLock::new(Default::default);
static ID: LazyLock<Regex> = LazyLock::new(|| Regex::new("{").unwrap());
#[cfg(test)]
thread_local! {
    static SWAP_HOOK: std::cell::RefCell<Option<(SwapFn, Reached)>> =
        const { std::cell::RefCell::new(None) };
    static AFTER_ADD: std::cell::RefCell<Option<Box<dyn FnOnce(&Path)>>> =
        const { std::cell::RefCell::new(None) };
}
#[cfg(test)]
static HOOK_TEST: std::sync::Mutex<()> = std::sync::Mutex::new(());
"#,
    );
}

#[test]
fn the_sweep_pause_shape_is_refused_and_passes_per_thread() {
    refused(
        "hub/transfer_in.rs",
        3,
        "test slot",
        r#"
/// A test's hook right after a sweep read a durable marker.
#[cfg(test)]
pub(super) static SWEEP_PAUSE: std::sync::Mutex<Option<Arc<dyn Fn(&str) + Send + Sync>>> =
    std::sync::Mutex::new(None);
"#,
    );
    passes(
        "hub/transfer_in.rs",
        r#"
#[cfg(test)]
type PauseFn = Box<dyn FnMut(&str)>;
#[cfg(test)]
thread_local! {
    /// A test's hook right after a sweep read a durable marker.
    static SWEEP_PAUSE: std::cell::RefCell<Option<(PauseFn, Reached)>> =
        const { std::cell::RefCell::new(None) };
}
"#,
    );
}

#[test]
fn a_slot_of_any_value_is_a_test_slot_in_test_code() {
    refused(
        "meta.rs",
        2,
        "test slot",
        r#"
#[cfg(test)]
pub(crate) static SETTLE_HOLD: std::sync::Mutex<Option<SettleHold>> = std::sync::Mutex::new(None);
"#,
    );
    refused(
        "meta.rs",
        5,
        "test slot",
        r#"
fn real() {}

#[cfg(test)]
mod tests {
    static HELD: std::sync::RwLock<Option<String>> = std::sync::RwLock::new(None);
}
"#,
    );
    refused(
        "meta_tests.rs",
        1,
        "test slot",
        "static HELD: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);\n",
    );
    // Production code under cfg(not(test)) is not test code.
    passes(
        "meta.rs",
        r#"
struct Cached { at: u64 }
#[cfg(not(test))]
static HELD: std::sync::Mutex<Option<Cached>> = std::sync::Mutex::new(None);
"#,
    );
}

#[test]
fn a_closure_in_a_cell_directly_or_through_an_alias() {
    refused(
        "text.rs",
        1,
        "closure",
        "pub static SAVE_CHECKED: std::sync::OnceLock<fn(bool)> = std::sync::OnceLock::new();\n",
    );
    refused(
        "text.rs",
        4,
        "closure",
        r#"
type Seam = Arc<
    dyn Fn(String) -> Pin<Box<dyn Future<Output = Result<bool, RpcError>> + Send>> + Send + Sync,
>;
static SEAM: std::sync::LazyLock<std::sync::Mutex<Vec<Seam>>> = std::sync::LazyLock::new(Default::default);
"#,
    );
}

#[test]
fn any_static_named_as_a_hook() {
    refused(
        "exit.rs",
        1,
        "named as a hook",
        "pub static EXIT_HOOK: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);\n",
    );
}

const READ_HOOK: &str = r#"
#[cfg(test)]
type ReadHook = Arc<dyn Fn(String) -> bool + Send + Sync>;
// test-hook-allow: serialized by HOOK_TEST, which both tests that set it hold until they clear it
#[cfg(test)]
static READ_HOOK: OnceLock<Mutex<Option<ReadHook>>> = OnceLock::new();

#[cfg(test)]
mod tests {
    static HOOK_TEST: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
}
"#;

#[test]
fn the_read_hook_shape_needs_its_marker_and_its_serializer() {
    passes("hub/watches.rs", READ_HOOK);
    let other = READ_HOOK.replace("static HOOK_TEST", "static OTHER_LOCK");
    refused("hub/watches.rs", 5, "no `static HOOK_TEST: Mutex<()>`", &other);
    let not_unit =
        READ_HOOK.replace("HOOK_TEST: tokio::sync::Mutex<()>", "HOOK_TEST: tokio::sync::Mutex<u8>");
    refused("hub/watches.rs", 5, "no `static HOOK_TEST: Mutex<()>`", &not_unit);
    let marker = "// test-hook-allow: serialized by HOOK_TEST, which both tests that set it hold until they clear it";
    let no_reason = READ_HOOK.replace(marker, "// test-hook-allow: fine");
    refused("hub/watches.rs", 5, "gives no reason", &no_reason);
    let no_marker = READ_HOOK.replace(marker, "// Some comment.");
    refused("hub/watches.rs", 5, "test slot", &no_marker);
}

#[test]
fn a_marker_on_another_static_does_not_cover_this_one() {
    refused(
        "two.rs",
        4,
        "closure",
        r#"
// test-hook-allow: one process per test, set once by its only test
pub static A_HOOK: std::sync::OnceLock<fn(bool)> = std::sync::OnceLock::new();

pub static B_HOOK: std::sync::OnceLock<fn(bool)> = std::sync::OnceLock::new();
"#,
    );
}

#[test]
fn the_files_aliases_are_resolved_transitively_in_either_order() {
    refused(
        "alias.rs",
        2,
        "closure",
        "type HookCell = Mutex<Option<Box<dyn Fn()>>>;\nstatic H: HookCell = Mutex::new(None);\n",
    );
    refused(
        "alias.rs",
        3,
        "closure",
        "type A = Mutex<Option<B>>;\ntype B = Box<dyn Fn()>;\nstatic H: A = Mutex::new(None);\n",
    );
    refused(
        "alias.rs",
        4,
        "closure",
        r#"
type Seam = OnceLock<Inner>;
type Inner = Step;
type Step = fn(bool);
pub static SEAM: Seam = OnceLock::new();
"#,
    );
    refused(
        "alias.rs",
        3,
        "test slot",
        "type Slot<T> = Mutex<Option<T>>;\n#[cfg(test)]\nstatic HELD: Slot<String> = Mutex::new(None);\n",
    );
}

#[test]
fn a_generic_aliass_arguments_go_by_position_and_unused_ones_drop() {
    passes(
        "alias.rs",
        "struct Cached { at: u64 }\ntype Cache<T> = Mutex<Option<Cached>>;\nstatic CACHE: Cache<fn()> = Mutex::new(None);\n",
    );
    refused(
        "alias.rs",
        2,
        "closure",
        "type Slot<T> = Mutex<Option<T>>;\nstatic S: Slot<Box<dyn Fn()>> = Mutex::new(None);\n",
    );
    passes(
        "alias.rs",
        r#"
struct Cached { at: u64 }
type Pair<A, B> = Mutex<Option<A>>;
static P: Pair<Cached, Box<dyn Fn()>> = Mutex::new(None);
static Q: Pair<Cached, Unseen> = Mutex::new(None);
"#,
    );
    refused(
        "alias.rs",
        3,
        "closure",
        "struct Cached { at: u64 }\ntype Pair<A, B> = Mutex<Option<A>>;\nstatic P: Pair<Box<dyn Fn()>, Cached> = Mutex::new(None);\n",
    );
    let nested = r#"
type Inner<A, B> = std::sync::OnceLock<B>;
type Outer<T> = Inner<u8, T>;
type Wrong<T> = Inner<T, u8>;
static O: Outer<fn(bool)> = std::sync::OnceLock::new();
static W: Wrong<fn(bool)> = std::sync::OnceLock::new();
"#;
    refused("alias.rs", 4, "closure", nested);
    let found = findings("alias.rs", nested);
    assert!(
        !found.iter().any(|f| f.contains("alias.rs:5:")),
        "W passes its closure to an unused parameter: {found:#?}"
    );
}

#[test]
fn one_ordered_substitution_pass() {
    // F1 of #41418: a default sees the parameters bound before it.
    passes(
        "alias.rs",
        "struct Pair<T, U = T> { first: T, second: U }\nstatic PAIR: std::sync::Mutex<Pair<u8>> = std::sync::Mutex::new(Pair { first: 0, second: 0 });\n",
    );
    refused(
        "alias.rs",
        2,
        "closure",
        "type Later<T, U = T> = std::sync::OnceLock<U>;\nstatic LATER: Later<fn(bool)> = std::sync::OnceLock::new();\n",
    );
    // F2: a parameter named as a prelude name is the parameter.
    refused(
        "alias.rs",
        2,
        "closure",
        "type Slot<Future> = Mutex<Option<Future>>;\nstatic S: Slot<fn()> = Mutex::new(None);\n",
    );
    // F3: a projection of a parameter keeps its argument and is unresolved, never dropped.
    refused(
        "alias.rs",
        4,
        "",
        r#"
trait Callback { type Hook; }
impl Callback for fn() { type Hook = fn(); }
type Slot<T: Callback> = Mutex<Option<T::Hook>>;
static S: Slot<fn()> = Mutex::new(None);
"#,
    );
    refused(
        "alias.rs",
        3,
        "unresolved",
        "struct Cached { at: u64 }\ntype Slot<T: Callback> = Mutex<Option<T::Hook>>;\nstatic S: Slot<Cached> = Mutex::new(None);\n",
    );
}

/// Review of #41427 (F1): `<T as Future>::Output` was split into tokens, its `Output` read as the
/// file's own `type Output`, and the projection never marked unresolved.
#[test]
fn a_qualified_projection_is_unresolved_never_the_files_own_name() {
    refused(
        "alias.rs",
        4,
        "unresolved: its type names <Fut as Future>::Output",
        r#"
struct Fut;
type Output = u8;
type Slot<T> = std::sync::OnceLock<<T as Future>::Output>;
static S: Slot<Fut> = std::sync::OnceLock::new();
"#,
    );
    refused(
        "alias.rs",
        3,
        "unresolved",
        "struct Fut;\ntype Output = u8;\nstatic S: std::sync::OnceLock<<Fut as Future>::Output> = std::sync::OnceLock::new();\n",
    );
    // What the projection's type holds still counts.
    refused(
        "alias.rs",
        2,
        "closure",
        "type Slot<T> = std::sync::OnceLock<<T as Future>::Output>;\nstatic S: Slot<fn()> = std::sync::OnceLock::new();\n",
    );
}

#[test]
fn a_struct_is_judged_by_its_fields_and_a_renamed_cell_is_a_cell() {
    refused(
        "alias.rs",
        4,
        "closure",
        r#"
struct Hooks {
    on_read: Mutex<Option<Box<dyn Fn(&str) + Send>>>,
}
static HOOKS: Hooks = Hooks { on_read: Mutex::new(None) };
"#,
    );
    refused(
        "alias.rs",
        3,
        "test slot",
        "use std::sync::{Arc, Mutex as StdMutex};\n#[cfg(test)]\nstatic HELD: StdMutex<Option<Arc<str>>> = StdMutex::new(None);\n",
    );
    passes(
        "alias.rs",
        r#"
use std::path::PathBuf;
use std::sync::atomic::AtomicU64;
type SizeCache = std::sync::Mutex<Option<(std::time::Instant, PathBuf, Option<u64>)>>;
static CACHE: SizeCache = std::sync::Mutex::new(None);
struct SizeWatch { near_cap: AtomicU64, inner: std::sync::Mutex<Inner> }
struct Inner { last: Option<u64> }
static GLOBAL: SizeWatch = SizeWatch::new();
const SLOTS: usize = 64;
static LOCKS: [std::sync::Mutex<()>; SLOTS] = [const { std::sync::Mutex::new(()) }; SLOTS];
"#,
    );
}

const PER_THREAD_FORMS: &str = r#"
thread_local!(static PAUSE_HOOK: std::cell::RefCell<Option<Box<dyn FnMut(&str)>>> = const { std::cell::RefCell::new(None) });
#[cfg(test)]
thread_local!(
    static SWAP_HOOK: std::cell::RefCell<Option<Box<dyn Fn()>>> =
        const { std::cell::RefCell::new(None) }
);
thread_local! {
    static READ_HOOK: std::cell::RefCell<Option<Box<dyn Fn()>>> = const { std::cell::RefCell::new(None) };
}
tokio::task_local! {
    static TASK_HOOK: std::sync::Arc<dyn Fn() + Send + Sync>;
}
tokio::task_local!(static SCOPE_HOOK: u64);
"#;

#[test]
fn thread_local_and_task_local_in_both_forms_are_per_thread() {
    passes("local.rs", PER_THREAD_FORMS);
    let after = format!(
        "{PER_THREAD_FORMS}pub static AFTER_HOOK: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);\n"
    );
    refused("local.rs", 14, "named as a hook", &after);
}

/// Review of #41383 (F1): the per-thread span was whole lines, so a static on the line a
/// `thread_local!` opens was skipped. Containment now goes by the macro's span in the tree.
#[test]
fn a_static_on_a_thread_locals_line_is_judged() {
    refused(
        "local.rs",
        1,
        "closure",
        "static AFTER_HOOK: std::sync::OnceLock<fn()> = std::sync::OnceLock::new(); thread_local! { static LOCAL: std::cell::Cell<u8> = const { std::cell::Cell::new(0) }; }\n",
    );
    refused(
        "local.rs",
        1,
        "closure",
        "thread_local! { static LOCAL: std::cell::Cell<u8> = const { std::cell::Cell::new(0) }; } static AFTER: std::sync::OnceLock<fn()> = std::sync::OnceLock::new();\n",
    );
    // Another macro's statics are judged when its body is items.
    refused(
        "local.rs",
        2,
        "closure",
        "wrapped! {\n    static INNER: std::sync::OnceLock<fn()> = std::sync::OnceLock::new();\n}\n",
    );
}

#[test]
fn a_name_the_file_does_not_show_is_unresolved_never_passed() {
    refused(
        "unseen.rs",
        2,
        "unresolved",
        "use crate::hooks::HookCell;\nstatic H: HookCell = HookCell::new();\n",
    );
    refused(
        "unseen.rs",
        2,
        "unresolved",
        "use super::*;\nstatic PENDING: std::sync::OnceLock<Pending> = std::sync::OnceLock::new();\n",
    );
    refused(
        "unseen.rs",
        1,
        "unresolved",
        "static SEAM: std::sync::Mutex<Vec<super::seams::Seam>> = std::sync::Mutex::new(Vec::new());\n",
    );
    passes(
        "unseen.rs",
        "// test-hook-allow: holds the parsed route file, no closure\nstatic LAST: std::sync::Mutex<Option<crate::route::RouteFile>> = std::sync::Mutex::new(None);\n",
    );
}

/// A fixed sample of the property's generated chains (check-test-hooks-property.py at #41427's
/// head, seed 41418, chains 0-4, 12, 13 and 24): `true` for each the python check refused. This
/// check refuses those and passes the others, as it did on the whole run (4000 chains, the same
/// 3486 refused by both); the counts are in the PR.
const CHAINS: &[(bool, &str)] = &[
    (
        true,
        r#"type L0<T, W = T> = (T, L1<Mutex<Option<(u8, bool)>>, W>);
type L1<Future, String> = std::sync::OnceLock<(L2<Box<Future>>, RwLock<Option<String>>)>;
type L2<V: Callback> = Mutex<Option<(V::Hook, String)>>;
static CHAIN: L0<Arc<dyn Fn(u8) + Send + Sync>> = todo();
"#,
    ),
    (
        true,
        r#"struct L0<W, String = W, U = String> { f0: Mutex<Option<String>>, f1: U, f2: RwLock<Option<W>>, f3: Option<fn(bool)> }
static CHAIN: std::sync::OnceLock<L0<RwLock<Option<Vec<u8>>>>> = todo();
"#,
    ),
    (
        true,
        r#"struct L0<String, Iterator = String> { f0: L1<Iterator, Mutex<Option<fn(bool)>>>, f1: String }
type L1<Future, Default = Future> = ((Default, u8), Future, L2<Arc<Future>, Arc<dyn Fn(u8) + Send + Sync>>);
struct L2<V: Callback, Default> { f0: Box<Default>, f1: <V as Callback>::Hook }
static CHAIN: OnceLock<Mutex<L0<Arc<Leaf>>>> = todo();
"#,
    ),
    (
        true,
        r#"struct L0<Iterator, W: Callback, V> { f0: V, f1: Iterator, f2: L1<(Cached, u8)>, f3: <W as Callback>::Hook }
type L1<V: Callback> = L2<Box<dyn Fn()>, V::Hook>;
type L2<Iterator, U> = Mutex<Option<(Iterator, L3<String>, U)>>;
type L3<V> = Vec<V>;
static CHAIN: Mutex<Option<L0<String, Vec<u8>, (Box<dyn Fn()>, u8)>>> = todo();
"#,
    ),
    (
        true,
        r#"type L0<W, Future, U> = Option<(Future, Option<W>, Mutex<Option<U>>, L1<u8, Vec<Cached>>)>;
struct L1<Default: Callback, Future: Callback = Default, Iterator: Callback = Default> { f0: <Iterator as Callback>::Hook, f1: Default::Hook, f2: Future::Hook }
static CHAIN: L0<u8, Vec<u8>, Option<u8>> = todo();
"#,
    ),
    (
        false,
        r#"type L0<Future: Callback> = L1<Future::Hook, <Future as Callback>::Hook>;
type L1<T: Callback, U> = ((U, u8), T);
#[cfg(test)]
static CHAIN: Vec<L0<Box<dyn Fn()>>> = todo();
"#,
    ),
    (
        false,
        r#"struct L0<U> { f0: L1<U> }
struct L1<W> { f0: (W, u8) }
static CHAIN: Vec<L0<fn()>> = todo();
"#,
    ),
    (
        false,
        r#"type L0<V> = Vec<L1<(V, u8), V>>;
type L1<U: Callback, W> = (Box<W>, L2<U>);
type L2<W> = (RwLock<Option<(u8, bool)>>, L3<W, W>);
type L3<String, Default: Callback> = Mutex<Option<(Default, String)>>;
static CHAIN: L0<String> = todo();
"#,
    ),
];

const CHAIN_PRELUDE: &str =
    "struct Cached { at: u64 }\ntype Leaf = fn(u8);\ntrait Callback { type Hook; }\n";

#[test]
fn generated_chains_the_python_check_refused_are_refused() {
    for (base_refused, chain) in CHAINS {
        let found = findings("chain.rs", &format!("{CHAIN_PRELUDE}{chain}"));
        assert_eq!(
            !found.is_empty(),
            *base_refused,
            "the python check refused this chain: {base_refused}; found {found:#?}\n{chain}"
        );
    }
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
