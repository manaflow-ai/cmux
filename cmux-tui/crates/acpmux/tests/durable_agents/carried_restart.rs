//! A restart while Claude Code runs a turn on a steer it read after its last turn ended
//! (`hub/carried_turn.rs`): that turn's prompt is the hub's own and had not gone out when the
//! daemon stopped. The next daemon must run that turn on, not record it as never received
//! (Leo, 2026-10-29: "you clearly just ended some fucking turns, and it still fucking shows
//! this.").

use super::*;

fn turns(daemon: &Daemon, session: &str, kind: &str) -> Vec<Value> {
    let events = daemon.events(session);
    events.into_iter().filter(|e| e["dir"] == "mux" && e["kind"] == kind).collect()
}

#[tokio::test]
async fn a_carried_turn_cut_by_a_restart_before_its_prompt_goes_on() {
    let mut daemon = Daemon::claude_router("carry-up", &[]);
    // This daemon holds a carried turn before its prompt goes out; the next one does not.
    daemon.sigterm();
    daemon.env.push(("ACPMUX_TEST_CARRY_HOLD_MS".into(), "60000".into()));
    daemon.start();
    let session = new_session(&daemon).await;
    let gate = daemon.home.join("carry-gate");
    let open = |n: u32, how: &str| {
        let tmp = gate.with_extension(format!("{n}.tmp"));
        std::fs::write(&tmp, how).unwrap();
        std::fs::rename(&tmp, format!("{}.{n}", gate.display())).unwrap();
    };
    let mut client = daemon.rpc().await;
    let text = format!("gated: {}", gate.display());
    client
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]}),
        )
        .await;
    daemon.wait_event(&session, "the first turn's words", |e| chunk(e, "gated turn 1"));
    let mut steerer = daemon.rpc().await;
    steerer
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "LATE-1"}], "_meta": {"acpmux": {"steer": true, "promptId": "p-late"}}}),
        )
        .await;
    daemon.wait_event(&session, "the steer on Claude's stdin", |e| {
        e["kind"] == "claude.stdin" && e["msg"].to_string().contains("LATE-1")
    });
    // Claude Code ends its turn with the steer unread, and runs it as its next.
    open(1, "end");
    daemon.wait_event(&session, "the carried turn's start", |e| {
        e["kind"] == "turn_started" && !e["msg"]["carried"].is_null()
    });
    let harness_pid = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();

    daemon.sigkill();
    drop((client, steerer));
    daemon.env.clear();
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    assert!(alive(harness_pid), "the agent died with the restart");
    until_turn_restored(&daemon, &session).await;
    open(2, "read");
    let started = turns(&daemon, &session, "turn_started");
    assert_eq!(started.len(), 2, "{started:#?}");
    let carried = started[1]["msg"]["turnId"].clone();
    let deadline = Instant::now() + Duration::from_secs(30);
    let ended = loop {
        let ended = turns(&daemon, &session, "turn_result");
        if ended.iter().any(|e| e["msg"]["turnId"] == carried) || Instant::now() > deadline {
            break ended;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    };
    let result = ended.iter().find(|e| e["msg"]["turnId"] == carried);
    let result = result.unwrap_or_else(|| panic!("the carried turn never ended: {ended:#?}"));
    assert_eq!(result["msg"]["status"], "completed", "{result}");
    assert_eq!(ended[0]["msg"]["carriedTo"]["turnId"], carried, "{:#?}", ended[0]);
    let unknown = daemon.events(&session).into_iter().find(|e| {
        e["msg"].to_string().contains("the agent host never received this turn's prompt")
    });
    assert!(unknown.is_none(), "recorded as never received: {unknown:#?}");
    // What Claude said in it is the carried turn's.
    let said = daemon.events(&session).into_iter().find(|e| chunk(e, "read: LATE-1"));
    let said = said.expect("Claude's words in the carried turn")["seq"].as_u64().unwrap();
    assert!(said > started[1]["seq"].as_u64().unwrap() && said < result["seq"].as_u64().unwrap());
}
