//! Bounded read-only projection of the app's currently admitted remote routes.
//! The connection record is its lease: removing that record removes the whole
//! projection. It cannot replace this daemon's identity or route execution.

use super::{ClientRegistry, ClientTransport};
use crate::panic_free::JsonFields;
use crate::request_origin::RequestOrigin;
use crate::resource::MachinePublicId;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::HashSet;
use std::sync::PoisonError;

pub(crate) const CAPABILITY: &str = "machine-catalog-publish-v1";

#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub(in crate::server) struct Publication {
    sequence: u64,
    machines: Vec<RemoteMachine>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct RemoteMachine {
    id: String,
    name: String,
    origin: Origin,
    status: Status,
    platform: Option<Platform>,
    #[serde(default)]
    capabilities: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
enum Origin {
    Cloud,
    Ssh,
    Server,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
enum Status {
    Running,
    Connecting,
    Unavailable,
    Sleeping,
    Stopped,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Platform {
    os: Option<String>,
    arch: Option<String>,
}

impl Publication {
    pub(in crate::server) fn parse(
        value: Value,
        local: &MachinePublicId,
    ) -> Result<Self, &'static str> {
        let publication: Self =
            serde_json::from_value(value).map_err(|_| "machine_catalog.bad_request")?;
        if publication.sequence == 0 || publication.machines.len() > 256 {
            return Err("machine_catalog.bad_request");
        }
        let mut ids = HashSet::new();
        for machine in &publication.machines {
            if MachinePublicId::parse(machine.id.clone()).is_err()
                || machine.id == local.as_str()
                || !ids.insert(&machine.id)
                || machine.name.is_empty()
                || machine.name.chars().count() > 64
                || machine.name.chars().any(char::is_control)
                || machine.capabilities.len() > 16
                || machine.capabilities.iter().any(|name| !Self::capability(name))
                || machine.platform.as_ref().is_some_and(|platform| {
                    [&platform.os, &platform.arch]
                        .into_iter()
                        .flatten()
                        .any(|token| !Self::token(token))
                })
            {
                return Err("machine_catalog.bad_request");
            }
        }
        Ok(publication)
    }

    fn token(value: &str) -> bool {
        (1..=64).contains(&value.len())
            && value.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
    }

    fn capability(value: &str) -> bool {
        (1..=64).contains(&value.len())
            && value.as_bytes().first().is_some_and(u8::is_ascii_lowercase)
            && value
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b"._-".contains(&b))
    }

    fn snapshots(&self) -> Vec<Value> {
        self.machines
            .iter()
            .filter_map(|machine| {
                let mut value = serde_json::to_value(machine).ok()?;
                value.insert(
                    "connectable",
                    json!(matches!(machine.status, Status::Running | Status::Connecting)),
                );
                value.insert("deleted", json!(false));
                value.insert("recoverable", json!(false));
                Some(value)
            })
            .collect()
    }
}

impl ClientRegistry {
    /// Called only after the native carrier, verified-app and agent-binding gates.
    pub(in crate::server) fn publish_machine_catalog(
        &self,
        client: u64,
        publication: Publication,
    ) -> Result<Value, &'static str> {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(record) = state.clients.get(&client) else {
            return Err("machine_catalog.not_trusted");
        };
        if !matches!(record.transport, ClientTransport::Unix)
            || record.origin.derive() != RequestOrigin::User
        {
            return Err("machine_catalog.not_trusted");
        }
        if state
            .clients
            .iter()
            .any(|(id, record)| *id != client && record.machine_catalog.is_some())
        {
            return Err("machine_catalog.taken");
        }
        let Some(record) = state.clients.get_mut(&client) else {
            return Err("machine_catalog.not_trusted");
        };
        if let Some(previous) = &record.machine_catalog {
            if publication == *previous {
                return Ok(json!({"sequence":publication.sequence,"replayed":true}));
            }
            if publication.sequence <= previous.sequence {
                return Err("machine_catalog.stale");
            }
        }
        let sequence = publication.sequence;
        record.machine_catalog = Some(publication);
        Ok(json!({"sequence":sequence,"replayed":false}))
    }

    /// A copy under the same lock that removes connections; no disconnected lease survives.
    pub(crate) fn remote_machine_catalog(&self) -> Option<(u64, Vec<Value>)> {
        let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        state.clients.iter().find_map(|(client, record)| {
            if !matches!(record.transport, ClientTransport::Unix)
                || record.origin.derive() != RequestOrigin::User
            {
                return None;
            }
            record.machine_catalog.as_ref().map(|publication| (*client, publication.snapshots()))
        })
    }
}
