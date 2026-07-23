//! Versioned wire types for external cmux machine providers.
//!
//! The control protocol uses newline-delimited JSON. Provider control metadata
//! may gain new top-level fields within v1, so envelopes accept unknown fields.
//! Method parameters, results, transport handshakes, and security-sensitive
//! descriptors reject unknown fields because silently ignoring those fields can
//! change the meaning of an operation.

use std::collections::BTreeMap;
use std::fmt;

use serde::de::Error as _;
use serde::ser::SerializeMap as _;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use subtle::ConstantTimeEq;
use zeroize::Zeroize;

pub const PROTOCOL_NAME: &str = "cmux.machine-provider";
pub const PROTOCOL_VERSION: u16 = 1;
/// Gates provider-owned external-machine enrollment.
///
/// The snapshot bit alone predates a complete provider request path. Clients
/// must require this negotiated capability before presenting that action.
pub const EXTERNAL_MACHINE_CONNECT_CAPABILITY: &str = "connect-external-machine-v1";
pub const MACHINE_LIFECYCLE_CAPABILITY: &str = "machine-lifecycle-v1";
pub const WORKSPACE_LIFECYCLE_CAPABILITY: &str = "workspace-lifecycle-v1";
pub const WORKSPACE_MIRROR_AUTHORITY_CAPABILITY: &str = "workspace-mirror-authority-v1";
pub const MIN_WORKSPACE_MIRROR_AUTHORITY_BYTES: usize = 32;

const MAX_OPAQUE_ID_BYTES: usize = 512;
const MAX_ERROR_CODE_BYTES: usize = 64;
const MAX_EXTERNAL_MACHINE_SPECIFIER_BYTES: usize = 512;

/// A provider-owned identifier. Its contents have no meaning to cmux.
#[derive(Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct OpaqueId(String);

impl OpaqueId {
    pub fn new(value: impl Into<String>) -> Result<Self, InvalidOpaqueId> {
        let value = value.into();
        validate_opaque(&value).then_some(Self(value)).ok_or(InvalidOpaqueId)
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn into_inner(self) -> String {
        self.0
    }
}

impl fmt::Debug for OpaqueId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.debug_tuple("OpaqueId").field(&self.0).finish()
    }
}

impl fmt::Display for OpaqueId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl Serialize for OpaqueId {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(&self.0)
    }
}

impl<'de> Deserialize<'de> for OpaqueId {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        Self::new(value).map_err(D::Error::custom)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InvalidOpaqueId;

impl fmt::Display for InvalidOpaqueId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("opaque IDs must be non-empty, bounded strings without control bytes")
    }
}

impl std::error::Error for InvalidOpaqueId {}

/// An address or one-use pairing code interpreted only by the provider.
///
/// Debug output is redacted because a pairing code can be a bearer
/// credential. Internal whitespace is retained so providers can define their
/// own human-readable pairing-code format.
#[derive(Clone)]
pub struct ExternalMachineSpecifier(String);

impl ExternalMachineSpecifier {
    pub fn new(value: impl Into<String>) -> Result<Self, InvalidExternalMachineSpecifier> {
        let mut value = value.into();
        if valid_external_machine_specifier(&value) {
            Ok(Self(value))
        } else {
            value.zeroize();
            Err(InvalidExternalMachineSpecifier)
        }
    }

    pub fn expose(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for ExternalMachineSpecifier {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("ExternalMachineSpecifier([redacted])")
    }
}

impl Drop for ExternalMachineSpecifier {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

impl PartialEq for ExternalMachineSpecifier {
    fn eq(&self, other: &Self) -> bool {
        bool::from(self.0.as_bytes().ct_eq(other.0.as_bytes()))
    }
}

impl Eq for ExternalMachineSpecifier {}

impl Serialize for ExternalMachineSpecifier {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(&self.0)
    }
}

impl<'de> Deserialize<'de> for ExternalMachineSpecifier {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        Self::new(value).map_err(D::Error::custom)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InvalidExternalMachineSpecifier;

impl fmt::Display for InvalidExternalMachineSpecifier {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(
            "external machine addresses and pairing codes must be non-empty, bounded strings without surrounding whitespace or control bytes",
        )
    }
}

impl std::error::Error for InvalidExternalMachineSpecifier {}

/// A bearer credential. Debug output is deliberately redacted.
#[derive(Clone)]
pub struct BearerToken(String);

impl BearerToken {
    pub fn new(value: impl Into<String>) -> Result<Self, InvalidOpaqueId> {
        let mut value = value.into();
        if validate_opaque(&value) {
            Ok(Self(value))
        } else {
            value.zeroize();
            Err(InvalidOpaqueId)
        }
    }

    pub fn expose(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for BearerToken {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("BearerToken([redacted])")
    }
}

impl Drop for BearerToken {
    fn drop(&mut self) {
        // Replacing every byte with NUL preserves UTF-8 validity while
        // clearing the credential's owned allocation before it is released.
        self.0.zeroize();
    }
}

impl PartialEq for BearerToken {
    fn eq(&self, other: &Self) -> bool {
        bool::from(self.0.as_bytes().ct_eq(other.0.as_bytes()))
    }
}

impl Eq for BearerToken {}

impl Serialize for BearerToken {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(&self.0)
    }
}

impl<'de> Deserialize<'de> for BearerToken {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        Self::new(value).map_err(D::Error::custom)
    }
}

fn validate_opaque(value: &str) -> bool {
    !value.is_empty() && value.len() <= MAX_OPAQUE_ID_BYTES && !value.chars().any(char::is_control)
}

fn valid_external_machine_specifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_EXTERNAL_MACHINE_SPECIFIER_BYTES
        && value.trim() == value
        && !value.chars().any(char::is_control)
}

fn is_false(value: &bool) -> bool {
    !*value
}

/// Serializes as the fixed protocol name and rejects every other name.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Protocol;

impl Serialize for Protocol {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(PROTOCOL_NAME)
    }
}

impl<'de> Deserialize<'de> for Protocol {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        if value == PROTOCOL_NAME {
            Ok(Self)
        } else {
            Err(D::Error::custom(format!("unsupported protocol {value:?}")))
        }
    }
}

/// Serializes as v1 and rejects every other major protocol version.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Version;

impl Serialize for Version {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_u16(PROTOCOL_VERSION)
    }
}

impl<'de> Deserialize<'de> for Version {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = u16::deserialize(deserializer)?;
        if value == PROTOCOL_VERSION {
            Ok(Self)
        } else {
            Err(D::Error::custom(format!("unsupported machine-provider protocol version {value}")))
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RequestEnvelope {
    pub protocol: Protocol,
    pub version: Version,
    pub id: OpaqueId,
    #[serde(flatten)]
    pub request: ProviderRequest,
}

impl RequestEnvelope {
    pub fn new(id: OpaqueId, request: ProviderRequest) -> Self {
        Self { protocol: Protocol, version: Version, id, request }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "method", content = "params", rename_all = "snake_case")]
pub enum ProviderRequest {
    Hello(HelloParams),
    Snapshot(SnapshotParams),
    OpenMachine(OpenMachineParams),
    SelectScope(SelectScopeParams),
    CreateMachine(CreateMachineParams),
    ConnectExternalMachine(ConnectExternalMachineParams),
    MachineLifecycleSnapshot(MachineLifecycleSnapshotParams),
    RenameMachine(RenameMachineParams),
    DeleteMachine(MachineMutationParams),
    RestoreMachine(MachineMutationParams),
    PurgeMachine(MachineMutationParams),
    CreateWorkspace(CreateWorkspaceParams),
    WorkspaceSnapshot(WorkspaceSnapshotParams),
    RenameWorkspace(RenameWorkspaceParams),
    DeleteWorkspace(WorkspaceMutationParams),
    RestoreWorkspace(WorkspaceMutationParams),
    PurgeWorkspace(WorkspaceMutationParams),
    InvokeAction(InvokeActionParams),
    CloseMachine(CloseMachineParams),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResponseEnvelope<T> {
    pub protocol: Protocol,
    pub version: Version,
    pub id: OpaqueId,
    /// Additive provider features available for this authenticated generation.
    ///
    /// Providers advertise these on the successful `hello` response. Unknown
    /// names are retained so future capabilities remain forward compatible.
    pub capabilities: Vec<String>,
    pub response: ProviderResponse<T>,
}

impl<T> ResponseEnvelope<T> {
    pub fn success(id: OpaqueId, result: T) -> Self {
        Self {
            protocol: Protocol,
            version: Version,
            id,
            capabilities: Vec::new(),
            response: ProviderResponse::Success(result),
        }
    }

    pub fn failure(id: OpaqueId, error: ProviderError) -> Self {
        Self {
            protocol: Protocol,
            version: Version,
            id,
            capabilities: Vec::new(),
            response: ProviderResponse::Failure(error),
        }
    }

    pub fn with_capabilities<I, S>(mut self, capabilities: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        self.capabilities = capabilities.into_iter().map(Into::into).collect();
        self
    }
}

impl<T> Serialize for ResponseEnvelope<T>
where
    T: Serialize,
{
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let mut map =
            serializer.serialize_map(Some(4 + usize::from(!self.capabilities.is_empty())))?;
        map.serialize_entry("protocol", &self.protocol)?;
        map.serialize_entry("version", &self.version)?;
        map.serialize_entry("id", &self.id)?;
        if !self.capabilities.is_empty() {
            map.serialize_entry("capabilities", &self.capabilities)?;
        }
        match &self.response {
            ProviderResponse::Success(result) => map.serialize_entry("result", result)?,
            ProviderResponse::Failure(error) => map.serialize_entry("error", error)?,
        }
        map.end()
    }
}

impl<'de, T> Deserialize<'de> for ResponseEnvelope<T>
where
    T: Deserialize<'de>,
{
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let raw = RawResponseEnvelope::<T>::deserialize(deserializer)?;
        let response = match (raw.result, raw.error) {
            (Some(result), None) => ProviderResponse::Success(result),
            (None, Some(error)) => ProviderResponse::Failure(error),
            (Some(_), Some(_)) => {
                return Err(D::Error::custom("provider response contains both result and error"));
            }
            (None, None) => {
                return Err(D::Error::custom(
                    "provider response contains neither result nor error",
                ));
            }
        };
        Ok(Self {
            protocol: raw.protocol,
            version: raw.version,
            id: raw.id,
            capabilities: raw.capabilities,
            response,
        })
    }
}

#[derive(Deserialize)]
#[serde(bound(deserialize = "T: Deserialize<'de>"))]
struct RawResponseEnvelope<T> {
    protocol: Protocol,
    version: Version,
    id: OpaqueId,
    #[serde(default)]
    capabilities: Vec<String>,
    #[serde(default)]
    result: Option<T>,
    #[serde(default)]
    error: Option<ProviderError>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProviderResponse<T> {
    Success(T),
    Failure(ProviderError),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EventEnvelope {
    pub protocol: Protocol,
    pub version: Version,
    #[serde(flatten)]
    pub event: ProviderEvent,
}

impl EventEnvelope {
    pub fn new(event: ProviderEvent) -> Self {
        Self { protocol: Protocol, version: Version, event }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "event", content = "params", rename_all = "snake_case")]
pub enum ProviderEvent {
    SnapshotChanged(SnapshotChangedEvent),
    ConnectionClosed(ConnectionClosedEvent),
    Notice(ProviderNotice),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ClientDescriptor {
    pub name: String,
    pub version: String,
    pub supported_versions: Vec<u16>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HelloParams {
    pub token: BearerToken,
    pub client: ClientDescriptor,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HelloResult {
    pub provider_id: OpaqueId,
    pub provider_name: String,
    pub negotiated_version: Version,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SnapshotParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub known_revision: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SnapshotResult {
    pub revision: u64,
    pub scopes: Vec<ScopeDescriptor>,
    pub selected_scope_id: OpaqueId,
    pub machines: Vec<MachineDescriptor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selected_machine_id: Option<OpaqueId>,
    pub capabilities: ProviderCapabilities,
    #[serde(default)]
    pub actions: Vec<ProviderAction>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notice: Option<ProviderNotice>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ScopeDescriptor {
    pub id: OpaqueId,
    pub display_name: String,
    pub kind: ScopeKind,
    pub can_admin: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ScopeKind {
    Personal,
    Team,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MachineDescriptor {
    pub id: OpaqueId,
    pub display_name: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub subtitle: String,
    pub status: MachineStatus,
    pub connectable: bool,
    pub workspace_create: WorkspaceCreatePolicy,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MachineStatus {
    Running,
    Connecting,
    Sleeping,
    Stopped,
    Unavailable,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "owner", rename_all = "snake_case", deny_unknown_fields)]
pub enum WorkspaceCreatePolicy {
    Session,
    Provider { default_mode: WorkspaceCreateMode, modes: Vec<WorkspaceCreateMode> },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkspaceCreateMode {
    Isolated,
    Host,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderCapabilities {
    #[serde(default)]
    pub create_machine: bool,
    #[serde(default)]
    pub connect_external_machine: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderAction {
    pub id: OpaqueId,
    pub label: String,
    #[serde(default)]
    pub destructive: bool,
    #[serde(default)]
    pub fields: Vec<ActionField>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ActionField {
    pub id: String,
    pub kind: ActionFieldKind,
    pub label: String,
    #[serde(default)]
    pub required: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_length: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub minimum: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub maximum: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub placeholder: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActionFieldKind {
    Text,
    Email,
    Integer,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OpenMachineParams {
    pub machine_id: OpaqueId,
    /// Set only after the provider advertises
    /// `workspace-mirror-authority-v1`. Omitting this field keeps v1
    /// requests compatible with providers built before that capability.
    #[serde(default, skip_serializing_if = "is_false")]
    pub workspace_mirror_authority: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OpenMachineResult {
    pub connection_id: OpaqueId,
    pub transport: TransportDescriptor,
    /// Per-mux secret used only for post-provider workspace mirror commits.
    /// Providers return it only when `workspace-mirror-authority-v1` was
    /// advertised and must provision the same value into the remote mux.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace_mirror_authority: Option<BearerToken>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SelectScopeParams {
    pub scope_id: OpaqueId,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SelectScopeResult {
    pub snapshot: SnapshotResult,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CreateMachineParams {
    pub scope_id: OpaqueId,
    pub mutation_id: OpaqueId,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CreateMachineResult {
    pub machine_id: OpaqueId,
    pub revision: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notice: Option<ProviderNotice>,
}

/// Enrolls and selects one machine from an address or pairing code.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ConnectExternalMachineParams {
    pub scope_id: OpaqueId,
    pub specifier: ExternalMachineSpecifier,
    pub mutation_id: OpaqueId,
}

/// The durable, idempotently replayable result of external-machine enrollment.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ConnectExternalMachineResult {
    pub machine_id: OpaqueId,
    pub revision: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notice: Option<ProviderNotice>,
}

/// Selects the provider-owned machine lifecycle catalog for one scope.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MachineLifecycleSnapshotParams {
    pub scope_id: OpaqueId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub known_revision: Option<u64>,
}

/// Active and recoverable machines whose durable lifecycle is provider-owned.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MachineLifecycleSnapshotResult {
    pub revision: u64,
    pub scope_id: OpaqueId,
    pub machines: Vec<MachineLifecycleDescriptor>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MachineLifecycleDescriptor {
    pub id: OpaqueId,
    pub display_name: String,
    pub status: MachineLifecycleStatus,
    pub version: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recoverable_until: Option<String>,
    pub capabilities: MachineLifecycleCapabilities,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MachineLifecycleStatus {
    Active,
    Recoverable,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MachineLifecycleCapabilities {
    #[serde(default)]
    pub rename: bool,
    #[serde(default)]
    pub delete: bool,
    #[serde(default)]
    pub restore: bool,
    #[serde(default)]
    pub purge: bool,
}

/// Renames one provider-owned machine under an optimistic version fence.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RenameMachineParams {
    pub scope_id: OpaqueId,
    pub machine_id: OpaqueId,
    pub expected_version: u64,
    pub display_name: String,
    pub mutation_id: OpaqueId,
}

/// Deletes, restores, or permanently purges one provider-owned machine.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MachineMutationParams {
    pub scope_id: OpaqueId,
    pub machine_id: OpaqueId,
    pub expected_version: u64,
    pub mutation_id: OpaqueId,
}

/// Durable result shared by provider-owned machine lifecycle mutations.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MachineMutationResult {
    pub machine_id: OpaqueId,
    pub version: u64,
    pub revision: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notice: Option<ProviderNotice>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CreateWorkspaceParams {
    pub machine_id: OpaqueId,
    pub mode: WorkspaceCreateMode,
    pub mutation_id: OpaqueId,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CreateWorkspaceResult {
    pub revision: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notice: Option<ProviderNotice>,
}

/// Selects the provider-owned workspace catalog for one machine.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WorkspaceSnapshotParams {
    pub machine_id: OpaqueId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub known_revision: Option<u64>,
}

/// The provider-owned workspace catalog for one machine.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WorkspaceSnapshotResult {
    pub revision: u64,
    pub machine_id: OpaqueId,
    pub workspaces: Vec<WorkspaceLifecycleDescriptor>,
}

/// A workspace whose durable lifecycle is owned by the provider.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WorkspaceLifecycleDescriptor {
    pub id: OpaqueId,
    pub display_name: String,
    pub mode: WorkspaceCreateMode,
    pub status: WorkspaceLifecycleStatus,
    pub version: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recoverable_until: Option<String>,
    pub capabilities: WorkspaceLifecycleCapabilities,
}

/// Provider lifecycle state independent of the nested cmux session state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkspaceLifecycleStatus {
    Active,
    Recoverable,
}

/// Mutations currently allowed for a workspace after server-side authorization.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WorkspaceLifecycleCapabilities {
    #[serde(default)]
    pub rename: bool,
    #[serde(default)]
    pub delete: bool,
    #[serde(default)]
    pub restore: bool,
    #[serde(default)]
    pub purge: bool,
}

/// Renames one provider-owned workspace under an optimistic version fence.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RenameWorkspaceParams {
    pub machine_id: OpaqueId,
    pub workspace_id: OpaqueId,
    pub expected_version: u64,
    pub display_name: String,
    pub mutation_id: OpaqueId,
}

/// Deletes, restores, or permanently purges one provider-owned workspace.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WorkspaceMutationParams {
    pub machine_id: OpaqueId,
    pub workspace_id: OpaqueId,
    pub expected_version: u64,
    pub mutation_id: OpaqueId,
}

/// Durable result shared by provider-owned workspace mutations.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WorkspaceMutationResult {
    pub workspace_id: OpaqueId,
    pub version: u64,
    pub revision: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notice: Option<ProviderNotice>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum ActionValue {
    Text(String),
    Integer(i64),
    Boolean(bool),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InvokeActionParams {
    pub action_id: OpaqueId,
    #[serde(default)]
    pub values: BTreeMap<String, ActionValue>,
    pub mutation_id: OpaqueId,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InvokeActionResult {
    pub revision: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notice: Option<ProviderNotice>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selected_scope_id: Option<OpaqueId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selected_machine_id: Option<OpaqueId>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CloseMachineParams {
    pub connection_id: OpaqueId,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CloseMachineResult {
    pub revision: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum TransportDescriptor {
    ProviderStream { ticket: BearerToken, expires_at: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TransportRole {
    Transport,
}

/// The first and only provider-protocol frame on a transport connection.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TransportHandshake {
    pub protocol: Protocol,
    pub version: Version,
    pub role: TransportRole,
    pub token: BearerToken,
    pub ticket: BearerToken,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TransportHandshakeResult {
    pub accepted: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SnapshotChangedEvent {
    pub revision: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ConnectionClosedEvent {
    pub connection_id: OpaqueId,
    pub machine_id: OpaqueId,
    pub reason: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderNotice {
    pub level: NoticeLevel,
    pub message: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NoticeLevel {
    Info,
    Warning,
    Error,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderError {
    pub code: ProviderErrorCode,
    pub message: String,
    pub retryable: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProviderErrorCode {
    InvalidInput,
    PermissionDenied,
    NotFound,
    Conflict,
    Unavailable,
    Timeout,
    UnsupportedVersion,
    Internal,
    Other(String),
}

impl ProviderErrorCode {
    pub fn as_str(&self) -> &str {
        match self {
            Self::InvalidInput => "invalid_input",
            Self::PermissionDenied => "permission_denied",
            Self::NotFound => "not_found",
            Self::Conflict => "conflict",
            Self::Unavailable => "unavailable",
            Self::Timeout => "timeout",
            Self::UnsupportedVersion => "unsupported_version",
            Self::Internal => "internal",
            Self::Other(value) => value,
        }
    }
}

impl Serialize for ProviderErrorCode {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(self.as_str())
    }
}

impl<'de> Deserialize<'de> for ProviderErrorCode {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        let code = match value.as_str() {
            "invalid_input" => Self::InvalidInput,
            "permission_denied" => Self::PermissionDenied,
            "not_found" => Self::NotFound,
            "conflict" => Self::Conflict,
            "unavailable" => Self::Unavailable,
            "timeout" => Self::Timeout,
            "unsupported_version" => Self::UnsupportedVersion,
            "internal" => Self::Internal,
            _ if valid_error_code(&value) => Self::Other(value),
            _ => return Err(D::Error::custom("provider error code is invalid")),
        };
        Ok(code)
    }
}

fn valid_error_code(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_ERROR_CODE_BYTES
        && value.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'_' | b'-' | b'.')
        })
}

#[cfg(test)]
mod tests {
    use serde::de::DeserializeOwned;
    use serde_json::{Value, json};

    use super::*;

    fn id(value: &str) -> OpaqueId {
        OpaqueId::new(value).unwrap()
    }

    fn token(value: &str) -> BearerToken {
        BearerToken::new(value).unwrap()
    }

    fn specifier(value: &str) -> ExternalMachineSpecifier {
        ExternalMachineSpecifier::new(value).unwrap()
    }

    #[test]
    fn credential_wrappers_compare_without_exposing_values() {
        assert_eq!(token("single-use-ticket"), token("single-use-ticket"));
        assert_ne!(token("single-use-ticket"), token("different-ticket"));
        assert_eq!(specifier("PAIR 4J7K"), specifier("PAIR 4J7K"));
        assert_ne!(specifier("PAIR 4J7K"), specifier("PAIR 9Q2M"));
    }

    fn empty_snapshot() -> SnapshotResult {
        SnapshotResult {
            revision: 21,
            scopes: vec![ScopeDescriptor {
                id: id("personal"),
                display_name: "Personal".into(),
                kind: ScopeKind::Personal,
                can_admin: false,
            }],
            selected_scope_id: id("personal"),
            machines: Vec::new(),
            selected_machine_id: None,
            capabilities: ProviderCapabilities::default(),
            actions: Vec::new(),
            notice: None,
        }
    }

    fn assert_response_round_trip<T>(result: T)
    where
        T: fmt::Debug + Clone + PartialEq + Eq + Serialize + DeserializeOwned,
    {
        let response = ResponseEnvelope::success(id("response-id"), result);
        let encoded = serde_json::to_value(&response).unwrap();
        let decoded: ResponseEnvelope<T> = serde_json::from_value(encoded).unwrap();
        assert_eq!(decoded, response);
    }

    #[test]
    fn response_capabilities_are_additive_and_legacy_compatible() {
        #[derive(Debug, Deserialize, PartialEq, Eq)]
        struct LegacyHelloResponse {
            protocol: Protocol,
            version: Version,
            id: OpaqueId,
            result: HelloResult,
        }

        let hello = HelloResult {
            provider_id: id("cmux-cloud"),
            provider_name: "cmux Cloud".into(),
            negotiated_version: Version,
        };
        let response = ResponseEnvelope::success(id("hello-response"), hello.clone())
            .with_capabilities([
                MACHINE_LIFECYCLE_CAPABILITY,
                WORKSPACE_LIFECYCLE_CAPABILITY,
                "future-provider-feature-v1",
            ]);
        let encoded = serde_json::to_value(&response).unwrap();
        assert_eq!(
            encoded["capabilities"],
            json!(["machine-lifecycle-v1", "workspace-lifecycle-v1", "future-provider-feature-v1"])
        );

        let decoded: ResponseEnvelope<HelloResult> =
            serde_json::from_value(encoded.clone()).unwrap();
        assert_eq!(decoded, response);

        let legacy: LegacyHelloResponse = serde_json::from_value(encoded).unwrap();
        assert_eq!(legacy.protocol, Protocol);
        assert_eq!(legacy.version, Version);
        assert_eq!(legacy.id, id("hello-response"));
        assert_eq!(legacy.result, hello);

        let legacy_wire = json!({
            "protocol": "cmux.machine-provider",
            "version": 1,
            "id": "hello-response",
            "result": hello
        });
        let decoded: ResponseEnvelope<HelloResult> = serde_json::from_value(legacy_wire).unwrap();
        assert!(decoded.capabilities.is_empty());
    }

    #[test]
    fn snapshot_request_matches_the_v1_golden_document() {
        let request = RequestEnvelope::new(
            id("17"),
            ProviderRequest::Snapshot(SnapshotParams { known_revision: Some(11) }),
        );
        let expected = json!({
            "protocol": "cmux.machine-provider",
            "version": 1,
            "id": "17",
            "method": "snapshot",
            "params": { "known_revision": 11 }
        });

        let encoded = serde_json::to_value(&request).unwrap();
        assert_eq!(encoded, expected);
        assert_eq!(serde_json::from_value::<RequestEnvelope>(expected).unwrap(), request);
    }

    #[test]
    fn connect_external_machine_request_matches_the_v1_golden_document() {
        let request = RequestEnvelope::new(
            id("connect-17"),
            ProviderRequest::ConnectExternalMachine(ConnectExternalMachineParams {
                scope_id: id("team"),
                specifier: specifier("PAIR 4J7K"),
                mutation_id: id("mutation-connect-17"),
            }),
        );
        let expected = json!({
            "protocol": "cmux.machine-provider",
            "version": 1,
            "id": "connect-17",
            "method": "connect_external_machine",
            "params": {
                "scope_id": "team",
                "specifier": "PAIR 4J7K",
                "mutation_id": "mutation-connect-17"
            }
        });

        let encoded = serde_json::to_value(&request).unwrap();
        assert_eq!(encoded, expected);
        assert_eq!(serde_json::from_value::<RequestEnvelope>(expected).unwrap(), request);
        let debug = format!("{request:?}");
        assert!(debug.contains("ExternalMachineSpecifier([redacted])"));
        assert!(!debug.contains("PAIR 4J7K"));
    }

    #[test]
    fn external_machine_specifiers_are_bounded_and_unambiguous() {
        assert!(ExternalMachineSpecifier::new("mini.local").is_ok());
        assert!(ExternalMachineSpecifier::new("PAIR 4J7K").is_ok());
        for invalid in [
            String::new(),
            " ".to_string(),
            " mini.local".to_string(),
            "mini.local ".to_string(),
            "PAIR\n4J7K".to_string(),
            "x".repeat(MAX_EXTERNAL_MACHINE_SPECIFIER_BYTES + 1),
        ] {
            assert!(
                ExternalMachineSpecifier::new(invalid).is_err(),
                "invalid external-machine specifier was accepted"
            );
        }

        let unknown = json!({
            "protocol": "cmux.machine-provider",
            "version": 1,
            "id": "connect-17",
            "method": "connect_external_machine",
            "params": {
                "scope_id": "team",
                "specifier": "mini.local",
                "mutation_id": "mutation-connect-17",
                "shell": "ssh"
            }
        });
        assert!(serde_json::from_value::<RequestEnvelope>(unknown).is_err());
    }

    #[test]
    fn snapshot_response_round_trips_the_full_provider_model() {
        let snapshot = SnapshotResult {
            revision: 13,
            scopes: vec![ScopeDescriptor {
                id: id("subject-uuid"),
                display_name: "Acme".into(),
                kind: ScopeKind::Team,
                can_admin: true,
            }],
            selected_scope_id: id("subject-uuid"),
            machines: vec![MachineDescriptor {
                id: id("vm-uuid"),
                display_name: "Sirius".into(),
                subtitle: "Freestyle".into(),
                status: MachineStatus::Running,
                connectable: true,
                workspace_create: WorkspaceCreatePolicy::Provider {
                    default_mode: WorkspaceCreateMode::Isolated,
                    modes: vec![WorkspaceCreateMode::Isolated, WorkspaceCreateMode::Host],
                },
            }],
            selected_machine_id: Some(id("vm-uuid")),
            capabilities: ProviderCapabilities {
                create_machine: true,
                connect_external_machine: false,
            },
            actions: vec![ProviderAction {
                id: id("team.invite"),
                label: "Invite member".into(),
                destructive: false,
                fields: vec![ActionField {
                    id: "email".into(),
                    kind: ActionFieldKind::Email,
                    label: "Email address".into(),
                    required: true,
                    max_length: Some(254),
                    minimum: None,
                    maximum: None,
                    placeholder: None,
                }],
            }],
            notice: None,
        };
        let response = ResponseEnvelope::success(id("17"), snapshot);
        let encoded = serde_json::to_value(&response).unwrap();
        let expected = json!({
            "protocol": "cmux.machine-provider",
            "version": 1,
            "id": "17",
            "result": {
                "revision": 13,
                "scopes": [{
                    "id": "subject-uuid",
                    "display_name": "Acme",
                    "kind": "team",
                    "can_admin": true
                }],
                "selected_scope_id": "subject-uuid",
                "machines": [{
                    "id": "vm-uuid",
                    "display_name": "Sirius",
                    "subtitle": "Freestyle",
                    "status": "running",
                    "connectable": true,
                    "workspace_create": {
                        "owner": "provider",
                        "default_mode": "isolated",
                        "modes": ["isolated", "host"]
                    }
                }],
                "selected_machine_id": "vm-uuid",
                "capabilities": {
                    "create_machine": true,
                    "connect_external_machine": false
                },
                "actions": [{
                    "id": "team.invite",
                    "label": "Invite member",
                    "destructive": false,
                    "fields": [{
                        "id": "email",
                        "kind": "email",
                        "label": "Email address",
                        "required": true,
                        "max_length": 254
                    }]
                }]
            }
        });
        assert_eq!(encoded, expected);

        let decoded: ResponseEnvelope<SnapshotResult> = serde_json::from_value(expected).unwrap();
        assert_eq!(decoded, response);
    }

    #[test]
    fn open_transport_and_events_match_the_v1_golden_documents() {
        let response = ResponseEnvelope::success(
            id("open-1"),
            OpenMachineResult {
                connection_id: id("connection-uuid"),
                transport: TransportDescriptor::ProviderStream {
                    ticket: token("single-use-ticket"),
                    expires_at: "2026-07-21T22:00:30Z".into(),
                },
                workspace_mirror_authority: Some(token(
                    "provider-workspace-authority-0000000000000001",
                )),
            },
        );
        let debug = format!("{response:?}");
        assert!(debug.contains("BearerToken([redacted])"));
        assert!(!debug.contains("provider-workspace-authority-0000000000000001"));
        assert_eq!(
            serde_json::to_value(response).unwrap(),
            json!({
                "protocol": "cmux.machine-provider",
                "version": 1,
                "id": "open-1",
                "result": {
                    "connection_id": "connection-uuid",
                    "transport": {
                        "kind": "provider_stream",
                        "ticket": "single-use-ticket",
                        "expires_at": "2026-07-21T22:00:30Z"
                    },
                    "workspace_mirror_authority": "provider-workspace-authority-0000000000000001"
                }
            })
        );

        let event = EventEnvelope::new(ProviderEvent::SnapshotChanged(SnapshotChangedEvent {
            revision: 14,
        }));
        assert_eq!(
            serde_json::to_value(event).unwrap(),
            json!({
                "protocol": "cmux.machine-provider",
                "version": 1,
                "event": "snapshot_changed",
                "params": { "revision": 14 }
            })
        );
    }

    #[test]
    fn open_machine_authority_opt_in_preserves_legacy_v1_shape() {
        let legacy = RequestEnvelope::new(
            id("legacy-open"),
            ProviderRequest::OpenMachine(OpenMachineParams {
                machine_id: id("machine"),
                workspace_mirror_authority: false,
            }),
        );
        assert_eq!(
            serde_json::to_value(legacy).unwrap(),
            json!({
                "protocol": "cmux.machine-provider",
                "version": 1,
                "id": "legacy-open",
                "method": "open_machine",
                "params": { "machine_id": "machine" }
            })
        );

        let opted_in = RequestEnvelope::new(
            id("authority-open"),
            ProviderRequest::OpenMachine(OpenMachineParams {
                machine_id: id("machine"),
                workspace_mirror_authority: true,
            }),
        );
        assert_eq!(
            serde_json::to_value(opted_in).unwrap(),
            json!({
                "protocol": "cmux.machine-provider",
                "version": 1,
                "id": "authority-open",
                "method": "open_machine",
                "params": {
                    "machine_id": "machine",
                    "workspace_mirror_authority": true
                }
            })
        );
    }

    #[test]
    fn every_v1_control_method_and_result_round_trips() {
        let mut action_values = BTreeMap::new();
        action_values.insert("email".into(), ActionValue::Text("member@example.com".into()));
        action_values.insert("seats".into(), ActionValue::Integer(4));
        let requests = vec![
            ProviderRequest::Hello(HelloParams {
                token: token("provider-token"),
                client: ClientDescriptor {
                    name: "cmux-tui".into(),
                    version: "0.1.0".into(),
                    supported_versions: vec![1],
                },
            }),
            ProviderRequest::OpenMachine(OpenMachineParams {
                machine_id: id("machine"),
                workspace_mirror_authority: false,
            }),
            ProviderRequest::SelectScope(SelectScopeParams { scope_id: id("team") }),
            ProviderRequest::CreateMachine(CreateMachineParams {
                scope_id: id("team"),
                mutation_id: id("mutation-machine"),
            }),
            ProviderRequest::ConnectExternalMachine(ConnectExternalMachineParams {
                scope_id: id("team"),
                specifier: specifier("PAIR 4J7K"),
                mutation_id: id("mutation-connect-machine"),
            }),
            ProviderRequest::MachineLifecycleSnapshot(MachineLifecycleSnapshotParams {
                scope_id: id("team"),
                known_revision: Some(22),
            }),
            ProviderRequest::RenameMachine(RenameMachineParams {
                scope_id: id("team"),
                machine_id: id("machine"),
                expected_version: 3,
                display_name: "new-machine-name".into(),
                mutation_id: id("mutation-rename-machine"),
            }),
            ProviderRequest::DeleteMachine(MachineMutationParams {
                scope_id: id("team"),
                machine_id: id("machine"),
                expected_version: 4,
                mutation_id: id("mutation-delete-machine"),
            }),
            ProviderRequest::RestoreMachine(MachineMutationParams {
                scope_id: id("team"),
                machine_id: id("machine"),
                expected_version: 5,
                mutation_id: id("mutation-restore-machine"),
            }),
            ProviderRequest::PurgeMachine(MachineMutationParams {
                scope_id: id("team"),
                machine_id: id("machine"),
                expected_version: 6,
                mutation_id: id("mutation-purge-machine"),
            }),
            ProviderRequest::CreateWorkspace(CreateWorkspaceParams {
                machine_id: id("machine"),
                mode: WorkspaceCreateMode::Host,
                mutation_id: id("mutation-workspace"),
            }),
            ProviderRequest::WorkspaceSnapshot(WorkspaceSnapshotParams {
                machine_id: id("machine"),
                known_revision: Some(23),
            }),
            ProviderRequest::RenameWorkspace(RenameWorkspaceParams {
                machine_id: id("machine"),
                workspace_id: id("workspace"),
                expected_version: 4,
                display_name: "new-name".into(),
                mutation_id: id("mutation-rename-workspace"),
            }),
            ProviderRequest::DeleteWorkspace(WorkspaceMutationParams {
                machine_id: id("machine"),
                workspace_id: id("workspace"),
                expected_version: 5,
                mutation_id: id("mutation-delete-workspace"),
            }),
            ProviderRequest::RestoreWorkspace(WorkspaceMutationParams {
                machine_id: id("machine"),
                workspace_id: id("workspace"),
                expected_version: 6,
                mutation_id: id("mutation-restore-workspace"),
            }),
            ProviderRequest::PurgeWorkspace(WorkspaceMutationParams {
                machine_id: id("machine"),
                workspace_id: id("workspace"),
                expected_version: 7,
                mutation_id: id("mutation-purge-workspace"),
            }),
            ProviderRequest::InvokeAction(InvokeActionParams {
                action_id: id("team.invite"),
                values: action_values,
                mutation_id: id("mutation-action"),
            }),
            ProviderRequest::CloseMachine(CloseMachineParams { connection_id: id("connection") }),
        ];
        for (index, request) in requests.into_iter().enumerate() {
            let envelope = RequestEnvelope::new(id(&format!("request-{index}")), request);
            let encoded = serde_json::to_value(&envelope).unwrap();
            let decoded: RequestEnvelope = serde_json::from_value(encoded).unwrap();
            assert_eq!(decoded, envelope);
        }

        assert_response_round_trip(HelloResult {
            provider_id: id("cmux-cloud"),
            provider_name: "cmux Cloud".into(),
            negotiated_version: Version,
        });
        assert_response_round_trip(SelectScopeResult { snapshot: empty_snapshot() });
        assert_response_round_trip(CreateMachineResult {
            machine_id: id("new-machine"),
            revision: 22,
            notice: Some(ProviderNotice {
                level: NoticeLevel::Info,
                message: "VM provisioning".into(),
            }),
        });
        assert_response_round_trip(ConnectExternalMachineResult {
            machine_id: id("paired-machine"),
            revision: 23,
            notice: Some(ProviderNotice {
                level: NoticeLevel::Info,
                message: "Machine connected".into(),
            }),
        });
        assert_response_round_trip(MachineLifecycleSnapshotResult {
            revision: 23,
            scope_id: id("team"),
            machines: vec![MachineLifecycleDescriptor {
                id: id("machine"),
                display_name: "earth".into(),
                status: MachineLifecycleStatus::Recoverable,
                version: 7,
                recoverable_until: Some("2026-07-28T22:00:30Z".into()),
                capabilities: MachineLifecycleCapabilities {
                    rename: false,
                    delete: false,
                    restore: true,
                    purge: true,
                },
            }],
        });
        assert_response_round_trip(MachineMutationResult {
            machine_id: id("machine"),
            version: 8,
            revision: 24,
            notice: Some(ProviderNotice {
                level: NoticeLevel::Info,
                message: "Machine restore requested".into(),
            }),
        });
        assert_response_round_trip(CreateWorkspaceResult {
            revision: 23,
            notice: Some(ProviderNotice {
                level: NoticeLevel::Info,
                message: "Workspace creation requested".into(),
            }),
        });
        assert_response_round_trip(WorkspaceSnapshotResult {
            revision: 24,
            machine_id: id("machine"),
            workspaces: vec![WorkspaceLifecycleDescriptor {
                id: id("workspace"),
                display_name: "earth".into(),
                mode: WorkspaceCreateMode::Isolated,
                status: WorkspaceLifecycleStatus::Recoverable,
                version: 7,
                recoverable_until: Some("2026-07-28T22:00:30Z".into()),
                capabilities: WorkspaceLifecycleCapabilities {
                    rename: false,
                    delete: false,
                    restore: true,
                    purge: true,
                },
            }],
        });
        assert_response_round_trip(WorkspaceMutationResult {
            workspace_id: id("workspace"),
            version: 8,
            revision: 25,
            notice: Some(ProviderNotice {
                level: NoticeLevel::Info,
                message: "Workspace restore requested".into(),
            }),
        });
        assert_response_round_trip(InvokeActionResult {
            revision: 24,
            notice: None,
            url: Some("https://checkout.stripe.com/c/pay/test".into()),
            selected_scope_id: Some(id("team")),
            selected_machine_id: Some(id("machine")),
        });
        assert_response_round_trip(CloseMachineResult { revision: 25 });
    }

    #[test]
    fn future_error_codes_round_trip_without_weakening_known_codes() {
        let document = json!({
            "protocol": "cmux.machine-provider",
            "version": 1,
            "id": "19",
            "error": {
                "code": "provider_rate_limited",
                "message": "Try again later",
                "retryable": true
            }
        });
        let decoded: ResponseEnvelope<SnapshotResult> =
            serde_json::from_value(document.clone()).unwrap();
        assert_eq!(
            decoded.response,
            ProviderResponse::Failure(ProviderError {
                code: ProviderErrorCode::Other("provider_rate_limited".into()),
                message: "Try again later".into(),
                retryable: true,
            })
        );
        assert_eq!(serde_json::to_value(decoded).unwrap(), document);
    }

    #[test]
    fn envelopes_allow_future_metadata_but_params_and_results_stay_strict() {
        let request = json!({
            "protocol": "cmux.machine-provider",
            "version": 1,
            "id": "17",
            "method": "snapshot",
            "params": {},
            "trace_id": "future-metadata"
        });
        assert!(serde_json::from_value::<RequestEnvelope>(request).is_ok());

        let unknown_param = json!({
            "protocol": "cmux.machine-provider",
            "version": 1,
            "id": "17",
            "method": "snapshot",
            "params": { "surprise": true }
        });
        assert!(serde_json::from_value::<RequestEnvelope>(unknown_param).is_err());

        let unknown_result = json!({
            "protocol": "cmux.machine-provider",
            "version": 1,
            "id": "17",
            "result": {
                "connection_id": "connection-uuid",
                "transport": {
                    "kind": "provider_stream",
                    "ticket": "ticket",
                    "expires_at": "soon"
                },
                "surprise": true
            }
        });
        assert!(
            serde_json::from_value::<ResponseEnvelope<OpenMachineResult>>(unknown_result).is_err()
        );
    }

    #[test]
    fn rejects_wrong_protocol_versions_invalid_ids_and_ambiguous_responses() {
        let base = json!({
            "protocol": "cmux.machine-provider",
            "version": 1,
            "id": "17",
            "method": "snapshot",
            "params": {}
        });

        let mut wrong_protocol = base.clone();
        wrong_protocol["protocol"] = Value::String("other.protocol".into());
        assert!(serde_json::from_value::<RequestEnvelope>(wrong_protocol).is_err());

        let mut wrong_version = base.clone();
        wrong_version["version"] = json!(2);
        assert!(serde_json::from_value::<RequestEnvelope>(wrong_version).is_err());

        let mut numeric_id = base.clone();
        numeric_id["id"] = json!(17);
        assert!(serde_json::from_value::<RequestEnvelope>(numeric_id).is_err());

        let mut empty_id = base;
        empty_id["id"] = Value::String(String::new());
        assert!(serde_json::from_value::<RequestEnvelope>(empty_id).is_err());

        let both = json!({
            "protocol": "cmux.machine-provider",
            "version": 1,
            "id": "17",
            "result": { "revision": 1 },
            "error": {
                "code": "internal",
                "message": "broken",
                "retryable": false
            }
        });
        assert!(serde_json::from_value::<ResponseEnvelope<CloseMachineResult>>(both).is_err());

        let neither = json!({
            "protocol": "cmux.machine-provider",
            "version": 1,
            "id": "17"
        });
        assert!(serde_json::from_value::<ResponseEnvelope<CloseMachineResult>>(neither).is_err());
    }

    #[test]
    fn transport_handshake_is_strict_and_redacts_credentials_in_debug_output() {
        let handshake = TransportHandshake {
            protocol: Protocol,
            version: Version,
            role: TransportRole::Transport,
            token: token("provider-token"),
            ticket: token("transport-ticket"),
        };
        assert_eq!(
            serde_json::to_value(&handshake).unwrap(),
            json!({
                "protocol": "cmux.machine-provider",
                "version": 1,
                "role": "transport",
                "token": "provider-token",
                "ticket": "transport-ticket"
            })
        );
        assert!(!format!("{handshake:?}").contains("provider-token"));
        assert!(!format!("{handshake:?}").contains("transport-ticket"));

        let invalid = json!({
            "protocol": "cmux.machine-provider",
            "version": 1,
            "role": "transport",
            "token": "provider-token",
            "ticket": "transport-ticket",
            "ignored": true
        });
        assert!(serde_json::from_value::<TransportHandshake>(invalid).is_err());
    }
}
