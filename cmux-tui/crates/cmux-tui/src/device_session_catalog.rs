//! Process-wide discovery model for device and session rows.
//!
//! Sources publish immutable descriptors. They do not own mux resources or a
//! window's connection. Provider protocol v1 maps each machine to one explicit
//! singleton session until an additive provider capability is available.

use std::collections::BTreeSet;

use anyhow::Context;
use cmux_tui_core::resource::{MachinePublicId, SessionPublicId};
use cmux_tui_core::{CatalogAlias, CatalogRepairPhase, CatalogSnapshot};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum CatalogSourceId {
    Local { machine_id: MachinePublicId },
    ProviderV1 { provider_id: String, scope_id: String },
}

impl CatalogSourceId {
    pub fn local(machine_id: &MachinePublicId) -> Self {
        Self::Local { machine_id: machine_id.clone() }
    }

    pub fn provider_v1(
        provider_id: impl Into<String>,
        scope_id: impl Into<String>,
    ) -> anyhow::Result<Self> {
        let provider_id = provider_id.into();
        let scope_id = scope_id.into();
        anyhow::ensure!(
            !provider_id.is_empty() && provider_id.len() <= 256,
            "invalid provider catalog id"
        );
        anyhow::ensure!(!scope_id.is_empty() && scope_id.len() <= 256, "invalid provider scope id");
        Ok(Self::ProviderV1 { provider_id, scope_id })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub struct CatalogDeviceId {
    pub source_id: CatalogSourceId,
    pub route_id: String,
}

impl CatalogDeviceId {
    pub fn local(machine_id: &MachinePublicId) -> Self {
        Self { source_id: CatalogSourceId::local(machine_id), route_id: machine_id.to_string() }
    }

    pub fn provider(source_id: CatalogSourceId, provider_machine_id: impl Into<String>) -> Self {
        Self { source_id, route_id: provider_machine_id.into() }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(tag = "kind", content = "id", rename_all = "snake_case")]
pub enum CatalogSessionId {
    Public(SessionPublicId),
    ProviderV1Singleton,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub struct CatalogSessionKey {
    pub device_id: CatalogDeviceId,
    pub session_id: CatalogSessionId,
}

impl CatalogSessionKey {
    pub fn local(machine_id: &MachinePublicId, session_id: &SessionPublicId) -> Self {
        Self {
            device_id: CatalogDeviceId::local(machine_id),
            session_id: CatalogSessionId::Public(session_id.clone()),
        }
    }

    pub fn provider_v1(device_id: CatalogDeviceId) -> Self {
        Self { device_id, session_id: CatalogSessionId::ProviderV1Singleton }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub struct ResourceAddress {
    pub machine_id: MachinePublicId,
    pub session_id: SessionPublicId,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DeviceAvailability {
    Online,
    Connecting,
    Sleeping,
    Stopped,
    Offline,
    Unavailable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionOwnerState {
    Creating,
    Stopped,
    Starting,
    Running,
    Stopping,
    Deleting,
    Failed,
    Unavailable,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CatalogDeviceDescriptor {
    pub id: CatalogDeviceId,
    pub display_name: String,
    pub availability: DeviceAvailability,
    pub capabilities: BTreeSet<String>,
    pub source_order: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CatalogSessionDescriptor {
    pub key: CatalogSessionKey,
    pub resource_address: Option<ResourceAddress>,
    pub registry_id: Option<String>,
    pub display_name: String,
    pub aliases: Vec<CatalogAlias>,
    pub owner_state: SessionOwnerState,
    pub capabilities: BTreeSet<String>,
    pub source_order: u64,
    pub last_seen_unix_ms: Option<u64>,
    pub tombstoned: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourceSnapshot {
    pub source_id: CatalogSourceId,
    pub generation: String,
    pub revision: u64,
    pub devices: Vec<CatalogDeviceDescriptor>,
    pub sessions: Vec<CatalogSessionDescriptor>,
}

pub trait DeviceSessionCatalogSource: Send + Sync {
    fn snapshot(&self, known_revision: Option<u64>) -> anyhow::Result<SourceSnapshot>;
}

#[derive(Debug, Clone)]
pub struct LocalDeviceSessionCatalog {
    snapshot: SourceSnapshot,
}

impl LocalDeviceSessionCatalog {
    pub fn from_core(snapshot: CatalogSnapshot, device_name: impl Into<String>) -> Self {
        let source_id = CatalogSourceId::local(&snapshot.machine_id);
        let device_id = CatalogDeviceId::local(&snapshot.machine_id);
        let sessions = snapshot
            .sessions
            .into_iter()
            .map(|session| {
                CatalogSessionDescriptor {
                    key: CatalogSessionKey::local(&session.machine_id, &session.session_id),
                    resource_address: Some(ResourceAddress {
                        machine_id: session.machine_id,
                        session_id: session.session_id,
                    }),
                    registry_id: Some(session.registry_id),
                    display_name: session.display_name,
                    aliases: session.aliases,
                    owner_state: local_owner_state(session.repair_phase),
                    capabilities: BTreeSet::from([
                        "attach".to_string(),
                        "rename".to_string(),
                        "start".to_string(),
                        "stop".to_string(),
                    ]),
                    source_order: session.created_sequence,
                    last_seen_unix_ms: None,
                    tombstoned: session.deleted_revision.is_some(),
                }
            })
            .collect();
        Self {
            snapshot: SourceSnapshot {
                source_id,
                generation: "local-catalog-v1".to_string(),
                revision: snapshot.revision,
                devices: vec![CatalogDeviceDescriptor {
                    id: device_id,
                    display_name: device_name.into(),
                    availability: DeviceAvailability::Online,
                    capabilities: BTreeSet::from(["session-catalog".to_string()]),
                    source_order: 0,
                }],
                sessions,
            },
        }
    }
}

impl DeviceSessionCatalogSource for LocalDeviceSessionCatalog {
    fn snapshot(&self, known_revision: Option<u64>) -> anyhow::Result<SourceSnapshot> {
        let _unchanged = known_revision == Some(self.snapshot.revision);
        Ok(self.snapshot.clone())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProviderV1Machine {
    pub stable_id: String,
    pub display_name: String,
    pub session_display_name: String,
    pub availability: DeviceAvailability,
}

#[derive(Debug, Clone)]
pub struct ProviderV1SingletonAdapter {
    snapshot: SourceSnapshot,
}

impl ProviderV1SingletonAdapter {
    pub fn new(
        provider_id: impl Into<String>,
        scope_id: impl Into<String>,
        generation: impl Into<String>,
        revision: u64,
        machines: Vec<ProviderV1Machine>,
    ) -> anyhow::Result<Self> {
        let source_id = CatalogSourceId::provider_v1(provider_id, scope_id)?;
        let mut devices = Vec::with_capacity(machines.len());
        let mut sessions = Vec::with_capacity(machines.len());
        for (index, machine) in machines.into_iter().enumerate() {
            anyhow::ensure!(!machine.stable_id.is_empty(), "provider machine id is empty");
            let source_order = u64::try_from(index).context("provider machine order overflow")?;
            let device_id = CatalogDeviceId::provider(source_id.clone(), machine.stable_id);
            devices.push(CatalogDeviceDescriptor {
                id: device_id.clone(),
                display_name: machine.display_name,
                availability: machine.availability,
                capabilities: BTreeSet::from(["open-machine".to_string()]),
                source_order,
            });
            sessions.push(CatalogSessionDescriptor {
                key: CatalogSessionKey::provider_v1(device_id),
                resource_address: None,
                registry_id: None,
                display_name: machine.session_display_name,
                aliases: Vec::new(),
                owner_state: match machine.availability {
                    DeviceAvailability::Online => SessionOwnerState::Running,
                    DeviceAvailability::Connecting => SessionOwnerState::Starting,
                    DeviceAvailability::Sleeping | DeviceAvailability::Stopped => {
                        SessionOwnerState::Stopped
                    }
                    DeviceAvailability::Offline | DeviceAvailability::Unavailable => {
                        SessionOwnerState::Unavailable
                    }
                },
                capabilities: BTreeSet::from(["attach".to_string()]),
                source_order,
                last_seen_unix_ms: None,
                tombstoned: false,
            });
        }
        Ok(Self {
            snapshot: SourceSnapshot {
                source_id,
                generation: generation.into(),
                revision,
                devices,
                sessions,
            },
        })
    }
}

fn local_owner_state(repair_phase: CatalogRepairPhase) -> SessionOwnerState {
    match repair_phase {
        CatalogRepairPhase::Creating => SessionOwnerState::Creating,
        CatalogRepairPhase::Ready => SessionOwnerState::Unavailable,
        CatalogRepairPhase::Deleting => SessionOwnerState::Deleting,
        CatalogRepairPhase::Failed => SessionOwnerState::Failed,
    }
}

impl DeviceSessionCatalogSource for ProviderV1SingletonAdapter {
    fn snapshot(&self, known_revision: Option<u64>) -> anyhow::Result<SourceSnapshot> {
        let _unchanged = known_revision == Some(self.snapshot.revision);
        Ok(self.snapshot.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn durable_ready_state_does_not_claim_a_runtime_owner_state() {
        assert_eq!(
            local_owner_state(CatalogRepairPhase::Ready),
            SessionOwnerState::Unavailable
        );
    }

    #[test]
    fn provider_v1_maps_each_machine_to_one_stable_singleton_session() {
        let adapter = ProviderV1SingletonAdapter::new(
            "provider-a",
            "team-a",
            "generation-a",
            4,
            vec![
                ProviderV1Machine {
                    stable_id: "machine-b".to_string(),
                    display_name: "Build B".to_string(),
                    session_display_name: "main".to_string(),
                    availability: DeviceAvailability::Online,
                },
                ProviderV1Machine {
                    stable_id: "machine-a".to_string(),
                    display_name: "Build A".to_string(),
                    session_display_name: "main".to_string(),
                    availability: DeviceAvailability::Offline,
                },
            ],
        )
        .unwrap();
        let snapshot = adapter.snapshot(None).unwrap();

        assert_eq!(snapshot.sessions.len(), 2);
        assert_eq!(snapshot.sessions[0].source_order, 0);
        assert_eq!(snapshot.sessions[1].source_order, 1);
        assert_eq!(snapshot.sessions[0].owner_state, SessionOwnerState::Running);
        assert!(
            snapshot
                .sessions
                .iter()
                .all(|session| session.key.session_id == CatalogSessionId::ProviderV1Singleton)
        );
        assert!(snapshot.sessions.iter().all(|session| session.resource_address.is_none()));
        assert_ne!(snapshot.sessions[0].key, snapshot.sessions[1].key);
    }
}
