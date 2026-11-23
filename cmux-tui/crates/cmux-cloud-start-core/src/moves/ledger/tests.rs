//! The ledgers (moved from the app's `CloudStartedChatsTests` and `CloudMoveAlwaysGrantsTests`).

use super::*;
use serde_json::json;

fn copy() -> Moved {
    Moved {
        machine_id: "vm-start".into(),
        host: "registry:start".into(),
        session: String::new(),
        harness: Some("claude".into()),
        local_root: "/local/project".into(),
        local_chat: "/local/project/web".into(),
        remote_folder: "/work/copy/project".into(),
        remote_chat: "/work/copy/project/web".into(),
        name: None,
        brought_back: None,
    }
}

fn apply(ledgers: &mut MovedChats, write: MovedWrite) {
    if let Some(moved) = write.moved {
        ledgers.moved = moved.value;
    }
    if let Some(starting) = write.starting {
        ledgers.starting = starting.value;
    }
}

#[test]
fn a_copy_waits_for_its_own_session_across_a_relaunch() {
    let mut ledgers = MovedChats::default();
    let copy = copy();
    let write = ledgers.copied(copy.clone());
    apply(&mut ledgers, write);
    assert!(ledgers.all().is_empty(), "a tab with no session appeared in access triage");
    assert!(!ledgers.started("registry:other", "chat", Some(&copy.remote_chat), None).0);
    assert!(!ledgers.started(&copy.host, "chat", Some("/work/other"), None).0);
    assert!(!ledgers.started(&copy.host, "home-chat", None, None).0);
    let (started, write) =
        ledgers.started(&copy.host, "chat", Some(&copy.remote_chat), Some("codex"));
    assert!(started);
    apply(&mut ledgers, write);
    let expected = Moved { session: "chat".into(), harness: Some("codex".into()), ..copy.clone() };
    assert_eq!(ledgers.entry(&copy.host, "chat"), Some(expected.clone()));
    assert!(!ledgers.started(&copy.host, "another-chat", Some(&copy.remote_chat), None).0);
    assert_eq!(ledgers.all(), [expected], "the committed mapping did not persist");
    assert_eq!(ledgers.starting, None, "an empty starting ledger removes its key");
}

#[test]
fn replaying_a_copy_does_not_overwrite_a_committed_bring_back() {
    let mut ledgers = MovedChats::default();
    let copy = Moved { harness: None, ..copy() };
    let write = ledgers.copied(copy.clone());
    apply(&mut ledgers, write);
    let (_, write) = ledgers.started(&copy.host, "chat", Some(&copy.remote_chat), None);
    apply(&mut ledgers, write);
    let mut committed = ledgers.entry(&copy.host, "chat").unwrap();
    committed.brought_back =
        Some(BroughtBack { session: "local-chat".into(), key: "transfer".into() });
    let write = ledgers.record(committed.clone());
    apply(&mut ledgers, write);
    let write = ledgers.copied(copy.clone());
    apply(&mut ledgers, write);
    let (started, write) = ledgers.started(&copy.host, "chat", Some(&copy.remote_chat), None);
    assert!(started);
    assert_eq!(write.moved, None, "the committed entry is not written over");
    apply(&mut ledgers, write);
    assert_eq!(ledgers.entry(&copy.host, "chat"), Some(committed));
}

#[test]
fn an_entry_this_version_cannot_read_drops_alone() {
    let stored = json!({
        "registry:a\ns1": {"machineID": "m", "host": "registry:a", "session": "s1", "localRoot": "/l", "localChat": "/l",
            "remoteFolder": "/r", "remoteChat": "/r", "broughtBack": {"session": "b", "key": "k"}},
        "registry:a\ns2": {"machineID": 7},
    })
    .to_string();
    let ledgers = MovedChats { moved: Some(stored), starting: Some("[corrupt".into()) };
    assert_eq!(ledgers.all().len(), 1);
    assert_eq!(ledgers.entry("registry:a", "s1").unwrap().brought_back.unwrap().key, "k");
    let forgotten = ledgers.forget("registry:a", "s1");
    assert_eq!(
        forgotten.moved.unwrap().value.as_deref(),
        Some("{}"),
        "the moved ledger is written even when empty"
    );
    assert_eq!(ledgers.forget("registry:a", "nobody"), MovedWrite::default());
}

/// The JSON is what the app's Swift `Codable` wrote: a ledger from an earlier build reads the same.
#[test]
fn retries_keep_the_earlier_builds_spelling() {
    let stored = json!({
        "tab-1": {"move": {"machineID": "vm-1"}},
        "tab-2": {"show": {"_0": {"session": "s", "machineID": "vm-2", "folder": "/w", "key": "k", "movedSession": "m"}}},
        "tab-3": {"askFirst": {"machineID": "vm-3"}},
        "tab-4": {"update": {"machineID": "vm-4"}},
        "tab-5": {"later": {"machineID": "vm-5"}},
        "tab-6": "nonsense",
    })
    .to_string();
    let all = retries(Some(&stored));
    assert_eq!(
        all.keys().collect::<Vec<_>>(),
        ["tab-1", "tab-2", "tab-3", "tab-4"],
        "a retry this version can't read drops alone"
    );
    let Retry::Show { shown } = &all["tab-2"] else { panic!("not a show") };
    assert_eq!((shown.moved_session.as_deref(), shown.harness.as_deref()), (Some("m"), None));
    assert_eq!(
        serde_json::to_value(&all["tab-2"]).unwrap(),
        json!({"show": {"_0": {"session": "s", "machineID": "vm-2", "folder": "/w",
        "key": "k", "movedSession": "m"}}})
    );
    assert!(retries(Some("[]")).is_empty());
    assert!(retries(None).is_empty());
}

#[test]
fn setting_a_retry_writes_only_a_change_and_an_empty_ledger_removes_its_key() {
    let retry = Retry::Move { machine_id: "vm-1".into() };
    let stored = set_retry(None, "tab", Some(retry.clone())).unwrap().unwrap();
    assert_eq!(retries(Some(&stored))["tab"], retry);
    assert_eq!(
        set_retry(Some(&stored), "tab", Some(retry)),
        None,
        "the same retry changes nothing"
    );
    assert_eq!(set_retry(Some(&stored), "tab", None), Some(None));
    assert_eq!(set_retry(None, "tab", None), None);
}

/// Persistent Move-to-Cloud consent is scoped to the Cloud identity and destination.
#[test]
fn a_grant_only_covers_the_approved_account_team_origin_and_folder() {
    let owner = Scope::new(Some("person-a"), Some("team-red"), "https://cmux.com");
    let other_team = Scope::new(Some("person-a"), Some("team-blue"), "https://cmux.com");
    let other_user = Scope::new(Some("person-b"), Some("team-red"), "https://cmux.com");
    let other_origin = Scope::new(Some("person-a"), Some("team-red"), "http://localhost:3777");
    let stored = remember(None, owner.as_ref(), "/work/repo", true);
    let stored = stored.as_deref();
    assert!(granted(stored, owner.as_ref(), "/work/repo"));
    assert!(!granted(stored, other_team.as_ref(), "/work/repo"));
    assert!(!granted(stored, other_user.as_ref(), "/work/repo"));
    assert!(!granted(stored, other_origin.as_ref(), "/work/repo"));
    assert!(!granted(stored, owner.as_ref(), "/work/another"));
    assert!(!granted(stored, None, "/work/repo"));
    // "Ask first next time" takes back exactly this grant.
    let stored = remember(stored, other_team.as_ref(), "/work/repo", true);
    let stored = remember(stored.as_deref(), owner.as_ref(), "/work/repo", false);
    assert!(!granted(stored.as_deref(), owner.as_ref(), "/work/repo"));
    assert!(granted(stored.as_deref(), other_team.as_ref(), "/work/repo"));
    assert_eq!(remember(stored.as_deref(), None, "/work/repo", true), None);
}

#[test]
fn an_unsigned_or_damaged_preference_never_authorizes_a_move() {
    assert_eq!(Scope::new(None, Some("t"), "https://cmux.com"), None);
    assert_eq!(Scope::new(Some("u"), None, "https://cmux.com"), None);
    assert_eq!(Scope::new(Some(""), Some("t"), "https://cmux.com"), None);
    assert_eq!(Scope::new(Some("u"), Some("t"), ""), None);
    let scope = Scope::new(Some("person-a"), Some("team-red"), "https://cmux.com");
    assert!(!granted(Some("{corrupt"), scope.as_ref(), "/work/repo"));
    // The old unscoped array of paths is never this team's grant.
    assert!(!granted(Some(r#"["/work/repo"]"#), scope.as_ref(), "/work/repo"));
}

#[test]
fn grants_are_stored_unique_in_a_stable_order() {
    let grant = |user: &str, folder: &str| Grant {
        user_id: user.into(),
        team_id: "t".into(),
        cloud_origin: "o".into(),
        folder: folder.into(),
    };
    let stored = store_grants([grant("b", "/x"), grant("a", "/y"), grant("b", "/x")]);
    assert_eq!(grants(Some(&stored)), [grant("a", "/y"), grant("b", "/x")]);
    assert_eq!(
        serde_json::from_str::<Value>(&stored).unwrap()[0],
        json!({"userID": "a", "teamID": "t", "cloudOrigin": "o", "folder": "/y"})
    );
}
