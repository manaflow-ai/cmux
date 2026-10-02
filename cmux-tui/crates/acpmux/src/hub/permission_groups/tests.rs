use super::*;

fn request(kind: &str) -> Value {
    json!({"toolCall":{"kind":kind,"title":"fixture","rawInput":{"path":"a.txt"}},
        "options":[{"kind":"allow_once","optionId":"yes"},{"kind":"reject_once","optionId":"no"}]})
}

#[test]
fn permission_groups_fixed_window_and_partition() {
    let mut state = PermissionState::default();
    let now = Instant::now();
    let req = request("edit");
    let (a, fresh) = state.register("a", &req, Some("turn-1".into()), 0, now).unwrap();
    assert!(fresh);
    let (b, fresh) = state.register("b", &req, Some("turn-1".into()), 0, now + WINDOW / 2).unwrap();
    assert_eq!(a,b);
    assert!(!fresh);
    // Exact boundary seals membership even if the timer has not been scheduled.
    let (c, _) = state.register("c", &req, Some("turn-1".into()), 0, now + WINDOW).unwrap();
    assert_ne!(a,c);
    let (d, _) = state.register("d", &req, Some("turn-2".into()), 0, now).unwrap();
    assert_ne!(a,d);
    let (e, _) = state.register("e", &req, Some("turn-1".into()), 1, now).unwrap();
    assert_ne!(a,e);
    assert_eq!(state.groups[0].items.len(),2);
    assert_eq!(state.groups[0].revision,2);
}

#[test]
fn permission_groups_item_and_pending_bounds() {
    let mut state = PermissionState::default();
    let now = Instant::now();
    let req = request("execute");
    for i in 0..=MAX_ITEMS {
        state.register(&i.to_string(), &req, Some("turn".into()), 0, now).unwrap();
    }
    assert_eq!(state.groups[0].items.len(),MAX_ITEMS);
    assert_eq!(state.groups[1].items.len(),1);
    for i in state.groups.len()..MAX_GROUPS {
        state.register(&format!("other-{i}"), &req, Some(format!("turn-{i}")), 0, now).unwrap();
    }
    let error = state.register("overflow", &req, Some("overflow".into()),0,now).unwrap_err();
    assert_eq!(error.data.unwrap()["reason"],"budget_exceeded");
}

#[test]
fn permission_groups_terminal_retention_never_prunes_pending() {
    let mut state = PermissionState::default();
    let now = Instant::now();
    let req = request("edit");
    let (pending,_) = state.register("pending",&req,Some("pending".into()),0,now).unwrap();
    for i in 0..MAX_GROUPS+2 {
        let id = format!("item-{i}");
        state.register(&id,&req,Some(id.clone()),0,now).unwrap();
        state.finish_item("s",&id,false).unwrap();
    }
    assert_eq!(state.groups.iter().filter(|g|g.terminal()).count(),MAX_GROUPS);
    assert!(state.groups.iter().any(|g|g.id==pending));
}

#[test]
fn permission_groups_legacy_partial_is_revision_checked() {
    let mut state = PermissionState::default();
    let now = Instant::now();
    let req = request("edit");
    state.register("a",&req,Some("turn".into()),0,now).unwrap();
    state.register("b",&req,Some("turn".into()),0,now).unwrap();
    state.groups[0].state = "pending";
    let value = state.finish_item("s","a",false).unwrap();
    assert_eq!(value["revision"],3);
    assert_eq!(value["state"],"pending");
    assert_eq!(value["items"][1]["state"],"pending");
    assert!(state.finish_item("s","a",false).is_none());
    assert_eq!(state.finish_item("s","b",true).unwrap()["state"],"cancelled");
}

#[test]
fn permission_groups_eligibility_and_safe_option_kinds() {
    assert!(eligible(&request("edit")));
    for kind in ["other", "", "custom"] { assert!(!eligible(&request(kind))); }
    let mut req = request("edit");
    req["toolCall"]["_meta"] = json!({"acpmux":{"interactive":true}});
    assert!(!eligible(&req));
    req["toolCall"]["_meta"] = json!({"claude":{"interactive":true}});
    assert!(!eligible(&req));
    req["toolCall"]["_meta"] = json!({"claude":{"tool":"ExitPlanMode"}});
    assert!(!eligible(&req));
    req["toolCall"]["_meta"] = Value::Null;
    req["_meta"] = json!({"acpmux":{"interactive":true}});
    assert!(!eligible(&req));
    req["_meta"] = Value::Null;
    req["options"] = json!([{"kind":"allow_always","optionId":"allow"}]);
    assert!(eligible(&req)); // Can group, but only deny is offered.
    assert!(option(&req,"allow_once").is_none());
    assert!(option(&json!({"options":[{"kind":"allow_once","optionId":""}]}),"allow_once").is_none());
}
