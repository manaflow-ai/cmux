//! A held chat takes no turn for anything but its person (`session_hold.rs`).

use super::*;

/// A hub with one open chat on the stand-in agent, its store in memory.
async fn chat() -> (Arc<Hub>, Arc<Session>) {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let cfg = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake"});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let session = hub.new_session(req).await.unwrap();
    (hub, session)
}

fn text(t: &str) -> Vec<Value> {
    vec![json!({"type": "text", "text": t})]
}

fn kinds(hub: &Hub, s: &Session, kind: &str) -> usize {
    hub.events(&s.id, 0, 1_000_000).unwrap().iter().filter(|e| e.kind == kind).count()
}

fn notice_opts(id: &str) -> PromptOptions {
    let notice = json!({"sender": "watcher", "severity": "warn", "title": "a merge"});
    PromptOptions {
        prompt_id: Some(id.to_owned()),
        provenance: Some(crate::prompt_provenance::notice(&notice, "chat")),
        ..PromptOptions::default()
    }
}

fn background_result(session: &Session, prompt: &str) -> Value {
    let notice = json!({"sender": "acpmux", "severity": "info", "title": "background task done"});
    let mut provenance = crate::prompt_provenance::notice(&notice, &session.id);
    provenance["bgTaskId"] = json!(prompt.strip_prefix("bg-done-").unwrap());
    let body = crate::prompt_provenance::notice_text(&notice, "task finished");
    let record = json!({"promptId":prompt, "client":"acpmux", "prompt":text(&body), "text":body});
    crate::prompt_provenance::marked(record, Some(&provenance))
}

fn queued_background_result(hub: &Hub, session: &Session, prompt: &str, turn: &str) {
    let mut record = background_result(session, prompt);
    record["turnId"] = json!(turn);
    record["fromAgent"] = json!("acpmux");
    record["class"] = json!("result");
    hub.append(session, "mux", "queued", record);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn restored_inbox_acceptance_retires_the_queue_entry_and_preserves_the_senders_receipt() {
    let (hub, session) = chat().await;
    let prompt = "bg-done-bg-1";
    hub.set_session_hold(&session, true).await.unwrap();
    queued_background_result(&hub, &session, prompt, "old-turn");
    hub.restore_queue(&session);
    assert_eq!(session.queued(), 1);
    hub.start_restored(&session);

    let receipt = tokio::time::timeout(
        std::time::Duration::from_secs(10),
        hub.prompt_outcome(&session, prompt),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(receipt["stopReason"], "end_turn");
    assert_eq!(receipt.pointer("/_meta/acpmux/inbox"), Some(&json!(true)));
    assert_ne!(receipt.pointer("/_meta/acpmux/withdrawn"), Some(&json!(true)));
    assert_eq!(session.queued(), 0);
    assert!(session.queue().is_empty());
    assert!(session.restored.lock().unwrap().is_empty());
    assert_eq!(kinds(&hub, &session, "inbox"), 1);
    assert_eq!(kinds(&hub, &session, "user_message"), 0);

    let restarted = hub.make_session(session.meta());
    hub.restore_queue(&restarted);
    assert!(restarted.queue().is_empty(), "a restart would deliver the notice twice");
    assert!(restarted.restored.lock().unwrap().is_empty());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn restored_inbox_replay_retires_only_prior_queue_entries_after_the_mux_received_them() {
    let (hub, session) = chat().await;
    let inbox = |dir, id| {
        let mut record = background_result(&session, id);
        record["from"] = json!("acpmux");
        record["class"] = json!("fyi");
        record["surgeHeld"] = json!(true);
        hub.append(&session, dir, "inbox", record)
    };
    queued_background_result(&hub, &session, "bg-done-accepted", "old");
    queued_background_result(&hub, &session, "bg-done-reused", "first");
    queued_background_result(&hub, &session, "bg-done-still-waiting", "unrelated");
    inbox("mux", "bg-done-accepted");
    inbox("mux", "bg-done-reused");
    queued_background_result(&hub, &session, "bg-done-reused", "second");
    inbox("agent", "bg-done-still-waiting");
    queued_background_result(&hub, &session, "bg-done-edited", "protected");
    hub.append(
        &session,
        "mux",
        "queue_updated",
        json!({"promptId":"bg-done-edited", "turnId":"protected",
        "text":"the corrected result", "prompt":text("the corrected result"),
        "revision":1, "awaitingOwner":true}),
    );
    inbox("mux", "bg-done-edited");

    // The daemon stopped before publishing any queue cleanup. Its own durable receipts suffice.
    hub.restore_queue(&session);
    let mut remaining: Vec<_> =
        session.queue().into_iter().map(|q| (q.prompt_id, q.turn_id)).collect();
    remaining.sort();
    assert_eq!(
        remaining,
        [
            ("bg-done-edited".to_owned(), "protected".to_owned()),
            ("bg-done-reused".to_owned(), "second".to_owned()),
            ("bg-done-still-waiting".to_owned(), "unrelated".to_owned())
        ]
    );
    assert_eq!(session.queued(), 3);
    let edited = session.queue().into_iter().find(|q| q.prompt_id == "bg-done-edited").unwrap();
    assert_eq!(edited.revision, 1);
    assert!(edited.awaiting_owner);
    // Neither the original worker nor a new one may write this held revision into the inbox.
    for rev in [0, 1] {
        let stored = hub
            .store_restored_inbox(&session, "protected", rev, || {
                panic!("a stale or protected queue entry was offered to the inbox")
            })
            .unwrap();
        assert!(!stored);
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn restored_inbox_rejects_a_notice_when_its_receipt_cannot_be_persisted() {
    let (hub, session) = chat().await;
    hub.set_session_hold(&session, true).await.unwrap();
    queued_background_result(&hub, &session, "bg-done-bg-1", "old-turn");
    hub.restore_queue(&session);
    hub.park_writes(&session, 7);
    hub.start_restored(&session);
    let error = tokio::time::timeout(
        std::time::Duration::from_secs(10),
        hub.prompt_outcome(&session, "bg-done-bg-1"),
    )
    .await
    .unwrap()
    .unwrap_err();
    assert!(error.message.contains("persist"), "{error:?}");
    hub.unpark_writes(&session);
    assert_eq!(kinds(&hub, &session, "inbox"), 0);
    assert_eq!(session.queue()[0].turn_id, "old-turn");
    let restarted = hub.make_session(session.meta());
    hub.restore_queue(&restarted);
    assert_eq!(restarted.queue()[0].turn_id, "old-turn");
}

/// interim-coord's test: a notice to a held chat starts no turn; it waits in the inbox.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_notice_to_a_held_chat_starts_no_turn() {
    let (hub, s) = chat().await;
    let held = hub.set_session_hold(&s, true).await.unwrap();
    assert_eq!(held["held"], true);
    assert!(hub.session_held(&s));

    let receipt = hub.prompt_with(&s, text("merged"), "test", false, notice_opts("n-1")).await;
    let receipt = receipt.unwrap();
    assert_eq!(receipt.pointer("/_meta/acpmux/sessionHeld"), Some(&json!(true)), "{receipt}");
    assert!(s.turn().is_none(), "a turn started in a held chat");
    assert_eq!(kinds(&hub, &s, "user_message"), 0, "the notice reached the agent");
    assert_eq!(kinds(&hub, &s, "inbox"), 1, "the notice is not in the inbox");

    // Another agent's message: held too.
    let opts = PromptOptions {
        prompt_id: Some("a-1".into()),
        agent: Some("lane".into()),
        ..PromptOptions::default()
    };
    let receipt = hub.prompt_with(&s, text("review this"), "acpmux", false, opts).await.unwrap();
    assert_eq!(receipt.pointer("/_meta/acpmux/sessionHeld"), Some(&json!(true)), "{receipt}");
    assert!(s.turn().is_none());
    assert_eq!(kinds(&hub, &s, "user_message"), 0);
    assert_eq!(kinds(&hub, &s, "inbox"), 2);
}

/// The person's own prompt lifts the hold and runs.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_persons_prompt_releases_a_held_chat() {
    let (hub, s) = chat().await;
    hub.set_session_hold(&s, true).await.unwrap();
    let opts = PromptOptions {
        prompt_id: Some("p-1".into()),
        human_authenticated: true,
        ..PromptOptions::default()
    };
    let receipt = hub.prompt_with(&s, text("hi"), "app", false, opts).await.unwrap();
    assert!(receipt.pointer("/_meta/acpmux/sessionHeld").is_none(), "{receipt}");
    assert!(!hub.session_held(&s));
    assert_eq!(kinds(&hub, &s, "user_message"), 1, "the person's prompt did not run");
}

/// `session release` lets agents' messages run again.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_released_chat_runs_notices() {
    let (hub, s) = chat().await;
    hub.set_session_hold(&s, true).await.unwrap();
    hub.set_session_hold(&s, false).await.unwrap();
    assert!(!hub.session_held(&s));
    let receipt = hub.prompt_with(&s, text("merged"), "test", false, notice_opts("n-2")).await;
    assert!(receipt.unwrap().pointer("/_meta/acpmux/sessionHeld").is_none());
    assert_eq!(kinds(&hub, &s, "user_message"), 1);
}

/// The fleet hold holds every chat but its allowlist's and refuses new chats outside it, save
/// the person's.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_fleet_hold_keeps_all_but_its_allowlist() {
    let (hub, s) = chat().await;
    let dir = tempfile::tempdir().unwrap();
    hub.fleet_hold.lock().unwrap().path = Some(dir.path().join(FILE));
    assert!(!hub.session_held(&s));
    let name = s.meta().name;

    let set =
        hub.set_fleet_hold(&json!({"on": true, "allow": ["coord*"], "reason": "Leo"})).unwrap();
    assert_eq!(set["held"], 1, "{set}");
    assert!(hub.session_held(&s));
    assert!(hub.fleet_hold_refuses_new(Some("lane-x"), false).is_some());
    assert!(hub.fleet_hold_refuses_new(None, false).is_some());
    assert!(hub.fleet_hold_refuses_new(Some("coord-2"), false).is_none());
    assert!(hub.fleet_hold_refuses_new(Some("lane-x"), true).is_none(), "the person was refused");

    let receipt = hub.prompt_with(&s, text("merged"), "test", false, notice_opts("n-3")).await;
    assert_eq!(receipt.unwrap().pointer("/_meta/acpmux/sessionHeld"), Some(&json!(true)));
    assert_eq!(kinds(&hub, &s, "user_message"), 0);

    hub.set_fleet_hold(&json!({"on": true, "allow": [name]})).unwrap();
    assert!(!hub.session_held(&s), "the allowlisted chat is held");
    hub.set_fleet_hold(&json!({"on": false})).unwrap();
    assert!(hub.fleet_hold_refuses_new(Some("lane-x"), false).is_none());
    assert_eq!(hub.set_fleet_hold(&json!({})).unwrap()["fleetHold"]["on"], false);
}

/// `*TERM*` lets any name containing TERM run, in any case: the coordinators' KEEP list
/// (`cloud|hybrid|coord|...`) as allowlist entries.
#[test]
fn a_star_term_star_entry_matches_a_substring_in_any_case() {
    let hold = FleetHold {
        on: true,
        allow: vec!["*cloud*".into(), "lane-*".into(), "exact".into(), "**".into()],
        ..FleetHold::default()
    };
    assert!(hold.allows("gcp-Cloud-sync", ""));
    assert!(hold.allows("cloud", ""));
    assert!(!hold.allows("clou-d", ""));
    assert!(hold.allows("lane-7", ""));
    assert!(!hold.allows("my-lane-7", ""), "a prefix entry matched mid-name");
    assert!(hold.allows("exact", ""));
    assert!(!hold.allows("exactly", ""));
    assert!(!hold.allows("anything", ""), "an empty term let every chat run");
}

/// The person releasing one chat under a fleet hold exempts it until it is held again.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn released_under_a_fleet_hold_stays_released() {
    let (hub, s) = chat().await;
    let dir = tempfile::tempdir().unwrap();
    hub.fleet_hold.lock().unwrap().path = Some(dir.path().join(FILE));
    hub.set_fleet_hold(&json!({"on": true})).unwrap();
    hub.release_session_hold_for_person(&s);
    assert!(!hub.session_held(&s));
    hub.set_session_hold(&s, true).await.unwrap();
    assert!(hub.session_held(&s));
}

#[test]
fn allow_adds_and_set_allow_replaces() {
    let s = |v: &[&str]| v.iter().map(|x| (*x).to_owned()).collect::<Vec<String>>();
    let was = s(&["api-overload-survive", "*cloud*"]);
    // `--allow NAME` keeps what was allowed (cosmic-gray 09:04Z: it used to replace the list).
    assert_eq!(
        next_allow(&was, None, &s(&["realtime-sync-rfd", "*cloud*"])),
        s(&["api-overload-survive", "*cloud*", "realtime-sync-rfd"])
    );
    // A bare `hold --fleet` keeps the list.
    assert_eq!(next_allow(&was, None, &[]), was);
    // `--set-allow` replaces, `--allow` adds to it, `--set-allow ''` empties it.
    assert_eq!(next_allow(&was, Some(&s(&["coord*"])), &s(&["x"])), s(&["coord*", "x"]));
    assert_eq!(next_allow(&was, Some(&s(&[""])), &[]), Vec::<String>::new());
}
