//! Connection-owned private state for browser runtimes hosted by a native frontend.
//!
//! The registry is deliberately outside canonical topology and the durable state
//! store. A source URL can contain credentials, private paths, or application
//! state, so only the exact trusted connection holding a generation-fenced claim
//! may read or replace it.

use std::collections::BTreeMap;
use std::fmt;
use std::sync::Mutex;

use sha2::{Digest, Sha256};

use crate::SurfaceUuid;
use crate::private_runtime::{
    ConnectionPrivateOwner, retained_bytes_after_replacing, validate_private_request_id,
};

pub(crate) const FRONTEND_NATIVE_BROWSER_SOURCE_MAX_BYTES: usize = 64 * 1024;
pub(crate) const FRONTEND_NATIVE_BROWSER_RETAINED_SOURCE_MAX_BYTES: usize = 16 * 1024 * 1024;

pub(crate) type FrontendNativeBrowserOwner = ConnectionPrivateOwner;

#[derive(Clone, PartialEq, Eq)]
pub(crate) struct FrontendNativeBrowserClaimReceipt {
    pub request_id: uuid::Uuid,
    pub owner_generation: u64,
    pub source_url: Option<String>,
    pub replayed: bool,
}

impl fmt::Debug for FrontendNativeBrowserClaimReceipt {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("FrontendNativeBrowserClaimReceipt")
            .field("request_id", &self.request_id)
            .field("owner_generation", &self.owner_generation)
            .field("source_present", &self.source_url.is_some())
            .field("replayed", &self.replayed)
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct FrontendNativeBrowserSourceReceipt {
    pub request_id: uuid::Uuid,
    pub owner_generation: u64,
    pub replayed: bool,
}

#[derive(Clone)]
struct ClaimReplay {
    owner: FrontendNativeBrowserOwner,
    seed_digest: [u8; 32],
    request_id: uuid::Uuid,
    owner_generation: u64,
}

#[derive(Clone)]
struct SourceReplay {
    owner: FrontendNativeBrowserOwner,
    source_digest: [u8; 32],
    receipt: FrontendNativeBrowserSourceReceipt,
}

#[derive(Default)]
struct FrontendNativeBrowserState {
    source_url: Option<String>,
    owner: Option<FrontendNativeBrowserOwner>,
    owner_generation: u64,
    last_claim: Option<ClaimReplay>,
    last_source_update: Option<SourceReplay>,
}

#[derive(Default)]
struct FrontendNativeBrowserRegistryState {
    states: BTreeMap<SurfaceUuid, FrontendNativeBrowserState>,
    retained_source_bytes: usize,
}

pub(crate) struct FrontendNativeBrowserRegistry {
    state: Mutex<FrontendNativeBrowserRegistryState>,
    retained_source_max_bytes: usize,
}

impl Default for FrontendNativeBrowserRegistry {
    fn default() -> Self {
        Self {
            state: Mutex::new(FrontendNativeBrowserRegistryState::default()),
            retained_source_max_bytes: FRONTEND_NATIVE_BROWSER_RETAINED_SOURCE_MAX_BYTES,
        }
    }
}

impl FrontendNativeBrowserRegistry {
    pub(crate) fn new() -> Self {
        Self::default()
    }

    #[cfg(test)]
    pub(crate) fn with_retained_source_max_bytes(retained_source_max_bytes: usize) -> Self {
        Self {
            state: Mutex::new(FrontendNativeBrowserRegistryState::default()),
            retained_source_max_bytes,
        }
    }

    /// Registers one canonical placement and its initial in-memory source.
    pub(crate) fn insert_surface(
        &self,
        surface_uuid: SurfaceUuid,
        source_url: Option<String>,
    ) -> anyhow::Result<()> {
        if surface_uuid.as_uuid().is_nil() {
            anyhow::bail!("frontend-native browser surface identity must be nonzero");
        }
        if let Some(source_url) = source_url.as_deref() {
            validate_frontend_native_browser_source(source_url)?;
        }
        let source_bytes = source_url.as_ref().map_or(0, |source_url| source_url.len());
        let mut registry = self.state.lock().unwrap();
        if registry.states.contains_key(&surface_uuid) {
            anyhow::bail!("frontend-native browser surface is already registered");
        }
        let retained_source_bytes = self.retained_source_bytes_after_replacing(
            registry.retained_source_bytes,
            0,
            source_bytes,
        )?;
        registry.states.insert(
            surface_uuid,
            FrontendNativeBrowserState { source_url, ..FrontendNativeBrowserState::default() },
        );
        registry.retained_source_bytes = retained_source_bytes;
        Ok(())
    }

    /// Keeps a provisional private source invisible to claimers until the
    /// caller's canonical transaction commits. An error restores the exact
    /// prior registry entry and retained-byte count.
    pub(crate) fn transactionally_insert_surface<T>(
        &self,
        surface_uuid: SurfaceUuid,
        source_url: Option<String>,
        transaction: impl FnOnce() -> anyhow::Result<T>,
    ) -> anyhow::Result<T> {
        if surface_uuid.as_uuid().is_nil() {
            anyhow::bail!("frontend-native browser surface identity must be nonzero");
        }
        if let Some(source_url) = source_url.as_deref() {
            validate_frontend_native_browser_source(source_url)?;
        }
        let mut registry = self.state.lock().unwrap();
        if registry.states.contains_key(&surface_uuid) {
            anyhow::bail!("frontend-native browser surface is already registered");
        }
        let source_bytes = source_url.as_ref().map_or(0, String::len);
        let retained_source_bytes = retained_bytes_after_replacing(
            registry.retained_source_bytes,
            0,
            source_bytes,
            self.retained_source_max_bytes,
            "frontend-native browser",
        )?;
        registry.states.insert(
            surface_uuid,
            FrontendNativeBrowserState { source_url, ..FrontendNativeBrowserState::default() },
        );
        let previous_retained_source_bytes = registry.retained_source_bytes;
        registry.retained_source_bytes = retained_source_bytes;
        match transaction() {
            Ok(result) => Ok(result),
            Err(error) => {
                registry.states.remove(&surface_uuid);
                registry.retained_source_bytes = previous_retained_source_bytes;
                Err(error)
            }
        }
    }

    /// Restores a registry entry or fills its absent private source after a
    /// durable canonical placement replay. Existing sources always win.
    pub(crate) fn ensure_surface_seed(
        &self,
        surface_uuid: SurfaceUuid,
        source_seed: Option<&str>,
    ) -> anyhow::Result<()> {
        if surface_uuid.as_uuid().is_nil() {
            anyhow::bail!("frontend-native browser surface identity must be nonzero");
        }
        if let Some(source_seed) = source_seed {
            validate_frontend_native_browser_source(source_seed)?;
        }
        let mut registry = self.state.lock().unwrap();
        if let (Some(existing), Some(source_seed)) = (
            registry.states.get(&surface_uuid).and_then(|state| state.source_url.as_deref()),
            source_seed,
        ) && existing != source_seed
        {
            anyhow::bail!("frontend-native browser replay source changed");
        }
        let existing_source_bytes = registry
            .states
            .get(&surface_uuid)
            .and_then(|state| state.source_url.as_ref())
            .map_or(0, |source_url| source_url.len());
        let replacement_source_bytes = if existing_source_bytes == 0 {
            source_seed.map_or(0, str::len)
        } else {
            existing_source_bytes
        };
        let retained_source_bytes = self.retained_source_bytes_after_replacing(
            registry.retained_source_bytes,
            existing_source_bytes,
            replacement_source_bytes,
        )?;
        let state = registry.states.entry(surface_uuid).or_default();
        if state.source_url.is_none() {
            state.source_url = source_seed.map(str::to_owned);
        }
        registry.retained_source_bytes = retained_source_bytes;
        Ok(())
    }

    /// Claims the private runtime for one exact live connection.
    ///
    /// A seed fills only an absent source. It cannot overwrite a newer value
    /// retained across a frontend restart.
    pub(crate) fn claim(
        &self,
        surface_uuid: SurfaceUuid,
        owner: FrontendNativeBrowserOwner,
        request_id: uuid::Uuid,
        source_seed: Option<&str>,
    ) -> anyhow::Result<FrontendNativeBrowserClaimReceipt> {
        validate_private_request_id(request_id, "frontend-native browser")?;
        if let Some(source_seed) = source_seed {
            validate_frontend_native_browser_source(source_seed)?;
        }
        let seed_digest = private_source_digest(source_seed);
        let mut registry = self.state.lock().unwrap();
        let (next_generation, retained_source_bytes) = {
            let state = registry
                .states
                .get(&surface_uuid)
                .ok_or_else(|| anyhow::anyhow!("unknown frontend-native browser surface"))?;
            if let Some(replay) = &state.last_claim
                && replay.request_id == request_id
            {
                if replay.owner != owner || replay.seed_digest != seed_digest {
                    anyhow::bail!("frontend-native browser claim request_id payload changed");
                }
                return Ok(FrontendNativeBrowserClaimReceipt {
                    request_id,
                    owner_generation: replay.owner_generation,
                    source_url: state.source_url.clone(),
                    replayed: true,
                });
            }
            let next_generation = match state.owner {
                Some(current) if current != owner => {
                    anyhow::bail!("frontend-native browser is owned by another live connection")
                }
                Some(_) => state.owner_generation,
                None => state.owner_generation.checked_add(1).ok_or_else(|| {
                    anyhow::anyhow!("frontend-native browser owner generation exhausted")
                })?,
            };
            let added_source_bytes =
                if state.source_url.is_none() { source_seed.map_or(0, str::len) } else { 0 };
            let retained_source_bytes = self.retained_source_bytes_after_replacing(
                registry.retained_source_bytes,
                0,
                added_source_bytes,
            )?;
            (next_generation, retained_source_bytes)
        };
        let receipt = {
            let state = registry.states.get_mut(&surface_uuid).expect("surface was resolved");
            if state.owner.is_none() {
                state.owner_generation = next_generation;
                state.owner = Some(owner);
                state.last_source_update = None;
            }
            if state.source_url.is_none() {
                state.source_url = source_seed.map(str::to_owned);
            }
            let receipt = FrontendNativeBrowserClaimReceipt {
                request_id,
                owner_generation: state.owner_generation,
                source_url: state.source_url.clone(),
                replayed: false,
            };
            state.last_claim = Some(ClaimReplay {
                owner,
                seed_digest,
                request_id,
                owner_generation: receipt.owner_generation,
            });
            receipt
        };
        registry.retained_source_bytes = retained_source_bytes;
        Ok(receipt)
    }

    /// Replaces the source for one exact owner generation without touching
    /// topology revision, journal, or durable session state.
    pub(crate) fn update_source(
        &self,
        surface_uuid: SurfaceUuid,
        owner: FrontendNativeBrowserOwner,
        owner_generation: u64,
        request_id: uuid::Uuid,
        source_url: &str,
    ) -> anyhow::Result<FrontendNativeBrowserSourceReceipt> {
        validate_private_request_id(request_id, "frontend-native browser")?;
        if owner_generation == 0 {
            anyhow::bail!("frontend-native browser owner generation must be nonzero");
        }
        validate_frontend_native_browser_source(source_url)?;
        let source_digest = private_source_digest(Some(source_url));
        let mut registry = self.state.lock().unwrap();
        let retained_source_bytes = {
            let state = registry
                .states
                .get(&surface_uuid)
                .ok_or_else(|| anyhow::anyhow!("unknown frontend-native browser surface"))?;
            if let Some(replay) = &state.last_source_update
                && replay.receipt.request_id == request_id
            {
                if replay.owner != owner
                    || replay.receipt.owner_generation != owner_generation
                    || replay.source_digest != source_digest
                {
                    anyhow::bail!("frontend-native browser source request_id payload changed");
                }
                let mut receipt = replay.receipt.clone();
                receipt.replayed = true;
                return Ok(receipt);
            }
            if state.owner != Some(owner) || state.owner_generation != owner_generation {
                anyhow::bail!("frontend-native browser owner generation changed");
            }
            self.retained_source_bytes_after_replacing(
                registry.retained_source_bytes,
                state.source_url.as_ref().map_or(0, |source_url| source_url.len()),
                source_url.len(),
            )?
        };
        let receipt = {
            let state = registry.states.get_mut(&surface_uuid).expect("surface was resolved");
            state.source_url = Some(source_url.to_owned());
            let receipt = FrontendNativeBrowserSourceReceipt {
                request_id,
                owner_generation,
                replayed: false,
            };
            state.last_source_update =
                Some(SourceReplay { owner, source_digest, receipt: receipt.clone() });
            receipt
        };
        registry.retained_source_bytes = retained_source_bytes;
        Ok(receipt)
    }

    /// Revokes every lease held by one disconnected transport while retaining
    /// sources for the next trusted frontend claimant.
    pub(crate) fn release_connection(&self, connection_id: u64) {
        for state in self.state.lock().unwrap().states.values_mut() {
            if state.owner.is_some_and(|owner| owner.connection_id == connection_id) {
                state.owner = None;
                state.last_claim = None;
                state.last_source_update = None;
            }
        }
    }

    /// Deletes all private state when the canonical surface closes.
    pub(crate) fn remove_surface(&self, surface_uuid: SurfaceUuid) -> bool {
        let mut registry = self.state.lock().unwrap();
        let Some(state) = registry.states.remove(&surface_uuid) else {
            return false;
        };
        registry.retained_source_bytes -=
            state.source_url.as_ref().map_or(0, |source_url| source_url.len());
        true
    }

    #[cfg(test)]
    pub(crate) fn contains_surface(&self, surface_uuid: SurfaceUuid) -> bool {
        self.state.lock().unwrap().states.contains_key(&surface_uuid)
    }

    fn retained_source_bytes_after_replacing(
        &self,
        retained_source_bytes: usize,
        replaced_source_bytes: usize,
        replacement_source_bytes: usize,
    ) -> anyhow::Result<usize> {
        retained_bytes_after_replacing(
            retained_source_bytes,
            replaced_source_bytes,
            replacement_source_bytes,
            self.retained_source_max_bytes,
            "frontend-native browser",
        )
    }
}

pub(crate) fn validate_frontend_native_browser_source(source_url: &str) -> anyhow::Result<()> {
    if source_url.is_empty() {
        anyhow::bail!("frontend-native browser source must not be empty");
    }
    if source_url.len() > FRONTEND_NATIVE_BROWSER_SOURCE_MAX_BYTES {
        anyhow::bail!(
            "frontend-native browser source exceeds {FRONTEND_NATIVE_BROWSER_SOURCE_MAX_BYTES} bytes"
        );
    }
    if source_url.chars().any(|character| character.is_control() || character.is_whitespace()) {
        anyhow::bail!("frontend-native browser source contains invalid characters");
    }
    let Some((scheme, remainder)) = source_url.split_once(':') else {
        anyhow::bail!("frontend-native browser source must be an absolute URL");
    };
    let mut scheme_bytes = scheme.bytes();
    if !matches!(scheme_bytes.next(), Some(b'A'..=b'Z' | b'a'..=b'z'))
        || !scheme_bytes.all(
            |byte| matches!(byte, b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'+' | b'-' | b'.'),
        )
        || remainder.is_empty()
    {
        anyhow::bail!("frontend-native browser source is not a valid absolute URL");
    }
    if matches!(scheme.to_ascii_lowercase().as_str(), "http" | "https" | "ws" | "wss") {
        let Some(authority_and_path) = remainder.strip_prefix("//") else {
            anyhow::bail!("frontend-native browser source is not a valid absolute URL");
        };
        let authority = authority_and_path.split(['/', '?', '#']).next().unwrap_or_default();
        if authority.is_empty() {
            anyhow::bail!("frontend-native browser source is not a valid absolute URL");
        }
    }
    Ok(())
}

fn private_source_digest(source_url: Option<&str>) -> [u8; 32] {
    let mut digest = Sha256::new();
    match source_url {
        Some(source_url) => {
            digest.update([1]);
            digest.update((source_url.len() as u64).to_be_bytes());
            digest.update(source_url.as_bytes());
        }
        None => digest.update([0]),
    }
    digest.finalize().into()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn owner(connection_id: u64) -> FrontendNativeBrowserOwner {
        FrontendNativeBrowserOwner {
            client_uuid: uuid::Uuid::from_u128(100 + u128::from(connection_id)),
            process_instance_uuid: uuid::Uuid::from_u128(200 + u128::from(connection_id)),
            connection_id,
        }
    }

    #[test]
    fn claim_is_connection_exclusive_and_request_idempotent() {
        let registry = FrontendNativeBrowserRegistry::new();
        let surface = SurfaceUuid::new();
        let request = uuid::Uuid::new_v4();
        registry.insert_surface(surface, None).unwrap();

        let first = registry
            .claim(surface, owner(1), request, Some("https://private.invalid/seed"))
            .unwrap();
        assert_eq!(first.owner_generation, 1);
        assert_eq!(first.source_url.as_deref(), Some("https://private.invalid/seed"));
        assert!(!first.replayed);
        let replay = registry
            .claim(surface, owner(1), request, Some("https://private.invalid/seed"))
            .unwrap();
        assert!(replay.replayed);
        assert_eq!(replay.owner_generation, first.owner_generation);

        let changed = registry
            .claim(surface, owner(1), request, Some("https://private.invalid/changed"))
            .unwrap_err();
        assert!(changed.to_string().contains("payload changed"));
        let competing = registry.claim(surface, owner(2), uuid::Uuid::new_v4(), None).unwrap_err();
        assert!(competing.to_string().contains("another live connection"));
    }

    #[test]
    fn disconnect_revokes_authority_but_retains_private_source() {
        let registry = FrontendNativeBrowserRegistry::new();
        let surface = SurfaceUuid::new();
        registry
            .insert_surface(surface, Some("https://private.invalid/created".to_string()))
            .unwrap();
        let first = registry.claim(surface, owner(1), uuid::Uuid::new_v4(), None).unwrap();
        registry
            .update_source(
                surface,
                owner(1),
                first.owner_generation,
                uuid::Uuid::new_v4(),
                "https://private.invalid/latest",
            )
            .unwrap();

        registry.release_connection(1);
        let replay_error = registry
            .ensure_surface_seed(
                surface,
                Some("https://private.invalid/sentinel-changed-replay-seed"),
            )
            .unwrap_err()
            .to_string();
        assert!(replay_error.contains("replay source changed"));
        assert!(!replay_error.contains("sentinel"));
        registry.ensure_surface_seed(surface, None).unwrap();
        let replacement = registry
            .claim(
                surface,
                owner(2),
                uuid::Uuid::new_v4(),
                Some("https://private.invalid/stale-seed"),
            )
            .unwrap();
        assert_eq!(replacement.owner_generation, first.owner_generation + 1);
        assert_eq!(replacement.source_url.as_deref(), Some("https://private.invalid/latest"));
    }

    #[test]
    fn durable_replay_can_recreate_an_absent_registry_entry() {
        let registry = FrontendNativeBrowserRegistry::new();
        let surface = SurfaceUuid::new();
        registry.ensure_surface_seed(surface, Some("https://private.invalid/replayed")).unwrap();
        let claim = registry.claim(surface, owner(1), uuid::Uuid::new_v4(), None).unwrap();
        assert_eq!(claim.owner_generation, 1);
        assert_eq!(claim.source_url.as_deref(), Some("https://private.invalid/replayed"));
    }

    #[test]
    fn source_updates_are_generation_fenced_and_idempotent() {
        let registry = FrontendNativeBrowserRegistry::new();
        let surface = SurfaceUuid::new();
        registry.insert_surface(surface, None).unwrap();
        let claim = registry.claim(surface, owner(1), uuid::Uuid::new_v4(), None).unwrap();
        let request = uuid::Uuid::new_v4();
        let updated = registry
            .update_source(
                surface,
                owner(1),
                claim.owner_generation,
                request,
                "https://private.invalid/latest",
            )
            .unwrap();
        assert!(!updated.replayed);
        let replay = registry
            .update_source(
                surface,
                owner(1),
                claim.owner_generation,
                request,
                "https://private.invalid/latest",
            )
            .unwrap();
        assert!(replay.replayed);
        assert!(
            registry
                .update_source(
                    surface,
                    owner(1),
                    claim.owner_generation,
                    request,
                    "https://private.invalid/changed",
                )
                .unwrap_err()
                .to_string()
                .contains("payload changed")
        );

        registry.release_connection(1);
        assert!(
            registry
                .update_source(
                    surface,
                    owner(1),
                    claim.owner_generation,
                    uuid::Uuid::new_v4(),
                    "https://private.invalid/late",
                )
                .unwrap_err()
                .to_string()
                .contains("generation changed")
        );
    }

    #[test]
    fn validation_and_debug_never_echo_source_secrets() {
        let secret = "sentinel-private-source-secret";
        for invalid in [
            secret.to_string(),
            format!("https://private.invalid/{secret}\n"),
            format!("https://private.invalid/{secret} space"),
            format!("https://#{secret}"),
            format!(
                "https://private.invalid/{secret}{}",
                "x".repeat(FRONTEND_NATIVE_BROWSER_SOURCE_MAX_BYTES)
            ),
        ] {
            let error = validate_frontend_native_browser_source(&invalid).unwrap_err().to_string();
            assert!(!error.contains(secret));
        }

        let receipt = FrontendNativeBrowserClaimReceipt {
            request_id: uuid::Uuid::new_v4(),
            owner_generation: 1,
            source_url: Some(format!("https://private.invalid/{secret}")),
            replayed: false,
        };
        assert!(!format!("{receipt:?}").contains(secret));
    }

    #[test]
    fn closing_surface_deletes_retained_source_and_claim_state() {
        let registry = FrontendNativeBrowserRegistry::new();
        let surface = SurfaceUuid::new();
        registry
            .insert_surface(surface, Some("https://private.invalid/closed".to_string()))
            .unwrap();
        assert!(registry.remove_surface(surface));
        assert!(!registry.remove_surface(surface));
        assert!(
            registry
                .claim(surface, owner(1), uuid::Uuid::new_v4(), None)
                .unwrap_err()
                .to_string()
                .contains("unknown frontend-native browser")
        );
    }

    #[test]
    fn retained_source_cap_rejections_are_atomic_and_redacted() {
        let secret = "sentinel-cap-secret";
        let registry = FrontendNativeBrowserRegistry::with_retained_source_max_bytes(80);
        let occupied = SurfaceUuid::new();
        let claim_target = SurfaceUuid::new();
        let rejected_insert = SurfaceUuid::new();
        let occupied_source = format!("private:{secret}-occupied");
        let claim_source = format!("private:{secret}-claim");
        registry.insert_surface(occupied, Some(occupied_source.clone())).unwrap();
        registry.insert_surface(claim_target, None).unwrap();

        let insert_error = registry
            .insert_surface(
                rejected_insert,
                Some(format!("private:{secret}-insert-{}", "x".repeat(40))),
            )
            .unwrap_err()
            .to_string();
        assert!(insert_error.contains("retained sources exceed"));
        assert!(!insert_error.contains(secret));
        registry.insert_surface(rejected_insert, Some("private:ok".to_string())).unwrap();

        let claim_error = registry
            .claim(
                claim_target,
                owner(1),
                uuid::Uuid::new_v4(),
                Some(&format!("private:{secret}-{}", "x".repeat(40))),
            )
            .unwrap_err()
            .to_string();
        assert!(claim_error.contains("retained sources exceed"));
        assert!(!claim_error.contains(secret));
        let claim = registry
            .claim(claim_target, owner(2), uuid::Uuid::new_v4(), Some(&claim_source))
            .unwrap();
        assert_eq!(claim.owner_generation, 1);
        assert_eq!(claim.source_url.as_deref(), Some(claim_source.as_str()));

        let occupied_claim =
            registry.claim(occupied, owner(3), uuid::Uuid::new_v4(), None).unwrap();
        let update_error = registry
            .update_source(
                occupied,
                owner(3),
                occupied_claim.owner_generation,
                uuid::Uuid::new_v4(),
                &format!("private:{secret}-update-{}", "x".repeat(40)),
            )
            .unwrap_err()
            .to_string();
        assert!(update_error.contains("retained sources exceed"));
        assert!(!update_error.contains(secret));
        let retained = registry.claim(occupied, owner(3), uuid::Uuid::new_v4(), None).unwrap();
        assert_eq!(retained.source_url.as_deref(), Some(occupied_source.as_str()));

        registry
            .update_source(
                occupied,
                owner(3),
                occupied_claim.owner_generation,
                uuid::Uuid::new_v4(),
                "private:short",
            )
            .unwrap();
        let replacement_accounting = SurfaceUuid::new();
        let replacement_source = format!("private:{}", "r".repeat(16));
        assert_eq!(replacement_source.len(), 24);
        registry.insert_surface(replacement_accounting, Some(replacement_source)).unwrap();

        assert!(registry.remove_surface(claim_target));
        let removal_accounting = SurfaceUuid::new();
        registry
            .insert_surface(removal_accounting, Some(format!("private:{}", "z".repeat(25))))
            .unwrap();
    }
}
