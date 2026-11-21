use super::*;

#[test]
fn families_and_methods() {
    assert_eq!(family_of("app.settings.set"), "app.settings");
    assert_eq!(family_of("fs.pick"), "fs");
    assert!(FAMILIES.contains(&family_of("agent_cli.list")));
    assert!(FAMILIES.contains(&family_of("agent_chat.list")));
    assert!(!FAMILIES.contains(&family_of("agent.list")), "the daemon owns agent.*");
    let mut params = json!({ "provider": "github" });
    normalize_method(&mut params);
    assert_eq!(params["method"], "GET");
    let mut post = json!({ "method": "post" });
    normalize_method(&mut post);
    assert_eq!(post["method"], "POST");
}

/// A new `app.*` op must be a decision: the supervisor keeps
/// `app.storage.*`; anything else in the catalog would silently go to
/// the provider's `app` family.
#[test]
fn every_app_op_in_the_scope_table_has_a_known_owner() {
    for op in super::super::grants::ScopeTable::get().known_ops() {
        if family_of(&op) == "app" {
            assert!(op.starts_with("app.storage."), "{op}: decide its owner before adding it");
        }
    }
}
