//! Protocol-v9 terminal input and geometry authority.
//!
//! Input and geometry are independent, connection-claimed leases. Input
//! operations additionally receive a daemon-global order and may be grouped so
//! a paste or press/drag/release lifecycle cannot be split by another caller.
//! Automation never owns geometry and can only use an explicit, bounded input
//! delegation from the current input holder.

use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::fmt;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use uuid::Uuid;

use crate::{PresentationId, SurfaceUuid};

pub(crate) const DEFAULT_TERMINAL_LEASE_TTL_MS: u64 = 5_000;
pub(crate) const MAX_TERMINAL_LEASE_TTL_MS: u64 = 30_000;
pub(crate) const MAX_AUTOMATION_DELEGATION_TTL_MS: u64 = 10_000;
/// Completed operations remain queryable until their originating logical
/// client acknowledges the receipt. Capacity is enforced before execution so
/// recovery can never silently turn an old retry into a duplicate PTY write.
pub(crate) const MAX_UNACKNOWLEDGED_RECEIPTS_PER_TERMINAL: usize = 512;
const MAX_DELEGATIONS_PER_TERMINAL: usize = 16;

pub(crate) trait AuthorityClock: Send + Sync {
    fn now_ms(&self) -> u64;
}

pub(crate) struct MonotonicAuthorityClock {
    origin: Instant,
}

impl MonotonicAuthorityClock {
    pub(crate) fn new() -> Self {
        Self { origin: Instant::now() }
    }
}

impl AuthorityClock for MonotonicAuthorityClock {
    fn now_ms(&self) -> u64 {
        u64::try_from(self.origin.elapsed().as_millis()).unwrap_or(u64::MAX)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TerminalControlMode {
    LegacyShared,
    Leased,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum TerminalLeaseKind {
    Input,
    Geometry,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum AutomationInputScope {
    Text,
    Key,
    Mouse,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct TerminalInputGroup {
    pub(crate) id: Uuid,
    pub(crate) index: u32,
    pub(crate) end: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct PresentationAuthority {
    pub(crate) connection: u64,
    pub(crate) presentation_id: PresentationId,
    pub(crate) presentation_generation: u64,
    pub(crate) surface_uuid: SurfaceUuid,
}

/// The stable identity and exact ephemeral claim that receives a lease.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct TerminalLeaseClaim {
    pub(crate) connection: u64,
    pub(crate) client_uuid: Uuid,
    pub(crate) process_instance_uuid: Uuid,
    pub(crate) presentation_id: PresentationId,
    pub(crate) presentation_generation: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct TerminalConnectionClaim {
    pub(crate) connection: u64,
    pub(crate) client_uuid: Uuid,
    pub(crate) process_instance_uuid: Uuid,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct TerminalLeaseReference {
    pub(crate) connection: u64,
    pub(crate) client_uuid: Uuid,
    pub(crate) process_instance_uuid: Uuid,
    pub(crate) presentation_id: PresentationId,
    pub(crate) presentation_generation: u64,
    pub(crate) lease_id: Uuid,
    pub(crate) lease_generation: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct TerminalDelegationReference {
    pub(crate) connection: u64,
    pub(crate) client_uuid: Uuid,
    pub(crate) process_instance_uuid: Uuid,
    pub(crate) delegation_id: Uuid,
    pub(crate) delegation_generation: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TerminalLease {
    pub(crate) kind: TerminalLeaseKind,
    pub(crate) surface_uuid: SurfaceUuid,
    pub(crate) lease_id: Uuid,
    pub(crate) lease_generation: u64,
    pub(crate) revocation_sequence: u64,
    pub(crate) expires_at_ms: u64,
    pub(crate) next_client_sequence: u64,
    pub(crate) next_global_input_sequence: Option<u64>,
    pub(crate) migrated_from_legacy: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TerminalInputDelegation {
    pub(crate) surface_uuid: SurfaceUuid,
    pub(crate) delegation_id: Uuid,
    pub(crate) delegation_generation: u64,
    pub(crate) owner_lease_generation: u64,
    pub(crate) delegate: TerminalConnectionClaim,
    pub(crate) expires_at_ms: u64,
    pub(crate) scopes: BTreeSet<AutomationInputScope>,
    pub(crate) next_client_sequence: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TerminalOperationKind {
    Input,
    Geometry,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct RequestFingerprint(pub(crate) [u8; 32]);

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum TerminalOperationOutcome {
    InputApplied { encoded_bytes: usize },
    GeometryApplied { cols: u16, rows: u16, changed: bool },
    InputIndeterminate { diagnostic: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TerminalOperationReceipt {
    pub(crate) request_id: Uuid,
    pub(crate) kind: TerminalOperationKind,
    /// Caller-local strict sequence, used to reject gaps within one authority.
    pub(crate) sequence: u64,
    /// Daemon-global order for input on this terminal. Geometry omits it.
    pub(crate) ordered_input_sequence: Option<u64>,
    pub(crate) lease_generation: u64,
    pub(crate) outcome: TerminalOperationOutcome,
    pub(crate) replayed: bool,
}

#[derive(Debug)]
pub(crate) enum BeginTerminalOperation {
    Execute(TerminalOperationPermit),
    Replay(TerminalOperationReceipt),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum InputAuthorization {
    Lease { lease_id: Uuid },
    Delegation { delegation_id: Uuid },
}

#[derive(Debug)]
pub(crate) struct TerminalOperationPermit {
    surface_uuid: SurfaceUuid,
    lease_id: Uuid,
    lease_generation: u64,
    operation_nonce: u64,
    kind: TerminalOperationKind,
    sequence: u64,
    ordered_input_sequence: Option<u64>,
    request_id: Uuid,
    client_uuid: Uuid,
    fingerprint: RequestFingerprint,
    input_authorization: Option<InputAuthorization>,
    previous_input_group: Option<ActiveInputGroup>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum TerminalAuthorityError {
    PresentationNotVisible,
    PresentationOwnedByAnotherConnection,
    PresentationGenerationMismatch,
    PresentationSurfaceMismatch,
    TerminalMigratedToLeasedControl,
    LeaseHeldByAnotherPresentation { kind: TerminalLeaseKind, expires_at_ms: u64 },
    LeaseMissing(TerminalLeaseKind),
    LeaseExpired(TerminalLeaseKind),
    LeaseMismatch(TerminalLeaseKind),
    LeaseGenerationMismatch(TerminalLeaseKind),
    LeaseBusy(TerminalLeaseKind),
    InputSequenceGap { expected: u64, received: u64 },
    GeometrySequenceGap { expected: u64, received: u64 },
    RequestConflict,
    ReceiptCapacityReached,
    OperationInFlight(TerminalOperationKind),
    OperationPermitInvalid,
    OperationOutcomeMismatch,
    DelegationLimitReached,
    DelegationMissing,
    DelegationExpired,
    DelegationMismatch,
    DelegationScopeDenied,
    InputGroupIdentifierInvalid,
    InputGroupInProgress,
    InputGroupMismatch,
    InputGroupIndexGap { expected: u32, received: u32 },
}

impl fmt::Display for TerminalAuthorityError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        use TerminalAuthorityError as Error;
        match self {
            Error::PresentationNotVisible => formatter.write_str("presentation is not visible"),
            Error::PresentationOwnedByAnotherConnection => {
                formatter.write_str("presentation is owned by another connection")
            }
            Error::PresentationGenerationMismatch => {
                formatter.write_str("presentation generation is stale")
            }
            Error::PresentationSurfaceMismatch => {
                formatter.write_str("presentation does not display this terminal")
            }
            Error::TerminalMigratedToLeasedControl => {
                formatter.write_str("terminal uses protocol-v9 leased control")
            }
            Error::LeaseHeldByAnotherPresentation { kind, expires_at_ms } => {
                write!(formatter, "{kind:?} lease is held until {expires_at_ms}ms")
            }
            Error::LeaseMissing(kind) => write!(formatter, "{kind:?} lease is missing"),
            Error::LeaseExpired(kind) => write!(formatter, "{kind:?} lease expired"),
            Error::LeaseMismatch(kind) => write!(formatter, "{kind:?} lease does not match"),
            Error::LeaseGenerationMismatch(kind) => {
                write!(formatter, "{kind:?} lease generation is stale")
            }
            Error::LeaseBusy(kind) => write!(formatter, "{kind:?} lease has an active input group"),
            Error::InputSequenceGap { expected, received } => {
                write!(
                    formatter,
                    "terminal input sequence gap: expected {expected}, got {received}"
                )
            }
            Error::GeometrySequenceGap { expected, received } => write!(
                formatter,
                "terminal geometry sequence gap: expected {expected}, got {received}"
            ),
            Error::RequestConflict => {
                formatter.write_str("request id was already used with a different payload")
            }
            Error::ReceiptCapacityReached => formatter.write_str(
                "terminal unacknowledged receipt capacity reached; acknowledge completed requests before sending more input",
            ),
            Error::OperationInFlight(kind) => write!(formatter, "{kind:?} operation is in flight"),
            Error::OperationPermitInvalid => {
                formatter.write_str("terminal operation permit is no longer valid")
            }
            Error::OperationOutcomeMismatch => {
                formatter.write_str("terminal operation outcome has the wrong kind")
            }
            Error::DelegationLimitReached => {
                formatter.write_str("terminal delegation limit reached")
            }
            Error::DelegationMissing => formatter.write_str("terminal input delegation is missing"),
            Error::DelegationExpired => formatter.write_str("terminal input delegation expired"),
            Error::DelegationMismatch => {
                formatter.write_str("terminal input delegation does not match")
            }
            Error::DelegationScopeDenied => {
                formatter.write_str("terminal input delegation scope denied")
            }
            Error::InputGroupIdentifierInvalid => {
                formatter.write_str("input group id must be non-nil")
            }
            Error::InputGroupInProgress => {
                formatter.write_str("another terminal input group is active")
            }
            Error::InputGroupMismatch => formatter.write_str("terminal input group does not match"),
            Error::InputGroupIndexGap { expected, received } => {
                write!(formatter, "input group index gap: expected {expected}, got {received}")
            }
        }
    }
}

impl std::error::Error for TerminalAuthorityError {}

#[derive(Clone, Copy)]
struct VisiblePresentation {
    connection: u64,
    generation: u64,
    surface_uuid: SurfaceUuid,
}

struct ActiveLease {
    lease_id: Uuid,
    generation: u64,
    holder: TerminalLeaseClaim,
    expires_at_ms: u64,
    ttl_ms: u64,
    next_client_sequence: u64,
    in_flight: Option<InFlightOperation>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct ActiveInputGroup {
    id: Uuid,
    client_uuid: Uuid,
    authorization: InputAuthorization,
    next_index: u32,
}

struct ActiveDelegation {
    delegation_id: Uuid,
    generation: u64,
    owner_lease_generation: u64,
    delegate: TerminalConnectionClaim,
    expires_at_ms: u64,
    scopes: BTreeSet<AutomationInputScope>,
    next_client_sequence: u64,
}

struct InFlightOperation {
    nonce: u64,
    kind: TerminalOperationKind,
    sequence: u64,
    ordered_input_sequence: Option<u64>,
    request_id: Uuid,
    client_uuid: Uuid,
    fingerprint: RequestFingerprint,
    input_authorization: Option<InputAuthorization>,
}

#[derive(Clone)]
struct StoredReceipt {
    client_uuid: Uuid,
    fingerprint: RequestFingerprint,
    receipt: TerminalOperationReceipt,
}

struct TerminalAuthorityState {
    mode: TerminalControlMode,
    next_input_lease_generation: u64,
    next_geometry_lease_generation: u64,
    input_revocation_sequence: u64,
    geometry_revocation_sequence: u64,
    next_delegation_generation: u64,
    next_operation_nonce: u64,
    next_global_input_sequence: u64,
    input_lease: Option<ActiveLease>,
    geometry_lease: Option<ActiveLease>,
    input_group: Option<ActiveInputGroup>,
    delegations: BTreeMap<Uuid, ActiveDelegation>,
    receipts: BTreeMap<Uuid, StoredReceipt>,
    receipt_order: VecDeque<Uuid>,
}

impl Default for TerminalAuthorityState {
    fn default() -> Self {
        Self {
            mode: TerminalControlMode::LegacyShared,
            next_input_lease_generation: 1,
            next_geometry_lease_generation: 1,
            input_revocation_sequence: 0,
            geometry_revocation_sequence: 0,
            next_delegation_generation: 1,
            next_operation_nonce: 1,
            next_global_input_sequence: 1,
            input_lease: None,
            geometry_lease: None,
            input_group: None,
            delegations: BTreeMap::new(),
            receipts: BTreeMap::new(),
            receipt_order: VecDeque::new(),
        }
    }
}

#[derive(Default)]
struct AuthorityState {
    terminals: BTreeMap<SurfaceUuid, TerminalAuthorityState>,
    visible_presentations: BTreeMap<PresentationId, VisiblePresentation>,
}

pub(crate) struct TerminalAuthorityRegistry {
    clock: Arc<dyn AuthorityClock>,
    state: Mutex<AuthorityState>,
}

impl TerminalAuthorityRegistry {
    pub(crate) fn new() -> Self {
        Self::new_with_clock(Arc::new(MonotonicAuthorityClock::new()))
    }

    pub(crate) fn new_with_clock(clock: Arc<dyn AuthorityClock>) -> Self {
        Self { clock, state: Mutex::new(AuthorityState::default()) }
    }

    pub(crate) fn mode(&self, surface_uuid: SurfaceUuid) -> TerminalControlMode {
        self.state
            .lock()
            .unwrap()
            .terminals
            .get(&surface_uuid)
            .map_or(TerminalControlMode::LegacyShared, |terminal| terminal.mode)
    }

    pub(crate) fn require_legacy(
        &self,
        surface_uuid: SurfaceUuid,
    ) -> Result<(), TerminalAuthorityError> {
        if self.mode(surface_uuid) == TerminalControlMode::Leased {
            return Err(TerminalAuthorityError::TerminalMigratedToLeasedControl);
        }
        Ok(())
    }

    pub(crate) fn mark_presentation_visible(
        &self,
        authority: PresentationAuthority,
    ) -> Result<(), TerminalAuthorityError> {
        let mut state = self.state.lock().unwrap();
        if let Some(current) = state.visible_presentations.get(&authority.presentation_id)
            && current.connection != authority.connection
        {
            return Err(TerminalAuthorityError::PresentationOwnedByAnotherConnection);
        }
        state.visible_presentations.insert(
            authority.presentation_id,
            VisiblePresentation {
                connection: authority.connection,
                generation: authority.presentation_generation,
                surface_uuid: authority.surface_uuid,
            },
        );
        Ok(())
    }

    pub(crate) fn hide_presentation(&self, connection: u64, presentation_id: PresentationId) {
        let mut state = self.state.lock().unwrap();
        if state
            .visible_presentations
            .get(&presentation_id)
            .is_some_and(|presentation| presentation.connection == connection)
        {
            state.visible_presentations.remove(&presentation_id);
        }
        Self::revoke_matching_leases(&mut state, |lease| {
            lease.holder.connection == connection && lease.holder.presentation_id == presentation_id
        });
    }

    pub(crate) fn revoke_presentation(&self, presentation_id: PresentationId) {
        let mut state = self.state.lock().unwrap();
        state.visible_presentations.remove(&presentation_id);
        Self::revoke_matching_leases(&mut state, |lease| {
            lease.holder.presentation_id == presentation_id
        });
    }

    pub(crate) fn revoke_connection(&self, connection: u64) {
        let mut state = self.state.lock().unwrap();
        state.visible_presentations.retain(|_, presentation| presentation.connection != connection);
        Self::revoke_matching_leases(&mut state, |lease| lease.holder.connection == connection);
        for terminal in state.terminals.values_mut() {
            terminal
                .delegations
                .retain(|_, delegation| delegation.delegate.connection != connection);
            if terminal.input_group.is_some_and(|group| {
                terminal
                    .delegations
                    .get(&match group.authorization {
                        InputAuthorization::Delegation { delegation_id } => delegation_id,
                        InputAuthorization::Lease { .. } => return false,
                    })
                    .is_none()
            }) {
                terminal.input_group = None;
            }
        }
    }

    pub(crate) fn retire_terminal(&self, surface_uuid: SurfaceUuid) {
        let mut state = self.state.lock().unwrap();
        state.terminals.remove(&surface_uuid);
        state
            .visible_presentations
            .retain(|_, presentation| presentation.surface_uuid != surface_uuid);
    }

    pub(crate) fn acquire(
        &self,
        surface_uuid: SurfaceUuid,
        kind: TerminalLeaseKind,
        claim: TerminalLeaseClaim,
        ttl_ms: u64,
    ) -> Result<TerminalLease, TerminalAuthorityError> {
        let now_ms = self.clock.now_ms();
        let ttl_ms = ttl_ms.clamp(1, MAX_TERMINAL_LEASE_TTL_MS);
        let mut state = self.state.lock().unwrap();
        Self::validate_visible_claim(&state, surface_uuid, claim)?;
        let terminal = state.terminals.entry(surface_uuid).or_default();
        Self::expire(terminal, now_ms);
        let migrated_from_legacy = terminal.mode == TerminalControlMode::LegacyShared;
        terminal.mode = TerminalControlMode::Leased;

        if let Some(lease) = Self::lease_mut(terminal, kind) {
            if lease.holder == claim {
                lease.ttl_ms = ttl_ms;
                lease.expires_at_ms = now_ms.saturating_add(ttl_ms);
                return Ok(Self::lease_response(surface_uuid, kind, terminal, false));
            }
            return Err(TerminalAuthorityError::LeaseHeldByAnotherPresentation {
                kind,
                expires_at_ms: lease.expires_at_ms,
            });
        }

        let generation = match kind {
            TerminalLeaseKind::Input => {
                let value = terminal.next_input_lease_generation;
                terminal.next_input_lease_generation = value.saturating_add(1).max(1);
                value
            }
            TerminalLeaseKind::Geometry => {
                let value = terminal.next_geometry_lease_generation;
                terminal.next_geometry_lease_generation = value.saturating_add(1).max(1);
                value
            }
        };
        *Self::lease_slot_mut(terminal, kind) = Some(ActiveLease {
            lease_id: Uuid::new_v4(),
            generation,
            holder: claim,
            expires_at_ms: now_ms.saturating_add(ttl_ms),
            ttl_ms,
            next_client_sequence: 1,
            in_flight: None,
        });
        Ok(Self::lease_response(surface_uuid, kind, terminal, migrated_from_legacy))
    }

    pub(crate) fn renew(
        &self,
        surface_uuid: SurfaceUuid,
        kind: TerminalLeaseKind,
        reference: TerminalLeaseReference,
        ttl_ms: u64,
    ) -> Result<TerminalLease, TerminalAuthorityError> {
        let now_ms = self.clock.now_ms();
        let ttl_ms = ttl_ms.clamp(1, MAX_TERMINAL_LEASE_TTL_MS);
        let mut state = self.state.lock().unwrap();
        let terminal = state
            .terminals
            .get_mut(&surface_uuid)
            .ok_or(TerminalAuthorityError::LeaseMissing(kind))?;
        if Self::expire_kind(terminal, kind, now_ms) {
            return Err(TerminalAuthorityError::LeaseExpired(kind));
        }
        Self::validate_lease(terminal, kind, reference)?;
        let lease = Self::lease_mut(terminal, kind).expect("validated lease exists");
        lease.ttl_ms = ttl_ms;
        lease.expires_at_ms = now_ms.saturating_add(ttl_ms);
        Ok(Self::lease_response(surface_uuid, kind, terminal, false))
    }

    pub(crate) fn release(
        &self,
        surface_uuid: SurfaceUuid,
        kind: TerminalLeaseKind,
        reference: TerminalLeaseReference,
    ) -> Result<(), TerminalAuthorityError> {
        let now_ms = self.clock.now_ms();
        let mut state = self.state.lock().unwrap();
        let terminal = state
            .terminals
            .get_mut(&surface_uuid)
            .ok_or(TerminalAuthorityError::LeaseMissing(kind))?;
        if Self::expire_kind(terminal, kind, now_ms) {
            return Err(TerminalAuthorityError::LeaseExpired(kind));
        }
        Self::validate_lease(terminal, kind, reference)?;
        if kind == TerminalLeaseKind::Input && terminal.input_group.is_some() {
            return Err(TerminalAuthorityError::LeaseBusy(kind));
        }
        Self::revoke_kind(terminal, kind);
        Ok(())
    }

    pub(crate) fn transfer(
        &self,
        surface_uuid: SurfaceUuid,
        kind: TerminalLeaseKind,
        reference: TerminalLeaseReference,
        target: TerminalLeaseClaim,
        ttl_ms: u64,
    ) -> Result<TerminalLease, TerminalAuthorityError> {
        let now_ms = self.clock.now_ms();
        let ttl_ms = ttl_ms.clamp(1, MAX_TERMINAL_LEASE_TTL_MS);
        let mut state = self.state.lock().unwrap();
        Self::validate_visible_claim(&state, surface_uuid, target)?;
        let terminal = state
            .terminals
            .get_mut(&surface_uuid)
            .ok_or(TerminalAuthorityError::LeaseMissing(kind))?;
        if Self::expire_kind(terminal, kind, now_ms) {
            return Err(TerminalAuthorityError::LeaseExpired(kind));
        }
        Self::validate_lease(terminal, kind, reference)?;
        if kind == TerminalLeaseKind::Input && terminal.input_group.is_some() {
            return Err(TerminalAuthorityError::LeaseBusy(kind));
        }
        if Self::lease(terminal, kind).is_some_and(|lease| lease.in_flight.is_some()) {
            return Err(TerminalAuthorityError::OperationInFlight(kind.into()));
        }
        Self::revoke_kind(terminal, kind);
        let generation = match kind {
            TerminalLeaseKind::Input => {
                let value = terminal.next_input_lease_generation;
                terminal.next_input_lease_generation = value.saturating_add(1).max(1);
                value
            }
            TerminalLeaseKind::Geometry => {
                let value = terminal.next_geometry_lease_generation;
                terminal.next_geometry_lease_generation = value.saturating_add(1).max(1);
                value
            }
        };
        *Self::lease_slot_mut(terminal, kind) = Some(ActiveLease {
            lease_id: Uuid::new_v4(),
            generation,
            holder: target,
            expires_at_ms: now_ms.saturating_add(ttl_ms),
            ttl_ms,
            next_client_sequence: 1,
            in_flight: None,
        });
        Ok(Self::lease_response(surface_uuid, kind, terminal, false))
    }

    pub(crate) fn grant_input_delegation(
        &self,
        surface_uuid: SurfaceUuid,
        owner: TerminalLeaseReference,
        delegate: TerminalConnectionClaim,
        ttl_ms: u64,
        scopes: BTreeSet<AutomationInputScope>,
    ) -> Result<TerminalInputDelegation, TerminalAuthorityError> {
        let now_ms = self.clock.now_ms();
        let ttl_ms = ttl_ms.clamp(1, MAX_AUTOMATION_DELEGATION_TTL_MS);
        let mut state = self.state.lock().unwrap();
        let terminal = state
            .terminals
            .get_mut(&surface_uuid)
            .ok_or(TerminalAuthorityError::LeaseMissing(TerminalLeaseKind::Input))?;
        Self::expire(terminal, now_ms);
        Self::validate_lease(terminal, TerminalLeaseKind::Input, owner)?;
        if scopes.is_empty() {
            return Err(TerminalAuthorityError::DelegationScopeDenied);
        }
        if terminal.delegations.len() >= MAX_DELEGATIONS_PER_TERMINAL {
            return Err(TerminalAuthorityError::DelegationLimitReached);
        }
        let input = terminal.input_lease.as_ref().expect("validated input lease exists");
        let generation = terminal.next_delegation_generation;
        terminal.next_delegation_generation = generation.saturating_add(1).max(1);
        let delegation = ActiveDelegation {
            delegation_id: Uuid::new_v4(),
            generation,
            owner_lease_generation: input.generation,
            delegate,
            expires_at_ms: now_ms.saturating_add(ttl_ms).min(input.expires_at_ms),
            scopes,
            next_client_sequence: 1,
        };
        let response = Self::delegation_response(surface_uuid, &delegation);
        terminal.delegations.insert(delegation.delegation_id, delegation);
        Ok(response)
    }

    pub(crate) fn revoke_input_delegation(
        &self,
        surface_uuid: SurfaceUuid,
        owner: TerminalLeaseReference,
        delegation_id: Uuid,
        delegation_generation: u64,
    ) -> Result<(), TerminalAuthorityError> {
        let now_ms = self.clock.now_ms();
        let mut state = self.state.lock().unwrap();
        let terminal = state
            .terminals
            .get_mut(&surface_uuid)
            .ok_or(TerminalAuthorityError::LeaseMissing(TerminalLeaseKind::Input))?;
        Self::expire(terminal, now_ms);
        Self::validate_lease(terminal, TerminalLeaseKind::Input, owner)?;
        let delegation = terminal
            .delegations
            .get(&delegation_id)
            .ok_or(TerminalAuthorityError::DelegationMissing)?;
        if delegation.generation != delegation_generation {
            return Err(TerminalAuthorityError::DelegationMismatch);
        }
        if terminal.input_group.is_some_and(|group| {
            group.authorization == InputAuthorization::Delegation { delegation_id }
        }) {
            return Err(TerminalAuthorityError::InputGroupInProgress);
        }
        terminal.delegations.remove(&delegation_id);
        Ok(())
    }

    #[cfg(test)]
    pub(crate) fn begin_input(
        &self,
        surface_uuid: SurfaceUuid,
        reference: TerminalLeaseReference,
        sequence: u64,
        request_id: Uuid,
        fingerprint: RequestFingerprint,
        group: Option<TerminalInputGroup>,
    ) -> Result<BeginTerminalOperation, TerminalAuthorityError> {
        self.begin_input_authorized(
            surface_uuid,
            TerminalInputAuthority::Lease(reference),
            AutomationInputScope::Text,
            sequence,
            request_id,
            fingerprint,
            group,
        )
    }

    pub(crate) fn begin_input_with_scope(
        &self,
        surface_uuid: SurfaceUuid,
        reference: TerminalLeaseReference,
        scope: AutomationInputScope,
        sequence: u64,
        request_id: Uuid,
        fingerprint: RequestFingerprint,
        group: Option<TerminalInputGroup>,
    ) -> Result<BeginTerminalOperation, TerminalAuthorityError> {
        self.begin_input_authorized(
            surface_uuid,
            TerminalInputAuthority::Lease(reference),
            scope,
            sequence,
            request_id,
            fingerprint,
            group,
        )
    }

    pub(crate) fn begin_delegated_input(
        &self,
        surface_uuid: SurfaceUuid,
        reference: TerminalDelegationReference,
        scope: AutomationInputScope,
        sequence: u64,
        request_id: Uuid,
        fingerprint: RequestFingerprint,
        group: Option<TerminalInputGroup>,
    ) -> Result<BeginTerminalOperation, TerminalAuthorityError> {
        self.begin_input_authorized(
            surface_uuid,
            TerminalInputAuthority::Delegation(reference),
            scope,
            sequence,
            request_id,
            fingerprint,
            group,
        )
    }

    pub(crate) fn begin_geometry(
        &self,
        surface_uuid: SurfaceUuid,
        reference: TerminalLeaseReference,
        sequence: u64,
        request_id: Uuid,
        fingerprint: RequestFingerprint,
    ) -> Result<BeginTerminalOperation, TerminalAuthorityError> {
        let now_ms = self.clock.now_ms();
        let mut state = self.state.lock().unwrap();
        let terminal = state
            .terminals
            .get_mut(&surface_uuid)
            .ok_or(TerminalAuthorityError::LeaseMissing(TerminalLeaseKind::Geometry))?;
        if let Some(replay) =
            Self::replay(terminal, reference.client_uuid, request_id, fingerprint)?
        {
            return Ok(BeginTerminalOperation::Replay(replay));
        }
        Self::require_receipt_capacity(terminal)?;
        if Self::expire_kind(terminal, TerminalLeaseKind::Geometry, now_ms) {
            return Err(TerminalAuthorityError::LeaseExpired(TerminalLeaseKind::Geometry));
        }
        Self::validate_lease(terminal, TerminalLeaseKind::Geometry, reference)?;
        let lease = terminal.geometry_lease.as_ref().expect("validated geometry lease exists");
        if lease.in_flight.is_some() {
            return Err(TerminalAuthorityError::OperationInFlight(TerminalOperationKind::Geometry));
        }
        if sequence != lease.next_client_sequence {
            return Err(TerminalAuthorityError::GeometrySequenceGap {
                expected: lease.next_client_sequence,
                received: sequence,
            });
        }
        let permit = Self::install_operation(
            terminal,
            surface_uuid,
            TerminalOperationKind::Geometry,
            reference.lease_id,
            reference.lease_generation,
            sequence,
            None,
            request_id,
            reference.client_uuid,
            fingerprint,
            None,
            None,
        );
        Ok(BeginTerminalOperation::Execute(permit))
    }

    pub(crate) fn abort_operation(
        &self,
        permit: TerminalOperationPermit,
    ) -> Result<(), TerminalAuthorityError> {
        let mut state = self.state.lock().unwrap();
        let terminal = state
            .terminals
            .get_mut(&permit.surface_uuid)
            .ok_or(TerminalAuthorityError::OperationPermitInvalid)?;
        let lease = Self::operation_lease_mut(terminal, permit.kind)
            .ok_or(TerminalAuthorityError::OperationPermitInvalid)?;
        let in_flight =
            lease.in_flight.as_ref().ok_or(TerminalAuthorityError::OperationPermitInvalid)?;
        if !Self::permit_matches(&permit, lease, in_flight) {
            return Err(TerminalAuthorityError::OperationPermitInvalid);
        }
        lease.in_flight = None;
        if permit.kind == TerminalOperationKind::Input {
            terminal.input_group = permit.previous_input_group;
        }
        Ok(())
    }

    pub(crate) fn complete_operation(
        &self,
        permit: TerminalOperationPermit,
        outcome: TerminalOperationOutcome,
    ) -> Result<TerminalOperationReceipt, TerminalAuthorityError> {
        if !Self::outcome_matches(permit.kind, &outcome) {
            return Err(TerminalAuthorityError::OperationOutcomeMismatch);
        }
        let now_ms = self.clock.now_ms();
        let mut state = self.state.lock().unwrap();
        let terminal = state
            .terminals
            .get_mut(&permit.surface_uuid)
            .ok_or(TerminalAuthorityError::OperationPermitInvalid)?;
        let lease = Self::operation_lease_mut(terminal, permit.kind)
            .ok_or(TerminalAuthorityError::OperationPermitInvalid)?;
        let in_flight =
            lease.in_flight.as_ref().ok_or(TerminalAuthorityError::OperationPermitInvalid)?;
        if !Self::permit_matches(&permit, lease, in_flight) {
            return Err(TerminalAuthorityError::OperationPermitInvalid);
        }

        let indeterminate = matches!(outcome, TerminalOperationOutcome::InputIndeterminate { .. });
        let receipt = TerminalOperationReceipt {
            request_id: permit.request_id,
            kind: permit.kind,
            sequence: permit.sequence,
            ordered_input_sequence: permit.ordered_input_sequence,
            lease_generation: permit.lease_generation,
            outcome,
            replayed: false,
        };
        lease.in_flight = None;
        lease.expires_at_ms = now_ms.saturating_add(lease.ttl_ms);
        match permit.kind {
            TerminalOperationKind::Geometry => {
                lease.next_client_sequence = lease.next_client_sequence.saturating_add(1).max(1);
            }
            TerminalOperationKind::Input => {
                match permit.input_authorization.expect("input permit has authority") {
                    InputAuthorization::Lease { .. } => {
                        lease.next_client_sequence =
                            lease.next_client_sequence.saturating_add(1).max(1);
                    }
                    InputAuthorization::Delegation { delegation_id } => {
                        let delegation = terminal
                            .delegations
                            .get_mut(&delegation_id)
                            .ok_or(TerminalAuthorityError::OperationPermitInvalid)?;
                        delegation.next_client_sequence =
                            delegation.next_client_sequence.saturating_add(1).max(1);
                    }
                }
                terminal.next_global_input_sequence =
                    terminal.next_global_input_sequence.saturating_add(1).max(1);
            }
        }
        Self::store_receipt(
            terminal,
            StoredReceipt {
                client_uuid: permit.client_uuid,
                fingerprint: permit.fingerprint,
                receipt: receipt.clone(),
            },
        );
        if indeterminate {
            Self::revoke_kind(terminal, TerminalLeaseKind::Input);
        }
        Ok(receipt)
    }

    pub(crate) fn receipt(
        &self,
        surface_uuid: SurfaceUuid,
        client_uuid: Uuid,
        request_id: Uuid,
    ) -> Option<TerminalOperationReceipt> {
        self.state
            .lock()
            .unwrap()
            .terminals
            .get(&surface_uuid)?
            .receipts
            .get(&request_id)
            .filter(|stored| stored.client_uuid == client_uuid)
            .map(|stored| {
                let mut receipt = stored.receipt.clone();
                receipt.replayed = true;
                receipt
            })
    }

    /// Removes one definitively observed receipt. Unknown acknowledgements are
    /// idempotent; a UUID owned by another logical client is a conflict.
    pub(crate) fn acknowledge_receipt(
        &self,
        surface_uuid: SurfaceUuid,
        client_uuid: Uuid,
        request_id: Uuid,
    ) -> Result<bool, TerminalAuthorityError> {
        let mut state = self.state.lock().unwrap();
        let Some(terminal) = state.terminals.get_mut(&surface_uuid) else {
            return Ok(false);
        };
        let Some(stored) = terminal.receipts.get(&request_id) else {
            return Ok(false);
        };
        if stored.client_uuid != client_uuid {
            return Err(TerminalAuthorityError::RequestConflict);
        }
        terminal.receipts.remove(&request_id);
        terminal.receipt_order.retain(|candidate| *candidate != request_id);
        Ok(true)
    }

    fn begin_input_authorized(
        &self,
        surface_uuid: SurfaceUuid,
        authority: TerminalInputAuthority,
        scope: AutomationInputScope,
        sequence: u64,
        request_id: Uuid,
        fingerprint: RequestFingerprint,
        group: Option<TerminalInputGroup>,
    ) -> Result<BeginTerminalOperation, TerminalAuthorityError> {
        let now_ms = self.clock.now_ms();
        let mut state = self.state.lock().unwrap();
        let terminal = state
            .terminals
            .get_mut(&surface_uuid)
            .ok_or(TerminalAuthorityError::LeaseMissing(TerminalLeaseKind::Input))?;
        let caller_uuid = authority.client_uuid();
        if let Some(replay) = Self::replay(terminal, caller_uuid, request_id, fingerprint)? {
            return Ok(BeginTerminalOperation::Replay(replay));
        }
        Self::require_receipt_capacity(terminal)?;
        if Self::expire_kind(terminal, TerminalLeaseKind::Input, now_ms) {
            return Err(TerminalAuthorityError::LeaseExpired(TerminalLeaseKind::Input));
        }

        let (authorization, lease_id, lease_generation, expected_sequence) = match authority {
            TerminalInputAuthority::Lease(reference) => {
                Self::validate_lease(terminal, TerminalLeaseKind::Input, reference)?;
                let lease = terminal.input_lease.as_ref().expect("validated input lease exists");
                (
                    InputAuthorization::Lease { lease_id: lease.lease_id },
                    lease.lease_id,
                    lease.generation,
                    lease.next_client_sequence,
                )
            }
            TerminalInputAuthority::Delegation(reference) => {
                Self::expire_delegations(terminal, now_ms);
                let delegation = terminal
                    .delegations
                    .get(&reference.delegation_id)
                    .ok_or(TerminalAuthorityError::DelegationMissing)?;
                if delegation.generation != reference.delegation_generation
                    || delegation.delegate.connection != reference.connection
                    || delegation.delegate.client_uuid != reference.client_uuid
                    || delegation.delegate.process_instance_uuid != reference.process_instance_uuid
                {
                    return Err(TerminalAuthorityError::DelegationMismatch);
                }
                if delegation.expires_at_ms <= now_ms {
                    return Err(TerminalAuthorityError::DelegationExpired);
                }
                if !delegation.scopes.contains(&scope) {
                    return Err(TerminalAuthorityError::DelegationScopeDenied);
                }
                let lease =
                    terminal.input_lease.as_ref().expect("input lease exists for delegation");
                if lease.generation != delegation.owner_lease_generation {
                    return Err(TerminalAuthorityError::DelegationMismatch);
                }
                (
                    InputAuthorization::Delegation { delegation_id: delegation.delegation_id },
                    lease.lease_id,
                    lease.generation,
                    delegation.next_client_sequence,
                )
            }
        };
        if terminal.input_lease.as_ref().is_some_and(|lease| lease.in_flight.is_some()) {
            return Err(TerminalAuthorityError::OperationInFlight(TerminalOperationKind::Input));
        }
        if sequence != expected_sequence {
            return Err(TerminalAuthorityError::InputSequenceGap {
                expected: expected_sequence,
                received: sequence,
            });
        }

        let previous_input_group = terminal.input_group;
        terminal.input_group =
            Self::next_input_group(terminal.input_group, group, caller_uuid, authorization)?;
        let ordered = terminal.next_global_input_sequence;
        let permit = Self::install_operation(
            terminal,
            surface_uuid,
            TerminalOperationKind::Input,
            lease_id,
            lease_generation,
            sequence,
            Some(ordered),
            request_id,
            caller_uuid,
            fingerprint,
            Some(authorization),
            previous_input_group,
        );
        Ok(BeginTerminalOperation::Execute(permit))
    }

    fn validate_visible_claim(
        state: &AuthorityState,
        surface_uuid: SurfaceUuid,
        claim: TerminalLeaseClaim,
    ) -> Result<(), TerminalAuthorityError> {
        let visible = state
            .visible_presentations
            .get(&claim.presentation_id)
            .copied()
            .ok_or(TerminalAuthorityError::PresentationNotVisible)?;
        if visible.connection != claim.connection {
            return Err(TerminalAuthorityError::PresentationOwnedByAnotherConnection);
        }
        if visible.generation != claim.presentation_generation {
            return Err(TerminalAuthorityError::PresentationGenerationMismatch);
        }
        if visible.surface_uuid != surface_uuid {
            return Err(TerminalAuthorityError::PresentationSurfaceMismatch);
        }
        Ok(())
    }

    fn next_input_group(
        active: Option<ActiveInputGroup>,
        requested: Option<TerminalInputGroup>,
        client_uuid: Uuid,
        authorization: InputAuthorization,
    ) -> Result<Option<ActiveInputGroup>, TerminalAuthorityError> {
        match (active, requested) {
            (None, None) => Ok(None),
            (Some(_), None) => Err(TerminalAuthorityError::InputGroupInProgress),
            (_, Some(group)) if group.id.is_nil() => {
                Err(TerminalAuthorityError::InputGroupIdentifierInvalid)
            }
            (None, Some(group)) => {
                if group.index != 0 {
                    return Err(TerminalAuthorityError::InputGroupIndexGap {
                        expected: 0,
                        received: group.index,
                    });
                }
                if group.end {
                    Ok(None)
                } else {
                    Ok(Some(ActiveInputGroup {
                        id: group.id,
                        client_uuid,
                        authorization,
                        next_index: 1,
                    }))
                }
            }
            (Some(active), Some(group)) => {
                if active.id != group.id
                    || active.client_uuid != client_uuid
                    || active.authorization != authorization
                {
                    return Err(TerminalAuthorityError::InputGroupMismatch);
                }
                if active.next_index != group.index {
                    return Err(TerminalAuthorityError::InputGroupIndexGap {
                        expected: active.next_index,
                        received: group.index,
                    });
                }
                if group.end {
                    Ok(None)
                } else {
                    Ok(Some(ActiveInputGroup {
                        next_index: active.next_index.saturating_add(1),
                        ..active
                    }))
                }
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn install_operation(
        terminal: &mut TerminalAuthorityState,
        surface_uuid: SurfaceUuid,
        kind: TerminalOperationKind,
        lease_id: Uuid,
        lease_generation: u64,
        sequence: u64,
        ordered_input_sequence: Option<u64>,
        request_id: Uuid,
        client_uuid: Uuid,
        fingerprint: RequestFingerprint,
        input_authorization: Option<InputAuthorization>,
        previous_input_group: Option<ActiveInputGroup>,
    ) -> TerminalOperationPermit {
        let nonce = terminal.next_operation_nonce;
        terminal.next_operation_nonce = nonce.saturating_add(1).max(1);
        let in_flight = InFlightOperation {
            nonce,
            kind,
            sequence,
            ordered_input_sequence,
            request_id,
            client_uuid,
            fingerprint,
            input_authorization,
        };
        Self::operation_lease_mut(terminal, kind).expect("operation lease exists").in_flight =
            Some(in_flight);
        TerminalOperationPermit {
            surface_uuid,
            lease_id,
            lease_generation,
            operation_nonce: nonce,
            kind,
            sequence,
            ordered_input_sequence,
            request_id,
            client_uuid,
            fingerprint,
            input_authorization,
            previous_input_group,
        }
    }

    fn replay(
        terminal: &TerminalAuthorityState,
        client_uuid: Uuid,
        request_id: Uuid,
        fingerprint: RequestFingerprint,
    ) -> Result<Option<TerminalOperationReceipt>, TerminalAuthorityError> {
        let Some(stored) = terminal.receipts.get(&request_id) else { return Ok(None) };
        if stored.client_uuid != client_uuid || stored.fingerprint != fingerprint {
            return Err(TerminalAuthorityError::RequestConflict);
        }
        let mut receipt = stored.receipt.clone();
        receipt.replayed = true;
        Ok(Some(receipt))
    }

    fn require_receipt_capacity(
        terminal: &TerminalAuthorityState,
    ) -> Result<(), TerminalAuthorityError> {
        let in_flight = usize::from(
            terminal.input_lease.as_ref().is_some_and(|lease| lease.in_flight.is_some()),
        ) + usize::from(
            terminal.geometry_lease.as_ref().is_some_and(|lease| lease.in_flight.is_some()),
        );
        if terminal.receipts.len().saturating_add(in_flight)
            >= MAX_UNACKNOWLEDGED_RECEIPTS_PER_TERMINAL
        {
            return Err(TerminalAuthorityError::ReceiptCapacityReached);
        }
        Ok(())
    }

    fn validate_lease(
        terminal: &TerminalAuthorityState,
        kind: TerminalLeaseKind,
        reference: TerminalLeaseReference,
    ) -> Result<(), TerminalAuthorityError> {
        let lease =
            Self::lease(terminal, kind).ok_or(TerminalAuthorityError::LeaseMissing(kind))?;
        if lease.lease_id != reference.lease_id
            || lease.holder.connection != reference.connection
            || lease.holder.client_uuid != reference.client_uuid
            || lease.holder.process_instance_uuid != reference.process_instance_uuid
            || lease.holder.presentation_id != reference.presentation_id
            || lease.holder.presentation_generation != reference.presentation_generation
        {
            return Err(TerminalAuthorityError::LeaseMismatch(kind));
        }
        if lease.generation != reference.lease_generation {
            return Err(TerminalAuthorityError::LeaseGenerationMismatch(kind));
        }
        Ok(())
    }

    fn lease(terminal: &TerminalAuthorityState, kind: TerminalLeaseKind) -> Option<&ActiveLease> {
        match kind {
            TerminalLeaseKind::Input => terminal.input_lease.as_ref(),
            TerminalLeaseKind::Geometry => terminal.geometry_lease.as_ref(),
        }
    }

    fn lease_mut(
        terminal: &mut TerminalAuthorityState,
        kind: TerminalLeaseKind,
    ) -> Option<&mut ActiveLease> {
        match kind {
            TerminalLeaseKind::Input => terminal.input_lease.as_mut(),
            TerminalLeaseKind::Geometry => terminal.geometry_lease.as_mut(),
        }
    }

    fn lease_slot_mut(
        terminal: &mut TerminalAuthorityState,
        kind: TerminalLeaseKind,
    ) -> &mut Option<ActiveLease> {
        match kind {
            TerminalLeaseKind::Input => &mut terminal.input_lease,
            TerminalLeaseKind::Geometry => &mut terminal.geometry_lease,
        }
    }

    fn operation_lease_mut(
        terminal: &mut TerminalAuthorityState,
        kind: TerminalOperationKind,
    ) -> Option<&mut ActiveLease> {
        match kind {
            TerminalOperationKind::Input => terminal.input_lease.as_mut(),
            TerminalOperationKind::Geometry => terminal.geometry_lease.as_mut(),
        }
    }

    fn expire(terminal: &mut TerminalAuthorityState, now_ms: u64) {
        Self::expire_kind(terminal, TerminalLeaseKind::Input, now_ms);
        Self::expire_kind(terminal, TerminalLeaseKind::Geometry, now_ms);
        Self::expire_delegations(terminal, now_ms);
    }

    fn expire_kind(
        terminal: &mut TerminalAuthorityState,
        kind: TerminalLeaseKind,
        now_ms: u64,
    ) -> bool {
        let expired = Self::lease(terminal, kind)
            .is_some_and(|lease| lease.expires_at_ms <= now_ms && lease.in_flight.is_none());
        if expired {
            Self::revoke_kind(terminal, kind);
        }
        expired
    }

    fn expire_delegations(terminal: &mut TerminalAuthorityState, now_ms: u64) {
        terminal.delegations.retain(|_, delegation| delegation.expires_at_ms > now_ms);
        if terminal.input_group.is_some_and(|group| {
            matches!(group.authorization, InputAuthorization::Delegation { delegation_id }
                if !terminal.delegations.contains_key(&delegation_id))
        }) {
            terminal.input_group = None;
        }
    }

    fn revoke_kind(terminal: &mut TerminalAuthorityState, kind: TerminalLeaseKind) {
        match kind {
            TerminalLeaseKind::Input => {
                if terminal.input_lease.take().is_some() {
                    terminal.input_revocation_sequence =
                        terminal.input_revocation_sequence.saturating_add(1);
                }
                terminal.delegations.clear();
                terminal.input_group = None;
            }
            TerminalLeaseKind::Geometry => {
                if terminal.geometry_lease.take().is_some() {
                    terminal.geometry_revocation_sequence =
                        terminal.geometry_revocation_sequence.saturating_add(1);
                }
            }
        }
    }

    fn revoke_matching_leases(state: &mut AuthorityState, matches: impl Fn(&ActiveLease) -> bool) {
        for terminal in state.terminals.values_mut() {
            if terminal.input_lease.as_ref().is_some_and(&matches) {
                Self::revoke_kind(terminal, TerminalLeaseKind::Input);
            }
            if terminal.geometry_lease.as_ref().is_some_and(&matches) {
                Self::revoke_kind(terminal, TerminalLeaseKind::Geometry);
            }
        }
    }

    fn lease_response(
        surface_uuid: SurfaceUuid,
        kind: TerminalLeaseKind,
        terminal: &TerminalAuthorityState,
        migrated_from_legacy: bool,
    ) -> TerminalLease {
        let lease = Self::lease(terminal, kind).expect("lease response requires active lease");
        TerminalLease {
            kind,
            surface_uuid,
            lease_id: lease.lease_id,
            lease_generation: lease.generation,
            revocation_sequence: match kind {
                TerminalLeaseKind::Input => terminal.input_revocation_sequence,
                TerminalLeaseKind::Geometry => terminal.geometry_revocation_sequence,
            },
            expires_at_ms: lease.expires_at_ms,
            next_client_sequence: lease.next_client_sequence,
            next_global_input_sequence: (kind == TerminalLeaseKind::Input)
                .then_some(terminal.next_global_input_sequence),
            migrated_from_legacy,
        }
    }

    fn delegation_response(
        surface_uuid: SurfaceUuid,
        delegation: &ActiveDelegation,
    ) -> TerminalInputDelegation {
        TerminalInputDelegation {
            surface_uuid,
            delegation_id: delegation.delegation_id,
            delegation_generation: delegation.generation,
            owner_lease_generation: delegation.owner_lease_generation,
            delegate: delegation.delegate,
            expires_at_ms: delegation.expires_at_ms,
            scopes: delegation.scopes.clone(),
            next_client_sequence: delegation.next_client_sequence,
        }
    }

    fn permit_matches(
        permit: &TerminalOperationPermit,
        lease: &ActiveLease,
        in_flight: &InFlightOperation,
    ) -> bool {
        permit.lease_id == lease.lease_id
            && permit.lease_generation == lease.generation
            && permit.operation_nonce == in_flight.nonce
            && permit.kind == in_flight.kind
            && permit.sequence == in_flight.sequence
            && permit.ordered_input_sequence == in_flight.ordered_input_sequence
            && permit.request_id == in_flight.request_id
            && permit.client_uuid == in_flight.client_uuid
            && permit.fingerprint == in_flight.fingerprint
            && permit.input_authorization == in_flight.input_authorization
    }

    fn outcome_matches(kind: TerminalOperationKind, outcome: &TerminalOperationOutcome) -> bool {
        matches!(
            (kind, outcome),
            (TerminalOperationKind::Input, TerminalOperationOutcome::InputApplied { .. })
                | (
                    TerminalOperationKind::Input,
                    TerminalOperationOutcome::InputIndeterminate { .. }
                )
                | (
                    TerminalOperationKind::Geometry,
                    TerminalOperationOutcome::GeometryApplied { .. }
                )
        )
    }

    fn store_receipt(terminal: &mut TerminalAuthorityState, receipt: StoredReceipt) {
        let request_id = receipt.receipt.request_id;
        if terminal.receipts.insert(request_id, receipt).is_none() {
            terminal.receipt_order.push_back(request_id);
        }
        debug_assert!(
            terminal.receipt_order.len() <= MAX_UNACKNOWLEDGED_RECEIPTS_PER_TERMINAL,
            "operation began only after reserving receipt capacity"
        );
    }
}

#[derive(Clone, Copy)]
enum TerminalInputAuthority {
    Lease(TerminalLeaseReference),
    Delegation(TerminalDelegationReference),
}

impl TerminalInputAuthority {
    fn client_uuid(self) -> Uuid {
        match self {
            Self::Lease(reference) => reference.client_uuid,
            Self::Delegation(reference) => reference.client_uuid,
        }
    }
}

impl From<TerminalLeaseKind> for TerminalOperationKind {
    fn from(value: TerminalLeaseKind) -> Self {
        match value {
            TerminalLeaseKind::Input => Self::Input,
            TerminalLeaseKind::Geometry => Self::Geometry,
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicU64, Ordering};

    use super::*;

    struct ManualClock(AtomicU64);

    impl ManualClock {
        fn new(now_ms: u64) -> Self {
            Self(AtomicU64::new(now_ms))
        }

        fn set(&self, now_ms: u64) {
            self.0.store(now_ms, Ordering::Release);
        }
    }

    impl AuthorityClock for ManualClock {
        fn now_ms(&self) -> u64 {
            self.0.load(Ordering::Acquire)
        }
    }

    fn surface(value: &str) -> SurfaceUuid {
        value.parse().unwrap()
    }

    fn presentation(value: &str) -> PresentationId {
        value.parse().unwrap()
    }

    fn uuid(value: &str) -> Uuid {
        Uuid::parse_str(value).unwrap()
    }

    fn claim(connection: u64, suffix: u8) -> TerminalLeaseClaim {
        TerminalLeaseClaim {
            connection,
            client_uuid: Uuid::from_u128(0x20000000000040008000000000000000 + u128::from(suffix)),
            process_instance_uuid: Uuid::from_u128(
                0x30000000000040008000000000000000 + u128::from(suffix),
            ),
            presentation_id: presentation(&format!("40000000-0000-4000-8000-{suffix:012}")),
            presentation_generation: 3,
        }
    }

    fn fixture() -> (Arc<ManualClock>, TerminalAuthorityRegistry, SurfaceUuid, TerminalLeaseClaim) {
        let clock = Arc::new(ManualClock::new(100));
        let registry = TerminalAuthorityRegistry::new_with_clock(clock.clone());
        let surface = surface("10000000-0000-4000-8000-000000000001");
        let claim = claim(7, 1);
        registry
            .mark_presentation_visible(PresentationAuthority {
                connection: claim.connection,
                presentation_id: claim.presentation_id,
                presentation_generation: claim.presentation_generation,
                surface_uuid: surface,
            })
            .unwrap();
        (clock, registry, surface, claim)
    }

    fn reference(claim: TerminalLeaseClaim, lease: &TerminalLease) -> TerminalLeaseReference {
        TerminalLeaseReference {
            connection: claim.connection,
            client_uuid: claim.client_uuid,
            process_instance_uuid: claim.process_instance_uuid,
            presentation_id: claim.presentation_id,
            presentation_generation: claim.presentation_generation,
            lease_id: lease.lease_id,
            lease_generation: lease.lease_generation,
        }
    }

    fn execute_input(
        registry: &TerminalAuthorityRegistry,
        surface: SurfaceUuid,
        reference: TerminalLeaseReference,
        sequence: u64,
        fingerprint: u8,
        group: Option<TerminalInputGroup>,
    ) -> TerminalOperationReceipt {
        let permit = match registry
            .begin_input_with_scope(
                surface,
                reference,
                AutomationInputScope::Text,
                sequence,
                Uuid::new_v4(),
                RequestFingerprint([fingerprint; 32]),
                group,
            )
            .unwrap()
        {
            BeginTerminalOperation::Execute(permit) => permit,
            BeginTerminalOperation::Replay(_) => panic!("new request unexpectedly replayed"),
        };
        registry
            .complete_operation(permit, TerminalOperationOutcome::InputApplied { encoded_bytes: 1 })
            .unwrap()
    }

    fn execute_delegated_input(
        registry: &TerminalAuthorityRegistry,
        surface: SurfaceUuid,
        reference: TerminalDelegationReference,
        sequence: u64,
        fingerprint: u8,
    ) -> TerminalOperationReceipt {
        let permit = match registry
            .begin_delegated_input(
                surface,
                reference,
                AutomationInputScope::Text,
                sequence,
                Uuid::new_v4(),
                RequestFingerprint([fingerprint; 32]),
                None,
            )
            .unwrap()
        {
            BeginTerminalOperation::Execute(permit) => permit,
            BeginTerminalOperation::Replay(_) => panic!("new request unexpectedly replayed"),
        };
        registry
            .complete_operation(permit, TerminalOperationOutcome::InputApplied { encoded_bytes: 1 })
            .unwrap()
    }

    #[test]
    fn input_and_geometry_leases_are_independent() {
        let (_, registry, surface, gui) = fixture();
        let tui = claim(8, 2);
        registry
            .mark_presentation_visible(PresentationAuthority {
                connection: tui.connection,
                presentation_id: tui.presentation_id,
                presentation_generation: tui.presentation_generation,
                surface_uuid: surface,
            })
            .unwrap();
        let input = registry.acquire(surface, TerminalLeaseKind::Input, gui, 5_000).unwrap();
        let geometry = registry.acquire(surface, TerminalLeaseKind::Geometry, tui, 9_000).unwrap();
        assert!(input.migrated_from_legacy);
        assert!(!geometry.migrated_from_legacy);
        assert_ne!(input.lease_id, geometry.lease_id);
        registry.release(surface, TerminalLeaseKind::Input, reference(gui, &input)).unwrap();
        execute_input(
            &registry,
            surface,
            reference(
                gui,
                &registry.acquire(surface, TerminalLeaseKind::Input, gui, 5_000).unwrap(),
            ),
            1,
            1,
            None,
        );
        registry.release(surface, TerminalLeaseKind::Geometry, reference(tui, &geometry)).unwrap();
    }

    #[test]
    fn expiry_and_disconnect_revoke_each_kind_without_reviving_legacy() {
        let (clock, registry, surface, gui) = fixture();
        let input = registry.acquire(surface, TerminalLeaseKind::Input, gui, 20).unwrap();
        let geometry = registry.acquire(surface, TerminalLeaseKind::Geometry, gui, 40).unwrap();
        clock.set(input.expires_at_ms);
        assert_eq!(
            registry
                .begin_input(
                    surface,
                    reference(gui, &input),
                    1,
                    Uuid::new_v4(),
                    RequestFingerprint([1; 32]),
                    None,
                )
                .unwrap_err(),
            TerminalAuthorityError::LeaseExpired(TerminalLeaseKind::Input)
        );
        registry.revoke_connection(gui.connection);
        assert_eq!(
            registry.release(surface, TerminalLeaseKind::Geometry, reference(gui, &geometry)),
            Err(TerminalAuthorityError::LeaseMissing(TerminalLeaseKind::Geometry))
        );
        assert_eq!(registry.mode(surface), TerminalControlMode::Leased);
    }

    #[test]
    fn global_input_order_survives_transfer_and_deduplicates_retry() {
        let (_, registry, surface, gui) = fixture();
        let tui = claim(8, 2);
        registry
            .mark_presentation_visible(PresentationAuthority {
                connection: tui.connection,
                presentation_id: tui.presentation_id,
                presentation_generation: tui.presentation_generation,
                surface_uuid: surface,
            })
            .unwrap();
        let gui_lease = registry.acquire(surface, TerminalLeaseKind::Input, gui, 5_000).unwrap();
        let first_request = Uuid::new_v4();
        let first_fingerprint = RequestFingerprint([2; 32]);
        let first_permit = match registry
            .begin_input(
                surface,
                reference(gui, &gui_lease),
                1,
                first_request,
                first_fingerprint,
                None,
            )
            .unwrap()
        {
            BeginTerminalOperation::Execute(permit) => permit,
            BeginTerminalOperation::Replay(_) => unreachable!(),
        };
        let first = registry
            .complete_operation(
                first_permit,
                TerminalOperationOutcome::InputApplied { encoded_bytes: 4 },
            )
            .unwrap();
        assert_eq!(first.ordered_input_sequence, Some(1));
        let replay = registry
            .begin_input(
                surface,
                reference(gui, &gui_lease),
                1,
                first_request,
                first_fingerprint,
                None,
            )
            .unwrap();
        assert!(matches!(
            replay,
            BeginTerminalOperation::Replay(TerminalOperationReceipt {
                ordered_input_sequence: Some(1),
                replayed: true,
                ..
            })
        ));
        let tui_lease = registry
            .transfer(surface, TerminalLeaseKind::Input, reference(gui, &gui_lease), tui, 5_000)
            .unwrap();
        let second = execute_input(&registry, surface, reference(tui, &tui_lease), 1, 3, None);
        assert_eq!(second.ordered_input_sequence, Some(2));
    }

    #[test]
    fn unacknowledged_receipts_backpressure_instead_of_eviction() {
        let (_, registry, surface, gui) = fixture();
        let lease = registry.acquire(surface, TerminalLeaseKind::Input, gui, 5_000).unwrap();
        let reference = reference(gui, &lease);
        let mut request_ids = Vec::new();
        for sequence in 1..=MAX_UNACKNOWLEDGED_RECEIPTS_PER_TERMINAL as u64 {
            let request_id = Uuid::new_v4();
            let permit = match registry
                .begin_input(
                    surface,
                    reference,
                    sequence,
                    request_id,
                    RequestFingerprint([u8::try_from(sequence % 251).unwrap(); 32]),
                    None,
                )
                .unwrap()
            {
                BeginTerminalOperation::Execute(permit) => permit,
                BeginTerminalOperation::Replay(_) => unreachable!(),
            };
            registry
                .complete_operation(
                    permit,
                    TerminalOperationOutcome::InputApplied { encoded_bytes: 1 },
                )
                .unwrap();
            request_ids.push(request_id);
        }

        assert_eq!(
            registry
                .begin_input(
                    surface,
                    reference,
                    MAX_UNACKNOWLEDGED_RECEIPTS_PER_TERMINAL as u64 + 1,
                    Uuid::new_v4(),
                    RequestFingerprint([252; 32]),
                    None,
                )
                .unwrap_err(),
            TerminalAuthorityError::ReceiptCapacityReached
        );
        assert!(registry.receipt(surface, gui.client_uuid, request_ids[0]).is_some());
        assert!(registry.acknowledge_receipt(surface, gui.client_uuid, request_ids[0]).unwrap());
        execute_input(
            &registry,
            surface,
            reference,
            MAX_UNACKNOWLEDGED_RECEIPTS_PER_TERMINAL as u64 + 1,
            253,
            None,
        );
        assert!(!registry.acknowledge_receipt(surface, gui.client_uuid, request_ids[0]).unwrap());
    }

    #[test]
    fn three_clients_preserve_group_and_automation_scope() {
        let (_, registry, surface, gui) = fixture();
        let tui = claim(8, 2);
        registry
            .mark_presentation_visible(PresentationAuthority {
                connection: tui.connection,
                presentation_id: tui.presentation_id,
                presentation_generation: tui.presentation_generation,
                surface_uuid: surface,
            })
            .unwrap();
        let automation = TerminalConnectionClaim {
            connection: 9,
            client_uuid: uuid("50000000-0000-4000-8000-000000000003"),
            process_instance_uuid: uuid("60000000-0000-4000-8000-000000000003"),
        };
        let lease = registry.acquire(surface, TerminalLeaseKind::Input, gui, 5_000).unwrap();
        let delegation = registry
            .grant_input_delegation(
                surface,
                reference(gui, &lease),
                automation,
                2_000,
                BTreeSet::from([AutomationInputScope::Text]),
            )
            .unwrap();
        let delegated_reference = TerminalDelegationReference {
            connection: automation.connection,
            client_uuid: automation.client_uuid,
            process_instance_uuid: automation.process_instance_uuid,
            delegation_id: delegation.delegation_id,
            delegation_generation: delegation.delegation_generation,
        };
        let group_id = Uuid::new_v4();
        let first = execute_input(
            &registry,
            surface,
            reference(gui, &lease),
            1,
            4,
            Some(TerminalInputGroup { id: group_id, index: 0, end: false }),
        );
        assert_eq!(first.ordered_input_sequence, Some(1));
        assert_eq!(
            registry
                .begin_delegated_input(
                    surface,
                    delegated_reference,
                    AutomationInputScope::Text,
                    1,
                    Uuid::new_v4(),
                    RequestFingerprint([5; 32]),
                    None,
                )
                .unwrap_err(),
            TerminalAuthorityError::InputGroupInProgress
        );
        let second = execute_input(
            &registry,
            surface,
            reference(gui, &lease),
            2,
            6,
            Some(TerminalInputGroup { id: group_id, index: 1, end: true }),
        );
        assert_eq!(second.ordered_input_sequence, Some(2));
        let automation_permit = match registry
            .begin_delegated_input(
                surface,
                delegated_reference,
                AutomationInputScope::Text,
                1,
                Uuid::new_v4(),
                RequestFingerprint([7; 32]),
                Some(TerminalInputGroup { id: Uuid::new_v4(), index: 0, end: true }),
            )
            .unwrap()
        {
            BeginTerminalOperation::Execute(permit) => permit,
            BeginTerminalOperation::Replay(_) => unreachable!(),
        };
        let third = registry
            .complete_operation(
                automation_permit,
                TerminalOperationOutcome::InputApplied { encoded_bytes: 9 },
            )
            .unwrap();
        assert_eq!(third.ordered_input_sequence, Some(3));
        assert_eq!(
            registry
                .begin_delegated_input(
                    surface,
                    delegated_reference,
                    AutomationInputScope::Mouse,
                    2,
                    Uuid::new_v4(),
                    RequestFingerprint([8; 32]),
                    None,
                )
                .unwrap_err(),
            TerminalAuthorityError::DelegationScopeDenied
        );
    }

    #[test]
    fn direct_and_two_phone_delegates_share_order_but_not_authority() {
        let (_, registry, surface, mac) = fixture();
        let phone_a = TerminalConnectionClaim {
            connection: 9,
            client_uuid: uuid("50000000-0000-4000-8000-000000000003"),
            process_instance_uuid: uuid("60000000-0000-4000-8000-000000000003"),
        };
        let phone_b = TerminalConnectionClaim {
            connection: 10,
            client_uuid: uuid("50000000-0000-4000-8000-000000000004"),
            process_instance_uuid: uuid("60000000-0000-4000-8000-000000000004"),
        };
        let input_lease = registry.acquire(surface, TerminalLeaseKind::Input, mac, 5_000).unwrap();
        let geometry_lease =
            registry.acquire(surface, TerminalLeaseKind::Geometry, mac, 5_000).unwrap();
        let phone_a_delegation = registry
            .grant_input_delegation(
                surface,
                reference(mac, &input_lease),
                phone_a,
                2_000,
                BTreeSet::from([AutomationInputScope::Text]),
            )
            .unwrap();
        let phone_b_delegation = registry
            .grant_input_delegation(
                surface,
                reference(mac, &input_lease),
                phone_b,
                2_000,
                BTreeSet::from([AutomationInputScope::Text]),
            )
            .unwrap();
        assert_eq!(phone_a_delegation.next_client_sequence, 1);
        assert_eq!(phone_b_delegation.next_client_sequence, 1);

        let phone_a_reference = TerminalDelegationReference {
            connection: phone_a.connection,
            client_uuid: phone_a.client_uuid,
            process_instance_uuid: phone_a.process_instance_uuid,
            delegation_id: phone_a_delegation.delegation_id,
            delegation_generation: phone_a_delegation.delegation_generation,
        };
        let phone_b_reference = TerminalDelegationReference {
            connection: phone_b.connection,
            client_uuid: phone_b.client_uuid,
            process_instance_uuid: phone_b.process_instance_uuid,
            delegation_id: phone_b_delegation.delegation_id,
            delegation_generation: phone_b_delegation.delegation_generation,
        };

        let mac_first =
            execute_input(&registry, surface, reference(mac, &input_lease), 1, 20, None);
        assert_eq!(mac_first.sequence, 1);
        assert_eq!(mac_first.ordered_input_sequence, Some(1));

        for (phone, delegated, fingerprint) in
            [(phone_a, phone_a_reference, 21), (phone_b, phone_b_reference, 22)]
        {
            for scope in [AutomationInputScope::Key, AutomationInputScope::Mouse] {
                assert_eq!(
                    registry
                        .begin_delegated_input(
                            surface,
                            delegated,
                            scope,
                            1,
                            Uuid::new_v4(),
                            RequestFingerprint([fingerprint; 32]),
                            None,
                        )
                        .unwrap_err(),
                    TerminalAuthorityError::DelegationScopeDenied
                );
            }
            let forged_geometry = TerminalLeaseReference {
                connection: phone.connection,
                client_uuid: phone.client_uuid,
                process_instance_uuid: phone.process_instance_uuid,
                presentation_id: mac.presentation_id,
                presentation_generation: mac.presentation_generation,
                lease_id: geometry_lease.lease_id,
                lease_generation: geometry_lease.lease_generation,
            };
            assert_eq!(
                registry
                    .begin_geometry(
                        surface,
                        forged_geometry,
                        1,
                        Uuid::new_v4(),
                        RequestFingerprint([fingerprint + 1; 32]),
                    )
                    .unwrap_err(),
                TerminalAuthorityError::LeaseMismatch(TerminalLeaseKind::Geometry)
            );
        }

        let phone_a_first = execute_delegated_input(&registry, surface, phone_a_reference, 1, 30);
        assert_eq!(phone_a_first.sequence, 1);
        assert_eq!(phone_a_first.ordered_input_sequence, Some(2));
        let phone_b_first = execute_delegated_input(&registry, surface, phone_b_reference, 1, 31);
        assert_eq!(phone_b_first.sequence, 1);
        assert_eq!(phone_b_first.ordered_input_sequence, Some(3));

        registry
            .revoke_input_delegation(
                surface,
                reference(mac, &input_lease),
                phone_a_delegation.delegation_id,
                phone_a_delegation.delegation_generation,
            )
            .unwrap();
        assert_eq!(
            registry
                .begin_delegated_input(
                    surface,
                    phone_a_reference,
                    AutomationInputScope::Text,
                    2,
                    Uuid::new_v4(),
                    RequestFingerprint([32; 32]),
                    None,
                )
                .unwrap_err(),
            TerminalAuthorityError::DelegationMissing
        );

        let mac_second =
            execute_input(&registry, surface, reference(mac, &input_lease), 2, 33, None);
        assert_eq!(mac_second.sequence, 2);
        assert_eq!(mac_second.ordered_input_sequence, Some(4));

        let phone_b_second = execute_delegated_input(&registry, surface, phone_b_reference, 2, 34);
        assert_eq!(phone_b_second.sequence, 2);
        assert_eq!(phone_b_second.ordered_input_sequence, Some(5));
    }

    #[test]
    fn stale_delegate_connection_claim_is_rejected_after_reconnect() {
        let (_, registry, surface, gui) = fixture();
        let automation = TerminalConnectionClaim {
            connection: 9,
            client_uuid: uuid("50000000-0000-4000-8000-000000000003"),
            process_instance_uuid: uuid("60000000-0000-4000-8000-000000000003"),
        };
        let lease = registry.acquire(surface, TerminalLeaseKind::Input, gui, 5_000).unwrap();
        let delegation = registry
            .grant_input_delegation(
                surface,
                reference(gui, &lease),
                automation,
                2_000,
                BTreeSet::from([AutomationInputScope::Text]),
            )
            .unwrap();
        let stale = TerminalDelegationReference {
            connection: 10,
            client_uuid: automation.client_uuid,
            process_instance_uuid: Uuid::new_v4(),
            delegation_id: delegation.delegation_id,
            delegation_generation: delegation.delegation_generation,
        };
        assert_eq!(
            registry
                .begin_delegated_input(
                    surface,
                    stale,
                    AutomationInputScope::Text,
                    1,
                    Uuid::new_v4(),
                    RequestFingerprint([9; 32]),
                    None,
                )
                .unwrap_err(),
            TerminalAuthorityError::DelegationMismatch
        );
    }
}
