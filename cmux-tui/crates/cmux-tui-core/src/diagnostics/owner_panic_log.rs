//! Where the session owner's panic log lives (cx-urd.59). The owner's panic
//! hook appends to it (cmux-tui `owner_start/owner_panic.rs`) and
//! `oracle-state` reports it, so both read the one path rule here. The
//! owner's hang log lives beside it, with the stack sampler its watcher uses.

use std::path::PathBuf;

/// The log for `session`: `owner-panics-<session>.jsonl` at the state root
/// (the parent of the sessions directory). A session name that needs
/// escaping gets a hash suffix, so two names never share a log.
pub fn owner_panic_log_path(session: &str) -> Option<PathBuf> {
    owner_log_path("owner-panics", session)
}

/// The hang log for `session`: `owner-hangs-<session>.jsonl` beside the
/// panic log. The owner's hang watcher (cmux-panic-log `hang`) appends one
/// line per scope busy past its hang tier.
pub fn owner_hang_log_path(session: &str) -> Option<PathBuf> {
    owner_log_path("owner-hangs", session)
}

fn owner_log_path(prefix: &str, session: &str) -> Option<PathBuf> {
    let sessions = crate::platform::workspace_state_dir()?;
    let root = sessions.parent().map(PathBuf::from).unwrap_or(sessions);
    let safe: String = session
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.') { c } else { '-' })
        .collect();
    let name = if safe == session {
        safe
    } else {
        // FNV-1a: stable across builds, no dependency.
        let hash = session.bytes().fold(0xcbf2_9ce4_8422_2325_u64, |hash, byte| {
            (hash ^ u64::from(byte)).wrapping_mul(0x100_0000_01b3)
        });
        format!("{safe}-{:08x}", hash as u32)
    };
    Some(root.join(format!("{prefix}-{name}.jsonl")))
}

/// The hung thread's stack for the hang watcher: cmux-tui-platform
/// `thread_backtrace` (`thread_suspend` and a frame-pointer walk on macOS,
/// a signal handler filling a preallocated buffer on Linux), symbolicated
/// after the thread runs again.
pub fn hang_stack_sampler() -> cmux_panic_log::hang::StackSampler {
    use cmux_panic_log::hang::{HangFrame, HangStack, StackSampler};
    use cmux_tui_platform::thread_backtrace::{self, BacktraceError, ThreadHandle};
    StackSampler {
        current_thread: || ThreadHandle::current().map_or(0, ThreadHandle::raw),
        capture: Box::new(|raw| {
            let thread = ThreadHandle::from_raw(raw).ok_or(BacktraceError::Unsupported.as_str())?;
            let backtrace = thread_backtrace::capture(thread).map_err(BacktraceError::as_str)?;
            Ok(HangStack {
                frames: backtrace
                    .symbolicate()
                    .into_iter()
                    .map(|frame| HangFrame {
                        image: frame.image,
                        image_id: frame.image_id,
                        offset: frame.offset as u64,
                        symbol: frame.symbol,
                    })
                    .collect(),
                truncated: backtrace.truncated(),
            })
        }),
    }
}
