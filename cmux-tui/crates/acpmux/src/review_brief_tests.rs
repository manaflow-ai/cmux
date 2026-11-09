use super::*;
use serde_json::json;

const CLAUDE: &str = include_str!("review_brief_fixtures/claude.ndjson");
const CODEX: &str = include_str!("review_brief_fixtures/codex.ndjson");
const ROOT: &str = "/work/repo";

fn records(log: &str) -> Vec<EventRecord> {
    log.lines().map(|line| serde_json::from_str(line).expect("a fixture record")).collect()
}

fn fold(log: &str) -> Fold {
    let mut fold = Fold::default();
    for rec in records(log) {
        fold.feed(&rec);
    }
    fold
}

#[test]
fn a_chat_s_brief_has_its_goal_plan_dropped_approach_and_unsure_spots() {
    let brief = fold(CLAUDE).brief(Some(ROOT));
    assert_eq!(
        brief["goal"],
        "Make the uploader retry failed chunks with backoff, and keep the progress bar honest."
    );
    assert_eq!(brief["planText"], "Retry each chunk; clamp progress.");
    assert_eq!(brief["plan"].as_array().unwrap().len(), 3);
    assert_eq!(brief["plan"][1], json!({"content": "Add retry with backoff", "status": "in_progress"}));
    assert_eq!(
        brief["rejected"],
        json!([{
            "text": "I first tried wrapping the whole upload in a retry loop, but that didn't work because it restarts finished chunks.",
            "seq": 4
        }])
    );
    assert_eq!(
        brief["unsure"],
        json!([
            // Written, undone, then written again: one spot for the chain.
            {"kind": "redone", "path": "src/upload.rs", "snippet": "retry(|| send(chunk))?;", "seq": 9},
            // Names its file.
            {"kind": "hedge", "text": "I'm not sure the backoff cap in upload.rs is right for slow links.",
             "path": "src/upload.rs", "seq": 11},
            // Names none: the last file its turn edited.
            {"kind": "hedge", "text": "The progress clamp is untested on resumed uploads.",
             "path": "src/progress.rs", "seq": 11},
        ])
    );
}

#[test]
fn a_subagent_s_words_and_code_blocks_are_not_the_chat_s_hedges() {
    let brief = fold(CLAUDE).brief(None);
    let texts: Vec<&str> =
        brief["unsure"].as_array().unwrap().iter().filter_map(|s| s["text"].as_str()).collect();
    assert!(!texts.iter().any(|t| t.contains("subagent")), "{texts:?}");
    assert!(!texts.iter().any(|t| t.contains("code line")), "{texts:?}");
}

#[test]
fn without_a_root_paths_stay_as_the_tool_calls_named_them() {
    let brief = fold(CLAUDE).brief(None);
    assert_eq!(brief["unsure"][0]["path"], "/work/repo/src/upload.rs");
}

#[test]
fn an_undo_never_redone_is_a_reverted_spot_with_the_text_it_took_out() {
    let lines: Vec<&str> = CLAUDE.lines().filter(|l| !l.contains("\"seq\": 9,")).collect();
    let brief = fold(&lines.join("\n")).brief(Some(ROOT));
    assert_eq!(
        brief["unsure"][0],
        json!({"kind": "reverted", "path": "src/upload.rs", "snippet": "retry(|| send(chunk))?;", "seq": 8})
    );
}

#[test]
fn text_rewritten_three_times_running_is_rework_and_a_short_prompt_is_not_the_goal() {
    let brief = fold(CODEX).brief(Some(ROOT));
    assert_eq!(brief["goal"], "Rename the config loader and update its callers.");
    assert_eq!(
        brief["unsure"],
        json!([{"kind": "reworked", "path": "cfg.py", "snippet": "def load_config(path=None):",
                "count": 2, "seq": 5}])
    );
    assert_eq!(
        brief["rejected"][0]["text"],
        "Switching to a keyword default rather than a required argument, since two callers pass nothing."
    );
}

#[test]
fn a_saved_fold_continued_from_its_seq_gives_the_brief_of_one_read() {
    let all = records(CLAUDE);
    for cut in 1..all.len() {
        let mut first = Fold::default();
        for rec in &all[..cut] {
            first.feed(rec);
        }
        let mut resumed = Fold::read(&serde_json::to_vec(&first).unwrap());
        assert_eq!(resumed, first, "the fold reads back whole at {cut}");
        // A scan from the saved seq may hand over records it already read.
        for rec in &all[cut.saturating_sub(1)..] {
            resumed.feed(rec);
        }
        assert_eq!(resumed.brief(Some(ROOT)), fold(CLAUDE).brief(Some(ROOT)), "cut at {cut}");
    }
}

#[test]
fn a_file_of_another_schema_is_folded_again() {
    assert_eq!(Fold::read(br#"{"schema":"old","seq":40}"#).seq, 0);
    assert_eq!(Fold::read(b"not json").seq, 0);
}

#[test]
fn every_list_stays_bounded_however_long_the_chat() {
    let mut fold = Fold::default();
    let mut seq = 0;
    for i in 0..2_000 {
        seq += 1;
        fold.feed(&EventRecord {
            seq,
            at: seq,
            dir: "in".into(),
            kind: "agent_message_chunk".into(),
            msg: json!({"params": {"update": {"messageId": format!("m{i}"), "content": {"type": "text",
                "text": format!("Attempt {i} didn't work at all. I'm not sure about step {i} here.")}}}}),
            host_seq: None,
        });
        seq += 1;
        fold.feed(&EventRecord {
            seq,
            at: seq,
            dir: "in".into(),
            kind: "tool_call".into(),
            msg: json!({"params": {"update": {"toolCallId": format!("t{i}"), "content": [{"type": "diff",
                "path": format!("/r/f{i}.rs"), "oldText": "a", "newText": format!("b{i}")}]}}}),
            host_seq: None,
        });
    }
    let saved = serde_json::to_vec(&fold).unwrap();
    assert!(saved.len() < 64 * 1024, "{} bytes", saved.len());
    let brief = fold.brief(None);
    assert!(brief["unsure"].as_array().unwrap().len() <= MAX_SPOTS);
    assert!(brief["rejected"].as_array().unwrap().len() <= 6);
}

fn tool(seq: u64, update: Value) -> EventRecord {
    EventRecord {
        seq,
        at: seq,
        dir: "in".into(),
        kind: if seq == 1 { "tool_call" } else { "tool_call_update" }.into(),
        msg: json!({"params": {"update": update}}),
        host_seq: None,
    }
}

fn diff(path: &str, old: &str, new: &str) -> Value {
    json!([{"type": "diff", "path": path, "oldText": old, "newText": new}])
}

#[test]
fn an_edit_counts_once_its_call_completes_and_a_failed_call_s_never() {
    let mut fold = Fold::default();
    // Proposed, then failed: no edit, so undoing it later is no revert.
    fold.feed(&tool(1, json!({"toolCallId": "a", "status": "pending",
        "content": diff("/r/x.rs", "one();", "two();")})));
    fold.feed(&tool(2, json!({"toolCallId": "a", "status": "failed"})));
    fold.feed(&tool(3, json!({"toolCallId": "b", "status": "completed",
        "content": diff("/r/x.rs", "two();", "one();")})));
    assert_eq!(fold.brief(Some("/r"))["unsure"], json!([]));
    // A diff corrected by a later update of the call is the edit that counts.
    fold.feed(&tool(4, json!({"toolCallId": "c", "status": "in_progress",
        "content": diff("/r/y.rs", "guess", "a();")})));
    fold.feed(&tool(5, json!({"toolCallId": "c", "content": diff("/r/y.rs", "b();", "a();")})));
    fold.feed(&tool(6, json!({"toolCallId": "c", "status": "completed"})));
    fold.feed(&tool(7, json!({"toolCallId": "d", "status": "completed",
        "content": diff("/r/y.rs", "a();", "b();")})));
    assert_eq!(
        fold.brief(Some("/r"))["unsure"],
        json!([{"kind": "reverted", "path": "y.rs", "snippet": "a();", "seq": 7}])
    );
}

#[test]
fn a_relative_path_counts_under_its_root_by_the_canonical_path_the_hub_added() {
    let mut fold = Fold::default();
    let edit = |seq: u64, id: &str, old: &str, new: &str| {
        tool(seq, json!({"toolCallId": id, "status": "completed", "content": [{"type": "diff",
            "path": "./src/a.rs", "oldText": old, "newText": new,
            "_meta": {"acpmux": {"canonicalPath": "/r/src/a.rs"}}}]}))
    };
    fold.feed(&edit(1, "a", "x();", "y();"));
    fold.feed(&edit(2, "b", "y();", "x();"));
    assert_eq!(fold.brief(Some("/r"))["unsure"][0]["path"], "src/a.rs");
}
