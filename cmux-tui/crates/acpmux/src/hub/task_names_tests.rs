//! `task_names.rs`: a session's name follows its task.

use super::super::former_names::tests::{chat, hub};
use super::*;
use crate::generic_goal::GoalRequest;

fn request(objective: &str) -> GoalRequest {
    GoalRequest {
        objective: objective.into(),
        done_when: "cargo test passes".into(),
        token_budget: None,
        time_budget_minutes: None,
    }
}

#[test]
fn a_title_becomes_a_lowercase_slug_of_whole_words() {
    assert_eq!(task_slug("Fix the sidebar spinner").as_deref(), Some("fix-the-sidebar-spinner"));
    assert_eq!(task_slug("  Ship #47928's  docs!  ").as_deref(), Some("ship-47928-s-docs"));
    assert_eq!(task_slug("Café menü").as_deref(), Some("caf-men"));
    assert_eq!(task_slug("日本語"), None);
    let long = task_slug("Make the acpmux daemon restart without losing any queued prompts");
    let long = long.unwrap();
    assert!(long.len() <= 40 && !long.ends_with('-'), "{long}");
    assert_eq!(long, "make-the-acpmux-daemon-restart-without");
    assert!(crate::session_name::validate(&long).is_ok());
}

#[test]
fn a_name_reads_as_words_in_its_title() {
    assert_eq!(name_in_words("session-name-aliases").as_deref(), Some("Session name aliases"));
    assert_eq!(name_in_words("snake_case_name").as_deref(), Some("Snake case name"));
    assert_eq!(name_in_words("coord/td2-a").as_deref(), Some("Td2 a"));
    assert_eq!(name_in_words("Already Words").as_deref(), Some("Already Words"));
    assert_eq!(name_in_words(""), None);
}

#[test]
fn fallback_names_are_no_task_names() {
    for generic in
        ["ask-0123abcd45", "claude-3", "claude-desktop-ab12cd34", "coordination", "codex-12"]
    {
        assert!(!is_task_name(generic), "{generic}");
    }
    for task in ["fix-the-sidebar-spinner", "session-name-aliases", "fix-27310-crash"] {
        assert!(is_task_name(task), "{task}");
    }
}

#[tokio::test]
async fn a_new_goal_renames_the_session_and_its_old_name_still_finds_it() {
    let hub = hub();
    let s = chat(&hub, "s1", "claude-3");
    hub.goal_set(&s, &request("Fix the spinner in the sidebar")).unwrap();
    let naming = hub.task_naming(&s, None).expect("a first goal names it");
    assert!(hub.name_after_task(&s, &naming, Some("Fix sidebar spinner".into())).await);
    let m = s.meta();
    assert_eq!(m.name, "fix-sidebar-spinner");
    assert_eq!(m.title.as_deref(), Some("Fix sidebar spinner"));
    assert_eq!(m.title_source.as_deref(), Some(TASK));
    assert_eq!(m.former_names, ["claude-3"]);
    assert_eq!(hub.resolve("claude-3").unwrap().id, "s1");

    // The objective changes: renamed again, both old names kept.
    let before = s.meta().goal.map(|g| g.objective);
    hub.goal_set(&s, &request("Write the release notes")).unwrap();
    let naming = hub.task_naming(&s, before.as_deref()).expect("a changed objective renames");
    assert!(hub.name_after_task(&s, &naming, Some("Write release notes".into())).await);
    assert_eq!(s.meta().name, "write-release-notes");
    assert_eq!(s.meta().former_names, ["claude-3", "fix-sidebar-spinner"]);
    assert_eq!(hub.resolve("fix-sidebar-spinner").unwrap().id, "s1");
}

#[tokio::test]
async fn the_same_objective_renames_only_a_fallback_name() {
    let hub = hub();
    let s = chat(&hub, "s1", "fix-sidebar-spinner");
    hub.goal_set(&s, &request("Fix the spinner")).unwrap();
    assert!(hub.task_naming(&s, Some("Fix the spinner")).is_none());
    let g = chat(&hub, "g1", "ask-0123abcd45");
    hub.goal_set(&g, &request("Fix the spinner")).unwrap();
    assert!(hub.task_naming(&g, Some("Fix the spinner")).is_some());
}

#[tokio::test]
async fn a_hand_rename_after_the_task_change_wins() {
    let hub = hub();
    let s = chat(&hub, "s1", "claude-3");
    hub.goal_set(&s, &request("Fix the spinner")).unwrap();
    let naming = hub.task_naming(&s, None).unwrap();
    // The person renames it while the title is asked for.
    hub.rename(&s, "my-own-name".into()).await.unwrap();
    assert!(!hub.name_after_task(&s, &naming, Some("Fix sidebar spinner".into())).await);
    assert_eq!(s.meta().name, "my-own-name");
    assert_eq!(s.meta().title.as_deref(), Some("My own name"));
    // A goal replaced while it was asked for: the older title names nothing either.
    let naming = hub.task_naming(&s, None).unwrap();
    hub.goal_set(&s, &request("Another task")).unwrap();
    assert!(!hub.name_after_task(&s, &naming, Some("Fix sidebar spinner".into())).await);
    assert_eq!(s.meta().name, "my-own-name");
}

#[tokio::test]
async fn an_empty_title_changes_nothing_and_a_taken_name_gets_a_number() {
    let hub = hub();
    let s = chat(&hub, "s1", "claude-3");
    hub.goal_set(&s, &request("Fix the spinner")).unwrap();
    let naming = hub.task_naming(&s, None).unwrap();
    assert!(!hub.name_after_task(&s, &naming, None).await);
    assert!(!hub.name_after_task(&s, &naming, Some("  ".into())).await);
    assert_eq!(s.meta().name, "claude-3");
    chat(&hub, "o1", "fix-sidebar-spinner");
    assert!(hub.name_after_task(&s, &naming, Some("Fix sidebar spinner".into())).await);
    assert_eq!(s.meta().name, "fix-sidebar-spinner-2");
}

#[tokio::test]
async fn a_sub_session_is_not_renamed_by_its_goal() {
    let hub = hub();
    let s = chat(&hub, "s1", "coord/claude-3");
    hub.goal_set(&s, &request("Fix the spinner")).unwrap();
    assert!(hub.task_naming(&s, None).is_none());
}
