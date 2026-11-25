use super::*;
use crate::mesh::Sender;

fn sender(user: Option<&str>, daemon: Option<&str>) -> Sender {
    Sender {
        user: user.map(str::to_owned),
        daemon_id: daemon.map(str::to_owned),
        ..Sender::default()
    }
}

#[test]
fn move_out_has_the_same_owner_only_grant_as_move() {
    let entry =
        MeshControlFrom { same_user: true, ops: vec![MOVE_OP.to_owned()], ..Default::default() };
    let own = sender(Some("person"), Some("daemon"));
    assert!(entry.allows(&own, Some("person"), MOVE_OP));
    assert!(entry.allows(&own, Some("person"), MOVE_OUT_OP));
    assert!(!entry.allows(&own, Some("other"), MOVE_OUT_OP));
    assert!(!entry.allows(&sender(None, Some("daemon")), Some("person"), MOVE_OUT_OP));
    assert!(!entry.allows(&sender(Some("person"), None), Some("person"), MOVE_OUT_OP));
    assert!(!entry.allows(&own, None, MOVE_OUT_OP));
}

#[test]
fn move_out_cannot_be_granted_by_daemon_id_or_lifecycle_defaults() {
    let by_daemon = MeshControlFrom {
        daemon_id: "daemon".into(),
        ops: vec![MOVE_OP.into()],
        ..Default::default()
    };
    let from = sender(Some("person"), Some("daemon"));
    assert!(!by_daemon.allows(&from, Some("person"), MOVE_OUT_OP));
    let default = MeshControlFrom::same_user();
    assert!(!default.allows(&from, Some("person"), MOVE_OUT_OP));
    let only_move_out = MeshControlFrom { ops: vec![MOVE_OUT_OP.into()], ..default };
    assert!(!only_move_out.allows(&from, Some("person"), MOVE_OUT_OP));
}
