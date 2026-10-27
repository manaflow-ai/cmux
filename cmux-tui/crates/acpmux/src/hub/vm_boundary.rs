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
//! The caller's daemon adds `_meta.acpmux.vmBoundary: true` ([`FIELD`])
//! to each `session/new` it forwards to such a peer, and drops the field from
//! any caller of its own. The guest takes it only from a connection that
//! presented its peer token ([`asked`]), records it on the session
//! (`SessionMeta::vm_boundary`; a fork or sub-session keeps it), and honours
//! it at each spawn while it takes the boundary ([`Hub::takes_vm_boundary`]):
//! never on a Mac, never once its own config says `vmHost: false`. The guest
//! may tighten, never loosen.
//!
//! Why a guest-side forger gains nothing: nothing the guest writes changes
//! another caller's session. A process with root there can read the peer
//! token and send the field itself, but it only gets an unsandboxed Claude
//! that it started, as the agent user, which its own root already runs.
//! What no guest-side check can do is hold a sandbox against root in that
//! guest; that is the "the VM is the boundary" residual.
//!
//! Approve-all follows the same opt-out, under the rules vmHost's had
//! ([`vm_boundary_peer_approves`]).

use super::*;

/// `_meta.acpmux.vmBoundary` on a `session/new`: `true` asks for it. (Not
/// `sandbox`, a mode field no remote request may carry: `web_modes::MODE_FIELDS`.)
pub const FIELD: &str = "vmBoundary";

/// Whether a `session/new` asks for the VM boundary: `_meta.acpmux.vmBoundary`
/// is exactly `true`, the connection presented this launch's peer token
/// (`server/peer_auth.rs`), and the peer asks for itself (`Control::Peer`), not
/// for a Web client of its own (`via: web`). From anything else it means nothing.
pub fn asked(auth: crate::server::ConnAuth, control: Control, params: &Value) -> bool {
    auth == crate::server::ConnAuth::PeerToken
        && control == Control::Peer
        && params.pointer("/_meta/acpmux/vmBoundary") == Some(&Value::Bool(true))
}

/// Whether this daemon, forwarding a `session/new` to a peer it holds at the VM
/// boundary, asks for it on the caller's behalf: only for the person's own
/// clients here, by the proof their connection presented. The unix socket
/// (the person, the CLI), the app (`LocalApp`: the very caller the Cloud API
/// answered), and the owner's own peer daemon asking for itself (`PeerToken`
/// and `Control::Peer`). Never a Web client, a paired device's connection
/// (`Device`, `ReadOnlyDevice`), or a request held to the Web's rules.
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

/// Whether a new session with no asked policy runs approve-all: only for a
/// session whose caller asked for the VM boundary that this machine takes,
/// never on a Mac, only for the owner's peer daemon (`Control::Peer`, proven
/// by the peer token), and only while MDM leaves approve-all allowed
/// (`Hub::approve_all_allowed`); a Web client never. vmHost's rule, with the
/// caller's opt-out in place of the guest's own say.
pub fn vm_boundary_peer_approves(
    vm_boundary: bool,
    macos: bool,
    from_peer: bool,
    approve_all_allowed: bool,
) -> bool {
    vm_boundary && !macos && from_peer && approve_all_allowed
}

impl Hub {
    /// Whether this machine takes a caller's VM boundary now: Linux only (a
    /// Mac's Seatbelt sandbox always runs, and another platform runs no remote
    /// Claude at all), and its config does not say `vmHost: false` (the
    /// owner's per-machine toggle). Read at each spawn, so the toggle applies
    /// to the spawns after it with no restart.
    pub async fn takes_vm_boundary(&self) -> bool {
        cfg!(target_os = "linux") && self.config.read().await.vm_host != Some(false)
    }

    /// Whether `meta`'s remote chain runs its Claude Code without the
    /// platform sandbox now (module docs).
    pub(crate) async fn vm_boundary_unsandboxed(&self, meta: &crate::store::SessionMeta) -> bool {
        meta.remote_origin && meta.vm_boundary && self.takes_vm_boundary().await
    }
}

#[cfg(test)]
mod tests {
    use super::{asked, forwards, vm_boundary_peer_approves};
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
}
