//! Settling chats on their own (`auto_settle.rs`): the Settings keys, the rule on its facts, the
//! GitHub read's parsing, and a hub pass that settles, holds a busy chat, and un-settles.

use super::*;
use crate::config::{Config, StoreMode};
use std::path::Path;

const SOURCE: &str = include_str!("../../../../../schemas/settings/source/agent-settle.json");

fn row(key: &str) -> Value {
    let doc: Value = serde_json::from_str(SOURCE).unwrap();
    doc["lists"][0]["rows"].as_array().unwrap().iter().find(|r| r["key"] == key).unwrap().clone()
}

fn url(n: u64) -> String {
    format!("https://github.com/o/settle-tests/pull/{n}")
}

fn facts(prs: &[u64], last: u64) -> Facts {
    Facts {
        pull_requests: prs.iter().map(|n| url(*n)).collect(),
        last_activity_ms: last,
        ..Facts::default()
    }
}

fn states(of: &[(u64, PrState)]) -> impl Fn(&str) -> Option<PrState> + '_ {
    move |u: &str| of.iter().find(|(n, _)| url(*n) == u).map(|(_, s)| *s)
}

const ALL: Rules = Rules { on_merge: true, on_close: true, idle_ms: Some(3 * DAY_MS) };

#[test]
fn the_settings_source_matches_the_daemon() {
    assert_eq!(row(SETTING_ON_MERGE)["default"], json!(false), "off by default");
    assert_eq!(row(SETTING_ON_CLOSE)["default"], json!(false), "off by default");
    assert_eq!(row(SETTING_IDLE_DAYS)["default"], json!(0), "off by default");
    assert_eq!(row(SETTING_IDLE_DAYS)["range"]["max"], json!(IDLE_DAYS_MAX));
}

#[test]
fn off_unless_turned_on() {
    assert!(!rules(None).any(), "no settings file");
    assert!(!rules(Some(&json!({}))).any(), "the defaults");
    let nested = json!({"agents": {"autoSettle": {"onMerge": true, "idleDays": 7}}});
    assert_eq!(
        rules(Some(&nested)),
        Rules { on_merge: true, on_close: false, idle_ms: Some(7 * DAY_MS) }
    );
    let flat = json!({"agents.autoSettle.onClose": true, "agents.autoSettle.idleDays": 0});
    assert_eq!(rules(Some(&flat)), Rules { on_merge: false, on_close: true, idle_ms: None });
    let wild = json!({"agents.autoSettle.idleDays": 9000});
    assert_eq!(rules(Some(&wild)).idle_ms, Some(IDLE_DAYS_MAX * DAY_MS), "clamped");
}

#[test]
fn every_pull_request_must_be_done_and_a_merge_wins() {
    let now = 10 * DAY_MS;
    let f = facts(&[1, 2], now);
    let merged = [(1, PrState::Merged), (2, PrState::Closed)];
    assert_eq!(decide(&ALL, &f, states(&merged), now), Some(Reason::Merged));
    let open = [(1, PrState::Merged), (2, PrState::Open)];
    assert_eq!(decide(&ALL, &f, states(&open), now), None, "one still open");
    assert_eq!(decide(&ALL, &f, states(&[(1, PrState::Merged)]), now), None, "one not read");
    let closed = [(1, PrState::Closed), (2, PrState::Closed)];
    assert_eq!(decide(&ALL, &f, states(&closed), now), Some(Reason::Closed));
    let merge_only = Rules { on_close: false, ..ALL };
    assert_eq!(decide(&merge_only, &f, states(&closed), now), None, "onClose off");
    let close_only = Rules { on_merge: false, ..ALL };
    assert_eq!(decide(&close_only, &f, states(&merged), now), None, "a merge needs onMerge");
}

#[test]
fn idle_days_count_from_the_last_record() {
    let f = facts(&[], DAY_MS);
    assert_eq!(decide(&ALL, &f, states(&[]), 4 * DAY_MS - 1), None);
    assert_eq!(decide(&ALL, &f, states(&[]), 4 * DAY_MS), Some(Reason::Idle));
    assert_eq!(idle_due_at(&ALL, &f), Some(4 * DAY_MS));
    let no_idle = Rules { idle_ms: None, ..ALL };
    assert_eq!(decide(&no_idle, &f, states(&[]), 400 * DAY_MS), None);
    assert_eq!(idle_due_at(&no_idle, &f), None);
}

#[test]
fn never_archived_and_held_chats_are_left_alone() {
    let now = 100 * DAY_MS;
    let done = [(1, PrState::Merged)];
    let never = Facts { never: true, ..facts(&[1], 0) };
    assert_eq!(decide(&ALL, &never, states(&done), now), None);
    assert_eq!(idle_due_at(&ALL, &never), None);
    let archived = Facts { archived: true, ..facts(&[1], 0) };
    assert_eq!(decide(&ALL, &archived, states(&done), now), None);
    // Un-settled with one pull request: that one does not settle it again, idle days still do.
    let held = Facts { held_at: Some(1), ..facts(&[1], now) };
    assert_eq!(decide(&ALL, &held, states(&done), now), None);
    assert!(to_read(&ALL, &held, states(&[])).is_empty(), "nothing to read for it");
    assert_eq!(decide(&ALL, &held, states(&done), now + 3 * DAY_MS), Some(Reason::Idle));
    // A new pull request does.
    let newer = Facts { held_at: Some(1), ..facts(&[1, 2], now) };
    let both = [(1, PrState::Merged), (2, PrState::Merged)];
    assert_eq!(decide(&ALL, &newer, states(&both), now), Some(Reason::Merged));
}

#[test]
fn every_pull_request_but_a_merged_one_is_read() {
    let f = facts(&[1, 2, 3, 4], 0);
    let known = [(1, PrState::Merged), (2, PrState::Open), (4, PrState::Closed)];
    let read = to_read(&ALL, &f, states(&known));
    assert_eq!(
        read,
        vec![url(2).as_str(), url(3).as_str(), url(4).as_str()],
        "a closed one can reopen"
    );
    let idle_only = Rules { on_merge: false, on_close: false, ..ALL };
    assert!(to_read(&idle_only, &f, states(&[])).is_empty(), "no pull request rule on");
}

#[test]
fn a_closed_read_goes_stale_and_a_merged_one_does_not() {
    let mut states = PrStates::default();
    states.set(&url(1), PrState::Closed);
    states.set(&url(2), PrState::Merged);
    let later = now_ms() + PR_RECHECK_MS;
    assert!(states.read_due(&url(1), later), "a reopen is seen");
    assert!(!states.read_due(&url(2), later));
}

/// With a pull request rule on, the loop never sleeps to a far idle deadline: a chat's first pull
/// request, or one merged on GitHub, sends no wake.
#[test]
fn the_sleep_is_capped_while_a_pull_request_rule_is_on() {
    let now = 1_000;
    let far = Some(now + 7 * DAY_MS);
    let merge_and_idle = Rules { on_merge: true, idle_ms: Some(7 * DAY_MS), ..Rules::default() };
    let wait = Hub::auto_settle_wait(&merge_and_idle, far, now);
    assert_eq!(wait.as_millis() as u64, PR_RECHECK_MS);
    let idle_only = Rules { idle_ms: Some(7 * DAY_MS), ..Rules::default() };
    assert_eq!(Hub::auto_settle_wait(&idle_only, far, now).as_millis() as u64, 7 * DAY_MS);
}

#[test]
fn the_github_read_parses() {
    assert_eq!(parse_state("open false\n"), Some(PrState::Open));
    assert_eq!(parse_state("closed true"), Some(PrState::Merged));
    assert_eq!(parse_state("closed false"), Some(PrState::Closed));
    assert_eq!(parse_state(""), None);
    assert_eq!(parse_state("gh: Not Found"), None);
    assert_eq!(pr_path("https://github.com/o/r/pull/5"), Some(("o/r".into(), 5)));
    for bad in [
        "https://github.com/o/r/issues/5",
        "https://github.com/o/r/pull/x",
        "https://github.com/o/r/pull/5/files",
        "https://github.com/o;rm/r/pull/5",
        "https://github.com/../r/pull/5",
        "https://github.com/o/./pull/5",
        "http://github.com/o/r/pull/5",
    ] {
        assert_eq!(pr_path(bad), None, "{bad}");
    }
}

async fn chat() -> (Arc<Hub>, Arc<Session>) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let session = hub.new_session(req).await.unwrap();
    (hub, session)
}

fn tag(session: &Session, key: &str) -> Option<String> {
    session.read_meta(|m| m.tags.get(key).map(|t| t.value.clone()))
}

/// A chat whose pull request merged settles, archived with why; a queued prompt holds it; the
/// Undo (Unarchive) brings it back and the same pull request does not settle it again.
#[tokio::test]
async fn a_pass_settles_holds_and_unsettles() {
    let (hub, session) = chat().await;
    let pr = format!("https://github.com/o/settle-pass-{}/pull/1", session.id);
    session.meta.lock().unwrap().pull_requests.push(pr.clone());
    let mut states = PrStates::default();
    states.set(&pr, PrState::Merged);
    let rules = Rules { on_merge: true, ..Rules::default() };

    session.queued.fetch_add(1, Ordering::SeqCst);
    hub.auto_settle_pass(&rules, &mut states).await;
    assert_eq!(tag(&session, SETTLED_TAG), None, "a queued prompt holds it");
    session.queued.fetch_sub(1, Ordering::SeqCst);

    hub.auto_settle_pass(&rules, &mut states).await;
    assert_eq!(tag(&session, SETTLED_TAG).as_deref(), Some("merged"));
    assert!(tag(&session, ARCHIVED_TAG).is_some(), "settled is archived");

    hub.unarchive(&session).unwrap();
    assert_eq!(tag(&session, SETTLED_TAG), None);
    assert_eq!(tag(&session, ARCHIVED_TAG), None);
    assert_eq!(tag(&session, UNSETTLED_TAG).as_deref(), Some("1"));
    hub.auto_settle_pass(&rules, &mut states).await;
    assert_eq!(tag(&session, SETTLED_TAG), None, "the same pull request does not settle it again");
    hub.shutdown_all().await;
}

/// The chat's own override keeps it; a person's prompt is what un-settles an idle-settled chat.
#[tokio::test]
async fn never_keeps_it_and_the_persons_prompt_brings_it_back() {
    let (hub, session) = chat().await;
    let rules = Rules { idle_ms: Some(DAY_MS), ..Rules::default() };
    let mut states = PrStates::default();
    {
        let mut m = session.meta.lock().unwrap();
        m.updated_at = 1;
        m.tags.insert(
            OVERRIDE_TAG.into(),
            crate::store::Tag { value: NEVER.into(), expires_at: None },
        );
    }
    hub.auto_settle_pass(&rules, &mut states).await;
    assert_eq!(tag(&session, SETTLED_TAG), None, "autoSettle=never");

    session.meta.lock().unwrap().tags.remove(OVERRIDE_TAG);
    session.meta.lock().unwrap().updated_at = 1;
    hub.auto_settle_pass(&rules, &mut states).await;
    assert_eq!(tag(&session, SETTLED_TAG).as_deref(), Some("idle"));

    hub.unsettle_on_person_prompt(&session);
    assert_eq!(tag(&session, ARCHIVED_TAG), None);
    assert_eq!(tag(&session, SETTLED_TAG), None);
    // A plain Archive is not settled: the person's prompt leaves it archived.
    hub.set_tags_answered(
        &session,
        Some(&serde_json::Map::from_iter([(ARCHIVED_TAG.to_owned(), json!("1"))])),
        &[],
        None,
    )
    .unwrap();
    hub.unsettle_on_person_prompt(&session);
    assert!(tag(&session, ARCHIVED_TAG).is_some());
    // Unarchiving that plain Archive holds it too: its merged pull requests do not hide it again.
    hub.unarchive(&session).unwrap();
    assert_eq!(tag(&session, UNSETTLED_TAG).as_deref(), Some("0"));
    hub.shutdown_all().await;
}

/// A chat whose log moved, or that was unarchived, after the pass read it does not settle, even
/// within the same millisecond: the check and the write are one step under the meta lock.
#[tokio::test]
async fn a_change_after_the_read_keeps_it() {
    let (hub, session) = chat().await;
    session.meta.lock().unwrap().updated_at = 1;
    let seen = session.read_meta(Facts::of);
    session.meta.lock().unwrap().updated_at = 2;
    assert!(!hub.settle(&session, Reason::Idle, &seen).unwrap(), "a record after the read");
    assert_eq!(tag(&session, SETTLED_TAG), None);

    // An unarchive of a chat that is neither archived nor settled changes nothing: no record
    // (its idle days stay) and no hold.
    assert!(!hub.unarchive(&session).unwrap());
    assert_eq!(tag(&session, UNSETTLED_TAG), None);

    hub.set_archived(&session, true, false).unwrap();
    let seen = session.read_meta(Facts::of);
    let updated_at = seen.last_activity_ms;
    assert!(hub.unarchive(&session).unwrap());
    // The Unarchive's own record, put back to the read's time: only its tag tells it apart.
    session.meta.lock().unwrap().updated_at = updated_at;
    assert!(!hub.settle(&session, Reason::Idle, &seen).unwrap(), "unarchived after the read");
    assert_eq!(tag(&session, ARCHIVED_TAG), None);
    assert_eq!(tag(&session, UNSETTLED_TAG).as_deref(), Some("0"), "the hold stays");

    let seen = session.read_meta(Facts::of);
    assert!(hub.settle(&session, Reason::Idle, &seen).unwrap());
    assert_eq!(tag(&session, SETTLED_TAG).as_deref(), Some("idle"));
    hub.shutdown_all().await;
}

/// A closed pull request that is reopened keeps its chat: the next read sees it open.
#[tokio::test]
async fn a_reopened_pull_request_keeps_it() {
    let (hub, session) = chat().await;
    let pr = format!("https://github.com/o/settle-reopen-{}/pull/1", session.id);
    session.meta.lock().unwrap().pull_requests.push(pr.clone());
    let rules = Rules { on_close: true, ..Rules::default() };
    let mut states = PrStates::default();
    states.set(&pr, PrState::Closed);
    session.queued.fetch_add(1, Ordering::SeqCst);
    hub.auto_settle_pass(&rules, &mut states).await;
    session.queued.fetch_sub(1, Ordering::SeqCst);
    // Reopened on GitHub while it was busy; the next read says so.
    states.set(&pr, PrState::Open);
    hub.auto_settle_pass(&rules, &mut states).await;
    assert_eq!(tag(&session, SETTLED_TAG), None);
    hub.shutdown_all().await;
}

/// The chat menu's Never Settle (`_acpmux/auto_settle`): sets and removes only the override, says
/// whether it changed, and the rule then leaves the chat alone until it is removed.
#[tokio::test]
async fn never_settle_from_the_menu_sets_and_clears_the_override() {
    let (hub, session) = chat().await;
    let rules = Rules { idle_ms: Some(DAY_MS), ..Rules::default() };
    let mut states = PrStates::default();
    assert_eq!(hub.auto_settle_state(&session)["never"], json!(false));

    assert!(hub.set_settle_never(&session, true).unwrap());
    assert!(!hub.set_settle_never(&session, true).unwrap(), "already never: no change");
    assert_eq!(tag(&session, OVERRIDE_TAG).as_deref(), Some(NEVER));
    assert_eq!(hub.auto_settle_state(&session)["never"], json!(true));
    session.meta.lock().unwrap().updated_at = 1;
    hub.auto_settle_pass(&rules, &mut states).await;
    assert_eq!(tag(&session, SETTLED_TAG), None, "never keeps it");

    assert!(hub.set_settle_never(&session, false).unwrap());
    assert!(!hub.set_settle_never(&session, false).unwrap(), "already follows: no change");
    assert_eq!(tag(&session, OVERRIDE_TAG), None);
    session.meta.lock().unwrap().updated_at = 1;
    hub.auto_settle_pass(&rules, &mut states).await;
    assert_eq!(tag(&session, SETTLED_TAG).as_deref(), Some("idle"), "back on the rule");
    hub.shutdown_all().await;
}
