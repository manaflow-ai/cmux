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
    hub.set_surge_inbox(Some(true));
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let session = hub.new_session(req).await.unwrap();
    hub.set_surge_triager(Some(Arc::new(move |_| answer.map(str::to_owned))));
    // The test runs each pass itself: a lazy inbox restore that finds held messages schedules
    // no pass of its own beside it (`resume_after_restore`). [`scheduled`] lets one run.
    hub.surge_triage_due.lock().unwrap().insert(session.id.clone(), false);
    (hub, session)
}

fn hold(hub: &Hub, s: &Session, id: &str, thread: &str, class: &str, text: &str) {
    let msg = json!({"promptId": id, "threadId": thread, "from": "lane-a", "class": class,
        "text": text, "surgeHeld": true, "fromSession": "lane-a-session"});
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
    hold(&hub, &s, "m4", "ask", "question", "which base? the person decides");
    assert_eq!(hub.surge_triage_pass(&s).await.unwrap(), PassEnd::Done);
    assert!(
        hub.surge_triage_journals.lock().unwrap()[&s.id].cursor > 0,
        "the pass keeps its cursor"
    );

    let events = hub.events(&s.id, 0, 100_000).unwrap();
    let triaged: Vec<&Value> = records(&events, triage::RECORD_KIND).collect();
    assert_eq!(triaged.len(), 3, "the question's batch, the model's, one marker: {triaged:?}");
    let digest = triaged[0]["digestPromptId"].as_str().unwrap().to_owned();
    assert_eq!(triaged[1]["digestPromptId"], digest.as_str(), "one digest for the pass");
    assert_eq!(triaged[2]["digestDelivered"], digest.as_str());
    let cats: Vec<(&str, &str)> = triaged[..2]
        .iter()
        .flat_map(|r| r["items"].as_array().unwrap())
        .map(|i| (i["promptId"].as_str().unwrap(), i["category"].as_str().unwrap()))
        .collect();
    assert_eq!(
        cats,
        [
            ("m4", "needs_this_session"),
            ("m1", "noise"),
            ("m2", "needs_this_session"),
            ("m3", "already_handled")
        ],
        "the question first, with no model"
    );
    // Two open threads, one of them the person's: m2 is the agent's to act on.
    assert_eq!(triaged[1]["surge"]["needYou"], 1, "only the question to the person");
    assert!(sent(&hub, &s, &digest) >= 1, "the digest went to the chat");
    let text = events
        .iter()
        .find(|e| e.kind == "queued" || e.kind == "user_message")
        .map(|e| e.msg.to_string())
        .unwrap_or_default();
    assert!(!text.contains("runner queued") && !text.contains("landed #12"), "{text}");

    // Another pass with nothing new writes nothing and sends nothing.
    let before = hub.events(&s.id, 0, 100_000).unwrap().len();
    assert_eq!(hub.surge_triage_pass(&s).await.unwrap(), PassEnd::Done);
    let after = hub.events(&s.id, 0, 100_000).unwrap();
    assert_eq!(records(&after, triage::RECORD_KIND).count(), 3);
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
async fn nothing_actionable_sends_no_digest_and_a_model_outage_wakes_no_one() {
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

    // The model is out: the messages stay held, nothing is journaled or sent.
    let (hub, s) = chat(None).await;
    hold(&hub, &s, "m1", "runners", "fyi", "runner queued");
    hold(&hub, &s, "m2", "review", "result", "pick a base");
    assert_eq!(hub.surge_triage_pass(&s).await.unwrap(), PassEnd::Undecided);
    let events = hub.events(&s.id, 0, 100_000).unwrap();
    assert_eq!(records(&events, triage::RECORD_KIND).count(), 0);
    assert!(!events.iter().any(|e| e.kind == "queued" || e.kind == "user_message"));
    // A garbled answer decides only what it names clearly.
    hub.set_surge_triager(Some(Arc::new(|_| Some("1 noise\n2 maybe".to_owned()))));
    assert_eq!(hub.surge_triage_pass(&s).await.unwrap(), PassEnd::Undecided);
    // It recovers: the next pass decides the rest, once.
    hub.set_surge_triager(Some(Arc::new(|_| Some("1 this".to_owned()))));
    assert_eq!(hub.surge_triage_pass(&s).await.unwrap(), PassEnd::Done);
    let events = hub.events(&s.id, 0, 100_000).unwrap();
    let items: Vec<(String, String)> = records(&events, triage::RECORD_KIND)
        .flat_map(|r| r["items"].as_array().cloned().unwrap_or_default())
        .map(|i| (i["promptId"].as_str().unwrap().into(), i["category"].as_str().unwrap().into()))
        .collect();
    assert_eq!(
        items,
        [("m1".into(), "noise".into()), ("m2".into(), "needs_this_session".into())],
        "each message decided once"
    );
}

/// One request over a connection of session `id`'s own agent (its caller token).
async fn rpc_as(hub: &Arc<Hub>, id: &str, method: &str, params: Value) -> Value {
    let (in_tx, in_rx) = tokio::sync::mpsc::channel(8);
    let (out_tx, mut out_rx) = tokio::sync::mpsc::channel(256);
    let origin = crate::server::Origin::Local;
    hub.scope.spawn_named(
        "test-conn",
        crate::server::serve_connection_with(hub.clone(), in_rx, out_tx, origin),
    );
    let token = crate::hub::person::caller_token(id);
    let init = json!({"protocolVersion": 1,
        "_meta": {"acpmux": {"callerSession": {"sessionId": id, "token": token}}}});
    for (n, m, p) in [(1i64, "initialize", init), (2, method, params)] {
        in_tx.send(crate::rpc::Message::request(n, m, p).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(std::time::Duration::from_secs(20), out_rx.recv())
                .await
                .expect("an answer in 20 s")
                .expect("the connection is open");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(n)) {
                if n == 2 {
                    return v;
                }
                break;
            }
        }
    }
    unreachable!()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_failure_after_the_journal_write_is_retried_with_no_new_arrival() {
    let (hub, s) = chat(Some("1 this")).await;
    hold(&hub, &s, "m1", "review", "result", "pick a base");
    FAIL_BEFORE_DELIVERY.lock().unwrap().insert(s.id.clone(), 2);
    scheduled(&hub, &s);
    hub.schedule_surge_triage(&s);
    wait_idle(&hub, &s).await;
    let events = hub.events(&s.id, 0, 100_000).unwrap();
    let triaged: Vec<&Value> = records(&events, triage::RECORD_KIND).collect();
    assert_eq!(
        triaged.len(),
        2,
        "one batch record, then one delivery after two failures: {triaged:?}"
    );
    let digest = triaged[0]["digestPromptId"].as_str().unwrap();
    assert_eq!(triaged[1]["digestDelivered"], digest);
    assert!(sent(&hub, &s, digest) >= 1);
    assert_eq!(FAIL_BEFORE_DELIVERY.lock().unwrap()[&s.id], 0);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn retries_are_bounded() {
    let (hub, s) = chat(Some("1 this")).await;
    hold(&hub, &s, "m1", "review", "result", "pick a base");
    FAIL_BEFORE_DELIVERY.lock().unwrap().insert(s.id.clone(), 1000);
    scheduled(&hub, &s);
    hub.schedule_surge_triage(&s);
    wait_idle(&hub, &s).await;
    let left = FAIL_BEFORE_DELIVERY.lock().unwrap()[&s.id];
    assert_eq!(1000 - left, RETRIES + 1, "the first pass and RETRIES more, then it stops");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_restored_inbox_resumes_the_held_backlog() {
    let (hub, s) = chat(Some("1 this\n2 noise")).await;
    hold(&hub, &s, "m1", "review", "result", "pick a base");
    hold(&hub, &s, "m2", "runners", "fyi", "queued");
    // A restart: no cached triage state, the inbox read again from the log, no new arrival.
    hub.surge_triage_journals.lock().unwrap().clear();
    *s.inbox() = Default::default();
    scheduled(&hub, &s);
    hub.restore_inbox(&s);
    wait_idle(&hub, &s).await;
    let events = hub.events(&s.id, 0, 100_000).unwrap();
    let ids: usize =
        records(&events, triage::RECORD_KIND).map(|r| triage::triaged_ids(r).count()).sum();
    assert_eq!(ids, 2, "the backlog was triaged");
}

/// A restart with more undecided held messages than the inbox keeps in memory
/// (`inbox::KEEP`) triages every one of them: the backlog is read from the journal, never from
/// the in-memory projection that keeps only the newest.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_restart_triages_a_held_backlog_larger_than_the_inbox_keeps() {
    let (hub, s) = chat(None).await;
    // Every numbered message in the prompt is noise: nothing is delivered, all is decided.
    hub.set_surge_triager(Some(Arc::new(|prompt: String| {
        let n = prompt.matches("<<<end>>>").count();
        Some((1..=n).map(|i| format!("{i} noise")).collect::<Vec<_>>().join("\n"))
    })));
    let total = super::super::inbox::KEEP + 20;
    for i in 0..total {
        hold(&hub, &s, &format!("m{i}"), "runners", "fyi", &format!("runner {i} queued"));
    }
    hub.surge_triage_journals.lock().unwrap().clear();
    *s.inbox() = Default::default();
    // The restore itself resumes the backlog (`resume_after_restore`), with no new arrival.
    scheduled(&hub, &s);
    hub.restore_inbox(&s);
    assert!(s.inbox().items.len() <= super::super::inbox::KEEP, "memory keeps only the newest");
    wait_idle(&hub, &s).await;
    let events = hub.events(&s.id, 0, 1_000_000).unwrap();
    let ids: BTreeSet<String> = records(&events, triage::RECORD_KIND)
        .flat_map(|r| triage::triaged_ids(r).collect::<Vec<_>>())
        .collect();
    assert_eq!(ids.len(), total, "every held message was triaged, the oldest too");
    assert!(ids.contains("m0"));
}

/// Waits until `s` has no triage pass due or running.
async fn wait_idle(hub: &Arc<Hub>, s: &Session) {
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(30);
    loop {
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        if !hub.surge_triage_due.lock().unwrap().contains_key(&s.id) {
            return;
        }
        assert!(tokio::time::Instant::now() < deadline, "the triage passes ended");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn schedule_runs_one_pass_for_a_burst() {
    let (hub, s) = chat(Some("1 noise\n2 noise\n3 noise")).await;
    for i in 0..3 {
        hold(&hub, &s, &format!("m{i}"), "runners", "fyi", "queued");
        if i == 0 {
            scheduled(&hub, &s);
        }
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

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn owner_items_go_only_to_owners_the_recipient_authorized() {
    let (hub, s) = chat(Some("1 owner\n2 owner\n3 owner")).await;
    let req = || NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let owner = hub.new_session(req()).await.unwrap();
    let lead = hub.new_session(req()).await.unwrap();
    let stranger = hub.new_session(req()).await.unwrap();
    // Each third session subscribes itself through the RPC, from its own agent's connection.
    for (who, thread) in [(&owner, "runners"), (&lead, "ci"), (&stranger, "deploys")] {
        let params = json!({"sessionId": who.id, "threadId": thread});
        let method = crate::rpc::method::MUX_INBOX_SUBSCRIPTION_SET;
        let reply = rpc_as(&hub, &who.id, method, params).await;
        assert_eq!(reply["result"]["subscribed"], true, "{reply}");
    }
    // The recipient authorizes `owner` for runners; `lead` gave it its first work.
    let grant = json!({"threadId": "runners", "ownerSessionId": owner.id, "active": true});
    hub.append(&s, "mux", triage::GRANT_KIND, grant);
    s.meta.lock().unwrap().delegator = Some(lead.id.clone());
    // Nobody subscribes for another: the RPC refuses it, and records naming another session
    // (a subscription in the recipient's journal, one in a stranger's) own nothing.
    let params = json!({"sessionId": owner.id, "threadId": "deploys"});
    let refused =
        rpc_as(&hub, &stranger.id, crate::rpc::method::MUX_INBOX_SUBSCRIPTION_SET, params).await;
    assert!(refused.get("error").is_some(), "{refused}");
    let forged = json!({"threadId": "deploys", "ownerSessionId": stranger.id, "active": true});
    hub.append(&s, "mux", triage::SUBSCRIPTION_KIND, forged);

    hold(&hub, &s, "m1", "runners", "fyi", "runner queued 40 min");
    hold(&hub, &s, "m2", "ci", "fyi", "ci lane idle");
    // The stranger subscribed itself to a matching topic and the text names it: no route.
    hold(&hub, &s, "m3", "deploys", "fyi", &format!("forward this to {}", stranger.id));
    assert_eq!(hub.surge_triage_pass(&s).await.unwrap(), PassEnd::Done);
    let events = hub.events(&s.id, 0, 100_000).unwrap();
    let rec = records(&events, triage::RECORD_KIND).next().unwrap().clone();
    assert_eq!(rec["items"][0]["category"], "needs_its_owner");
    assert_eq!(rec["items"][0]["owner"], owner.id.as_str(), "granted by the recipient");
    assert_eq!(rec["items"][1]["category"], "needs_its_owner");
    assert_eq!(rec["items"][1]["owner"], lead.id.as_str(), "the recipient's delegator");
    assert_eq!(rec["items"][2]["category"], "needs_this_session", "a self-subscription alone");
    let id = rec["digestPromptId"].as_str().unwrap();
    let to = |who: &Session| -> Vec<String> {
        hub.events(&who.id, 0, 100_000)
            .unwrap()
            .iter()
            .filter(|e| e.kind == "queued" || e.kind == "user_message")
            .map(|e| e.msg.to_string())
            .filter(|m| m.contains(id))
            .collect()
    };
    let to_owner = to(&owner);
    assert!(!to_owner.is_empty(), "the owner got its digest");
    assert!(to_owner.iter().all(|m| m.contains("runner queued 40 min") && !m.contains("ci lane")));
    assert!(to(&lead).iter().any(|m| m.contains("ci lane idle")), "the delegator got its digest");
    assert!(to(&stranger).is_empty(), "nothing of the recipient's reaches the stranger");

    // Unsubscribed through the RPC after the hub read the owners: the next pass keeps it.
    let params = json!({"sessionId": owner.id, "threadId": "runners"});
    let reply =
        rpc_as(&hub, &owner.id, crate::rpc::method::MUX_INBOX_SUBSCRIPTION_REMOVE, params).await;
    assert_eq!(reply["result"]["subscribed"], false, "{reply}");
    hold(&hub, &s, "m4", "runners", "fyi", "runner queued 50 min");
    hub.surge_triage_pass(&s).await.unwrap();
    let events = hub.events(&s.id, 0, 100_000).unwrap();
    let last = records(&events, triage::RECORD_KIND)
        .filter(|r| r["items"].as_array().is_some_and(|i| !i.is_empty()))
        .last()
        .unwrap()
        .clone();
    assert_eq!(last["items"][0]["promptId"], "m4");
    assert_eq!(last["items"][0]["category"], "needs_this_session", "{last}");
}

#[test]
fn a_later_self_subscription_never_shadows_an_authorized_owner() {
    let mut map = BTreeMap::new();
    let sub =
        |o: &str, active: bool| json!({"threadId": "pr:1", "ownerSessionId": o, "active": active});
    apply_subscription(&mut map, "owner", &sub("owner", true), 10);
    apply_subscription(&mut map, "stranger", &sub("stranger", true), 20);
    let only_owner = |_: &str, o: &str| o == "owner";
    assert_eq!(
        authorized_owners(&map, only_owner).0.get("pr:1").map(String::as_str),
        Some("owner")
    );
    // The stranger's unsubscribe drops only its own entry.
    apply_subscription(&mut map, "stranger", &sub("stranger", false), 30);
    assert_eq!(
        authorized_owners(&map, only_owner).0.get("pr:1").map(String::as_str),
        Some("owner")
    );
    // A record in one session's journal naming another changes nothing.
    apply_subscription(&mut map, "stranger", &sub("owner", false), 40);
    assert_eq!(
        authorized_owners(&map, only_owner).0.get("pr:1").map(String::as_str),
        Some("owner")
    );
    // Two authorized: the most recent wins, the same every time.
    apply_subscription(&mut map, "lead", &sub("lead", true), 50);
    let both = |_: &str, o: &str| o == "owner" || o == "lead";
    assert_eq!(authorized_owners(&map, both).0.get("pr:1").map(String::as_str), Some("lead"));
    apply_subscription(&mut map, "owner", &sub("owner", false), 60);
    apply_subscription(&mut map, "lead", &sub("lead", false), 70);
    assert!(map.is_empty());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn each_digest_names_only_its_own_recipients_messages() {
    let (hub, s) = chat(Some("1 owner\n2 this")).await;
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let owner = hub.new_session(req).await.unwrap();
    let params = json!({"sessionId": owner.id, "threadId": "runners"});
    let method = crate::rpc::method::MUX_INBOX_SUBSCRIPTION_SET;
    rpc_as(&hub, &owner.id, method, params).await;
    let grant = json!({"threadId": "runners", "ownerSessionId": owner.id, "active": true});
    hub.append(&s, "mux", triage::GRANT_KIND, grant);
    hold(&hub, &s, "m1", "runners", "fyi", "runner queued");
    hold(&hub, &s, "m2", "review", "result", "pick a base");
    hub.surge_triage_pass(&s).await.unwrap();
    let ids_in = |who: &str| -> Vec<Value> {
        let events = hub.events(who, 0, 100_000).unwrap();
        events
            .iter()
            .filter_map(|e| e.msg.pointer("/_meta/provenance").or(e.msg.get("provenance")))
            .filter(|p| p["kind"] == PROVENANCE_KIND)
            .map(|p| p["promptIds"].clone())
            .collect()
    };
    let to_owner = ids_in(&owner.id);
    let to_chat = ids_in(&s.id);
    assert!(!to_owner.is_empty() && !to_chat.is_empty(), "{to_owner:?} {to_chat:?}");
    assert!(to_owner.iter().all(|ids| *ids == json!(["m1"])), "{to_owner:?}");
    assert!(to_chat.iter().all(|ids| *ids == json!(["m2"])), "{to_chat:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn failed_journal_writes_lose_no_decision_and_no_delivery() {
    let (hub, s) = chat(Some("1 this\n2 noise")).await;
    hold(&hub, &s, "m1", "review", "result", "pick a base");
    hold(&hub, &s, "m2", "runners", "fyi", "queued");
    // The batch write fails: nothing counts as decided; the retry triages both, once.
    FAIL_WRITES.lock().unwrap().insert((s.id.clone(), "batch"), 1);
    assert!(hub.surge_triage_pass(&s).await.is_err());
    assert_eq!(records(&hub.events(&s.id, 0, 100_000).unwrap(), triage::RECORD_KIND).count(), 0);
    // The digest goes out but its delivered marker's write fails: the retry sends it again as
    // its own duplicate, then writes the marker.
    FAIL_WRITES.lock().unwrap().insert((s.id.clone(), "marker"), 1);
    assert!(hub.surge_triage_pass(&s).await.is_err());
    assert_eq!(hub.surge_triage_pass(&s).await.unwrap(), PassEnd::Done);
    let events = hub.events(&s.id, 0, 100_000).unwrap();
    let recs: Vec<&Value> = records(&events, triage::RECORD_KIND).collect();
    let decided: Vec<String> = recs.iter().flat_map(|r| triage::triaged_ids(r)).collect();
    assert_eq!(decided, ["m1", "m2"], "each decided once: {recs:?}");
    let digest = recs[0]["digestPromptId"].as_str().unwrap();
    let markers: Vec<&&Value> = recs.iter().filter(|r| r["digestDelivered"] == digest).collect();
    assert_eq!(markers.len(), 1, "{recs:?}");
    let accepts: Vec<Value> = DIGEST_ACCEPTS
        .lock()
        .unwrap()
        .iter()
        .filter(|(to, a)| *to == s.id && a["promptId"] == digest)
        .map(|(_, a)| a.clone())
        .collect();
    assert_eq!(accepts.len(), 2, "sent, then resent: {accepts:?}");
    assert_ne!(accepts[0]["duplicate"], true);
    assert_eq!(accepts[1]["duplicate"], true, "the resend is the first one's duplicate");
}

fn hold_from(hub: &Hub, s: &Session, id: &str, from: &str, thread: &str, text: &str) {
    let msg = json!({"promptId": id, "threadId": thread, "from": from, "class": "fyi",
        "text": text, "surgeHeld": true, "fromSession": format!("{from}-session")});
    hub.append(s, "mux", "inbox", msg);
}

/// The prompt ids each surge digest to `who` named.
fn digested(hub: &Hub, who: &str) -> Vec<Value> {
    let events = hub.events(who, 0, 100_000).unwrap();
    events
        .iter()
        .filter(|e| e.kind == "queued" || e.kind == "user_message")
        .filter_map(|e| e.msg.pointer("/_meta/provenance").or(e.msg.get("provenance")))
        .filter(|p| p["kind"] == PROVENANCE_KIND)
        .map(|p| p["promptIds"].clone())
        .collect()
}

fn item<'a>(events: &'a [EventRecord], id: &str) -> &'a Value {
    records(events, triage::RECORD_KIND)
        .flat_map(|r| r["items"].as_array().unwrap())
        .find(|i| i["promptId"] == id)
        .unwrap_or_else(|| panic!("{id} triaged"))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_repeated_observation_wakes_no_one_twice_across_passes_and_restarts() {
    let (hub, s) = chat(Some("1 this")).await;
    let thread = "runner pool";
    hold_from(
        &hub,
        &s,
        "m1",
        "gcp-lane-1/ci-watch",
        thread,
        "Runner ubuntu-2404 queued 12 min on #48195",
    );
    pass_through(&hub, &s).await;
    // The next 30-second pass: another host's report of the same incident.
    hold_from(
        &hub,
        &s,
        "m2",
        "gcp-lane-7/ci-watch",
        thread,
        "runner ubuntu-2404 queued 40 min on #48195",
    );
    pass_through(&hub, &s).await;
    // A restart: the projection is rebuilt from the journal, and still knows m1 was told.
    hub.surge_triage_journals.lock().unwrap().clear();
    hold_from(
        &hub,
        &s,
        "m3",
        "gcp-lane-9/ci-watch",
        thread,
        "runner ubuntu-2404 queued 55 min on #48195",
    );
    pass_through(&hub, &s).await;
    // A materially different condition on the same topic surfaces.
    hold_from(
        &hub,
        &s,
        "m4",
        "gcp-lane-7/ci-watch",
        thread,
        "runner pool down: no runner registers",
    );
    pass_through(&hub, &s).await;

    let events = hub.events(&s.id, 0, 100_000).unwrap();
    assert!(item(&events, "m1").get("repeatOf").is_none());
    assert_eq!(item(&events, "m2")["repeatOf"], "m1", "the receipt names the first report");
    assert_eq!(item(&events, "m3")["repeatOf"], "m1", "across a restart");
    assert!(item(&events, "m4").get("repeatOf").is_none(), "{}", item(&events, "m4"));
    assert_eq!(digested(&hub, &s.id), [json!(["m1"]), json!(["m4"])]);
    let last = records(&events, triage::RECORD_KIND).filter(|r| r.get("surge").is_some()).last();
    // Status reports, however many, need the agent, not the person (Leo, 2026-11-23).
    assert_eq!(last.unwrap()["surge"]["needYou"], 0, "runner reports never need the person");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_question_and_an_expired_report_are_never_repeats() {
    let mut told = triage::Told::default();
    let b = triage::batches(
        "coord",
        vec![triage::Held {
            prompt_id: "q2".into(),
            thread_id: "t".into(),
            from: "lane-b".into(),
            class: "question".into(),
            text: "which base?".into(),
            program: false,
        }],
    )
    .remove(0);
    let print = triage::fingerprint(&b.messages[0]);
    told.note("coord", "t", &print, "q1", 0);
    let mut d =
        triage::decide(&b, None, &Owners::default()).into_iter().flatten().collect::<Vec<_>>();
    triage::mark_repeats(&b, &mut d, &mut told, 10);
    assert_eq!(d[0].repeat_of, None, "someone waits on a question's answer");
    assert_eq!(told.repeat("coord", "t", &print, 10), Some("q1"));
    assert_eq!(told.repeat("coord", "t", &print, triage::REPEAT_WINDOW_MS), None, "expired");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_grant_revoked_before_delivery_sends_the_item_to_the_chat_not_the_old_owner() {
    let (hub, s) = chat(Some("1 owner")).await;
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let owner = hub.new_session(req).await.unwrap();
    let params = json!({"sessionId": owner.id, "threadId": "runners"});
    let method = crate::rpc::method::MUX_INBOX_SUBSCRIPTION_SET;
    rpc_as(&hub, &owner.id, method, params).await;
    let grant = json!({"threadId": "runners", "ownerSessionId": owner.id, "active": true});
    hub.append(&s, "mux", triage::GRANT_KIND, grant);
    hold(&hub, &s, "m1", "runners", "fyi", "runner queued 40 min");
    // Decided for the owner and journaled; delivery fails.
    FAIL_BEFORE_DELIVERY.lock().unwrap().insert(s.id.clone(), 1);
    assert!(hub.surge_triage_pass(&s).await.is_err());
    let events = hub.events(&s.id, 0, 100_000).unwrap();
    assert_eq!(item(&events, "m1")["owner"], owner.id.as_str());
    // The recipient revokes the grant before the retry delivers.
    let revoke = json!({"threadId": "runners", "ownerSessionId": owner.id, "active": false});
    hub.append(&s, "mux", triage::GRANT_KIND, revoke);
    assert_eq!(hub.surge_triage_pass(&s).await.unwrap(), PassEnd::Done);
    assert!(digested(&hub, &owner.id).is_empty(), "the old owner hears nothing");
    assert_eq!(digested(&hub, &s.id), [json!(["m1"])], "the chat is told instead");
    let events = hub.events(&s.id, 0, 100_000).unwrap();
    let marker = records(&events, triage::RECORD_KIND).find(|r| r.get("digestDelivered").is_some());
    assert_eq!(marker.unwrap()["redirected"][0]["promptId"], "m1");
    assert_eq!(hub.surge_open_topics(&s, &mut hub.surge_journal(&s).unwrap()), 1);
}

/// Lets [`Hub::schedule_surge_triage`] start passes for `s` again ([`chat`] stops them).
fn scheduled(hub: &Hub, s: &Session) {
    hub.surge_triage_due.lock().unwrap().remove(&s.id);
}

/// One pass of `s`, run again while a recipient is still in an earlier digest's turn.
async fn pass_through(hub: &Arc<Hub>, s: &Arc<Session>) -> PassEnd {
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(30);
    loop {
        match hub.surge_triage_pass(s).await.unwrap() {
            PassEnd::Busy(_) => {}
            end => return end,
        }
        assert!(tokio::time::Instant::now() < deadline, "the digest turn ended");
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn distinct_topics_while_the_receiver_is_busy_coalesce_into_one_paced_digest() {
    let (hub, s) = chat(Some("1 this")).await;
    let slow = Duration::from_secs(90);
    let busy = DigestPace {
        running: Some(("an earlier digest".into(), std::time::Instant::now())),
        period: slow,
    };
    hub.surge_digest_pace.lock().unwrap().insert(s.id.clone(), busy);
    // Three distinct actionable topics, one per 30-second pass, while the chat's earlier digest
    // turn runs: none is sent, and each pass asks for the next one at its reply period.
    for (id, thread, text) in [
        ("m1", "review", "pick a base for #12"),
        ("m2", "deploy", "deploy failed: roll back?"),
        ("m3", "ci", "ci red on main after #13"),
    ] {
        hold(&hub, &s, id, thread, "result", text);
        assert_eq!(hub.surge_triage_pass(&s).await.unwrap(), PassEnd::Busy(slow));
    }
    assert!(digested(&hub, &s.id).is_empty(), "nothing queued behind the busy turn");
    let events = hub.events(&s.id, 0, 100_000).unwrap();
    let ids: BTreeSet<&str> = records(&events, triage::RECORD_KIND)
        .filter_map(|r| r["digestPromptId"].as_str())
        .collect();
    assert_eq!(ids.len(), 3, "three passes, three owed digests");
    // A fast receiver paces at the debounce, never faster.
    hub.surge_digest_pace.lock().unwrap().get_mut(&s.id).unwrap().period = Duration::ZERO;
    assert_eq!(hub.surge_triage_pass(&s).await.unwrap(), PassEnd::Busy(DEBOUNCE));

    // The turn ends: one digest names all three.
    hub.surge_digest_pace.lock().unwrap().get_mut(&s.id).unwrap().running = None;
    assert_eq!(hub.surge_triage_pass(&s).await.unwrap(), PassEnd::Done);
    assert_eq!(digested(&hub, &s.id), [json!(["m1", "m2", "m3"])]);
    let events = hub.events(&s.id, 0, 100_000).unwrap();
    let merged = records(&events, triage::RECORD_KIND).filter(|r| r.get("into").is_some()).last();
    let delivered = records(&events, triage::RECORD_KIND).find_map(|r| r.get("digestDelivered"));
    assert_eq!(Some(&merged.unwrap()["into"]), delivered, "the merged digest is the one sent");
    // A restart owes nothing more.
    hub.surge_triage_journals.lock().unwrap().clear();
    assert_eq!(pass_through(&hub, &s).await, PassEnd::Done);
    assert_eq!(digested(&hub, &s.id).len(), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_closed_owner_is_never_marked_delivered_its_items_go_to_the_chat() {
    let (hub, s) = chat(Some("1 owner")).await;
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let owner = hub.new_session(req).await.unwrap();
    let params = json!({"sessionId": owner.id, "threadId": "runners"});
    let method = crate::rpc::method::MUX_INBOX_SUBSCRIPTION_SET;
    rpc_as(&hub, &owner.id, method, params).await;
    let grant = json!({"threadId": "runners", "ownerSessionId": owner.id, "active": true});
    hub.append(&s, "mux", triage::GRANT_KIND, grant);
    hold(&hub, &s, "m1", "runners", "fyi", "runner queued 40 min");
    FAIL_BEFORE_DELIVERY.lock().unwrap().insert(s.id.clone(), 1);
    assert!(hub.surge_triage_pass(&s).await.is_err());
    // The owner closes between the decision and the delivery.
    hub.kill(&owner, true).await.unwrap();
    assert_eq!(pass_through(&hub, &s).await, PassEnd::Done);
    assert_eq!(digested(&hub, &s.id), [json!(["m1"])], "the chat is told instead");
    let events = hub.events(&s.id, 0, 100_000).unwrap();
    let marker = records(&events, triage::RECORD_KIND).find(|r| r.get("digestDelivered").is_some());
    assert_eq!(marker.unwrap()["redirected"][0]["promptId"], "m1");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_fork_never_sends_its_parents_owed_digest_or_uses_its_grants() {
    let (hub, _) = chat(Some("1 owner")).await;
    let req = || NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let owner = hub.new_session(req()).await.unwrap();
    let child = hub.new_session(req()).await.unwrap();
    hub.surge_triage_due.lock().unwrap().insert(child.id.clone(), false);
    child.meta.lock().unwrap().fork_seq = Some(1);
    let params = json!({"sessionId": owner.id, "threadId": "runners"});
    let method = crate::rpc::method::MUX_INBOX_SUBSCRIPTION_SET;
    rpc_as(&hub, &owner.id, method, params).await;
    // The parent's records, copied before the fork's marker: its grant, a held message, and a
    // digest it owed.
    let grant = json!({"threadId": "runners", "ownerSessionId": owner.id, "active": true});
    hub.append(&child, "mux", triage::GRANT_KIND, grant);
    hold(&hub, &child, "p1", "review", "result", "the parent's own question");
    let owed = json!({"batchId": "b", "recipient": "parent", "digestPromptId": "surge-digest-parent",
        "items": [{"promptId": "p0", "threadId": "secret", "category": "needs_this_session",
        "decidedBy": "rule", "from": "x", "label": "the parent's private item"}]});
    hub.append(&child, "mux", triage::RECORD_KIND, owed);
    hub.append(&child, "mux", "forked", json!({"parentId": "parent", "forkSeq": 1}));
    hold(&hub, &child, "c1", "runners", "fyi", "runner queued 40 min");
    assert_eq!(pass_through(&hub, &child).await, PassEnd::Done);

    let events = hub.events(&child.id, 0, 100_000).unwrap();
    let triaged: Vec<String> = records(&events, triage::RECORD_KIND)
        .filter(|r| r.get("surge").is_some())
        .flat_map(|r| triage::triaged_ids(r).collect::<Vec<_>>())
        .collect();
    assert_eq!(triaged, ["c1"], "only the fork's own message");
    assert_eq!(item(&events, "c1")["category"], "needs_this_session", "no inherited grant");
    assert_eq!(digested(&hub, &child.id), [json!(["c1"])], "the parent's digest is not sent");
    assert!(digested(&hub, &owner.id).is_empty());
}

/// A held message from a program: no session sent it (glaeda-land, hang-watch, NOW).
fn hold_program(hub: &Hub, s: &Session, id: &str, thread: &str, class: &str, text: &str) {
    let msg = json!({"promptId": id, "threadId": thread, "from": thread, "class": class,
        "text": text, "surgeHeld": true, "sender": {"session": null, "relay": null}});
    hub.append(s, "mux", "inbox", msg);
}

fn need_you(hub: &Hub, s: &Session) -> Value {
    hub.inbox_threads(s)["surge"]["needYou"].clone()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn program_notices_never_count_and_a_read_lowers_need_you_at_once() {
    // The model would call every one of them actionable, and each asks the person.
    let (hub, s) = chat(Some("1 this\n2 this\n3 this")).await;
    hold_program(&hub, &s, "g1", "glaeda-land", "block", "land stopped #51600: needs approval");
    hold_program(
        &hub,
        &s,
        "h1",
        "hang-watch",
        "question",
        "turn stuck 31 min; can the person look?",
    );
    hold_program(&hub, &s, "n1", "now-md", "block", "NOW: 15 red; the owner must sign in");
    hold_program(
        &hub,
        &s,
        "f1",
        "now-fire",
        "block",
        "FIRE runner label stalled; approve a restart",
    );
    hold(&hub, &s, "a1", "review", "question", "can the person pick a base?");
    hold(&hub, &s, "a2", "deploy", "block", "deploy needs the owner's approval");
    assert_eq!(hub.surge_triage_pass(&s).await.unwrap(), PassEnd::Done);
    let events = hub.events(&s.id, 0, 100_000).unwrap();
    for id in ["g1", "h1", "n1"] {
        assert_eq!(item(&events, id)["category"], "fyi", "{id}");
        assert_eq!(item(&events, id)["decidedBy"], "rule", "{id}");
    }
    assert_eq!(item(&events, "f1")["category"], "needs_this_session", "a FIRE still reaches it");
    assert_eq!(need_you(&hub, &s), 3, "the FIRE and the two agents' asks, no program notice");

    // Reading a thread lowers needYou now, with no pass; its held messages left memory
    // (`hold` journals them only), as `trim` lets them go on a busy chat.
    hub.inbox_thread(&s, "review", true);
    assert_eq!(need_you(&hub, &s), 2);
    hub.inbox_thread(&s, "review", true);
    assert_eq!(need_you(&hub, &s), 2, "a second read changes nothing");
    hub.inbox_thread(&s, "deploy", false);
    assert_eq!(need_you(&hub, &s), 2, "a look without marking read changes nothing");
    hub.inbox_thread(&s, "deploy", true);
    hub.inbox_thread(&s, "now-fire", true);
    assert_eq!(need_you(&hub, &s), 0);

    // A restart rebuilds the journal from the log: the reads stand.
    hub.surge_triage_journals.lock().unwrap().remove(&s.id);
    assert_eq!(hub.surge_triage_pass(&s).await.unwrap(), PassEnd::Done);
    assert_eq!(need_you(&hub, &s), 0);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_program_notice_an_older_pass_opened_stops_counting_at_the_next_pass() {
    let (hub, s) = chat(Some("1 this")).await;
    hold_program(&hub, &s, "g1", "glaeda-land", "result", "merged #51600");
    // What a daemon before the rule journaled: the model called it this chat's.
    let old = json!({"batchId": "b0", "recipient": s.id, "digestPromptId": "d0", "items": [
        {"promptId": "g1", "threadId": "glaeda-land", "category": "needs_this_session",
         "decidedBy": "model", "from": "glaeda-land", "label": "merged", "class": "result"}]});
    hub.persist_surge_triage(&s, old, 1).unwrap();
    assert_eq!(need_you(&hub, &s), 1);
    assert_eq!(hub.surge_triage_pass(&s).await.unwrap(), PassEnd::Done);
    assert_eq!(need_you(&hub, &s), 0, "the pass counts it again under the rule");
}
