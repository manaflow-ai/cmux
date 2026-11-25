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

use std::time::Duration;

/// The flag's value from the command words of `agent hook emit`, when it is there.
pub(super) fn requested(command: &[String]) -> Option<Duration> {
    if command.get(..3)? != ["agent", "hook", "emit"] {
        return None;
    }
    let mut words = command[3..].iter();
    while let Some(word) = words.next() {
        let value = match word.strip_prefix("--deadline-ms") {
            Some("") => words.next()?.as_str(),
            Some(inline) => inline.strip_prefix('=')?,
            None => continue,
        };
        return value.parse::<u64>().ok().filter(|ms| *ms > 0).map(Duration::from_millis);
    }
    None
}

/// Runs the command on a worker thread and answers 0 at the deadline if it has
/// not answered by then; the caller's exit then ends the blocked request.
pub(super) fn within(deadline: Duration, command: impl FnOnce() -> i32 + Send + 'static) -> i32 {
    let (answered, answer) = std::sync::mpsc::channel();
    let worker = std::thread::Builder::new().name("hook-emit".into()).spawn(move || {
        let _ = answered.send(command());
    });
    if worker.is_err() {
        return 0;
    }
    answer.recv_timeout(deadline).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::{requested, within};
    use std::time::Duration;

    fn words(line: &str) -> Vec<String> {
        line.split_whitespace().map(str::to_owned).collect()
    }

    #[test]
    fn reads_the_deadline_of_an_emit_only() {
        let emit = "agent hook emit --source claude --event Stop --deadline-ms 3500";
        assert_eq!(requested(&words(emit)), Some(Duration::from_millis(3500)));
        let inline = "agent hook emit --deadline-ms=3500 --source claude --event Stop";
        assert_eq!(requested(&words(inline)), Some(Duration::from_millis(3500)));
        assert_eq!(requested(&words("agent hook emit --source claude --event Stop")), None);
        assert_eq!(requested(&words("agent hook emit --deadline-ms 0")), None);
        assert_eq!(requested(&words("agent hook emit --deadline-ms soon")), None);
        assert_eq!(requested(&words("agent list --deadline-ms 3500")), None);
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
}
