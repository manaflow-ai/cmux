#!/usr/bin/env bash
# check-test-hooks.py: no process-wide test hooks in acpmux (cmux#41350). Run it yourself after
# changing the check; it is not a CI step (CLAUDE.md: no new CI tests).
set -euo pipefail
repo="$(cd "$(dirname "$0")/../../.." && pwd)"
check="$repo/scripts/cmux-next/check-test-hooks.py"
# CHECK: another copy of the check to run these cases against (an older one, to see which of them it misses).
check="${CHECK:-$check}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
failures=0
# Each case is judged on its own: a failure is counted and the next case runs.
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
src="$tmp/cmux-tui/crates/acpmux/src"
mkdir -p "$src/hub"

# refused FILE LINE CASE [WORD]: the check fails and names FILE:LINE (with WORD in its finding).
refused() {
  local out
  if out="$(python3 -I "$check" "$tmp")"; then fail "$3: must be refused"; return; fi
  case "$out" in *"$1:$2:"*) ;; *) fail "$3: $1:$2 not named: $out"; return ;; esac
  if [ -n "${4:-}" ]; then
    case "$(printf '%s\n' "$out" | grep -F "$1:$2:")" in *"$4"*) ;; *) fail "$3: $1:$2 not $4: $out" ;; esac
  fi
}
passes() {
  python3 -I "$check" "$tmp" >/dev/null || fail "$1: must pass: $(python3 -I "$check" "$tmp")"
}

# Production state, per-thread hooks and serializers themselves are not hooks.
cat >"$src/lib.rs" <<'RS'
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
RS
passes "production caches, thread_local! hooks and a serializer"
sed -n 1,9p "$src/lib.rs" >"$tmp/lib.rs" && mv "$tmp/lib.rs" "$src/lib.rs"

# The SWEEP_PAUSE shape, as it was on base: a #[cfg(test)] Mutex<Option<closure>>.
cat >"$src/hub/transfer_in.rs" <<'RS'
/// A test's hook right after a sweep read a durable marker.
#[cfg(test)]
pub(super) static SWEEP_PAUSE: std::sync::Mutex<Option<Arc<dyn Fn(&str) + Send + Sync>>> =
    std::sync::Mutex::new(None);
RS
refused cmux-tui/crates/acpmux/src/hub/transfer_in.rs 3 "the SWEEP_PAUSE shape"

# The same hook made per thread (the on_* guard): passes.
cat >"$src/hub/transfer_in.rs" <<'RS'
#[cfg(test)]
type PauseFn = Box<dyn FnMut(&str)>;
#[cfg(test)]
thread_local! {
    /// A test's hook right after a sweep read a durable marker.
    static SWEEP_PAUSE: std::cell::RefCell<Option<(PauseFn, Reached)>> =
        const { std::cell::RefCell::new(None) };
}
RS
passes "SWEEP_PAUSE in a thread_local!"

# A slot of another value is still a test slot under #[cfg(test)], and inside a test module.
cat >"$src/meta.rs" <<'RS'
#[cfg(test)]
pub(crate) static SETTLE_HOLD: std::sync::Mutex<Option<SettleHold>> = std::sync::Mutex::new(None);
RS
refused cmux-tui/crates/acpmux/src/meta.rs 2 "a #[cfg(test)] Mutex<Option<_>>"
cat >"$src/meta.rs" <<'RS'
fn real() {}

#[cfg(test)]
mod tests {
    static HELD: std::sync::RwLock<Option<String>> = std::sync::RwLock::new(None);
}
RS
refused cmux-tui/crates/acpmux/src/meta.rs 5 "a slot inside a #[cfg(test)] module"
cat >"$src/meta_tests.rs" <<'RS'
static HELD: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);
RS
refused cmux-tui/crates/acpmux/src/meta_tests.rs 1 "a slot in a test file"
rm "$src/meta.rs" "$src/meta_tests.rs"

# A closure in a OnceLock, directly, as a fn pointer, or through a type alias of the file.
printf 'pub static SAVE_CHECKED: std::sync::OnceLock<fn(bool)> = std::sync::OnceLock::new();\n' >"$src/text.rs"
refused cmux-tui/crates/acpmux/src/text.rs 1 "a fn pointer in a OnceLock"
cat >"$src/text.rs" <<'RS'
type Seam = Arc<
    dyn Fn(String) -> Pin<Box<dyn Future<Output = Result<bool, RpcError>> + Send>> + Send + Sync,
>;
static SEAM: std::sync::LazyLock<std::sync::Mutex<Vec<Seam>>> = std::sync::LazyLock::new(Default::default);
RS
refused cmux-tui/crates/acpmux/src/text.rs 4 "a closure alias in a LazyLock"
rm "$src/text.rs"

# Any static named as a hook, pub or not.
printf 'pub static EXIT_HOOK: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);\n' >"$src/exit.rs"
refused cmux-tui/crates/acpmux/src/exit.rs 1 "a pub static ...HOOK"
rm "$src/exit.rs"

# The READ_HOOK shape: allowed by a marker naming its serializer, which must exist in the file.
cat >"$src/hub/watches.rs" <<'RS'
#[cfg(test)]
type ReadHook = Arc<dyn Fn(String) -> bool + Send + Sync>;
// test-hook-allow: serialized by HOOK_TEST, which both tests that set it hold until they clear it
#[cfg(test)]
static READ_HOOK: OnceLock<Mutex<Option<ReadHook>>> = OnceLock::new();

#[cfg(test)]
mod tests {
    static HOOK_TEST: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
}
RS
passes "READ_HOOK under HOOK_TEST with its marker"
sed -i 's/static HOOK_TEST/static OTHER_LOCK/' "$src/hub/watches.rs"
refused cmux-tui/crates/acpmux/src/hub/watches.rs 5 "a marker naming a serializer the file lacks"
sed -i 's/static OTHER_LOCK: tokio::sync::Mutex<()>/static HOOK_TEST: tokio::sync::Mutex<u8>/' "$src/hub/watches.rs"
refused cmux-tui/crates/acpmux/src/hub/watches.rs 5 "a serializer that is not a Mutex<()>"
sed -i 's|^// test-hook-allow: .*|// test-hook-allow: fine|' "$src/hub/watches.rs"
refused cmux-tui/crates/acpmux/src/hub/watches.rs 5 "a marker with no reason"
sed -i 's|^// test-hook-allow: .*|// Some comment.|' "$src/hub/watches.rs"
refused cmux-tui/crates/acpmux/src/hub/watches.rs 5 "READ_HOOK without its marker"
rm "$src/hub/watches.rs"

# A marker on another static does not cover this one.
cat >"$src/two.rs" <<'RS'
// test-hook-allow: one process per test, set once by its only test
pub static A_HOOK: std::sync::OnceLock<fn(bool)> = std::sync::OnceLock::new();

pub static B_HOOK: std::sync::OnceLock<fn(bool)> = std::sync::OnceLock::new();
RS
refused cmux-tui/crates/acpmux/src/two.rs 4 "a marker two lines up, past a blank line"
rm "$src/two.rs"

# The file's own names are resolved before the static is judged: a direct alias of the whole cell (cmux#41355 F1).
cat >"$src/alias.rs" <<'RS'
type HookCell = Mutex<Option<Box<dyn Fn()>>>;
static H: HookCell = Mutex::new(None);
RS
refused cmux-tui/crates/acpmux/src/alias.rs 2 "a direct alias of a closure cell" "closure"
# Transitive aliases, in either order of definition.
cat >"$src/alias.rs" <<'RS'
type A = Mutex<Option<B>>;
type B = Box<dyn Fn()>;
static H: A = Mutex::new(None);
RS
refused cmux-tui/crates/acpmux/src/alias.rs 3 "a transitive alias (type A = Mutex<Option<B>>; type B = Box<dyn Fn()>)" "closure"
cat >"$src/alias.rs" <<'RS'
type Seam = OnceLock<Inner>;
type Inner = Step;
type Step = fn(bool);
pub static SEAM: Seam = OnceLock::new();
RS
refused cmux-tui/crates/acpmux/src/alias.rs 4 "a three-step alias to a fn pointer" "closure"
cat >"$src/alias.rs" <<'RS'
type Slot<T> = Mutex<Option<T>>;
#[cfg(test)]
static HELD: Slot<String> = Mutex::new(None);
RS
refused cmux-tui/crates/acpmux/src/alias.rs 3 "a generic alias of a test slot" "test slot"
# A generic alias's arguments are put in for its parameters by position; one it does not use is dropped (#41383 F1).
cat >"$src/alias.rs" <<'RS'
struct Cached { at: u64 }
type Cache<T> = Mutex<Option<Cached>>;
static CACHE: Cache<fn()> = Mutex::new(None);
RS
passes "a generic alias that does not use its fn() argument"
cat >"$src/alias.rs" <<'RS'
type Slot<T> = Mutex<Option<T>>;
static S: Slot<Box<dyn Fn()>> = Mutex::new(None);
RS
refused cmux-tui/crates/acpmux/src/alias.rs 2 "a generic alias given a closure it holds" "closure"
cat >"$src/alias.rs" <<'RS'
struct Cached { at: u64 }
type Pair<A, B> = Mutex<Option<A>>;
static P: Pair<Cached, Box<dyn Fn()>> = Mutex::new(None);
static Q: Pair<Cached, Unseen> = Mutex::new(None);
RS
passes "a two-parameter alias that uses only its first, given a closure and an unseen name second"
cat >"$src/alias.rs" <<'RS'
struct Cached { at: u64 }
type Pair<A, B> = Mutex<Option<A>>;
static P: Pair<Box<dyn Fn()>, Cached> = Mutex::new(None);
RS
refused cmux-tui/crates/acpmux/src/alias.rs 3 "a two-parameter alias given a closure in the parameter it uses" "closure"
cat >"$src/alias.rs" <<'RS'
type Inner<A, B> = std::sync::OnceLock<B>;
type Outer<T> = Inner<u8, T>;
type Wrong<T> = Inner<T, u8>;
static O: Outer<fn(bool)> = std::sync::OnceLock::new();
static W: Wrong<fn(bool)> = std::sync::OnceLock::new();
RS
refused cmux-tui/crates/acpmux/src/alias.rs 4 "a nested alias passing its closure on to the parameter used" "closure"
case "$(python3 -I "$check" "$tmp" || true)" in *alias.rs:5:*) fail "a nested alias passing its closure to an unused parameter: refused" ;; esac
# One ordered substitution pass (#41418 F1-F3): arguments, then defaults in order, then the body, then names.
# F1: a default sees the parameters bound before it.
cat >"$src/alias.rs" <<'RS'
struct Pair<T, U = T> { first: T, second: U }
static PAIR: std::sync::Mutex<Pair<u8>> = std::sync::Mutex::new(Pair { first: 0, second: 0 });
RS
passes "a default naming an earlier parameter (struct Pair<T, U = T>, Mutex<Pair<u8>>)"
cat >"$src/alias.rs" <<'RS'
type Later<T, U = T> = std::sync::OnceLock<U>;
static LATER: Later<fn(bool)> = std::sync::OnceLock::new();
RS
refused cmux-tui/crates/acpmux/src/alias.rs 2 "a default naming an earlier parameter given a fn pointer" "closure"
# F2: a parameter named as a prelude name is the parameter.
cat >"$src/alias.rs" <<'RS'
type Slot<Future> = Mutex<Option<Future>>;
static S: Slot<fn()> = Mutex::new(None);
RS
refused cmux-tui/crates/acpmux/src/alias.rs 2 "a parameter named Future given a fn pointer" "closure"
# F3: a projection of a parameter keeps its argument and is unresolved, never dropped.
cat >"$src/alias.rs" <<'RS'
trait Callback { type Hook; }
impl Callback for fn() { type Hook = fn(); }
type Slot<T: Callback> = Mutex<Option<T::Hook>>;
static S: Slot<fn()> = Mutex::new(None);
RS
refused cmux-tui/crates/acpmux/src/alias.rs 4 "T::Hook with T a fn pointer"
cat >"$src/alias.rs" <<'RS'
struct Cached { at: u64 }
type Slot<T: Callback> = Mutex<Option<T::Hook>>;
static S: Slot<Cached> = Mutex::new(None);
RS
refused cmux-tui/crates/acpmux/src/alias.rs 3 "T::Hook with T a struct of the file" "unresolved"
# A struct of the file is judged by its fields, and a renamed cell is a cell.
cat >"$src/alias.rs" <<'RS'
struct Hooks {
    on_read: Mutex<Option<Box<dyn Fn(&str) + Send>>>,
}
static HOOKS: Hooks = Hooks { on_read: Mutex::new(None) };
RS
refused cmux-tui/crates/acpmux/src/alias.rs 4 "a struct field holding a closure cell" "closure"
cat >"$src/alias.rs" <<'RS'
use std::sync::{Arc, Mutex as StdMutex};
#[cfg(test)]
static HELD: StdMutex<Option<Arc<str>>> = StdMutex::new(None);
RS
refused cmux-tui/crates/acpmux/src/alias.rs 3 "a test slot in a renamed Mutex" "test slot"
# Resolved production state still passes: an alias of a cache, a struct of atomics, an array of serializers.
cat >"$src/alias.rs" <<'RS'
use std::path::PathBuf;
use std::sync::atomic::AtomicU64;
type SizeCache = std::sync::Mutex<Option<(std::time::Instant, PathBuf, Option<u64>)>>;
static CACHE: SizeCache = std::sync::Mutex::new(None);
struct SizeWatch { near_cap: AtomicU64, inner: std::sync::Mutex<Inner> }
struct Inner { last: Option<u64> }
static GLOBAL: SizeWatch = SizeWatch::new();
const SLOTS: usize = 64;
static LOCKS: [std::sync::Mutex<()>; SLOTS] = [const { std::sync::Mutex::new(()) }; SLOTS];
RS
passes "resolved production state: an aliased cache, a struct of atomics, an array of serializers"
rm "$src/alias.rs"

# thread_local! in both forms, and task_local!, is per thread (or task), not process-wide (cmux#41355 F2).
cat >"$src/local.rs" <<'RS'
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
RS
passes "thread_local!( ) and thread_local! { } hooks, task_local! in both forms"
# The per-thread span ends with its macro: a static after it is judged.
cat >>"$src/local.rs" <<'RS'
pub static AFTER_HOOK: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
RS
refused cmux-tui/crates/acpmux/src/local.rs 14 "a process-wide hook after a thread_local!( )"
rm "$src/local.rs"

# A name the file does not show is unresolved, never passed: at the head of the type, or in a cell.
cat >"$src/unseen.rs" <<'RS'
use crate::hooks::HookCell;
static H: HookCell = HookCell::new();
RS
refused cmux-tui/crates/acpmux/src/unseen.rs 2 "an imported alias heading the type" "unresolved"
cat >"$src/unseen.rs" <<'RS'
use super::*;
static PENDING: std::sync::OnceLock<Pending> = std::sync::OnceLock::new();
RS
refused cmux-tui/crates/acpmux/src/unseen.rs 2 "a glob-imported name in a cell" "unresolved"
cat >"$src/unseen.rs" <<'RS'
static SEAM: std::sync::Mutex<Vec<super::seams::Seam>> = std::sync::Mutex::new(Vec::new());
RS
refused cmux-tui/crates/acpmux/src/unseen.rs 1 "a crate path in a cell" "unresolved"
cat >"$src/unseen.rs" <<'RS'
// test-hook-allow: holds the parsed route file, no closure
static LAST: std::sync::Mutex<Option<crate::route::RouteFile>> = std::sync::Mutex::new(None);
RS
passes "an unresolved static with a reasoned marker"
rm "$src/unseen.rs"

# BASE_CHECK: the check at origin/feat-cmux-next. Generated alias chains: whatever it refuses, this check refuses.
if [ -n "${BASE_CHECK:-}" ]; then
  python3 -I "$repo/scripts/cmux-next/tests/check-test-hooks-property.py" "$check" "$BASE_CHECK" \
    || fail "every hook base finds the head refuses too, on generated alias chains"
fi

if [ "$failures" -gt 0 ]; then
  echo "check-test-hooks tests: $failures failed" >&2
  exit 1
fi

# The repository's own tree: shown, not failed; the pre-push gate refuses only a hook a push adds.
python3 -I "$check" "$repo" || echo "note: the repository still has the process-wide test hooks above"
echo "check-test-hooks tests: ok"
