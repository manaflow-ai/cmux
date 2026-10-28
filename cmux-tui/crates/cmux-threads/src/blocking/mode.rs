//! The violation mode: what a blocking call on a thread that disallows
//! blocking does beyond recording its site.

use std::cell::Cell;
use std::sync::atomic::{AtomicU8, Ordering};

/// What a violation does beyond recording its site.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BlockingMode {
    /// Record the site and continue (Release always; Debug with
    /// `CMUX_DAEMON_BLOCKING=record`).
    Record,
    /// Record the site, then panic at the caller's location (the Debug default
    /// since the sweep passed in record mode). Debug
    /// builds only; Release treats it as [`BlockingMode::Record`].
    Panic,
}

/// The environment variable whose value `record` selects
/// [`BlockingMode::Record`]; unset or any other value is
/// [`BlockingMode::Panic`].
pub const MODE_ENV: &str = "CMUX_DAEMON_BLOCKING";

const MODE_UNSET: u8 = 0;
const MODE_RECORD: u8 = 1;
const MODE_PANIC: u8 = 2;

static MODE: AtomicU8 = AtomicU8::new(MODE_UNSET);

/// Sets the process-wide violation mode, replacing the [`MODE_ENV`] value.
pub fn set_mode(mode: BlockingMode) {
    let raw = match mode {
        BlockingMode::Record => MODE_RECORD,
        BlockingMode::Panic => MODE_PANIC,
    };
    MODE.store(raw, Ordering::Relaxed);
}

thread_local! {
    /// This thread's [`with_mode`] override, or [`MODE_UNSET`].
    static THREAD_MODE: Cell<u8> = const { Cell::new(MODE_UNSET) };
}

/// Runs `f` with `mode` as this thread's violation mode, then restores the
/// previous one: a test checks one thread in panic mode without changing
/// the process-wide mode the other tests of its binary run in.
pub fn with_mode<R>(mode: BlockingMode, f: impl FnOnce() -> R) -> R {
    struct Restore(u8);
    impl Drop for Restore {
        fn drop(&mut self) {
            THREAD_MODE.with(|cell| cell.set(self.0));
        }
    }
    let raw = match mode {
        BlockingMode::Record => MODE_RECORD,
        BlockingMode::Panic => MODE_PANIC,
    };
    let _restore = Restore(THREAD_MODE.with(|cell| cell.replace(raw)));
    f()
}

/// The violation mode in effect on this thread: its [`with_mode`] override,
/// else the process-wide mode, read from [`MODE_ENV`] on first use.
pub fn mode() -> BlockingMode {
    let raw = match THREAD_MODE.with(Cell::get) {
        MODE_UNSET => MODE.load(Ordering::Relaxed),
        raw => raw,
    };
    let raw = match raw {
        MODE_UNSET => {
            let from_env = mode_from_env(std::env::var(MODE_ENV).ok().as_deref());
            // A concurrent set_mode wins over the environment.
            match MODE.compare_exchange(MODE_UNSET, from_env, Ordering::Relaxed, Ordering::Relaxed)
            {
                Ok(_) => from_env,
                Err(current) => current,
            }
        }
        raw => raw,
    };
    if raw == MODE_PANIC && cfg!(debug_assertions) {
        BlockingMode::Panic
    } else {
        BlockingMode::Record
    }
}

/// The raw mode [`MODE_ENV`]'s value selects: `record` is the off switch,
/// anything else (unset included) panics.
fn mode_from_env(value: Option<&str>) -> u8 {
    match value {
        Some("record") => MODE_RECORD,
        _ => MODE_PANIC,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_environment_panics_unless_it_says_record() {
        assert_eq!(mode_from_env(None), MODE_PANIC);
        assert_eq!(mode_from_env(Some("panic")), MODE_PANIC);
        assert_eq!(mode_from_env(Some("")), MODE_PANIC);
        assert_eq!(mode_from_env(Some("Record")), MODE_PANIC);
        assert_eq!(mode_from_env(Some("record")), MODE_RECORD);
    }
}
