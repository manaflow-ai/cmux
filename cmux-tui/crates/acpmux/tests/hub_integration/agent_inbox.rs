//! Every chat's inbox (`hub/inbox.rs`): another agent's message never becomes a turn or a steer
//! of its own. It waits in a thread of the chat's inbox, and the agent hears of what is new as ONE
//! notice (`inbox_notice`), into its running turn at the next tool step or, for a message that may
//! wake it, as one turn of an idle chat. Leo, 2026-10-29: "im the only one that steers".

use super::*;

/// What `acpmux send --from AGENT` sends: another agent's message, steering by default.
fn from_agent(id: &str, prompt_id: &str, agent: &str, text: &str, mux: Value) -> Value {
    let mut meta = json!({"promptId": prompt_id, "fromAgent": agent, "steer": true});
    for (k, v) in mux.as_object().cloned().unwrap_or_default() {
        meta[k] = v;
    }
    json!({"sessionId": id, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": meta}})
}

/// A FIFO for the fake agent's gates.
fn fifo(tag: &str) -> std::path::PathBuf {
    let path = std::env::temp_dir().join(format!("acpmux-inbox-{tag}-{}", uuid::Uuid::now_v7()));
    assert!(std::process::Command::new("mkfifo").arg(&path).status().unwrap().success());
    path
}

/// Writes to FIFO `path` (a gate opens, or the agent takes its next tool step), within 20 s.
async fn open(path: &std::path::Path) {
    let path = path.to_owned();
    let write = tokio::task::spawn_blocking(move || std::fs::write(path, "go"));
    tokio::time::timeout(Duration::from_secs(20), write)
        .await
        .expect("the agent never read the FIFO")
        .unwrap()
        .unwrap();
}

/// The session's `user_message` records.
fn prompts(hub: &Arc<Hub>, id: &str) -> Vec<Value> {
    let records = hub.events(id, 0, 1_000_000).unwrap();
    records.into_iter().filter(|r| r.kind == "user_message").map(|r| r.msg).collect()
}

/// The `user_message` records of inbox notices.
fn notices(hub: &Arc<Hub>, id: &str) -> Vec<Value> {
    let kind = |m: &Value| m["_meta"]["provenance"]["kind"] == "inbox_notice";
    prompts(hub, id).into_iter().filter(kind).collect()
}

/// The prompt ids a notice carries, in its threads' order.
fn carried(notice: &Value) -> Vec<String> {
    let threads = notice["_meta"]["provenance"]["threads"].as_array().cloned().unwrap_or_default();
    threads
        .iter()
        .flat_map(|t| t["promptIds"].as_array().cloned().unwrap_or_default())
        .filter_map(|v| v.as_str().map(str::to_owned))
        .collect()
}

/// Waits until `done` holds of the session's records, within 20 s.
async fn until(hub: &Arc<Hub>, id: &str, what: &str, done: impl Fn(&[Value]) -> bool) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while !done(&prompts(hub, id)) {
        assert!(tokio::time::Instant::now() < deadline, "never: {what}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

/// Reads responses until those of `ids` came, within 20 s.
async fn answers(c: &mut TestClient, ids: &[i64]) -> BTreeMap<i64, Value> {
    let mut got = BTreeMap::new();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while ids.iter().any(|id| !got.contains_key(id)) {
        let line = tokio::time::timeout_at(deadline, c.rx.recv())
            .await
            .unwrap_or_else(|_| panic!("unanswered: {} of {}", ids.len() - got.len(), ids.len()))
            .expect("connection closed");
        if let Message::Response { id, result, error } = Message::parse(&line).unwrap()
            && let Some(id) = id.as_i64()
        {
            assert!(error.is_none(), "prompt {id} failed: {error:?}");
            got.insert(id, result.unwrap_or(Value::Null));
        }
    }
    got
}

/// Leo's 319 (2026-10-29): 300 other agents' messages that wait while the agent reads the one
/// before them go in as ONE notice at its next tool step, and none is a turn or a steer of its own.
#[tokio::test]
async fn three_hundred_agent_messages_go_in_as_one_notice_at_the_next_tool_step() {
    let step = fifo("step");
    let env = BTreeMap::from([
        ("FAKE_CLAUDE_STEER".to_owned(), "1".to_owned()),
        ("FAKE_STEER_STEP".to_owned(), step.display().to_string()),
    ]);
    let (hub, mut c) = setup_env(PermissionPolicy::ApproveAll, env).await;
    let id = new_session(&mut c, "coord").await;
    let gate = fifo("gate");
    let turn = c
        .send(method::SESSION_PROMPT, prompt(&id, &format!("gate: {}", gate.display()), None))
        .await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "before-gate").await;
    let running = hub.resolve(&id).unwrap().turn().unwrap().turn_id;

    // The first message goes in as a notice at once; the agent reads it at its next tool step.
    let first = c
        .send(method::SESSION_PROMPT, from_agent(&id, "m-first", "lane-0", "merged #1", json!({})))
        .await;
    until(&hub, &id, "the first notice", |p| p.iter().any(|m| m["steer"] == true)).await;
    let mut sent = vec![first];
    for i in 1..=300 {
        let msg = from_agent(
            &id,
            &format!("m-{i}"),
            &format!("lane-{i}"),
            &format!("result {i}"),
            json!({}),
        );
        sent.push(c.send(method::SESSION_PROMPT, msg).await);
    }
    // Each is in the inbox at once (its acceptance says so), none steered in by itself.
    let mut accepted = 0;
    while accepted < 300 {
        let p = c
            .wait_for(method::MUX_PROMPT_ACCEPTED, |p| {
                p["promptId"].as_str().is_some_and(|id| id.starts_with("m-") && id != "m-first")
            })
            .await;
        assert_eq!(p["inbox"], true, "{p}");
        accepted += 1;
    }
    let steers = prompts(&hub, &id).into_iter().filter(|m| m["steer"] == true).count();
    assert_eq!(steers, 1, "one notice in flight; no message steered in by itself");

    // The next tool step: the first notice was read, and ONE notice brings all 300.
    open(&step).await;
    until(&hub, &id, "the second notice", |_| notices(&hub, &id).len() == 2).await;
    let notices = notices(&hub, &id);
    assert_eq!(carried(&notices[0]), ["m-first"]);
    assert_eq!(carried(&notices[1]).len(), 300);
    assert!(
        notices[1]["text"].as_str().unwrap().starts_with("[inbox] New messages"),
        "{}",
        notices[1]
    );
    open(&step).await;

    // Every sender is answered by the turn its notice went into; no turn of its own.
    let answered = answers(&mut c, &sent).await;
    for (rid, answer) in &answered {
        assert_eq!(answer["stopReason"], "steered", "{rid}: {answer}");
        assert_eq!(answer["_meta"]["acpmux"]["turnId"], running, "{rid}: {answer}");
        assert_eq!(answer["_meta"]["acpmux"]["inbox"], true, "{rid}: {answer}");
    }
    open(&gate).await;
    answers(&mut c, &[turn]).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    let turns = prompts(&hub, &id).into_iter().filter(|m| m["steer"] != true).count();
    assert_eq!(turns, 1, "the person's turn only: {:?}", prompts(&hub, &id));
    for path in [step, gate] {
        let _ = std::fs::remove_file(path);
    }
}

/// An idle chat is woken by a blocker, as ONE turn that carries every new message, and by the
/// first message of a chat that never ran a turn (its first work); an action from a session that
/// neither started it nor gave it its first work, and an FYI, wake no one. A sender that waits
/// for its reply gets the reply of the turn that carried its message.
#[tokio::test]
async fn an_idle_chat_wakes_for_a_blocker_and_for_its_first_work_only() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "lane").await;

    // Its first work wakes it, and the waiting send gets that turn's reply.
    let task = from_agent(&id, "t-1", "coord", "do the thing", json!({}));
    let reply = c.request(method::SESSION_PROMPT, task).await.unwrap();
    assert_eq!(reply["stopReason"], "end_turn", "{reply}");
    let turn_id = reply["_meta"]["acpmux"]["turnId"].as_str().unwrap().to_owned();
    let notice = notices(&hub, &id);
    assert_eq!(notice.len(), 1, "one turn: {:?}", prompts(&hub, &id));
    assert_eq!(notice[0]["turnId"], turn_id);
    assert_eq!(carried(&notice[0]), ["t-1"]);

    // Idle again: an action and an FYI from another lane wait.
    let action =
        c.send(method::SESSION_PROMPT, from_agent(&id, "a-1", "lane-b", "merged", json!({}))).await;
    let fyi = from_agent(&id, "f-1", "lane-c", "CI is slow", json!({"class": "fyi"}));
    let fyi = c.send(method::SESSION_PROMPT, fyi).await;
    tokio::time::sleep(Duration::from_millis(3_000)).await;
    assert_eq!(notices(&hub, &id).len(), 1, "no wake: {:?}", prompts(&hub, &id));

    // A blocker wakes it: ONE turn carries all three.
    let blocker = from_agent(&id, "b-1", "lane-d", "blocked on #12", json!({"class": "blocker"}));
    let blocker = c.send(method::SESSION_PROMPT, blocker).await;
    let answered = answers(&mut c, &[action, fyi, blocker]).await;
    let notices = notices(&hub, &id);
    assert_eq!(notices.len(), 2, "{:?}", prompts(&hub, &id));
    let mut ids = carried(&notices[1]);
    ids.sort();
    assert_eq!(ids, ["a-1", "b-1", "f-1"]);
    let text = notices[1]["text"].as_str().unwrap();
    assert!(
        text.contains("\n- [blocker] 1 new in #12 from lane-d: blocked on #12"),
        "blockers first: {text}"
    );
    for answer in answered.values() {
        assert_eq!(answer["_meta"]["acpmux"]["turnId"], notices[1]["turnId"], "{answer}");
    }
}

/// #27566's case: a prompt queued behind a running turn is never held up behind other agents'
/// messages. No notice steers into the turn while the prompt waits; it goes into the prompt's own
/// turn once that starts.
#[tokio::test]
async fn a_queued_prompt_never_waits_behind_agent_messages() {
    let env = BTreeMap::from([("FAKE_CLAUDE_STEER".to_owned(), "1".to_owned())]);
    let (hub, mut c) = setup_env(PermissionPolicy::ApproveAll, env).await;
    let id = new_session(&mut c, "coord").await;
    let gate = fifo("gate");
    let turn = c
        .send(method::SESSION_PROMPT, prompt(&id, &format!("gate: {}", gate.display()), None))
        .await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "before-gate").await;
    let next = fifo("next");
    let text = format!("gate: {}", next.display());
    let mine = c.send(method::SESSION_PROMPT, prompt(&id, &text, Some("p-me"))).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-me" && p["queued"] == true)
        .await;
    let mut sent = Vec::new();
    for i in 0..5 {
        let msg =
            from_agent(&id, &format!("m-{i}"), "lane-a", &format!("step {i} of #9"), json!({}));
        sent.push(c.send(method::SESSION_PROMPT, msg).await);
    }
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(notices(&hub, &id).is_empty(), "nothing steers in ahead of the waiting prompt");
    open(&gate).await;
    until(&hub, &id, "the notice", |_| !notices(&hub, &id).is_empty()).await;
    open(&next).await;
    let mut ids = sent.clone();
    ids.extend([turn, mine]);
    let mut answered = answers(&mut c, &ids).await;
    answered.retain(|rid, _| sent.contains(rid));
    let all = prompts(&hub, &id);
    let at = |pid: &str| all.iter().position(|m| m["promptId"] == pid).unwrap();
    let notices = notices(&hub, &id);
    assert_eq!(notices.len(), 1, "{all:?}");
    let notice_id = notices[0]["promptId"].as_str().unwrap();
    assert!(at("p-me") < at(notice_id), "the person's prompt first: {all:?}");
    assert_eq!(notices[0]["turnId"], all[at("p-me")]["turnId"], "into its turn");
    assert_eq!(carried(&notices[0]).len(), 5);
    assert!(notices[0]["text"].as_str().unwrap().contains("5 new in #9 from lane-a"));
    for answer in answered.values() {
        assert_eq!(answer["stopReason"], "steered", "{answer}");
    }
    for path in [gate, next] {
        let _ = std::fs::remove_file(path);
    }
}

/// A connection that proved it runs in chat `id`: its agent's tools.
async fn agent_of(hub: &Arc<Hub>, id: &str) -> TestClient {
    let (tx, in_rx) = mpsc::channel(64);
    let (out_tx, rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut c = TestClient { tx, rx, next: 0 };
    let token = acpmux::hub::person::caller_token(id);
    let caller = json!({"callerSession": {"sessionId": id, "token": token}});
    c.request("initialize", json!({"protocolVersion": 1, "_meta": {"acpmux": caller}}))
        .await
        .unwrap();
    c
}

/// Threads: by the PR its sender named, the PR its first line names, else its sender. The chat's
/// agent reads one whole (marked read) and answers in it: the answer lands in the sender's inbox
/// under the same thread, never a turn. Another session reads no inbox but its own.
#[tokio::test]
async fn threads_are_read_whole_and_answered_into_the_senders_inbox() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "coord").await;
    let lane = new_session(&mut c, "lane-a").await;
    // Each has run a turn, so no message wakes either.
    for s in [&id, &lane] {
        c.request(method::SESSION_PROMPT, prompt(s, "hello", None)).await.unwrap();
    }
    let mut lane_agent = agent_of(&hub, &lane).await;
    for (pid, text, mux) in [
        ("m-1", "landed", json!({"pr": 27133})),
        ("m-2", "#27133 is green now", json!({})),
        ("m-3", "starting the next piece", json!({"topic": "plan"})),
    ] {
        let mut p = json!({"sessionId": id, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": {"promptId": pid}}});
        for (k, v) in mux.as_object().cloned().unwrap() {
            p["_meta"]["acpmux"][k] = v;
        }
        lane_agent.send(method::SESSION_PROMPT, p).await;
        lane_agent.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == pid).await;
        // Newest first, by the millisecond.
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    let threads = c.request(method::MUX_INBOX_THREADS, json!({"sessionId": id})).await.unwrap();
    let rows = threads["threads"].as_array().unwrap();
    let keys: Vec<&str> = rows.iter().map(|t| t["threadId"].as_str().unwrap()).collect();
    assert_eq!(keys, ["topic:plan", "from:lane-a/pr:27133", "pr:27133"], "{threads}");
    assert_eq!(rows[0]["from"], json!(["lane-a"]));
    assert_eq!(rows[0]["unread"], 1);
    assert_eq!(rows[0]["class"], "action");
    assert_eq!(rows[0]["newestPreview"], "starting the next piece");

    // Another session's agent reads no other chat's inbox.
    let refused = lane_agent.request(method::MUX_INBOX_THREADS, json!({"sessionId": id})).await;
    assert!(refused.is_err_and(|e| e.contains("inbox.other_session")));

    // The chat's own agent reads a thread, marked read, and answers in it.
    let mut coord_agent = agent_of(&hub, &id).await;
    let read = json!({"sessionId": id, "threadId": "pr:27133", "markRead": true});
    let thread = coord_agent.request(method::MUX_INBOX_THREAD, read).await.unwrap();
    assert_eq!(thread["messages"][0]["text"], "landed", "{thread}");
    let threads = c.request(method::MUX_INBOX_THREADS, json!({"sessionId": id})).await.unwrap();
    assert_eq!(threads["threads"][2]["unread"], 0, "{threads}");
    let reply = json!({"sessionId": id, "threadId": "pr:27133", "text": "thanks, merging"});
    let sent = coord_agent.request(method::MUX_INBOX_REPLY, reply).await.unwrap();
    assert_eq!(sent["sessionId"], lane, "{sent}");
    let theirs = c.request(method::MUX_INBOX_THREADS, json!({"sessionId": lane})).await.unwrap();
    assert_eq!(theirs["threads"][0]["threadId"], "pr:27133", "{theirs}");
    assert_eq!(theirs["threads"][0]["from"], json!(["coord"]));
    tokio::time::sleep(Duration::from_millis(2_500)).await;
    assert!(notices(&hub, &lane).is_empty(), "an answer is no turn of theirs");
}

/// Withdraw (`withdraw.rs`, "unsend") of an inbox item: one no notice carried yet leaves the inbox
/// and its waiting send answers withdrawn; once a notice carried it, a retraction goes into its
/// thread in the inbox, never a turn.
#[tokio::test]
async fn an_inbox_message_is_unsent_until_a_notice_carries_it_then_retracted_in_its_thread() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "coord").await;
    c.request(method::SESSION_PROMPT, prompt(&id, "hello", None)).await.unwrap();
    let waiting =
        c.send(method::SESSION_PROMPT, from_agent(&id, "a-1", "lane-b", "merged", json!({}))).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "a-1").await;
    let unsent = json!({"sessionId": id, "promptId": "a-1"});
    let unsent = c.request("_acpmux/prompt_withdraw", unsent).await.unwrap();
    assert_eq!(unsent["outcome"], "unsent", "{unsent}");
    let answered = answers(&mut c, &[waiting]).await;
    assert_eq!(answered[&waiting]["_meta"]["acpmux"]["withdrawn"], true, "{answered:?}");
    let threads = c.request(method::MUX_INBOX_THREADS, json!({"sessionId": id})).await.unwrap();
    assert_eq!(threads["threads"], json!([]), "{threads}");

    // A blocker wakes the chat; once its notice carried it, a withdraw retracts it in its thread.
    let blocker = from_agent(&id, "b-1", "lane-d", "blocked on #12", json!({"class": "blocker"}));
    let blocker = c.send(method::SESSION_PROMPT, blocker).await;
    answers(&mut c, &[blocker]).await;
    let retract = json!({"sessionId": id, "promptId": "b-1"});
    let retracted = c.request("_acpmux/prompt_withdraw", retract).await.unwrap();
    assert_eq!(retracted["outcome"], "retracted", "{retracted}");
    assert_eq!(retracted["via"], "inbox", "{retracted}");
    let thread = json!({"sessionId": id, "threadId": "from:lane-d/pr:12"});
    let thread = c.request(method::MUX_INBOX_THREAD, thread).await.unwrap();
    let texts: Vec<&str> =
        thread["messages"].as_array().unwrap().iter().filter_map(|m| m["text"].as_str()).collect();
    assert_eq!(texts.len(), 2, "{thread}");
    assert!(texts[0].contains("was withdrawn by its sender"), "{thread}");
    let again = json!({"sessionId": id, "promptId": "b-1"});
    let again = c.request("_acpmux/prompt_withdraw", again).await.unwrap();
    assert_eq!(again["already"], true, "{again}");
    tokio::time::sleep(Duration::from_millis(2_500)).await;
    assert_eq!(notices(&hub, &id).len(), 1, "a retraction is no turn: {:?}", prompts(&hub, &id));
}
