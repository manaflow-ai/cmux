//! Server-issued authorization for one control connection.
//!
//! Unix peer credentials establish a same-UID boundary. A process running as
//! the daemon user is intentionally inside that boundary; this does not claim
//! to authenticate the client's executable or code signature. Registered
//! client kinds select the least role the server grants within that boundary.

use uuid::Uuid;

use crate::platform;
use crate::platform::transport::PeerCredentials;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ConnectionTransport {
    Unix,
    WebSocket,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ConnectionRole {
    Unaffiliated,
    RemoteReadOnly,
    TrustedFrontend,
    TrustedAutomation,
    TrustedRenderer,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ConnectionPermission {
    Control,
    Frontend,
}

impl ConnectionRole {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Unaffiliated => "unaffiliated",
            Self::RemoteReadOnly => "remote-read-only",
            Self::TrustedFrontend => "trusted-frontend",
            Self::TrustedAutomation => "trusted-automation",
            Self::TrustedRenderer => "trusted-renderer",
        }
    }

    fn permits_topology_mutation(self) -> bool {
        matches!(self, Self::TrustedFrontend | Self::TrustedAutomation)
    }

    pub(crate) fn permits(self, permission: ConnectionPermission) -> bool {
        match permission {
            ConnectionPermission::Control => {
                matches!(self, Self::TrustedFrontend | Self::TrustedAutomation)
            }
            ConnectionPermission::Frontend => matches!(self, Self::TrustedFrontend),
        }
    }

    pub(crate) fn require_permission(
        self,
        permission: ConnectionPermission,
        command: &str,
    ) -> anyhow::Result<()> {
        if self.permits(permission) {
            Ok(())
        } else {
            let required = match permission {
                ConnectionPermission::Control => "trusted frontend or automation",
                ConnectionPermission::Frontend => "trusted frontend",
            };
            anyhow::bail!(
                "command {command:?} requires a registered server-issued same-UID {required} role"
            )
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RegisteredClientKind {
    SwiftShell,
    Tui,
    Automation,
    RendererWorker,
    Web,
}

impl RegisteredClientKind {
    pub(crate) fn parse(value: &str) -> anyhow::Result<Self> {
        match value {
            "swift-shell" => Ok(Self::SwiftShell),
            "tui" => Ok(Self::Tui),
            "automation" => Ok(Self::Automation),
            "renderer-worker" => Ok(Self::RendererWorker),
            "web" => Ok(Self::Web),
            other => anyhow::bail!("unsupported registered client kind {other:?}"),
        }
    }

    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::SwiftShell => "swift-shell",
            Self::Tui => "tui",
            Self::Automation => "automation",
            Self::RendererWorker => "renderer-worker",
            Self::Web => "web",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct TopologyMutationLease {
    pub(crate) id: Uuid,
    pub(crate) generation: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct TopologyMutationLeaseClaim {
    pub(crate) id: Uuid,
    pub(crate) generation: u64,
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct ConnectionAuthorization {
    transport: ConnectionTransport,
    peer_credentials: Option<PeerCredentials>,
    registered_kind: Option<RegisteredClientKind>,
    role: ConnectionRole,
    topology_lease: Option<TopologyMutationLease>,
}

impl ConnectionAuthorization {
    pub(crate) fn unix(peer_credentials: Option<PeerCredentials>) -> Self {
        Self {
            transport: ConnectionTransport::Unix,
            peer_credentials,
            registered_kind: None,
            role: ConnectionRole::Unaffiliated,
            topology_lease: None,
        }
    }

    pub(crate) fn websocket() -> Self {
        Self {
            transport: ConnectionTransport::WebSocket,
            peer_credentials: None,
            registered_kind: None,
            role: ConnectionRole::RemoteReadOnly,
            topology_lease: None,
        }
    }

    pub(crate) fn register(
        &mut self,
        protocol: u32,
        client_kind: Option<&str>,
    ) -> anyhow::Result<()> {
        // Registration is fail closed. Clear any prior grant before parsing
        // caller-controlled kind text so an error cannot retain authority.
        self.registered_kind = None;
        self.topology_lease = None;
        self.role = match self.transport {
            ConnectionTransport::Unix => ConnectionRole::Unaffiliated,
            ConnectionTransport::WebSocket => ConnectionRole::RemoteReadOnly,
        };
        let registered_kind = client_kind.map(RegisteredClientKind::parse).transpose()?;
        let role = match self.transport {
            ConnectionTransport::WebSocket => ConnectionRole::RemoteReadOnly,
            ConnectionTransport::Unix if protocol < 9 => ConnectionRole::Unaffiliated,
            ConnectionTransport::Unix if !self.has_same_user_peer() => ConnectionRole::Unaffiliated,
            ConnectionTransport::Unix => match registered_kind {
                Some(RegisteredClientKind::SwiftShell | RegisteredClientKind::Tui) => {
                    ConnectionRole::TrustedFrontend
                }
                Some(RegisteredClientKind::Automation) => ConnectionRole::TrustedAutomation,
                Some(RegisteredClientKind::RendererWorker) => ConnectionRole::TrustedRenderer,
                Some(RegisteredClientKind::Web) | None => ConnectionRole::Unaffiliated,
            },
        };
        let topology_lease = if role.permits_topology_mutation() {
            Some(TopologyMutationLease { id: Uuid::new_v4(), generation: 1 })
        } else {
            None
        };
        self.registered_kind = registered_kind;
        self.role = role;
        self.topology_lease = topology_lease;
        Ok(())
    }

    pub(crate) fn role(self) -> ConnectionRole {
        self.role
    }

    pub(crate) fn registered_kind(self) -> Option<RegisteredClientKind> {
        self.registered_kind
    }

    pub(crate) fn peer_credentials(self) -> Option<PeerCredentials> {
        self.peer_credentials
    }

    pub(crate) fn topology_lease(self) -> Option<TopologyMutationLease> {
        self.topology_lease
    }

    pub(crate) fn require_topology_mutation(
        self,
        claim: TopologyMutationLeaseClaim,
    ) -> anyhow::Result<()> {
        if !self.has_same_user_peer() || !self.role.permits_topology_mutation() {
            anyhow::bail!(
                "canonical topology mutation requires a server-issued trusted local same-UID role"
            );
        }
        let lease = self.topology_lease.ok_or_else(|| {
            anyhow::anyhow!("canonical topology mutation has no live connection lease")
        })?;
        if claim.id != lease.id {
            anyhow::bail!("canonical topology mutation lease does not belong to this connection");
        }
        if claim.generation != lease.generation {
            anyhow::bail!(
                "stale canonical topology mutation lease generation {}; current generation is {}",
                claim.generation,
                lease.generation
            );
        }
        Ok(())
    }

    fn has_same_user_peer(self) -> bool {
        self.peer_credentials
            .zip(platform::effective_user_id())
            .is_some_and(|(credentials, effective_user)| credentials.user_id == effective_user)
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    fn same_user_peer() -> PeerCredentials {
        PeerCredentials {
            process_id: Some(std::process::id()),
            user_id: platform::effective_user_id().expect("Unix test UID"),
            group_id: 1,
        }
    }

    #[test]
    fn only_v9_same_user_server_mapped_kinds_receive_topology_leases() {
        let mut frontend = ConnectionAuthorization::unix(Some(same_user_peer()));
        frontend.register(9, Some("swift-shell")).unwrap();
        assert_eq!(frontend.role(), ConnectionRole::TrustedFrontend);
        assert!(frontend.topology_lease().is_some());

        let mut legacy = ConnectionAuthorization::unix(Some(same_user_peer()));
        legacy.register(8, Some("swift-shell")).unwrap();
        assert_eq!(legacy.role(), ConnectionRole::Unaffiliated);
        assert!(legacy.topology_lease().is_none());

        let mut renderer = ConnectionAuthorization::unix(Some(same_user_peer()));
        renderer.register(9, Some("renderer-worker")).unwrap();
        assert_eq!(renderer.role(), ConnectionRole::TrustedRenderer);
        assert!(renderer.topology_lease().is_none());
    }

    #[test]
    fn websocket_and_foreign_or_missing_peers_never_receive_trusted_roles() {
        let mut websocket = ConnectionAuthorization::websocket();
        websocket.register(9, Some("swift-shell")).unwrap();
        assert_eq!(websocket.role(), ConnectionRole::RemoteReadOnly);
        assert!(websocket.topology_lease().is_none());

        let mut foreign_peer = same_user_peer();
        foreign_peer.user_id = foreign_peer.user_id.wrapping_add(1);
        let mut foreign = ConnectionAuthorization::unix(Some(foreign_peer));
        foreign.register(9, Some("swift-shell")).unwrap();
        assert_eq!(foreign.role(), ConnectionRole::Unaffiliated);
        assert!(foreign.topology_lease().is_none());

        let mut missing = ConnectionAuthorization::unix(None);
        missing.register(9, Some("swift-shell")).unwrap();
        assert_eq!(missing.role(), ConnectionRole::Unaffiliated);
        assert!(missing.topology_lease().is_none());
    }

    #[test]
    fn topology_lease_is_connection_bound_and_generation_fenced() {
        let mut first = ConnectionAuthorization::unix(Some(same_user_peer()));
        first.register(9, Some("swift-shell")).unwrap();
        let first_lease = first.topology_lease().unwrap();
        first
            .require_topology_mutation(TopologyMutationLeaseClaim {
                id: first_lease.id,
                generation: first_lease.generation,
            })
            .unwrap();

        let mut second = ConnectionAuthorization::unix(Some(same_user_peer()));
        second.register(9, Some("swift-shell")).unwrap();
        let second_lease = second.topology_lease().unwrap();
        assert_ne!(first_lease.id, second_lease.id);
        assert!(
            second
                .require_topology_mutation(TopologyMutationLeaseClaim {
                    id: first_lease.id,
                    generation: first_lease.generation,
                })
                .unwrap_err()
                .to_string()
                .contains("does not belong")
        );
        assert!(
            first
                .require_topology_mutation(TopologyMutationLeaseClaim {
                    id: first_lease.id,
                    generation: first_lease.generation + 1,
                })
                .unwrap_err()
                .to_string()
                .contains("stale")
        );
    }

    #[test]
    fn unsupported_client_kind_fails_registration_without_a_role_or_lease() {
        let mut authorization = ConnectionAuthorization::unix(Some(same_user_peer()));
        authorization.register(9, Some("swift-shell")).unwrap();
        assert_eq!(authorization.role(), ConnectionRole::TrustedFrontend);
        assert!(authorization.topology_lease().is_some());

        let error = authorization.register(9, Some("self-asserted-admin")).unwrap_err();
        assert!(error.to_string().contains("unsupported registered client kind"));
        assert_eq!(authorization.role(), ConnectionRole::Unaffiliated);
        assert!(authorization.registered_kind().is_none());
        assert!(authorization.topology_lease().is_none());
    }

    #[test]
    fn renderer_role_cannot_inherit_frontend_or_automation_permissions() {
        let mut renderer = ConnectionAuthorization::unix(Some(same_user_peer()));
        renderer.register(9, Some("renderer-worker")).unwrap();
        assert!(!renderer.role().permits(ConnectionPermission::Control));
        assert!(!renderer.role().permits(ConnectionPermission::Frontend));

        let mut automation = ConnectionAuthorization::unix(Some(same_user_peer()));
        automation.register(9, Some("automation")).unwrap();
        assert!(automation.role().permits(ConnectionPermission::Control));
        assert!(!automation.role().permits(ConnectionPermission::Frontend));
    }
}
