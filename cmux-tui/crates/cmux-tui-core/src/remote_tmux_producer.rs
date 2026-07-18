//! Durable redacted provenance plus connection-private remote tmux reconnect state.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::mem::size_of;
use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::SurfaceUuid;
use crate::private_runtime::{
    ConnectionPrivateOwner, retained_bytes_after_replacing, validate_private_request_id,
};

pub(crate) const REMOTE_TMUX_PRODUCER_SOURCE_MAX_BYTES: usize = 64 * 1024;
pub(crate) const REMOTE_TMUX_RETAINED_SOURCE_MAX_BYTES: usize = 16 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub(crate) enum ExternalTerminalProducerKind {
    RemoteTmux,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub(crate) enum ExternalTerminalPresentationRole {
    WorkspaceTab,
    NestedPane,
}

/// Bounded non-secret metadata that is safe for topology and durable state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ExternalTerminalProvenance {
    pub producer_kind: ExternalTerminalProducerKind,
    pub producer_id: uuid::Uuid,
    pub tmux_session_id: u64,
    pub tmux_window_id: u64,
    pub tmux_pane_id: u64,
    pub presentation_role: ExternalTerminalPresentationRole,
}

impl ExternalTerminalProvenance {
    pub(crate) fn validate(self) -> anyhow::Result<Self> {
        if self.producer_id.is_nil() {
            anyhow::bail!("external terminal producer identity must be nonzero");
        }
        Ok(self)
    }
}

/// Sensitive reconnect state retained only in daemon memory.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RemoteTmuxProducerSource {
    pub destination: String,
    #[serde(default)]
    pub port: Option<u16>,
    #[serde(default)]
    pub identity_file: Option<String>,
    pub session_name: String,
}

impl fmt::Debug for RemoteTmuxProducerSource {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RemoteTmuxProducerSource")
            .field("destination", &"<redacted>")
            .field("port_present", &self.port.is_some())
            .field("identity_file_present", &self.identity_file.is_some())
            .field("session_name", &"<redacted>")
            .finish()
    }
}

impl RemoteTmuxProducerSource {
    pub(crate) fn validate(&self) -> anyhow::Result<()> {
        if self.destination.is_empty() {
            anyhow::bail!("remote tmux producer destination must not be empty");
        }
        if self.session_name.is_empty() {
            anyhow::bail!("remote tmux producer session name must not be empty");
        }
        if self.port == Some(0) {
            anyhow::bail!("remote tmux producer port must be nonzero");
        }
        if self.identity_file.as_ref().is_some_and(String::is_empty) {
            anyhow::bail!("remote tmux producer identity file must not be empty");
        }
        if self.destination.chars().any(char::is_whitespace)
            || contains_control(&self.destination)
            || contains_control(&self.session_name)
            || self.identity_file.as_deref().is_some_and(contains_control)
        {
            anyhow::bail!("remote tmux producer source contains invalid characters");
        }
        if self.retained_bytes() > REMOTE_TMUX_PRODUCER_SOURCE_MAX_BYTES {
            anyhow::bail!(
                "remote tmux producer source exceeds {REMOTE_TMUX_PRODUCER_SOURCE_MAX_BYTES} bytes"
            );
        }
        Ok(())
    }

    fn retained_bytes(&self) -> usize {
        self.destination
            .len()
            .saturating_add(self.session_name.len())
            .saturating_add(self.identity_file.as_ref().map_or(0, String::len))
            .saturating_add(usize::from(self.port.is_some()) * size_of::<u16>())
    }
}

fn contains_control(value: &str) -> bool {
    value.chars().any(char::is_control)
}

pub(crate) type RemoteTmuxProducerOwner = ConnectionPrivateOwner;

#[derive(Clone, PartialEq, Eq)]
pub(crate) struct RemoteTmuxProducerClaimReceipt {
    pub request_id: uuid::Uuid,
    pub producer_id: uuid::Uuid,
    pub owner_generation: u64,
    pub source: Option<RemoteTmuxProducerSource>,
    pub replayed: bool,
}

impl fmt::Debug for RemoteTmuxProducerClaimReceipt {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RemoteTmuxProducerClaimReceipt")
            .field("request_id", &self.request_id)
            .field("producer_id", &self.producer_id)
            .field("owner_generation", &self.owner_generation)
            .field("source_present", &self.source.is_some())
            .field("replayed", &self.replayed)
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RemoteTmuxProducerSourceUpdateReceipt {
    pub request_id: uuid::Uuid,
    pub producer_id: uuid::Uuid,
    pub owner_generation: u64,
    pub replayed: bool,
}

#[derive(Clone)]
struct ClaimReplay {
    owner: RemoteTmuxProducerOwner,
    source_digest: [u8; 32],
    receipt: RemoteTmuxProducerClaimReceipt,
}

#[derive(Clone)]
struct UpdateReplay {
    owner: RemoteTmuxProducerOwner,
    source_digest: [u8; 32],
    receipt: RemoteTmuxProducerSourceUpdateReceipt,
}

#[derive(Clone)]
struct ProducerState {
    tmux_session_id: u64,
    surfaces: BTreeSet<SurfaceUuid>,
    source: Option<RemoteTmuxProducerSource>,
    owner: Option<RemoteTmuxProducerOwner>,
    owner_generation: u64,
    last_claim: Option<ClaimReplay>,
    last_update: Option<UpdateReplay>,
}

impl ProducerState {
    fn new(
        tmux_session_id: u64,
        surface: SurfaceUuid,
        source: Option<RemoteTmuxProducerSource>,
    ) -> Self {
        Self {
            tmux_session_id,
            surfaces: BTreeSet::from([surface]),
            source,
            owner: None,
            owner_generation: 0,
            last_claim: None,
            last_update: None,
        }
    }
}

#[derive(Default)]
struct RegistryState {
    producers: BTreeMap<uuid::Uuid, ProducerState>,
    retained_source_bytes: usize,
}

pub(crate) struct RemoteTmuxProducerRegistry {
    state: Mutex<RegistryState>,
    retained_source_max_bytes: usize,
}

impl Default for RemoteTmuxProducerRegistry {
    fn default() -> Self {
        Self {
            state: Mutex::new(RegistryState::default()),
            retained_source_max_bytes: REMOTE_TMUX_RETAINED_SOURCE_MAX_BYTES,
        }
    }
}

impl RemoteTmuxProducerRegistry {
    pub(crate) fn new() -> Self {
        Self::default()
    }

    #[cfg(test)]
    pub(crate) fn with_retained_source_max_bytes(retained_source_max_bytes: usize) -> Self {
        Self { state: Mutex::new(RegistryState::default()), retained_source_max_bytes }
    }

    /// Provisions a surface while holding the registry lock across the caller's
    /// canonical commit. Claimers cannot observe an unpublished producer.
    pub(crate) fn transactionally_register_surface<T>(
        &self,
        provenance: ExternalTerminalProvenance,
        surface: SurfaceUuid,
        source_seed: Option<RemoteTmuxProducerSource>,
        transaction: impl FnOnce() -> anyhow::Result<T>,
    ) -> anyhow::Result<T> {
        self.transactionally_register_surface_inner(
            provenance,
            surface,
            source_seed,
            false,
            transaction,
        )
    }

    /// Adds a sibling surface only when its producer was already provisioned.
    /// This prevents a nested materialization from creating an orphan producer
    /// that has no private reconnect source.
    pub(crate) fn transactionally_register_existing_surface<T>(
        &self,
        provenance: ExternalTerminalProvenance,
        surface: SurfaceUuid,
        transaction: impl FnOnce() -> anyhow::Result<T>,
    ) -> anyhow::Result<T> {
        self.transactionally_register_surface_inner(provenance, surface, None, true, transaction)
    }

    fn transactionally_register_surface_inner<T>(
        &self,
        provenance: ExternalTerminalProvenance,
        surface: SurfaceUuid,
        source_seed: Option<RemoteTmuxProducerSource>,
        require_existing_producer: bool,
        transaction: impl FnOnce() -> anyhow::Result<T>,
    ) -> anyhow::Result<T> {
        provenance.validate()?;
        validate_surface(surface)?;
        if let Some(source) = &source_seed {
            source.validate()?;
        }
        let mut registry = self.state.lock().unwrap();
        if require_existing_producer && !registry.producers.contains_key(&provenance.producer_id) {
            anyhow::bail!("unknown remote tmux producer");
        }
        let previous = registry.producers.get(&provenance.producer_id).cloned();
        let previous_retained_source_bytes = registry.retained_source_bytes;
        register_surface_locked(
            &mut registry,
            self.retained_source_max_bytes,
            provenance,
            surface,
            source_seed,
            false,
        )?;
        match transaction() {
            Ok(result) => Ok(result),
            Err(error) => {
                match previous {
                    Some(previous) => {
                        registry.producers.insert(provenance.producer_id, previous);
                    }
                    None => {
                        registry.producers.remove(&provenance.producer_id);
                    }
                }
                registry.retained_source_bytes = previous_retained_source_bytes;
                Err(error)
            }
        }
    }

    /// Rebuilds a daemon-lifetime registry entry from durable provenance. A
    /// source supplied by a replay fills only an absent value.
    pub(crate) fn ensure_surface(
        &self,
        provenance: ExternalTerminalProvenance,
        surface: SurfaceUuid,
        source_seed: Option<RemoteTmuxProducerSource>,
    ) -> anyhow::Result<()> {
        provenance.validate()?;
        validate_surface(surface)?;
        if let Some(source) = &source_seed {
            source.validate()?;
        }
        register_surface_locked(
            &mut self.state.lock().unwrap(),
            self.retained_source_max_bytes,
            provenance,
            surface,
            source_seed,
            true,
        )
    }

    pub(crate) fn claim(
        &self,
        producer_id: uuid::Uuid,
        owner: RemoteTmuxProducerOwner,
        request_id: uuid::Uuid,
        source_seed: Option<&RemoteTmuxProducerSource>,
    ) -> anyhow::Result<RemoteTmuxProducerClaimReceipt> {
        validate_producer_id(producer_id)?;
        validate_private_request_id(request_id, "remote tmux producer")?;
        if let Some(source) = source_seed {
            source.validate()?;
        }
        let source_digest = private_source_digest(source_seed);
        let mut registry = self.state.lock().unwrap();
        let (next_generation, retained_source_bytes) = {
            let state = registry
                .producers
                .get(&producer_id)
                .ok_or_else(|| anyhow::anyhow!("unknown remote tmux producer"))?;
            if let Some(replay) = &state.last_claim
                && replay.receipt.request_id == request_id
            {
                if replay.owner != owner || replay.source_digest != source_digest {
                    anyhow::bail!("remote tmux producer claim request_id payload changed");
                }
                let mut receipt = replay.receipt.clone();
                receipt.source = state.source.clone();
                receipt.replayed = true;
                return Ok(receipt);
            }
            let next_generation = match state.owner {
                Some(current) if current != owner => {
                    anyhow::bail!("remote tmux producer is owned by another live connection")
                }
                Some(_) => state.owner_generation,
                None => state.owner_generation.checked_add(1).ok_or_else(|| {
                    anyhow::anyhow!("remote tmux producer owner generation exhausted")
                })?,
            };
            let added = if state.source.is_none() {
                source_seed.map_or(0, RemoteTmuxProducerSource::retained_bytes)
            } else {
                0
            };
            let retained = retained_bytes_after_replacing(
                registry.retained_source_bytes,
                0,
                added,
                self.retained_source_max_bytes,
                "remote tmux producer",
            )?;
            (next_generation, retained)
        };
        let receipt = {
            let state = registry.producers.get_mut(&producer_id).expect("producer was resolved");
            if state.owner.is_none() {
                state.owner = Some(owner);
                state.owner_generation = next_generation;
                state.last_update = None;
            }
            if state.source.is_none() {
                state.source = source_seed.cloned();
            }
            let receipt = RemoteTmuxProducerClaimReceipt {
                request_id,
                producer_id,
                owner_generation: state.owner_generation,
                source: state.source.clone(),
                replayed: false,
            };
            state.last_claim = Some(ClaimReplay { owner, source_digest, receipt: receipt.clone() });
            receipt
        };
        registry.retained_source_bytes = retained_source_bytes;
        Ok(receipt)
    }

    pub(crate) fn update_source(
        &self,
        producer_id: uuid::Uuid,
        owner: RemoteTmuxProducerOwner,
        owner_generation: u64,
        request_id: uuid::Uuid,
        source: &RemoteTmuxProducerSource,
    ) -> anyhow::Result<RemoteTmuxProducerSourceUpdateReceipt> {
        validate_producer_id(producer_id)?;
        validate_private_request_id(request_id, "remote tmux producer")?;
        if owner_generation == 0 {
            anyhow::bail!("remote tmux producer owner generation must be nonzero");
        }
        source.validate()?;
        let source_digest = private_source_digest(Some(source));
        let mut registry = self.state.lock().unwrap();
        let retained_source_bytes = {
            let state = registry
                .producers
                .get(&producer_id)
                .ok_or_else(|| anyhow::anyhow!("unknown remote tmux producer"))?;
            if let Some(replay) = &state.last_update
                && replay.receipt.request_id == request_id
            {
                if replay.owner != owner
                    || replay.receipt.owner_generation != owner_generation
                    || replay.source_digest != source_digest
                {
                    anyhow::bail!("remote tmux producer source request_id payload changed");
                }
                let mut receipt = replay.receipt.clone();
                receipt.replayed = true;
                return Ok(receipt);
            }
            if state.owner != Some(owner) || state.owner_generation != owner_generation {
                anyhow::bail!("remote tmux producer owner generation changed");
            }
            retained_bytes_after_replacing(
                registry.retained_source_bytes,
                state.source.as_ref().map_or(0, RemoteTmuxProducerSource::retained_bytes),
                source.retained_bytes(),
                self.retained_source_max_bytes,
                "remote tmux producer",
            )?
        };
        let receipt = {
            let state = registry.producers.get_mut(&producer_id).expect("producer was resolved");
            state.source = Some(source.clone());
            let receipt = RemoteTmuxProducerSourceUpdateReceipt {
                request_id,
                producer_id,
                owner_generation,
                replayed: false,
            };
            state.last_update =
                Some(UpdateReplay { owner, source_digest, receipt: receipt.clone() });
            receipt
        };
        registry.retained_source_bytes = retained_source_bytes;
        Ok(receipt)
    }

    pub(crate) fn release_connection(&self, connection_id: u64) {
        for state in self.state.lock().unwrap().producers.values_mut() {
            if state.owner.is_some_and(|owner| owner.connection_id == connection_id) {
                state.owner = None;
                state.last_claim = None;
                state.last_update = None;
            }
        }
    }

    /// Removes one surface association. The private source survives until the
    /// last surface belonging to the producer closes.
    pub(crate) fn remove_surface(&self, producer_id: uuid::Uuid, surface: SurfaceUuid) -> bool {
        let mut registry = self.state.lock().unwrap();
        let Some(state) = registry.producers.get_mut(&producer_id) else {
            return false;
        };
        if !state.surfaces.remove(&surface) {
            return false;
        }
        if !state.surfaces.is_empty() {
            return true;
        }
        let state = registry.producers.remove(&producer_id).expect("empty producer remains");
        registry.retained_source_bytes = registry.retained_source_bytes.saturating_sub(
            state.source.as_ref().map_or(0, RemoteTmuxProducerSource::retained_bytes),
        );
        true
    }

    #[cfg(test)]
    pub(crate) fn contains_producer(&self, producer_id: uuid::Uuid) -> bool {
        self.state.lock().unwrap().producers.contains_key(&producer_id)
    }

    #[cfg(test)]
    pub(crate) fn surface_count(&self, producer_id: uuid::Uuid) -> usize {
        self.state
            .lock()
            .unwrap()
            .producers
            .get(&producer_id)
            .map_or(0, |state| state.surfaces.len())
    }
}

fn register_surface_locked(
    registry: &mut RegistryState,
    retained_source_max_bytes: usize,
    provenance: ExternalTerminalProvenance,
    surface: SurfaceUuid,
    source_seed: Option<RemoteTmuxProducerSource>,
    allow_existing_surface: bool,
) -> anyhow::Result<()> {
    if let (Some(existing), Some(source_seed)) = (
        registry.producers.get(&provenance.producer_id).and_then(|state| state.source.as_ref()),
        source_seed.as_ref(),
    ) && existing != source_seed
    {
        anyhow::bail!("remote tmux producer replay source changed");
    }
    let existing_source_bytes = registry
        .producers
        .get(&provenance.producer_id)
        .and_then(|state| state.source.as_ref())
        .map_or(0, RemoteTmuxProducerSource::retained_bytes);
    let replacement_source_bytes = if existing_source_bytes == 0 {
        source_seed.as_ref().map_or(0, RemoteTmuxProducerSource::retained_bytes)
    } else {
        existing_source_bytes
    };
    let retained_source_bytes = retained_bytes_after_replacing(
        registry.retained_source_bytes,
        existing_source_bytes,
        replacement_source_bytes,
        retained_source_max_bytes,
        "remote tmux producer",
    )?;
    match registry.producers.get_mut(&provenance.producer_id) {
        Some(state) => {
            if state.tmux_session_id != provenance.tmux_session_id {
                anyhow::bail!("remote tmux producer session identity changed");
            }
            if !state.surfaces.insert(surface) && !allow_existing_surface {
                anyhow::bail!("remote tmux producer surface is already registered");
            }
            if state.source.is_none() {
                state.source = source_seed;
            }
        }
        None => {
            registry.producers.insert(
                provenance.producer_id,
                ProducerState::new(provenance.tmux_session_id, surface, source_seed),
            );
        }
    }
    registry.retained_source_bytes = retained_source_bytes;
    Ok(())
}

fn validate_surface(surface: SurfaceUuid) -> anyhow::Result<()> {
    if surface.as_uuid().is_nil() {
        anyhow::bail!("remote tmux producer surface identity must be nonzero");
    }
    Ok(())
}

fn validate_producer_id(producer_id: uuid::Uuid) -> anyhow::Result<()> {
    if producer_id.is_nil() {
        anyhow::bail!("remote tmux producer identity must be nonzero");
    }
    Ok(())
}

fn private_source_digest(source: Option<&RemoteTmuxProducerSource>) -> [u8; 32] {
    let mut digest = Sha256::new();
    match source {
        Some(source) => {
            digest.update([1]);
            update_private_source_digest(&mut digest, source.destination.as_bytes());
            update_private_source_digest(
                &mut digest,
                &source.port.unwrap_or_default().to_be_bytes(),
            );
            update_private_source_digest(
                &mut digest,
                source.identity_file.as_deref().unwrap_or_default().as_bytes(),
            );
            update_private_source_digest(&mut digest, source.session_name.as_bytes());
        }
        None => digest.update([0]),
    }
    digest.finalize().into()
}

fn update_private_source_digest(digest: &mut Sha256, bytes: &[u8]) {
    digest.update((bytes.len() as u64).to_be_bytes());
    digest.update(bytes);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn provenance(producer_id: uuid::Uuid, pane: u64) -> ExternalTerminalProvenance {
        ExternalTerminalProvenance {
            producer_kind: ExternalTerminalProducerKind::RemoteTmux,
            producer_id,
            tmux_session_id: 7,
            tmux_window_id: 11,
            tmux_pane_id: pane,
            presentation_role: ExternalTerminalPresentationRole::NestedPane,
        }
    }

    fn source(session_name: &str) -> RemoteTmuxProducerSource {
        RemoteTmuxProducerSource {
            destination: "agent@private.invalid".into(),
            port: Some(2222),
            identity_file: Some("/private/key".into()),
            session_name: session_name.into(),
        }
    }

    fn owner(connection_id: u64) -> RemoteTmuxProducerOwner {
        RemoteTmuxProducerOwner {
            client_uuid: uuid::Uuid::from_u128(100 + u128::from(connection_id)),
            process_instance_uuid: uuid::Uuid::from_u128(200 + u128::from(connection_id)),
            connection_id,
        }
    }

    #[test]
    fn disconnect_retains_source_and_last_surface_close_deletes_it() {
        let registry = RemoteTmuxProducerRegistry::new();
        let producer = uuid::Uuid::new_v4();
        let first = SurfaceUuid::new();
        let second = SurfaceUuid::new();
        registry.ensure_surface(provenance(producer, 13), first, Some(source("agents"))).unwrap();
        registry.ensure_surface(provenance(producer, 14), second, None).unwrap();
        let claim = registry.claim(producer, owner(1), uuid::Uuid::new_v4(), None).unwrap();
        registry.release_connection(1);
        let replacement = registry.claim(producer, owner(2), uuid::Uuid::new_v4(), None).unwrap();
        assert_eq!(replacement.owner_generation, claim.owner_generation + 1);
        assert_eq!(
            replacement.source.as_ref().map(|source| source.session_name.as_str()),
            Some("agents")
        );

        assert!(registry.remove_surface(producer, first));
        assert!(registry.contains_producer(producer));
        assert!(registry.remove_surface(producer, second));
        assert!(!registry.contains_producer(producer));
    }

    #[test]
    fn transactional_failure_restores_registry_and_cap_rejection_is_atomic() {
        let registry = RemoteTmuxProducerRegistry::with_retained_source_max_bytes(40);
        let producer = uuid::Uuid::new_v4();
        let surface = SurfaceUuid::new();
        let error = registry
            .transactionally_register_surface(
                provenance(producer, 13),
                surface,
                Some(source("agents")),
                || -> anyhow::Result<()> { anyhow::bail!("injected pre-commit failure") },
            )
            .unwrap_err();
        assert!(
            error.to_string().contains("retained sources exceed")
                || error.to_string().contains("pre-commit")
        );
        assert!(!registry.contains_producer(producer));

        let oversized = RemoteTmuxProducerSource {
            destination: "x".repeat(REMOTE_TMUX_PRODUCER_SOURCE_MAX_BYTES),
            port: None,
            identity_file: None,
            session_name: "sentinel-secret".into(),
        };
        let error = registry
            .ensure_surface(provenance(producer, 13), surface, Some(oversized))
            .unwrap_err()
            .to_string();
        assert!(!error.contains("sentinel-secret"));
        assert!(!registry.contains_producer(producer));
    }

    #[test]
    fn debug_and_validation_are_redacted() {
        let secret = "sentinel-private-producer-secret";
        let source = RemoteTmuxProducerSource {
            destination: format!("agent@{secret}"),
            port: None,
            identity_file: Some(format!("/private/{secret}\n")),
            session_name: secret.into(),
        };
        assert!(!source.validate().unwrap_err().to_string().contains(secret));
        assert!(!format!("{source:?}").contains(secret));
    }
}
