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

/// A prompt dequeued for a turn that never started (`lost_start.rs`) waits through a daemon whose
/// log load failed (`ACPMUX_TEST_PANIC_IN_LOAD_LOGS`: it restored no queue) and ran another
/// prompt there. That turn's `turn_started` names another prompt and turn, so it did not start
/// this one; the next restore settled every lost prompt at any `turn_started`, dropped this one
/// and it never ran (#23125 review). The third daemon's startup waits (`hold_startup`), so the
/// restored prompt waits in the queue for the test to see.
#[tokio::test]
async fn a_lost_prompt_runs_once_after_another_turn_started_first() {
    let seam = [("ACPMUX_TEST_EXIT_AFTER_DEQUEUE", "1")];
    let mut daemon = Daemon::with_env("qlostrun", "approve-all", &seam);
    let (session, gate, mut client) = gated_turn_without_host(&daemon).await;
    client
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "lost text"}], "_meta": {"acpmux": {"promptId": "q-lost"}}}),
        )
        .await;
    daemon.wait_event(&session, "queued record", |e| {
        e["kind"] == "queued" && e["msg"]["promptId"] == "q-lost"
    });
    // The gated turn ends, q-lost leaves the queue for its turn, and the daemon stops there.
    std::fs::write(&gate, b"go").unwrap();
    daemon.wait_exit();
    drop(client);
    let of = |events: &[Value], kind: &str, id: &str| {
        events.iter().filter(|e| e["kind"] == kind && e["msg"]["promptId"] == id).count()
    };
    let events = daemon.events(&session);
    assert_eq!(of(&events, "dequeued", "q-lost"), 1, "q-lost never left the queue: {events:#?}");
    assert_eq!(of(&events, "turn_started", "q-lost"), 0, "q-lost's turn started before the stop");

    // The second daemon's log load fails: it knows no queue, and another prompt runs at once.
    daemon.env = vec![("ACPMUX_TEST_PANIC_IN_LOAD_LOGS".into(), "1".into())];
    daemon.start();
    let mut rpc = daemon.rpc().await;
    let other = json!({"sessionId": session, "prompt": [{"type": "text", "text": "another prompt"}],
                       "_meta": {"acpmux": {"promptId": "q-other"}}});
    let answered = rpc.call("session/prompt", other).await;
    assert_eq!(answered["stopReason"], "end_turn", "the other prompt did not run: {answered:#}");
    daemon.sigterm();
    drop(rpc);
    let events = daemon.events(&session);
    assert_eq!(of(&events, "turn_started", "q-other"), 1, "q-other's turn never started");
    assert_eq!(of(&events, "turn_started", "q-lost"), 0, "q-lost ran on the second daemon");

    // The third daemon reads the logs: q-lost is still waiting, and runs once.
    daemon.env.clear();
    hold_startup(&daemon);
    daemon.start();
    let mut rpc = daemon.rpc().await;
    let attached = rpc.call("_acpmux/attach", json!({"sessionId": session, "limit": 0})).await;
    let queue = attached["session"]["queue"].as_array().expect("queue in the attach reply");
    let ids: Vec<&str> = queue.iter().filter_map(|q| q["promptId"].as_str()).collect();
    assert_eq!(ids, ["q-lost"], "the restore dropped the lost prompt: {attached:#}");
    std::fs::write(daemon.home.join("go"), b"").unwrap();
    daemon.wait_event(&session, "q-lost's turn result", |e| {
        e["kind"] == "turn_result" && e["msg"]["promptId"] == "q-lost"
    });
    let events = daemon.events(&session);
    let answers = events
        .iter()
        .filter(|e| {
            e["msg"]["params"]["update"]["sessionUpdate"] == "agent_message_chunk"
                && e["msg"]["params"]["update"]["content"]["text"]
                    .as_str()
                    .is_some_and(|t| t.starts_with("echo: lost text"))
        })
        .count();
    assert_eq!(of(&events, "turn_started", "q-lost"), 1, "q-lost did not run exactly once");
    assert_eq!(answers, 1, "q-lost's answer came {answers} times");
}

/// How many prompts each long log below holds.
const LONG_LOG_PROMPTS: usize = 20_000;
/// How long its restore may take: the per-record scans of the waiting list, the reorder list
/// that grew by every prompt run and the prompts that left the queue for a turn that never
/// started (`queue.rs` `restore_queue`, `lost_start.rs`) made it quadratic.
const LONG_LOG_RESTORE_BOUND: Duration = Duration::from_secs(12);

/// A `queued` record of prompt `p-{i}` for turn `t-{i}`.
fn queued(i: usize, text: &str) -> Value {
    json!({"text": text, "client": "test", "position": i + 1, "promptId": format!("p-{i}"), "turnId": format!("t-{i}"),
           "prompt": [{"type": "text", "text": text}], "control": "local", "trustGate": false})
}

/// Appends the records `write` makes to a new session's log, as the daemons that ran them
/// would have, restarts the daemon and returns the prompt ids its restored queue holds and how
/// long the logs took to read and the queues to restore.
async fn restore_long_log(
    name: &str,
    write: impl FnOnce(&mut dyn FnMut(&str, Value)),
) -> (Vec<String>, Duration) {
    let mut daemon = Daemon::new(name, "approve-all");
    let session = new_session(&daemon).await;
    daemon.sigterm();
    let dir = daemon.home.join("sessions").join(&session).join("events");
    let mut segments: Vec<PathBuf> =
        std::fs::read_dir(&dir).unwrap().filter_map(|e| e.ok().map(|e| e.path())).collect();
    segments.sort();
    let segment = segments.last().expect("the new session's log segment").clone();
    let mut seq = daemon.events(&session).iter().filter_map(|e| e["seq"].as_u64()).max().unwrap();
    let at = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis()
        as u64;
    let mut lines = String::new();
    write(&mut |kind: &str, msg: Value| {
        seq += 1;
        lines.push_str(
            &json!({"seq": seq, "at": at, "dir": "mux", "kind": kind, "msg": msg}).to_string(),
        );
        lines.push('\n');
    });
    let mut file = std::fs::OpenOptions::new().append(true).open(&segment).unwrap();
    std::io::Write::write_all(&mut file, lines.as_bytes()).unwrap();
    drop(file);

    // The restored prompts wait for the test (`hold_startup`).
    hold_startup(&daemon);
    let started = Instant::now();
    daemon.start();
    let mut rpc = daemon.rpc().await;
    // `_acpmux/info` answers once the logs are read and the queues restored (`wait_logs`). Its
    // own deadline, not `Rpc::reply`'s 30 s a line: a slow restore fails on the bound, with its
    // time.
    let id = rpc.send("_acpmux/info", json!({"sessionId": session})).await;
    let info = tokio::time::timeout(Duration::from_secs(900), async {
        loop {
            let line = rpc.lines.next_line().await.unwrap().expect("daemon closed the socket");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v["result"].clone();
            }
        }
    })
    .await
    .expect("the logs were read within 900 s");
    let took = started.elapsed();
    eprintln!("{name}: restored in {took:?}");
    assert_eq!(info["logsLoading"], false, "{info:#}");
    let attached = rpc.call("_acpmux/attach", json!({"sessionId": session, "limit": 0})).await;
    let queue = attached["session"]["queue"].as_array().expect("queue in the attach reply");
    let ids = queue.iter().filter_map(|q| q["promptId"].as_str().map(str::to_owned)).collect();
    (ids, took)
}

/// A session log that queued 20,000 prompts behind a turn and then ran each (`queued`, then
/// `dequeued`, `user_message`, `turn_started` and `turn_result` for each: 100,000 queue records)
/// and left one more queued is read and its queue restored in time, with that one prompt in it.
#[tokio::test]
async fn a_long_queue_log_restores_in_time() {
    let (ids, took) = restore_long_log("qlong", |record| {
        for i in 0..LONG_LOG_PROMPTS {
            record("queued", queued(i, &format!("prompt {i}")));
        }
        for i in 0..LONG_LOG_PROMPTS {
            let (p, t) = (format!("p-{i}"), format!("t-{i}"));
            let left = LONG_LOG_PROMPTS - i - 1;
            record("dequeued", json!({"promptId": p, "turnId": t, "queued": left}));
            record(
                "user_message",
                json!({"text": format!("prompt {i}"), "client": "test", "promptId": p, "turnId": t}),
            );
            record(
                "turn_started",
                json!({"prompt": format!("prompt {i}"), "client": "test", "promptId": p, "turnId": t, "control": "local"}),
            );
            record("turn_result", json!({"promptId": p, "turnId": t, "stopReason": "end_turn"}));
        }
        record("queued", queued(LONG_LOG_PROMPTS, "the last one"));
    })
    .await;
    assert_eq!(
        ids,
        [format!("p-{LONG_LOG_PROMPTS}")],
        "the restore did not put back only the last prompt"
    );
    assert!(
        took < LONG_LOG_RESTORE_BOUND,
        "restoring the queue of a log of {} queued prompts took {took:?} (bound {LONG_LOG_RESTORE_BOUND:?})",
        LONG_LOG_PROMPTS + 1
    );
}

/// A session log in which 20,000 queued prompts each left the queue for a turn that never
/// started (`dequeued` with no `turn_started`: daemons that stopped first, `lost_start.rs`) is
/// read and its queue restored in time, with every one of them back at the head in the order
/// they left it.
#[tokio::test]
async fn a_long_log_of_unstarted_prompts_restores_in_time() {
    let (ids, took) = restore_long_log("qunstart", |record| {
        for i in 0..LONG_LOG_PROMPTS {
            record("queued", queued(i, &format!("prompt {i}")));
        }
        for i in 0..LONG_LOG_PROMPTS {
            let left = LONG_LOG_PROMPTS - i - 1;
            record(
                "dequeued",
                json!({"promptId": format!("p-{i}"), "turnId": format!("t-{i}"), "queued": left}),
            );
        }
    })
    .await;
    let want: Vec<String> = (0..LONG_LOG_PROMPTS).map(|i| format!("p-{i}")).collect();
    assert!(ids == want, "the restore did not put back every unstarted prompt in order");
    assert!(
        took < LONG_LOG_RESTORE_BOUND,
        "restoring the queue of a log of {LONG_LOG_PROMPTS} unstarted prompts took {took:?} (bound {LONG_LOG_RESTORE_BOUND:?})"
    );
}

/// Prompts that left the queue for turns that never started go back in the order the last
/// daemon's queue had them. Each went to the head as it left; one a daemon then held keeps the
/// place it had there, and a prompt that left after that goes ahead of it.
#[tokio::test]
async fn unstarted_prompts_a_daemon_held_keep_their_place_in_the_restored_queue() {
    let (ids, _) = restore_long_log("qheld", |record| {
        for i in 0..4 {
            record("queued", queued(i, &format!("prompt {i}")));
        }
        let dequeued = |i: usize| json!({"promptId": format!("p-{i}"), "turnId": format!("t-{i}")});
        record("dequeued", dequeued(0));
        record("dequeued", dequeued(1));
        record("queue_paused", json!({"held": ["p-0"]}));
        record("dequeued", dequeued(3));
    })
    .await;
    assert_eq!(ids, ["p-1", "p-3", "p-0", "p-2"], "the restored queue is out of order");

/// A person's queued prompt (chat multiplayer, `author.rs`) is still theirs after a crash: the
/// rebuilt queue keeps its `person_message` provenance, through that person's own edit, so only
/// they change it, and it runs as theirs. The restarted daemon's startup waits
/// (`hold_startup`), so the restored prompt waits for the test.
#[tokio::test]
async fn a_persons_queued_prompt_stays_theirs_across_a_crash() {
    let mut daemon = Daemon::new("qauthor", "approve-all");
    let (session, gate, client) = gated_turn_without_host(&daemon).await;
    let ana = json!({"id": "tailnet:ana@example.com", "name": "Ana", "login": "ana@example.com"});
    let mut rpc = daemon.rpc().await;
    rpc.send(
        "session/prompt",
        json!({"sessionId": session, "prompt": [{"type": "text", "text": "from ana"}],
               "_meta": {"acpmux": {"promptId": "q-ana", "author": ana}}}),
    )
    .await;
    daemon.wait_event(&session, "queued record", |e| {
        e["kind"] == "queued" && e["msg"]["promptId"] == "q-ana"
    });
    let edit = |author: Option<&Value>| {
        let mut p = json!({"sessionId": session, "promptId": "q-ana", "op": "update", "text": "ana's rewrite"});
        if let Some(author) = author {
            p["_meta"] = json!({"acpmux": {"author": author}});
        }
        p
    };
    let mut editor = daemon.rpc().await;
    let edited = editor.call("_acpmux/queue_edit", edit(Some(&ana))).await;
    assert_eq!(edited["ok"], true, "{edited}");
    daemon.sigkill();
    drop((client, rpc, editor));

    hold_startup(&daemon);
    daemon.start();
    let mut rpc = daemon.rpc().await;
    for other in [Some(json!({"id": "user_bo", "name": "Bo"})), None] {
        let refused = rpc.reply("_acpmux/queue_edit", edit(other.as_ref())).await;
        assert_eq!(
            refused.pointer("/error/data/reason"),
            Some(&json!("queue.not_author")),
            "the restart lost her name: {refused:#}"
        );
    }
    std::fs::write(daemon.home.join("go"), b"").unwrap();
    // The gated turn's agent did not outlive the daemon; one started again waits on the gate.
    let _ = std::fs::OpenOptions::new()
        .write(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(&gate)
        .and_then(|mut f| std::io::Write::write_all(&mut f, b"go"));
    let ran = daemon.wait_event(&session, "q-ana's run", |e| {
        e["kind"] == "user_message" && e["msg"]["promptId"] == "q-ana"
    });
    assert_eq!(ran["msg"]["text"], "ana's rewrite", "{ran:#}");
    let anas = json!({"kind": "person_message", "from": "tailnet:ana@example.com", "fromName": "Ana", "login": "ana@example.com"});
    assert_eq!(ran["msg"].pointer("/_meta/provenance"), Some(&anas), "{ran:#}");
}
