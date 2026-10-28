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

fn answer(session: &str, id: &str, revision: Option<u64>) -> Value {
    let mut params = json!({"sessionId": session, "promptId": id, "_meta": {"acpmux": {}}});
    if let Some(revision) = revision {
        params["revision"] = json!(revision);
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

    let authored = by(answer(&session, "g-1", Some(0)), Some(&guest()));
    let refused = c.reply("_acpmux/queue_approve", authored).await;
    assert_eq!(reason(&refused), "queue.owner_only", "{refused}");
    let stale = c.reply("_acpmux/queue_approve", answer(&session, "g-1", Some(1))).await;
    assert_eq!(reason(&stale), "queue.stale", "{stale}");
    c.call("_acpmux/queue_approve", answer(&session, "g-1", Some(0))).await;
    // Both answers, in either order.
    for _ in 0..2 {
        let done = c.until(|v| [waiting, again].iter().any(|id| v.get("id") == Some(&json!(id))));
        assert!(done.await.get("error").is_none());
    }
    let message = c.user_message(&session, "g-1").await;
    assert_eq!(message.pointer("/_meta/provenance/from"), Some(&json!("guest:k3x9")));
    assert_ne!(message["steer"], true, "it went in as a steer: {message}");
    let late = c.reply("_acpmux/queue_decline", answer(&session, "g-1", None)).await;
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
    let authored = by(answer(&session, "g-1", None), Some(&guest()));
    let refused = c.reply("_acpmux/queue_decline", authored).await;
    assert_eq!(reason(&refused), "queue.owner_only", "{refused}");
    c.call("_acpmux/queue_decline", answer(&session, "g-1", None)).await;
    let declined = c.reply_to(waiting).await;
    assert_eq!(reason(&declined), "queue.declined", "{declined}");
    let again = c.reply("_acpmux/queue_approve", answer(&session, "g-1", Some(0))).await;
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
    let stale = c.reply("_acpmux/queue_approve", answer(&session, "g-1", Some(0))).await;
    assert_eq!(reason(&stale), "queue.stale", "the owner approved words they never saw");
    c.call("_acpmux/queue_approve", answer(&session, "g-1", Some(1))).await;
    let late = c.reply("_acpmux/queue_edit", edit(&session, "g-1", "update")).await;
    assert_eq!(reason(&late), "queue.approved", "{late}");
    let remove = by(answer(&session, "g-1", None), Some(&guest()));
    assert_eq!(c.call("_acpmux/queue_remove", remove).await["removed"], true);
    let gone = c.reply("_acpmux/queue_decline", answer(&session, "g-1", None)).await;
    assert_eq!(gone.pointer("/error/data/decided"), Some(&json!("removed")), "{gone}");

    // At most 16 wait for the owner at once, per author.
    for i in 0..16 {
        c.queue(held(&session, &format!("g-cap-{i}"), "more")).await;
    }
    let over = c.reply("session/prompt", held(&session, "g-cap-16", "one more")).await;
    assert_eq!(reason(&over), "queue.too_many_held", "{over}");
    assert_eq!(hub.session_summary(&hub.resolve(&session).unwrap())["queued"], 16);
    let recorded = c.records(&session, "queued").await;
    assert!(!recorded.iter().any(|m| m["promptId"] == "g-cap-16"), "the refused prompt was recorded");
    c.cancel(&session).await;
}

fn durable(dir: &Path) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "codex"}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Local;
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
    let stale = c.reply("_acpmux/queue_approve", answer(&session, "g-1", Some(0))).await;
    assert_eq!(reason(&stale), "queue.stale", "{stale}");
    c.call("_acpmux/queue_approve", answer(&session, "g-1", Some(1))).await;
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
    c.call("_acpmux/queue_approve", answer(&session, "g-1", Some(0))).await;
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
        let remove = by(answer(&session, &id, None), Some(&guest()));
        let approve = owner.send("_acpmux/queue_approve", answer(&session, &id, Some(0))).await;
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
        let late = c.reply("_acpmux/queue_decline", answer(&session, &id, None)).await;
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
    let stale = c.reply("_acpmux/queue_approve", answer(&session, "g-1", Some(9))).await;
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
    c.call("_acpmux/queue_decline", answer(&session, "g-1", None)).await;
    assert_eq!(reason(&c.reply_to(waiting).await), "queue.declined");
    let moved = c.call("_acpmux/transfer_begin", begin).await;
    let abort = json!({"sessionId": session, "transferId": moved["transferId"]});
    c.call("_acpmux/transfer_abort", abort).await;
}
