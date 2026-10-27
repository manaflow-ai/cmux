//! Small panic-free helpers (plans/cmux-next/rust-panic-free.md).
//!
//! [`RecoverPoison`]: a `std::sync` lock is poisoned when a thread panicked
//! while it held the lock. Unwrapping that error turns one panic into a
//! panic in every later user of the lock, and every FFI entry point takes
//! these locks, so a panic in one stream task aborted the embedding app at
//! its next call (a panic cannot unwind out of `extern "C"`). The client's
//! locks guard callback registrations, the desired resize and the per-stream
//! render state; a frame the panicking task left half applied fails the next
//! frame's sequence check, which restarts the stream from a fresh snapshot.
//! The same rule as cmux-tui-core's `panic_free::RecoverPoison`.

use std::sync::{LockResult, PoisonError};

/// `.recover_poison()` in place of `.unwrap()` on any `LockResult`.
pub(crate) trait RecoverPoison<T> {
    fn recover_poison(self) -> T;
}

impl<T> RecoverPoison<T> for LockResult<T> {
    fn recover_poison(self) -> T {
        self.unwrap_or_else(PoisonError::into_inner)
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
