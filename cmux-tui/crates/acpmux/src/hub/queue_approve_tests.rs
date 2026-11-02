//! A prompt that waits for the owner never reaches the agent by a flag a race left on it (review
//! of #26747): its author's Send now is refused under the lock that would make it a steer, a steer
//! flag forced on it lets nothing out (`queue_turn`, `take_queued`), and once approved it runs in
//! its place as a queued prompt, never as a steer.

use super::*;
use crate::config::{Config, StoreMode};
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

/// The owner at this machine: approves under no rule stricter than the prompt's own.
const OWNER: Approver<'static> =
    Approver { control: Control::Local, trust_gate: false, device: None };

/// The first message on `out` that `pred` matches.
async fn until(out: &mut mpsc::Receiver<String>, pred: impl Fn(&Value) -> bool) -> Value {
    loop {
        let line = tokio::time::timeout(Duration::from_secs(30), out.recv()).await;
        let line = line.expect("timed out").expect("connection closed");
        let value: Value = serde_json::from_str(&line).unwrap();
        if pred(&value) {
            return value;
        }
    }
}

fn user_messages(hub: &Hub, session: &str, prompt_id: &str) -> Vec<Value> {
    let events = hub.events(session, 0, 10_000).unwrap();
    let mine = |e: &&EventRecord| e.kind == "user_message" && e.msg["promptId"] == prompt_id;
    events.iter().filter(mine).map(|e| e.msg.clone()).collect()
}

/// Queue insertion must enforce the cap itself: several callers can all have observed room
/// before any inserts. Exercise that commit point directly, with its count reservation, rather
/// than depending on an unlikely scheduler interleaving between two RPC preflight checks.
#[tokio::test]
async fn concurrent_enqueues_reserve_only_one_last_held_slot() {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let (tx, rx) = mpsc::channel(8);
    let (out_tx, mut out) = mpsc::channel(4096);
    tokio::spawn(crate::server::serve_connection_with(
        hub.clone(),
        rx,
        out_tx,
        crate::server::Origin::Local,
    ));
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": []});
    tx.send(Message::request(1, method::SESSION_NEW, new).to_line()).await.unwrap();
    let created = until(&mut out, |v| v["id"] == 1).await;
    let session = hub.resolve(created["result"]["sessionId"].as_str().unwrap()).unwrap();
    let guest = json!({"kind": "person_message", "from": "guest:cap", "fromName": "Cy",
        "approval": "owner"});
    for i in 0..MAX_HELD_PER_AUTHOR - 1 {
        insert(&hub, &session, &format!("g-{i}"), Some(&guest));
    }
    let contenders = 8;
    let start = Arc::new(std::sync::Barrier::new(contenders));
    let mut tasks = Vec::new();
    for i in 0..contenders {
        let (hub, session, guest, start) =
            (hub.clone(), session.clone(), guest.clone(), start.clone());
        tasks.push(tokio::task::spawn_blocking(move || {
            start.wait();
            insert(&hub, &session, &format!("race-{i}"), Some(&guest));
        }));
    }
    for task in tasks {
        task.await.unwrap();
    }
    let queued = session.queue();
    assert_eq!(queued.len(), MAX_HELD_PER_AUTHOR, "only one contender fits");
    assert_eq!(session.queued.load(Ordering::SeqCst), MAX_HELD_PER_AUTHOR as u64);
    let logged = hub.events(&session.id, 0, 10_000).unwrap();
    assert_eq!(logged.iter().filter(|e| e.kind == "queued").count(), MAX_HELD_PER_AUTHOR);
    assert_eq!(queued.iter().filter(|q| q.prompt_id.starts_with("race-")).count(), 1);

    // Approval frees an author's held slot, while another author and the owner have their own
    // admission. None of these direct enqueues has a task that could drain the queue meanwhile.
    hub.approve_queued(&session, &queued[0].prompt_id, &queued[0].turn_id, 0, &OWNER).unwrap();
    insert(&hub, &session, "after-approval", Some(&guest));
    let mut other = guest.clone();
    other["from"] = json!("guest:other");
    insert(&hub, &session, "other-author", Some(&other));
    insert(&hub, &session, "owner", None);
    assert_eq!(session.queue().len(), MAX_HELD_PER_AUTHOR + 3);
    assert_eq!(session.queued.load(Ordering::SeqCst), (MAX_HELD_PER_AUTHOR + 3) as u64);
    hub.shutdown_all().await;
}

fn insert(hub: &Hub, session: &Arc<Session>, id: &str, provenance: Option<&Value>) {
    let blocks = [json!({"type": "text", "text": "waiting"})];
    let replaced = std::sync::OnceLock::new();
    let slot = Slot {
        text: "waiting",
        blocks: &blocks,
        display_parts: None,
        client: "cap-test",
        prompt_id: id,
        control: Control::Local,
        trust_gate: false,
        interrupt: false,
        interrupt_turn: None,
        provenance,
        agent: None,
        class: None,
        supersede: None,
        full_access_device: None,
        replaced: &replaced,
        no_queue: false,
        admitted: false,
        after_turn: false,
    };
    session.queued.fetch_add(1, Ordering::SeqCst);
    let limits = super::super::queue_admission::QueueLimits { prompts: None, bytes: None };
    // As `session/prompt` does: a refusal counts the prompt back out of the session's total.
    let _ = hub.enqueue_or_refuse(session, &slot, id, limits);
}

#[tokio::test]
async fn a_held_prompt_with_a_steer_flag_never_reaches_the_agent() {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "env": {"FAKE_CLAUDE_STEER": "1"}}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let (tx, rx) = mpsc::channel(8);
    let (out_tx, mut out) = mpsc::channel(4096);
    let local = crate::server::Origin::Local;
    tokio::spawn(crate::server::serve_connection_with(hub.clone(), rx, out_tx, local));
    let send = |id: i64, m: &str, params: Value| Message::request(id, m, params).to_line();
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": []});
    tx.send(send(1, method::SESSION_NEW, new)).await.unwrap();
    let created = until(&mut out, |v| v["id"] == 1).await;
    let session = hub.resolve(created["result"]["sessionId"].as_str().unwrap()).unwrap();
    let prompt = |id: &str, text: &str| {
        json!({"sessionId": session.id, "prompt": [{"type": "text", "text": text}],
               "_meta": {"acpmux": {"promptId": id}}})
    };
    tx.send(send(2, method::SESSION_PROMPT, prompt("p-run", "until-cancel"))).await.unwrap();
    until(&mut out, |v| v.pointer("/params/update/content/text") == Some(&json!("running"))).await;
    let guest = json!({"id": "guest:k3x9", "name": "Cy", "approval": "owner"});
    let mut held = prompt("g-1", "guest words");
    held["_meta"]["acpmux"]["author"] = guest.clone();
    held["_meta"]["acpmux"]["steer"] = json!(true);
    tx.send(send(3, method::SESSION_PROMPT, held)).await.unwrap();
    until(&mut out, |v| {
        v["method"] == "_acpmux/prompt_accepted" && v["params"]["promptId"] == "g-1"
    })
    .await;

    // Its author's Send now into the running turn: refused under the lock that would steer it.
    let now = json!({"sessionId": session.id, "promptId": "g-1", "op": "send_now",
                     "_meta": {"acpmux": {"author": guest}}});
    let refused = hub.queue_edit(&session, &now, Control::Local, false, None).await.unwrap_err();
    assert_eq!(refused.data.unwrap()["reason"], "queue.awaiting_owner");

    // A steer flag forced on it, as a lost race would leave it: nothing lets it out.
    for q in session.queue.lock().unwrap().iter_mut().filter(|q| q.prompt_id == "g-1") {
        q.steer = true;
    }
    session.queue_moved.notify_waiters();
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(user_messages(&hub, &session.id, "g-1").is_empty(), "it reached the agent");
    assert!(session.queue().iter().any(|q| q.prompt_id == "g-1" && q.awaiting_owner));

    // Approved, it runs once the turn ends, in its place and not as a steer.
    let turn = session.queue().iter().find(|q| q.prompt_id == "g-1").unwrap().turn_id.clone();
    hub.approve_queued(&session, "g-1", &turn, 0, &OWNER).unwrap();
    hub.cancel(&session).await.unwrap();
    let answer = until(&mut out, |v| v["id"] == 3).await;
    assert!(answer.get("error").is_none(), "{answer}");
    let ran = user_messages(&hub, &session.id, "g-1");
    assert_eq!(ran.len(), 1, "{ran:?}");
    assert_ne!(ran[0]["steer"], true, "it went in as a steer: {:?}", ran[0]);
}

/// A bundle's log in more than one `events/*.ndjson` segment, as import reads it (every segment,
/// in name order): a prompt queued in a later segment still waits for the owner, so the move is
/// refused (review of #26747: only `000001.ndjson` was read, and a held prompt in a later segment
/// went to a target that would run it unapproved).
#[test]
fn a_held_prompt_in_a_later_log_segment_refuses_the_move() {
    let dir = std::env::temp_dir().join(format!("acpmux-held-segments-{}", uuid::Uuid::now_v7()));
    let events = dir.join("events");
    std::fs::create_dir_all(&events).unwrap();
    let line = |seq: u64, kind: &str, msg: Value| {
        let e =
            EventRecord { seq, at: 1, dir: "mux".into(), kind: kind.into(), msg, host_seq: None };
        serde_json::to_string(&e).unwrap() + "\n"
    };
    let first = line(1, "created", json!({}));
    std::fs::write(events.join("000001.ndjson"), first).unwrap();
    let held = json!({"promptId": "g-1", "turnId": "t-1", "text": "guest words",
                      "awaitingOwner": true, "revision": 0});
    std::fs::write(events.join("000002.ndjson"), line(2, "queued", held)).unwrap();
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Memory;
    let hub = Hub::new(cfg.clone(), crate::store::open(&cfg.store, &dir).unwrap());
    let refused = hub.held_prompts(&dir).expect_err("a held prompt in segment 2 was let through");
    assert_eq!(refused.data.unwrap()["promptIds"], json!(["g-1"]));
    // Approved at its revision in a third segment, it no longer holds the move; still waiting
    // for its place, it is named, so that only a receiver that lists queue approval takes it
    // (review of #28859).
    let approved = json!({"promptId": "g-1", "turnId": "t-1", "revision": 0, "approvedAt": 2});
    std::fs::write(events.join("000003.ndjson"), line(3, "queue_approved", approved)).unwrap();
    assert_eq!(hub.held_prompts(&dir).expect("an approved prompt holds nothing"), ["g-1"]);
    // Once it ran, nothing waits.
    let ran = json!({"promptId": "g-1", "turnId": "t-1"});
    std::fs::write(events.join("000004.ndjson"), line(4, "turn_started", ran)).unwrap();
    assert!(hub.held_prompts(&dir).expect("a prompt that ran holds nothing").is_empty());
    let _ = std::fs::remove_dir_all(&dir);
}

/// The owner declines a held prompt in the instant after it entered the queue, before its
/// `queued` record is logged (review of #26747: the record was written after the queue's lock was
/// released, so the decline's `queue_declined` and `queue_removed` could come first; a restart then
/// restored the declined prompt and its resend lost the decline). The decline waits for the
/// queue's lock, at most half a second here, while `queued` is logged.
#[tokio::test]
async fn a_decline_racing_the_queued_record_stays_declined_after_a_restart() {
    let dir = std::env::temp_dir().join(format!("acpmux-decline-race-{}", uuid::Uuid::now_v7()));
    let durable = || {
        let mut cfg: Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", FAKE]}},
            "defaultHarness": "fake"
        }))
        .unwrap();
        cfg.store.mode = StoreMode::Local;
        let store = crate::store::open(&cfg.store, &dir).unwrap();
        Hub::new(cfg, store)
    };
    let hub = durable();
    let (tx, rx) = mpsc::channel(8);
    let (out_tx, mut out) = mpsc::channel(4096);
    tokio::spawn(crate::server::serve_connection_with(
        hub.clone(),
        rx,
        out_tx,
        crate::server::Origin::Local,
    ));
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": []});
    tx.send(Message::request(1, method::SESSION_NEW, new).to_line()).await.unwrap();
    let created = until(&mut out, |v| v["id"] == 1).await;
    let id = created["result"]["sessionId"].as_str().unwrap().to_owned();
    let session = hub.resolve(&id).unwrap();
    let guest = json!({"kind": "person_message", "from": "guest:race", "fromName": "Cy",
        "approval": "owner"});
    let decline = Arc::new(StdMutex::new(None));
    let (h, s, slot) = (hub.clone(), session.clone(), decline.clone());
    *hub.queued_log_seam.lock().unwrap() = Some(Box::new(move || {
        let (done_tx, done_rx) = std::sync::mpsc::channel();
        let task = std::thread::spawn(move || {
            let declined = h.decline_queued(&s, "g-1");
            let _ = done_tx.send(());
            declined
        });
        let _ = done_rx.recv_timeout(Duration::from_millis(500));
        *slot.lock().unwrap() = Some(task);
    }));
    insert(&hub, &session, "g-1", Some(&guest));
    let task = decline.lock().unwrap().take().expect("the seam ran");
    task.join().unwrap().expect("the owner's decline");
    let logged = hub.events(&id, 0, 10_000).unwrap();
    let at = |kind: &str| logged.iter().position(|e| e.kind == kind && e.msg["promptId"] == "g-1");
    assert!(at("queued") < at("queue_declined"), "the decline was logged before the prompt");
    hub.shutdown_all().await;
    drop((tx, out, session, hub));

    let hub = durable();
    hub.resume_queues();
    let session = hub.resolve(&id).unwrap();
    assert!(session.queue().is_empty(), "a restart brought the declined prompt back");
    let resend = hub.logged_prompt(&session, "g-1").expect("the log knows it");
    let reason = resend.expect_err("a resend is told it was declined").data.unwrap();
    assert_eq!(reason["reason"], "queue.declined");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}

/// The owner approves a held prompt from the Web: it runs under the stricter rules of both, the
/// Web's control and trust gate and no Full-access machine the approver's request did not name,
/// logged with the approval so a restart restores them (review of #26747).
#[tokio::test]
async fn an_approval_keeps_the_approvers_rules_across_a_restart() {
    let dir = std::env::temp_dir().join(format!("acpmux-approver-{}", uuid::Uuid::now_v7()));
    let durable = || {
        let mut cfg: Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", FAKE]}},
            "defaultHarness": "fake"
        }))
        .unwrap();
        cfg.store.mode = StoreMode::Local;
        let store = crate::store::open(&cfg.store, &dir).unwrap();
        Hub::new(cfg, store)
    };
    let hub = durable();
    let (tx, rx) = mpsc::channel(8);
    let (out_tx, mut out) = mpsc::channel(4096);
    tokio::spawn(crate::server::serve_connection_with(
        hub.clone(),
        rx,
        out_tx,
        crate::server::Origin::Local,
    ));
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": []});
    tx.send(Message::request(1, method::SESSION_NEW, new).to_line()).await.unwrap();
    let created = until(&mut out, |v| v["id"] == 1).await;
    let id = created["result"]["sessionId"].as_str().unwrap().to_owned();
    let session = hub.resolve(&id).unwrap();
    let guest = json!({"kind": "person_message", "from": "guest:web", "fromName": "Cy",
        "approval": "owner"});
    insert(&hub, &session, "g-1", Some(&guest));
    let turn = session.queue()[0].turn_id.clone();
    let web = Approver { control: Control::Web, trust_gate: true, device: Some("phone-1") };
    hub.approve_queued(&session, "g-1", &turn, 0, &web).unwrap();
    let rules =
        |q: &QueuedPrompt| (q.run.control, q.run.trust_gate, q.run.full_access_device.clone());
    assert_eq!(rules(&session.queue()[0]), (Control::Web, true, None));
    let logged = hub.events(&id, 0, 10_000).unwrap();
    let approved = logged.iter().find(|e| e.kind == "queue_approved").expect("logged");
    assert_eq!(
        (&approved.msg["control"], &approved.msg["trustGate"]),
        (&json!("web"), &json!(true))
    );
    hub.shutdown_all().await;
    drop((tx, out, session, hub));

    // Restored, it is approved and keeps them. The queue is read without starting its tasks.
    let hub = durable();
    let session = hub.resolve(&id).unwrap();
    hub.restore_queue(&session);
    let queue = session.queue();
    assert_eq!(queue.len(), 1, "{queue:?}");
    assert!(!queue[0].awaiting_owner, "the approval was lost");
    assert_eq!(rules(&queue[0]), (Control::Web, true, None));
    drop(queue);
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}

/// A hub whose session store is memory, for tests that queue prompts directly.
fn memory_hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

fn held_guest() -> Value {
    json!({"kind": "person_message", "from": "guest:aside", "fromName": "Cy", "approval": "owner"})
}

/// A prompt that waits for the owner wakes nothing until approved, as a prompt a failed turn
/// holds does: a hibernated child with only such a prompt frees its parent's width slot (review
/// of #26747: `waking_children` subtracted only held prompts, so it took a slot).
#[tokio::test]
async fn a_child_with_only_an_owner_held_prompt_takes_no_width_slot() {
    let hub = memory_hub();
    let new = |subsession| crate::hub::NewRequest {
        cwd: Some(std::env::temp_dir()),
        subsession,
        ..crate::hub::NewRequest::default()
    };
    let parent = hub.new_session(new(None)).await.unwrap();
    let link = crate::store::SubsessionLink {
        started_by: parent.id.clone(),
        short_name: "a".into(),
        depth: 1,
        offered: false,
    };
    let child = hub.new_session(new(Some(link))).await.unwrap();
    hub.set_status(&child, SessionStatus::Idle);
    assert_eq!(hub.width_used(&parent.id), 0, "a hibernated child frees its slot");
    insert(&hub, &child, "g-1", Some(&held_guest()));
    assert!(child.queue()[0].awaiting_owner);
    assert_eq!(hub.width_used(&parent.id), 0, "an owner-held prompt woke the child");
    assert!(hub.waking_children(&parent.id).is_empty());
    hub.shutdown_all().await;
}

/// A prompt that waits for the owner holds no other agent's notice back from the running turn
/// (review of #26747: `prompt_waits` passed only held prompts, so a guest's prompt kept every
/// notice out of the turn until the owner answered).
#[tokio::test]
async fn an_owner_held_prompt_does_not_hold_back_a_notice() {
    let hub = memory_hub();
    let req = crate::hub::NewRequest { cwd: Some(std::env::temp_dir()), ..Default::default() };
    let session = hub.new_session(req).await.unwrap();
    assert!(!super::super::inbox::notice_held(&session), "an empty queue holds nothing back");
    insert(&hub, &session, "g-1", Some(&held_guest()));
    assert!(session.queue()[0].awaiting_owner);
    assert!(!super::super::inbox::notice_held(&session), "an owner-held prompt held a notice");
    // The owner's own waiting prompt still does.
    insert(&hub, &session, "owner", None);
    assert!(super::super::inbox::notice_held(&session));
    hub.shutdown_all().await;
}

/// Round-4 review of #28859: `to.host` names a peer whose handshake listed queue approval, but
/// the daemon the move client actually hands the bundle to (`to.socket`) is an older build that
/// ignores `queue_approved` and would run the approved prompt under its sender's rules alone. A
/// peer record says nothing of that receiver: the move is refused unless the client vouches for
/// the receiving connection's own `initialize` (`transfer_out.rs`, `cli/run/transfer.rs`).
#[tokio::test]
async fn a_capable_host_name_fronting_an_older_receiver_does_not_move_an_approved_prompt() {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let (tx, rx) = mpsc::channel(8);
    let (out_tx, mut out) = mpsc::channel(4096);
    let local = crate::server::Origin::Local;
    tokio::spawn(crate::server::serve_connection_with(hub.clone(), rx, out_tx, local));
    let send = |id: i64, m: &str, params: Value| Message::request(id, m, params).to_line();
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": []});
    tx.send(send(1, method::SESSION_NEW, new)).await.unwrap();
    let created = until(&mut out, |v| v["id"] == 1).await;
    let session = hub.resolve(created["result"]["sessionId"].as_str().unwrap()).unwrap();
    let prompt = |id: &str, text: &str| {
        json!({"sessionId": session.id, "prompt": [{"type": "text", "text": text}],
               "_meta": {"acpmux": {"promptId": id}}})
    };
    tx.send(send(2, method::SESSION_PROMPT, prompt("p-run", "until-cancel"))).await.unwrap();
    until(&mut out, |v| v.pointer("/params/update/content/text") == Some(&json!("running"))).await;
    let mut held = prompt("g-1", "guest words");
    held["_meta"]["acpmux"]["author"] =
        json!({"id": "guest:k3x9", "name": "Cy", "approval": "owner"});
    tx.send(send(3, method::SESSION_PROMPT, held)).await.unwrap();
    until(&mut out, |v| {
        v["method"] == "_acpmux/prompt_accepted" && v["params"]["promptId"] == "g-1"
    })
    .await;
    let turn = session.queue().iter().find(|q| q.prompt_id == "g-1").unwrap().turn_id.clone();
    hub.approve_queued(&session, "g-1", &turn, 0, &OWNER).unwrap();

    // A peer that listed queue approval at its last handshake...
    let (ptx, _prx) = mpsc::channel(8);
    let capable = crate::peer::Peer::new("capable", "ws://127.0.0.1:9", None, None, ptx);
    capable.seed_features(&[crate::author::QUEUE_APPROVAL_FEATURE]);
    hub.peers.lock().unwrap().insert("capable".to_owned(), capable);
    // ...named for a move whose bundle goes to another daemon's socket (an older build).
    let begin = json!({"sessionId": session.id, "interrupt": true,
                       "to": {"socket": "/tmp/acpmux-older-receiver.sock", "host": "capable"}});
    let result = hub.transfer_request("_acpmux/transfer_begin", &begin).await;
    if let Ok(bundle) = &result {
        let abort = json!({"sessionId": session.id, "transferId": bundle["transferId"]});
        hub.transfer_request("_acpmux/transfer_abort", &abort).await.unwrap();
    }
    let refused = result.expect_err("a peer record vouched for the receiver it does not front");
    assert_eq!(refused.data.as_ref().unwrap()["reason"], "transfer.approved_prompts");
    assert_eq!(refused.data.unwrap()["promptIds"], json!(["g-1"]));

    // A client that checks its receiver's own `initialize` gets the bundle, which names the
    // prompt (`cli/run/transfer.rs` `receiver_takes` hands it on only to a daemon that lists
    // queue approval)...
    let mut gated = begin.clone();
    gated["gatesQueueApproval"] = json!(true);
    let manifest = hub.transfer_request("_acpmux/transfer_begin", &gated).await.unwrap();
    assert_eq!(manifest["approvedWaiting"], json!(["g-1"]), "{manifest}");
    let older = json!({"_meta": {"acpmux": {"features": ["queueEdit", "sessionTransfer"]}}});
    let current =
        json!({"_meta": {"acpmux": {"features": [crate::author::QUEUE_APPROVAL_FEATURE]}}});
    let e = crate::cli::run::transfer::receiver_takes(&manifest, &older).unwrap_err();
    let e = e.downcast_ref::<crate::client::DaemonError>().expect("a daemon-shaped refusal");
    assert_eq!(e.0.data.as_ref().unwrap()["reason"], "transfer.approved_prompts");
    crate::cli::run::transfer::receiver_takes(&manifest, &current).expect("a current receiver");
    // ...and a receiver that does not understand queue approval refuses it itself.
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let receiver = Hub::new(cfg, store);
    receiver.queue_approval_off.store(true, std::sync::atomic::Ordering::SeqCst);
    let receive = json!({"manifest": manifest});
    let refused =
        receiver.transfer_request("_acpmux/transfer_receive", &receive).await.unwrap_err();
    assert_eq!(refused.data.as_ref().unwrap()["reason"], "transfer.approved_prompts");
    let abort = json!({"sessionId": session.id, "transferId": manifest["transferId"]});
    hub.transfer_request("_acpmux/transfer_abort", &abort).await.unwrap();
    hub.shutdown_all().await;
}
