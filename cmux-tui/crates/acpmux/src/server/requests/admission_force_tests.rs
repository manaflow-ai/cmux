use super::*;

#[test]
fn a_dispatch_keeps_the_name_its_caller_gave() {
    let named = json!({"name": "slam-09", "title": "Fix the bug"});
    assert_eq!(dispatch_name(&named, "brief"), "slam-09");
    // No name (or a blank one): made from the title, never the agent's.
    assert_eq!(dispatch_name(&json!({"title": "Fix the bug"}), "brief"), "fix-the-bug");
    assert_eq!(dispatch_name(&json!({"name": "  "}), "Do it\nmore"), "do-it");
}

#[test]
fn force_admit_is_honoured_only_from_this_machine() {
    let forced = json!({"_meta": {"acpmux": {"forceAdmit": true}}});
    assert!(force_asked(&forced));
    assert!(!force_asked(&json!({})));
    assert!(can_force(Origin::Local), "the unix socket");
    assert!(can_force(Origin::LocalApp), "the app");
    assert!(!can_force(Origin::Web), "a Web client");
    assert!(!can_force(Origin::Peer), "a peer");
}

/// Only an Auto start waits for a machine being added: an explicit choice from the app (this
/// Mac, which carries no `peer` either) is admitted as before the wait existed.
#[test]
fn only_an_auto_marked_start_may_wait_for_a_new_machine() {
    let this_mac = json!({"cwd": "/tmp", "_meta": {"acpmux": {"harness": "claude"}}});
    assert!(!auto_place_asked(Origin::LocalApp, &this_mac), "this Mac, from the app");
    assert!(!auto_place_asked(Origin::LocalApp, &json!({"cwd": "/tmp"})), "no _meta");
    let named = json!({"_meta": {"acpmux": {"peer": "box"}}});
    assert!(!auto_place_asked(Origin::LocalApp, &named), "a named machine");
    let off = json!({"_meta": {"acpmux": {"autoPlace": false}}});
    assert!(!auto_place_asked(Origin::LocalApp, &off));
    let auto = json!({"cwd": "/tmp", "_meta": {"acpmux": {"autoPlace": true}}});
    assert!(auto_place_asked(Origin::LocalApp, &auto), "the app's Auto start");
    assert!(auto_place_asked(Origin::Local, &auto), "acpmux new --host auto");
    assert!(!auto_place_asked(Origin::Peer, &auto), "a forwarded create waited already");
}

#[test]
fn the_admission_name_is_the_one_the_create_takes() {
    let name = |p: Value| create_name(&p);
    assert_eq!(name(json!({"name": "top"})).as_deref(), Some("top"));
    let both = json!({"name": "top", "_meta": {"acpmux": {"name": "meta"}}});
    assert_eq!(name(both).as_deref(), Some("meta"));
    // A `_meta` name that is not a string falls back to the top-level one, as the create does.
    let null = json!({"name": "top", "_meta": {"acpmux": {"name": null}}});
    assert_eq!(name(null).as_deref(), Some("top"));
    assert_eq!(name(json!({})), None);
}
