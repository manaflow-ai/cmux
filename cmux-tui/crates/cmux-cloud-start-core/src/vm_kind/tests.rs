//! The `vmKind` word (moved from the app's `CloudVmKindTests`).

use super::*;

#[test]
fn only_owner_starts_the_link_at_the_vm_boundary() {
    let owner = read(Some("owner"));
    assert!(owner.owns_vm && !owner.teammate);
    assert_eq!(owner.link_arguments, ["--vm-kind", "owner"]);
    for kind in [Some("team"), None, Some("Owner"), Some(""), Some(" owner")] {
        let other = read(kind);
        assert!(!other.owns_vm, "{kind:?}");
        assert!(other.link_arguments.is_empty(), "{kind:?}");
    }
}

/// An older server sends no word: the sandbox stays.
#[test]
fn an_older_server_keeps_the_sandbox() {
    assert_eq!(read(None), VmKind { owns_vm: false, teammate: false, link_arguments: Vec::new() });
}

#[test]
fn only_team_names_a_teammates_machine() {
    assert!(read(Some("team")).teammate);
    for kind in [Some("owner"), Some("Team"), Some(""), None] {
        assert!(!read(kind).teammate, "{kind:?}");
    }
}

#[test]
fn the_wire_is_the_apps_shape() {
    let reply = serde_json::to_value(read(Some("owner"))).unwrap();
    assert_eq!(
        reply,
        serde_json::json!({"ownsVm": true, "teammate": false, "linkArguments": ["--vm-kind", "owner"]})
    );
}
