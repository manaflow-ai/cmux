//! The panic boundary of every in-app Rust C ABI (`include/cmux_ffi_guard.h`).
//!
//! Since Rust 1.81 a panic that reaches an `extern "C" fn` aborts the
//! process, and CCmuxAppFFI runs inside the cmux app. Chromium never lets a
//! Rust panic cross its FFI either (`build/rust/`: cxx bridges, no unwind
//! across the boundary); cmux keeps the app alive instead of turning the
//! panic into a CHECK: every export runs its body in [`ffi_boundary`], which
//! catches the unwind, stores the panic in a fixed ring and returns the
//! export's documented error value. The app drains the ring with
//! [`cmux_ffi_take_panic`] and forwards each record to crash reporting, the
//! way Chrome's crash keys are preallocated and read later
//! (`components/crash/core/common/crash_key.h`).
//!
//! The ring is lock free and allocation free: a panic in one export never
//! waits on another thread, and a panic while the app reads never blocks.
//! When the app does not read, the newest records overwrite the oldest;
//! `sequence` numbers show what was lost.

use std::any::Any;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicU32, AtomicU64, Ordering};

/// Bytes of an export name a record keeps (`CMUX_FFI_PANIC_NAME_CAP`).
pub const NAME_CAP: usize = 64;
/// Bytes of a panic message a record keeps (`CMUX_FFI_PANIC_MESSAGE_CAP`).
pub const MESSAGE_CAP: usize = 256;
/// Records the ring holds before the newest overwrite the oldest.
pub const RING_SLOTS: usize = 16;

/// Runs `body`, the whole body of the export `name`. A panic is caught,
/// stored in the ring and turned into `default`, the export's documented
/// error value. An export that repairs its own state after a panic passes
/// `None` and wraps its result in `Some`.
#[inline]
pub fn ffi_boundary<R>(name: &'static str, default: R, body: impl FnOnce() -> R) -> R {
    catch_unwind(AssertUnwindSafe(|| {
        #[cfg(feature = "testing")]
        testing::fire(name);
        body()
    }))
    .unwrap_or_else(|payload| {
        let message = panic_message(payload.as_ref());
        RING.record(name, message);
        #[cfg(feature = "testing")]
        testing::note(name);
        default
    })
}

fn panic_message(payload: &(dyn Any + Send)) -> &str {
    if let Some(text) = payload.downcast_ref::<&'static str>() {
        text
    } else if let Some(text) = payload.downcast_ref::<String>() {
        text
    } else {
        "panic payload is not a string"
    }
}

/// One stored panic (`CmuxFfiPanic`). `name` and `message` are UTF-8 of
/// `name_len` and `message_len` bytes, not NUL-terminated; `truncated` when
/// the message was longer than [`MESSAGE_CAP`] (cut on a character boundary).
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CmuxFfiPanic {
    /// 1 for the process's first guarded panic, then one more per panic; a
    /// gap between two records counts the panics the ring lost.
    pub sequence: u64,
    pub name_len: u32,
    pub message_len: u32,
    pub truncated: bool,
    pub name: [u8; NAME_CAP],
    pub message: [u8; MESSAGE_CAP],
}

impl CmuxFfiPanic {
    /// A record with no panic in it.
    pub const EMPTY: Self = Self {
        sequence: 0,
        name_len: 0,
        message_len: 0,
        truncated: false,
        name: [0; NAME_CAP],
        message: [0; MESSAGE_CAP],
    };

    /// The export name.
    pub fn name(&self) -> &str {
        utf8_prefix(&self.name, self.name_len)
    }

    /// The panic message.
    pub fn message(&self) -> &str {
        utf8_prefix(&self.message, self.message_len)
    }
}

fn utf8_prefix(bytes: &[u8], len: u32) -> &str {
    let len = usize::try_from(len).unwrap_or(usize::MAX).min(bytes.len());
    let bytes = bytes.get(..len).unwrap_or_default();
    std::str::from_utf8(bytes).unwrap_or_default()
}

const EMPTY: u8 = 0;
const WRITING: u8 = 1;
const FULL: u8 = 2;
const READING: u8 = 3;

/// One record slot. The state is the only synchronization: a writer owns
/// the slot from EMPTY or FULL to WRITING until it stores FULL (Release); a
/// reader owns it from FULL to READING until it stores EMPTY (Release).
struct Slot {
    state: AtomicU8,
    sequence: AtomicU64,
    name_len: AtomicU32,
    message_len: AtomicU32,
    truncated: AtomicBool,
    name: [AtomicU8; NAME_CAP],
    message: [AtomicU8; MESSAGE_CAP],
}

impl Slot {
    const fn new() -> Self {
        Self {
            state: AtomicU8::new(EMPTY),
            sequence: AtomicU64::new(0),
            name_len: AtomicU32::new(0),
            message_len: AtomicU32::new(0),
            truncated: AtomicBool::new(false),
            name: [const { AtomicU8::new(0) }; NAME_CAP],
            message: [const { AtomicU8::new(0) }; MESSAGE_CAP],
        }
    }
}

/// Copies the longest prefix of `text` that fits `cells` and ends on a
/// character boundary; returns its length and whether bytes were cut.
fn store_text(cells: &[AtomicU8], text: &str) -> (u32, bool) {
    let mut end = text.len().min(cells.len());
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    for (cell, byte) in cells.iter().zip(text.as_bytes().iter().take(end)) {
        cell.store(*byte, Ordering::Relaxed);
    }
    (u32::try_from(end).unwrap_or(u32::MAX), end < text.len())
}

fn load_text(cells: &[AtomicU8], out: &mut [u8]) {
    for (byte, cell) in out.iter_mut().zip(cells) {
        *byte = cell.load(Ordering::Relaxed);
    }
}

/// The fixed ring of panic records: [`RING_SLOTS`] preallocated slots,
/// written by any thread that panics, read by the app.
pub struct PanicRing {
    /// Panics recorded so far; the next one's sequence is this plus 1.
    count: AtomicU64,
    slots: [Slot; RING_SLOTS],
}

impl Default for PanicRing {
    fn default() -> Self {
        Self::new()
    }
}

impl PanicRing {
    pub const fn new() -> Self {
        Self { count: AtomicU64::new(0), slots: [const { Slot::new() }; RING_SLOTS] }
    }

    /// Stores one panic of export `name`. When its slot is being written or
    /// read at this moment, the record is dropped (its sequence is a gap).
    pub fn record(&self, name: &str, message: &str) {
        let sequence = self.count.fetch_add(1, Ordering::Relaxed).wrapping_add(1);
        let index = usize::try_from(sequence % RING_SLOTS as u64).unwrap_or_default();
        let Some(slot) = self.slots.get(index) else { return };
        let current = slot.state.load(Ordering::Relaxed);
        if !matches!(current, EMPTY | FULL)
            || slot
                .state
                .compare_exchange(current, WRITING, Ordering::Acquire, Ordering::Relaxed)
                .is_err()
        {
            return;
        }
        let (name_len, _) = store_text(&slot.name, name);
        let (message_len, truncated) = store_text(&slot.message, message);
        slot.sequence.store(sequence, Ordering::Relaxed);
        slot.name_len.store(name_len, Ordering::Relaxed);
        slot.message_len.store(message_len, Ordering::Relaxed);
        slot.truncated.store(truncated, Ordering::Relaxed);
        slot.state.store(FULL, Ordering::Release);
    }

    /// Moves the oldest stored record into `out`; false when none is stored.
    pub fn take(&self, out: &mut CmuxFfiPanic) -> bool {
        // A writer may refill a slot between the scan and the claim; scan
        // again then, at most once per slot.
        for _ in 0..=RING_SLOTS {
            let oldest = self
                .slots
                .iter()
                .filter(|slot| slot.state.load(Ordering::Acquire) == FULL)
                .min_by_key(|slot| slot.sequence.load(Ordering::Relaxed));
            let Some(slot) = oldest else { return false };
            if slot
                .state
                .compare_exchange(FULL, READING, Ordering::Acquire, Ordering::Relaxed)
                .is_err()
            {
                continue;
            }
            out.sequence = slot.sequence.load(Ordering::Relaxed);
            out.name_len = slot.name_len.load(Ordering::Relaxed);
            out.message_len = slot.message_len.load(Ordering::Relaxed);
            out.truncated = slot.truncated.load(Ordering::Relaxed);
            load_text(&slot.name, &mut out.name);
            load_text(&slot.message, &mut out.message);
            slot.state.store(EMPTY, Ordering::Release);
            return true;
        }
        false
    }

    /// Panics recorded since the process started, lost ones included.
    pub fn count(&self) -> u64 {
        self.count.load(Ordering::Relaxed)
    }
}

/// The process's ring, written by [`ffi_boundary`] and [`ffi_boundary_catch`].
static RING: PanicRing = PanicRing::new();

/// Takes the oldest stored panic, for Rust callers and tests.
pub fn take_panic() -> Option<CmuxFfiPanic> {
    let mut record = CmuxFfiPanic::EMPTY;
    RING.take(&mut record).then_some(record)
}

/// Moves the oldest stored panic into `*out`: 1 when it was filled, 0 when
/// none is stored, -1 for a NULL `out`.
///
/// # Safety
/// `out` is NULL or points to a writable `CmuxFfiPanic`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_ffi_take_panic(out: *mut CmuxFfiPanic) -> i32 {
    // ffi-nopanic: the ring only loads and stores atomics and copies fixed arrays.
    // SAFETY: NULL or writable per the contract above.
    let Some(out) = (unsafe { out.as_mut() }) else { return -1 };
    i32::from(RING.take(out))
}

/// Guarded panics since the process started, the ones the ring lost included.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_ffi_panic_count() -> u64 {
    // ffi-nopanic: one atomic load.
    RING.count()
}

/// Test support for the FFI crates: make a boundary panic on purpose, so a
/// test calls a real export and sees its error value, and find exports
/// whose body is not guarded.
#[cfg(feature = "testing")]
pub mod testing {
    use std::cell::{Cell, RefCell};

    thread_local! {
        static ARMED: Cell<u32> = const { Cell::new(0) };
        static LAST: RefCell<Option<String>> = const { RefCell::new(None) };
    }

    /// The next [`ffi_boundary`](crate::ffi_boundary) on this thread panics
    /// before its body.
    pub fn panic_in_next_boundary() {
        ARMED.with(|armed| armed.set(1));
    }

    pub(crate) fn fire(name: &str) {
        let armed = ARMED.with(|armed| armed.replace(armed.get().saturating_sub(1)));
        if armed > 0 {
            // An unwind without the panic hook: the armed boundary stays
            // quiet and records this message like any panic.
            std::panic::resume_unwind(Box::new(format!("cmux-ffi-guard test panic in {name}")));
        }
    }

    pub(crate) fn note(name: &str) {
        LAST.with(|last| *last.borrow_mut() = Some(name.to_owned()));
    }

    /// Runs `body` in a boundary as an export does, with the panic hook
    /// quiet: for a test whose body panics on purpose part way through a
    /// handle call.
    pub fn quiet_boundary<R>(default: R, body: impl FnOnce() -> R) -> R {
        let hook = std::panic::take_hook();
        std::panic::set_hook(Box::new(|_| {}));
        let result = crate::ffi_boundary("cmux_ffi_guard_test", default, body);
        std::panic::set_hook(hook);
        result
    }

    /// Calls `export` with its boundary armed to panic and returns its
    /// result and the boundary name the panic was recorded under (the
    /// process ring got the same record). Parallel tests do not see each
    /// other's panics.
    pub fn panic_through<R>(export: impl FnOnce() -> R) -> (R, Option<String>) {
        let (result, _, name) = panic_through_boundaries(1, export);
        (result, name)
    }

    /// [`panic_through`] with the next `count` boundaries armed, for an
    /// export whose recovery runs in a boundary of its own. Also returns how
    /// many armed boundaries did not run.
    pub fn panic_through_boundaries<R>(
        count: u32,
        export: impl FnOnce() -> R,
    ) -> (R, u32, Option<String>) {
        LAST.with(|last| last.borrow_mut().take());
        ARMED.with(|armed| armed.set(count));
        let result = export();
        let unfired = ARMED.with(Cell::take);
        (result, unfired, LAST.with(|last| last.borrow_mut().take()))
    }

    /// The names of the `extern "C" fn` items in `source` whose body has
    /// neither an `ffi_boundary(` call named after the export nor an
    /// `ffi-nopanic:` reason (Q18). A macro's `$name` export passes
    /// `stringify!($name)`.
    pub fn unguarded_exports(source: &str) -> Vec<String> {
        let mut unguarded = Vec::new();
        let mut rest = source;
        while let Some(at) = rest.find("extern \"C\" fn ") {
            let after = &rest[at + "extern \"C\" fn ".len()..];
            let name: String = after
                .chars()
                .take_while(|c| c.is_alphanumeric() || *c == '_' || *c == '$')
                .collect();
            let body = body_of(after);
            let named = if let Some(ident) = name.strip_prefix('$') {
                format!("ffi_boundary(stringify!(${ident})")
            } else {
                format!("ffi_boundary(\"{name}\"")
            };
            if !body.contains(&named) && !body.contains("ffi-nopanic:") {
                unguarded.push(name);
            }
            rest = after;
        }
        unguarded
    }

    /// The text between the first `{` after a signature and its matching `}`.
    fn body_of(signature: &str) -> &str {
        let Some(open) = signature.find('{') else { return "" };
        let mut depth = 0_usize;
        for (index, c) in signature[open..].char_indices() {
            match c {
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if depth == 0 {
                        return &signature[open..open + index];
                    }
                }
                _ => {}
            }
        }
        &signature[open..]
    }
}

#[cfg(test)]
mod tests;
