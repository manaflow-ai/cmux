//! A daemon restart tells the resumed agent which tool calls were still in flight.
use super::*;

#[tokio::test]
async fn restart_resume_prompt_lists_an_unfinished_tool_call() {
    let mut daemon = Daemon::new("restart-resume-tools", "approve-all");
    let session = new_session(&daemon).await;
    let gate = daemon.home.join("tool-gate");
    make_fifo(&gate);
    let mut rpc = daemon.rpc().await;
    rpc.send(
        "session/prompt",
        json!({
            "sessionId": session,
            "prompt": [{"type": "text", "text": format!("parallel-tools: {}", gate.display())}],
            "_meta": {"acpmux": {"promptId": "restart-tool-prompt"}}
        }),
    )
    .await;
    daemon.wait_event(&session, "unfinished tool call", |e| {
        e["kind"] == "tool_call" && e["msg"]["params"]["update"]["toolCallId"] == "slow-1"
    });
    let host = daemon.host_record(&session);
    let host_pid = host["host_pid"].as_i64().expect("host pid");
    let harness_pid = host["harness_pid"].as_i64().expect("harness pid");

    daemon.sigkill();
    drop(rpc);
    // Simulate the agent host dying with the daemon, so the next daemon settles the open turn.
    for pid in [host_pid, harness_pid] {
        // SAFETY: these are process groups this test's daemon created.
        unsafe { libc::killpg(pid as i32, libc::SIGKILL) };
    }
    daemon.start();

    let queued = daemon.wait_event(&session, "restart resume prompt", |e| {
        e["kind"] == "queued"
            && e["msg"]["promptId"] == "restart-tool-prompt~resume-1"
            && e["msg"]["text"]
                .as_str()
                .is_some_and(|text| text.contains("curl -H 'Authorization: Bearer fake-secret'"))
    });
    assert!(queued["msg"]["text"].as_str().unwrap().contains("slow-1"), "{queued}");
}
