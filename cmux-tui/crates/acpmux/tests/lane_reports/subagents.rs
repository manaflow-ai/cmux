//! A lane's turn that a Claude Code subagent of its parent asked for (W5-M, 2026-11-08). A
//! subagent runs in its lead's process with the lead's caller token, so every one of its
//! `acpmux run` and `acpmux send` calls proves the lead's session; only the Bash hook's mark
//! (`callerSubagent`) says which of its agents sent it. Seen three times on 2026-11-08: a
//! subagent's reviewer answered into the lead's chat, the lead got a lane report of each review
//! turn, and the reviewer said it "sent the review to claude-17".
//!
//! - A reply the sender's CLI waited for and printed (`readsReply`) is read: no lane report of
//!   that turn goes into the lead's chat as well.
//! - The lane reads the subagent, not its lead, as the sender of the prompt.
//! - The report of a turn the subagent asked for without waiting goes to that subagent while it
//!   runs (the Bash hook hands it over after its next shell command, or as it stops), and to the
//!   lead, labeled with the subagent, once it has ended.
use super::*;

const SUB: &str = "a0a68e7af3df5967e";
const WAIT: Duration = Duration::from_secs(20);

/// The parent's prompt to `lane` as its general-purpose subagent's `acpmux` call makes it;
/// `reads`: the CLI waits for the reply and prints it (`send --wait`, `run`).
fn subagent_prompt(lane: &str, text: &str, reads: bool) -> Value {
    let mut mux = json!({"callerSubagent": {"id": SUB, "type": "general-purpose"}});
    if reads {
        mux.as_object_mut().unwrap().insert("readsReply".into(), json!(true));
    }
    json!({"sessionId": lane, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": mux}})
}

/// What acpmux's Claude Code hook (`acpmux __bg-hook HOME`, the session plugin's hooks.json)
/// prints for `input`, run as Claude Code runs it in session `session`.
fn hook(session: &str, input: Value) -> Option<Value> {
    use std::io::Write;
    let scratch = std::env::temp_dir().join(format!("w5m-hook-{}", std::process::id()));
    std::fs::create_dir_all(&scratch).unwrap();
    let home = acpmux::config::home();
    let mut child = daemon_env::acpmux(&scratch)
        .arg("__bg-hook")
        .arg(&home)
        .env("ACPMUX_SESSION_ID", session)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(input.to_string().as_bytes()).unwrap();
    let out = child.wait_with_output().unwrap();
    assert!(out.status.success(), "{out:?}");
    let text = String::from_utf8(out.stdout).unwrap();
    let text = text.trim();
    (!text.is_empty()).then(|| serde_json::from_str(text).unwrap())
}

/// The subagent's Bash call ended (`PostToolUse`).
fn after_bash(session: &str) -> Option<Value> {
    hook(
        session,
        json!({"hook_event_name": "PostToolUse", "tool_name": "Bash", "agent_id": SUB,
               "agent_type": "general-purpose", "cwd": std::env::temp_dir(),
               "tool_input": {"command": "ls"}, "tool_response": {"stdout": ""}}),
    )
}

/// The subagent stops (`SubagentStop`).
fn subagent_stops(session: &str) -> Option<Value> {
    hook(
        session,
        json!({"hook_event_name": "SubagentStop", "agent_id": SUB,
               "agent_type": "general-purpose", "stop_hook_active": false}),
    )
}

/// A FIFO whose first write lets the parent's `child-gate:` turn (and its subagent) end.
pub(super) fn fifo(name: &str) -> std::path::PathBuf {
    let path = std::env::temp_dir().join(format!("w5m-{name}-{}", std::process::id()));
    let _ = std::fs::remove_file(&path);
    let c = std::ffi::CString::new(path.to_str().unwrap()).unwrap();
    // SAFETY: a NUL-terminated path this function owns.
    assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
    path
}

/// The parent runs a turn with one subagent running in it (fake_agent.py `child-gate:`).
pub(super) async fn parent_with_a_running_subagent(
    hub: &Arc<Hub>,
    person: &mut Client,
    gate: &Path,
) -> String {
    let parent = person.new_session("parent", json!({})).await;
    person
        .send(
            "session/prompt",
            json!({"sessionId": parent,
                   "prompt": [{"type": "text", "text": format!("child-gate: {}", gate.display())}]}),
        )
        .await;
    let s = hub.resolve(&parent).unwrap();
    tokio::time::timeout(WAIT, async {
        while hub.session_summary(&s)["subagentsRunning"] != 1 {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("the parent's subagent runs");
    parent
}

/// The lane reports of turns in `parent`'s queue, not run yet (its turn is running).
pub(super) async fn queued_reports(person: &mut Client, parent: &str) -> Vec<Value> {
    let page = person.ok("_acpmux/events", json!({"sessionId": parent, "limit": 5000})).await;
    page["events"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|e| {
            e["kind"] == "queued" && e["msg"]["_meta"]["provenance"]["kind"] == "lane_report"
        })
        .map(|e| e["msg"].clone())
        .collect()
}

/// The text of a queued record.
fn queued_text(msg: &Value) -> String {
    msg["_meta"]["_acpmuxMessage"]["message"]["text"].as_str().unwrap_or_default().to_owned()
}

/// Waits until `lane`'s turn `turn` ended.
pub(super) async fn turn_ended(hub: &Arc<Hub>, lane: &str, turn: u64) {
    let s = hub.resolve(lane).unwrap();
    tokio::time::timeout(WAIT, async {
        loop {
            let summary = hub.session_summary(&s);
            // `turnCount` counts a turn once it started; `turn` null once it ended.
            let started = summary["turnCount"].as_u64();
            if started >= Some(turn) && summary["turn"].is_null() && summary["status"] != "running"
            {
                return;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("the lane's turn ended");
}

#[tokio::test]
async fn lane_report_subagent_a_reply_its_waiting_send_printed_is_not_reported_again() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let parent = person.new_session("parent", json!({})).await;
    let mut sub = Client::as_session(&hub, &parent).await;
    let lane = sub.new_session("waited-lane", json!({})).await;
    // `acpmux run` / `send --wait` from the subagent: the reply comes back on this call.
    sub.ok("session/prompt", subagent_prompt(&lane, "review this", true)).await;
    person.exactly(&parent, 0).await;
    // So does the lead's own waiting send that prints the reply.
    let mut lead = Client::as_session(&hub, &parent).await;
    let mut own = subagent_prompt(&lane, "and this", true);
    own["_meta"]["acpmux"].as_object_mut().unwrap().remove("callerSubagent");
    lead.ok("session/prompt", own).await;
    person.exactly(&parent, 0).await;
}

#[tokio::test]
async fn lane_report_subagent_a_reply_whose_caller_left_before_it_came_is_reported() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let parent = person.new_session("parent", json!({})).await;
    let lane = Client::as_session(&hub, &parent).await.new_session("left-lane", json!({})).await;
    let mut gone = Client::as_session(&hub, &parent).await;
    gone.send("session/prompt", subagent_prompt(&lane, "until-cancel", true)).await;
    person
        .ok("_acpmux/wait", json!({"sessions": [lane], "until": ["running"], "timeoutMs": 5000}))
        .await;
    // The CLI timed out or was killed: its connection closed before the turn ended.
    drop(gone);
    tokio::time::sleep(Duration::from_millis(200)).await;
    person.ok("session/cancel", json!({"sessionId": lane})).await;
    person.exactly(&parent, 1).await;
}

#[tokio::test]
async fn lane_report_subagent_the_lane_reads_the_subagent_as_its_sender() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let parent = person.new_session("parent", json!({})).await;
    let mut sub = Client::as_session(&hub, &parent).await;
    let lane = sub.new_session("named-lane", json!({})).await;
    sub.ok("session/prompt", subagent_prompt(&lane, "who sent this?", true)).await;
    let page = person.ok("_acpmux/events", json!({"sessionId": lane, "limit": 5000})).await;
    let sent: Vec<String> = page["events"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|e| e["dir"] == "out" && e["kind"] == "session/prompt")
        .map(|e| e["msg"]["params"]["prompt"].to_string())
        .collect();
    assert_eq!(sent.len(), 1, "{sent:#?}");
    let prompt = &sent[0];
    assert!(prompt.contains("parent's general-purpose subagent a0a68e7a"), "{prompt}");
    assert!(prompt.contains("Do not send it to parent"), "{prompt}");
}

#[tokio::test]
async fn lane_report_subagent_a_no_wait_report_goes_to_the_live_subagent_then_to_the_lead() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let gate = fifo("live");
    let parent = parent_with_a_running_subagent(&hub, &mut person, &gate).await;
    let mut sub = Client::as_session(&hub, &parent).await;
    let lane = sub.new_session("bg-lane", json!({})).await;

    // `acpmux send --no-wait` (or `new` with a prompt) from the subagent: nobody reads the reply.
    sub.send("session/prompt", subagent_prompt(&lane, "first finding", false)).await;
    turn_ended(&hub, &lane, 1).await;
    // The subagent gets it after its next shell command.
    let deadline = Instant::now() + WAIT;
    let handed = loop {
        if let Some(out) = after_bash(&parent) {
            break out;
        }
        assert!(Instant::now() < deadline, "no notice for the subagent");
        tokio::time::sleep(Duration::from_millis(100)).await;
    };
    let out = &handed["hookSpecificOutput"];
    assert_eq!(out["hookEventName"], "PostToolUse", "{handed}");
    let context = out["additionalContext"].as_str().unwrap();
    assert!(context.contains("[bg-lane]") && context.contains("echo: first finding"), "{context}");
    assert_eq!(after_bash(&parent), None, "handed over once");
    assert!(queued_reports(&mut person, &parent).await.is_empty(), "the lead got none");

    // The subagent ends: a later report goes to the lead, labeled with it.
    assert_eq!(subagent_stops(&parent), None, "nothing waits for it");
    sub.send("session/prompt", subagent_prompt(&lane, "second finding", false)).await;
    let deadline = Instant::now() + WAIT;
    let queued = loop {
        let got = queued_reports(&mut person, &parent).await;
        if !got.is_empty() {
            break got;
        }
        assert!(Instant::now() < deadline, "no report reached the lead");
        tokio::time::sleep(Duration::from_millis(50)).await;
    };
    assert_eq!(queued.len(), 1, "{queued:#?}");
    let t = queued_text(&queued[0]);
    assert!(t.contains("echo: second finding"), "{t}");
    assert!(t.contains("general-purpose subagent a0a68e7a") && t.contains("has ended"), "{t}");
    let p = &queued[0]["_meta"]["provenance"];
    assert_eq!(p["forSubagent"], json!({"id": SUB, "type": "general-purpose"}), "{p}");
    std::fs::write(&gate, "go").unwrap();
    person.until(&parent, 1).await;
}

#[tokio::test]
async fn lane_report_subagent_a_report_the_subagent_never_took_goes_to_the_lead_when_it_ends() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let gate = fifo("sweep");
    let parent = parent_with_a_running_subagent(&hub, &mut person, &gate).await;
    let mut sub = Client::as_session(&hub, &parent).await;
    let lane = sub.new_session("swept-lane", json!({})).await;
    sub.send("session/prompt", subagent_prompt(&lane, "third finding", false)).await;
    turn_ended(&hub, &lane, 1).await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(queued_reports(&mut person, &parent).await.is_empty(), "it waits for the subagent");
    // The subagent ends with no stop hook (its harness was killed, say): the lead gets it.
    std::fs::write(&gate, "go").unwrap();
    let got = person.until(&parent, 1).await;
    let t = text(&got[0]);
    assert!(t.contains("echo: third finding"), "{t}");
    assert!(t.contains("general-purpose subagent a0a68e7a") && t.contains("has ended"), "{t}");
}
