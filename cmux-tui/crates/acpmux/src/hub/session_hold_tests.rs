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

#[test]
fn a_fleet_hold_lifts_at_its_until_and_an_older_unmarked_one_after_the_default() {
    // 2026-11-25: a leftover fleet hold idled every chat on a host, silently, for good.
    let at = 1_000_000;
    let set = FleetHold {
        on: true,
        at,
        until: Some(at + 60_000),
        by: Some("c".into()),
        ..Default::default()
    };
    assert!(set.active(at + 59_999));
    assert!(!set.active(at + 60_000));
    let never = FleetHold { on: true, at, until: None, by: Some("c".into()), ..Default::default() };
    assert!(never.active(at + 30 * DEFAULT_FOR_MS));
    let older = FleetHold { on: true, at, ..Default::default() };
    assert!(older.active(at + DEFAULT_FOR_MS - 1));
    assert!(!older.active(at + DEFAULT_FOR_MS));
    assert!(!FleetHold { on: false, ..never }.active(at));
}
