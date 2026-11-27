use super::*;
use serde_json::json;

#[test]
fn a_turn_result_gives_its_facts() {
    let msg = json!({"status": "completed", "model": "claude-opus-4-5", "inputTokens": 12,
        "outputTokens": 34, "cacheReadTokens": 56, "cacheWriteTokens": 78, "costUsd": 0.5,
        "turnId": "t1", "promptId": "p1"});
    let cwd = std::path::Path::new("/tmp/x");
    let f = facts_of("s1", "claude", cwd, &msg, Some((1_000, 4)), 3_500);
    assert_eq!(f.ms, 2_500);
    assert_eq!(f.tool_calls, 4);
    assert_eq!((f.input_tokens, f.output_tokens), (12, 34));
    assert_eq!((f.cache_read_tokens, f.cache_write_tokens), (56, 78));
    assert_eq!(f.cost_usd, Some(0.5));
    assert_eq!(f.model, Some("claude-opus-4-5"));
    assert_eq!(f.outcome, Some(Outcome::Done));
    for (status, outcome) in [("cancelled", Outcome::Cancelled), ("failed", Outcome::Failed)] {
        let msg = json!({"status": status, "turnId": "t1"});
        let f = facts_of("s1", "codex", cwd, &msg, None, 9);
        assert_eq!(f.outcome, Some(outcome));
        assert_eq!((f.ms, f.tool_calls, f.input_tokens), (0, 0, 0));
    }
}
