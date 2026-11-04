//! An update mid-tool-call (Leo, 2026-10-22: "The tests: a session mid-tool-call survives an
//! update and continues, with a queued prompt delivered exactly once."). The agent host outlives
//! the daemon an update stops; the next daemon adopts it, the tool call finishes and its turn
//! completes, and the prompt queued behind it runs once, though its client sends it again on
//! reconnect.

use super::*;

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_tool_call_cut_by_an_update_continues_and_its_queued_prompt_runs_once() {
    let mut daemon = Daemon::new("upd-tool", "approve-all");
    let session = new_session(&daemon).await;
    let gate = daemon.home.join("tool-gate");
    make_fifo(&gate);
    let mut client = daemon.rpc().await;
    client
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": format!("work-gate: {}", gate.display())}], "_meta": {"acpmux": {"promptId": "tool-1"}}}),
        )
        .await;
    daemon.wait_event(&session, "the running tool call", |e| e["kind"] == "tool_call");
    let queued = json!({"sessionId": session, "prompt": [{"type": "text", "text": "queued behind the tool"}],
                        "_meta": {"acpmux": {"promptId": "q-1"}}});
    client.send("session/prompt", queued.clone()).await;
    daemon.wait_event(&session, "queued record", |e| {
        e["kind"] == "queued" && e["msg"]["promptId"] == "q-1"
    });
    let harness_pid = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();

    // The update stops the daemon mid-tool-call; the agent keeps running its tool.
    daemon.sigterm();
    drop(client);
    assert!(alive(harness_pid), "the agent died with the daemon the update stopped");

    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    // The client reconnects and sends its queued prompt again, as the CLI does after a drop.
    let mut resender = daemon.rpc().await;
    let mut resent = queued;
    resent["_meta"]["acpmux"]["resend"] = json!(true);
    let resend = tokio::spawn(async move { resender.reply("session/prompt", resent).await });
    until_turn_restored(&daemon, &session).await;

    // The tool finishes on the adopted agent: its turn completes, then the queued prompt runs.
    std::fs::write(&gate, b"go").unwrap();
    daemon.wait_event(&session, "the queued prompt's answer", |e| {
        chunk(e, "echo: queued behind the tool")
    });
    let answered = tokio::time::timeout(Duration::from_secs(30), resend)
        .await
        .expect("the resent prompt was answered in time")
        .unwrap();
    assert!(answered.get("error").is_none(), "the resent prompt failed: {answered:#}");

    let events = daemon.events(&session);
    let count = |pred: &dyn Fn(&Value) -> bool| events.iter().filter(|e| pred(e)).count();
    let of =
        |kind: &str, id: &str| count(&|e: &Value| e["kind"] == kind && e["msg"]["promptId"] == id);
    assert!(alive(harness_pid), "a second agent replaced the adopted one");
    assert!(
        !events.iter().any(|e| e["msg"]["detail"] == "outcome_unknown"),
        "the update cut the turn instead of continuing it: {events:#?}"
    );
    assert!(
        !events.iter().any(|e| e["kind"] == "auto_resume_scheduled"),
        "the adopted turn was resumed as a new prompt instead of continuing: {events:#?}"
    );
    let tool_done = count(&|e: &Value| {
        e["kind"] == "tool_call_update"
            && e["msg"].pointer("/params/update/toolCallId") == Some(&json!("wg-1"))
            && e["msg"].pointer("/params/update/status") == Some(&json!("completed"))
    });
    assert_eq!(tool_done, 1, "the tool call did not finish once after the update: {events:#?}");
    assert_eq!(count(&|e: &Value| chunk(e, "worked")), 1, "the tool's turn did not continue once");
    let results: Vec<&Value> = events.iter().filter(|e| e["kind"] == "turn_result").collect();
    assert_eq!(
        results.len(),
        2,
        "not one result for the tool's turn and one for q-1: {results:#?}"
    );
    assert!(
        results.iter().all(|r| r["msg"]["status"] == "completed"),
        "a turn did not complete: {results:#?}"
    );
    assert_eq!(of("user_message", "tool-1"), 1, "the tool's prompt went out again");
    assert_eq!(of("user_message", "q-1"), 1, "q-1 was not delivered exactly once: {events:#?}");
    assert_eq!(of("turn_started", "q-1"), 1, "q-1 did not run exactly once: {events:#?}");
    assert_eq!(
        count(&|e: &Value| chunk(e, "echo: queued behind the tool")),
        1,
        "the agent got q-1 more than once"
    );
    let tool_end = events.iter().position(|e| chunk(e, "worked")).expect("the tool's turn ended");
    let q_start = events
        .iter()
        .position(|e| e["kind"] == "user_message" && e["msg"]["promptId"] == "q-1")
        .expect("q-1 went out");
    assert!(q_start > tool_end, "q-1 went out before the tool's turn ended: {events:#?}");
}
