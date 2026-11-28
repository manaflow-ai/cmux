//! Which `session/new` counts as a sub-session for the one-parent rule (`hub/agent_vm.rs`).
//! An agent that omits `parent` starts a child of its own session (`lineage::ParentAsk::Caller`),
//! so a leased VM must not refuse it as a second parent (the before refused it).

use super::starts_sub_session;
use crate::hub::lineage::{ParentAsk, parent_ask};
use serde_json::json;

#[test]
fn an_agent_omitting_parent_starts_a_sub_session() {
    let ask = parent_ask(Some(&json!({}))).ok();
    assert_eq!(ask, Some(ParentAsk::Caller));
    assert!(starts_sub_session(ask, true));
}

#[test]
fn a_person_omitting_parent_starts_a_parent() {
    assert!(!starts_sub_session(parent_ask(None).ok(), false));
}

#[test]
fn a_named_parent_is_a_sub_session_and_null_is_a_root() {
    assert!(starts_sub_session(parent_ask(Some(&json!({"parent": "s1"}))).ok(), false));
    assert!(!starts_sub_session(parent_ask(Some(&json!({"parent": null}))).ok(), true));
}
