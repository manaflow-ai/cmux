//! The waits' rules and the start's words (moved from the app's `CloudStartCoreTests`,
//! `CloudStartChatMachineTests` and the Swift `CloudWait`, `CloudStartRuns` and `CloudListFreshness`).

use super::*;
use serde_json::json;

#[test]
fn a_failure_that_showed_before_the_wait_ends_it_only_after_it_cleared() {
    // The last link's failure shows when the wait begins: not this connect's.
    assert_eq!(
        link_look(LinkLook { connected: false, failed: true, cleared: false }),
        (false, false)
    );
    // It clears: the connect is running.
    assert_eq!(
        link_look(LinkLook { connected: false, failed: false, cleared: false }),
        (false, true)
    );
    // It fails again: this connect's failure ends the wait.
    assert_eq!(link_look(LinkLook { connected: false, failed: true, cleared: true }), (true, true));
    assert!(link_look(LinkLook { connected: true, failed: true, cleared: false }).0);
}

#[test]
fn a_new_link_is_a_changed_handshake() {
    assert!(relinked(Some("old"), Some("new"), false));
    assert!(!relinked(Some("old"), Some("old"), false));
    assert!(!relinked(Some("old"), None, false));
    assert!(relinked(None, Some("new"), false));
    assert!(!relinked(Some("old"), Some("refused"), false), "a refused handshake is no new link");
    assert!(relinked(Some("old"), Some("refused"), true), "for a copy any other link is one");
}

#[test]
fn only_a_closed_connection_or_a_gone_or_refused_socket_is_a_dropped_link() {
    assert!(link_dropped(&StartFailure::ConnectionClosed));
    assert!(link_dropped(&StartFailure::ConnectFailed { code: ENOENT }));
    assert!(link_dropped(&StartFailure::ConnectFailed { code: ECONNREFUSED }));
    assert!(!link_dropped(&StartFailure::ConnectFailed { code: 13 }));
    assert!(!link_dropped(&StartFailure::Other));
    let read: StartFailure =
        serde_json::from_value(json!({"kind": "connectFailed", "code": 2})).unwrap();
    assert!(link_dropped(&read));
}

#[test]
fn only_the_machines_older_daemon_refusing_updates_it_first() {
    assert!(updates_before_copying_again(false, Some("machine_outdated"), Some("target")));
    assert!(updates_before_copying_again(false, Some("machine_outdated"), None));
    assert!(
        !updates_before_copying_again(false, Some("machine_outdated"), Some("source")),
        "this Mac's own daemon"
    );
    assert!(!updates_before_copying_again(true, Some("machine_outdated"), None));
    assert!(!updates_before_copying_again(false, Some("io"), None));
}

#[test]
fn a_kept_run_lasts_ten_minutes_and_at_most_thirty_two_are_kept() {
    assert!(run_reusable(600_000));
    assert!(!run_reusable(600_001));
    let kept: Vec<KeptRun> = (0..5).map(|id| KeptRun { id, age_ms: 1_000 * (5 - id) }).collect();
    assert_eq!(runs_to_drop(&kept, 3), [0, 1], "the oldest beyond the limit");
    let expired = [KeptRun { id: 9, age_ms: 700_000 }, KeptRun { id: 1, age_ms: 10 }];
    assert_eq!(runs_to_drop(&expired, 32), [9]);
    assert_eq!(DEADLINES.runs_kept, 32);
}

#[test]
fn a_list_answers_only_for_its_account_while_fresh() {
    let me = [Some("u".to_owned()), None];
    let team = [Some("u".to_owned()), Some("t".to_owned())];
    assert!(list_current(Some(10), Some(&me), &me, 30_000));
    assert!(!list_current(Some(30_000), Some(&me), &me, 30_000));
    assert!(!list_current(Some(10), Some(&team), &me, 30_000), "another team's list");
    assert!(!list_current(None, Some(&me), &me, 30_000));
    assert!(!list_current(Some(10), None, &me, 30_000));
}

/// A start that is not an agent chat's starts as the person's when the person asked for it or
/// lets agents start without asking (#35191).
#[test]
fn a_start_is_the_persons_when_they_asked_or_let_agents_start_without_asking() {
    assert!(starts_as_person(true, false));
    assert!(starts_as_person(true, true));
    assert!(starts_as_person(false, true));
    assert!(!starts_as_person(false, false));
}

/// Only a personal send on a non-production sign-in copies through the content-addressed store (#34604).
#[test]
fn only_a_personal_send_on_a_non_production_sign_in_copies_through_the_store() {
    let user = |team: Option<&str>| vec![Some("user".to_owned()), team.map(str::to_owned)];
    assert!(copies_through_store(&[], false));
    assert!(copies_through_store(&user(None), false));
    assert!(!copies_through_store(&user(None), true));
    assert!(!copies_through_store(&user(Some("team")), false));
    assert!(!copies_through_store(&user(Some("team")), true));
}

#[test]
fn a_start_command_word_is_one_shell_word() {
    assert_eq!(shell_quoted("dev-1"), "dev-1");
    assert_eq!(shell_quoted(""), "''");
    assert_eq!(shell_quoted("my dev"), "'my dev'");
    assert_eq!(shell_quoted("it's"), r"'it'\''s'");
    assert_eq!(shell_quoted("a;rm -rf ~"), "'a;rm -rf ~'");
    assert_eq!(shell_quoted("Renée"), "'Renée'");
}

#[test]
fn the_plan_request_carries_the_send_its_account_workspace_and_the_listed_machines() {
    let me = Some("user-leo".to_owned());
    let read = |facts: PlanFacts| serde_json::from_str::<Value>(&plan_request(&facts)).unwrap();
    let request = read(PlanFacts {
        key: "K".into(),
        account: vec![me.clone(), Some("team-a".into())],
        workspace: Some("ws-1".into()),
        user: me,
        stored: vec!["vm-new".into()],
        ..PlanFacts::default()
    });
    assert_eq!(
        request,
        json!({"key": "K", "account": "user-leo/team-a", "workspace": "ws-1", "user": "user-leo", "loaded": true,
        "machines": [], "stored": ["vm-new"], "credential_on_stdin": false})
    );
    let unsigned =
        read(PlanFacts { key: "K".into(), account: vec![None, None], ..PlanFacts::default() });
    assert!(unsigned.get("user").is_none() && unsigned.get("workspace").is_none());
    // Zero-setup hot start: the folder, the chosen environment and that the token is on stdin.
    let hot = read(PlanFacts {
        local: Some("/Users/me/src/paint".into()),
        environment: Some("env_1".into()),
        access: true,
        ..PlanFacts::default()
    });
    assert_eq!(
        (hot["local"].as_str(), hot["environment"].as_str(), hot["credential_on_stdin"].as_bool()),
        (Some("/Users/me/src/paint"), Some("env_1"), Some(true))
    );
    let warm = read(PlanFacts {
        reservation_key: Some("R".into()),
        platform: Some("https://p".into()),
        team: Some("team_1".into()),
        ensure_project: Some(false),
        machines: vec![json!({"id": "vm-a"})],
        ..PlanFacts::default()
    });
    assert_eq!(
        (
            warm["reservation_key"].as_str(),
            warm["platform"].as_str(),
            warm["team"].as_str(),
            warm["ensure_project"].as_bool()
        ),
        (Some("R"), Some("https://p"), Some("team_1"), Some(false))
    );
    assert_eq!(warm["machines"], json!([{"id": "vm-a"}]));
}
