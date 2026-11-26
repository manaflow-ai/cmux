use super::*;
use serde_json::json;

const THREAD: &str = "019a0000-1111-7222-8333-444444444444";

fn item(payload: Value) -> Value {
    json!({"timestamp": "2026-11-26T03:00:00Z", "type": "response_item", "payload": payload})
}

fn event(payload: Value) -> Value {
    json!({"timestamp": "2026-11-26T03:00:00Z", "type": "event_msg", "payload": payload})
}

/// `turns` turns, each one big `shell` read and one tiny `apply_patch`.
fn rollout(turns: usize) -> Vec<Value> {
    let big = "x".repeat(10_000);
    let mut out = vec![json!({"type": "session_meta", "payload": {"id": THREAD, "cwd": "/w"}})];
    for t in 0..turns {
        out.push(event(json!({"type": "task_started"})));
        out.push(event(json!({"type": "user_message", "message": format!("turn {t}")})));
        out.push(item(
            json!({"type": "message", "role": "user", "content": [{"type": "input_text", "text": format!("turn {t}")}]}),
        ));
        out.push(item(
            json!({"type": "reasoning", "summary": [], "encrypted_content": "enc-abc"}),
        ));
        out.push(item(json!({"type": "function_call", "name": "shell", "call_id": format!("c{t}"),
            "arguments": json!({"command": ["bash", "-lc", format!("cat src/f{t}.rs")]}).to_string()})));
        out.push(item(
            json!({"type": "function_call_output", "call_id": format!("c{t}"), "output": big}),
        ));
        out.push(item(json!({"type": "custom_tool_call", "name": "apply_patch", "call_id": format!("p{t}"), "input": "*** Begin Patch"})));
        out.push(item(
            json!({"type": "custom_tool_call_output", "call_id": format!("p{t}"), "output": "ok"}),
        ));
        out.push(event(
            json!({"type": "token_count", "info": {"last_token_usage": {"input_tokens": 60_000, "output_tokens": 100, "total_tokens": 60_100}}}),
        ));
        out.push(event(json!({"type": "task_complete"})));
    }
    out
}

fn parsed(m: &Masked) -> Vec<Value> {
    m.lines.iter().map(|l| serde_json::from_str(l).unwrap()).collect()
}

#[test]
fn masks_old_large_outputs_and_renames_the_thread() {
    let records = rollout(5);
    let m = mask_codex_records(records.clone(), MaskOptions::default()).unwrap().unwrap();
    assert_eq!(m.masked, 2, "turns 0 and 1 are older than the last 3");
    assert_eq!(m.keys, vec!["cmd:cat src/f0.rs", "cmd:cat src/f1.rs"]);
    assert_eq!(m.thread.as_deref(), Some(THREAD));
    assert_eq!(m.tokens_before, Some(60_100));
    assert!(m.tokens_after().unwrap() < 60_100);
    let out = parsed(&m);
    assert_eq!(out.len(), records.len(), "no record added or removed");
    assert_eq!(out[0]["payload"]["id"], json!(m.id), "session_meta names the copy");
    assert_eq!(out[0]["payload"]["cwd"], json!("/w"));
    let mut masked = 0;
    for (a, b) in records.iter().zip(&out) {
        if a["type"] == "session_meta" {
            continue;
        }
        let output = b.pointer("/payload/output").and_then(Value::as_str).unwrap_or("");
        if output.starts_with("[masked by harness:") {
            masked += 1;
            assert_eq!(a["payload"]["call_id"], b["payload"]["call_id"]);
            assert!(output.contains("shell cat src/f"), "the stub names the call: {output}");
            assert!(output.contains("you saw it in full then"));
        } else {
            assert_eq!(a, b, "every other record is copied verbatim");
        }
    }
    assert_eq!(masked, 2);
}

#[test]
fn only_records_after_the_last_compaction_are_masked() {
    let mut records = rollout(2);
    records.push(json!({"type": "compacted", "payload": {"message": "summary", "replacement_history": []}}));
    records.extend(rollout(5).into_iter().skip(1));
    let m = mask_codex_records(records.clone(), MaskOptions::default()).unwrap().unwrap();
    assert_eq!(m.masked, 2, "the two turns before the compaction are left alone");
    let out = parsed(&m);
    let compacted = records.iter().position(|r| r["type"] == "compacted").unwrap();
    assert_eq!(&out[..compacted], &{
        let mut head = records[..compacted].to_vec();
        head[0]["payload"]["id"] = json!(m.id);
        head
    }[..]);
}

#[test]
fn refuses_a_call_with_no_output_and_skips_short_chats() {
    let mut records = rollout(5);
    records.push(event(json!({"type": "task_started"})));
    records.push(item(
        json!({"type": "function_call", "name": "shell", "call_id": "open", "arguments": "{}"}),
    ));
    let err = mask_codex_records(records, MaskOptions::default()).unwrap_err();
    assert!(err.to_string().contains("no output yet"), "{err}");
    assert!(mask_codex_records(rollout(3), MaskOptions::default()).unwrap().is_none());
    let no_meta: Vec<Value> = rollout(5).into_iter().skip(1).collect();
    assert!(mask_codex_records(no_meta, MaskOptions::default()).is_err());
}

#[test]
fn masking_twice_masks_nothing_new() {
    let m = mask_codex_records(rollout(5), MaskOptions::default()).unwrap().unwrap();
    let again = mask_codex_records(parsed(&m), MaskOptions::default()).unwrap();
    assert!(again.is_none());
}

#[test]
fn call_input_reads_every_call_shape() {
    let shell = json!({"arguments": r#"{"command":["bash","-lc","rg foo"]}"#});
    assert_eq!(refetch_key(&call_input(&shell)).as_deref(), Some("cmd:rg foo"));
    let exec = json!({"arguments": r#"{"cmd":"ls -la"}"#});
    assert_eq!(refetch_key(&call_input(&exec)).as_deref(), Some("cmd:ls -la"));
    let local = json!({"action": {"type": "exec", "command": ["git", "status"]}});
    assert_eq!(refetch_key(&call_input(&local)).as_deref(), Some("cmd:git status"));
    let custom = json!({"input": "*** Begin Patch"});
    assert_eq!(call_input(&custom), json!({"input": "*** Begin Patch"}));
}

#[test]
fn writes_beside_under_the_new_thread_id() {
    let dir = tempfile::tempdir().unwrap();
    let day = dir.path().join("sessions/2026/11/26");
    std::fs::create_dir_all(&day).unwrap();
    let original = day.join(format!("rollout-2026-11-26T03-00-00-{THREAD}.jsonl"));
    let text: String = rollout(5).iter().map(|r| format!("{r}\n")).collect();
    std::fs::write(&original, &text).unwrap();
    let m = mask_codex(&original, MaskOptions::default()).unwrap().unwrap();
    let path = write_codex_beside(&original, &m).unwrap();
    assert_eq!(
        path.file_name().unwrap().to_str().unwrap(),
        format!("rollout-2026-11-26T03-00-00-{}.jsonl", m.id)
    );
    assert_eq!(std::fs::read_to_string(&original).unwrap(), text, "the original is unchanged");
    assert_eq!(crate::adopt::find_codex(dir.path(), &m.id).as_deref(), Some(path.as_path()));
    assert!(write_codex_beside(&original, &m).is_err(), "never over a file");
}
