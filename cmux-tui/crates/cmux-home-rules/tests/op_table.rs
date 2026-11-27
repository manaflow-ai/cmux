//! The op table: every listed op answers, and nothing else does.

use cmux_home_rules::{OpError, call, ops};
use serde_json::{Value, json};

#[test]
fn ops_list_names_every_area_op_once() {
    let listed = call("ops.list", &json!({})).expect("ops.list");
    let names: Vec<String> = serde_json::from_value(listed).expect("a list of names");
    assert_eq!(names, ops::op_names());
    let mut sorted = names.clone();
    sorted.sort();
    sorted.dedup();
    assert_eq!(sorted.len(), names.len(), "an op is listed twice");
    for name in &names {
        let (area, _) = name.split_once('.').expect("AREA.NAME");
        assert!(area == "ops" || ops::AREAS.contains(&area), "{name}: not an area");
    }
}

#[test]
fn every_listed_op_is_known() {
    for name in ops::op_names() {
        // An empty request may be invalid for an op, but never unknown.
        assert_ne!(
            call(&name, &json!({})),
            Err(OpError::Unknown),
            "{name} is listed but not routed"
        );
    }
}

#[test]
fn unknown_ops_are_unknown() {
    for name in ["", "inbox", "nope.x", "inbox.nope", "ops.nope", ".list"] {
        assert_eq!(call(name, &Value::Null), Err(OpError::Unknown), "{name}");
    }
}
