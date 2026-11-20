use super::{asked, forwards, owner, vm_boundary_peer_approves};
use crate::hub::Control;
use crate::server::ConnAuth;
use serde_json::json;

#[test]
fn only_a_peer_token_connection_asking_for_itself_asks_for_the_vm_boundary() {
    let vm = json!({"_meta": {"acpmux": {"vmBoundary": true}}});
    assert!(asked(ConnAuth::PeerToken, Control::Peer, &vm));
    // A peer forwarding for its own Web client (`via: web`).
    assert!(!asked(ConnAuth::PeerToken, Control::Web, &vm));
    for auth in [
        ConnAuth::ListenerToken,
        ConnAuth::LocalApp,
        ConnAuth::LocalSocket,
        ConnAuth::Device,
        ConnAuth::ReadOnlyDevice,
        ConnAuth::None,
    ] {
        for control in [Control::Peer, Control::Local, Control::Web] {
            assert!(!asked(auth, control, &vm), "{auth:?} {control:?}");
        }
    }
    for other in [
        json!({}),
        json!({"_meta": {"acpmux": {"vmBoundary": "true"}}}),
        json!({"vmBoundary": true}),
    ] {
        assert!(!asked(ConnAuth::PeerToken, Control::Peer, &other), "{other}");
    }
}

#[test]
fn only_the_persons_own_clients_get_the_boundary_forwarded() {
    assert!(forwards(ConnAuth::LocalSocket, Control::Local));
    assert!(forwards(ConnAuth::LocalApp, Control::Local));
    assert!(forwards(ConnAuth::PeerToken, Control::Peer));
    assert!(!forwards(ConnAuth::PeerToken, Control::Web), "a peer's own Web client");
    for auth in
        [ConnAuth::ListenerToken, ConnAuth::Device, ConnAuth::ReadOnlyDevice, ConnAuth::None]
    {
        for control in [Control::Peer, Control::Local, Control::Web] {
            assert!(!forwards(auth, control), "{auth:?} {control:?}");
        }
    }
}

#[test]
fn a_request_forwarded_for_a_paired_machine_is_never_the_owners() {
    let device = json!({"_meta": {"acpmux": {"via": "device", "vmBoundary": true}}});
    assert!(!owner(ConnAuth::PeerToken, Control::Peer, &device));
    assert!(!asked(ConnAuth::PeerToken, Control::Peer, &device));
    assert!(owner(ConnAuth::PeerToken, Control::Peer, &json!({})));
    assert!(!owner(ConnAuth::Device, Control::Peer, &json!({})), "a paired client");
    assert!(owner(ConnAuth::LocalApp, Control::Local, &json!({})));
}

#[test]
fn only_the_owner_peer_with_the_vm_boundary_gets_approve_all() {
    assert!(vm_boundary_peer_approves(true, false, true, true));
    assert!(!vm_boundary_peer_approves(true, false, false, true), "a Web client still asks");
    assert!(!vm_boundary_peer_approves(true, true, true, true), "never on a Mac");
    assert!(!vm_boundary_peer_approves(false, false, true, true), "only with the boundary");
    assert!(
        !vm_boundary_peer_approves(true, false, true, false),
        "never while MDM forces full access off"
    );
}
