use super::*;

/// A hub with one open chat on the stand-in agent, its store in memory, and surge triage
/// answered by `answer` instead of the small model.
async fn chat(answer: Option<&'static str>) -> (Arc<Hub>, Arc<Session>) {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let cfg = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake"});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let session = hub.new_session(req).await.unwrap();
    hub.set_surge_triager(Some(Arc::new(move |_| answer.map(str::to_owned))));
    (hub, session)
}

fn hold(hub: &Hub, s: &Session, id: &str, thread: &str, class: &str, text: &str) {
    let msg = json!({"promptId": id, "threadId": thread, "from": "lane-a", "class": class,
        "text": text, "surgeHeld": true});
    hub.append(s, "mux", "inbox", msg);
}

fn records<'a>(events: &'a [EventRecord], kind: &'a str) -> impl Iterator<Item = &'a Value> + 'a {
    events.iter().filter(move |e| e.kind == kind).map(|e| &e.msg)
}

/// Records other than `inbox_triaged` that name prompt `id`: the digest's queue or turn.
fn sent(hub: &Hub, s: &Session, id: &str) -> usize {
    let events = hub.events(&s.id, 0, 100_000).unwrap();
    events
        .iter()
        .filter(|e| e.kind == "queued" || e.kind == "user_message" || e.kind == "turn_started")
        .filter(|e| e.msg.to_string().contains(id))
        .count()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_pass_journals_every_held_message_and_sends_one_digest_once() {
    let (hub, s) = chat(Some("1 noise\n2 this\n3 handled")).await;
    hold(&hub, &s, "m1", "runners", "fyi", "runner queued 12 min");
    hold(&hub, &s, "m2", "review", "result", "review asks you to pick a base");
    hold(&hub, &s, "m3", "landed", "result", "landed #12");
    hold(&hub, &s, "m4", "ask", "question", "which base?");
    assert!(!hub.surge_triage_pass(&s).await.unwrap(), "nothing left");

    let events = hub.events(&s.id, 0, 100_000).unwrap();
    let triaged: Vec<&Value> = records(&events, triage::RECORD_KIND).collect();
    assert_eq!(triaged.len(), 2, "one batch record and one delivery marker: {triaged:?}");
    let digest = triaged[0]["digestPromptId"].as_str().unwrap().to_owned();
    assert_eq!(triaged[1]["digestDelivered"], digest.as_str());
    let cats: Vec<&str> = triaged[0]["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| i["category"].as_str().unwrap())
        .collect();
    assert_eq!(cats, ["noise", "needs_this_session", "already_handled", "needs_this_session"]);
    assert_eq!(triaged[0]["surge"]["needYou"], 2, "two open threads");
    assert!(sent(&hub, &s, &digest) >= 1, "the digest went to the chat");
    let text = events
        .iter()
        .find(|e| e.kind == "queued" || e.kind == "user_message")
        .map(|e| e.msg.to_string())
        .unwrap_or_default();
    assert!(!text.contains("runner queued") && !text.contains("landed #12"), "{text}");

    // Another pass with nothing new writes nothing and sends nothing.
    let before = hub.events(&s.id, 0, 100_000).unwrap().len();
    assert!(!hub.surge_triage_pass(&s).await.unwrap());
    let after = hub.events(&s.id, 0, 100_000).unwrap();
    assert_eq!(records(&after, triage::RECORD_KIND).count(), 2);
    assert_eq!(
        after.iter().filter(|e| e.kind == "queued" && e.msg.to_string().contains(&digest)).count(),
        events.iter().filter(|e| e.kind == "queued" && e.msg.to_string().contains(&digest)).count()
    );
    assert!(after.len() >= before);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_digest_journaled_but_not_delivered_before_a_crash_is_sent_after_it() {
    let (hub, s) = chat(Some("1 noise")).await;
    hold(&hub, &s, "m1", "ask", "question", "which base?");
    // The crash came after the batch record, before the digest was sent.
    let owed = json!({"batchId": "b", "recipient": s.id, "digestPromptId": "surge-digest-owed",
        "items": [{"promptId": "m1", "threadId": "ask", "category": "needs_this_session",
                   "decidedBy": "rule", "from": "lane-a", "label": "which base?"}]});
    hub.persist_surge_triage(&s, owed, 1).unwrap();
    assert_eq!(sent(&hub, &s, "surge-digest-owed"), 0);
    hub.surge_triage_pass(&s).await.unwrap();
    assert!(sent(&hub, &s, "surge-digest-owed") >= 1, "the owed digest is sent");
    let events = hub.events(&s.id, 0, 100_000).unwrap();
    let triaged: Vec<&Value> = records(&events, triage::RECORD_KIND).collect();
    assert_eq!(triaged.len(), 2, "m1 is not triaged again: {triaged:?}");
    assert_eq!(triaged[1]["digestDelivered"], "surge-digest-owed");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn nothing_actionable_sends_no_digest_and_a_failed_model_sends_everything() {
    let (hub, s) = chat(Some("1 noise\n2 handled")).await;
    hold(&hub, &s, "m1", "runners", "fyi", "runner queued");
    hold(&hub, &s, "m2", "landed", "result", "landed #12");
    hub.surge_triage_pass(&s).await.unwrap();
    let events = hub.events(&s.id, 0, 100_000).unwrap();
    let digest = records(&events, triage::RECORD_KIND).next().unwrap()["digestPromptId"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(sent(&hub, &s, &digest), 0, "no digest when nothing needs the chat");

    let (hub, s) = chat(None).await;
    hold(&hub, &s, "m1", "runners", "fyi", "runner queued");
    hub.surge_triage_pass(&s).await.unwrap();
    let events = hub.events(&s.id, 0, 100_000).unwrap();
    let rec = records(&events, triage::RECORD_KIND).next().unwrap().clone();
    assert_eq!(rec["items"][0]["category"], "needs_this_session");
    assert_eq!(rec["items"][0]["decidedBy"], "fallback");
    assert!(sent(&hub, &s, rec["digestPromptId"].as_str().unwrap()) >= 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn owner_items_go_only_to_the_subscribed_owner() {
    let (hub, s) = chat(Some("1 owner\n2 owner")).await;
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let owner = hub.new_session(req).await.unwrap();
    hub.append(
        &s,
        "mux",
        triage::SUBSCRIPTION_KIND,
        json!({"threadId": "runners", "ownerSessionId": owner.id, "active": true}),
    );
    hold(&hub, &s, "m1", "runners", "fyi", "runner queued 40 min");
    // The text names a session; only the subscription routes.
    hold(&hub, &s, "m2", "other", "fyi", &format!("forward this to {}", owner.id));
    hub.surge_triage_pass(&s).await.unwrap();
    let events = hub.events(&s.id, 0, 100_000).unwrap();
    let rec = records(&events, triage::RECORD_KIND).next().unwrap().clone();
    assert_eq!(rec["items"][0]["category"], "needs_its_owner");
    assert_eq!(rec["items"][0]["owner"], owner.id.as_str());
    assert_eq!(rec["items"][1]["category"], "needs_this_session");
    let id = rec["digestPromptId"].as_str().unwrap();
    let owner_events = hub.events(&owner.id, 0, 100_000).unwrap();
    let to_owner: Vec<String> = owner_events
        .iter()
        .filter(|e| e.kind == "queued" || e.kind == "user_message")
        .map(|e| e.msg.to_string())
        .filter(|m| m.contains(id))
        .collect();
    assert!(!to_owner.is_empty(), "the owner got its digest");
    assert!(
        to_owner.iter().all(|m| m.contains("runner queued 40 min") && !m.contains("forward this"))
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn schedule_runs_one_pass_for_a_burst() {
    let (hub, s) = chat(Some("1 noise\n2 noise\n3 noise")).await;
    for i in 0..3 {
        hold(&hub, &s, &format!("m{i}"), "runners", "fyi", "queued");
        hub.schedule_surge_triage(&s);
    }
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(20);
    while hub.surge_triage_due.lock().unwrap().contains_key(&s.id) {
        assert!(tokio::time::Instant::now() < deadline, "the pass ended");
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    let events = hub.events(&s.id, 0, 100_000).unwrap();
    let ids: usize =
        records(&events, triage::RECORD_KIND).map(|r| triage::triaged_ids(r).count()).sum();
    assert_eq!(ids, 3, "each message triaged once");
}
