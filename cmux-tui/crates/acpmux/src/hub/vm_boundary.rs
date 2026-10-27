//! The VM boundary: a remote chain's Claude Code runs without the platform
//! sandbox (bwrap) only when its caller asked for that, for that one session,
//! and the VM is the boundary.
//!
//! The guest never decides it. Every Cloud VM's agent user has passwordless
//! sudo, so anything on the machine (`/etc/cmux/vm-kind`, `/srv/team`,
//! config.json) can say whatever an agent writes (`vm_host.rs`). The caller
//! decides from its own system of record and says so per request:
//!
//! - A Cloud link's lease (`_acpmux/peer_lease {vmBoundary: true}`): the app
//!   asked the Cloud API's attach-endpoint for that machine, signed in as the
//!   user, and the answer was `vmKind: "owner"` (the caller's own personal VM,
//!   which it created). Held with the lease only, never saved.
//! - A saved peer's `vmBoundary: true` in this caller's config.json: a fleet
//!   tool writes it for a VM its registry says is a dedicated agent VM.
//!
//! This is the caller's side. The caller's daemon adds
//! `_meta.acpmux.vmBoundary: true` ([`FIELD`]) to each `session/new` it
//! forwards to such a peer, only for the person's own clients ([`owner`]), and
//! drops the field from any caller of its own. A request it forwards for a
//! paired machine says so (`via: device`, [`VIA_DEVICE`]), so the peer never
//! takes it for the owner's. A guest that does not take the boundary ignores
//! the field: its sandbox runs as before.

use super::*;

/// `_meta.acpmux.vmBoundary` on a `session/new`: `true` asks for it. (Not
/// `sandbox`, a mode field no remote request may carry: `web_modes::MODE_FIELDS`.)
pub const FIELD: &str = "vmBoundary";

/// `_meta.acpmux.via` on a request a daemon forwards for a client of its own
/// that is not the person's ([`owner`] false: a paired machine's credential, or
/// a peer forwarding one). The daemon it reaches holds it as not the owner's.
pub const VIA_DEVICE: &str = "device";

/// Whether this daemon, forwarding a request to a peer, may stand for the
/// person at that peer's VM boundary, by the proof the connection presented:
/// the unix socket (the person, the CLI), the app (`LocalApp`: the very caller
/// the Cloud API answered), and the owner's own peer daemon asking for itself
/// (`PeerToken` and `Control::Peer`). Never a Web client, a paired machine's
/// connection (`Device`, `ReadOnlyDevice`), or a request held to the Web's
/// rules.
pub fn forwards(auth: crate::server::ConnAuth, control: Control) -> bool {
    use crate::server::ConnAuth;
    match auth {
        ConnAuth::LocalSocket | ConnAuth::LocalApp => control != Control::Web,
        ConnAuth::PeerToken => control == Control::Peer,
        ConnAuth::ListenerToken | ConnAuth::Device | ConnAuth::ReadOnlyDevice | ConnAuth::None => {
            false
        }
    }
}

/// Whether a request is the person's own for the VM boundary: its connection
/// may have the boundary forwarded ([`forwards`]), and no daemon forwarding it
/// said it came from a paired machine (`via: device`, [`VIA_DEVICE`]).
pub fn owner(auth: crate::server::ConnAuth, control: Control, params: &Value) -> bool {
    forwards(auth, control)
        && params.pointer("/_meta/acpmux/via").and_then(Value::as_str) != Some(VIA_DEVICE)
}

#[cfg(test)]
mod tests {
    use super::{forwards, owner};
    use crate::hub::Control;
    use crate::server::ConnAuth;
    use serde_json::json;

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
        let device = json!({"_meta": {"acpmux": {"via": "device"}}});
        assert!(!owner(ConnAuth::PeerToken, Control::Peer, &device));
        assert!(owner(ConnAuth::PeerToken, Control::Peer, &json!({})));
        assert!(!owner(ConnAuth::Device, Control::Peer, &json!({})), "a paired client");
        assert!(owner(ConnAuth::LocalApp, Control::Local, &json!({})));
    }
}
