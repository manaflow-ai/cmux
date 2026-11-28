use super::listed_model;

fn ids(list: &[&str]) -> Vec<String> {
    list.iter().map(|s| (*s).to_owned()).collect()
}

#[test]
fn a_harness_head_is_dropped_when_the_harness_lists_the_bare_model() {
    let claude = ids(&["default", "haiku", "opus", "claude-haiku-5-5"]);
    assert_eq!(listed_model("claude/haiku", &["claude"], &claude, true).as_deref(), Some("haiku"));
    assert_eq!(listed_model("haiku", &["claude"], &claude, true).as_deref(), Some("haiku"));
}

#[test]
fn a_provider_model_id_stays_whole_and_a_bare_one_gets_its_head() {
    let opencode = ids(&["opencode/big-pickle", "opencode/deepseek-v4.1-flash-free"]);
    let heads = ["opencode"];
    assert_eq!(
        listed_model("opencode/big-pickle", &heads, &opencode, false).as_deref(),
        Some("opencode/big-pickle")
    );
    assert_eq!(
        listed_model("big-pickle", &heads, &opencode, false).as_deref(),
        Some("opencode/big-pickle")
    );
}

#[test]
fn a_model_the_harness_does_not_list_is_none_unless_it_lists_nothing() {
    let codex = ids(&["gpt-6.1-sol"]);
    assert_eq!(listed_model("codex/nope", &["codex"], &codex, false), None);
    assert_eq!(listed_model("nope", &["codex"], &[], false).as_deref(), Some("nope"));
}

#[test]
fn claude_runs_a_claude_model_id_it_does_not_list() {
    let claude = ids(&["default", "haiku"]);
    assert_eq!(
        listed_model("claude/claude-opus-4-1", &["claude"], &claude, true).as_deref(),
        Some("claude-opus-4-1")
    );
    assert_eq!(listed_model("claude/bogus", &["claude"], &claude, true), None);
}
