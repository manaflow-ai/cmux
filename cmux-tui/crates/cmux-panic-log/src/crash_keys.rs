//! Crash keys of cmux's background processes (plans/cmux-next/chrome-parity/p10-stability.md
//! section 3B, task 207).
//!
//! Chrome keeps each crash key in static storage that exists before the
//! crash (`components/crash/core/common/crash_key.h`), `ScopedCrashKeyString`
//! puts the outer value back at scope exit, and Chrome's `HangWatcher`
//! (`base/threading/hang_watcher.cc`) names the hung threads in the dump it
//! takes. Here every key is one static `AtomicU64` written and read with
//! relaxed atomics: setting, scoping and reading a key ([`snapshot`])
//! allocate nothing and take no lock, so a panic hook or a hang reporter can
//! read them on any thread.
//!
//! Every value is a number (a catalog name's [`stable_key`], a kind, an
//! epoch, a thread id), never a person's text, so the keys need no
//! scrubbing; [`Snapshot::parse`] keeps only the names and decimal values
//! this module writes, so a damaged or planted record never reaches a
//! report. The record line ([`Snapshot::write_line`]) is the one the app's
//! crash path writes (`CrashKeys` in CmuxNextCrashReporting):
//! `crash_keys action_id=1234 daemon_epoch=3 hung_threads=1 hung_kind_0=3`.
//! The panic hook adds the same keys to each panic line as `crash_keys`.
//!
//! Two scopes. [`set`] and [`scoped`] write the process's value, for state
//! one owner moves (an epoch). A daemon serves many requests at once on a
//! pool of threads, so a request's [`Key::ActionId`] is this thread's own
//! instead ([`scoped_thread`], and [`keyed`] for a future: set for each poll
//! on the thread polling it). The panic hook runs on the panicking thread,
//! so its line names the request that thread was running; a thread's value
//! wins over the process's in [`snapshot`].
//!
//! Who writes what: the acpmux daemon names each request's method
//! ([`keyed`] around its dispatch, `server/mod.rs`) and the session owner
//! each command's (`connection_frame.rs`). Pane kind, Chromium state and
//! daemon epoch are the app's keys (`CrashKeySlots` in CmuxNextWakeups);
//! these processes keep the slots so the record format is one, and set
//! none. The hung threads are for the daemons' hang watch to name
//! ([`note_hung`]), which p09-observability-071 wires.

use std::cell::Cell;
use std::future::Future;
use std::marker::PhantomData;
use std::sync::atomic::{AtomicU64, Ordering};

/// One single-word key. The names and their order match the app's
/// `CrashKeySlots.Key`, so one record format serves both.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Key {
    /// The running action or request method, as [`stable_key`] of its name;
    /// 0 outside one.
    ActionId,
    /// The pane kind the work is for (the app's `CrashKeySlots.PaneKind`
    /// numbers), 0 when none.
    PaneKind,
    /// The Chromium runtime's state (the app's `CrashKeySlots.CEFState`
    /// numbers), 0 when Chromium never started.
    CefState,
    /// The daemon's connection or session epoch, 0 before the first.
    DaemonEpoch,
}

impl Key {
    /// Every key, in record order.
    pub const ALL: [Key; 4] = [Key::ActionId, Key::PaneKind, Key::CefState, Key::DaemonEpoch];

    /// The key's name in a record and a report's tags (`crash_key.<name>`).
    pub const fn name(self) -> &'static str {
        match self {
            Key::ActionId => "action_id",
            Key::PaneKind => "pane_kind",
            Key::CefState => "cef_state",
            Key::DaemonEpoch => "daemon_epoch",
        }
    }

    const fn index(self) -> usize {
        match self {
            Key::ActionId => 0,
            Key::PaneKind => 1,
            Key::CefState => 2,
            Key::DaemonEpoch => 3,
        }
    }
}

/// Hung-thread entries the process keeps; a ninth concurrent hang is not
/// named (the hang log has every report).
pub const HUNG_THREAD_CAPACITY: usize = 8;
/// The longest line [`Snapshot::write_line`] writes, its newline included.
pub const MAX_RECORD_BYTES: usize = 512;

#[allow(
    clippy::declare_interior_mutable_const,
    reason = "the initializer of the static arrays below: each element is its own atomic"
)]
const ZERO: AtomicU64 = AtomicU64::new(0);
static KEYS: [AtomicU64; 4] = [ZERO; 4];
static HUNG: [AtomicU64; HUNG_THREAD_CAPACITY] = [ZERO; HUNG_THREAD_CAPACITY];

thread_local! {
    /// This thread's own values (0: none), over the process's. Const
    /// initialized with no destructor: reading or writing allocates nothing.
    static THREAD_KEYS: [Cell<u64>; 4] = const { [const { Cell::new(0) }; 4] };
}

/// A catalog name (an action id, a request method) as a key value: FNV-1a 64
/// of its UTF-8 bytes, never 0. The app's `CrashKeySlots.stableKey` computes
/// the same number.
pub const fn stable_key(name: &str) -> u64 {
    let bytes = name.as_bytes();
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    let mut index = 0;
    while index < bytes.len() {
        hash = (hash ^ bytes[index] as u64).wrapping_mul(0x0000_0100_0000_01b3);
        index += 1;
    }
    if hash == 0 { 1 } else { hash }
}

/// Stores `value` in `key` (one relaxed store).
pub fn set(key: Key, value: u64) {
    KEYS[key.index()].store(value, Ordering::Relaxed);
}

/// The value `key` holds now (0 when never set).
pub fn get(key: Key) -> u64 {
    KEYS[key.index()].load(Ordering::Relaxed)
}

/// Sets `key` to `value` until the guard drops, then puts the value it
/// replaced back (Chrome's `ScopedCrashKeyString`).
#[must_use = "the key is put back when the guard drops"]
pub fn scoped(key: Key, value: u64) -> Scoped {
    Scoped { key, outer: KEYS[key.index()].swap(value, Ordering::Relaxed) }
}

/// A key set by [`scoped`]; dropping it restores the outer value.
#[derive(Debug)]
pub struct Scoped {
    key: Key,
    outer: u64,
}

impl Drop for Scoped {
    fn drop(&mut self) {
        set(self.key, self.outer);
    }
}

/// This thread's own value of `key` (0 when it has none; also after the
/// thread's locals are gone).
pub fn thread_value(key: Key) -> u64 {
    THREAD_KEYS.try_with(|keys| keys[key.index()].get()).unwrap_or(0)
}

/// Sets `key` to `value` on this thread until the guard drops, then puts
/// this thread's value it replaced back. For work many threads run at once
/// (requests on a pool); the guard stays on its thread.
#[must_use = "the key is put back when the guard drops"]
pub fn scoped_thread(key: Key, value: u64) -> ThreadScoped {
    let outer = THREAD_KEYS.try_with(|keys| keys[key.index()].replace(value)).unwrap_or(0);
    ThreadScoped { key, outer, _thread: PhantomData }
}

/// A key set by [`scoped_thread`]; dropping it restores this thread's outer
/// value. Not `Send`: it belongs to the thread that set it.
#[derive(Debug)]
pub struct ThreadScoped {
    key: Key,
    outer: u64,
    _thread: PhantomData<*const ()>,
}

impl Drop for ThreadScoped {
    fn drop(&mut self) {
        let _ = THREAD_KEYS.try_with(|keys| keys[self.key.index()].set(self.outer));
    }
}

/// Runs `future` with `key` set to `value` on whichever thread polls it,
/// for each poll ([`scoped_thread`] around each one, like `tracing`'s
/// `Instrumented`): a panic while the future runs names it, and a future
/// that moves between a runtime's workers takes its key along. Allocates
/// nothing.
pub async fn keyed<F: Future>(key: Key, value: u64, future: F) -> F::Output {
    let mut future = std::pin::pin!(future);
    std::future::poll_fn(|context| {
        let _key = scoped_thread(key, value);
        future.as_mut().poll(context)
    })
    .await
}

/// A thread a hang reporter found past its deadline whose scope is still
/// open.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct HungThread {
    /// The thread's id (its Mach port or OS thread id; never 0 for a set
    /// entry). In-process only: a record keeps only the kind.
    pub id: u32,
    /// What the thread runs (the hang watch's thread kind numbers).
    pub kind: u8,
}

impl HungThread {
    const fn packed(self) -> u64 {
        (self.kind as u64) << 32 | self.id as u64
    }

    const fn unpack(word: u64) -> Option<HungThread> {
        if word & 0xffff_ffff == 0 {
            return None;
        }
        Some(HungThread { id: word as u32, kind: (word >> 32) as u8 })
    }
}

/// Names `thread` among the hung threads (the hang reporter, when it
/// reports a scope past its deadline). Returns false when every entry is
/// taken or the id is 0. The hang reporter's thread is the one writer.
pub fn note_hung(thread: HungThread) -> bool {
    if thread.id == 0 {
        return false;
    }
    for entry in &HUNG {
        if HungThread::unpack(entry.load(Ordering::Relaxed))
            .is_some_and(|hung| hung.id == thread.id)
        {
            entry.store(thread.packed(), Ordering::Relaxed);
            return true;
        }
    }
    HUNG.iter().any(|entry| {
        entry.compare_exchange(0, thread.packed(), Ordering::Relaxed, Ordering::Relaxed).is_ok()
    })
}

/// Takes the thread `id` off the hung threads (its scope ended).
pub fn clear_hung(id: u32) {
    if id == 0 {
        return;
    }
    for entry in &HUNG {
        let word = entry.load(Ordering::Relaxed);
        if HungThread::unpack(word).is_some_and(|hung| hung.id == id) {
            let _ = entry.compare_exchange(word, 0, Ordering::Relaxed, Ordering::Relaxed);
        }
    }
}

/// Every key and hung-thread entry now, as the calling thread sees them
/// (its own value of a key, else the process's), with relaxed loads: no
/// allocation, no lock.
pub fn snapshot() -> Snapshot {
    let mut snapshot = Snapshot::default();
    for key in Key::ALL {
        snapshot.keys[key.index()] = match thread_value(key) {
            0 => get(key),
            own => own,
        };
    }
    for (slot, entry) in snapshot.hung.iter_mut().zip(&HUNG) {
        *slot = entry.load(Ordering::Relaxed);
    }
    snapshot
}

/// The keys of one moment: fixed arrays, so taking one allocates nothing.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Snapshot {
    keys: [u64; 4],
    hung: [u64; HUNG_THREAD_CAPACITY],
}

impl Snapshot {
    /// The value of `key`.
    pub fn get(&self, key: Key) -> u64 {
        self.keys[key.index()]
    }

    /// Sets `key` (a snapshot built by hand or read back from a record).
    pub fn set(&mut self, key: Key, value: u64) {
        self.keys[key.index()] = value;
    }

    /// The hung-thread entries that are set, in entry order.
    pub fn hung_threads(&self) -> impl Iterator<Item = HungThread> + '_ {
        self.hung.iter().filter_map(|&word| HungThread::unpack(word))
    }

    /// Whether no key and no hung thread is set.
    pub fn is_empty(&self) -> bool {
        self.keys.iter().chain(&self.hung).all(|&word| word == 0)
    }

    /// Writes the record line into `buffer` (at least [`MAX_RECORD_BYTES`]
    /// for a whole line; a shorter buffer gets a cut line) and returns its
    /// length. No allocation, no lock.
    pub fn write_line(&self, buffer: &mut [u8]) -> usize {
        let mut line = LineWriter { buffer, len: 0 };
        line.text("crash_keys");
        for key in Key::ALL {
            line.field(key.name(), self.get(key));
        }
        line.field("hung_threads", self.hung_threads().count() as u64);
        for (index, thread) in self.hung_threads().enumerate() {
            line.text(" hung_kind_");
            line.decimal(index as u64);
            line.text("=");
            line.decimal(u64::from(thread.kind));
        }
        line.text("\n");
        line.len
    }

    /// The keys of a line [`write_line`](Self::write_line) wrote; `None`
    /// when `record` is not one. Unknown names, values that are not decimal
    /// numbers and hung-thread kinds past the capacity are dropped. A record
    /// keeps kinds, not ids: entry n reads back with id n + 1.
    pub fn parse(record: &str) -> Option<Snapshot> {
        let mut words = record.split([' ', '\n']).filter(|word| !word.is_empty());
        if words.next()? != "crash_keys" {
            return None;
        }
        let mut snapshot = Snapshot::default();
        let mut kinds = 0;
        for word in words {
            let Some((name, value)) = word.split_once('=') else { continue };
            if value.is_empty()
                || value.len() > 20
                || !value.bytes().all(|byte| byte.is_ascii_digit())
            {
                continue;
            }
            let Ok(value) = value.parse::<u64>() else { continue };
            if let Some(key) = Key::ALL.into_iter().find(|key| key.name() == name) {
                snapshot.set(key, value);
            } else if name.starts_with("hung_kind_") && kinds < HUNG_THREAD_CAPACITY {
                let Ok(kind) = u8::try_from(value) else { continue };
                snapshot.hung[kinds] = HungThread { id: kinds as u32 + 1, kind }.packed();
                kinds += 1;
            }
        }
        Some(snapshot)
    }

    /// The keys as a panic line's `crash_keys` object: each set key by name,
    /// and the hung threads' count and kinds. Ids are left out (they mean
    /// nothing outside the process).
    pub fn to_json(&self) -> serde_json::Value {
        let mut object = serde_json::Map::new();
        for key in Key::ALL {
            let value = self.get(key);
            if value != 0 {
                object.insert(key.name().into(), value.into());
            }
        }
        let kinds: Vec<serde_json::Value> =
            self.hung_threads().map(|thread| thread.kind.into()).collect();
        if !kinds.is_empty() {
            object.insert("hung_threads".into(), kinds.len().into());
            object.insert("hung_thread_kinds".into(), kinds.into());
        }
        serde_json::Value::Object(object)
    }
}

/// Appends ASCII to a caller's buffer; stops at its end.
struct LineWriter<'a> {
    buffer: &'a mut [u8],
    len: usize,
}

impl LineWriter<'_> {
    fn byte(&mut self, byte: u8) {
        if let Some(slot) = self.buffer.get_mut(self.len) {
            *slot = byte;
            self.len += 1;
        }
    }

    fn text(&mut self, text: &str) {
        for &byte in text.as_bytes() {
            self.byte(byte);
        }
    }

    /// ` name=value`, left out when `value` is 0.
    fn field(&mut self, name: &str, value: u64) {
        if value == 0 {
            return;
        }
        self.byte(b' ');
        self.text(name);
        self.byte(b'=');
        self.decimal(value);
    }

    fn decimal(&mut self, value: u64) {
        let mut divisor: u64 = 1;
        while value / divisor >= 10 {
            divisor *= 10;
        }
        let mut rest = value;
        while divisor > 0 {
            self.byte(b'0' + (rest / divisor) as u8);
            rest %= divisor;
            divisor /= 10;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stable_key_is_fnv1a_and_never_zero() {
        assert_eq!(stable_key(""), 0xcbf2_9ce4_8422_2325);
        assert_eq!(stable_key("a"), 0xaf63_dc4c_8601_ec8c);
        assert_ne!(stable_key("workspace.new"), stable_key("workspace.close"));
    }

    #[test]
    fn a_record_round_trips_without_thread_ids() {
        let mut snapshot = Snapshot::default();
        snapshot.set(Key::ActionId, stable_key("workspace.new"));
        snapshot.set(Key::DaemonEpoch, 3);
        snapshot.hung[2] = HungThread { id: 4242, kind: 3 }.packed();
        let mut buffer = [0u8; MAX_RECORD_BYTES];
        let len = snapshot.write_line(&mut buffer);
        let line = std::str::from_utf8(&buffer[..len]).unwrap();
        assert_eq!(
            line,
            format!(
                "crash_keys action_id={} daemon_epoch=3 hung_threads=1 hung_kind_0=3\n",
                stable_key("workspace.new")
            )
        );
        assert!(!line.contains("4242"), "a record never holds a thread id: {line}");
        let back = Snapshot::parse(line).unwrap();
        assert_eq!(back.get(Key::ActionId), stable_key("workspace.new"));
        assert_eq!(back.get(Key::DaemonEpoch), 3);
        assert_eq!(back.hung_threads().collect::<Vec<_>>(), vec![HungThread { id: 1, kind: 3 }]);
    }

    #[test]
    fn parsing_drops_everything_it_did_not_write() {
        let planted = "crash_keys action_id=12 path=/Users/someone/secret pane_kind=0x41 cef_state=-1 \
                       daemon_epoch=99999999999999999999999 token=abc hung_kind_0=300 hung_kind_1=2";
        let back = Snapshot::parse(planted).unwrap();
        assert_eq!(back.get(Key::ActionId), 12);
        assert_eq!(back.get(Key::PaneKind), 0);
        assert_eq!(back.get(Key::CefState), 0);
        assert_eq!(back.get(Key::DaemonEpoch), 0);
        assert_eq!(back.hung_threads().map(|thread| thread.kind).collect::<Vec<_>>(), vec![2]);
        let json = back.to_json().to_string();
        assert!(!json.contains("secret") && !json.contains("abc"), "{json}");
        assert!(Snapshot::parse("not a record").is_none());
    }

    /// Each unit test that touches the process's keys uses a key no other one does.
    #[test]
    fn a_scope_puts_the_outer_value_back_and_a_full_table_names_no_more() {
        let _outer = scoped(Key::CefState, 2);
        {
            let _inner = scoped(Key::CefState, 3);
            assert_eq!(get(Key::CefState), 3);
        }
        assert_eq!(get(Key::CefState), 2);
        for id in 1..=HUNG_THREAD_CAPACITY as u32 {
            assert!(note_hung(HungThread { id, kind: 1 }));
        }
        assert!(note_hung(HungThread { id: 3, kind: 4 }), "a named thread is updated in place");
        assert!(!note_hung(HungThread { id: 99, kind: 1 }), "a ninth thread is not named");
        assert!(!note_hung(HungThread { id: 0, kind: 1 }));
        assert_eq!(snapshot().hung_threads().count(), HUNG_THREAD_CAPACITY);
        for id in 1..=HUNG_THREAD_CAPACITY as u32 {
            clear_hung(id);
        }
        assert!(snapshot().hung_threads().next().is_none());
    }

    #[test]
    fn a_thread_key_wins_over_the_process_key_on_its_own_thread_only() {
        let _process = scoped(Key::PaneKind, 4);
        {
            let _own = scoped_thread(Key::PaneKind, 9);
            assert_eq!(snapshot().get(Key::PaneKind), 9);
            let other = std::thread::spawn(|| snapshot().get(Key::PaneKind)).join().unwrap();
            assert_eq!(other, 4, "another thread saw this thread's key");
        }
        assert_eq!(snapshot().get(Key::PaneKind), 4, "the thread's outer value is back");
    }

    #[test]
    fn a_keyed_future_names_its_key_in_each_poll_only() {
        let mut seen = Vec::new();
        {
            let future = keyed(
                Key::ActionId,
                42,
                std::future::poll_fn(|context| {
                    seen.push(thread_value(Key::ActionId));
                    if seen.len() < 2 {
                        context.waker().wake_by_ref();
                        std::task::Poll::Pending
                    } else {
                        std::task::Poll::Ready(())
                    }
                }),
            );
            let mut future = std::pin::pin!(future);
            let mut context = std::task::Context::from_waker(std::task::Waker::noop());
            assert!(future.as_mut().poll(&mut context).is_pending());
            assert_eq!(thread_value(Key::ActionId), 0, "the key outlived its poll");
            assert!(future.as_mut().poll(&mut context).is_ready());
        }
        assert_eq!(seen, vec![42, 42]);
    }

    #[test]
    fn the_longest_record_fits() {
        let mut snapshot = Snapshot { keys: [u64::MAX; 4], hung: [0; HUNG_THREAD_CAPACITY] };
        for (index, word) in snapshot.hung.iter_mut().enumerate() {
            *word = HungThread { id: index as u32 + 1, kind: u8::MAX }.packed();
        }
        let mut buffer = [0u8; MAX_RECORD_BYTES];
        let len = snapshot.write_line(&mut buffer);
        assert!(len < MAX_RECORD_BYTES);
        assert_eq!(buffer[len - 1], b'\n');
    }
}
