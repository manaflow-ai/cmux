//! Mirrors `WorkspaceAutoNamerTests` and `WorkspaceAutoNameHoldTests`.

use super::*;

fn slot(workspace: &str) -> Slot {
    Slot { machine_id: "m1".into(), workspace_id: workspace.into() }
}

fn session(id: &str) -> AgentSession {
    AgentSession {
        host: "h".into(),
        host_name: None,
        session: Some(id.into()),
        harness: Some("claude".into()),
    }
}

fn target(workspace: &str, generation: &str, revision: u64) -> Target {
    Target {
        machine_id: "m1".into(),
        workspace_id: workspace.into(),
        daemon_generation: Some(generation.into()),
        name_revision: revision,
    }
}

fn rename(workspace: &str, generation: &str, revision: u64, tab: &str, name: &str) -> Rename {
    Rename {
        machine_id: "m1".into(),
        workspace_id: workspace.into(),
        daemon_generation: Some(generation.into()),
        name_revision: revision,
        front_tab_id: tab.into(),
        front_agent_session: session(tab),
        name: name.into(),
    }
}

/// Plans then applies `candidate` against itself as current: the attempt.
fn submit(namer: &mut Namer, candidate: &Rename) -> Option<u64> {
    let target = Target {
        machine_id: candidate.machine_id.clone(),
        workspace_id: candidate.workspace_id.clone(),
        daemon_generation: candidate.daemon_generation.clone(),
        name_revision: candidate.name_revision,
    };
    let planned = namer.plan(&target, Some(candidate.clone()))?;
    namer.apply(&planned, Some(candidate))
}

#[test]
fn a_candidate_is_submitted_once() {
    let mut namer = Namer::default();
    namer.list(&[slot("w1")]);
    let fix = rename("w1", "g1", 0, "t1", "Fix login");
    assert_eq!(submit(&mut namer, &fix), Some(0));
    assert_eq!(namer.plan(&target("w1", "g1", 0), Some(fix.clone())), None);
    assert_eq!(namer.apply(&fix, Some(&fix)), None);
    assert!(namer.may_send(&slot("w1"), 0, Some(&fix)));
}

#[test]
fn a_new_revision_drops_the_old_submission() {
    let mut namer = Namer::default();
    namer.list(&[slot("w1")]);
    let fix = rename("w1", "g1", 0, "t1", "Fix login");
    submit(&mut namer, &fix);
    assert_eq!(namer.plan(&target("w1", "g1", 1), None), None);
    assert!(namer.submitted.is_empty());
}

#[test]
fn a_new_daemon_run_drops_the_old_submission() {
    let mut namer = Namer::default();
    namer.list(&[slot("w1")]);
    submit(&mut namer, &rename("w1", "g1", 0, "t1", "Fix login"));
    let again = rename("w1", "g2", 0, "t1", "Fix login");
    assert_eq!(namer.plan(&target("w1", "g2", 0), Some(again.clone())), Some(again));
    assert!(namer.submitted.is_empty());
}

#[test]
fn a_different_candidate_replaces_the_live_one() {
    let mut namer = Namer::default();
    namer.list(&[slot("w1")]);
    submit(&mut namer, &rename("w1", "g1", 0, "t1", "Fix login"));
    let other = rename("w1", "g1", 0, "t2", "Add tests");
    assert_eq!(namer.plan(&target("w1", "g1", 0), Some(other.clone())), Some(other.clone()));
    assert_eq!(namer.apply(&other, Some(&other)), Some(1));
    assert!(!namer.may_send(&slot("w1"), 0, Some(&other)));
    assert!(namer.may_send(&slot("w1"), 1, Some(&other)));
}

#[test]
fn deferred_send_rechecks_and_retries_once() {
    let mut namer = Namer::default();
    namer.list(&[slot("w1")]);
    let fix = rename("w1", "g1", 0, "t1", "Fix login");
    let attempt = submit(&mut namer, &fix).unwrap();
    assert_eq!(namer.retries.get(&slot("w1")), Some(&0));
    let moved = rename("w1", "g1", 0, "t2", "Fix login");
    assert!(!namer.may_send(&slot("w1"), attempt, Some(&moved)));
    assert_eq!(namer.retries.get(&slot("w1")), Some(&1));
    assert!(namer.submitted.is_empty());
    // A second stale callback of the same attempt does not advance the mark.
    assert!(!namer.may_send(&slot("w1"), attempt, Some(&moved)));
    assert_eq!(namer.retries.get(&slot("w1")), Some(&1));
}

#[test]
fn deferred_send_with_no_key_is_stale() {
    let mut namer = Namer::default();
    namer.list(&[slot("w1")]);
    let attempt = submit(&mut namer, &rename("w1", "g1", 0, "t1", "Fix login")).unwrap();
    assert!(!namer.may_send(&slot("w1"), attempt, None));
    assert_eq!(namer.retries.get(&slot("w1")), Some(&1));
}

#[test]
fn deferred_send_checks_every_field() {
    let fix = rename("w1", "g1", 0, "t1", "Fix login");
    let mut renamed = fix.clone();
    renamed.name = "Other".into();
    let mut revised = fix.clone();
    revised.name_revision = 1;
    let mut restarted = fix.clone();
    restarted.daemon_generation = None;
    let mut chat = fix.clone();
    chat.front_agent_session.host_name = Some("mac".into());
    for current in [renamed, revised, restarted, chat] {
        let mut namer = Namer::default();
        namer.list(&[slot("w1")]);
        let attempt = submit(&mut namer, &fix).unwrap();
        assert!(!namer.may_send(&slot("w1"), attempt, Some(&current)), "{current:?}");
    }
}

#[test]
fn an_old_attempt_cannot_own_a_reused_candidate() {
    let mut namer = Namer::default();
    namer.list(&[slot("w1")]);
    let fix = rename("w1", "g1", 0, "t1", "Fix login");
    let first = submit(&mut namer, &fix).unwrap();
    namer.release(&slot("w1"), first);
    let second = submit(&mut namer, &fix).unwrap();
    assert_ne!(first, second);
    namer.release(&slot("w1"), first);
    assert!(!namer.may_send(&slot("w1"), first, Some(&fix)));
    assert!(namer.may_send(&slot("w1"), second, Some(&fix)));
}

#[test]
fn a_failed_accepted_send_releases_only_the_older_candidate() {
    let mut namer = Namer::default();
    namer.list(&[slot("w1")]);
    let fix = rename("w1", "g1", 0, "t1", "Fix login");
    let older = submit(&mut namer, &fix).unwrap();
    let newer_candidate = rename("w1", "g1", 0, "t1", "Fix login flow");
    let newer = submit(&mut namer, &newer_candidate).unwrap();
    namer.release(&slot("w1"), older);
    assert_eq!(namer.submitted.get(&slot("w1")).map(|live| live.attempt), Some(newer));
    namer.release(&slot("w1"), newer);
    assert!(namer.submitted.is_empty());
    // A failure is not a retry.
    assert_eq!(namer.retries.get(&slot("w1")), Some(&0));
}

#[test]
fn a_removed_target_drops_its_submission() {
    let mut namer = Namer::default();
    namer.list(&[slot("w1"), slot("w2")]);
    let attempt = submit(&mut namer, &rename("w1", "g1", 0, "t1", "Fix login")).unwrap();
    submit(&mut namer, &rename("w2", "g1", 0, "t9", "Docs"));
    namer.list(&[slot("w2")]);
    assert!(!namer.submitted.contains_key(&slot("w1")));
    assert!(!namer.retries.contains_key(&slot("w1")));
    assert!(!namer.may_send(&slot("w1"), attempt, None));
    assert!(namer.submitted.contains_key(&slot("w2")));
}

#[test]
fn an_unlisted_workspace_is_not_applied() {
    let mut namer = Namer::default();
    let fix = rename("w1", "g1", 0, "t1", "Fix login");
    assert_eq!(namer.apply(&fix, Some(&fix)), None);
    assert_eq!(namer.next_attempt_id, 0);
}

#[test]
fn setting_off_asks_for_nothing() {
    let mut namer = Namer::default();
    namer.list(&[slot("w1")]);
    assert_eq!(namer.plan(&target("w1", "g1", 0), None), None);
    assert!(namer.submitted.is_empty());
    assert_eq!(namer.retries.get(&slot("w1")), Some(&0));
}

#[test]
fn attempt_ids_wrap() {
    let mut namer = Namer { next_attempt_id: u64::MAX, ..Namer::default() };
    namer.list(&[slot("w1")]);
    assert_eq!(submit(&mut namer, &rename("w1", "g1", 0, "t1", "a")), Some(u64::MAX));
    assert_eq!(namer.next_attempt_id, 0);
}

#[test]
fn namer_state_round_trips_as_lists() {
    let mut namer = Namer::default();
    namer.list(&[slot("w1"), slot("w2")]);
    let attempt = submit(&mut namer, &rename("w1", "g1", 3, "t1", "Fix login")).unwrap();
    namer.may_send(&slot("w1"), attempt, None);
    submit(&mut namer, &rename("w2", "g1", 0, "t2", "Docs"));
    let json = serde_json::to_value(&namer).unwrap();
    assert!(json["submitted"].is_array());
    assert_eq!(json["retries"][0]["revision"], 1);
    let back: Namer = serde_json::from_value(json).unwrap();
    assert_eq!(back, namer);
}

#[test]
fn hold_keeps_a_namers_last_label() {
    let mut hold = Hold::default();
    assert_eq!(hold.settle("w1", "t1", None), None);
    assert_eq!(hold.settle("w1", "t1", Some("Fix login")).as_deref(), Some("Fix login"));
    assert_eq!(hold.settle("w1", "t1", None).as_deref(), Some("Fix login"));
    assert_eq!(hold.settle("w1", "t2", None), None);
    assert_eq!(hold.settle("w2", "t1", None), None);
    assert_eq!(hold.settle("w1", "t1", Some("Add tests")).as_deref(), Some("Add tests"));
    assert_eq!(hold.settle("w1", "t1", None).as_deref(), Some("Add tests"));
}

#[test]
fn hold_forgets_a_user_named_workspace() {
    let mut hold = Hold::default();
    hold.settle("w1", "t1", Some("Fix login"));
    hold.settle("w2", "t1", Some("Docs"));
    hold.forget("w1");
    assert_eq!(hold.settle("w1", "t1", None), None);
    assert_eq!(hold.settle("w2", "t1", None).as_deref(), Some("Docs"));
}

#[test]
fn launcher_named_survives_an_agent_rename_until_the_name_or_chat_changes() {
    let mut hold = Hold::default();
    assert!(!hold.launcher_named("w1", "claude", "s1", false));
    assert!(hold.launcher_named("w1", "claude", "s1", true));
    assert!(hold.launcher_named("w1", "claude", "s1", false));
    assert!(!hold.launcher_named("w1", "renamed", "s1", false));
    assert!(!hold.launcher_named("w1", "claude", "s2", false));
    assert!(!hold.launcher_named("w2", "claude", "s1", false));
}
