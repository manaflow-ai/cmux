//! A guest's prompt waits for the owner (Share with guest, hq#4766, `hub/queue_approve.rs`): an
//! author with `approval: "owner"` queues it, never steered in, and the queue runs past it until
//! the owner approves it at the revision they saw (`_acpmux/queue_approve`) or declines it
//! (`_acpmux/queue_decline`, its `session/prompt` answering `queue.declined`). Only the owner
//! answers; the guest edits (a new revision, still waiting) or removes it, and nothing else of
//! theirs runs it. A restart keeps all of it.

use super::prompt_provenance::{Client, by, hub, hub_env, prompt, reason};
use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn guest() -> Value {
    json!({"id": "guest:k3x9", "name": "Cy", "approval": "owner"})
}

/// The guest's prompt `id`.
fn held(session: &str, id: &str, text: &str) -> Value {
    by(prompt(session, id, text, None), Some(&guest()))
}

fn answer(hub: &Arc<Hub>, session: &str, id: &str, revision: Option<u64>) -> Value {
    let mut params = json!({"sessionId": session, "promptId": id, "_meta": {"acpmux": {}}});
    if let Some(revision) = revision {
        params["revision"] = json!(revision);
        let records = hub.events(session, 0, 10_000).unwrap();
        params["turnId"] = records
            .iter()
            .rev()
            .find(|e| e.kind == "queued" && e.msg["promptId"] == id)
            .map(|e| e.msg["turnId"].clone())
            .unwrap_or(Value::Null);
    }
    params
}

fn edit(session: &str, id: &str, op: &str) -> Value {
    let params = json!({"sessionId": session, "promptId": id, "op": op, "text": "my rewrite",
                        "index": 0, "_meta": {"acpmux": {}}});
    by(params, Some(&guest()))
}

/// The session summary's queue.
fn queue(hub: &Arc<Hub>, session: &str) -> Vec<Value> {
    let summary = hub.session_summary(&hub.resolve(session).unwrap());
    summary["queue"].as_array().cloned().unwrap_or_default()
}

async fn ran(c: &mut Client, session: &str, id: &str) -> bool {
    c.records(session, "user_message").await.iter().any(|m| m["promptId"] == id)
}

/// Its steer asks to go into the running turn; it waits for the owner instead, the owner's own
/// prompt runs past it, and the owner's approval at its revision runs it under its author.
#[tokio::test]
async fn a_guests_prompt_waits_while_the_owners_run_past_it() {
    let hub = hub_env(json!({"FAKE_CLAUDE_STEER": "1"}));
    let mut c = Client::open(&hub);
    let session = c.new_session(json!({"harness": "fake"})).await;
    c.busy(&session).await;
    let mut steer = held(&session, "g-1", "guest words");
    steer["_meta"]["acpmux"]["steer"] = json!(true);
    steer["_meta"]["acpmux"]["interrupt"] = json!(true);
    let waiting = c.queue(steer.clone()).await;
    // A resend of the same id waits for the first: no second copy.
    let again = c.send("session/prompt", steer).await;
    let dup = c.until(|v| v["method"] == "_acpmux/prompt_accepted").await;
    assert_eq!(dup["params"]["duplicate"], true, "{dup}");
    let listed = queue(&hub, &session);
    assert_eq!(listed.len(), 1, "{listed:?}");
    assert_eq!(listed[0]["awaitingOwner"], true, "{listed:?}");
    assert_eq!(listed[0]["revision"], 0, "{listed:?}");
    let owner = c.queue(prompt(&session, "p-owner", "owner words", None)).await;
    c.cancel(&session).await;
    assert!(c.reply_to(owner).await.get("error").is_none());
    assert!(!ran(&mut c, &session, "g-1").await, "it ran before the owner approved it");
    let queued = c.records(&session, "queued").await;
    let queued = queued.iter().find(|m| m["promptId"] == "g-1").expect("its queued record");
    assert_eq!((&queued["awaitingOwner"], &queued["revision"]), (&json!(true), &json!(0)));

    let authored = by(answer(&hub, &session, "g-1", Some(0)), Some(&guest()));
    let refused = c.reply("_acpmux/queue_approve", authored).await;
    assert_eq!(reason(&refused), "queue.owner_only", "{refused}");
    let stale = c.reply("_acpmux/queue_approve", answer(&hub, &session, "g-1", Some(1))).await;
    assert_eq!(reason(&stale), "queue.stale", "{stale}");
    c.call("_acpmux/queue_approve", answer(&hub, &session, "g-1", Some(0))).await;
    // Both answers, in either order.
    for _ in 0..2 {
        let done = c.until(|v| [waiting, again].iter().any(|id| v.get("id") == Some(&json!(id))));
        assert!(done.await.get("error").is_none());
    }
    let message = c.user_message(&session, "g-1").await;
    assert_eq!(message.pointer("/_meta/provenance/from"), Some(&json!("guest:k3x9")));
    assert_ne!(message["steer"], true, "it went in as a steer: {message}");
    let late = c.reply("_acpmux/queue_decline", answer(&hub, &session, "g-1", None)).await;
    assert_eq!(reason(&late), "queue.not_found", "{late}");
    assert_eq!(late.pointer("/error/data/decided"), Some(&json!("approved")), "{late}");
}

#[tokio::test]
async fn a_declined_prompt_answers_declined_and_never_runs() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let session = c.new_session(json!({"harness": "fake"})).await;
    // Nothing runs: it waits for the owner all the same.
    let waiting = c.queue(held(&session, "g-1", "guest words")).await;
    let authored = by(answer(&hub, &session, "g-1", None), Some(&guest()));
    let refused = c.reply("_acpmux/queue_decline", authored).await;
    assert_eq!(reason(&refused), "queue.owner_only", "{refused}");
    c.call("_acpmux/queue_decline", answer(&hub, &session, "g-1", None)).await;
    let declined = c.reply_to(waiting).await;
    assert_eq!(reason(&declined), "queue.declined", "{declined}");
    let again = c.reply("_acpmux/queue_approve", answer(&hub, &session, "g-1", Some(0))).await;
    assert_eq!(again.pointer("/error/data/decided"), Some(&json!("declined")), "{again}");
    c.call("session/prompt", prompt(&session, "p-after", "after", None)).await;
    assert!(!ran(&mut c, &session, "g-1").await, "a declined prompt ran");
    assert_eq!(c.records(&session, "queue_declined").await.len(), 1);
}

/// The guest edits (a new revision, still waiting) and removes it; their move, send now and
/// interrupt are refused, the owner's edit too, and their edit once it is approved.
#[tokio::test]
async fn the_guest_edits_or_removes_it_and_nothing_else() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let session = c.new_session(json!({"harness": "fake"})).await;
    c.busy(&session).await;
    c.queue(held(&session, "g-1", "guest words")).await;
    for op in ["move", "send_now", "interrupt"] {
        let value = c.reply("_acpmux/queue_edit", edit(&session, "g-1", op)).await;
        assert_eq!(reason(&value), "queue.awaiting_owner", "{op}: {value}");
    }
    let mut owners = edit(&session, "g-1", "update");
    owners["_meta"]["acpmux"] = json!({});
    assert_eq!(reason(&c.reply("_acpmux/queue_edit", owners).await), "queue.not_author");
    assert_eq!(c.call("_acpmux/queue_edit", edit(&session, "g-1", "update")).await["ok"], true);
    let listed = queue(&hub, &session);
    assert_eq!((&listed[0]["awaitingOwner"], &listed[0]["revision"]), (&json!(true), &json!(1)));
    let stale = c.reply("_acpmux/queue_approve", answer(&hub, &session, "g-1", Some(0))).await;
    assert_eq!(reason(&stale), "queue.stale", "the owner approved words they never saw");
    c.call("_acpmux/queue_approve", answer(&hub, &session, "g-1", Some(1))).await;
    let late = c.reply("_acpmux/queue_edit", edit(&session, "g-1", "update")).await;
    assert_eq!(reason(&late), "queue.approved", "{late}");
    let remove = by(answer(&hub, &session, "g-1", None), Some(&guest()));
    assert_eq!(c.call("_acpmux/queue_remove", remove).await["removed"], true);
    let gone = c.reply("_acpmux/queue_decline", answer(&hub, &session, "g-1", None)).await;
    assert_eq!(gone.pointer("/error/data/decided"), Some(&json!("removed")), "{gone}");

    // At most 16 wait for the owner at once, per author.
    for i in 0..16 {
        c.queue(held(&session, &format!("g-cap-{i}"), "more")).await;
    }
    let over = c.reply("session/prompt", held(&session, "g-cap-16", "one more")).await;
    assert_eq!(reason(&over), "queue.too_many_held", "{over}");
    assert_eq!(hub.session_summary(&hub.resolve(&session).unwrap())["queued"], 16);
    let recorded = c.records(&session, "queued").await;
    assert!(
        !recorded.iter().any(|m| m["promptId"] == "g-cap-16"),
        "the refused prompt was recorded"
    );
    c.cancel(&session).await;
}

fn durable_config() -> Config {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "codex"}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Local;
    cfg
}

fn durable(dir: &Path) -> Arc<Hub> {
    let cfg = durable_config();
    let store = acpmux::store::open(&cfg.store, dir).unwrap();
    Hub::new(cfg, store)
}

/// A restart between the guest's edit and the owner's approval keeps it waiting at the new
/// revision; the owner's own prompt still runs past it, and the approval runs it.
#[tokio::test]
async fn a_held_prompt_survives_a_restart_at_its_revision() {
    let dir = std::env::temp_dir().join(format!("acpmux-approval-{}", uuid::Uuid::now_v7()));
    let hub = durable(&dir);
    let mut c = Client::open(&hub);
    let session = c.new_session(json!({"harness": "fake"})).await;
    c.queue(held(&session, "g-1", "guest words")).await;
    c.call("_acpmux/queue_edit", edit(&session, "g-1", "update")).await;
    hub.shutdown_all().await;
    drop(c);
    drop(hub);

    let hub = durable(&dir);
    let mut c = Client::open(&hub);
    hub.resume_queues();
    c.call("session/prompt", prompt(&session, "p-owner", "owner words", None)).await;
    let listed = queue(&hub, &session);
    assert_eq!(listed.len(), 1, "{listed:?}");
    assert_eq!((&listed[0]["awaitingOwner"], &listed[0]["revision"]), (&json!(true), &json!(1)));
    assert!(!ran(&mut c, &session, "g-1").await, "a restart ran it");
    let stale = c.reply("_acpmux/queue_approve", answer(&hub, &session, "g-1", Some(0))).await;
    assert_eq!(reason(&stale), "queue.stale", "{stale}");
    c.call("_acpmux/queue_approve", answer(&hub, &session, "g-1", Some(1))).await;
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    while !ran(&mut c, &session, "g-1").await {
        assert!(std::time::Instant::now() < deadline, "the approved prompt never ran");
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    assert_eq!(c.user_message(&session, "g-1").await["text"], "my rewrite");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}

/// An approval belongs to the queued prompt it answered, not to its client-chosen id: after the
/// approved prompt ran and the daemon restarted twice, a new guest prompt reusing that id at
/// revision 0 still waits for the owner (review of #26747).
#[tokio::test]
async fn an_approval_never_carries_over_to_a_prompt_reusing_its_id() {
    let dir = std::env::temp_dir().join(format!("acpmux-approval-{}", uuid::Uuid::now_v7()));
    let hub = durable(&dir);
    let mut c = Client::open(&hub);
    let session = c.new_session(json!({"harness": "fake"})).await;
    let first = c.queue(held(&session, "g-1", "first words")).await;
    c.call("_acpmux/queue_approve", answer(&hub, &session, "g-1", Some(0))).await;
    assert!(c.reply_to(first).await.get("error").is_none());
    hub.shutdown_all().await;
    drop(c);
    drop(hub);

    // A new daemon's ledger has forgotten the id: the same id is a new prompt.
    let hub = durable(&dir);
    let mut c = Client::open(&hub);
    hub.resume_queues();
    c.queue(held(&session, "g-1", "second words")).await;
    hub.shutdown_all().await;
    drop(c);
    drop(hub);

    let hub = durable(&dir);
    let mut c = Client::open(&hub);
    hub.resume_queues();
    c.call("session/prompt", prompt(&session, "p-owner", "owner words", None)).await;
    let listed = queue(&hub, &session);
    assert_eq!(listed.len(), 1, "{listed:?}");
    assert_eq!(listed[0]["awaitingOwner"], true, "the old approval let it run: {listed:?}");
    let ran = c.records(&session, "user_message").await;
    let texts: Vec<&Value> =
        ran.iter().filter(|m| m["promptId"] == "g-1").map(|m| &m["text"]).collect();
    assert_eq!(texts, [&json!("first words")], "{ran:?}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}

/// The owner's approval and the guest's removal race: whichever wins, the log records them in the
/// order the queue changed, so the last decision for the prompt is its removal and a late answer
/// is told `removed` (review of #26747).
#[tokio::test]
async fn approve_and_remove_are_logged_in_the_order_they_happened() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let mut owner = Client::open(&hub);
    let session = c.new_session(json!({"harness": "fake"})).await;
    c.busy(&session).await;
    for i in 0..20 {
        let id = format!("g-race-{i}");
        c.queue(held(&session, &id, "race")).await;
        let remove = by(answer(&hub, &session, &id, None), Some(&guest()));
        let approve =
            owner.send("_acpmux/queue_approve", answer(&hub, &session, &id, Some(0))).await;
        let removed = c.reply("_acpmux/queue_remove", remove).await;
        owner.reply_to(approve).await;
        assert_eq!(removed["result"]["removed"], true, "{removed}");
        let mut decisions = Vec::new();
        for kind in ["queue_approved", "queue_removed"] {
            let page =
                c.call("_acpmux/events", json!({"sessionId": session, "kinds": [kind]})).await;
            for e in page["events"].as_array().unwrap() {
                if e["msg"]["promptId"] == id.as_str() {
                    decisions.push((e["seq"].as_u64().unwrap(), kind));
                }
            }
        }
        decisions.sort();
        assert_eq!(decisions.last().map(|d| d.1), Some("queue_removed"), "{id}: {decisions:?}");
        let late = c.reply("_acpmux/queue_decline", answer(&hub, &session, &id, None)).await;
        assert_eq!(late.pointer("/error/data/decided"), Some(&json!("removed")), "{id}: {late}");
    }
    c.cancel(&session).await;
}

/// The owner declines a prompt a restart restored before its task claims it: the restored task
/// then finds it gone, and its `withdrawn` never replaces the decline, so a client waiting on the
/// prompt id is told `queue.declined` (review of #26747).
#[tokio::test]
async fn a_decline_before_the_restored_task_claims_it_stays_the_answer() {
    let dir = std::env::temp_dir().join(format!("acpmux-approval-{}", uuid::Uuid::now_v7()));
    let hub = durable(&dir);
    let mut c = Client::open(&hub);
    let session = c.new_session(json!({"harness": "fake"})).await;
    c.queue(held(&session, "g-1", "guest words")).await;
    hub.shutdown_all().await;
    drop(c);
    drop(hub);

    let hub = durable(&dir);
    let mut c = Client::open(&hub);
    // Reading the chat's log restores its queue (a stale approval changes nothing).
    let stale = c.reply("_acpmux/queue_approve", answer(&hub, &session, "g-1", Some(9))).await;
    assert_eq!(reason(&stale), "queue.stale", "{stale}");
    // Its restored task is spawned, and before it runs (nothing is awaited in between on this
    // test's one thread) the owner declines the prompt: the task then finds it gone.
    hub.resume_queues();
    hub.decline_queued(&hub.resolve(&session).unwrap(), "g-1").unwrap();
    c.call("session/prompt", prompt(&session, "p-owner", "owner words", None)).await;
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    let mut resend = held(&session, "g-1", "guest words");
    resend["_meta"]["acpmux"]["resend"] = json!(true);
    let answer = c.reply("session/prompt", resend).await;
    assert_eq!(reason(&answer), "queue.declined", "{answer}");
    assert!(!ran(&mut c, &session, "g-1").await, "a declined prompt ran");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}

fn rewrite(session: &str, id: &str, text: &str) -> Value {
    let mut params = edit(session, id, "update");
    params["text"] = json!(text);
    params
}

/// The guest's edits race each other: each is logged under the queue lock that gave it its
/// revision, so the log's `queue_updated` records name their revisions in order (review of
/// #26747: an edit logged after the lock let a slower, older edit land last).
#[tokio::test]
async fn racing_edits_are_logged_in_revision_order() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let mut other = Client::open(&hub);
    let session = c.new_session(json!({"harness": "fake"})).await;
    c.queue(held(&session, "g-1", "guest words")).await;
    for i in 0..20 {
        let a = c.send("_acpmux/queue_edit", rewrite(&session, "g-1", &format!("a{i}"))).await;
        let b = other.send("_acpmux/queue_edit", rewrite(&session, "g-1", &format!("b{i}"))).await;
        c.reply_to(a).await;
        other.reply_to(b).await;
    }
    let page =
        c.call("_acpmux/events", json!({"sessionId": session, "kinds": ["queue_updated"]})).await;
    let mut logged: Vec<(u64, u64)> = page["events"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|e| e["msg"]["promptId"] == "g-1")
        .map(|e| (e["seq"].as_u64().unwrap(), e["msg"]["revision"].as_u64().unwrap()))
        .collect();
    logged.sort();
    let revisions: Vec<u64> = logged.iter().map(|l| l.1).collect();
    assert_eq!(revisions, (1..=40).collect::<Vec<u64>>(), "{logged:?}");
    c.cancel(&session).await;
}

/// A log from before edits were logged under the queue lock may hold an older edit after a newer
/// one. A restart keeps the newer words and revision, so an approval of the newer revision never
/// counts for another edit's words that reuse the older number (review of #26747).
#[tokio::test]
async fn a_restart_never_rolls_an_edit_back_to_an_older_revision() {
    let dir = std::env::temp_dir().join(format!("acpmux-approval-{}", uuid::Uuid::now_v7()));
    let hub = durable(&dir);
    let mut c = Client::open(&hub);
    let session = c.new_session(json!({"harness": "fake"})).await;
    c.queue(held(&session, "g-1", "guest words")).await;
    c.call("_acpmux/queue_edit", rewrite(&session, "g-1", "first rewrite")).await;
    c.call("_acpmux/queue_edit", rewrite(&session, "g-1", "second rewrite")).await;
    hub.shutdown_all().await;
    drop(c);
    drop(hub);

    // The first edit's record again, as a slower writer would have logged it after the second.
    let store = acpmux::store::open(&durable_config().store, &dir).unwrap();
    let records = store.events(&session, 0, usize::MAX).unwrap();
    let first = records
        .iter()
        .find(|e| e.kind == "queue_updated" && e.msg["revision"] == 1)
        .expect("the first edit's record")
        .clone();
    let last = records.last().map_or(0, |r| r.seq);
    store.append(&session, &acpmux::store::EventRecord { seq: last + 1, ..first }).unwrap();
    store.flush().unwrap();
    drop(store);

    let hub = durable(&dir);
    let mut c = Client::open(&hub);
    hub.resume_queues();
    let listed = queue(&hub, &session);
    assert_eq!(listed.len(), 1, "{listed:?}");
    assert_eq!((&listed[0]["awaitingOwner"], &listed[0]["revision"]), (&json!(true), &json!(2)));
    let stale = c.reply("_acpmux/queue_approve", answer(&hub, &session, "g-1", Some(1))).await;
    assert_eq!(reason(&stale), "queue.stale", "{stale}");
    c.call("_acpmux/queue_approve", answer(&hub, &session, "g-1", Some(2))).await;
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    while !ran(&mut c, &session, "g-1").await {
        assert!(std::time::Instant::now() < deadline, "the approved prompt never ran");
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    assert_eq!(c.user_message(&session, "g-1").await["text"], "second rewrite");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}

/// A chat with a prompt that waits for the owner is not moved: the daemon it goes to may be an
/// older build that would run it unapproved. The move is refused `transfer.held_prompts` and the
/// chat stays here, unfrozen; once the owner declines it, the chat moves (review of #26747).
#[tokio::test]
async fn a_chat_is_not_moved_while_a_prompt_waits_for_the_owner() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let session = c.new_session(json!({"harness": "fake"})).await;
    let waiting = c.queue(held(&session, "g-1", "guest words")).await;
    let begin = json!({"sessionId": session, "interrupt": true});
    let refused = c.reply("_acpmux/transfer_begin", begin.clone()).await;
    assert_eq!(reason(&refused), "transfer.held_prompts", "{refused}");
    assert_eq!(refused.pointer("/error/data/promptIds"), Some(&json!(["g-1"])), "{refused}");
    assert!(c.records(&session, "transfer_aborted").await.len() == 1);
    // Still the owner's to answer here, and the chat still takes prompts.
    c.call("session/prompt", prompt(&session, "p-owner", "owner words", None)).await;
    c.call("_acpmux/queue_decline", answer(&hub, &session, "g-1", None)).await;
    assert_eq!(reason(&c.reply_to(waiting).await), "queue.declined");
    let moved = c.call("_acpmux/transfer_begin", begin).await;
    let abort = json!({"sessionId": session, "transferId": moved["transferId"]});
    c.call("_acpmux/transfer_abort", abort).await;
}

/// An approved prompt still waiting for its place (a turn runs) keeps `awaitingOwner` on its
/// `queued` record: an older daemon ignores `queue_approved` and would run it under its sender's
/// rules alone, not the stricter of theirs and the owner's. The move is refused
/// `transfer.approved_prompts` unless its client says it checks the receiving daemon's own
/// `initialize` for queue approval (`gatesQueueApproval`, review of #28859); a host name is
/// never taken to vouch for it.
#[tokio::test]
async fn a_chat_with_an_approved_waiting_prompt_moves_only_to_a_target_that_approves() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let session = c.new_session(json!({"harness": "fake"})).await;
    c.busy(&session).await;
    c.queue(held(&session, "g-1", "guest words")).await;
    c.call("_acpmux/queue_approve", answer(&hub, &session, "g-1", Some(0))).await;
    assert!(!ran(&mut c, &session, "g-1").await, "it ran while the turn was running");
    // Named, but no client check of the receiver: refused all the same. (The refusal
    // gives the chat back, and the interrupted turn's end lets the approved prompt run.)
    let begin = json!({"sessionId": session, "interrupt": true,
                       "to": {"socket": "/tmp/acpmux-nowhere.sock", "host": "no-such-peer"}});
    let refused = c.reply("_acpmux/transfer_begin", begin).await;
    assert_eq!(reason(&refused), "transfer.approved_prompts", "{refused}");
    assert_eq!(refused.pointer("/error/data/promptIds"), Some(&json!(["g-1"])), "{refused}");
    assert_eq!(c.records(&session, "transfer_aborted").await.len(), 1);
}

/// An old card still names the removed incarnation, even when another prompt reuses both its
/// client id and revision after a restart. Missing turn ids must fail closed too.
#[tokio::test]
async fn stale_approval_cannot_approve_a_reused_prompt_id() {
    let dir = std::env::temp_dir().join(format!("acpmux-approval-{}", uuid::Uuid::now_v7()));
    let hub = durable(&dir);
    let mut c = Client::open(&hub);
    let session = c.new_session(json!({"harness": "fake"})).await;
    let first = c.queue(held(&session, "reused", "words the owner saw")).await;
    let old = answer(&hub, &session, "reused", Some(0));
    c.call("_acpmux/queue_remove", by(answer(&hub, &session, "reused", None), Some(&guest())))
        .await;
    c.reply_to(first).await;
    hub.shutdown_all().await;
    drop(c);
    drop(hub);

    let hub = durable(&dir);
    let mut c = Client::open(&hub);
    hub.resume_queues();
    let second = c.queue(held(&session, "reused", "unseen replacement")).await;
    let fresh = answer(&hub, &session, "reused", Some(0));
    assert_ne!(old["turnId"], fresh["turnId"]);
    let stale = c.reply("_acpmux/queue_approve", old).await;
    assert_eq!(reason(&stale), "queue.stale", "{stale}");
    let mut missing = fresh.clone();
    missing.as_object_mut().unwrap().remove("turnId");
    let refused = c.reply("_acpmux/queue_approve", missing).await;
    assert_eq!(refused["error"]["code"], -32602, "{refused}");
    assert!(
        queue(&hub, &session)
            .iter()
            .any(|q| q["promptId"] == "reused" && q["awaitingOwner"] == true)
    );
    assert!(!ran(&mut c, &session, "reused").await);
    c.call("_acpmux/queue_approve", fresh).await;
    assert!(c.reply_to(second).await.get("error").is_none());
    assert_eq!(c.user_message(&session, "reused").await["text"], "unseen replacement");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn declined_resend_stays_an_error_after_restart() {
    let dir = std::env::temp_dir().join(format!("acpmux-approval-{}", uuid::Uuid::now_v7()));
    let hub = durable(&dir);
    let mut c = Client::open(&hub);
    let session = c.new_session(json!({"harness": "fake"})).await;
    // A previous incarnation ran under the same client id. Its successful last_turn cache
    // must not hide the later decline, nor may a forward log scan stop at the old incarnation.
    c.call("session/prompt", prompt(&session, "declined", "old incarnation", None)).await;
    hub.shutdown_all().await;
    drop(c);
    drop(hub);
    let hub = durable(&dir);
    let mut c = Client::open(&hub);
    hub.resume_queues();
    let first = c.queue(held(&session, "declined", "guest words")).await;
    let turn = answer(&hub, &session, "declined", Some(0))["turnId"].clone();
    c.call("_acpmux/queue_decline", answer(&hub, &session, "declined", None)).await;
    assert_eq!(reason(&c.reply_to(first).await), "queue.declined");
    hub.shutdown_all().await;
    drop(c);
    drop(hub);

    let hub = durable(&dir);
    let mut c = Client::open(&hub);
    hub.resume_queues();
    let mut resend = held(&session, "declined", "guest words");
    resend["_meta"]["acpmux"]["resend"] = json!(true);
    // First answers from the durable log, second from the newly populated ledger.
    for _ in 0..2 {
        let reply = c.reply("session/prompt", resend.clone()).await;
        assert_eq!(reason(&reply), "queue.declined", "{reply}");
        assert_eq!(reply["error"]["data"]["turnId"], turn, "{reply}");
    }
    let messages = c.records(&session, "user_message").await;
    assert_eq!(messages.iter().filter(|m| m["promptId"] == "declined").count(), 1);
    assert!(!messages.iter().any(|m| m["promptId"] == "declined" && m["text"] == "guest words"));
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}

/// Inject a completed queue removal immediately after export has copied the log. This is the
/// same snapshot/live-queue split as a decline that passed its moving check before the freeze.
type AfterScan = Arc<std::sync::Mutex<Option<Box<dyn FnOnce() + Send>>>>;
struct AfterScanStore {
    inner: Box<dyn acpmux::store::Store>,
    after: AfterScan,
    stop_at_decline: bool,
}

impl acpmux::store::Store for AfterScanStore {
    fn list(&self) -> anyhow::Result<Vec<acpmux::store::SessionMeta>> {
        self.inner.list()
    }
    fn load(&self, id: &str) -> anyhow::Result<Option<acpmux::store::SessionMeta>> {
        self.inner.load(id)
    }
    fn save(&self, meta: &acpmux::store::SessionMeta) -> anyhow::Result<()> {
        self.inner.save(meta)
    }
    fn append(&self, id: &str, record: &acpmux::store::EventRecord) -> anyhow::Result<()> {
        self.inner.append(id, record)
    }
    fn events(
        &self,
        id: &str,
        after: u64,
        limit: usize,
    ) -> anyhow::Result<Vec<acpmux::store::EventRecord>> {
        self.inner.events(id, after, limit)
    }
    fn delete(&self, id: &str) -> anyhow::Result<()> {
        self.inner.delete(id)
    }
    fn scan(
        &self,
        id: &str,
        after: u64,
        visit: &mut dyn FnMut(acpmux::store::EventRecord) -> bool,
    ) -> anyhow::Result<()> {
        self.inner.scan(id, after, &mut |record| {
            // Export the durable prefix a crash or concurrent export between the two decline
            // appends can see: queue_declined is present, queue_removed is not yet present.
            let stop = self.stop_at_decline && record.kind == "queue_declined";
            visit(record) && !stop
        })?;
        let callback = self.after.lock().unwrap().take();
        if let Some(callback) = callback {
            callback();
        }
        Ok(())
    }
}

#[tokio::test]
async fn transfer_refuses_a_held_snapshot_even_when_the_live_prompt_was_removed() {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "codex"}},
        "defaultHarness": "fake", "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let inner = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let after = Arc::new(std::sync::Mutex::new(None));
    let store = AfterScanStore { inner, after: after.clone(), stop_at_decline: false };
    let hub = Hub::new(cfg, Box::new(store));
    let mut c = Client::open(&hub);
    let session = c.new_session(json!({"harness": "fake"})).await;
    c.queue(held(&session, "g-1", "never approved")).await;
    let s = hub.resolve(&session).unwrap();
    let h = hub.clone();
    *after.lock().unwrap() = Some(Box::new(move || {
        assert!(h.remove_queued(&s, "g-1"));
    }));
    let result =
        hub.transfer_request("_acpmux/transfer_begin", &json!({"sessionId": session})).await;
    assert!(queue(&hub, &session).is_empty(), "injected removal did not run");
    // Clean up even on the old vulnerable implementation, which incorrectly offers a bundle.
    if let Ok(bundle) = &result {
        hub.transfer_request(
            "_acpmux/transfer_abort",
            &json!({"sessionId": session, "transferId": bundle["transferId"]}),
        )
        .await
        .unwrap();
    }
    hub.shutdown_all().await;
    let error = result.expect_err("exported held prompt was offered to an older target");
    assert_eq!(error.data.unwrap()["reason"], "transfer.held_prompts");
}

#[tokio::test]
async fn transfer_refuses_a_decline_snapshot_before_the_legacy_removal() {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "codex"}},
        "defaultHarness": "fake", "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let inner = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let store = AfterScanStore {
        inner,
        after: Arc::new(std::sync::Mutex::new(None)),
        stop_at_decline: true,
    };
    let hub = Hub::new(cfg, Box::new(store));
    let mut c = Client::open(&hub);
    let session = c.new_session(json!({"harness": "fake"})).await;
    let waiting = c.queue(held(&session, "g-1", "never approved")).await;
    c.call("_acpmux/queue_decline", answer(&hub, &session, "g-1", None)).await;
    assert_eq!(reason(&c.reply_to(waiting).await), "queue.declined");
    assert!(queue(&hub, &session).is_empty());
    // The live queue is already empty, but export's log snapshot ends at queue_declined.
    // An older target ignores that new record and would restore its queued prompt.
    let result =
        hub.transfer_request("_acpmux/transfer_begin", &json!({"sessionId": session})).await;
    if let Ok(bundle) = &result {
        hub.transfer_request(
            "_acpmux/transfer_abort",
            &json!({"sessionId": session, "transferId": bundle["transferId"]}),
        )
        .await
        .unwrap();
    }
    hub.shutdown_all().await;
    let error = result.expect_err("decline without legacy removal was offered to an older target");
    assert_eq!(error.data.unwrap()["reason"], "transfer.held_prompts");
}

/// A link guest as the cmux daemon's guest relay (cmux#28928, hq#5528) reaches acpmux: its
/// connection attaches, views and types under `guest:<share_id>.<guest_id>`, and its prompt (a
/// `g-` id, the relay's) is accepted and waits for the owner. A guest author whose sender left
/// `approval` off waits all the same: no guest prompt runs before the owner approves it.
#[tokio::test]
async fn a_relayed_guests_prompt_typing_and_view_are_taken_and_its_prompt_waits() {
    let hub = hub();
    let mut owner = Client::open(&hub);
    let session = owner.new_session(json!({"harness": "fake"})).await;
    let id = "guest:Ab-_9xYz012345678901.q-_Z0aB1cD2";
    let bound = json!({"id": id, "name": "Theo", "approval": "owner"});
    let mut guest = Client::open(&hub);
    let attach =
        by(json!({"sessionId": session, "limit": 0, "_meta": {"acpmux": {}}}), Some(&bound));
    guest.call("_acpmux/attach", attach).await;
    let view = json!({"sessionId": session, "visible": true, "_meta": {"acpmux": {}}});
    guest.call("_acpmux/view", by(view, Some(&bound))).await;
    let typing = json!({"sessionId": session, "on": true, "_meta": {"acpmux": {}}});
    guest.call("_acpmux/typing", by(typing, Some(&bound))).await;

    let unmarked = json!({"id": id, "name": "Theo"});
    for (prompt_id, author) in [("g-Qm9xV3bT1kLp0aZr8yW2cE", &bound), ("g-unmarked", &unmarked)] {
        let sent = by(prompt(&session, prompt_id, "guest words", None), Some(author));
        let reply = guest.send("session/prompt", sent).await;
        let accepted = guest
            .until(|v| {
                v.get("id") == Some(&json!(reply))
                    || (v["method"] == "_acpmux/prompt_accepted"
                        && v["params"]["promptId"] == prompt_id)
            })
            .await;
        assert!(accepted.get("error").is_none(), "{author}: refused: {accepted}");
        assert_eq!(accepted["params"]["queued"], true, "{author}: {accepted}");
        assert_eq!(accepted["params"]["awaitingOwner"], true, "{author}: {accepted}");
    }
    let listed = queue(&hub, &session);
    assert_eq!(listed.len(), 2, "{listed:?}");
    assert!(listed.iter().all(|q| q["awaitingOwner"] == true), "{listed:?}");
    owner.call("session/prompt", prompt(&session, "p-owner", "owner words", None)).await;
    for prompt_id in ["g-Qm9xV3bT1kLp0aZr8yW2cE", "g-unmarked"] {
        assert!(!ran(&mut owner, &session, prompt_id).await, "{prompt_id} ran unapproved");
    }
    let records = owner.records(&session, "queued").await;
    let unmarked = records.iter().find(|m| m["promptId"] == "g-unmarked").expect("its record");
    assert_eq!(unmarked.pointer("/_meta/provenance/approval"), Some(&json!("owner")), "{unmarked}");
    assert_eq!(unmarked.pointer("/_meta/provenance/from"), Some(&json!(id)), "{unmarked}");

    owner.call("_acpmux/queue_approve", answer(&hub, &session, "g-unmarked", Some(0))).await;
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    while !ran(&mut owner, &session, "g-unmarked").await {
        assert!(std::time::Instant::now() < deadline, "the approved prompt never ran");
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    assert!(!ran(&mut owner, &session, "g-Qm9xV3bT1kLp0aZr8yW2cE").await, "approved the other");
}
