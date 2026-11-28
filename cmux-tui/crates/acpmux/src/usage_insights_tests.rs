use super::*;
use serde_json::json;

const MIN: u64 = 60_000;

fn req(at_min: u64, input: u64, read: u64, write: u64) -> Request {
    Request {
        at_ms: at_min * MIN,
        input,
        cache_read: read,
        cache_write: write,
        hour_cache: true,
        model: "claude-opus-5-5".into(),
        shape: None,
        compacted: false,
    }
}

fn causes(requests: &[Request]) -> Vec<(usize, Cause, u64)> {
    classify(requests, false)
}

#[test]
fn a_warm_follow_up_writes_only_what_it_appended() {
    let requests = [req(0, 10, 0, 50_000), req(1, 10, 50_010, 3_000)];
    assert_eq!(
        causes(&requests),
        vec![(0, Cause::SessionStart, 50_000), (1, Cause::Append, 3_000)]
    );
}

#[test]
fn a_helper_first_request_is_helper_start() {
    let requests = [req(0, 10, 0, 20_000)];
    assert_eq!(classify(&requests, true), vec![(0, Cause::HelperStart, 20_000)]);
}

#[test]
fn a_short_read_within_block_rounding_is_not_a_rewrite() {
    let requests = [req(0, 0, 0, 50_000), req(1, 0, 50_000 - TOLERANCE, 2_000)];
    assert_eq!(causes(&requests)[1], (1, Cause::Append, 2_000));
}

#[test]
fn each_rewrite_takes_the_first_cause_that_holds() {
    // Past the hour lifetime: idle wake.
    let idle = [req(0, 0, 0, 80_000), req(61, 0, 0, 82_000)];
    assert_eq!(&causes(&idle)[1..], &[(1, Cause::IdleWake, 80_000), (1, Cause::Append, 2_000)]);

    // A 5-minute write goes cold after five minutes.
    let mut short = [req(0, 0, 0, 80_000), req(6, 0, 0, 80_000)];
    short[0].hour_cache = false;
    assert_eq!(causes(&short)[1], (1, Cause::IdleWake, 80_000));

    // A compaction beats every other cause, even a long gap.
    let mut compact = [req(0, 0, 0, 150_000), req(90, 0, 0, 20_000)];
    compact[1].compacted = true;
    assert_eq!(causes(&compact)[1], (1, Cause::Compaction, 20_000));

    let mut model = [req(0, 0, 0, 40_000), req(1, 0, 0, 40_000)];
    model[1].model = "claude-sonnet-5-5".into();
    assert_eq!(causes(&model)[1], (1, Cause::ModelSwitch, 40_000));

    let mut shape = [req(0, 0, 0, 40_000), req(1, 0, 0, 40_000)];
    shape[0].shape = Some("a".into());
    shape[1].shape = Some("b".into());
    assert_eq!(causes(&shape)[1], (1, Cause::ShapeChange, 40_000));

    let lost = [req(0, 0, 0, 40_000), req(20, 0, 0, 40_000)];
    assert_eq!(causes(&lost)[1], (1, Cause::LostUnderTtl, 40_000));

    // Read back only the first half within a minute: something early changed.
    let edit = [req(0, 0, 0, 40_000), req(1, 0, 20_000, 22_000)];
    assert_eq!(&causes(&edit)[1..], &[(1, Cause::PrefixEdit, 20_000), (1, Cause::Append, 2_000)]);
}

#[test]
fn the_rewrite_never_exceeds_the_request_write() {
    // A big previous context, a small write: the rewrite is capped at what was written.
    let requests = [req(0, 0, 0, 100_000), req(70, 5_000, 0, 10_000)];
    assert_eq!(causes(&requests)[1..], [(1, Cause::IdleWake, 10_000)]);
}

fn line(value: serde_json::Value) -> String {
    format!("{value}\n")
}

fn assistant(at: &str, id: &str, read: u64, write: u64) -> String {
    line(json!({
        "type": "assistant",
        "timestamp": at,
        "requestId": id,
        "promptCacheRequested": "1h",
        "message": {"id": id, "model": "claude-opus-5-5", "content": [{"type": "text", "text": "secret reply"}],
                    "usage": {"input_tokens": 3, "output_tokens": 9, "cache_read_input_tokens": read,
                              "cache_creation_input_tokens": write}}
    }))
}

#[test]
fn a_transcript_parses_each_request_once_and_marks_compaction() {
    let mut text = String::new();
    text += &line(json!({"type": "user", "message": {"content": "a prompt nobody reads"}}));
    text += &assistant("2026-11-25T10:00:00.000Z", "r1", 0, 30_000);
    // The same request streamed again: counted once.
    text += &assistant("2026-11-25T10:00:01.000Z", "r1", 0, 30_000);
    text += &line(json!({"type": "system", "subtype": "compact_boundary"}));
    text += &assistant("2026-11-25T10:02:00.000Z", "r2", 0, 9_000);
    text += "not json\n";
    text += &line(json!({"type": "assistant", "timestamp": "2026-11-25T10:03:00Z",
                         "message": {"model": "<synthetic>", "usage": {"input_tokens": 1}}}));
    let requests = parse_transcript(text.as_bytes());
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[0].cache_write, 30_000);
    assert!(requests[0].hour_cache);
    assert!(!requests[0].compacted);
    assert!(requests[1].compacted);
    assert_eq!(requests[1].at_ms - requests[0].at_ms, 2 * MIN);
    assert_eq!(
        classify(&requests, false),
        vec![(0, Cause::SessionStart, 30_000), (1, Cause::Compaction, 9_000)]
    );
}

#[test]
fn the_report_counts_only_the_window_and_prices_the_gap() {
    // The first request is before the window: it sets what the next should read, but is not counted.
    let requests = vec![req(0, 0, 0, 100_000), req(70, 0, 0, 104_000), req(71, 0, 104_000, 1_000)];
    let report = report([("s1".to_owned(), false, requests.as_slice())], 60 * MIN, 120 * MIN);
    assert_eq!(report.requests, 2);
    assert_eq!(report.cache_write_tokens, 105_000);
    assert_eq!(report.avoidable_tokens, 100_000);
    assert_eq!(report.floor_tokens, 5_000);
    assert_eq!(report.avoidable_share, Some(0.9524));
    assert_eq!(report.causes[0].cause, Cause::IdleWake);
    assert!(report.causes[0].avoidable);
    // Opus 5.5: hour write 2 x 4 = $8/M, read $0.2/M; 100k tokens rewritten = $0.80, $0.78 avoidable.
    assert_eq!(report.causes[0].cost_usd, 0.8);
    assert_eq!(report.avoidable_usd, 0.78);
    assert_eq!(report.top_sessions.len(), 1);
    assert_eq!(report.top_sessions[0].top_cause, Some(Cause::IdleWake));
    assert!(report.headline.as_deref().is_some_and(|h| h.starts_with("idle_wake rewrote 100000")));
    assert!(report.unpriced_models.is_empty());
}

#[test]
fn an_unpriced_model_counts_tokens_but_no_cost() {
    let mut requests = vec![req(0, 0, 0, 10_000)];
    requests[0].model = "claude-unknown-9".into();
    let report = report([("s".to_owned(), false, requests.as_slice())], 0, 10 * MIN);
    assert_eq!(report.cache_write_tokens, 10_000);
    assert_eq!(report.cache_write_usd, 0.0);
    assert_eq!(report.unpriced_models, vec!["claude-unknown-9".to_owned()]);
}

#[test]
fn the_report_json_names_causes_in_snake_case_and_carries_no_content() {
    let requests = vec![req(0, 0, 0, 10_000), req(30, 0, 0, 10_000)];
    let report = report([("s".to_owned(), false, requests.as_slice())], 0, 60 * MIN);
    let json = serde_json::to_value(&report).unwrap();
    assert_eq!(json["insight"], "cache_waste");
    // Equal tokens: the cause order breaks the tie, the floor's session start first.
    assert_eq!(json["causes"][0]["cause"], "session_start");
    assert_eq!(json["causes"][1]["cause"], "lost_under_ttl");
    assert_eq!(json["causes"][1]["avoidable"], true);
    assert!(json["causes"][1]["fix"].as_str().is_some_and(|fix| !fix.is_empty()));
    assert!(!json.to_string().contains("secret"));
    assert!(json.get("avoidableShare").is_some());
    let text = render(&report);
    assert!(text.contains("lost_under_ttl"), "{text}");
}

#[test]
fn transcripts_are_found_with_their_helpers_and_cut_by_age() {
    let home = tempfile::tempdir().unwrap();
    let project = home.path().join("projects/-Users-me-repo");
    std::fs::create_dir_all(project.join("sid/subagents")).unwrap();
    std::fs::write(project.join("sid.jsonl"), assistant("2026-11-25T10:00:00Z", "a", 0, 10))
        .unwrap();
    std::fs::write(project.join("sid/subagents/agent-1.jsonl"), "").unwrap();
    std::fs::write(project.join("notes.txt"), "").unwrap();
    let homes = vec![home.path().to_path_buf(), home.path().to_path_buf()];
    let found = transcripts(&homes, 0);
    let mut names: Vec<(String, bool)> = found
        .iter()
        .map(|(path, helper)| (path.file_name().unwrap().to_string_lossy().into_owned(), *helper))
        .collect();
    names.sort();
    assert_eq!(names, vec![("agent-1.jsonl".into(), true), ("sid.jsonl".into(), false)]);
    assert!(transcripts(&homes, u64::MAX).is_empty());
}

#[test]
fn every_cause_has_a_key_and_a_fix_and_only_rewrites_are_avoidable() {
    let keys: HashSet<&str> = Cause::ALL.iter().map(|cause| cause.key()).collect();
    assert_eq!(keys.len(), Cause::ALL.len());
    for cause in Cause::ALL {
        assert!(!cause.fix().is_empty());
        let json = serde_json::to_value(cause).unwrap();
        assert_eq!(json, cause.key());
    }
    let avoidable: Vec<Cause> = Cause::ALL.into_iter().filter(|cause| cause.avoidable()).collect();
    assert_eq!(avoidable.len(), 6);
}
