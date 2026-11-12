//! Resume of a stopped Claude subagent (`subagent_resume.rs`): a stopped one is resumable with its
//! brief, Resume sends the parent the seeded prompt, the new run links to the old one, and its end
//! is the old row's end.

use super::*;
use crate::config::{Config, StoreMode};
use crate::rpc::{Message, method};
use std::time::Duration;
use tokio::sync::mpsc;

/// A hub with one chat (a stand-in agent).
async fn chat() -> (Arc<Hub>, Arc<Session>, mpsc::Sender<String>) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let (in_tx, in_rx) = mpsc::channel(8);
    let (out_tx, mut out_rx) = mpsc::channel(256);
    tokio::spawn(crate::server::serve_connection_with(
        hub.clone(),
        in_rx,
        out_tx,
        crate::server::Origin::Local,
    ));
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": []});
    in_tx.send(Message::request(1, method::SESSION_NEW, new).to_line()).await.unwrap();
    loop {
        let reply: Value = serde_json::from_str(&out_rx.recv().await.unwrap()).unwrap();
        if reply["id"] == 1 {
            let session = hub.resolve(reply["result"]["sessionId"].as_str().unwrap()).unwrap();
            return (hub, session, in_tx);
        }
    }
}

fn by_person() -> RetryBy {
    RetryBy {
        control: crate::hub::Control::Local,
        trust_gate: false,
        full_access_device: None,
        from: None,
    }
}

/// A background helper's spawn, as the subagent tree reports it.
fn spawned(id: &str, prompt: &str) -> Value {
    json!({"id": id, "parent": null, "state": "running", "name": "Fix the build",
        "task": "Fix the build", "kind": "general-purpose", "prompt": prompt,
        "background": true, "toolCallId": id.rsplit('/').next()})
}

/// Its end after Stop: Claude Code's `task_notification` `stopped`.
fn stopped(id: &str) -> Value {
    json!({"id": id, "parent": null, "state": "cancelled",
        "agentId": format!("agent{}", id.rsplit('/').next().unwrap_or(id))})
}

/// The subagent's last entry acpmux logged about its resume.
fn last_entry(hub: &Hub, session: &Session, id: &str) -> Option<Value> {
    let records = hub.events(&session.id, 0, 10_000).unwrap();
    records
        .into_iter()
        .rev()
        .filter_map(|e| e.msg.pointer("/params/_meta/acpmux/subagents/0").cloned())
        .find(|e| e["id"] == id && (e.get("resumable").is_some() || e.get("resumedBy").is_some()))
}

fn prompts(hub: &Hub, session: &Session) -> Vec<Value> {
    let records = hub.events(&session.id, 0, 10_000).unwrap();
    records.into_iter().filter(|e| e.kind == "user_message").map(|e| e.msg).collect()
}

const TRANSCRIPT: &str = concat!(
    r#"{"type":"user","message":{"role":"user","content":"Fix the build"}}"#,
    "\n",
    r#"{"type":"assistant","message":{"content":[{"type":"text","text":"Looking at the failing job."},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"gh run view 42 --log-failed"}}]}}"#,
    "\n",
    r#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"error: unused import `canonical_path`"}]}}"#,
    "\n",
    r#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":"src/lib.rs"}}]}}"#,
    "\n",
    "not json\n",
);

#[test]
fn the_digest_reads_the_last_steps_in_order() {
    let d = digest(TRANSCRIPT);
    let lines: Vec<&str> = d.lines().collect();
    assert_eq!(lines[0], "- said: Looking at the failing job.", "{d}");
    assert!(lines[1].starts_with("- called Bash: {\"command\":\"gh run view 42"), "{d}");
    assert_eq!(lines[2], "  result: error: unused import `canonical_path`", "{d}");
    assert!(lines[3].starts_with("- called Edit:"), "{d}");
    assert_eq!(lines.len(), 4, "the user's first words and a bad line are left out: {d}");
}

#[test]
fn the_digest_is_bounded_and_keeps_the_newest_steps() {
    let line = |i: usize| {
        format!(
            r#"{{"type":"assistant","message":{{"content":[{{"type":"text","text":"step {i} {}"}}]}}}}"#,
            "x".repeat(200)
        )
    };
    let text: String = (0..200).map(|i| line(i) + "\n").collect();
    let d = digest(&text);
    assert!(d.len() < DIGEST_CHARS + 400, "{}", d.len());
    assert!(d.starts_with("(earlier steps left out)"), "{d}");
    assert!(d.trim_end().ends_with(&"x".repeat(200)) && d.contains("step 199 "), "{d}");
    assert!(!d.contains("step 0 "), "{d}");
}

#[test]
fn the_seeded_prompt_has_the_brief_the_transcript_and_the_marker() {
    let brief = Brief {
        name: Some("Fix the build".into()),
        task: Some("Fix the build".into()),
        kind: Some("general-purpose".into()),
        prompt: Some("Read the brief file. Fix CI.".into()),
        background: true,
        agent_id: Some("a6a1d".into()),
        state: "cancelled".into(),
        ..Brief::default()
    };
    let path = Path::new("/h/.claude/projects/p/s1/subagents/agent-a6a1d.jsonl");
    let text = resume_text("s/toolu_1", &brief, Some((path, TRANSCRIPT)));
    assert!(text.contains("subagent_type \"general-purpose\""), "{text}");
    assert!(text.contains("description \"Fix the build\""), "{text}");
    assert!(text.contains("run_in_background true"), "{text}");
    assert!(text.contains("will not resume a stopped agent with SendMessage"), "{text}");
    let seeded = text.split("<<<RESUME PROMPT\n").nth(1).unwrap();
    assert!(seeded.starts_with("Read the brief file. Fix CI.\n"), "the brief first: {seeded}");
    assert!(seeded.contains(&path.display().to_string()), "{seeded}");
    assert!(seeded.contains("result: error: unused import"), "its last steps: {seeded}");
    assert!(seeded.contains("Continue from its last step"), "{seeded}");
    assert_eq!(marked(seeded), Some("s/toolu_1"), "{seeded}");
}

#[tokio::test]
async fn a_stopped_subagent_is_resumable_with_its_brief() {
    let (hub, session, _conn) = chat().await;
    hub.observe_resumable(&session, &[spawned("s/t1", "Fix CI")]);
    assert!(last_entry(&hub, &session, "s/t1").is_none(), "a running one is not resumable");
    hub.observe_resumable(&session, &[stopped("s/t1")]);
    let entry = last_entry(&hub, &session, "s/t1").expect("its entry after the Stop");
    assert_eq!((&entry["state"], &entry["resumable"]), (&json!("cancelled"), &json!(true)));
    let (id, brief) = hub.resumable_subagent(&session, "s/t1").await.unwrap();
    assert_eq!(id, "s/t1");
    assert_eq!(brief.prompt.as_deref(), Some("Fix CI"));
    assert_eq!(brief.kind.as_deref(), Some("general-purpose"));
    assert!(brief.background);
    // Named by its agent id too.
    assert!(hub.resumable_subagent(&session, "agentt1").await.is_some());
    // One whose brief acpmux never saw, or that finished, is not.
    hub.observe_resumable(&session, &[json!({"id": "s/t2", "parent": null, "state": "running"})]);
    hub.observe_resumable(&session, &[stopped("s/t2")]);
    assert!(hub.resumable_subagent(&session, "s/t2").await.is_none());
    hub.observe_resumable(
        &session,
        &[spawned("s/t3", "Review"), json!({"id": "s/t3", "parent": null, "state": "completed"})],
    );
    assert!(hub.resumable_subagent(&session, "s/t3").await.is_none());
}

#[tokio::test]
async fn a_subagent_lost_with_its_harness_is_resumable() {
    let (hub, session, _conn) = chat().await;
    hub.observe_resumable(&session, &[spawned("s/t1", "Fix CI")]);
    hub.subagents_lost(&session);
    let entry = last_entry(&hub, &session, "s/t1").unwrap();
    assert_eq!((&entry["state"], &entry["resumable"]), (&json!("disconnected"), &json!(true)));
    assert_eq!(entry["reason"], "harness_exit");
    assert!(hub.resumable_subagent(&session, "s/t1").await.is_some());
}

/// Kill a subagent, Resume it: the parent gets the seeded prompt; the new Agent run links to the
/// old one, and when it completes the old row ends completed with it.
#[tokio::test]
async fn a_resumed_subagent_continues_as_the_same_helper_and_reports_back() {
    let (hub, session, _conn) = chat().await;
    hub.observe_resumable(&session, &[spawned("s/t1", "Fix CI")]);
    hub.observe_resumable(&session, &[stopped("s/t1")]);
    let (id, brief) = hub.resumable_subagent(&session, "s/t1").await.unwrap();
    let v = hub.resume_subagent(&session, id, brief, by_person()).await.unwrap();
    assert_eq!(v["kind"], "subagent", "{v}");
    let mut sent = prompts(&hub, &session);
    for _ in 0..50 {
        if !sent.is_empty() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
        sent = prompts(&hub, &session);
    }
    assert_eq!(sent.len(), 1, "{sent:?}");
    let provenance = &sent[0]["_meta"]["provenance"];
    assert_eq!(provenance["kind"], PROVENANCE_KIND, "{provenance}");
    assert_eq!(provenance["subagentId"], "s/t1", "{provenance}");
    let said = sent[0].to_string();
    assert!(said.contains("Fix CI"), "the brief: {said}");
    assert!(said.contains("[acpmux-resume:s/t1]"), "the marker: {said}");

    // The chat's agent starts it again: a new Agent call with the seeded prompt.
    let seeded = format!("Fix CI\n\n## Continuing an earlier run\n...{}", marker("s/t1"));
    hub.observe_resumable(&session, &[spawned("s/t9", &seeded)]);
    let new = last_entry(&hub, &session, "s/t9").unwrap();
    assert_eq!((&new["state"], &new["resumes"]), (&json!("running"), &json!("s/t1")));
    let old = last_entry(&hub, &session, "s/t1").unwrap();
    assert_eq!(
        (&old["state"], &old["resumedBy"], &old["resumable"]),
        (&json!("running"), &json!("s/t9"), &json!(false))
    );
    assert!(hub.resumable_subagent(&session, "s/t1").await.is_none(), "resumed once");

    // It finishes: Claude Code's task_notification `completed` on the new run reaches the parent,
    // and the old row ends with it.
    let done = json!({"id": "s/t9", "parent": null, "state": "completed", "agentId": "a9"});
    hub.observe_resumable(&session, &[done]);
    let old = last_entry(&hub, &session, "s/t1").unwrap();
    assert_eq!((&old["state"], &old["resumedBy"]), (&json!("completed"), &json!("s/t9")));
}

/// A second Resume while the first one's prompt is out (another surface, another device) is
/// refused busy: one prompt, one new run. A resume of a resumed run links to the run it resumes.
#[tokio::test]
async fn a_second_resume_while_one_is_out_is_refused_busy() {
    let (hub, session, _conn) = chat().await;
    hub.observe_resumable(&session, &[spawned("s/t1", "Fix CI")]);
    hub.observe_resumable(&session, &[stopped("s/t1")]);
    let (id, brief) = hub.resumable_subagent(&session, "s/t1").await.unwrap();
    // Two at once: the first one out holds the helper until its turn ends.
    let (a, b) = tokio::join!(
        hub.resume_subagent(&session, id.clone(), brief.clone(), by_person()),
        hub.resume_subagent(&session, id, brief, by_person()),
    );
    let busy = |r: &Result<Value, RpcError>| {
        r.as_ref().err().and_then(|e| e.data.as_ref()).map(|d| d["reason"].clone())
            == Some(json!("retry.busy"))
    };
    assert!(a.is_ok() != b.is_ok() && (busy(&a) || busy(&b)), "{a:?} {b:?}");
    let mut sent = prompts(&hub, &session);
    for _ in 0..50 {
        if !sent.is_empty() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
        sent = prompts(&hub, &session);
    }
    assert_eq!(sent.len(), 1, "one prompt: {sent:?}");
    // A brief that already carries an older run's marker names the newest one last.
    let seeded =
        format!("Fix CI\n{}\n## Continuing an earlier run\n{}", marker("s/t0"), marker("s/t1"));
    assert_eq!(marked(&seeded), Some("s/t1"));
}

#[tokio::test]
async fn a_brief_is_read_from_the_log_after_a_restart() {
    let (hub, session, _conn) = chat().await;
    let update = |e: Value| {
        json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session.id,
            "update": {"sessionUpdate": "subagent_spawned"}, "_meta": {"acpmux": {"subagents": [e]}}}})
    };
    hub.append(&session, "in", "subagent_spawned", update(spawned("s/t1", "Fix CI")));
    hub.append(&session, "in", "subagent_state_update", update(stopped("s/t1")));
    // Nothing in memory: a restarted daemon.
    hub.forget_resumable(&session);
    let (id, brief) = hub.resumable_subagent(&session, "s/t1").await.expect("from the log");
    assert_eq!((id.as_str(), brief.prompt.as_deref()), ("s/t1", Some("Fix CI")));
    assert_eq!(brief.state, "cancelled");
}
