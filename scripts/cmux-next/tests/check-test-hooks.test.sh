#!/usr/bin/env bash
# check-test-hooks.py: no process-wide test hooks in acpmux (cmux#41350). Run it yourself after
# changing the check; it is not a CI step (CLAUDE.md: no new CI tests).
set -euo pipefail
repo="$(cd "$(dirname "$0")/../../.." && pwd)"
check="$repo/scripts/cmux-next/check-test-hooks.py"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
src="$tmp/cmux-tui/crates/acpmux/src"
mkdir -p "$src/hub"

# refused FILE LINE CASE: the check fails and names FILE:LINE.
refused() {
  local out
  if out="$(python3 -I "$check" "$tmp")"; then fail "$3: must be refused"; fi
  case "$out" in *"$1:$2:"*) ;; *) fail "$3: $1:$2 not named: $out" ;; esac
}
passes() {
  python3 -I "$check" "$tmp" >/dev/null || fail "$1: must pass: $(python3 -I "$check" "$tmp")"
}

# Production state, per-thread hooks and serializers themselves are not hooks.
cat >"$src/lib.rs" <<'RS'
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

# The repository's own tree: shown, not failed; the pre-push gate refuses only a hook a push adds.
python3 -I "$check" "$repo" || echo "note: the repository still has the process-wide test hooks above"
echo "check-test-hooks tests: ok"
