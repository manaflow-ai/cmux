//! The person's own input on macOS, for pause-on-takeover in the Rust
//! worker (the Screen Sharing helper's `__computer-use-worker`; cmux Remote's
//! Swift worker keeps its event tap, `Takeover.swift`).
//!
//! The HID system's seconds since the last event of each deliberate type
//! (key down, mouse down, scroll, drag): hardware input only, the state the
//! window server keeps for the keyboard and mouse themselves. Pointer
//! movement is not a takeover (a hand resting on the mouse does not stop
//! the agent), as in the Swift rule. Our own events go to a process
//! (a post to its pid) from a private source; the rare HID-tap post
//! (foreground delivery) is marked in [`mark_injection`], so input within
//! [`crate::takeover::OWN_INPUT_GRACE`] of it is ours. Reading these
//! counters needs no grant.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::engine::PersonActivity;
use crate::takeover::{IdleClock, IdlePoll};

/// `kCGEventSourceStateHIDSystemState`.
const HID_SYSTEM_STATE: i32 = 1;

/// The deliberate CGEventTypes: left, right and other mouse down, key down,
/// scroll wheel, and the three drags.
pub const DELIBERATE: [u32; 8] = [1, 3, 25, 10, 22, 6, 7, 27];

#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    fn CGEventSourceSecondsSinceLastEventType(state: i32, event_type: u32) -> f64;
}

static LAST_INJECTION_MS: AtomicU64 = AtomicU64::new(0);

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// Every post of our own input marks it here (`input::post`).
pub(super) fn mark_injection() {
    LAST_INJECTION_MS.store(now_ms(), Ordering::Relaxed);
}

/// The newest of the per-type readings (seconds), in milliseconds; `None`
/// when no reading is a finite, non-negative number.
pub fn newest_ms(seconds: impl IntoIterator<Item = f64>) -> Option<u64> {
    seconds
        .into_iter()
        .filter(|s| s.is_finite() && *s >= 0.0)
        .map(|s| (s * 1000.0).min(u64::MAX as f64) as u64)
        .min()
}

pub(super) struct HidIdle;

impl IdleClock for HidIdle {
    fn idle_ms(&self) -> Option<u64> {
        newest_ms(DELIBERATE.iter().map(|&ty| {
            // SAFETY: plain C call with a state id and an event type.
            unsafe { CGEventSourceSecondsSinceLastEventType(HID_SYSTEM_STATE, ty) }
        }))
    }
    fn now_ms(&self) -> u64 {
        now_ms()
    }
    fn last_injection_ms(&self) -> u64 {
        LAST_INJECTION_MS.load(Ordering::Relaxed)
    }
    fn pause(&self, duration: Duration) {
        // Polls the HID idle counters; not a synchronization sleep.
        std::thread::park_timeout(duration);
    }
}

pub fn person_activity() -> Arc<dyn PersonActivity> {
    Arc::new(IdlePoll(HidIdle))
}
