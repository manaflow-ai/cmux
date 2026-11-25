use super::*;
use serde_json::json;

/// One assistant record at `secs` past 12:00:00Z.
fn rec(id: &str, secs: u64, model: &str, input: u64, cr: u64, cw: u64, w1h: bool) -> String {
    let ts = chrono::DateTime::from_timestamp(1_764_072_000 + secs as i64, 0).unwrap().to_rfc3339();
    json!({
        "type": "assistant",
        "timestamp": ts,
        "requestId": id,
        "message": {"model": model, "id": format!("m-{id}"), "usage": {
            "input_tokens": input,
            "cache_read_input_tokens": cr,
            "cache_creation_input_tokens": cw,
            "output_tokens": 10,
            "cache_creation": {"ephemeral_1h_input_tokens": if w1h { cw } else { 0 }},
        }},
    })
    .to_string()
}

const OPUS: &str = "claude-opus-5-5";

fn causes(text: &str, helper: bool) -> HashMap<String, u64> {
    let i = analyze(&[Transcript { text, helper }], 0.0, &fallback_rates);
    i.causes.into_iter().map(|c| (c.cause, c.tokens)).collect()
}

#[test]
fn first_request_is_a_session_start_or_a_helper_start() {
    let t = rec("a", 0, OPUS, 5, 0, 20_000, true);
    assert_eq!(causes(&t, false), HashMap::from([("session start".into(), 20_000)]));
    assert_eq!(causes(&t, true), HashMap::from([("helper start".into(), 20_000)]));
}

#[test]
fn a_full_read_back_is_only_append() {
    let t = [rec("a", 0, OPUS, 5, 0, 20_000, true), rec("b", 10, OPUS, 5, 20_005, 3_000, true)]
        .join("\n");
    let c = causes(&t, false);
    assert_eq!(c.get("append"), Some(&3_000));
    assert_eq!(c.len(), 2, "{c:?}");
}

#[test]
fn a_short_miss_within_tolerance_is_ignored() {
    let t = [rec("a", 0, OPUS, 5, 0, 20_000, true), rec("b", 10, OPUS, 5, 19_500, 3_000, true)]
        .join("\n");
    assert_eq!(causes(&t, false).get("prefix edit"), None);
}

fn rewrite_after(gap: u64, model: &str, w1h: bool, extra: &[&str]) -> HashMap<String, u64> {
    let mut lines = vec![rec("a", 0, OPUS, 5, 0, 20_000, w1h)];
    lines.extend(extra.iter().map(|s| s.to_string()));
    lines.push(rec("b", gap, model, 5, 0, 23_000, w1h));
    causes(&lines.join("\n"), false)
}

#[test]
fn each_rewrite_cause_is_the_first_that_holds() {
    let compact = json!({"type": "system", "subtype": "compact_boundary"}).to_string();
    let c = rewrite_after(30, OPUS, true, &[&compact]);
    assert_eq!(c.get("compaction"), Some(&20_005));
    assert_eq!(c.get("append"), Some(&2_995));

    assert_eq!(rewrite_after(4000, OPUS, true, &[]).get("idle wake"), Some(&20_005));
    // A 5-minute write is gone after 300 s.
    assert_eq!(rewrite_after(400, OPUS, false, &[]).get("idle wake"), Some(&20_005));
    assert_eq!(
        rewrite_after(30, "claude-sonnet-5-5", true, &[]).get("model switch"),
        Some(&20_005)
    );
    assert_eq!(rewrite_after(400, OPUS, true, &[]).get("lost under ttl"), Some(&20_005));
    assert_eq!(rewrite_after(30, OPUS, true, &[]).get("prefix edit"), Some(&20_005));
}

#[test]
fn a_shape_hash_change_is_a_shape_change() {
    let s1 = json!({"type": "api-request-shape", "shapeHash": "aaa"}).to_string();
    let s2 = json!({"type": "api-request", "shapeHash": "bbb"}).to_string();
    let t = [s1, rec("a", 0, OPUS, 5, 0, 20_000, true), s2, rec("b", 30, OPUS, 5, 0, 23_000, true)]
        .join("\n");
    assert_eq!(causes(&t, false).get("shape change"), Some(&20_005));
}

#[test]
fn a_streamed_request_counts_once_and_non_claude_models_not_at_all() {
    let t = [
        rec("a", 0, OPUS, 5, 0, 20_000, true),
        rec("a", 1, OPUS, 5, 0, 20_000, true),
        rec("x", 2, "gpt-5", 5, 0, 99_999, false),
    ]
    .join("\n");
    let i = analyze(&[Transcript { text: &t, helper: false }], 0.0, &fallback_rates);
    assert_eq!(i.requests, 1);
    assert_eq!(i.cache_write_tokens, 20_000);
}

#[test]
fn the_gap_is_priced_at_write_minus_read_and_the_floor_is_the_append() {
    let t =
        [rec("a", 0, OPUS, 0, 0, 1_000_000, true), rec("b", 30, OPUS, 0, 1_000_000, 500_000, true)]
            .join("\n");
    let i = analyze(&[Transcript { text: &t, helper: false }], 0.0, &fallback_rates);
    // Opus: a 1 h write is 2 x $5, a read $0.2: the session start's 1M tokens cost $9.8 over a read.
    assert!((i.gap_usd - 9.8).abs() < 1e-9, "{}", i.gap_usd);
    assert_eq!(i.floor_write_tokens, 500_000);
    assert_eq!(i.gap_write_tokens, 1_000_000);
    assert_eq!(i.causes.last().map(|c| c.cause.as_str()), Some("append"));
    assert!(i.causes.iter().all(|c| !c.fix.is_empty()));
}

#[test]
fn since_skips_older_requests_but_keeps_them_as_the_previous_one() {
    let t = [rec("a", 0, OPUS, 5, 0, 20_000, true), rec("b", 30, OPUS, 5, 20_005, 1_000, true)]
        .join("\n");
    let i = analyze(&[Transcript { text: &t, helper: false }], 1_764_072_010.0, &fallback_rates);
    assert_eq!(i.requests, 1);
    assert_eq!(i.gap_write_tokens, 0);
}

#[test]
fn subagent_transcripts_are_helpers() {
    assert!(is_helper(Path::new("/h/.claude/projects/p/abc/subagents/agent-1.jsonl")));
    assert!(!is_helper(Path::new("/h/.claude/projects/p/abc.jsonl")));
}

#[test]
fn every_cause_has_a_fix() {
    for c in CAUSES {
        assert!(!fix_for(c).is_empty(), "{c}");
    }
}
