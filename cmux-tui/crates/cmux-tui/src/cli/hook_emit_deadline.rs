//! `agent hook emit --deadline-ms N`: the installed fallback hook answers
//! inside its hook timeout.
//!
//! On a host without the `cmux-tui-hook` helper, a wrapped Claude launch
//! installs `cmux-tui agent hook emit ... --deadline-ms N >/dev/null 2>&1||:;echo {}`
//! for every event except `PreToolUse`, where N is the hook's installed
//! timeout minus a margin (`cmux_tui_hooks::emit_deadline_ms`). The request
//! itself waits up to a 2 s preflight, a 10 s response read and the
//! connection-healing resends, so a stalled daemon would run the hook past its
//! timeout and the agent would show "A hook didn't answer in time". At N the
//! command answers 0 with no output, which is the fallback's safe answer: the
//! shell already discards emit's output and prints `{}`.

use std::sync::mpsc::RecvTimeoutError;
use std::time::Duration;

/// Runs the command on a worker thread and answers 0 at the deadline if it has
/// not answered by then; the caller's exit then ends the blocked request.
pub(super) fn within(deadline: Duration, command: impl FnOnce() -> i32 + Send + 'static) -> i32 {
    let (answered, answer) = std::sync::mpsc::channel();
    let worker = std::thread::Builder::new().name("hook-emit".into()).spawn(move || {
        let _ = answered.send(command());
    });
    if worker.is_err() {
        return 1;
    }
    match answer.recv_timeout(deadline) {
        Ok(code) => code,
        Err(RecvTimeoutError::Timeout) => 0,
        Err(RecvTimeoutError::Disconnected) => 1,
    }
}

#[cfg(test)]
#[path = "hook_emit_deadline_tests.rs"]
mod tests;
