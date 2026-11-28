use super::*;
use serde_json::json;

const SID: &str = "11111111-2222-3333-4444-555555555555";

fn rec(v: Value) -> Value {
    let mut v = v;
    v["sessionId"] = json!(SID);
    v
}

fn prompt(uuid: &str, parent: &str, text: &str) -> Value {
    rec(
        json!({"type": "user", "uuid": uuid, "parentUuid": parent, "message": {"role": "user", "content": text}}),
    )
}

fn call(uuid: &str, parent: &str, id: &str, name: &str, input: Value) -> Value {
    rec(
        json!({"type": "assistant", "uuid": uuid, "parentUuid": parent, "message": {"role": "assistant", "content": [
        {"type": "thinking", "thinking": "hmm", "signature": "sig-abc"},
        {"type": "tool_use", "id": id, "name": name, "input": input}
    ], "usage": {"input_tokens": 10, "cache_read_input_tokens": 50_000, "cache_creation_input_tokens": 100, "output_tokens": 20}}}),
    )
}

fn result(uuid: &str, parent: &str, id: &str, text: &str) -> Value {
    rec(
        json!({"type": "user", "uuid": uuid, "parentUuid": parent, "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": id, "content": text}
    ]}, "toolUseResult": {"stdout": text}}),
    )
}

/// `turns` person turns, each one Read of a big file and one tiny Bash.
fn transcript(turns: usize) -> Vec<Value> {
    let big = "x".repeat(10_000);
    let mut out = vec![json!({"type": "queue-operation", "operation": "enqueue"})];
    let mut parent = String::new();
    for t in 0..turns {
        let p = format!("p{t}");
        out.push(prompt(&p, &parent, &format!("turn {t}")));
        out.push(call(
            &format!("a{t}"),
            &p,
            &format!("r{t}"),
            "Read",
            json!({"file_path": format!("/src/f{t}.rs")}),
        ));
        out.push(result(&format!("u{t}"), &format!("a{t}"), &format!("r{t}"), &big));
        out.push(call(
            &format!("b{t}"),
            &format!("u{t}"),
            &format!("s{t}"),
            "Bash",
            json!({"command": "ls"}),
        ));
        out.push(result(&format!("v{t}"), &format!("b{t}"), &format!("s{t}"), "ok"));
        parent = format!("v{t}");
    }
    out
}

fn parsed(m: &Masked) -> Vec<Value> {
    m.lines.iter().map(|l| serde_json::from_str(l).unwrap()).collect()
}

#[test]
fn masks_only_large_results_older_than_the_last_turns() {
    let records = transcript(5);
    let m = mask_records(records.clone(), MaskOptions::default()).unwrap().unwrap();
    // Turns 0 and 1 are older than the last 3: their big Reads go, nothing else.
    assert_eq!(m.masked, 2);
    assert_eq!(m.keys, vec!["path:/src/f0.rs", "path:/src/f1.rs"]);
    let out = parsed(&m);
    assert_eq!(out.len(), records.len(), "no record added or removed");
    for (a, b) in records.iter().zip(&out) {
        assert_eq!(a.get("uuid"), b.get("uuid"));
        assert_eq!(a.get("parentUuid"), b.get("parentUuid"));
        if a.get("sessionId").is_some() {
            assert_eq!(b["sessionId"], json!(m.id));
        }
    }
    let stub = out[3].pointer("/message/content/0/content").unwrap().as_str().unwrap();
    assert!(stub.starts_with("[masked by harness: Read /src/f0.rs, 10000 chars"), "{stub}");
    assert_eq!(out[3]["toolUseResult"], json!(stub));
    // The tool_use pairing stays: the id is still answered.
    assert_eq!(out[3].pointer("/message/content/0/tool_use_id"), Some(&json!("r0")));
    // Thinking with its signature and tool inputs verbatim; small results whole.
    assert_eq!(out[2], {
        let mut r = records[2].clone();
        r["sessionId"] = json!(m.id);
        r
    });
    assert_eq!(out[5].pointer("/message/content/0/content"), Some(&json!("ok")));
    // The last three turns' big Reads are whole.
    for i in [13, 18, 23] {
        assert_eq!(
            out[i].pointer("/message/content/0/content").unwrap().as_str().unwrap().len(),
            10_000
        );
    }
    assert_eq!(m.tokens_before, Some(50_130));
    assert!(m.tokens_after().unwrap() < 50_130 - 4_000);
}

#[test]
fn nothing_to_mask_with_few_turns() {
    assert!(mask_records(transcript(3), MaskOptions::default()).unwrap().is_none());
    let opts = MaskOptions { keep_turns: 1, min_chars: 20_000 };
    assert!(mask_records(transcript(5), opts).unwrap().is_none());
}

#[test]
fn refuses_a_tool_call_without_a_result() {
    let mut records = transcript(5);
    records.push(call("z", "v4", "open", "Bash", json!({"command": "sleep 9"})));
    assert!(mask_records(records, MaskOptions::default()).is_err());
}

#[test]
fn leaves_records_before_the_last_compaction() {
    let mut records = transcript(4);
    records.push(rec(json!({"type": "system", "subtype": "compact_boundary", "uuid": "cb"})));
    records.extend(transcript(4).into_iter().skip(1).map(|mut r| {
        if let Some(u) = r.get("uuid").and_then(Value::as_str) {
            r["uuid"] = json!(format!("n{u}"));
        }
        if let Some(Value::Array(blocks)) = r.pointer_mut("/message/content") {
            for b in blocks {
                for k in ["id", "tool_use_id"] {
                    if let Some(id) = b.get(k).and_then(Value::as_str) {
                        b[k] = json!(format!("n{id}"));
                    }
                }
            }
        }
        r
    }));
    let m = mask_records(records, MaskOptions::default()).unwrap().unwrap();
    // Only the first turn after the boundary; the four before it are not sent anyway.
    assert_eq!(m.masked, 1);
}

#[test]
fn masking_twice_masks_nothing_new() {
    let m = mask_records(transcript(5), MaskOptions::default()).unwrap().unwrap();
    assert!(mask_records(parsed(&m), MaskOptions::default()).unwrap().is_none());
}

#[test]
fn writes_beside_the_original_and_never_over_it() {
    let dir = tempfile::tempdir().unwrap();
    let original = dir.path().join(format!("{SID}.jsonl"));
    let lines: Vec<String> = transcript(5).iter().map(|r| r.to_string()).collect();
    std::fs::write(&original, lines.join("\n") + "\n").unwrap();
    let before = std::fs::read(&original).unwrap();
    let m = mask_claude(&original, MaskOptions::default()).unwrap().unwrap();
    let path = write_beside(&original, &m).unwrap();
    assert_eq!(path.parent(), original.parent());
    assert_eq!(std::fs::read(&original).unwrap(), before, "the original is untouched");
    assert!(write_beside(&original, &m).is_err(), "never over an existing file");
}

#[test]
fn switches_and_counters() {
    assert!(enabled_with(None, None));
    assert!(!enabled_with(None, Some("0")));
    let off = json!({"agents": {"harnessMagic": {"surgery": {"enabled": false}}}});
    assert!(!enabled_with(Some(&off), None));
    let opts = options_with(Some(
        &json!({"agents": {"harnessMagic": {"surgery": {"keepTurns": 5, "minChars": 10}}}}),
    ));
    assert_eq!((opts.keep_turns, opts.min_chars), (5, 256));

    let s = "surgery-counters-test";
    let m = mask_records(transcript(5), MaskOptions::default()).unwrap().unwrap();
    note_run(s, &m);
    note_tool_input(s, &json!({"file_path": "/src/f0.rs"}));
    note_tool_input(s, &json!({"file_path": "/src/f0.rs"}));
    note_tool_input(s, &json!({"file_path": "/src/other.rs"}));
    let f = turn_fields(s);
    assert_eq!(f["harnessMagic.surgery.runs"], json!(1));
    assert_eq!(f["harnessMagic.surgery.maskedResults"], json!(2));
    assert_eq!(f["harnessMagic.surgery.refetched"], json!(1));
    assert_eq!(f["harnessMagic.surgery.tokensBefore"], json!(50_130));
    for _ in 1..REFETCH_TURNS {
        let f = turn_fields(s);
        assert!(!f.contains_key("harnessMagic.surgery.runs"));
        assert_eq!(f["harnessMagic.surgery.refetched"], json!(0));
    }
    assert!(turn_fields(s).is_empty());
}

#[test]
fn timer_waits_for_a_cold_cache_over_the_share() {
    let update = |used: u64| json!({"used": used, "size": 200_000, "_meta": {"acpmux": {"cacheExpiresAt": 100_000}}});
    assert_eq!(trigger_wait_ms(&update(100_000), 0), None);
    assert_eq!(trigger_wait_ms(&update(130_000), 0), Some(105_000));
    assert_eq!(trigger_wait_ms(&update(130_000), 200_000), Some(1));
}

#[test]
fn stubs_name_the_call() {
    assert_eq!(
        stub("Bash", Some(&json!({"command": "cargo   test\n -p x"})), 900),
        "[masked by harness: Bash cargo test -p x, 900 chars; you saw it in full then; removed since to save context, re-run or Read to see it again]"
    );
    assert_eq!(
        refetch_key(&json!({"pattern": "fn main", "path": "src"})).as_deref(),
        Some("search:fn main@src")
    );
}

/// A compaction trigger that tried surgery and sent `/compact` after all counts once per
/// fallback on the next `turn_result`, then clears; nothing else shows with it.
#[test]
fn fallbacks_count_on_the_next_turn_result() {
    let s = "surgery-fallbacks-test";
    note_fallback(s);
    note_fallback(s);
    let f = turn_fields(s);
    assert_eq!(f["harnessMagic.surgery.fallbacks"], json!(2));
    assert!(!f.contains_key("harnessMagic.surgery.runs"));
    assert!(!f.contains_key("harnessMagic.surgery.refetched"));
    assert!(turn_fields(s).is_empty());
}

/// Surgery stands in for `/compact` only when its dry run masks something and lands under the
/// trigger's line; an applied answer alone skips `/compact`.
#[test]
fn surgery_before_compact_decisions() {
    use super::super::cold_wake::{surgery_applied, surgery_suffices};
    let dry = |masked: u64, after: u64| -> Result<Value, RpcError> {
        Ok(json!({"dryRun": true, "maskedResults": masked, "tokensAfter": after}))
    };
    assert!(surgery_suffices(&dry(3, 150_000), 200_000));
    assert!(!surgery_suffices(&dry(3, 210_000), 200_000));
    assert!(!surgery_suffices(&dry(0, 10_000), 200_000));
    assert!(!surgery_suffices(&Ok(refused("off")), 200_000));
    assert!(surgery_applied(&Ok(json!({"applied": true}))));
    assert!(!surgery_applied(&Ok(refused("busy"))));
}
