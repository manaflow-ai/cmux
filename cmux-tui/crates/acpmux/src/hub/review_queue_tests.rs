//! The review queue (`review_queue.rs`) and the audit entries its answers write
//! (`audit_entries.rs`), on a hub with a memory store.

use super::*;
use crate::store::SessionMeta;

fn hub() -> Arc<Hub> {
    let mut cfg: crate::config::Config = serde_json::from_value(json!({})).unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    Hub::new(cfg, Box::new(crate::store::MemoryStore::default()))
}

/// A session last active `at`, whose pull requests `prs` were each opened `at`.
fn meta(id: &str, status: &str, prs: &[&str], at: u64) -> SessionMeta {
    let times: serde_json::Map<String, Value> =
        prs.iter().map(|u| ((*u).to_owned(), json!(at))).collect();
    serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": id, "harness": "claude",
        "family": "claude", "cwd": "/tmp", "status": status, "createdAt": 1,
        "updatedAt": at, "pullRequests": prs, "pullRequestTimes": times,
    }))
    .unwrap()
}

fn tool_request(title: &str) -> Value {
    json!({"toolCall": {"toolCallId": "t1", "kind": "execute", "title": title,
                        "rawInput": {"command": "ls -la"}},
           "options": [{"optionId": "ok", "name": "Allow", "kind": "allow_once"},
                       {"optionId": "no", "name": "Deny", "kind": "reject_once"}]})
}

/// Holds `request` pending on `session` the way `request_permission` does: the pending entry,
/// then its `permission_request` record.
fn ask(hub: &Hub, session: &Session, id: &str, request: Value) -> oneshot::Receiver<Value> {
    let (reply, rx) = oneshot::channel();
    session.permissions.lock().unwrap().pending.insert(
        id.to_owned(),
        PendingPermission {
            request: request.clone(),
            reply,
            decision_nonce: super::person::new_nonce(),
            ancestor_may_answer: false,
            prev_status: SessionStatus::Ready,
            agent_request: None,
            agent_host_incarnation: None,
        },
    );
    hub.append(
        session,
        "mux",
        "permission_request",
        json!({"permissionId": id, "request": request, "turnId": "turn-1"}),
    );
    rx
}

/// Answers `id` the way `respond_permission` and `settle_permission` do.
fn answer(hub: &Hub, session: &Session, id: &str, option: &str) {
    session.permissions.lock().unwrap().pending.remove(id);
    hub.append(
        session,
        "mux",
        "permission_decision",
        json!({"permissionId": id, "outcome": {"outcome": "selected", "optionId": option}}),
    );
}

#[tokio::test]
async fn asks_are_classified_and_carry_what_answering_needs() {
    let hub = hub();
    let s = hub.insert_test_session(meta("s1", "ready", &[], 2));
    let _a = ask(&hub, &s, "p-tool", tool_request("Run ls"));
    let plan = json!({"toolCall": {"kind": "other", "title": "Plan",
        "_meta": {"claude": {"tool": "ExitPlanMode"}}, "rawInput": {"plan": "1. do it"}},
        "options": [{"optionId": "yes", "name": "Approve", "kind": "allow_once"}]});
    let _b = ask(&hub, &s, "p-plan", plan);
    let question = json!({"toolCall": {"kind": "other", "_meta": {"claude": {"tool": "AskUserQuestion"}},
        "rawInput": {"questions": [{"question": "Which branch?", "options": [{"label": "main"}]}]}},
        "options": [{"optionId": "go", "name": "Answer", "kind": "allow_once"}]});
    let _c = ask(&hub, &s, "p-q", question);
    let now = now_ms();
    let (items, visited) = hub.review_queue_local(now);
    assert_eq!(visited, 1);
    let by_id = |id: &str| items.iter().find(|i| i["id"] == id).cloned().unwrap();
    let tool = by_id("acpmux:p-tool");
    assert_eq!(tool["kind"], "approval");
    assert_eq!(tool["sessionId"], "s1");
    assert_eq!(tool["permissionId"], "p-tool");
    assert_eq!(tool["turnId"], "turn-1");
    assert_eq!(tool["vendor"], "anthropic");
    assert_eq!(tool["ask"], "Run ls");
    assert_eq!(tool["detail"], "ls -la");
    assert_eq!(
        tool["options"][1],
        json!({"optionId": "no", "name": "Deny", "kind": "reject_once"})
    );
    assert_eq!(tool["impactReasons"][0], "blocksTurn");
    assert!(tool.get("question").is_none());
    assert_eq!(by_id("acpmux:p-plan")["kind"], "plan");
    let q = by_id("acpmux:p-q");
    assert_eq!(q["kind"], "question");
    assert_eq!(q["ask"], "Which branch?");
    assert!(q["question"]["toolCall"].is_object());
}

#[tokio::test]
async fn an_answer_writes_one_audit_entry_and_leaves_the_queue() {
    let hub = hub();
    let s = hub.insert_test_session(meta("s1", "ready", &[], 2));
    let _rx =
        ask(&hub, &s, "p1", tool_request("Run ls with ghp_aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jSaZ3k"));
    let _rx2 = ask(&hub, &s, "p2", tool_request("Delete build"));
    answer(&hub, &s, "p1", "ok");
    answer(&hub, &s, "p2", "no");
    // A decision the index never saw asked (a replay) writes nothing.
    hub.append(
        &s,
        "mux",
        "permission_decision",
        json!({"permissionId": "ghost", "outcome": {"outcome": "selected", "optionId": "ok"}}),
    );
    let all = hub.audit.all().unwrap();
    assert_eq!(all.len(), 2, "{all:?}");
    assert_eq!(all[0]["kind"], "approval");
    assert_eq!(all[0]["decision"], json!({"optionId": "ok", "kind": "allow"}));
    assert_eq!(all[0]["answeredBy"], json!({"person": true}));
    assert!(
        !all[0]["ask"].as_str().unwrap().contains("aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jS"),
        "{}",
        all[0]["ask"]
    );
    assert_eq!(all[1]["decision"]["kind"], "deny");
    assert_eq!(all[1]["prevHash"], all[0]["hash"]);
    assert_eq!(super::audit_log::verify(&all)["ok"], true);
    let (items, _) = hub.review_queue_local(now_ms());
    assert!(items.is_empty(), "{items:?}");
    assert_eq!(hub.review_index.sizes().0, 0);
}

#[tokio::test]
async fn a_withdrawn_ask_leaves_the_index_on_the_next_read() {
    let hub = hub();
    let s = hub.insert_test_session(meta("s1", "ready", &[], 2));
    let _rx = ask(&hub, &s, "p1", tool_request("Run ls"));
    s.permissions.lock().unwrap().pending.clear();
    let (items, visited) = hub.review_queue_local(now_ms());
    assert!(items.is_empty());
    assert_eq!(visited, 1);
    assert_eq!(hub.review_index.sizes().0, 0);
    assert_eq!(hub.review_queue_local(now_ms()).1, 0);
    assert!(hub.audit.all().unwrap().is_empty());
}

#[tokio::test]
async fn pull_requests_wait_for_a_verdict_while_their_turn_is_not_running() {
    let hub = hub();
    let now = now_ms();
    let url = "https://github.com/o/r/pull/7";
    let idle = hub.insert_test_session(meta("idle", "idle", &[url], now - 60_000));
    hub.insert_test_session(meta("busy", "running", &["https://github.com/o/r/pull/8"], now));
    let old = now - super::review_queue::PR_WINDOW_MS - 1;
    hub.insert_test_session(meta("old", "idle", &["https://github.com/o/r/pull/9"], old));
    let (items, _) = hub.review_queue_local(now);
    let ids: Vec<_> = items.iter().map(|i| i["id"].as_str().unwrap().to_owned()).collect();
    assert_eq!(ids, vec![format!("pr:{url}")]);
    assert_eq!(items[0]["kind"], "pr");
    assert_eq!(items[0]["prUrl"], url);
    assert_eq!(items[0]["ask"], "Review o/r#7");
    assert_eq!(items[0]["impact"], super::review_queue::BASE_PR);
    // The old pull request left the index; the running one stays for later.
    assert_eq!(hub.review_index.sizes().1, 2);
    assert!(
        hub.record_review_verdict(&idle, "https://github.com/o/r/pull/99", true, true).is_err()
    );
    let entry = hub.record_review_verdict(&idle, url, false, true).unwrap();
    assert_eq!(entry["decision"], json!({"kind": "changes"}));
    assert!(hub.review_queue_local(now).0.is_empty());
    let all = hub.audit.all().unwrap();
    assert_eq!((all[0]["kind"].clone(), all[0]["prUrl"].clone()), (json!("review"), json!(url)));
    assert_eq!(all[0]["answeredBy"], json!({"person": true, "via": "app"}));
}

#[tokio::test]
async fn a_verdict_leaves_the_same_pull_request_of_another_session_queued() {
    let hub = hub();
    let now = now_ms();
    let url = "https://github.com/o/r/pull/7";
    let a = hub.insert_test_session(meta("a", "idle", &[url], now - 60_000));
    hub.insert_test_session(meta("b", "idle", &[url], now - 60_000));
    assert_eq!(hub.review_queue_local(now).0.len(), 2);
    hub.record_review_verdict(&a, url, true, true).unwrap();
    let (items, _) = hub.review_queue_local(now);
    let sessions: Vec<_> = items.iter().map(|i| i["sessionId"].clone()).collect();
    assert_eq!(sessions, vec![json!("b")]);
}

#[tokio::test]
async fn a_restored_pull_request_keeps_the_time_it_was_opened() {
    let hub = hub();
    let now = now_ms();
    let old = now - super::review_queue::PR_WINDOW_MS - 1;
    // Opened long ago, though the session was active a minute ago.
    let mut timed = meta("timed", "idle", &["https://github.com/o/r/pull/1"], old);
    timed.updated_at = now - 60_000;
    hub.insert_test_session(timed);
    // Kept before times were: it counts from the session's creation, long ago.
    let mut untimed = meta("untimed", "idle", &["https://github.com/o/r/pull/2"], now - 60_000);
    untimed.pull_request_times.clear();
    untimed.created_at = old;
    hub.insert_test_session(untimed);
    assert!(hub.review_queue_local(now).0.is_empty());
}

#[tokio::test]
async fn a_queue_read_between_the_answer_and_its_record_keeps_the_audit_entry() {
    let hub = hub();
    let s = hub.insert_test_session(meta("s1", "ready", &[], 2));
    let _rx = ask(&hub, &s, "p1", tool_request("Run ls"));
    // `respond_permission` takes the pending entry first...
    s.permissions.lock().unwrap().pending.remove("p1");
    // ...a read lands before its decision record...
    assert!(hub.review_queue_local(now_ms()).0.is_empty());
    assert_eq!(hub.review_index.settling(), 1);
    // ...and the record still finds the ask.
    hub.append(
        &s,
        "mux",
        "permission_decision",
        json!({"permissionId": "p1", "outcome": {"outcome": "selected", "optionId": "ok"}}),
    );
    let all = hub.audit.all().unwrap();
    assert_eq!(all.len(), 1, "{all:?}");
    assert_eq!(all[0]["permissionId"], "p1");
    assert_eq!(all[0]["decision"]["kind"], "allow");
    assert_eq!(hub.review_index.settling(), 0);
    // An ask set aside that no record settles goes after SETTLE_MS.
    let _rx = ask(&hub, &s, "p2", tool_request("Run pwd"));
    s.permissions.lock().unwrap().pending.remove("p2");
    hub.review_queue_local(now_ms());
    assert_eq!(hub.review_index.settling(), 1);
    hub.review_queue_local(now_ms() + super::review_queue::SETTLE_MS);
    assert_eq!(hub.review_index.settling(), 0);
}

#[tokio::test]
async fn a_dismissal_and_an_automatic_allow_are_recorded_as_such() {
    use super::review_queue::Settled;
    let hub = hub();
    let s = hub.insert_test_session(meta("s1", "ready", &[], 2));
    // Dismissed by its caller: kept, apart from a withdrawal.
    let _a = ask(&hub, &s, "p1", tool_request("Run ls"));
    hub.review_index.mark_settled("s1", "p1", Settled::Caller);
    s.permissions.lock().unwrap().pending.remove("p1");
    hub.append(
        &s,
        "mux",
        "permission_decision",
        json!({"permissionId": "p1", "outcome": {"outcome": "cancelled"}}),
    );
    // Withdrawn by its agent: nobody answered.
    let _b = ask(&hub, &s, "p2", tool_request("Run pwd"));
    s.permissions.lock().unwrap().pending.remove("p2");
    hub.append(
        &s,
        "mux",
        "permission_decision",
        json!({"permissionId": "p2", "outcome": {"outcome": "cancelled"}}),
    );
    // Allowed by a switch to full access.
    let _c = ask(&hub, &s, "p3", tool_request("Run make"));
    hub.review_index.mark_settled("s1", "p3", Settled::Auto("mode"));
    answer(&hub, &s, "p3", "ok");
    let all = hub.audit.all().unwrap();
    let got: Vec<_> =
        all.iter().map(|e| (e["permissionId"].clone(), e["decision"]["kind"].clone())).collect();
    assert_eq!(got, vec![(json!("p1"), json!("cancel")), (json!("p3"), json!("allow"))]);
    assert_eq!(all[1]["answeredBy"], json!({"person": false, "via": "mode"}));
}

#[tokio::test]
async fn a_failed_audit_purge_fails_the_delete_and_the_chat_still_records() {
    let hub = hub();
    let s = hub.insert_test_session(meta("s1", "ready", &[], 2));
    let _a = ask(&hub, &s, "p1", tool_request("Run ls"));
    answer(&hub, &s, "p1", "ok");
    hub.audit.fail_purges(true);
    assert!(hub.kill(&s, true).await.is_err());
    assert!(!s.purged.load(Ordering::SeqCst));
    assert!(!s.closing.load(Ordering::SeqCst), "nothing of the chat was stopped");
    assert!(hub.sessions.lock().unwrap().contains_key("s1"));
    let _b = ask(&hub, &s, "p2", tool_request("Run pwd"));
    answer(&hub, &s, "p2", "ok");
    let all = hub.audit.all().unwrap();
    assert_eq!(all.len(), 2, "{all:?}");
    assert_eq!(all[1]["permissionId"], "p2");
}

#[tokio::test]
async fn a_reissued_ask_keeps_the_time_and_turn_it_was_first_asked() {
    let hub = hub();
    let s = hub.insert_test_session(meta("s1", "waiting", &[], 2));
    let request = tool_request("Run ls");
    // A restart: the index learns the ask as first recorded, then its reissue is appended.
    hub.review_index.note_ask(
        &s.id,
        &json!({"permissionId": "p1", "turnId": "turn-7", "request": request.clone()}),
        1_000,
    );
    let (reply, _rx) = oneshot::channel();
    s.permissions.lock().unwrap().pending.insert(
        "p1".to_owned(),
        PendingPermission {
            request: request.clone(),
            reply,
            decision_nonce: super::person::new_nonce(),
            ancestor_may_answer: false,
            prev_status: SessionStatus::Waiting,
            agent_request: None,
            agent_host_incarnation: None,
        },
    );
    hub.append(&s, "mux", "permission_reissued", json!({"permissionId": "p1", "request": request}));
    let (items, _) = hub.review_queue_local(now_ms());
    let item = items.iter().find(|i| i["permissionId"] == "p1").unwrap();
    assert_eq!(item["at"], 1_000);
    assert_eq!(item["turnId"], "turn-7");
}

#[tokio::test]
async fn a_purged_chat_leaves_no_audit_entry() {
    let hub = hub();
    let gone = hub.insert_test_session(meta("incognito", "ready", &[], 2));
    let kept = hub.insert_test_session(meta("kept", "ready", &[], 2));
    let _a = ask(&hub, &gone, "p1", tool_request("Run cat private-plans.txt"));
    answer(&hub, &gone, "p1", "ok");
    let _b = ask(&hub, &kept, "p2", tool_request("Run ls"));
    answer(&hub, &kept, "p2", "ok");
    assert_eq!(hub.audit.all().unwrap().len(), 2);
    hub.kill(&gone, true).await.unwrap();
    let all = hub.audit.all().unwrap();
    let sessions: Vec<_> = all.iter().map(|e| e["sessionId"].clone()).collect();
    assert_eq!(sessions, vec![json!("kept")]);
    assert_eq!(super::audit_log::verify(&all)["ok"], true);
    // A decision recorded for it after the purge began writes nothing.
    answer(&hub, &gone, "p3", "ok");
    assert_eq!(hub.audit.all().unwrap().len(), 1);
}

#[tokio::test]
async fn a_queue_read_does_not_grow_with_idle_sessions() {
    let hub = hub();
    for i in 0..2000 {
        hub.insert_test_session(meta(&format!("idle-{i}"), "idle", &[], 2));
    }
    let s = hub.insert_test_session(meta("asking", "ready", &[], 2));
    let _rx = ask(&hub, &s, "p1", tool_request("Run ls"));
    let (items, visited) = hub.review_queue_local(now_ms());
    assert_eq!(items.len(), 1);
    assert_eq!(visited, 1, "a read visits only the sessions the index holds");
    assert_eq!(hub.review_index.sizes(), (1, 0));
}

#[tokio::test]
async fn queued_prompts_and_age_order_the_queue() {
    let hub = hub();
    let a = hub.insert_test_session(meta("a", "ready", &[], 2));
    let b = hub.insert_test_session(meta("b", "ready", &[], 2));
    let _ra = ask(&hub, &a, "pa", tool_request("A"));
    let _rb = ask(&hub, &b, "pb", tool_request("B"));
    b.queued.store(3, Ordering::SeqCst);
    let (mut items, _) = hub.review_queue_local(now_ms());
    super::review_queue::sort_items(&mut items, 10);
    assert_eq!(items[0]["id"], "acpmux:pb");
    assert!(items[0]["impactReasons"].as_array().unwrap().contains(&json!("queuedPrompts:3")));
    // Read an hour later, every ask has aged: the score doubles.
    let (later, _) = hub.review_queue_local(now_ms() + 3_600_000);
    let pa = later.iter().find(|i| i["id"] == "acpmux:pa").unwrap();
    assert!(pa["score"].as_f64().unwrap() >= 2.0 * f64::from(super::review_queue::BASE_ASK) - 1.0);
}
