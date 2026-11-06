//! The person's own mouse and keyboard use, for pause-on-takeover.
//!
//! GetLastInputInfo stamps the session's last hardware or injected input.
//! Posted window messages (our background route) never touch it; our own
//! SendInput (foreground route) does, so every injection records its tick
//! here and input that lands right after one of ours is not the person's.
//! GetLastInputInfo has no change notification, so the wait sleeps exactly
//! until the earliest moment the person could count as idle, bounded by
//! the caller's limit.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use windows::Win32::System::SystemInformation::GetTickCount;
use windows::Win32::UI::Input::KeyboardAndMouse::{GetLastInputInfo, LASTINPUTINFO};

use super::pure;
use crate::engine::PersonActivity;

/// The person counts as idle after this long without input of theirs.
pub const IDLE_AFTER: Duration = Duration::from_millis(1000);
/// How long after our SendInput returns the session may still stamp it.
const OWN_INPUT_SLACK_MS: u32 = 250;

/// The tick of our latest SendInput, plus one (0: never).
static LAST_INJECTED: AtomicU64 = AtomicU64::new(0);

pub fn note_injected() {
    // SAFETY: plain query.
    let now = unsafe { GetTickCount() };
    LAST_INJECTED.store(u64::from(now) + 1, Ordering::Release);
}

fn last_injected() -> Option<u32> {
    match LAST_INJECTED.load(Ordering::Acquire) {
        0 => None,
        n => Some((n - 1) as u32),
    }
}

/// Milliseconds since the person's own last input (`None`: unknown).
fn person_idle_ms() -> Option<u32> {
    let mut info = LASTINPUTINFO { cbSize: size_of::<LASTINPUTINFO>() as u32, dwTime: 0 };
    // SAFETY: cbSize describes the struct.
    if !unsafe { GetLastInputInfo(&mut info) }.as_bool() {
        return None;
    }
    // SAFETY: plain query.
    let now = unsafe { GetTickCount() };
    if pure::input_is_ours(info.dwTime, last_injected(), OWN_INPUT_SLACK_MS) {
        return Some(u32::MAX);
    }
    Some(pure::ticks_since(now, info.dwTime))
}

struct LastInput;

impl PersonActivity for LastInput {
    fn wait_idle(&self, limit: Duration) -> bool {
        let deadline = Instant::now() + limit;
        loop {
            // Unknown (no input desktop): nothing to defer to.
            let Some(idle) = person_idle_ms() else { return true };
            let idle = Duration::from_millis(u64::from(idle));
            if idle >= IDLE_AFTER {
                return true;
            }
            let now = Instant::now();
            if now >= deadline {
                return false;
            }
            // The earliest moment the person can be idle, if they stop now.
            std::thread::sleep((IDLE_AFTER - idle).min(deadline - now));
        }
    }
}

pub fn person_activity() -> Arc<dyn PersonActivity> {
    Arc::new(LastInput)
}
