use crate::workspace_registry::Actor;

#[test]
fn only_the_verified_app_counts_as_a_drag() {
    assert!(super::from_app(&Actor::Frontend { install_id: "signed_app".into() }));
    assert!(!super::from_app(&Actor::local_user()));
    assert!(!super::from_app(&Actor::Terminal { id: "t1".into() }));
    assert!(!super::from_app(&Actor::Peer { id: "peer:websocket".into() }));
}
