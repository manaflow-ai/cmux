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

/// `_meta.acpmux.via` on a request a daemon forwards for a client of its own
/// that is not the person's ([`owner`] false: a paired machine's credential, or
/// a peer forwarding one). The daemon it reaches holds it as not the owner's.
pub const VIA_DEVICE: &str = "device";

/// Whether a `session/new` asks for the VM boundary: `_meta.acpmux.vmBoundary`
/// is exactly `true`, the connection presented this launch's peer token
/// (`server/peer_auth.rs`), and the peer asks for itself ([`owner`]), not for a
/// Web client (`via: web`) or a paired machine (`via: device`) of its own. From
/// anything else it means nothing.
pub fn asked(auth: crate::server::ConnAuth, control: Control, params: &Value) -> bool {
    auth == crate::server::ConnAuth::PeerToken
        && owner(auth, control, params)
        && params.pointer("/_meta/acpmux/vmBoundary") == Some(&Value::Bool(true))
}

/// Whether a request is the person's own for the VM boundary: its connection
/// may have the boundary forwarded ([`forwards`]), and no daemon forwarding it
/// said it came from a paired machine (`via: device`, [`VIA_DEVICE`]). Only
/// such a request starts, controls, forks or re-enables a session at the
/// boundary; any other is held to the Web's rules for one
/// ([`Hub::refuse_at_vm_boundary`]).
pub fn owner(auth: crate::server::ConnAuth, control: Control, params: &Value) -> bool {
    forwards(auth, control)
        && params.pointer("/_meta/acpmux/via").and_then(Value::as_str) != Some(VIA_DEVICE)
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

    /// Admits a request that is not the person's own ([`owner`] false: a Web
    /// client, a paired machine's `client` credential, or a peer forwarding for
    /// either) against the VM boundary, before anything else runs and again
    /// once the guard's awaits are done. It resolves the session the request
    /// names, refuses a key that names several, and pins the request to that
    /// session's exact id (`sessionId`), so a rename or a new session that
    /// shadows the name while the request waits cannot move it onto another
    /// session. If that session is at the VM boundary, the request is refused
    /// unless it only reads (the read-only role's closed allow list,
    /// `pairing::read_only_allows`), so no such caller prompts, steers,
    /// cancels, answers for, restarts, re-models, forks, kills or reconfigures
    /// one, including any method added later; a read runs under the Web's rules
    /// (`via: web`). `_acpmux/warm` and `_acpmux/shutdown`, which name no one
    /// session, check their own (`warm.rs`, `requests.rs`).
    pub fn refuse_at_vm_boundary(
        &self,
        auth: crate::server::ConnAuth,
        control: Control,
        m: &str,
        params: &mut Value,
    ) -> Result<(), RpcError> {
        // `session/new`'s name is the new chat's, never a session it acts on.
        if owner(auth, control, params) || m == crate::rpc::method::SESSION_NEW {
            return Ok(());
        }
        let Ok(key) = crate::server::session_key(params) else { return Ok(()) };
        let session = match self.resolve(key) {
            Ok(session) => session,
            // A key that names no session here names none at the boundary: one would have to
            // take that name first, which only its owner or its own agent does.
            Err(e) if e.code == RpcError::not_found("").code => return Ok(()),
            // A key that names several (an ambiguous prefix, a shared name): refused, so a
            // rename while the request waits cannot make it name a boundary session.
            Err(e) => return Err(e),
        };
        if !crate::no_panic::JsonExt::set(params, "sessionId", Value::String(session.id.clone())) {
            return Err(RpcError::invalid_params("params must be an object"));
        }
        if !session.meta().vm_boundary {
            return Ok(());
        }
        if crate::pairing::read_only_allows(m) {
            if control == Control::Peer {
                super::merge_mux_meta(params, json!({"via": "web"}));
            }
            return Ok(());
        }
        Err(RpcError::new(
            -32000,
            format!(
                "{m}: this chat runs without the sandbox on its owner's own VM; only the owner's own devices change it"
            ),
        )
        .with_data(json!({"reason": "remote.unsandboxed_agent", "method": m})))
    }

    /// Whether any session here is at its owner's VM boundary: what a caller
    /// that is not the owner may not shut down (`_acpmux/shutdown`).
    pub fn any_at_vm_boundary(&self) -> bool {
        self.sessions().iter().any(|s| s.meta().vm_boundary)
    }

    /// Whether `meta`'s remote chain runs its Claude Code without the
    /// platform sandbox now (module docs).
    pub(crate) async fn vm_boundary_unsandboxed(&self, meta: &crate::store::SessionMeta) -> bool {
        meta.remote_origin && meta.vm_boundary && self.takes_vm_boundary().await
    }
}

#[cfg(test)]
mod tests {
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
}
