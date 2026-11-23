//! `agentPane.sessionWorktrees`: a choice row, Off by default, that the
//! daemon reads as a typed value and an agent may set.

use cmux_config::Schema;
use cmux_config::session_worktrees::{KEY, SessionWorktrees};
use serde_json::json;

#[test]
fn the_embedded_schema_has_the_row_off_by_default() {
    let schema = Schema::embedded();
    let row = schema.rows.iter().find(|row| row.key == KEY).expect("the row is in the schema");
    assert_eq!(row.default, Some(json!("off")));
}

#[test]
fn a_value_reads_as_its_choice_and_anything_else_as_off() {
    assert_eq!(SessionWorktrees::default(), SessionWorktrees::Off);
    assert_eq!(SessionWorktrees::parse(None), SessionWorktrees::Off);
    assert_eq!(SessionWorktrees::parse(Some(&json!("off"))), SessionWorktrees::Off);
    assert_eq!(SessionWorktrees::parse(Some(&json!("shared"))), SessionWorktrees::Shared);
    assert_eq!(SessionWorktrees::parse(Some(&json!("project"))), SessionWorktrees::Project);
    assert_eq!(SessionWorktrees::parse(Some(&json!("elsewhere"))), SessionWorktrees::Off);
    assert_eq!(SessionWorktrees::parse(Some(&json!(true))), SessionWorktrees::Off);
    assert!(SessionWorktrees::Project.in_project());
    assert!(!SessionWorktrees::Shared.in_project());
    assert!(!SessionWorktrees::Off.in_project());
}
