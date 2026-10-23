//! Queued prompts across daemon restarts: what a restore puts back runs once.

use super::*;

/// A config whose `slow` launcher check (`config/launchers.rs`) waits until `<home>/go` exists:
/// the daemon's startup, and so the run of every prompt it restored (`resume_queues`), waits
/// for the test. A check a killed daemon left behind ends once the test removes its home.
fn hold_startup(daemon: &Daemon) {
    let script = daemon.home.join("hold-startup.sh");
    let go = daemon.home.join("go");
    std::fs::write(
        &script,
        format!(
            "#!/bin/sh\ni=0\nwhile [ ! -e '{}' ] && [ -d '{}' ] && [ $i -lt 1200 ]; do sleep 0.05; i=$((i+1)); done\necho 'slow 1.0'\n",
            go.display(),
            daemon.home.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&script, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    std::fs::write(
        daemon.home.join("config.json"),
        json!({"harnesses": {"fake": {"argv": ["python3", FAKE]}, "slow": {"argv": [script, "claude", "proxy"]}}, "defaultHarness": "fake", "permissionPolicy": "approve-all"}).to_string(),
    )
    .unwrap();
}

/// A dequeued prompt whose turn never started comes back after a crash (`lost_start.rs`); edited
/// and moved there before it ran, it keeps that edit and place across a second crash, and still
/// runs once, with its image. The restarted daemons' startup waits (`hold_startup`), so the
/// restored prompts wait too.
#[tokio::test]
async fn a_restored_dequeued_prompt_keeps_its_edits_across_a_second_crash() {
    let seam = [("ACPMUX_TEST_EXIT_AFTER_DEQUEUE", "1")];
    let mut daemon = Daemon::with_env("qdeq2", "approve-all", &seam);
    let (session, gate, mut client) = gated_turn_without_host(&daemon).await;
    let image =
        json!({"type": "image", "mimeType": "image/png", "data": "iVBORw==", "name": "shot.png"});
    let prompts = [
        ("q-1", json!([{"type": "text", "text": "first text"}, image])),
        ("q-2", json!([{"type": "text", "text": "second text"}])),
    ];
    for (id, prompt) in prompts {
        client
            .send(
                "session/prompt",
                json!({"sessionId": session, "prompt": prompt, "_meta": {"acpmux": {"promptId": id}}}),
            )
            .await;
        daemon.wait_event(&session, "queued record", |e| {
            e["kind"] == "queued" && e["msg"]["promptId"] == id
        });
    }
    // The gated turn ends, q-1 leaves the queue for its turn, and the daemon stops there.
    std::fs::write(&gate, b"go").unwrap();
    daemon.wait_exit();
    drop(client);
    let of = |events: &[Value], kind: &str, id: &str| {
        events.iter().filter(|e| e["kind"] == kind && e["msg"]["promptId"] == id).count()
    };
    let events = daemon.events(&session);
    assert_eq!(of(&events, "dequeued", "q-1"), 1, "q-1 never left the queue: {events:#?}");
    assert_eq!(of(&events, "turn_started", "q-1"), 0, "q-1's turn started before the stop");

    // The second daemon puts q-1 back first; it is edited and moved behind q-2 before it runs.
    daemon.env.clear();
    hold_startup(&daemon);
    daemon.start();
    let mut rpc = daemon.rpc().await;
    let attached = rpc.call("_acpmux/attach", json!({"sessionId": session, "limit": 0})).await;
    let ids = |attached: &Value| -> Vec<String> {
        let queue = attached["session"]["queue"].as_array().expect("queue in the attach reply");
        queue.iter().filter_map(|q| q["promptId"].as_str().map(str::to_owned)).collect()
    };
    assert_eq!(ids(&attached), ["q-1", "q-2"], "the first restart lost the queue: {attached:#}");
    let edit = |op: &str, extra: Value| {
        let mut p = json!({"sessionId": session, "promptId": "q-1", "op": op});
        p.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
        p
    };
    let updated =
        rpc.call("_acpmux/queue_edit", edit("update", json!({"text": "first edited"}))).await;
    assert_eq!(updated["ok"], true, "{updated}");
    let moved = rpc.call("_acpmux/queue_edit", edit("move", json!({"index": 1}))).await;
    assert_eq!(moved["ok"], true, "{moved}");
    let events = daemon.events(&session);
    assert_eq!(of(&events, "turn_started", "q-1"), 0, "q-1 started on the second daemon");
    assert_eq!(of(&events, "turn_started", "q-2"), 0, "q-2 started on the second daemon");

    // A second crash before either runs: the third daemon has the edit and the order.
    daemon.sigkill();
    drop(rpc);
    daemon.start();
    let mut rpc = daemon.rpc().await;
    let attached = rpc.call("_acpmux/attach", json!({"sessionId": session, "limit": 0})).await;
    assert_eq!(ids(&attached), ["q-2", "q-1"], "the second restart lost the order: {attached:#}");
    let queue = attached["session"]["queue"].as_array().unwrap();
    assert_eq!(
        queue[1]["prompt"], "first edited",
        "the second restart lost the edit: {attached:#}"
    );
    // A client that resends q-1 waits for its one run.
    let mut resend = daemon.rpc().await;
    let resent = resend
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "first text"}], "_meta": {"acpmux": {"promptId": "q-1", "resend": true}}}),
        )
        .await;
    std::fs::write(daemon.home.join("go"), b"").unwrap();
    let reply = loop {
        let line = tokio::time::timeout(Duration::from_secs(30), resend.lines.next_line())
            .await
            .expect("the resent prompt answered in time")
            .unwrap()
            .expect("daemon closed the socket");
        let v: Value = serde_json::from_str(&line).unwrap();
        if v.get("id") == Some(&json!(resent)) {
            break v;
        }
    };
    assert_eq!(reply["result"]["stopReason"], "end_turn", "q-1 never ran: {reply:#}");
    let edited = |e: &Value| {
        e["msg"]["params"]["update"]["sessionUpdate"] == "agent_message_chunk"
            && e["msg"]["params"]["update"]["content"]["text"]
                .as_str()
                .is_some_and(|t| t.starts_with("echo: first edited"))
    };
    let ran = daemon.wait_event(&session, "the edited prompt's answer", edited);
    let text = ran["msg"]["params"]["update"]["content"]["text"].as_str().unwrap_or_default();
    assert!(text.contains(" image:"), "the edit dropped q-1's image: {text}");
    let events = daemon.events(&session);
    let order: Vec<&str> = events
        .iter()
        .filter(|e| e["kind"] == "turn_started")
        .filter_map(|e| e["msg"]["promptId"].as_str())
        .filter(|id| id.starts_with("q-"))
        .collect();
    assert_eq!(order, ["q-2", "q-1"], "the queued prompts ran out of order or twice");
    assert_eq!(events.iter().filter(|e| edited(e)).count(), 1, "q-1 ran more than once");
    let old = |e: &Value| {
        e["msg"]["params"]["update"]["content"]["text"]
            .as_str()
            .is_some_and(|t| t.starts_with("echo: first text"))
    };
    assert_eq!(
        events.iter().filter(|e| old(e)).count(),
        0,
        "q-1 ran its text from before the edit"
    );
}

/// A prompt the first daemon left queued, sent again with its id to a daemon whose log load
/// failed (`ACPMUX_TEST_PANIC_IN_LOAD_LOGS`: it restored no queue and knew no prompt id), ran
/// there under a new turn id. The next daemon's restore (`queue.rs` `restore_queue`) dropped
/// only what settled the old turn id, so it put the old `queued` copy back and the prompt ran a
/// second time (#23118 review). The third daemon's startup waits (`hold_startup`), so a restored
/// copy waits in the queue for the test to see.
#[tokio::test]
async fn a_queued_prompt_sent_again_after_a_failed_log_load_runs_once() {
    let mut daemon = Daemon::new("qonce", "approve-all");
    let (session, _gate, mut client) = gated_turn_without_host(&daemon).await;
    let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": "run me once"}],
                        "_meta": {"acpmux": {"promptId": "q-once"}}});
    client.send("session/prompt", prompt.clone()).await;
    let queued = daemon.wait_event(&session, "queued record", |e| {
        e["kind"] == "queued" && e["msg"]["promptId"] == "q-once"
    });
    let first_turn = queued["msg"]["turnId"].clone();
    daemon.sigkill();
    drop(client);

    // The second daemon's log load fails: the client sends the prompt again and it runs.
    daemon.env = vec![("ACPMUX_TEST_PANIC_IN_LOAD_LOGS".into(), "1".into())];
    daemon.start();
    let mut rpc = daemon.rpc().await;
    let answered = rpc.call("session/prompt", prompt).await;
    assert_eq!(answered["stopReason"], "end_turn", "the prompt did not run: {answered:#}");
    let run_turn = answered["_meta"]["acpmux"]["turnId"].clone();
    assert!(run_turn.is_string() && run_turn != first_turn, "not a new turn: {answered:#}");
    daemon.sigterm();
    drop(rpc);

    // The third daemon reads the logs.
    daemon.env.clear();
    hold_startup(&daemon);
    daemon.start();
    let mut rpc = daemon.rpc().await;
    let attached = rpc.call("_acpmux/attach", json!({"sessionId": session, "limit": 0})).await;
    let queue = attached["session"]["queue"].as_array().expect("queue in the attach reply");
    let restored = queue.iter().any(|q| q["promptId"] == "q-once");
    std::fs::write(daemon.home.join("go"), b"").unwrap();
    let run_of = |e: &Value| e["kind"] == "user_message" && e["msg"]["promptId"] == "q-once";
    if restored {
        let again = daemon.wait_event(&session, "the restored copy's run", |e| {
            run_of(e) && e["msg"]["turnId"] != run_turn
        });
        panic!(
            "q-once ran a second time, as turn {} (it ran as {run_turn}; queued as {first_turn}): {again:#}",
            again["msg"]["turnId"]
        );
    }
    // A prompt sent now runs after anything the restore put back.
    let after =
        json!({"sessionId": session, "prompt": [{"type": "text", "text": "after the restore"}]});
    let answered = rpc.call("session/prompt", after).await;
    assert_eq!(answered["stopReason"], "end_turn", "{answered:#}");
    let events = daemon.events(&session);
    let runs: Vec<&Value> = events.iter().filter(|e| run_of(e)).collect();
    assert_eq!(runs.len(), 1, "q-once did not run exactly once: {runs:#?}");
}
