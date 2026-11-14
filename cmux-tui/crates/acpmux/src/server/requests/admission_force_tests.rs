use super::*;

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
