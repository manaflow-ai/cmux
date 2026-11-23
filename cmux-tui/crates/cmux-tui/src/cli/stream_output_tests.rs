use super::*;

fn words(text: &[&str]) -> Vec<String> {
    text.iter().map(|word| (*word).to_owned()).collect()
}

#[test]
fn the_same_command_with_jsonl_is_named() {
    assert_eq!(
        jsonl_command(&words(&["--json", "session", "current", "events"])),
        "cmux --jsonl session current events"
    );
    assert_eq!(
        jsonl_command(&words(&["--session", "build", "session", "current", "events", "--json"])),
        "cmux --session build session current events --jsonl"
    );
}

#[test]
fn values_are_quoted_and_a_json_after_dashes_is_kept() {
    assert_eq!(
        jsonl_command(&words(&["--json", "terminal", "attach", "--", "it's", "--json"])),
        "cmux --jsonl terminal attach -- 'it'\\''s' --json"
    );
}

/// A `--json` that is an option's value is the caller's filter, not the
/// output switch (review finding F1 on #38766).
#[test]
fn an_option_value_of_json_is_kept() {
    assert_eq!(
        jsonl_command(&words(&[
            "--json",
            "session",
            "current",
            "journal",
            "subscribe",
            "--regex",
            "--json",
        ])),
        "cmux --jsonl session current journal subscribe --regex --json"
    );
    assert_eq!(
        jsonl_command(&words(&[
            "session",
            "current",
            "journal",
            "subscribe",
            "--regex",
            "--json",
            "--json",
        ])),
        "cmux session current journal subscribe --regex --json --jsonl"
    );
}

#[test]
fn with_no_json_word_the_switch_goes_first() {
    assert_eq!(
        jsonl_command(&words(&["session", "current", "events"])),
        "cmux --jsonl session current events"
    );
}

#[test]
fn only_json_is_refused() {
    for output in [OutputMode::JsonLines, OutputMode::Quiet, OutputMode::Human] {
        assert_eq!(refuse_json(output), None);
    }
}
