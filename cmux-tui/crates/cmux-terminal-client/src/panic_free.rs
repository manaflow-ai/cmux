//! Small panic-free helpers (plans/cmux-next/rust-panic-free.md).
//!
//! A `std::sync` lock is poisoned when a thread panicked while it held the
//! lock. Two rules, by what the lock guards (p10-stability.md section E):
//!
//! - [`LockShared`]: the per-stream render state and the active terminal
//!   tasks. The stream task and the FFI both change them, and a panic can
//!   leave them half changed (a frame half applied with its sequence already
//!   advanced). Poison there escalates to Fatal: the next locker panics, and
//!   in an `extern "C"` entry point that panic aborts the process.
//! - [`RecoverPoison`]: a slot that holds one `Copy` value written whole (a
//!   callback registration, the desired resize). A panic cannot leave it half
//!   written, so the value left behind is valid and is used.

use std::sync::{LockResult, Mutex, MutexGuard, PoisonError};

/// `.recover_poison()` in place of `.unwrap()` on the `LockResult` of a
/// one-value slot. Never on state a panic can leave half changed.
pub(crate) trait RecoverPoison<T> {
    fn recover_poison(self) -> T;
}

impl<T> RecoverPoison<T> for LockResult<T> {
    fn recover_poison(self) -> T {
        self.unwrap_or_else(PoisonError::into_inner)
    }
}

/// `.lock_shared()` on a lock whose state a panic can leave half changed.
pub(crate) trait LockShared<T> {
    fn lock_shared(&self) -> MutexGuard<'_, T>;
}

impl<T> LockShared<T> for Mutex<T> {
    #[allow(
        clippy::expect_used,
        reason = "INVARIANT: a poisoned lock holds state a panic left half changed; serving it \
                  is a silent wrong default, so poison escalates to Fatal (p10-stability.md E)"
    )]
    fn lock_shared(&self) -> MutexGuard<'_, T> {
        // crash-allow: poison of shared terminal state escalates to Fatal (p10-stability.md E).
        self.lock().expect("INVARIANT: no panic while shared terminal state is locked")
    }
}

/// A `Resized` frame payload: little-endian `cols` and `rows`, then in the
/// 8-byte form the cell width and height in pixels. Zero sizes read as 1.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct ResizedPayload {
    pub(crate) cols: u16,
    pub(crate) rows: u16,
    pub(crate) cell_pixels: Option<(u16, u16)>,
}

impl ResizedPayload {
    /// `None` for any length other than 4 or 8 bytes.
    pub(crate) fn decode(payload: &[u8]) -> Option<Self> {
        let size = |low: u8, high: u8| u16::from_le_bytes([low, high]).max(1);
        match *payload {
            [c0, c1, r0, r1] => {
                Some(Self { cols: size(c0, c1), rows: size(r0, r1), cell_pixels: None })
            }
            [c0, c1, r0, r1, w0, w1, h0, h1] => Some(Self {
                cols: size(c0, c1),
                rows: size(r0, r1),
                cell_pixels: Some((size(w0, w1), size(h0, h1))),
            }),
            _ => None,
        }
    }
}

/// A `ResizeAck` payload: little-endian `cols` and `rows` (zero reads as 1)
/// and a `u32` flag word.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct ResizeAckPayload {
    pub(crate) cols: u16,
    pub(crate) rows: u16,
    pub(crate) flags: u32,
}

impl ResizeAckPayload {
    /// `None` for any length other than 8 bytes.
    pub(crate) fn decode(payload: &[u8]) -> Option<Self> {
        let [c0, c1, r0, r1, f0, f1, f2, f3] = *payload else {
            return None;
        };
        Some(Self {
            cols: u16::from_le_bytes([c0, c1]).max(1),
            rows: u16::from_le_bytes([r0, r1]).max(1),
            flags: u32::from_le_bytes([f0, f1, f2, f3]),
        })
    }
}
