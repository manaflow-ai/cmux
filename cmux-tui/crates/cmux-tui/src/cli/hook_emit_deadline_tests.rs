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
