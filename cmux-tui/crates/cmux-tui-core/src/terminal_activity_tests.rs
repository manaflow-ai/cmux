use super::*;

#[test]
fn the_first_output_publishes_and_a_burst_publishes_at_most_once_per_interval() {
    let mut activity = ShellActivity::default();
    assert_eq!(activity.last_output(), None);
    assert!(!activity.take_change());

    activity.note_output(10_000);
    assert_eq!(activity.last_output(), Some(10_000));
    assert!(activity.take_change(), "the first output publishes");

    // More output inside the interval is read on demand, not pushed.
    activity.note_output(10_000 + OUTPUT_PUBLISH_INTERVAL_MS - 1);
    assert_eq!(activity.last_output(), Some(10_000 + OUTPUT_PUBLISH_INTERVAL_MS - 1));
    assert!(!activity.take_change());

    activity.note_output(10_000 + OUTPUT_PUBLISH_INTERVAL_MS);
    assert!(activity.take_change(), "output a whole interval later publishes");
    assert!(!activity.take_change());
}

#[test]
fn a_prompt_publish_carries_the_latest_output_and_restarts_the_interval() {
    let mut activity = ShellActivity::default();
    activity.note_output(1_000);
    assert!(activity.take_change());
    activity.note_output(2_000);
    assert!(!activity.take_change());

    // The command ends at a new prompt: that publish names 2_000, so
    // output just after it waits a whole interval from there.
    activity.observe(ShellMark::PromptStart, 2_000);
    assert!(activity.take_change());
    activity.note_output(2_000 + OUTPUT_PUBLISH_INTERVAL_MS - 1);
    assert!(!activity.take_change());
}

#[test]
fn restoring_a_host_state_keeps_the_last_output() {
    let mut previous = ShellActivity::default();
    previous.note_output(7_000);
    assert!(previous.take_change());

    let mut restored = ShellActivity::default();
    restored.restore(previous.snapshot());
    restored.keep_output_of(&previous);
    assert_eq!(restored.last_output(), Some(7_000));
    // The output was already published: no push now, and the next one
    // still waits a whole interval from 7_000.
    assert!(!restored.take_change());
    restored.note_output(7_000 + OUTPUT_PUBLISH_INTERVAL_MS - 1);
    assert!(!restored.take_change());
    restored.note_output(7_000 + OUTPUT_PUBLISH_INTERVAL_MS);
    assert!(restored.take_change());
}

#[test]
fn a_clock_that_steps_back_still_records_the_output() {
    let mut activity = ShellActivity::default();
    activity.note_output(50_000);
    assert!(activity.take_change());
    activity.note_output(40_000);
    assert_eq!(activity.last_output(), Some(40_000));
    assert!(activity.take_change(), "a time before the published one publishes");
}

#[test]
fn read_run_last_command_records_the_exit_code_of_d_and_publishes_once() {
    let mut activity = ShellActivity::default();
    assert_eq!(activity.last_command(), None, "no command, no record");
    activity.observe(ShellMark::PromptStart, 1_000);
    assert_eq!(activity.last_command(), None, "a prompt alone finishes nothing");
    assert!(activity.take_change());

    activity.observe(ShellMark::CommandStart, 2_000);
    activity.observe(ShellMark::CommandEnd { exit_code: Some(7) }, 2_500);
    let last =
        LastCommand { exit_code: Some(7), started_at_ms: Some(2_000), finished_at_ms: 2_500 };
    assert_eq!(activity.last_command(), Some(last));
    assert!(activity.take_change(), "a finished command publishes");
    activity.observe(ShellMark::PromptStart, 2_501);
    assert_eq!(activity.last_command(), Some(last), "the prompt after D keeps D's status");
    assert!(activity.take_change(), "the prompt publishes");
    assert!(!activity.take_change());
    assert_eq!(
        last_command_json(last),
        json!({"exit_code": 7, "started_at_ms": "2000", "finished_at_ms": "2500"})
    );
}

#[test]
fn read_run_last_command_without_d_or_without_a_code_has_no_exit_code() {
    let mut activity = ShellActivity::default();
    activity.observe(ShellMark::CommandStart, 10);
    activity.observe(ShellMark::PromptStart, 20);
    let last = activity.last_command().unwrap();
    assert_eq!(last.exit_code, None, "a prompt without D: status unknown, not 0");
    assert_eq!(last_command_json(last), json!({"started_at_ms": "10", "finished_at_ms": "20"}));

    activity.observe(ShellMark::CommandStart, 30);
    activity.observe(ShellMark::CommandEnd { exit_code: None }, 40);
    assert_eq!(activity.last_command().unwrap().exit_code, None);

    // Without shell integration there are no marks, so no record at all.
    let mut plain = ShellActivity::default();
    plain.note_output(50);
    assert_eq!(plain.last_command(), None);
}

#[test]
fn read_run_last_command_survives_a_reconnect_to_the_same_host() {
    let mut previous = ShellActivity::default();
    previous.observe(ShellMark::CommandStart, 1);
    previous.observe(ShellMark::CommandEnd { exit_code: Some(0) }, 2);
    assert!(previous.take_change());
    let mut restored = ShellActivity::default();
    restored.restore(previous.snapshot());
    restored.keep_output_of(&previous);
    assert_eq!(restored.last_command(), previous.last_command());
    assert!(!restored.take_change(), "an already published record does not publish again");
}

#[test]
fn last_output_json_names_the_time_as_a_decimal_string() {
    assert_eq!(last_output_json(1_792_000_000_123), json!({"at_ms": "1792000000123"}));
}
