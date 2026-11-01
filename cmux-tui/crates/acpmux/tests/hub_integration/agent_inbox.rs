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

/// The chat's first work from another agent (`hub/inbox.rs` `first_work`): a turn that is not the
/// person's own, gated on `gate`, which notices and other agents' steers may go into.
fn agents_gated_turn(id: &str, gate: &std::path::Path) -> Value {
    let mut msg =
        from_agent(id, "w-first", "orch", &format!("gate: {}", gate.display()), json!({}));
    msg["_meta"]["acpmux"]["steer"] = json!(false);
    msg
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
/// The turn is the chat's first work from another agent: none goes into the person's own turn.
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
    let turn = c.send(method::SESSION_PROMPT, agents_gated_turn(&id, &gate)).await;
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
    assert_eq!(turns, 1, "the first work's turn only: {:?}", prompts(&hub, &id));
    for path in [step, gate] {
        let _ = std::fs::remove_file(path);
    }
}

/// A chat's first work from another agent runs as that prompt, never as a notice of it, and its
/// sender gets that turn's reply. After it, an idle chat is woken by a blocker, as ONE turn that
/// carries every new message; an action from a session that neither started it nor gave it its
/// first work, and an FYI, wake no one. A sender that waits for its reply gets the reply of the
/// turn that carried its message.
#[tokio::test]
async fn an_idle_chat_runs_its_first_work_and_wakes_for_a_blocker_only() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "lane").await;

    // Its first work runs as its prompt, and the waiting send gets that turn's reply.
    let task = from_agent(&id, "t-1", "coord", "do the thing", json!({}));
    let reply = c.request(method::SESSION_PROMPT, task).await.unwrap();
    assert_eq!(reply["stopReason"], "end_turn", "{reply}");
    assert_ne!(reply["_meta"]["acpmux"]["inbox"], true, "{reply}");
    let all = prompts(&hub, &id);
    assert!(notices(&hub, &id).is_empty(), "no notice of its brief: {all:?}");
    assert_eq!(all.len(), 1, "{all:?}");
    assert_eq!(all[0]["promptId"], "t-1", "{all:?}");

    // Idle again: an action and an FYI from another lane wait.
    let action =
        c.send(method::SESSION_PROMPT, from_agent(&id, "a-1", "lane-b", "merged", json!({}))).await;
    let accepted = c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "a-1").await;
    assert_eq!(accepted["inbox"], true, "a message after the first goes to the inbox: {accepted}");
    let fyi = from_agent(&id, "f-1", "lane-c", "CI is slow", json!({"class": "fyi"}));
    let fyi = c.send(method::SESSION_PROMPT, fyi).await;
    tokio::time::sleep(Duration::from_millis(3_000)).await;
    assert!(notices(&hub, &id).is_empty(), "no wake: {:?}", prompts(&hub, &id));

    // A blocker wakes it: ONE turn carries all three.
    let blocker = from_agent(&id, "b-1", "lane-d", "blocked on #12", json!({"class": "blocker"}));
    let blocker = c.send(method::SESSION_PROMPT, blocker).await;
    let answered = answers(&mut c, &[action, fyi, blocker]).await;
    let notices = notices(&hub, &id);
    assert_eq!(notices.len(), 1, "{:?}", prompts(&hub, &id));
    let mut ids = carried(&notices[0]);
    ids.sort();
    assert_eq!(ids, ["a-1", "b-1", "f-1"]);
    let text = notices[0]["text"].as_str().unwrap();
    assert!(
        text.contains("\n- [blocker] 1 new in #12 from lane-d: blocked on #12"),
        "blockers first: {text}"
    );
    for answer in answered.values() {
        assert_eq!(answer["_meta"]["acpmux"]["turnId"], notices[0]["turnId"], "{answer}");
    }
}

/// #27566's case: a prompt queued behind a running turn is never held up behind other agents'
/// messages. No notice steers into the turn while the prompt waits, nor into the prompt's own turn
/// once that starts (Leo, 2026-11-01: "why do the x messages from y sessions seem to always
/// piggyback on my messages instead of going on their own"): it goes in as a turn of its own after
/// it, at once, though none of its messages would wake an idle chat.
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
    until(&hub, &id, "the person's turn", |p| p.iter().any(|m| m["promptId"] == "p-me")).await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(
        notices(&hub, &id).is_empty(),
        "nothing goes into the person's turn: {:?}",
        prompts(&hub, &id)
    );
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
    assert_ne!(notices[0]["turnId"], all[at("p-me")]["turnId"], "a turn of its own: {all:?}");
    assert_ne!(notices[0]["steer"], true, "no steer: {all:?}");
    assert_eq!(all[at("p-me")]["text"], text.as_str(), "the person's words as written");
    assert_eq!(carried(&notices[0]).len(), 5);
    assert!(notices[0]["text"].as_str().unwrap().contains("5 new in #9 from lane-a"));
    for answer in answered.values() {
        assert_eq!(answer["stopReason"], "end_turn", "{answer}");
        assert_eq!(answer["_meta"]["acpmux"]["turnId"], notices[0]["turnId"], "{answer}");
    }
    for path in [gate, next] {
        let _ = std::fs::remove_file(path);
    }
}

/// Starts a gated turn in a steering chat and queues the person's prompt `p-me` behind it: the
/// hub, the client, the chat, the running turn's id and request, and both gates.
async fn turn_with_a_waiting_prompt()
-> (Arc<Hub>, TestClient, String, String, i64, i64, std::path::PathBuf, std::path::PathBuf) {
    let env = BTreeMap::from([("FAKE_CLAUDE_STEER".to_owned(), "1".to_owned())]);
    let (hub, mut c) = setup_env(PermissionPolicy::ApproveAll, env).await;
    let id = new_session(&mut c, "coord").await;
    let gate = fifo("gate");
    let turn = c
        .send(method::SESSION_PROMPT, prompt(&id, &format!("gate: {}", gate.display()), None))
        .await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "before-gate").await;
    let running = hub.resolve(&id).unwrap().turn().unwrap().turn_id;
    let next = fifo("next");
    let text = format!("gate: {}", next.display());
    let mine = c.send(method::SESSION_PROMPT, prompt(&id, &text, Some("p-me"))).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-me" && p["queued"] == true)
        .await;
    (hub, c, id, running, turn, mine, gate, next)
}

/// Leo, 2026-10-29: "but even if im just queueing, your turn should still be ending". Another
/// agent's steer that is no inbox item (here a team message; also a peer's forward, a correction
/// under a supersede key, a `cmux agent message`) follows the notices' rule: while a prompt waits
/// behind the running turn it never steers in, which kept that turn going past the prompt. It
/// queues behind the person's prompt and runs after it; a steer-only one is refused.
#[tokio::test]
async fn another_agents_steer_waits_behind_a_queued_prompt() {
    let (hub, mut c, id, running, turn, mine, gate, next) = turn_with_a_waiting_prompt().await;
    let msg = from_agent(&id, "t-1", "coord", "status of #9?", json!({"teamMessage": true}));
    let sent = c.send(method::SESSION_PROMPT, msg).await;
    let accepted = c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "t-1").await;
    assert_eq!(accepted["queued"], true, "behind the person's prompt: {accepted}");
    assert_ne!(accepted["inbox"], true, "no inbox item: {accepted}");
    // Sent with interrupt, it stops nothing and goes ahead of no one: it waits too.
    let stop = from_agent(
        &id,
        "t-3",
        "coord",
        "stop what you do",
        json!({"teamMessage": true, "interrupt": true}),
    );
    let stop = c.send(method::SESSION_PROMPT, stop).await;
    let held = c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "t-3").await;
    assert_eq!(held["queued"], true, "{held}");
    let only = from_agent(&id, "t-2", "coord", "now", json!({"steerOnly": true}));
    let refused = c.request(method::SESSION_PROMPT, only).await.unwrap_err();
    assert!(format!("{refused:?}").contains("steer.unavailable"), "{refused:?}");
    assert!(format!("{refused:?}").contains("a prompt waits"), "{refused:?}");
    tokio::time::sleep(Duration::from_millis(300)).await;
    let all = prompts(&hub, &id);
    assert!(!all.iter().any(|m| m["steer"] == true), "nothing steered in: {all:?}");

    open(&gate).await;
    open(&next).await;
    let answered = answers(&mut c, &[turn, mine, sent, stop]).await;
    assert_eq!(answered[&turn]["stopReason"], "end_turn", "never stopped: {}", answered[&turn]);
    assert_eq!(answered[&sent]["stopReason"], "end_turn", "a turn of its own: {}", answered[&sent]);
    assert_eq!(answered[&stop]["stopReason"], "end_turn", "{}", answered[&stop]);
    // Each went in after the person's prompt, in a turn of the agents' messages (they may join
    // one, `digest.rs`), never into the turn that ran or the person's.
    let all = prompts(&hub, &id);
    let mine_at = all.iter().position(|m| m["promptId"] == "p-me").unwrap();
    for words in ["status of #9?", "stop what you do"] {
        let has = |m: &Value| m["text"].as_str().is_some_and(|t| t.contains(words));
        let at = all.iter().position(has).unwrap_or_else(|| panic!("{words}: {all:?}"));
        assert!(mine_at < at, "the person's prompt first: {all:?}");
        assert_ne!(all[at]["turnId"], running.as_str(), "not in the running turn: {all:?}");
        assert_ne!(all[at]["turnId"], all[mine_at]["turnId"], "nor the person's: {all:?}");
    }
    for path in [gate, next] {
        let _ = std::fs::remove_file(path);
    }
}

/// With nothing waiting behind the running turn, and that turn not the person's own, another
/// agent's steer still steers in.
#[tokio::test]
async fn another_agents_steer_goes_in_when_no_prompt_waits() {
    let env = BTreeMap::from([("FAKE_CLAUDE_STEER".to_owned(), "1".to_owned())]);
    let (hub, mut c) = setup_env(PermissionPolicy::ApproveAll, env).await;
    let id = new_session(&mut c, "coord").await;
    let gate = fifo("gate");
    let turn = c.send(method::SESSION_PROMPT, agents_gated_turn(&id, &gate)).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "before-gate").await;
    let running = hub.resolve(&id).unwrap().turn().unwrap().turn_id;
    let msg = from_agent(&id, "t-1", "coord", "status of #9?", json!({"teamMessage": true}));
    let sent = c.send(method::SESSION_PROMPT, msg).await;
    let only = from_agent(&id, "t-2", "coord", "now", json!({"steerOnly": true}));
    let only = c.send(method::SESSION_PROMPT, only).await;
    let answered = answers(&mut c, &[sent, only]).await;
    for answer in answered.values() {
        assert_eq!(answer["stopReason"], "steered", "{answer}");
        assert_eq!(answer["_meta"]["acpmux"]["turnId"], running.as_str(), "{answer}");
    }
    open(&gate).await;
    answers(&mut c, &[turn]).await;
    let _ = std::fs::remove_file(gate);
}

/// The person's own steer still goes into the running turn while their prompt waits behind it.
#[tokio::test]
async fn the_persons_steer_goes_in_while_a_prompt_waits() {
    let (hub, mut c, id, running, turn, mine, gate, next) = turn_with_a_waiting_prompt().await;
    assert!(hub.resolve(&id).unwrap().turn().unwrap().persons, "the running turn is the person's");
    let steer = json!({"sessionId": id, "prompt": [{"type": "text", "text": "also this"}],
                       "_meta": {"acpmux": {"promptId": "p-steer", "steer": true}}});
    let steer = c.send(method::SESSION_PROMPT, steer).await;
    let answered = answers(&mut c, &[steer]).await;
    assert_eq!(answered[&steer]["stopReason"], "steered", "{}", answered[&steer]);
    let all = prompts(&hub, &id);
    let at = |pid: &str| all.iter().position(|m| m["promptId"] == pid).unwrap();
    assert_eq!(all[at("p-steer")]["turnId"], running.as_str(), "into the running turn: {all:?}");
    open(&gate).await;
    open(&next).await;
    answers(&mut c, &[turn, mine]).await;
    for path in [gate, next] {
        let _ = std::fs::remove_file(path);
    }
}

/// Leo, 2026-11-01: "why do the x messages from y sessions seem to always piggyback on my messages
/// instead of going on their own". Another agent's message never goes into the person's own turn:
/// no notice steers in at its start or its steps, and it goes in as a turn of its own once that
/// turn ends, at once, though it would wake no idle chat (an action from a lane that neither
/// started the chat nor gave it work).
#[tokio::test]
async fn a_notice_never_goes_into_the_persons_turn_and_runs_on_its_own_after_it() {
    let env = BTreeMap::from([("FAKE_CLAUDE_STEER".to_owned(), "1".to_owned())]);
    let (hub, mut c) = setup_env(PermissionPolicy::ApproveAll, env).await;
    let id = new_session(&mut c, "coord").await;
    // The chat ran a turn, so what follows goes to its inbox.
    let first = from_agent(&id, "w-0", "orch", "warm up", json!({"steer": false}));
    c.request(method::SESSION_PROMPT, first).await.unwrap();
    let gate = fifo("gate");
    let words = format!("gate: {}", gate.display());
    let turn = c.send(method::SESSION_PROMPT, prompt(&id, &words, Some("p-me"))).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "before-gate").await;
    let mine = hub.resolve(&id).unwrap().turn().unwrap().turn_id;
    let msg = from_agent(&id, "m-1", "lane-a", "merged #9", json!({}));
    let sent = c.send(method::SESSION_PROMPT, msg).await;
    let accepted = c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "m-1").await;
    assert_eq!(accepted["inbox"], true, "{accepted}");
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(notices(&hub, &id).is_empty(), "none into the person's turn: {:?}", prompts(&hub, &id));

    open(&gate).await;
    let answered = answers(&mut c, &[turn, sent]).await;
    assert_eq!(answered[&turn]["stopReason"], "end_turn", "{}", answered[&turn]);
    assert_eq!(answered[&sent]["stopReason"], "end_turn", "its own turn: {}", answered[&sent]);
    let all = prompts(&hub, &id);
    let notices = notices(&hub, &id);
    assert_eq!(notices.len(), 1, "{all:?}");
    assert_eq!(carried(&notices[0]), ["m-1"]);
    assert_ne!(notices[0]["turnId"], mine.as_str(), "a turn of its own: {all:?}");
    assert_ne!(notices[0]["steer"], true, "{all:?}");
    let at = |pid: &str| all.iter().position(|m| m["promptId"] == pid).unwrap();
    assert!(at("p-me") < at(notices[0]["promptId"].as_str().unwrap()), "{all:?}");
    assert_eq!(all[at("p-me")]["text"], words.as_str(), "the person's words as written");
    // The turn says so in its log, so a restart keeps it the person's (`hosts.rs`).
    let started: Vec<Value> = hub
        .events(&id, 0, 1_000_000)
        .unwrap()
        .into_iter()
        .filter(|r| r.kind == "turn_started")
        .map(|r| r.msg)
        .collect();
    let of =
        |turn: &Value| started.iter().find(|m| m["turnId"] == *turn).unwrap()["persons"].clone();
    assert_eq!(of(&json!(mine)), true, "{started:?}");
    assert_eq!(of(&notices[0]["turnId"]), false, "{started:?}");
    let _ = std::fs::remove_file(gate);
}

/// Nor does another agent's steer that is no inbox item (a team message, a peer's forward) go into
/// the person's own turn, though nothing waits behind it: it queues and goes in as a turn of its
/// own after it. One sent with interrupt stops nothing, and a steer-only one is refused.
#[tokio::test]
async fn another_agents_steer_waits_for_the_persons_turn() {
    let env = BTreeMap::from([("FAKE_CLAUDE_STEER".to_owned(), "1".to_owned())]);
    let (hub, mut c) = setup_env(PermissionPolicy::ApproveAll, env).await;
    let id = new_session(&mut c, "coord").await;
    let gate = fifo("gate");
    let words = format!("gate: {}", gate.display());
    let turn = c.send(method::SESSION_PROMPT, prompt(&id, &words, Some("p-me"))).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "before-gate").await;
    let mine = hub.resolve(&id).unwrap().turn().unwrap().turn_id;
    let msg = from_agent(&id, "t-1", "coord", "status of #9?", json!({"teamMessage": true}));
    let sent = c.send(method::SESSION_PROMPT, msg).await;
    let accepted = c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "t-1").await;
    assert_eq!(accepted["queued"], true, "behind the person's turn: {accepted}");
    let stop = from_agent(
        &id,
        "t-3",
        "coord",
        "stop what you do",
        json!({"teamMessage": true, "interrupt": true}),
    );
    let stop = c.send(method::SESSION_PROMPT, stop).await;
    let held = c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "t-3").await;
    assert_eq!(held["queued"], true, "{held}");
    let only = from_agent(&id, "t-2", "coord", "now", json!({"steerOnly": true}));
    let refused = c.request(method::SESSION_PROMPT, only).await.unwrap_err();
    assert!(format!("{refused:?}").contains("the person's own turn"), "{refused:?}");
    tokio::time::sleep(Duration::from_millis(300)).await;
    let all = prompts(&hub, &id);
    assert!(!all.iter().any(|m| m["steer"] == true), "nothing steered in: {all:?}");

    open(&gate).await;
    let answered = answers(&mut c, &[turn, sent, stop]).await;
    assert_eq!(answered[&turn]["stopReason"], "end_turn", "never stopped: {}", answered[&turn]);
    let all = prompts(&hub, &id);
    for words in ["status of #9?", "stop what you do"] {
        let has = |m: &Value| m["text"].as_str().is_some_and(|t| t.contains(words));
        let at = all.iter().position(has).unwrap_or_else(|| panic!("{words}: {all:?}"));
        assert_ne!(all[at]["turnId"], mine.as_str(), "not in the person's turn: {all:?}");
    }
    let _ = std::fs::remove_file(gate);
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
    // Sent again, a withdrawn message answers withdrawn and never goes back in.
    let resent =
        c.send(method::SESSION_PROMPT, from_agent(&id, "a-1", "lane-b", "merged", json!({}))).await;
    let answered = answers(&mut c, &[resent]).await;
    assert_eq!(answered[&resent]["_meta"]["acpmux"]["withdrawn"], true, "{answered:?}");
    let threads = c.request(method::MUX_INBOX_THREADS, json!({"sessionId": id})).await.unwrap();
    assert_eq!(threads["threads"], json!([]), "{threads}");

    // A blocker wakes the chat; once its notice carried it, a withdraw retracts it in its thread.
    let blocker = from_agent(&id, "b-1", "lane-d", "blocked on #12", json!({"class": "blocker"}));
    let blocker = c.send(method::SESSION_PROMPT, blocker).await;
    let first = answers(&mut c, &[blocker]).await;
    // Sent again, it answers with its notice's answer, and no second notice carries it.
    let resend = from_agent(&id, "b-1", "lane-d", "blocked on #12", json!({"class": "blocker"}));
    let resend = c.send(method::SESSION_PROMPT, resend).await;
    let again = answers(&mut c, &[resend]).await;
    assert_eq!(again[&resend]["stopReason"], first[&blocker]["stopReason"], "{again:?} {first:?}");
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

/// A chat that closes answers the senders its inbox still holds with the closing error and keeps
/// its threads readable: no sender waits forever on a closed chat.
#[tokio::test]
async fn a_closed_chat_answers_and_refuses_senders_and_keeps_its_threads() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "coord").await;
    c.request(method::SESSION_PROMPT, prompt(&id, "hello", None)).await.unwrap();
    // An action from a lane that neither started the chat nor gave it work: it waits.
    let msg = from_agent(&id, "a-1", "lane-b", "merged #5", json!({}));
    let waiting = c.send(method::SESSION_PROMPT, msg).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "a-1").await;
    c.request(method::SESSION_CLOSE, json!({"sessionId": id})).await.unwrap();
    let line = tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            let line = c.rx.recv().await.expect("connection closed");
            if let Message::Response { id: rid, error, .. } = Message::parse(&line).unwrap()
                && rid.as_i64() == Some(waiting)
            {
                return error;
            }
        }
    })
    .await
    .expect("the waiting sender was never answered");
    assert!(line.is_some(), "a closed chat answers its waiting sender with an error");
    let threads = c.request(method::MUX_INBOX_THREADS, json!({"sessionId": id})).await.unwrap();
    assert_eq!(threads["threads"][0]["threadId"], "from:lane-b/pr:5", "{threads}");
}

/// A review box (`review_box.rs`) has no inbox: another agent's message to its running review
/// turn makes no inbox item and steers nothing in, notice or message. It queues behind the review
/// as before the inbox, runs as its own turn once the review ends, and its sender gets that
/// turn's answer. A steer-only one is refused. The same message to any other chat still goes to
/// its inbox.
#[tokio::test]
async fn a_review_box_takes_no_inbox_message_and_no_steer_during_its_review() {
    let env = BTreeMap::from([("FAKE_CLAUDE_STEER".to_owned(), "1".to_owned())]);
    let (hub, mut c) = setup_env(PermissionPolicy::ApproveAll, env).await;
    let id = new_session(&mut c, "review-1").await;
    c.request(method::MUX_TAG, json!({"sessionId": id, "set": {"review.target": "cmux:a..b"}}))
        .await
        .unwrap();
    let gate = fifo("review");
    let review = c
        .send(method::SESSION_PROMPT, prompt(&id, &format!("gate: {}", gate.display()), None))
        .await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "before-gate").await;

    let msg = from_agent(&id, "r-1", "coord", "any news on #9?", json!({}));
    let sent = c.send(method::SESSION_PROMPT, msg).await;
    let accepted = c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "r-1").await;
    assert_eq!(accepted["queued"], true, "behind the review: {accepted}");
    assert_ne!(accepted["inbox"], true, "no inbox item: {accepted}");
    let only = json!({"promptId": "r-2", "fromAgent": "coord", "steer": true, "steerOnly": true});
    let only = json!({"sessionId": id, "prompt": [{"type": "text", "text": "now"}], "_meta": {"acpmux": only}});
    let refused = c.request(method::SESSION_PROMPT, only).await.unwrap_err();
    assert!(format!("{refused:?}").contains("review box"), "{refused:?}");
    // One sent with interrupt stops no review: it waits too.
    let stop = from_agent(&id, "r-4", "coord", "stop and do this", json!({"interrupt": true}));
    let stop = c.send(method::SESSION_PROMPT, stop).await;
    let held = c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "r-4").await;
    assert_eq!(held["queued"], true, "{held}");
    // Nor does a digest bundle it: it stays its own prompt.
    let digest = c.request("_acpmux/inbox_digest", json!({"sessionId": id})).await.unwrap_err();
    assert!(digest.contains("inbox_digest.review_box"), "{digest}");
    tokio::time::sleep(Duration::from_millis(500)).await;
    let all = prompts(&hub, &id);
    assert!(notices(&hub, &id).is_empty(), "no notice: {all:?}");
    assert!(!all.iter().any(|m| m["steer"] == true), "nothing steered into the review: {all:?}");

    open(&gate).await;
    let answered = answers(&mut c, &[review, sent, stop]).await;
    assert_eq!(answered[&review]["stopReason"], "end_turn", "never stopped: {}", answered[&review]);
    assert_eq!(answered[&sent]["stopReason"], "end_turn", "its own turn: {}", answered[&sent]);
    let all = prompts(&hub, &id);
    assert!(notices(&hub, &id).is_empty(), "{all:?}");
    let turns: Vec<_> = all.iter().map(|m| m["turnId"].clone()).collect();
    // Each its own turn: none joins another (`digest.rs`), none is in the review's.
    assert_eq!(turns.len(), 3, "the review, then each message: {all:?}");
    assert!(turns[0] != turns[1] && turns[1] != turns[2], "{all:?}");
    assert_eq!(answered[&stop]["stopReason"], "end_turn", "{}", answered[&stop]);

    // Any other chat that ran a turn: the same message goes to its inbox.
    let lane = new_session(&mut c, "lane").await;
    c.request(method::SESSION_PROMPT, prompt(&lane, "hello", None)).await.unwrap();
    let msg = from_agent(&lane, "r-3", "coord", "any news on #9?", json!({"class": "fyi"}));
    c.send(method::SESSION_PROMPT, msg).await;
    let accepted = c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "r-3").await;
    assert_eq!(accepted["inbox"], true, "{accepted}");
    let _ = std::fs::remove_file(gate);
}

/// A review box's first prompt is the task `lane-place new --review` sends it as another agent
/// (`acpmux new --prompt-file`): it runs as that prompt, never as an inbox notice in its place,
/// and the sender gets that turn's answer.
#[tokio::test]
async fn a_review_box_runs_its_first_prompt_from_another_agent_as_its_task() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    {
        let mut config = hub.config.write().await;
        let fake = config.harnesses["fake"].clone();
        config.harnesses.insert("fake-review-box".to_owned(), fake);
    }
    let new = json!({"cwd": cwd(), "mcpServers": [],
                     "_meta": {"acpmux": {"name": "review-2", "harness": "fake-review-box"}}});
    let id = c.request(method::SESSION_NEW, new).await.unwrap()["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let task =
        from_agent(&id, "task-1", "lane-place", "Review #9 and end with SHIP or BLOCK", json!({}));
    let reply = c.request(method::SESSION_PROMPT, task).await.unwrap();
    assert_eq!(reply["stopReason"], "end_turn", "{reply}");
    assert_ne!(reply["_meta"]["acpmux"]["inbox"], true, "{reply}");
    let all = prompts(&hub, &id);
    assert!(notices(&hub, &id).is_empty(), "no notice in place of the task: {all:?}");
    assert_eq!(all.len(), 1, "{all:?}");
    assert_eq!(all[0]["promptId"], "task-1", "{all:?}");
}

/// A chat whose inbox took a message before it became a review box (a `review.` tag set later):
/// no notice of it steers into the review turn that starts next. The message comes while the
/// person's prompt waits behind a turn, so its notice is held for the next turn's start (as
/// `a_queued_prompt_never_waits_behind_agent_messages` shows); the tag comes before that turn.
#[tokio::test]
async fn an_inbox_message_from_before_the_review_tag_never_steers_into_the_review() {
    let env = BTreeMap::from([("FAKE_CLAUDE_STEER".to_owned(), "1".to_owned())]);
    let (hub, mut c) = setup_env(PermissionPolicy::ApproveAll, env).await;
    let id = new_session(&mut c, "review-3").await;
    let gate = fifo("before");
    let first = c
        .send(method::SESSION_PROMPT, prompt(&id, &format!("gate: {}", gate.display()), None))
        .await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "before-gate").await;
    let review_gate = fifo("review");
    let text = format!("gate: {}", review_gate.display());
    let review = c.send(method::SESSION_PROMPT, prompt(&id, &text, Some("p-review"))).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-review" && p["queued"] == true)
        .await;
    let msg = from_agent(&id, "m-1", "lane-b", "blocked on #5", json!({"class": "blocker"}));
    let sent = c.send(method::SESSION_PROMPT, msg).await;
    let accepted = c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "m-1").await;
    assert_eq!(accepted["inbox"], true, "{accepted}");
    c.request(method::MUX_TAG, json!({"sessionId": id, "set": {"review.target": "cmux:a..b"}}))
        .await
        .unwrap();

    // The review turn starts and ends: on base the held notice steered in at its start. A FIFO
    // write waits for its reader, so the second opens once the review turn runs. Every answer is
    // read together: none is dropped while waiting for another.
    open(&gate).await;
    open(&review_gate).await;
    let answered = answers(&mut c, &[first, review, sent]).await;
    assert_eq!(answered[&review]["stopReason"], "end_turn", "{}", answered[&review]);
    let review_turn = answered[&review]["_meta"]["acpmux"]["turnId"].clone();
    let all = prompts(&hub, &id);
    assert!(
        !all.iter().any(|m| m["steer"] == true && m["turnId"] == review_turn),
        "nothing steered into the review: {all:?}"
    );
    assert!(
        notices(&hub, &id).iter().all(|n| n["turnId"] != review_turn),
        "no notice in the review's turn: {all:?}"
    );
    // After the review it woke the chat as a turn of its own, which answered its sender.
    assert_ne!(answered[&sent]["_meta"]["acpmux"]["turnId"], review_turn, "{}", answered[&sent]);
    for path in [gate, review_gate] {
        let _ = std::fs::remove_file(path);
    }
}

/// A message that comes while a chat's first work waits or runs is no first work: it goes to the
/// inbox, and only the first runs as a prompt.
#[tokio::test]
async fn only_the_first_message_to_a_new_chat_runs_as_its_prompt() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "lane").await;
    let gate = fifo("first");
    let brief = from_agent(&id, "t-1", "coord", &format!("gate: {}", gate.display()), json!({}));
    let first = c.send(method::SESSION_PROMPT, brief).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "before-gate").await;
    let next = from_agent(&id, "t-2", "coord", "and this too", json!({"class": "fyi"}));
    c.send(method::SESSION_PROMPT, next).await;
    let accepted = c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "t-2").await;
    assert_eq!(accepted["inbox"], true, "{accepted}");
    open(&gate).await;
    let reply = answers(&mut c, &[first]).await;
    assert_eq!(reply[&first]["stopReason"], "end_turn", "{}", reply[&first]);
    let all = prompts(&hub, &id);
    assert_eq!(all[0]["promptId"], "t-1", "{all:?}");
    let _ = std::fs::remove_file(gate);
}

/// Two messages that come at once to a chat that never ran a turn: only one is its first work
/// and runs as its prompt; the other goes to the inbox (the first work's hold, `inbox.rs`).
#[tokio::test]
async fn of_two_first_messages_at_once_only_one_runs_as_the_prompt() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "lane").await;
    let a = from_agent(&id, "x-1", "coord", "do the thing", json!({}));
    let b = from_agent(&id, "x-2", "lane-b", "and this", json!({"class": "fyi"}));
    let sent = [c.send(method::SESSION_PROMPT, a).await, c.send(method::SESSION_PROMPT, b).await];
    let mut inbox = BTreeMap::new();
    while inbox.len() < 2 {
        let p = c
            .wait_for(method::MUX_PROMPT_ACCEPTED, |p| {
                p["promptId"] == "x-1" || p["promptId"] == "x-2"
            })
            .await;
        inbox.insert(p["promptId"].as_str().unwrap().to_owned(), p["inbox"] == true);
    }
    let taken = inbox.values().filter(|v| **v).count();
    assert_eq!(taken, 1, "one first work, one inbox item: {inbox:?}");
    // The first work's turn answers; the inbox item waits for a notice, so its answer is not read.
    let ran = if inbox["x-1"] { sent[1] } else { sent[0] };
    let reply = answers(&mut c, &[ran]).await;
    assert_eq!(reply[&ran]["stopReason"], "end_turn", "{}", reply[&ran]);
}

/// Labs team messaging (`meshRelay.teamMessaging`) is off here, as on most daemons: a chat's agent
/// still reads every word of its inbox. `inbox_read` reads it, and so do the team mailbox's inbox,
/// read and ack, which an agent started before the inbox has instead of `inbox_read`, and which
/// `acpmux inbox` calls (`hub/inbox_team_page.rs`). Three helpers saw only a notice's
/// 120-character preview of a standing order from their owner, refused "team messaging is
/// disabled" (2026-10-31).
#[tokio::test]
async fn with_team_messaging_off_a_chat_reads_its_inbox_whole() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    assert!(!hub.config.read().await.mesh_relay.as_ref().is_some_and(|r| r.team_messaging));
    let id = new_session(&mut c, "helper").await;
    let owner = new_session(&mut c, "owner").await;
    for s in [&id, &owner] {
        c.request(method::SESSION_PROMPT, prompt(s, "hello", None)).await.unwrap();
    }
    // Longer than a notice holds whole (4 KB), so the notice has only a preview of it.
    let order = format!(
        "A standing rule from your owner: {}",
        "read code and diffs from the host mirror, never the contents API. ".repeat(70)
    );
    let mut owner_agent = agent_of(&hub, &owner).await;
    let p = json!({"sessionId": id, "prompt": [{"type": "text", "text": order}],
        "_meta": {"acpmux": {"promptId": "m-1", "class": "blocker"}}});
    owner_agent.send(method::SESSION_PROMPT, p).await;
    owner_agent.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "m-1").await;
    // A blocker wakes the chat: its notice shows only a preview.
    until(&hub, &id, "the notice", |p| {
        p.iter().any(|m| m["_meta"]["provenance"]["kind"] == "inbox_notice")
    })
    .await;
    let notice = notices(&hub, &id)[0]["text"].as_str().unwrap().to_owned();
    assert!(!notice.contains(&order), "{notice}");

    let mut agent = agent_of(&hub, &id).await;
    let threads = agent.request(method::MUX_INBOX_THREADS, json!({"sessionId": id})).await.unwrap();
    let thread = threads["threads"][0]["threadId"].as_str().unwrap().to_owned();
    let read = json!({"sessionId": id, "threadId": thread, "markRead": false});
    let whole = agent.request(method::MUX_INBOX_THREAD, read).await.unwrap();
    assert_eq!(whole["messages"][0]["text"], order, "{whole}");

    // The team mailbox's methods read the same inbox while team messaging is off.
    let page = agent.request(method::MUX_TEAM_INBOX, json!({"unreadOnly": false})).await.unwrap();
    assert_eq!(page["messages"][0]["messageId"], "m-1", "{page}");
    assert_eq!(page["messages"][0]["body"], order, "{page}");
    assert_eq!(page["messages"][0]["from"]["name"], "owner", "{page}");
    let one = agent.request(method::MUX_TEAM_READ, json!({"id": "m-1"})).await.unwrap();
    assert_eq!(one["message"]["body"], order, "{one}");
    let by_thread = agent.request(method::MUX_TEAM_READ, json!({"id": thread})).await.unwrap();
    assert!(by_thread["message"]["body"].as_str().unwrap().contains(&order), "{by_thread}");
    agent.request(method::MUX_TEAM_ACK, json!({"id": "m-1"})).await.unwrap();
    // What it gave whole is read: unread only, nothing is left, and the thread says so.
    let unread = agent.request(method::MUX_TEAM_INBOX, json!({})).await.unwrap();
    assert_eq!(unread["messages"], json!([]), "{unread}");
    let threads = c.request(method::MUX_INBOX_THREADS, json!({"sessionId": id})).await.unwrap();
    assert_eq!(threads["threads"][0]["unread"], 0, "{threads}");
    let missing = agent.request(method::MUX_TEAM_READ, json!({"id": "m-404"})).await;
    assert!(missing.is_err_and(|e| e.contains("inbox.not_found")));

    // Another chat's agent reads its own inbox, never this one.
    let theirs = owner_agent.request(method::MUX_TEAM_INBOX, json!({"unreadOnly": false})).await;
    assert_eq!(theirs.unwrap()["messages"], json!([]));
    let refused = owner_agent.request(method::MUX_TEAM_READ, json!({"id": "m-1"})).await;
    assert!(refused.is_err_and(|e| e.contains("inbox.not_found")));
    // A connection of no chat (the person's) is told team messaging is off, as before.
    let person = c.request(method::MUX_TEAM_INBOX, json!({})).await;
    assert!(person.is_err_and(|e| e.contains("team messaging is disabled")));
}

/// A chat whose agent was started with no cmux tools (`ACPMUX_AGENT_TOOLS=0`) cannot read an inbox:
/// another agent's message queues for it as before the inbox and runs as a turn whose prompt is
/// every word of it, never a notice of a thread it could not open.
#[tokio::test]
async fn a_chat_whose_agent_has_no_tools_gets_its_messages_as_prompts() {
    let env = BTreeMap::from([("ACPMUX_AGENT_TOOLS".to_owned(), "0".to_owned())]);
    let (hub, mut c) = setup_env(PermissionPolicy::ApproveAll, env).await;
    let id = new_session(&mut c, "toolless").await;
    let lane = new_session(&mut c, "lane-a").await;
    // Its agent starts, with no tools.
    c.request(method::SESSION_PROMPT, prompt(&id, "hello", None)).await.unwrap();
    let mut lane_agent = agent_of(&hub, &lane).await;
    let text = "landed #27133; the full message follows on more lines\nsecond line";
    let p = json!({"sessionId": id, "prompt": [{"type": "text", "text": text}],
        "_meta": {"acpmux": {"promptId": "m-1"}}});
    lane_agent.send(method::SESSION_PROMPT, p).await;
    let accepted =
        lane_agent.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "m-1").await;
    assert_ne!(accepted["inbox"], true, "{accepted}");
    until(&hub, &id, "the message's own turn", |p| p.iter().any(|m| m["text"] == text)).await;
    assert!(notices(&hub, &id).is_empty(), "no notice of a thread it cannot read");
    let threads = c.request(method::MUX_INBOX_THREADS, json!({"sessionId": id})).await.unwrap();
    assert_eq!(threads["threads"], json!([]), "{threads}");
}

/// Messages the inbox took while the chat's agent had cmux's tools still reach an agent that has
/// none: whether a notice can be read is decided as it goes, by the agent last launched and the
/// profile the chat spawns with now, so one sent to an agent without the tools carries each
/// message whole (router review: a respawn under `--strict-mcp-config`, or a restart's first
/// spawn, would have got the 120-character previews only).
#[tokio::test]
async fn a_notice_to_an_agent_that_lost_its_tools_carries_each_message_whole() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "coord").await;
    let lane = new_session(&mut c, "lane-a").await;
    for s in [&id, &lane] {
        c.request(method::SESSION_PROMPT, prompt(s, "hello", None)).await.unwrap();
    }
    let order =
        format!("Merged; next, {}", "a long standing order that a preview cuts. ".repeat(5));
    // Its profile now starts agents with no cmux tools; the agent it runs still has them, so the
    // inbox takes the message, and its next agent is the one that reads it.
    let mut cfg = hub.config.write().await;
    let fake = cfg.harnesses.get_mut("fake").unwrap();
    fake.env.insert("ACPMUX_AGENT_TOOLS".into(), "0".into());
    drop(cfg);
    let mut lane_agent = agent_of(&hub, &lane).await;
    let p = json!({"sessionId": id, "prompt": [{"type": "text", "text": order}],
        "_meta": {"acpmux": {"promptId": "m-1", "class": "blocker"}}});
    lane_agent.send(method::SESSION_PROMPT, p).await;
    let accepted =
        lane_agent.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "m-1").await;
    assert_eq!(accepted["inbox"], true, "{accepted}");
    // A blocker wakes the chat: its notice is whole.
    until(&hub, &id, "the notice", |p| {
        p.iter().any(|m| m["_meta"]["provenance"]["kind"] == "inbox_notice")
    })
    .await;
    let notice = notices(&hub, &id)[0]["text"].as_str().unwrap().to_owned();
    assert!(notice.contains(&order), "{notice}");
    assert!(notice.contains("lane-a"), "{notice}");
}
