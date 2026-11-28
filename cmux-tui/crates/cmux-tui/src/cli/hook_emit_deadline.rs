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
mod tests {
    use super::within;
    use crate::cli::command::hook_emit_budget;
    use std::time::Duration;

    fn words(line: &str) -> Vec<String> {
        line.split_whitespace().map(str::to_owned).collect()
    }

    #[test]
    fn reads_the_deadline_of_an_emit_only() {
        for emit in [
            "agent hook emit --source claude --event Stop --deadline-ms 3500",
            "agent hook emit --deadline-ms=3500 --source claude --event Stop",
            "agent --deadline-ms 3500 hook emit --source claude --event Stop",
        ] {
            assert_eq!(hook_emit_budget(&words(emit)).unwrap(), Some(Duration::from_millis(3500)));
        }
        assert_eq!(
            hook_emit_budget(&words("agent hook emit --source claude --event Stop")).unwrap(),
            None
        );
        assert!(hook_emit_budget(&words("agent hook emit --deadline-ms 0")).is_err());
        assert!(hook_emit_budget(&words("agent hook emit --deadline-ms soon")).is_err());
        assert_eq!(hook_emit_budget(&words("agent list --deadline-ms 3500")).unwrap(), None);
    }

    #[test]
    fn answers_at_the_deadline_when_the_command_has_not() {
        assert_eq!(within(Duration::from_secs(5), || 7), 7);
        let start = std::time::Instant::now();
        let code = within(Duration::from_millis(200), || {
            std::thread::sleep(Duration::from_secs(30));
            7
        });
        assert_eq!(code, 0);
        assert!(start.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn a_worker_failure_is_not_a_successful_deadline() {
        assert_eq!(within(Duration::from_secs(5), || panic!("worker failed")), 1);
    }
}
