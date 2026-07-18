//! Binary control plane between cmuxd and one renderer worker.
//!
//! This wire carries semantic Ghostty scenes and resolved render configuration.
//! It intentionally has no representation for PTY output or rendered pixel data.

use std::collections::VecDeque;
use std::error::Error;
use std::fmt;
use std::mem::size_of;

use uuid::Uuid;

pub const RENDERER_CONTROL_VERSION: u16 = 1;
pub const RENDERER_CONTROL_HEADER_LENGTH: usize = 32;
pub const MAXIMUM_SEMANTIC_SCENE_LENGTH: usize = 64 * 1_024 * 1_024;
pub const MAXIMUM_RESOLVED_CONFIG_LENGTH: usize = 256 * 1_024;
pub const MAXIMUM_DIAGNOSTIC_LENGTH: usize = 4 * 1_024;
pub const MAXIMUM_RENDERER_CONTROL_PAYLOAD_LENGTH: usize = 80 + MAXIMUM_SEMANTIC_SCENE_LENGTH;
pub const MAXIMUM_RENDERER_CONTROL_FRAME_LENGTH: usize =
    RENDERER_CONTROL_HEADER_LENGTH + MAXIMUM_RENDERER_CONTROL_PAYLOAD_LENGTH;

const MAGIC: [u8; 4] = *b"CMRC";
const MAXIMUM_SERVICE_NAME_LENGTH: usize = 120;
const CAPABILITY_LENGTH: usize = 32;
const MAXIMUM_DIMENSION: u32 = 16_384;
const MAXIMUM_PIXEL_COUNT: u64 = 134_217_728;
const MAXIMUM_BACKING_SCALE_FACTOR: f64 = 16.0;
const MAXIMUM_RETIRED_PRESENTATION_FENCES: usize = 8_192;
const MAXIMUM_RETIRED_PRESENTATION_FENCE_BYTES: usize = 512 * 1_024;
const MAXIMUM_PRESENTATION_GENERATION_TOMBSTONES: usize = 8_192;
const MAXIMUM_PRESENTATION_GENERATION_TOMBSTONE_BYTES: usize = 512 * 1_024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RendererControlError {
    InvalidMagic,
    UnsupportedVersion(u16),
    InvalidHeaderLength(u16),
    UnknownDirection(u8),
    UnexpectedDirection,
    UnknownMessageType(u8),
    UnknownFlags(u16),
    NonzeroReserved,
    InvalidSequence { expected: u64, actual: u64 },
    SequenceExhausted,
    InvalidPayloadLength,
    TruncatedFrame,
    TrailingPayload,
    ZeroIdentity,
    ZeroRendererEpoch,
    ZeroPresentationGeneration,
    InvalidDimensions,
    InvalidScale,
    UnknownPixelFormat(u32),
    UnknownColorSpace(u32),
    InvalidServiceName,
    InvalidCapabilityLength,
    ResolvedConfigTooLarge,
    SemanticSceneTooLarge,
    DiagnosticTooLarge,
    InvalidUtf8,
    UnknownSceneCapabilities(u64),
    UnknownNeedsFullSceneReason(u32),
    UnknownFatalCode(u32),
    InvalidProcessIdentity,
    InvalidTransition,
    DecoderFailed,
}

impl fmt::Display for RendererControlError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "renderer control error: {self:?}")
    }
}

impl Error for RendererControlError {}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum RendererControlDirection {
    DaemonToWorker = 1,
    WorkerToDaemon = 2,
}

impl TryFrom<u8> for RendererControlDirection {
    type Error = RendererControlError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::DaemonToWorker),
            2 => Ok(Self::WorkerToDaemon),
            other => Err(RendererControlError::UnknownDirection(other)),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum RendererPixelFormat {
    Bgra8Unorm = 0x4247_5241,
    Rgba16Float = 0x5247_6841,
}

impl TryFrom<u32> for RendererPixelFormat {
    type Error = RendererControlError;

    fn try_from(value: u32) -> Result<Self, Self::Error> {
        match value {
            0x4247_5241 => Ok(Self::Bgra8Unorm),
            0x5247_6841 => Ok(Self::Rgba16Float),
            other => Err(RendererControlError::UnknownPixelFormat(other)),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum RendererColorSpace {
    Srgb = 1,
    DisplayP3 = 2,
    ExtendedLinearSrgb = 3,
}

impl TryFrom<u32> for RendererColorSpace {
    type Error = RendererControlError;

    fn try_from(value: u32) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::Srgb),
            2 => Ok(Self::DisplayP3),
            3 => Ok(Self::ExtendedLinearSrgb),
            other => Err(RendererControlError::UnknownColorSpace(other)),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RendererSceneCapabilities(u64);

impl RendererSceneCapabilities {
    pub const FULL_SCENE: Self = Self(1 << 0);
    pub const CANONICAL_DELTA: Self = Self(1 << 1);
    pub const PRESENTATION_DELTA: Self = Self(1 << 2);
    pub const ALL_KNOWN: Self =
        Self(Self::FULL_SCENE.0 | Self::CANONICAL_DELTA.0 | Self::PRESENTATION_DELTA.0);

    pub const fn from_bits(bits: u64) -> Self {
        Self(bits)
    }

    pub const fn bits(self) -> u64 {
        self.0
    }

    pub const fn union(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }

    pub const fn contains(self, other: Self) -> bool {
        self.0 & other.0 == other.0
    }

    fn validate(self) -> Result<(), RendererControlError> {
        if self.0 & !Self::ALL_KNOWN.0 != 0 || !self.contains(Self::FULL_SCENE) {
            return Err(RendererControlError::UnknownSceneCapabilities(self.0));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum RendererNeedsFullSceneReason {
    InitialSceneRequired = 1,
    SequenceGap = 2,
    DecodeFailure = 3,
    PresentationReset = 4,
}

impl TryFrom<u32> for RendererNeedsFullSceneReason {
    type Error = RendererControlError;

    fn try_from(value: u32) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::InitialSceneRequired),
            2 => Ok(Self::SequenceGap),
            3 => Ok(Self::DecodeFailure),
            4 => Ok(Self::PresentationReset),
            other => Err(RendererControlError::UnknownNeedsFullSceneReason(other)),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum RendererFatalCode {
    ProtocolViolation = 1,
    SceneDecodeFailure = 2,
    RendererInitializationFailure = 3,
    RenderFailure = 4,
    FrameTransportFailure = 5,
    ResourceExhausted = 6,
    InternalInvariant = 7,
}

impl TryFrom<u32> for RendererFatalCode {
    type Error = RendererControlError;

    fn try_from(value: u32) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::ProtocolViolation),
            2 => Ok(Self::SceneDecodeFailure),
            3 => Ok(Self::RendererInitializationFailure),
            4 => Ok(Self::RenderFailure),
            5 => Ok(Self::FrameTransportFailure),
            6 => Ok(Self::ResourceExhausted),
            7 => Ok(Self::InternalInvariant),
            other => Err(RendererControlError::UnknownFatalCode(other)),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct RendererBootstrap {
    pub daemon_instance_id: Uuid,
    pub workspace_id: Uuid,
    pub renderer_epoch: u64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct RendererPresentationAttachment {
    pub terminal_id: Uuid,
    pub terminal_epoch: u64,
    pub presentation_id: Uuid,
    pub presentation_generation: u64,
    pub width: u32,
    pub height: u32,
    pub backing_scale_factor: f64,
    pub pixel_format: RendererPixelFormat,
    pub color_space: RendererColorSpace,
    pub frame_endpoint_service: String,
    pub frame_endpoint_capability: Vec<u8>,
    pub resolved_config_revision: u64,
    pub resolved_config: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RendererPresentationRemoval {
    pub terminal_id: Uuid,
    pub terminal_epoch: u64,
    pub presentation_id: Uuid,
    pub presentation_generation: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RendererPresentationRemoved {
    pub terminal_id: Uuid,
    pub terminal_epoch: u64,
    pub presentation_id: Uuid,
    pub presentation_generation: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RendererSemanticScene {
    pub terminal_id: Uuid,
    pub terminal_epoch: u64,
    pub presentation_id: Uuid,
    pub presentation_generation: u64,
    pub canonical_sequence: u64,
    pub presentation_sequence: u64,
    pub bytes: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RendererFrameRelease {
    pub daemon_instance_id: Uuid,
    pub renderer_epoch: u64,
    pub terminal_id: Uuid,
    pub terminal_epoch: u64,
    pub terminal_sequence: u64,
    pub presentation_id: Uuid,
    pub presentation_generation: u64,
    pub frame_sequence: u64,
    pub surface_id: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RendererWorkerReady {
    pub process_id: u32,
    pub effective_user_id: u32,
    pub scene_capabilities: RendererSceneCapabilities,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RendererPresentationReady {
    pub terminal_id: Uuid,
    pub terminal_epoch: u64,
    pub presentation_id: Uuid,
    pub presentation_generation: u64,
    pub canonical_sequence: u64,
    pub presentation_sequence: u64,
    pub columns: u32,
    pub rows: u32,
    pub cell_width: u32,
    pub cell_height: u32,
    pub padding_top: u32,
    pub padding_right: u32,
    pub padding_bottom: u32,
    pub padding_left: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RendererNeedsFullScene {
    pub terminal_id: Uuid,
    pub terminal_epoch: u64,
    pub presentation_id: Uuid,
    pub presentation_generation: u64,
    pub last_canonical_sequence: u64,
    pub last_presentation_sequence: u64,
    pub reason: RendererNeedsFullSceneReason,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RendererFatal {
    pub code: RendererFatalCode,
    pub diagnostic: String,
}

#[derive(Debug, Clone, PartialEq)]
pub enum RendererControlMessage {
    Bootstrap(RendererBootstrap),
    UpsertPresentation(RendererPresentationAttachment),
    RemovePresentation(RendererPresentationRemoval),
    SemanticScene(RendererSemanticScene),
    FrameRelease(RendererFrameRelease),
    Shutdown,
    Ready(RendererWorkerReady),
    NeedsFullScene(RendererNeedsFullScene),
    Fatal(RendererFatal),
    PresentationReady(RendererPresentationReady),
    PresentationRemoved(RendererPresentationRemoved),
}

impl RendererControlMessage {
    pub const fn direction(&self) -> RendererControlDirection {
        match self {
            Self::Bootstrap(_)
            | Self::UpsertPresentation(_)
            | Self::RemovePresentation(_)
            | Self::SemanticScene(_)
            | Self::FrameRelease(_)
            | Self::Shutdown => RendererControlDirection::DaemonToWorker,
            Self::Ready(_)
            | Self::NeedsFullScene(_)
            | Self::Fatal(_)
            | Self::PresentationReady(_)
            | Self::PresentationRemoved(_) => RendererControlDirection::WorkerToDaemon,
        }
    }

    const fn message_type(&self) -> RendererControlMessageType {
        match self {
            Self::Bootstrap(_) => RendererControlMessageType::Bootstrap,
            Self::UpsertPresentation(_) => RendererControlMessageType::UpsertPresentation,
            Self::RemovePresentation(_) => RendererControlMessageType::RemovePresentation,
            Self::SemanticScene(_) => RendererControlMessageType::SemanticScene,
            Self::FrameRelease(_) => RendererControlMessageType::FrameRelease,
            Self::Shutdown => RendererControlMessageType::Shutdown,
            Self::Ready(_) => RendererControlMessageType::Ready,
            Self::NeedsFullScene(_) => RendererControlMessageType::NeedsFullScene,
            Self::Fatal(_) => RendererControlMessageType::Fatal,
            Self::PresentationReady(_) => RendererControlMessageType::PresentationReady,
            Self::PresentationRemoved(_) => RendererControlMessageType::PresentationRemoved,
        }
    }

    /// Return the exact encoded frame length after validating all variable
    /// payload bounds, without allocating an encoding buffer.
    pub(crate) fn encoded_frame_length(&self) -> Result<usize, RendererControlError> {
        validated_payload_length(self)?
            .checked_add(RENDERER_CONTROL_HEADER_LENGTH)
            .ok_or(RendererControlError::InvalidPayloadLength)
    }

    /// Return bytes retained directly by this owned message.
    ///
    /// This includes the enum's inline storage and every owned buffer's
    /// allocated capacity. Allocator bookkeeping is intentionally excluded;
    /// queue count caps bound that fixed per-allocation overhead separately.
    #[cfg(test)]
    pub(crate) fn retained_byte_count(&self) -> usize {
        size_of::<Self>().saturating_add(self.dynamic_retained_byte_count())
    }

    pub(crate) fn dynamic_retained_byte_count(&self) -> usize {
        match self {
            Self::UpsertPresentation(value) => value
                .frame_endpoint_service
                .capacity()
                .saturating_add(value.frame_endpoint_capability.capacity())
                .saturating_add(value.resolved_config.capacity()),
            Self::SemanticScene(value) => value.bytes.capacity(),
            Self::Fatal(value) => value.diagnostic.capacity(),
            Self::Bootstrap(_)
            | Self::RemovePresentation(_)
            | Self::FrameRelease(_)
            | Self::Shutdown
            | Self::Ready(_)
            | Self::NeedsFullScene(_)
            | Self::PresentationReady(_)
            | Self::PresentationRemoved(_) => 0,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct RendererControlEnvelope {
    pub direction: RendererControlDirection,
    pub sequence: u64,
    pub message: RendererControlMessage,
}

impl RendererControlEnvelope {
    pub fn new(
        direction: RendererControlDirection,
        sequence: u64,
        message: RendererControlMessage,
    ) -> Result<Self, RendererControlError> {
        if sequence == 0 {
            return Err(RendererControlError::InvalidSequence { expected: 1, actual: 0 });
        }
        if direction != message.direction() {
            return Err(RendererControlError::UnexpectedDirection);
        }
        Ok(Self { direction, sequence, message })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
enum RendererControlMessageType {
    Bootstrap = 0x01,
    UpsertPresentation = 0x02,
    RemovePresentation = 0x03,
    SemanticScene = 0x04,
    FrameRelease = 0x05,
    Shutdown = 0x06,
    Ready = 0x81,
    NeedsFullScene = 0x82,
    Fatal = 0x83,
    PresentationReady = 0x84,
    PresentationRemoved = 0x85,
}

impl RendererControlMessageType {
    const fn direction(self) -> RendererControlDirection {
        match self {
            Self::Bootstrap
            | Self::UpsertPresentation
            | Self::RemovePresentation
            | Self::SemanticScene
            | Self::FrameRelease
            | Self::Shutdown => RendererControlDirection::DaemonToWorker,
            Self::Ready
            | Self::NeedsFullScene
            | Self::Fatal
            | Self::PresentationReady
            | Self::PresentationRemoved => RendererControlDirection::WorkerToDaemon,
        }
    }

    const fn payload_bounds(self) -> (usize, usize) {
        match self {
            Self::Bootstrap => (48, 48),
            Self::UpsertPresentation => (
                96,
                96 + MAXIMUM_SERVICE_NAME_LENGTH
                    + CAPABILITY_LENGTH
                    + MAXIMUM_RESOLVED_CONFIG_LENGTH,
            ),
            Self::RemovePresentation => (56, 56),
            Self::SemanticScene => (80, 80 + MAXIMUM_SEMANTIC_SCENE_LENGTH),
            Self::FrameRelease => (96, 96),
            Self::Shutdown => (8, 8),
            Self::Ready => (24, 24),
            Self::NeedsFullScene => (72, 72),
            Self::Fatal => (16, 16 + MAXIMUM_DIAGNOSTIC_LENGTH),
            Self::PresentationReady => (104, 104),
            Self::PresentationRemoved => (56, 56),
        }
    }
}

impl TryFrom<u8> for RendererControlMessageType {
    type Error = RendererControlError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            0x01 => Ok(Self::Bootstrap),
            0x02 => Ok(Self::UpsertPresentation),
            0x03 => Ok(Self::RemovePresentation),
            0x04 => Ok(Self::SemanticScene),
            0x05 => Ok(Self::FrameRelease),
            0x06 => Ok(Self::Shutdown),
            0x81 => Ok(Self::Ready),
            0x82 => Ok(Self::NeedsFullScene),
            0x83 => Ok(Self::Fatal),
            0x84 => Ok(Self::PresentationReady),
            0x85 => Ok(Self::PresentationRemoved),
            other => Err(RendererControlError::UnknownMessageType(other)),
        }
    }
}

pub struct RendererControlWire;

impl RendererControlWire {
    pub fn encode(envelope: &RendererControlEnvelope) -> Result<Vec<u8>, RendererControlError> {
        if envelope.sequence == 0 {
            return Err(RendererControlError::InvalidSequence { expected: 1, actual: 0 });
        }
        if envelope.direction != envelope.message.direction() {
            return Err(RendererControlError::UnexpectedDirection);
        }
        let message_type = envelope.message.message_type();
        let payload_length = validated_payload_length(&envelope.message)?;
        let frame_length = envelope.message.encoded_frame_length()?;
        let mut frame = Vec::with_capacity(frame_length);
        frame.extend_from_slice(&MAGIC);
        frame.extend_from_slice(&RENDERER_CONTROL_VERSION.to_be_bytes());
        frame.extend_from_slice(&(RENDERER_CONTROL_HEADER_LENGTH as u16).to_be_bytes());
        frame.push(envelope.direction as u8);
        frame.push(message_type as u8);
        frame.extend_from_slice(&0_u16.to_be_bytes());
        frame.extend_from_slice(&0_u32.to_be_bytes());
        frame.extend_from_slice(&envelope.sequence.to_be_bytes());
        frame.extend_from_slice(&(payload_length as u64).to_be_bytes());
        Self::encode_payload(&envelope.message, &mut frame)?;
        debug_assert_eq!(frame.len(), frame_length);
        Ok(frame)
    }

    pub fn decode(frame: &[u8]) -> Result<RendererControlEnvelope, RendererControlError> {
        if frame.len() < RENDERER_CONTROL_HEADER_LENGTH {
            return Err(RendererControlError::TruncatedFrame);
        }
        let mut reader = WireReader::new(frame);
        if reader.read_array::<4>()? != MAGIC {
            return Err(RendererControlError::InvalidMagic);
        }
        let version = reader.read_u16()?;
        if version != RENDERER_CONTROL_VERSION {
            return Err(RendererControlError::UnsupportedVersion(version));
        }
        let header_length = reader.read_u16()?;
        if header_length as usize != RENDERER_CONTROL_HEADER_LENGTH {
            return Err(RendererControlError::InvalidHeaderLength(header_length));
        }
        let direction = RendererControlDirection::try_from(reader.read_u8()?)?;
        let type_raw = reader.read_u8()?;
        let message_type = RendererControlMessageType::try_from(type_raw)?;
        if message_type.direction() != direction {
            return Err(RendererControlError::UnknownMessageType(type_raw));
        }
        let flags = reader.read_u16()?;
        if flags != 0 {
            return Err(RendererControlError::UnknownFlags(flags));
        }
        require_reserved_zero(reader.read_u32()?)?;
        let sequence = reader.read_u64()?;
        let payload_length = usize::try_from(reader.read_u64()?)
            .map_err(|_| RendererControlError::InvalidPayloadLength)?;
        let (minimum, maximum) = message_type.payload_bounds();
        if !(minimum..=maximum).contains(&payload_length) {
            return Err(RendererControlError::InvalidPayloadLength);
        }
        if reader.remaining() < payload_length {
            return Err(RendererControlError::TruncatedFrame);
        }
        if reader.remaining() > payload_length {
            return Err(RendererControlError::TrailingPayload);
        }
        let message = Self::decode_payload(message_type, reader.read_slice(payload_length)?)?;
        RendererControlEnvelope::new(direction, sequence, message)
    }

    fn inspect_header(
        header: &[u8],
    ) -> Result<(RendererControlDirection, u64, usize), RendererControlError> {
        if header.len() != RENDERER_CONTROL_HEADER_LENGTH {
            return Err(RendererControlError::TruncatedFrame);
        }
        let mut reader = WireReader::new(header);
        if reader.read_array::<4>()? != MAGIC {
            return Err(RendererControlError::InvalidMagic);
        }
        let version = reader.read_u16()?;
        if version != RENDERER_CONTROL_VERSION {
            return Err(RendererControlError::UnsupportedVersion(version));
        }
        let header_length = reader.read_u16()?;
        if header_length as usize != RENDERER_CONTROL_HEADER_LENGTH {
            return Err(RendererControlError::InvalidHeaderLength(header_length));
        }
        let direction = RendererControlDirection::try_from(reader.read_u8()?)?;
        let type_raw = reader.read_u8()?;
        let message_type = RendererControlMessageType::try_from(type_raw)?;
        if message_type.direction() != direction {
            return Err(RendererControlError::UnknownMessageType(type_raw));
        }
        let flags = reader.read_u16()?;
        if flags != 0 {
            return Err(RendererControlError::UnknownFlags(flags));
        }
        require_reserved_zero(reader.read_u32()?)?;
        let sequence = reader.read_u64()?;
        let payload_length = usize::try_from(reader.read_u64()?)
            .map_err(|_| RendererControlError::InvalidPayloadLength)?;
        let (minimum, maximum) = message_type.payload_bounds();
        if !(minimum..=maximum).contains(&payload_length) {
            return Err(RendererControlError::InvalidPayloadLength);
        }
        Ok((direction, sequence, RENDERER_CONTROL_HEADER_LENGTH + payload_length))
    }

    fn encode_payload(
        message: &RendererControlMessage,
        payload: &mut Vec<u8>,
    ) -> Result<(), RendererControlError> {
        let start = payload.len();
        let expected_length = validated_payload_length(message)?;
        match message {
            RendererControlMessage::Bootstrap(value) => {
                validate_identity(value.daemon_instance_id)?;
                validate_identity(value.workspace_id)?;
                if value.renderer_epoch == 0 {
                    return Err(RendererControlError::ZeroRendererEpoch);
                }
                append_uuid(payload, value.daemon_instance_id);
                append_uuid(payload, value.workspace_id);
                append_u64(payload, value.renderer_epoch);
                append_u64(payload, 0);
            }
            RendererControlMessage::UpsertPresentation(value) => {
                validate_presentation(value)?;
                append_uuid(payload, value.terminal_id);
                append_u64(payload, value.terminal_epoch);
                append_uuid(payload, value.presentation_id);
                append_u64(payload, value.presentation_generation);
                append_u32(payload, value.width);
                append_u32(payload, value.height);
                append_u64(payload, value.backing_scale_factor.to_bits());
                append_u32(payload, value.pixel_format as u32);
                append_u32(payload, value.color_space as u32);
                append_u64(payload, value.resolved_config_revision);
                append_u16(payload, value.frame_endpoint_service.len() as u16);
                append_u16(payload, value.frame_endpoint_capability.len() as u16);
                append_u32(payload, 0);
                append_u64(payload, value.resolved_config.len() as u64);
                payload.extend_from_slice(value.frame_endpoint_service.as_bytes());
                payload.extend_from_slice(&value.frame_endpoint_capability);
                payload.extend_from_slice(&value.resolved_config);
            }
            RendererControlMessage::RemovePresentation(value) => {
                validate_identity(value.terminal_id)?;
                validate_identity(value.presentation_id)?;
                validate_generation(value.presentation_generation)?;
                append_uuid(payload, value.terminal_id);
                append_u64(payload, value.terminal_epoch);
                append_uuid(payload, value.presentation_id);
                append_u64(payload, value.presentation_generation);
                append_u64(payload, 0);
            }
            RendererControlMessage::SemanticScene(value) => {
                validate_identity(value.terminal_id)?;
                validate_identity(value.presentation_id)?;
                validate_generation(value.presentation_generation)?;
                if value.bytes.len() > MAXIMUM_SEMANTIC_SCENE_LENGTH {
                    return Err(RendererControlError::SemanticSceneTooLarge);
                }
                append_uuid(payload, value.terminal_id);
                append_u64(payload, value.terminal_epoch);
                append_uuid(payload, value.presentation_id);
                append_u64(payload, value.presentation_generation);
                append_u64(payload, value.canonical_sequence);
                append_u64(payload, value.presentation_sequence);
                append_u64(payload, value.bytes.len() as u64);
                append_u64(payload, 0);
                payload.extend_from_slice(&value.bytes);
            }
            RendererControlMessage::FrameRelease(value) => {
                validate_identity(value.daemon_instance_id)?;
                validate_identity(value.terminal_id)?;
                validate_identity(value.presentation_id)?;
                if value.renderer_epoch == 0 {
                    return Err(RendererControlError::ZeroRendererEpoch);
                }
                validate_generation(value.presentation_generation)?;
                append_uuid(payload, value.daemon_instance_id);
                append_u64(payload, value.renderer_epoch);
                append_uuid(payload, value.terminal_id);
                append_u64(payload, value.terminal_epoch);
                append_u64(payload, value.terminal_sequence);
                append_uuid(payload, value.presentation_id);
                append_u64(payload, value.presentation_generation);
                append_u64(payload, value.frame_sequence);
                append_u32(payload, value.surface_id);
                append_u32(payload, 0);
            }
            RendererControlMessage::Shutdown => append_u64(payload, 0),
            RendererControlMessage::Ready(value) => {
                if value.process_id == 0 {
                    return Err(RendererControlError::InvalidProcessIdentity);
                }
                value.scene_capabilities.validate()?;
                append_u32(payload, value.process_id);
                append_u32(payload, value.effective_user_id);
                append_u64(payload, value.scene_capabilities.bits());
                append_u64(payload, 0);
            }
            RendererControlMessage::NeedsFullScene(value) => {
                validate_identity(value.terminal_id)?;
                validate_identity(value.presentation_id)?;
                validate_generation(value.presentation_generation)?;
                append_uuid(payload, value.terminal_id);
                append_u64(payload, value.terminal_epoch);
                append_uuid(payload, value.presentation_id);
                append_u64(payload, value.presentation_generation);
                append_u64(payload, value.last_canonical_sequence);
                append_u64(payload, value.last_presentation_sequence);
                append_u32(payload, value.reason as u32);
                append_u32(payload, 0);
            }
            RendererControlMessage::Fatal(value) => {
                if value.diagnostic.len() > MAXIMUM_DIAGNOSTIC_LENGTH {
                    return Err(RendererControlError::DiagnosticTooLarge);
                }
                append_u32(payload, value.code as u32);
                append_u32(payload, value.diagnostic.len() as u32);
                append_u64(payload, 0);
                payload.extend_from_slice(value.diagnostic.as_bytes());
            }
            RendererControlMessage::PresentationReady(value) => {
                validate_identity(value.terminal_id)?;
                validate_identity(value.presentation_id)?;
                validate_generation(value.presentation_generation)?;
                if value.canonical_sequence == 0
                    || value.presentation_sequence == 0
                    || value.columns == 0
                    || value.rows == 0
                    || value.cell_width == 0
                    || value.cell_height == 0
                {
                    return Err(RendererControlError::InvalidDimensions);
                }
                append_uuid(payload, value.terminal_id);
                append_u64(payload, value.terminal_epoch);
                append_uuid(payload, value.presentation_id);
                append_u64(payload, value.presentation_generation);
                append_u64(payload, value.canonical_sequence);
                append_u64(payload, value.presentation_sequence);
                append_u32(payload, value.columns);
                append_u32(payload, value.rows);
                append_u32(payload, value.cell_width);
                append_u32(payload, value.cell_height);
                append_u32(payload, value.padding_top);
                append_u32(payload, value.padding_right);
                append_u32(payload, value.padding_bottom);
                append_u32(payload, value.padding_left);
                append_u64(payload, 0);
            }
            RendererControlMessage::PresentationRemoved(value) => {
                validate_identity(value.terminal_id)?;
                validate_identity(value.presentation_id)?;
                validate_generation(value.presentation_generation)?;
                append_uuid(payload, value.terminal_id);
                append_u64(payload, value.terminal_epoch);
                append_uuid(payload, value.presentation_id);
                append_u64(payload, value.presentation_generation);
                append_u64(payload, 0);
            }
        }
        debug_assert_eq!(payload.len().saturating_sub(start), expected_length);
        Ok(())
    }

    fn decode_payload(
        message_type: RendererControlMessageType,
        payload: &[u8],
    ) -> Result<RendererControlMessage, RendererControlError> {
        let mut reader = WireReader::new(payload);
        let message = match message_type {
            RendererControlMessageType::Bootstrap => {
                let value = RendererBootstrap {
                    daemon_instance_id: reader.read_uuid()?,
                    workspace_id: reader.read_uuid()?,
                    renderer_epoch: reader.read_u64()?,
                };
                require_reserved_zero(reader.read_u64()?)?;
                validate_identity(value.daemon_instance_id)?;
                validate_identity(value.workspace_id)?;
                if value.renderer_epoch == 0 {
                    return Err(RendererControlError::ZeroRendererEpoch);
                }
                RendererControlMessage::Bootstrap(value)
            }
            RendererControlMessageType::UpsertPresentation => {
                let terminal_id = reader.read_uuid()?;
                let terminal_epoch = reader.read_u64()?;
                let presentation_id = reader.read_uuid()?;
                let presentation_generation = reader.read_u64()?;
                let width = reader.read_u32()?;
                let height = reader.read_u32()?;
                let backing_scale_factor = f64::from_bits(reader.read_u64()?);
                let pixel_format = RendererPixelFormat::try_from(reader.read_u32()?)?;
                let color_space = RendererColorSpace::try_from(reader.read_u32()?)?;
                let resolved_config_revision = reader.read_u64()?;
                let service_length = reader.read_u16()? as usize;
                let capability_length = reader.read_u16()? as usize;
                require_reserved_zero(reader.read_u32()?)?;
                let config_length = usize::try_from(reader.read_u64()?)
                    .map_err(|_| RendererControlError::ResolvedConfigTooLarge)?;
                if service_length == 0 || service_length > MAXIMUM_SERVICE_NAME_LENGTH {
                    return Err(RendererControlError::InvalidServiceName);
                }
                if capability_length != CAPABILITY_LENGTH {
                    return Err(RendererControlError::InvalidCapabilityLength);
                }
                if config_length > MAXIMUM_RESOLVED_CONFIG_LENGTH {
                    return Err(RendererControlError::ResolvedConfigTooLarge);
                }
                let expected_remaining = service_length
                    .checked_add(capability_length)
                    .and_then(|value| value.checked_add(config_length))
                    .ok_or(RendererControlError::InvalidPayloadLength)?;
                if reader.remaining() != expected_remaining {
                    return Err(RendererControlError::InvalidPayloadLength);
                }
                let service_bytes = reader.read_slice(service_length)?;
                if service_bytes.contains(&0) {
                    return Err(RendererControlError::InvalidServiceName);
                }
                let frame_endpoint_service = std::str::from_utf8(service_bytes)
                    .map_err(|_| RendererControlError::InvalidServiceName)?
                    .to_owned();
                let frame_endpoint_capability = reader.read_slice(capability_length)?.to_vec();
                let resolved_config = reader.read_slice(config_length)?.to_vec();
                let value = RendererPresentationAttachment {
                    terminal_id,
                    terminal_epoch,
                    presentation_id,
                    presentation_generation,
                    width,
                    height,
                    backing_scale_factor,
                    pixel_format,
                    color_space,
                    frame_endpoint_service,
                    frame_endpoint_capability,
                    resolved_config_revision,
                    resolved_config,
                };
                validate_presentation(&value)?;
                RendererControlMessage::UpsertPresentation(value)
            }
            RendererControlMessageType::RemovePresentation => {
                let value = RendererPresentationRemoval {
                    terminal_id: reader.read_uuid()?,
                    terminal_epoch: reader.read_u64()?,
                    presentation_id: reader.read_uuid()?,
                    presentation_generation: reader.read_u64()?,
                };
                require_reserved_zero(reader.read_u64()?)?;
                validate_identity(value.terminal_id)?;
                validate_identity(value.presentation_id)?;
                validate_generation(value.presentation_generation)?;
                RendererControlMessage::RemovePresentation(value)
            }
            RendererControlMessageType::SemanticScene => {
                let terminal_id = reader.read_uuid()?;
                let terminal_epoch = reader.read_u64()?;
                let presentation_id = reader.read_uuid()?;
                let presentation_generation = reader.read_u64()?;
                let canonical_sequence = reader.read_u64()?;
                let presentation_sequence = reader.read_u64()?;
                let scene_length = usize::try_from(reader.read_u64()?)
                    .map_err(|_| RendererControlError::SemanticSceneTooLarge)?;
                require_reserved_zero(reader.read_u64()?)?;
                if scene_length > MAXIMUM_SEMANTIC_SCENE_LENGTH {
                    return Err(RendererControlError::SemanticSceneTooLarge);
                }
                if reader.remaining() != scene_length {
                    return Err(RendererControlError::InvalidPayloadLength);
                }
                let value = RendererSemanticScene {
                    terminal_id,
                    terminal_epoch,
                    presentation_id,
                    presentation_generation,
                    canonical_sequence,
                    presentation_sequence,
                    bytes: reader.read_slice(scene_length)?.to_vec(),
                };
                validate_identity(value.terminal_id)?;
                validate_identity(value.presentation_id)?;
                validate_generation(value.presentation_generation)?;
                RendererControlMessage::SemanticScene(value)
            }
            RendererControlMessageType::FrameRelease => {
                let value = RendererFrameRelease {
                    daemon_instance_id: reader.read_uuid()?,
                    renderer_epoch: reader.read_u64()?,
                    terminal_id: reader.read_uuid()?,
                    terminal_epoch: reader.read_u64()?,
                    terminal_sequence: reader.read_u64()?,
                    presentation_id: reader.read_uuid()?,
                    presentation_generation: reader.read_u64()?,
                    frame_sequence: reader.read_u64()?,
                    surface_id: reader.read_u32()?,
                };
                require_reserved_zero(reader.read_u32()?)?;
                validate_identity(value.daemon_instance_id)?;
                validate_identity(value.terminal_id)?;
                validate_identity(value.presentation_id)?;
                if value.renderer_epoch == 0 {
                    return Err(RendererControlError::ZeroRendererEpoch);
                }
                validate_generation(value.presentation_generation)?;
                RendererControlMessage::FrameRelease(value)
            }
            RendererControlMessageType::Shutdown => {
                require_reserved_zero(reader.read_u64()?)?;
                RendererControlMessage::Shutdown
            }
            RendererControlMessageType::Ready => {
                let value = RendererWorkerReady {
                    process_id: reader.read_u32()?,
                    effective_user_id: reader.read_u32()?,
                    scene_capabilities: RendererSceneCapabilities::from_bits(reader.read_u64()?),
                };
                require_reserved_zero(reader.read_u64()?)?;
                if value.process_id == 0 {
                    return Err(RendererControlError::InvalidProcessIdentity);
                }
                value.scene_capabilities.validate()?;
                RendererControlMessage::Ready(value)
            }
            RendererControlMessageType::NeedsFullScene => {
                let value = RendererNeedsFullScene {
                    terminal_id: reader.read_uuid()?,
                    terminal_epoch: reader.read_u64()?,
                    presentation_id: reader.read_uuid()?,
                    presentation_generation: reader.read_u64()?,
                    last_canonical_sequence: reader.read_u64()?,
                    last_presentation_sequence: reader.read_u64()?,
                    reason: RendererNeedsFullSceneReason::try_from(reader.read_u32()?)?,
                };
                require_reserved_zero(reader.read_u32()?)?;
                validate_identity(value.terminal_id)?;
                validate_identity(value.presentation_id)?;
                validate_generation(value.presentation_generation)?;
                RendererControlMessage::NeedsFullScene(value)
            }
            RendererControlMessageType::Fatal => {
                let code = RendererFatalCode::try_from(reader.read_u32()?)?;
                let diagnostic_length = reader.read_u32()? as usize;
                require_reserved_zero(reader.read_u64()?)?;
                if diagnostic_length > MAXIMUM_DIAGNOSTIC_LENGTH {
                    return Err(RendererControlError::DiagnosticTooLarge);
                }
                if reader.remaining() != diagnostic_length {
                    return Err(RendererControlError::InvalidPayloadLength);
                }
                let diagnostic = std::str::from_utf8(reader.read_slice(diagnostic_length)?)
                    .map_err(|_| RendererControlError::InvalidUtf8)?
                    .to_owned();
                RendererControlMessage::Fatal(RendererFatal { code, diagnostic })
            }
            RendererControlMessageType::PresentationReady => {
                let value = RendererPresentationReady {
                    terminal_id: reader.read_uuid()?,
                    terminal_epoch: reader.read_u64()?,
                    presentation_id: reader.read_uuid()?,
                    presentation_generation: reader.read_u64()?,
                    canonical_sequence: reader.read_u64()?,
                    presentation_sequence: reader.read_u64()?,
                    columns: reader.read_u32()?,
                    rows: reader.read_u32()?,
                    cell_width: reader.read_u32()?,
                    cell_height: reader.read_u32()?,
                    padding_top: reader.read_u32()?,
                    padding_right: reader.read_u32()?,
                    padding_bottom: reader.read_u32()?,
                    padding_left: reader.read_u32()?,
                };
                require_reserved_zero(reader.read_u64()?)?;
                validate_identity(value.terminal_id)?;
                validate_identity(value.presentation_id)?;
                validate_generation(value.presentation_generation)?;
                if value.canonical_sequence == 0
                    || value.presentation_sequence == 0
                    || value.columns == 0
                    || value.rows == 0
                    || value.cell_width == 0
                    || value.cell_height == 0
                {
                    return Err(RendererControlError::InvalidDimensions);
                }
                RendererControlMessage::PresentationReady(value)
            }
            RendererControlMessageType::PresentationRemoved => {
                let value = RendererPresentationRemoved {
                    terminal_id: reader.read_uuid()?,
                    terminal_epoch: reader.read_u64()?,
                    presentation_id: reader.read_uuid()?,
                    presentation_generation: reader.read_u64()?,
                };
                require_reserved_zero(reader.read_u64()?)?;
                validate_identity(value.terminal_id)?;
                validate_identity(value.presentation_id)?;
                validate_generation(value.presentation_generation)?;
                RendererControlMessage::PresentationRemoved(value)
            }
        };
        if reader.remaining() != 0 {
            return Err(RendererControlError::TrailingPayload);
        }
        Ok(message)
    }
}

fn validated_payload_length(
    message: &RendererControlMessage,
) -> Result<usize, RendererControlError> {
    let length = match message {
        RendererControlMessage::Bootstrap(value) => {
            validate_identity(value.daemon_instance_id)?;
            validate_identity(value.workspace_id)?;
            if value.renderer_epoch == 0 {
                return Err(RendererControlError::ZeroRendererEpoch);
            }
            48
        }
        RendererControlMessage::UpsertPresentation(value) => {
            validate_presentation(value)?;
            96_usize
                .checked_add(value.frame_endpoint_service.len())
                .and_then(|length| length.checked_add(value.frame_endpoint_capability.len()))
                .and_then(|length| length.checked_add(value.resolved_config.len()))
                .ok_or(RendererControlError::InvalidPayloadLength)?
        }
        RendererControlMessage::RemovePresentation(value) => {
            validate_identity(value.terminal_id)?;
            validate_identity(value.presentation_id)?;
            validate_generation(value.presentation_generation)?;
            56
        }
        RendererControlMessage::SemanticScene(value) => {
            validate_identity(value.terminal_id)?;
            validate_identity(value.presentation_id)?;
            validate_generation(value.presentation_generation)?;
            if value.bytes.len() > MAXIMUM_SEMANTIC_SCENE_LENGTH {
                return Err(RendererControlError::SemanticSceneTooLarge);
            }
            80_usize
                .checked_add(value.bytes.len())
                .ok_or(RendererControlError::InvalidPayloadLength)?
        }
        RendererControlMessage::FrameRelease(value) => {
            validate_identity(value.daemon_instance_id)?;
            validate_identity(value.terminal_id)?;
            validate_identity(value.presentation_id)?;
            if value.renderer_epoch == 0 {
                return Err(RendererControlError::ZeroRendererEpoch);
            }
            validate_generation(value.presentation_generation)?;
            96
        }
        RendererControlMessage::Shutdown => 8,
        RendererControlMessage::Ready(value) => {
            if value.process_id == 0 {
                return Err(RendererControlError::InvalidProcessIdentity);
            }
            value.scene_capabilities.validate()?;
            24
        }
        RendererControlMessage::NeedsFullScene(value) => {
            validate_identity(value.terminal_id)?;
            validate_identity(value.presentation_id)?;
            validate_generation(value.presentation_generation)?;
            72
        }
        RendererControlMessage::Fatal(value) => {
            if value.diagnostic.len() > MAXIMUM_DIAGNOSTIC_LENGTH {
                return Err(RendererControlError::DiagnosticTooLarge);
            }
            16_usize
                .checked_add(value.diagnostic.len())
                .ok_or(RendererControlError::InvalidPayloadLength)?
        }
        RendererControlMessage::PresentationReady(value) => {
            validate_identity(value.terminal_id)?;
            validate_identity(value.presentation_id)?;
            validate_generation(value.presentation_generation)?;
            if value.canonical_sequence == 0
                || value.presentation_sequence == 0
                || value.columns == 0
                || value.rows == 0
                || value.cell_width == 0
                || value.cell_height == 0
            {
                return Err(RendererControlError::InvalidDimensions);
            }
            104
        }
        RendererControlMessage::PresentationRemoved(value) => {
            validate_identity(value.terminal_id)?;
            validate_identity(value.presentation_id)?;
            validate_generation(value.presentation_generation)?;
            56
        }
    };
    let (minimum, maximum) = message.message_type().payload_bounds();
    if !(minimum..=maximum).contains(&length) {
        return Err(RendererControlError::InvalidPayloadLength);
    }
    Ok(length)
}

fn validate_identity(value: Uuid) -> Result<(), RendererControlError> {
    if value.is_nil() {
        return Err(RendererControlError::ZeroIdentity);
    }
    Ok(())
}

fn validate_generation(value: u64) -> Result<(), RendererControlError> {
    if value == 0 {
        return Err(RendererControlError::ZeroPresentationGeneration);
    }
    Ok(())
}

fn validate_presentation(
    value: &RendererPresentationAttachment,
) -> Result<(), RendererControlError> {
    validate_identity(value.terminal_id)?;
    validate_identity(value.presentation_id)?;
    validate_generation(value.presentation_generation)?;
    if value.width == 0
        || value.height == 0
        || value.width > MAXIMUM_DIMENSION
        || value.height > MAXIMUM_DIMENSION
        || u64::from(value.width) * u64::from(value.height) > MAXIMUM_PIXEL_COUNT
    {
        return Err(RendererControlError::InvalidDimensions);
    }
    if !value.backing_scale_factor.is_finite()
        || value.backing_scale_factor <= 0.0
        || value.backing_scale_factor > MAXIMUM_BACKING_SCALE_FACTOR
    {
        return Err(RendererControlError::InvalidScale);
    }
    let service = value.frame_endpoint_service.as_bytes();
    if service.is_empty() || service.len() > MAXIMUM_SERVICE_NAME_LENGTH || service.contains(&0) {
        return Err(RendererControlError::InvalidServiceName);
    }
    if value.frame_endpoint_capability.len() != CAPABILITY_LENGTH {
        return Err(RendererControlError::InvalidCapabilityLength);
    }
    if value.resolved_config.len() > MAXIMUM_RESOLVED_CONFIG_LENGTH {
        return Err(RendererControlError::ResolvedConfigTooLarge);
    }
    Ok(())
}

fn require_reserved_zero<T>(value: T) -> Result<(), RendererControlError>
where
    T: PartialEq + From<u8>,
{
    if value != T::from(0) {
        return Err(RendererControlError::NonzeroReserved);
    }
    Ok(())
}

fn append_u16(output: &mut Vec<u8>, value: u16) {
    output.extend_from_slice(&value.to_be_bytes());
}

fn append_u32(output: &mut Vec<u8>, value: u32) {
    output.extend_from_slice(&value.to_be_bytes());
}

fn append_u64(output: &mut Vec<u8>, value: u64) {
    output.extend_from_slice(&value.to_be_bytes());
}

fn append_uuid(output: &mut Vec<u8>, value: Uuid) {
    output.extend_from_slice(value.as_bytes());
}

struct WireReader<'a> {
    bytes: &'a [u8],
    offset: usize,
}

impl<'a> WireReader<'a> {
    const fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, offset: 0 }
    }

    fn remaining(&self) -> usize {
        self.bytes.len() - self.offset
    }

    fn read_slice(&mut self, length: usize) -> Result<&'a [u8], RendererControlError> {
        if length > self.remaining() {
            return Err(RendererControlError::TruncatedFrame);
        }
        let start = self.offset;
        self.offset += length;
        Ok(&self.bytes[start..self.offset])
    }

    fn read_array<const N: usize>(&mut self) -> Result<[u8; N], RendererControlError> {
        self.read_slice(N)?.try_into().map_err(|_| RendererControlError::TruncatedFrame)
    }

    fn read_u8(&mut self) -> Result<u8, RendererControlError> {
        Ok(self.read_array::<1>()?[0])
    }

    fn read_u16(&mut self) -> Result<u16, RendererControlError> {
        Ok(u16::from_be_bytes(self.read_array()?))
    }

    fn read_u32(&mut self) -> Result<u32, RendererControlError> {
        Ok(u32::from_be_bytes(self.read_array()?))
    }

    fn read_u64(&mut self) -> Result<u64, RendererControlError> {
        Ok(u64::from_be_bytes(self.read_array()?))
    }

    fn read_uuid(&mut self) -> Result<Uuid, RendererControlError> {
        Ok(Uuid::from_bytes(self.read_array()?))
    }
}

pub struct RendererControlEncoder {
    direction: RendererControlDirection,
    next_sequence: Option<u64>,
}

impl RendererControlEncoder {
    pub const fn new(direction: RendererControlDirection) -> Self {
        Self { direction, next_sequence: Some(1) }
    }

    pub fn encode(
        &mut self,
        message: RendererControlMessage,
    ) -> Result<Vec<u8>, RendererControlError> {
        if message.direction() != self.direction {
            return Err(RendererControlError::UnexpectedDirection);
        }
        let sequence = self.next_sequence.ok_or(RendererControlError::SequenceExhausted)?;
        let frame = RendererControlWire::encode(&RendererControlEnvelope::new(
            self.direction,
            sequence,
            message,
        )?)?;
        self.next_sequence = sequence.checked_add(1);
        Ok(frame)
    }
}

pub struct RendererControlIncrementalDecoder {
    expected_direction: RendererControlDirection,
    buffer: Vec<u8>,
    expected_frame_length: Option<usize>,
    next_sequence: Option<u64>,
    failed: bool,
    maximum_observed_buffered_byte_count: usize,
}

impl RendererControlIncrementalDecoder {
    pub const fn new(expected_direction: RendererControlDirection) -> Self {
        Self {
            expected_direction,
            buffer: Vec::new(),
            expected_frame_length: None,
            next_sequence: Some(1),
            failed: false,
            maximum_observed_buffered_byte_count: 0,
        }
    }

    pub fn buffered_byte_count(&self) -> usize {
        self.buffer.len()
    }

    pub fn maximum_observed_buffered_byte_count(&self) -> usize {
        self.maximum_observed_buffered_byte_count
    }

    pub fn feed(
        &mut self,
        bytes: &[u8],
    ) -> Result<Vec<RendererControlEnvelope>, RendererControlError> {
        if self.failed {
            return Err(RendererControlError::DecoderFailed);
        }
        match self.feed_validated(bytes) {
            Ok(envelopes) => Ok(envelopes),
            Err(error) => {
                self.failed = true;
                self.buffer.clear();
                self.buffer.shrink_to_fit();
                self.expected_frame_length = None;
                Err(error)
            }
        }
    }

    pub fn finish(&mut self) -> Result<(), RendererControlError> {
        if self.failed {
            return Err(RendererControlError::DecoderFailed);
        }
        if !self.buffer.is_empty() {
            self.failed = true;
            self.buffer.clear();
            self.buffer.shrink_to_fit();
            self.expected_frame_length = None;
            return Err(RendererControlError::TruncatedFrame);
        }
        Ok(())
    }

    fn feed_validated(
        &mut self,
        bytes: &[u8],
    ) -> Result<Vec<RendererControlEnvelope>, RendererControlError> {
        let mut envelopes = Vec::new();
        let mut input_offset = 0;
        while input_offset < bytes.len() {
            let target_length =
                self.expected_frame_length.unwrap_or(RENDERER_CONTROL_HEADER_LENGTH);
            let needed = target_length - self.buffer.len();
            let copy_count = needed.min(bytes.len() - input_offset);
            self.buffer.extend_from_slice(&bytes[input_offset..input_offset + copy_count]);
            input_offset += copy_count;
            self.maximum_observed_buffered_byte_count =
                self.maximum_observed_buffered_byte_count.max(self.buffer.len());

            if self.expected_frame_length.is_none()
                && self.buffer.len() == RENDERER_CONTROL_HEADER_LENGTH
            {
                let (direction, sequence, frame_length) =
                    RendererControlWire::inspect_header(&self.buffer)?;
                if direction != self.expected_direction {
                    return Err(RendererControlError::UnexpectedDirection);
                }
                let expected = self.next_sequence.ok_or(RendererControlError::SequenceExhausted)?;
                if sequence != expected {
                    return Err(RendererControlError::InvalidSequence {
                        expected,
                        actual: sequence,
                    });
                }
                if frame_length > MAXIMUM_RENDERER_CONTROL_FRAME_LENGTH {
                    return Err(RendererControlError::InvalidPayloadLength);
                }
                self.expected_frame_length = Some(frame_length);
            }

            if self.expected_frame_length == Some(self.buffer.len()) {
                let frame = std::mem::take(&mut self.buffer);
                let envelope = RendererControlWire::decode(&frame)?;
                if envelope.direction != self.expected_direction {
                    return Err(RendererControlError::UnexpectedDirection);
                }
                let expected = self.next_sequence.ok_or(RendererControlError::SequenceExhausted)?;
                if envelope.sequence != expected {
                    return Err(RendererControlError::InvalidSequence {
                        expected,
                        actual: envelope.sequence,
                    });
                }
                self.next_sequence = expected.checked_add(1);
                self.expected_frame_length = None;
                envelopes.push(envelope);
            }
        }
        Ok(envelopes)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RendererControlSessionPhase {
    AwaitingBootstrap,
    AwaitingReady,
    Active,
    Terminal,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct RendererPresentationFence {
    terminal_id: Uuid,
    terminal_epoch: u64,
    presentation_id: Uuid,
    presentation_generation: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct RendererPresentationLifetime {
    presentation_id: Uuid,
    presentation_generation: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct PendingRemovalAcknowledgement {
    fence: RendererPresentationFence,
    acknowledgements_due: u64,
    retained_for_late_release: bool,
}

impl From<&RendererPresentationAttachment> for RendererPresentationFence {
    fn from(value: &RendererPresentationAttachment) -> Self {
        Self {
            terminal_id: value.terminal_id,
            terminal_epoch: value.terminal_epoch,
            presentation_id: value.presentation_id,
            presentation_generation: value.presentation_generation,
        }
    }
}

#[derive(Default)]
struct RendererPresentationGenerationTombstones {
    highest: std::collections::HashMap<Uuid, u64>,
    insertion_order: VecDeque<(Uuid, u64)>,
}

impl RendererPresentationGenerationTombstones {
    fn highest(&self, presentation_id: Uuid) -> Option<u64> {
        self.highest.get(&presentation_id).copied()
    }

    fn record(&mut self, presentation_id: Uuid, generation: u64) {
        self.highest.insert(presentation_id, generation);
        self.insertion_order.push_back((presentation_id, generation));
        while self.insertion_order.len() > MAXIMUM_PRESENTATION_GENERATION_TOMBSTONES
            || self.logical_byte_count() > MAXIMUM_PRESENTATION_GENERATION_TOMBSTONE_BYTES
        {
            self.evict_oldest();
        }
        while !self.insertion_order.is_empty()
            && self.retained_byte_count() > MAXIMUM_PRESENTATION_GENERATION_TOMBSTONE_BYTES
        {
            let target = self.insertion_order.len().saturating_mul(3) / 4;
            while self.insertion_order.len() > target {
                self.evict_oldest();
            }
            self.highest.shrink_to_fit();
            self.insertion_order.shrink_to_fit();
        }
    }

    fn clear(&mut self) {
        *self = Self::default();
    }

    fn evict_oldest(&mut self) {
        let Some((retired_id, retired_generation)) = self.insertion_order.pop_front() else {
            return;
        };
        if self.highest.get(&retired_id) == Some(&retired_generation) {
            self.highest.remove(&retired_id);
        }
    }

    fn logical_byte_count(&self) -> usize {
        self.insertion_order
            .len()
            .saturating_mul(size_of::<(Uuid, u64)>())
            .saturating_add(self.highest.len().saturating_mul(size_of::<(Uuid, u64)>()))
    }

    fn retained_byte_count(&self) -> usize {
        self.insertion_order
            .capacity()
            .saturating_mul(size_of::<(Uuid, u64)>())
            .saturating_add(self.highest.capacity().saturating_mul(size_of::<(Uuid, u64)>()))
    }
}

pub struct RendererControlSessionStateMachine {
    phase: RendererControlSessionPhase,
    bootstrap: Option<RendererBootstrap>,
    presentations: std::collections::HashMap<Uuid, RendererPresentationFence>,
    retired_presentations: VecDeque<RendererPresentationFence>,
    pending_removal_acknowledgements:
        std::collections::HashMap<RendererPresentationLifetime, PendingRemovalAcknowledgement>,
    presentation_generation_tombstones: RendererPresentationGenerationTombstones,
    last_scene_sequences: std::collections::HashMap<Uuid, (u64, u64)>,
    next_daemon_sequence: Option<u64>,
    next_worker_sequence: Option<u64>,
}

impl RendererControlSessionStateMachine {
    pub fn new() -> Self {
        Self {
            phase: RendererControlSessionPhase::AwaitingBootstrap,
            bootstrap: None,
            presentations: std::collections::HashMap::new(),
            retired_presentations: VecDeque::new(),
            pending_removal_acknowledgements: std::collections::HashMap::new(),
            presentation_generation_tombstones: RendererPresentationGenerationTombstones::default(),
            last_scene_sequences: std::collections::HashMap::new(),
            next_daemon_sequence: Some(1),
            next_worker_sequence: Some(1),
        }
    }

    pub const fn is_terminal(&self) -> bool {
        matches!(
            self.phase,
            RendererControlSessionPhase::Terminal | RendererControlSessionPhase::Failed
        )
    }

    pub fn presentation_count(&self) -> usize {
        self.presentations.len()
    }

    pub fn accept(
        &mut self,
        envelope: &RendererControlEnvelope,
    ) -> Result<(), RendererControlError> {
        if self.is_terminal() {
            return Err(RendererControlError::InvalidTransition);
        }
        let result = self.accept_validated(envelope);
        if result.is_err() {
            self.phase = RendererControlSessionPhase::Failed;
            self.presentations.clear();
            self.retired_presentations.clear();
            self.pending_removal_acknowledgements.clear();
            self.presentation_generation_tombstones.clear();
            self.last_scene_sequences.clear();
        }
        result
    }

    fn accept_validated(
        &mut self,
        envelope: &RendererControlEnvelope,
    ) -> Result<(), RendererControlError> {
        let expected = match envelope.direction {
            RendererControlDirection::DaemonToWorker => self.next_daemon_sequence,
            RendererControlDirection::WorkerToDaemon => self.next_worker_sequence,
        }
        .ok_or(RendererControlError::SequenceExhausted)?;
        if envelope.sequence != expected {
            return Err(RendererControlError::InvalidSequence {
                expected,
                actual: envelope.sequence,
            });
        }
        self.transition(envelope)?;
        match envelope.direction {
            RendererControlDirection::DaemonToWorker => {
                self.next_daemon_sequence = expected.checked_add(1);
            }
            RendererControlDirection::WorkerToDaemon => {
                self.next_worker_sequence = expected.checked_add(1);
            }
        }
        Ok(())
    }

    fn transition(
        &mut self,
        envelope: &RendererControlEnvelope,
    ) -> Result<(), RendererControlError> {
        match self.phase {
            RendererControlSessionPhase::AwaitingBootstrap => {
                let RendererControlMessage::Bootstrap(value) = &envelope.message else {
                    return Err(RendererControlError::InvalidTransition);
                };
                if envelope.direction != RendererControlDirection::DaemonToWorker {
                    return Err(RendererControlError::InvalidTransition);
                }
                self.bootstrap = Some(value.clone());
                self.phase = RendererControlSessionPhase::AwaitingReady;
                Ok(())
            }
            RendererControlSessionPhase::AwaitingReady => match envelope.message {
                RendererControlMessage::Ready(_) => {
                    if envelope.direction != RendererControlDirection::WorkerToDaemon {
                        return Err(RendererControlError::InvalidTransition);
                    }
                    self.phase = RendererControlSessionPhase::Active;
                    Ok(())
                }
                RendererControlMessage::Shutdown | RendererControlMessage::Fatal(_) => {
                    self.phase = RendererControlSessionPhase::Terminal;
                    Ok(())
                }
                _ => Err(RendererControlError::InvalidTransition),
            },
            RendererControlSessionPhase::Active => self.transition_active(&envelope.message),
            RendererControlSessionPhase::Terminal | RendererControlSessionPhase::Failed => {
                Err(RendererControlError::InvalidTransition)
            }
        }
    }

    fn transition_active(
        &mut self,
        message: &RendererControlMessage,
    ) -> Result<(), RendererControlError> {
        match message {
            RendererControlMessage::Bootstrap(_) | RendererControlMessage::Ready(_) => {
                Err(RendererControlError::InvalidTransition)
            }
            RendererControlMessage::UpsertPresentation(value) => {
                if let Some(previous) = self.presentations.get(&value.presentation_id)
                    && (previous.terminal_id != value.terminal_id
                        || previous.terminal_epoch != value.terminal_epoch)
                {
                    return Err(RendererControlError::InvalidTransition);
                }
                if let Some(previous_generation) =
                    self.presentation_generation_tombstones.highest(value.presentation_id)
                    && value.presentation_generation <= previous_generation
                {
                    return Err(RendererControlError::InvalidTransition);
                }
                let fence = RendererPresentationFence::from(value);
                if let Some(previous) = self.presentations.insert(value.presentation_id, fence) {
                    self.retire_presentation(previous);
                }
                self.presentation_generation_tombstones
                    .record(value.presentation_id, value.presentation_generation);
                self.last_scene_sequences.remove(&value.presentation_id);
                Ok(())
            }
            RendererControlMessage::RemovePresentation(value) => {
                let lifetime = RendererPresentationLifetime {
                    presentation_id: value.presentation_id,
                    presentation_generation: value.presentation_generation,
                };
                if let Some(attached) = self.presentations.get(&value.presentation_id).copied() {
                    if !presentation_matches(
                        &attached,
                        value.terminal_id,
                        value.terminal_epoch,
                        value.presentation_generation,
                    ) {
                        return Err(RendererControlError::InvalidTransition);
                    }
                    let retired = self
                        .presentations
                        .remove(&value.presentation_id)
                        .ok_or(RendererControlError::InvalidTransition)?;
                    self.retire_presentation(retired);
                    self.pending_removal_acknowledgements.insert(
                        lifetime,
                        PendingRemovalAcknowledgement {
                            fence: retired,
                            acknowledgements_due: 1,
                            retained_for_late_release: true,
                        },
                    );
                    self.last_scene_sequences.remove(&value.presentation_id);
                } else {
                    let Some(pending) = self.pending_removal_acknowledgements.get_mut(&lifetime)
                    else {
                        return Err(RendererControlError::InvalidTransition);
                    };
                    if !presentation_matches(
                        &pending.fence,
                        value.terminal_id,
                        value.terminal_epoch,
                        value.presentation_generation,
                    ) {
                        return Err(RendererControlError::InvalidTransition);
                    }
                    pending.acknowledgements_due = pending
                        .acknowledgements_due
                        .checked_add(1)
                        .ok_or(RendererControlError::SequenceExhausted)?;
                }
                Ok(())
            }
            RendererControlMessage::SemanticScene(value) => {
                self.require_presentation(
                    value.presentation_id,
                    value.terminal_id,
                    value.terminal_epoch,
                    value.presentation_generation,
                )?;
                if let Some((canonical, presentation)) =
                    self.last_scene_sequences.get(&value.presentation_id)
                    && (value.canonical_sequence < *canonical
                        || value.presentation_sequence < *presentation)
                {
                    return Err(RendererControlError::InvalidTransition);
                }
                self.last_scene_sequences.insert(
                    value.presentation_id,
                    (value.canonical_sequence, value.presentation_sequence),
                );
                Ok(())
            }
            RendererControlMessage::FrameRelease(value) => {
                let Some(bootstrap) = &self.bootstrap else {
                    return Err(RendererControlError::InvalidTransition);
                };
                if value.daemon_instance_id != bootstrap.daemon_instance_id
                    || value.renderer_epoch != bootstrap.renderer_epoch
                {
                    return Err(RendererControlError::InvalidTransition);
                }
                self.require_active_or_retired_presentation(
                    value.presentation_id,
                    value.terminal_id,
                    value.terminal_epoch,
                    value.presentation_generation,
                )
            }
            RendererControlMessage::NeedsFullScene(value) => self.require_presentation(
                value.presentation_id,
                value.terminal_id,
                value.terminal_epoch,
                value.presentation_generation,
            ),
            RendererControlMessage::PresentationReady(value) => {
                self.require_presentation(
                    value.presentation_id,
                    value.terminal_id,
                    value.terminal_epoch,
                    value.presentation_generation,
                )?;
                let Some((canonical, presentation)) =
                    self.last_scene_sequences.get(&value.presentation_id)
                else {
                    return Err(RendererControlError::InvalidTransition);
                };
                if value.canonical_sequence > *canonical
                    || value.presentation_sequence > *presentation
                {
                    return Err(RendererControlError::InvalidTransition);
                }
                Ok(())
            }
            RendererControlMessage::PresentationRemoved(value) => {
                let lifetime = RendererPresentationLifetime {
                    presentation_id: value.presentation_id,
                    presentation_generation: value.presentation_generation,
                };
                let remove_tombstone = {
                    let Some(pending) = self.pending_removal_acknowledgements.get_mut(&lifetime)
                    else {
                        return Err(RendererControlError::InvalidTransition);
                    };
                    if pending.acknowledgements_due == 0 {
                        return Err(RendererControlError::InvalidTransition);
                    }
                    if !presentation_matches(
                        &pending.fence,
                        value.terminal_id,
                        value.terminal_epoch,
                        value.presentation_generation,
                    ) {
                        return Err(RendererControlError::InvalidTransition);
                    }
                    pending.acknowledgements_due -= 1;
                    pending.acknowledgements_due == 0 && !pending.retained_for_late_release
                };
                if remove_tombstone {
                    self.pending_removal_acknowledgements.remove(&lifetime);
                }
                Ok(())
            }
            RendererControlMessage::Shutdown | RendererControlMessage::Fatal(_) => {
                self.presentations.clear();
                self.retired_presentations = VecDeque::new();
                self.pending_removal_acknowledgements.clear();
                self.presentation_generation_tombstones.clear();
                self.last_scene_sequences.clear();
                self.phase = RendererControlSessionPhase::Terminal;
                Ok(())
            }
        }
    }

    fn require_presentation(
        &self,
        presentation_id: Uuid,
        terminal_id: Uuid,
        terminal_epoch: u64,
        presentation_generation: u64,
    ) -> Result<(), RendererControlError> {
        let Some(attached) = self.presentations.get(&presentation_id) else {
            return Err(RendererControlError::InvalidTransition);
        };
        if !presentation_matches(attached, terminal_id, terminal_epoch, presentation_generation) {
            return Err(RendererControlError::InvalidTransition);
        }
        Ok(())
    }

    fn require_active_or_retired_presentation(
        &self,
        presentation_id: Uuid,
        terminal_id: Uuid,
        terminal_epoch: u64,
        presentation_generation: u64,
    ) -> Result<(), RendererControlError> {
        if self.presentations.get(&presentation_id).is_some_and(|attached| {
            presentation_matches(attached, terminal_id, terminal_epoch, presentation_generation)
        }) || self.retired_presentations.iter().rev().any(|attached| {
            attached.presentation_id == presentation_id
                && presentation_matches(
                    attached,
                    terminal_id,
                    terminal_epoch,
                    presentation_generation,
                )
        }) {
            Ok(())
        } else {
            Err(RendererControlError::InvalidTransition)
        }
    }

    fn retire_presentation(&mut self, presentation: RendererPresentationFence) {
        while self.retired_presentations.len() >= MAXIMUM_RETIRED_PRESENTATION_FENCES
            || self
                .retired_presentations
                .len()
                .saturating_add(1)
                .saturating_mul(size_of::<RendererPresentationFence>())
                > MAXIMUM_RETIRED_PRESENTATION_FENCE_BYTES
        {
            self.evict_oldest_retired_presentation();
        }
        self.retired_presentations.push_back(presentation);
        while !self.retired_presentations.is_empty()
            && self.retired_presentation_byte_count() > MAXIMUM_RETIRED_PRESENTATION_FENCE_BYTES
        {
            self.evict_oldest_retired_presentation();
            self.retired_presentations.shrink_to_fit();
        }
    }

    fn evict_oldest_retired_presentation(&mut self) {
        let Some(retired) = self.retired_presentations.pop_front() else { return };
        let lifetime = RendererPresentationLifetime {
            presentation_id: retired.presentation_id,
            presentation_generation: retired.presentation_generation,
        };
        let remove_tombstone =
            if let Some(pending) = self.pending_removal_acknowledgements.get_mut(&lifetime) {
                pending.retained_for_late_release = false;
                pending.acknowledgements_due == 0
            } else {
                false
            };
        if remove_tombstone {
            self.pending_removal_acknowledgements.remove(&lifetime);
        }
    }

    fn retired_presentation_byte_count(&self) -> usize {
        self.retired_presentations.capacity().saturating_mul(size_of::<RendererPresentationFence>())
    }
}

impl Default for RendererControlSessionStateMachine {
    fn default() -> Self {
        Self::new()
    }
}

fn presentation_matches(
    attached: &RendererPresentationFence,
    terminal_id: Uuid,
    terminal_epoch: u64,
    presentation_generation: u64,
) -> bool {
    attached.terminal_id == terminal_id
        && attached.terminal_epoch == terminal_epoch
        && attached.presentation_generation == presentation_generation
}

#[cfg(test)]
mod tests {
    use super::*;

    fn uuid(value: &str) -> Uuid {
        Uuid::parse_str(value).expect("valid fixture UUID")
    }

    fn daemon_id() -> Uuid {
        uuid("11111111-1111-1111-1111-111111111111")
    }

    fn workspace_id() -> Uuid {
        uuid("22222222-2222-2222-2222-222222222222")
    }

    fn terminal_a() -> Uuid {
        uuid("33333333-3333-3333-3333-333333333333")
    }

    fn terminal_b() -> Uuid {
        uuid("44444444-4444-4444-4444-444444444444")
    }

    fn presentation_a() -> Uuid {
        uuid("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    }

    fn presentation_b() -> Uuid {
        uuid("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
    }

    fn bootstrap() -> RendererBootstrap {
        RendererBootstrap {
            daemon_instance_id: daemon_id(),
            workspace_id: workspace_id(),
            renderer_epoch: 7,
        }
    }

    fn ready() -> RendererWorkerReady {
        RendererWorkerReady {
            process_id: 12_345,
            effective_user_id: 501,
            scene_capabilities: RendererSceneCapabilities::FULL_SCENE
                .union(RendererSceneCapabilities::CANONICAL_DELTA)
                .union(RendererSceneCapabilities::PRESENTATION_DELTA),
        }
    }

    fn attachment(
        terminal_id: Uuid,
        presentation_id: Uuid,
        generation: u64,
        config: Vec<u8>,
    ) -> RendererPresentationAttachment {
        RendererPresentationAttachment {
            terminal_id,
            terminal_epoch: 9,
            presentation_id,
            presentation_generation: generation,
            width: 1_280,
            height: 800,
            backing_scale_factor: 2.0,
            pixel_format: RendererPixelFormat::Bgra8Unorm,
            color_space: RendererColorSpace::DisplayP3,
            frame_endpoint_service: "dev.cmux.renderer.fixture".to_owned(),
            frame_endpoint_capability: vec![0x5a; CAPABILITY_LENGTH],
            resolved_config_revision: 11,
            resolved_config: config,
        }
    }

    fn scene(
        terminal_id: Uuid,
        presentation_id: Uuid,
        generation: u64,
        bytes: Vec<u8>,
    ) -> RendererSemanticScene {
        RendererSemanticScene {
            terminal_id,
            terminal_epoch: 9,
            presentation_id,
            presentation_generation: generation,
            canonical_sequence: 20,
            presentation_sequence: 5,
            bytes,
        }
    }

    fn release(terminal_id: Uuid, presentation_id: Uuid, generation: u64) -> RendererFrameRelease {
        RendererFrameRelease {
            daemon_instance_id: daemon_id(),
            renderer_epoch: 7,
            terminal_id,
            terminal_epoch: 9,
            terminal_sequence: 20,
            presentation_id,
            presentation_generation: generation,
            frame_sequence: 3,
            surface_id: 42,
        }
    }

    fn presentation_ready(
        terminal_id: Uuid,
        presentation_id: Uuid,
        generation: u64,
    ) -> RendererPresentationReady {
        RendererPresentationReady {
            terminal_id,
            terminal_epoch: 9,
            presentation_id,
            presentation_generation: generation,
            canonical_sequence: 20,
            presentation_sequence: 5,
            columns: 120,
            rows: 40,
            cell_width: 18,
            cell_height: 36,
            padding_top: 8,
            padding_right: 10,
            padding_bottom: 12,
            padding_left: 14,
        }
    }

    fn presentation_removed(
        terminal_id: Uuid,
        presentation_id: Uuid,
        generation: u64,
    ) -> RendererPresentationRemoved {
        RendererPresentationRemoved {
            terminal_id,
            terminal_epoch: 9,
            presentation_id,
            presentation_generation: generation,
        }
    }

    fn envelope(message: RendererControlMessage, sequence: u64) -> RendererControlEnvelope {
        RendererControlEnvelope::new(message.direction(), sequence, message)
            .expect("valid fixture envelope")
    }

    fn decode_hex(value: &str) -> Vec<u8> {
        let digits =
            value.chars().filter(|character| !character.is_whitespace()).collect::<Vec<_>>();
        assert_eq!(digits.len() % 2, 0);
        digits
            .chunks_exact(2)
            .map(|pair| {
                u8::from_str_radix(&pair.iter().collect::<String>(), 16).expect("valid fixture hex")
            })
            .collect()
    }

    #[test]
    fn swift_golden_bootstrap_uses_exact_uuid_bytes_and_network_order() {
        let fixture = include_str!(
            "../../../../Packages/macOS/CmuxTerminalRenderTransport/Tests/\
             CmuxTerminalRendererControlTests/Fixtures/renderer-control-v1.hex"
        );
        let expected = decode_hex(fixture);
        let message = RendererControlMessage::Bootstrap(RendererBootstrap {
            daemon_instance_id: uuid("00112233-4455-6677-8899-aabbccddeeff"),
            workspace_id: uuid("ffeeddcc-bbaa-9988-7766-554433221100"),
            renderer_epoch: 0x0102_0304_0506_0708,
        });
        let value = envelope(message, 1);
        assert_eq!(RendererControlWire::encode(&value).unwrap(), expected);
        assert_eq!(RendererControlWire::decode(&expected).unwrap(), value);
    }

    #[test]
    fn swift_variable_payload_and_worker_reply_goldens_match() {
        let upsert_fixture = include_str!(
            "../../../../Packages/macOS/CmuxTerminalRenderTransport/Tests/\
             CmuxTerminalRendererControlTests/Fixtures/renderer-control-v1-upsert.hex"
        );
        let mut value = attachment(
            uuid("11112222-3333-4444-5555-666677778888"),
            uuid("9999aaaa-bbbb-cccc-dddd-eeeeffff0001"),
            0x2122_2324_2526_2728,
            vec![0xde, 0xad, 0xbe, 0xef],
        );
        value.terminal_epoch = 0x1112_1314_1516_1718;
        value.frame_endpoint_service = "svc".to_owned();
        value.frame_endpoint_capability = (0_u8..32).collect();
        value.resolved_config_revision = 0x3132_3334_3536_3738;
        let upsert_envelope = envelope(RendererControlMessage::UpsertPresentation(value), 1);
        let expected = decode_hex(upsert_fixture);
        assert_eq!(RendererControlWire::encode(&upsert_envelope).unwrap(), expected);
        assert_eq!(RendererControlWire::decode(&expected).unwrap(), upsert_envelope);

        let ready_fixture = include_str!(
            "../../../../Packages/macOS/CmuxTerminalRenderTransport/Tests/\
             CmuxTerminalRendererControlTests/Fixtures/renderer-control-v1-ready.hex"
        );
        let ready_envelope = envelope(
            RendererControlMessage::Ready(RendererWorkerReady {
                process_id: 0x0102_0304,
                effective_user_id: 0x0506_0708,
                scene_capabilities: RendererSceneCapabilities::ALL_KNOWN,
            }),
            1,
        );
        let expected = decode_hex(ready_fixture);
        assert_eq!(RendererControlWire::encode(&ready_envelope).unwrap(), expected);
        assert_eq!(RendererControlWire::decode(&expected).unwrap(), ready_envelope);
    }

    #[test]
    fn every_typed_message_round_trips() {
        let messages = [
            RendererControlMessage::Bootstrap(bootstrap()),
            RendererControlMessage::UpsertPresentation(attachment(
                terminal_a(),
                presentation_a(),
                1,
                vec![1, 2, 3],
            )),
            RendererControlMessage::RemovePresentation(RendererPresentationRemoval {
                terminal_id: terminal_a(),
                terminal_epoch: 9,
                presentation_id: presentation_a(),
                presentation_generation: 1,
            }),
            RendererControlMessage::SemanticScene(scene(
                terminal_a(),
                presentation_a(),
                1,
                vec![1, 2, 3],
            )),
            RendererControlMessage::FrameRelease(release(terminal_a(), presentation_a(), 1)),
            RendererControlMessage::Shutdown,
            RendererControlMessage::Ready(ready()),
            RendererControlMessage::NeedsFullScene(RendererNeedsFullScene {
                terminal_id: terminal_a(),
                terminal_epoch: 9,
                presentation_id: presentation_a(),
                presentation_generation: 1,
                last_canonical_sequence: 19,
                last_presentation_sequence: 4,
                reason: RendererNeedsFullSceneReason::SequenceGap,
            }),
            RendererControlMessage::Fatal(RendererFatal {
                code: RendererFatalCode::ResourceExhausted,
                diagnostic: "bounded".to_owned(),
            }),
            RendererControlMessage::PresentationReady(presentation_ready(
                terminal_a(),
                presentation_a(),
                1,
            )),
            RendererControlMessage::PresentationRemoved(presentation_removed(
                terminal_a(),
                presentation_a(),
                1,
            )),
        ];
        for message in messages {
            let expected_length = message.encoded_frame_length().unwrap();
            let envelope = envelope(message, 1);
            let encoded = RendererControlWire::encode(&envelope).unwrap();
            assert_eq!(encoded.len(), expected_length);
            assert_eq!(RendererControlWire::decode(&encoded).unwrap(), envelope);
        }
    }

    #[test]
    fn presentation_ready_has_the_exact_fixed_payload_and_requires_an_applied_scene() {
        let metrics = presentation_ready(terminal_a(), presentation_a(), 1);
        let encoded = RendererControlWire::encode(&envelope(
            RendererControlMessage::PresentationReady(metrics.clone()),
            1,
        ))
        .unwrap();
        assert_eq!(encoded.len(), RENDERER_CONTROL_HEADER_LENGTH + 104);
        assert_eq!(
            RendererControlWire::decode(&encoded).unwrap().message,
            RendererControlMessage::PresentationReady(metrics.clone())
        );

        let mut state = RendererControlSessionStateMachine::new();
        state.accept(&envelope(RendererControlMessage::Bootstrap(bootstrap()), 1)).unwrap();
        state.accept(&envelope(RendererControlMessage::Ready(ready()), 1)).unwrap();
        state
            .accept(&envelope(
                RendererControlMessage::UpsertPresentation(attachment(
                    terminal_a(),
                    presentation_a(),
                    1,
                    vec![],
                )),
                2,
            ))
            .unwrap();
        assert_eq!(
            state
                .accept(&envelope(RendererControlMessage::PresentationReady(metrics.clone()), 2,))
                .unwrap_err(),
            RendererControlError::InvalidTransition
        );

        let mut applied = RendererControlSessionStateMachine::new();
        applied.accept(&envelope(RendererControlMessage::Bootstrap(bootstrap()), 1)).unwrap();
        applied.accept(&envelope(RendererControlMessage::Ready(ready()), 1)).unwrap();
        applied
            .accept(&envelope(
                RendererControlMessage::UpsertPresentation(attachment(
                    terminal_a(),
                    presentation_a(),
                    1,
                    vec![],
                )),
                2,
            ))
            .unwrap();
        applied
            .accept(&envelope(
                RendererControlMessage::SemanticScene(scene(
                    terminal_a(),
                    presentation_a(),
                    1,
                    vec![],
                )),
                3,
            ))
            .unwrap();
        applied.accept(&envelope(RendererControlMessage::PresentationReady(metrics), 2)).unwrap();
    }

    #[test]
    fn fragmentation_and_coalescing_preserve_contiguous_sequences() {
        let mut encoder = RendererControlEncoder::new(RendererControlDirection::DaemonToWorker);
        let first = encoder.encode(RendererControlMessage::Bootstrap(bootstrap())).unwrap();
        let second = encoder.encode(RendererControlMessage::Shutdown).unwrap();

        let mut fragmented =
            RendererControlIncrementalDecoder::new(RendererControlDirection::DaemonToWorker);
        let mut decoded = Vec::new();
        for byte in &first {
            decoded.extend(fragmented.feed(std::slice::from_ref(byte)).unwrap());
        }
        assert_eq!(decoded.len(), 1);
        assert_eq!(fragmented.buffered_byte_count(), 0);
        assert_eq!(fragmented.maximum_observed_buffered_byte_count(), first.len());

        let mut coalesced =
            RendererControlIncrementalDecoder::new(RendererControlDirection::DaemonToWorker);
        let both = [first, second].concat();
        let decoded = coalesced.feed(&both).unwrap();
        assert_eq!(decoded.iter().map(|value| value.sequence).collect::<Vec<_>>(), [1, 2]);
        assert!(coalesced.maximum_observed_buffered_byte_count() < both.len());
        coalesced.finish().unwrap();
    }

    #[test]
    fn replay_gap_truncation_and_oversized_header_fail_closed() {
        let first = RendererControlWire::encode(&envelope(
            RendererControlMessage::Bootstrap(bootstrap()),
            1,
        ))
        .unwrap();
        let mut replay =
            RendererControlIncrementalDecoder::new(RendererControlDirection::DaemonToWorker);
        assert_eq!(replay.feed(&first).unwrap().len(), 1);
        assert_eq!(
            replay.feed(&first).unwrap_err(),
            RendererControlError::InvalidSequence { expected: 2, actual: 1 }
        );
        assert_eq!(replay.feed(&[]).unwrap_err(), RendererControlError::DecoderFailed);

        let second = RendererControlWire::encode(&envelope(
            RendererControlMessage::Bootstrap(bootstrap()),
            2,
        ))
        .unwrap();
        let mut gap =
            RendererControlIncrementalDecoder::new(RendererControlDirection::DaemonToWorker);
        assert_eq!(
            gap.feed(&second).unwrap_err(),
            RendererControlError::InvalidSequence { expected: 1, actual: 2 }
        );

        let mut truncated =
            RendererControlIncrementalDecoder::new(RendererControlDirection::DaemonToWorker);
        assert!(truncated.feed(&first[..first.len() - 1]).unwrap().is_empty());
        assert_eq!(truncated.finish().unwrap_err(), RendererControlError::TruncatedFrame);

        let mut oversized = RendererControlWire::encode(&envelope(
            RendererControlMessage::SemanticScene(scene(terminal_a(), presentation_a(), 1, vec![])),
            1,
        ))
        .unwrap();
        let payload_length = (80 + MAXIMUM_SEMANTIC_SCENE_LENGTH + 1) as u64;
        oversized[24..32].copy_from_slice(&payload_length.to_be_bytes());
        let mut decoder =
            RendererControlIncrementalDecoder::new(RendererControlDirection::DaemonToWorker);
        assert_eq!(
            decoder.feed(&oversized[..RENDERER_CONTROL_HEADER_LENGTH]).unwrap_err(),
            RendererControlError::InvalidPayloadLength
        );
        assert_eq!(decoder.maximum_observed_buffered_byte_count(), RENDERER_CONTROL_HEADER_LENGTH);
    }

    #[test]
    fn scene_config_and_diagnostic_boundaries_are_exact() {
        {
            let value = envelope(
                RendererControlMessage::SemanticScene(scene(
                    terminal_a(),
                    presentation_a(),
                    1,
                    vec![0xa5; MAXIMUM_SEMANTIC_SCENE_LENGTH],
                )),
                1,
            );
            let encoded = RendererControlWire::encode(&value).unwrap();
            assert_eq!(encoded.len(), MAXIMUM_RENDERER_CONTROL_FRAME_LENGTH);
            assert_eq!(RendererControlWire::decode(&encoded).unwrap(), value);
        }
        let one_over_scene = envelope(
            RendererControlMessage::SemanticScene(scene(
                terminal_a(),
                presentation_a(),
                1,
                vec![0; MAXIMUM_SEMANTIC_SCENE_LENGTH + 1],
            )),
            1,
        );
        assert_eq!(
            one_over_scene.message.encoded_frame_length().unwrap_err(),
            RendererControlError::SemanticSceneTooLarge
        );
        assert_eq!(
            RendererControlWire::encode(&one_over_scene).unwrap_err(),
            RendererControlError::SemanticSceneTooLarge
        );

        let config = attachment(
            terminal_a(),
            presentation_a(),
            1,
            vec![0x5c; MAXIMUM_RESOLVED_CONFIG_LENGTH],
        );
        assert!(
            RendererControlWire::encode(&envelope(
                RendererControlMessage::UpsertPresentation(config),
                1,
            ))
            .is_ok()
        );
        let config_over = attachment(
            terminal_a(),
            presentation_a(),
            1,
            vec![0; MAXIMUM_RESOLVED_CONFIG_LENGTH + 1],
        );
        assert_eq!(
            RendererControlWire::encode(&envelope(
                RendererControlMessage::UpsertPresentation(config_over),
                1,
            ))
            .unwrap_err(),
            RendererControlError::ResolvedConfigTooLarge
        );

        let diagnostic = RendererFatal {
            code: RendererFatalCode::RenderFailure,
            diagnostic: "x".repeat(MAXIMUM_DIAGNOSTIC_LENGTH),
        };
        assert!(
            RendererControlWire::encode(&envelope(RendererControlMessage::Fatal(diagnostic), 1,))
                .is_ok()
        );
        let diagnostic_over = RendererFatal {
            code: RendererFatalCode::RenderFailure,
            diagnostic: "x".repeat(MAXIMUM_DIAGNOSTIC_LENGTH + 1),
        };
        assert_eq!(
            RendererControlWire::encode(&envelope(
                RendererControlMessage::Fatal(diagnostic_over),
                1,
            ))
            .unwrap_err(),
            RendererControlError::DiagnosticTooLarge
        );
    }

    #[test]
    fn unknown_header_payload_and_enum_fields_are_rejected() {
        let original = RendererControlWire::encode(&envelope(
            RendererControlMessage::Bootstrap(bootstrap()),
            1,
        ))
        .unwrap();
        for (offset, replacement) in [(4, 2), (9, 0x7f), (10, 1), (12, 1)] {
            let mut frame = original.clone();
            frame[offset] = replacement;
            assert!(RendererControlWire::decode(&frame).is_err());
        }
        let mut reserved = original;
        let last = reserved.len() - 1;
        reserved[last] = 1;
        assert_eq!(
            RendererControlWire::decode(&reserved).unwrap_err(),
            RendererControlError::NonzeroReserved
        );

        let mut ready_frame =
            RendererControlWire::encode(&envelope(RendererControlMessage::Ready(ready()), 1))
                .unwrap();
        ready_frame[47] = 0x83;
        assert_eq!(
            RendererControlWire::decode(&ready_frame).unwrap_err(),
            RendererControlError::UnknownSceneCapabilities(0x83)
        );
    }

    #[test]
    fn lifecycle_rejects_pre_attach_cross_presentation_release_and_post_detach_scene() {
        let mut pre_attach = RendererControlSessionStateMachine::new();
        assert_eq!(
            pre_attach.accept(&envelope(RendererControlMessage::Ready(ready()), 1)).unwrap_err(),
            RendererControlError::InvalidTransition
        );

        let mut state = RendererControlSessionStateMachine::new();
        state.accept(&envelope(RendererControlMessage::Bootstrap(bootstrap()), 1)).unwrap();
        state.accept(&envelope(RendererControlMessage::Ready(ready()), 1)).unwrap();
        state
            .accept(&envelope(
                RendererControlMessage::UpsertPresentation(attachment(
                    terminal_a(),
                    presentation_a(),
                    1,
                    vec![],
                )),
                2,
            ))
            .unwrap();
        state
            .accept(&envelope(
                RendererControlMessage::UpsertPresentation(attachment(
                    terminal_b(),
                    presentation_b(),
                    1,
                    vec![],
                )),
                3,
            ))
            .unwrap();
        let crossed = release(terminal_a(), presentation_b(), 1);
        assert_eq!(
            state.accept(&envelope(RendererControlMessage::FrameRelease(crossed), 4)).unwrap_err(),
            RendererControlError::InvalidTransition
        );

        let mut detached = RendererControlSessionStateMachine::new();
        detached.accept(&envelope(RendererControlMessage::Bootstrap(bootstrap()), 1)).unwrap();
        detached.accept(&envelope(RendererControlMessage::Ready(ready()), 1)).unwrap();
        detached
            .accept(&envelope(
                RendererControlMessage::UpsertPresentation(attachment(
                    terminal_a(),
                    presentation_a(),
                    1,
                    vec![],
                )),
                2,
            ))
            .unwrap();
        detached
            .accept(&envelope(
                RendererControlMessage::RemovePresentation(RendererPresentationRemoval {
                    terminal_id: terminal_a(),
                    terminal_epoch: 9,
                    presentation_id: presentation_a(),
                    presentation_generation: 1,
                }),
                3,
            ))
            .unwrap();
        assert_eq!(detached.presentation_count(), 0);
        detached
            .accept(&envelope(
                RendererControlMessage::PresentationRemoved(presentation_removed(
                    terminal_a(),
                    presentation_a(),
                    1,
                )),
                2,
            ))
            .unwrap();
        detached
            .accept(&envelope(
                RendererControlMessage::FrameRelease(release(terminal_a(), presentation_a(), 1)),
                4,
            ))
            .unwrap();
        assert_eq!(
            detached
                .accept(&envelope(
                    RendererControlMessage::SemanticScene(scene(
                        terminal_a(),
                        presentation_a(),
                        1,
                        vec![],
                    )),
                    5,
                ))
                .unwrap_err(),
            RendererControlError::InvalidTransition
        );
        assert!(detached.is_terminal());
    }

    #[test]
    fn exact_removal_can_be_retransmitted_after_a_lost_acknowledgement() {
        let mut state = RendererControlSessionStateMachine::new();
        state.accept(&envelope(RendererControlMessage::Bootstrap(bootstrap()), 1)).unwrap();
        state.accept(&envelope(RendererControlMessage::Ready(ready()), 1)).unwrap();
        state
            .accept(&envelope(
                RendererControlMessage::UpsertPresentation(attachment(
                    terminal_a(),
                    presentation_a(),
                    1,
                    vec![],
                )),
                2,
            ))
            .unwrap();
        let removal = RendererPresentationRemoval {
            terminal_id: terminal_a(),
            terminal_epoch: 9,
            presentation_id: presentation_a(),
            presentation_generation: 1,
        };
        state
            .accept(&envelope(RendererControlMessage::RemovePresentation(removal.clone()), 3))
            .unwrap();
        state
            .accept(&envelope(
                RendererControlMessage::PresentationRemoved(presentation_removed(
                    terminal_a(),
                    presentation_a(),
                    1,
                )),
                2,
            ))
            .unwrap();

        state.accept(&envelope(RendererControlMessage::RemovePresentation(removal), 4)).unwrap();
        state
            .accept(&envelope(
                RendererControlMessage::PresentationRemoved(presentation_removed(
                    terminal_a(),
                    presentation_a(),
                    1,
                )),
                3,
            ))
            .unwrap();

        assert!(!state.is_terminal());
        assert_eq!(state.presentation_count(), 0);
    }

    #[test]
    fn exact_frame_release_for_a_retired_generation_remains_valid() {
        let mut state = RendererControlSessionStateMachine::new();
        state.accept(&envelope(RendererControlMessage::Bootstrap(bootstrap()), 1)).unwrap();
        state.accept(&envelope(RendererControlMessage::Ready(ready()), 1)).unwrap();
        state
            .accept(&envelope(
                RendererControlMessage::UpsertPresentation(attachment(
                    terminal_a(),
                    presentation_a(),
                    1,
                    vec![],
                )),
                2,
            ))
            .unwrap();
        state
            .accept(&envelope(
                RendererControlMessage::UpsertPresentation(attachment(
                    terminal_a(),
                    presentation_a(),
                    2,
                    vec![],
                )),
                3,
            ))
            .unwrap();

        state
            .accept(&envelope(
                RendererControlMessage::FrameRelease(release(terminal_a(), presentation_a(), 1)),
                4,
            ))
            .unwrap();
    }

    #[test]
    fn presentation_release_fences_and_generation_tombstones_are_compact_and_byte_bounded() {
        let mut state = RendererControlSessionStateMachine::new();
        state.accept(&envelope(RendererControlMessage::Bootstrap(bootstrap()), 1)).unwrap();
        state.accept(&envelope(RendererControlMessage::Ready(ready()), 1)).unwrap();

        state
            .accept(&envelope(
                RendererControlMessage::UpsertPresentation(attachment(
                    terminal_a(),
                    presentation_a(),
                    1,
                    vec![0x5c; MAXIMUM_RESOLVED_CONFIG_LENGTH],
                )),
                2,
            ))
            .unwrap();
        state
            .accept(&envelope(
                RendererControlMessage::UpsertPresentation(attachment(
                    terminal_a(),
                    presentation_a(),
                    2,
                    vec![],
                )),
                3,
            ))
            .unwrap();
        assert_eq!(state.retired_presentations.len(), 1);
        assert!(state.retired_presentation_byte_count() >= size_of::<RendererPresentationFence>());
        assert!(
            state.retired_presentation_byte_count() < MAXIMUM_RESOLVED_CONFIG_LENGTH,
            "retired release fences must not retain resolved configuration"
        );

        let mut sequence = 4_u64;
        let mut worker_sequence = 2_u64;
        for suffix in 1_u128..=12_000 {
            let presentation_id =
                Uuid::from_u128(0x9000_0000_0000_4000_8000_0000_0000_0000 + suffix);
            state
                .accept(&envelope(
                    RendererControlMessage::UpsertPresentation(attachment(
                        terminal_a(),
                        presentation_id,
                        1,
                        vec![],
                    )),
                    sequence,
                ))
                .unwrap();
            sequence += 1;
            state
                .accept(&envelope(
                    RendererControlMessage::RemovePresentation(RendererPresentationRemoval {
                        terminal_id: terminal_a(),
                        terminal_epoch: 9,
                        presentation_id,
                        presentation_generation: 1,
                    }),
                    sequence,
                ))
                .unwrap();
            sequence += 1;
            state
                .accept(&envelope(
                    RendererControlMessage::PresentationRemoved(presentation_removed(
                        terminal_a(),
                        presentation_id,
                        1,
                    )),
                    worker_sequence,
                ))
                .unwrap();
            worker_sequence += 1;
        }

        assert!(state.retired_presentations.len() <= MAXIMUM_RETIRED_PRESENTATION_FENCES);
        assert!(
            state.retired_presentation_byte_count() <= MAXIMUM_RETIRED_PRESENTATION_FENCE_BYTES
        );
        assert!(
            state.presentation_generation_tombstones.insertion_order.len()
                <= MAXIMUM_PRESENTATION_GENERATION_TOMBSTONES
        );
        assert!(
            state.presentation_generation_tombstones.retained_byte_count()
                <= MAXIMUM_PRESENTATION_GENERATION_TOMBSTONE_BYTES
        );
        assert_eq!(state.presentations.len(), 1);
    }

    #[test]
    fn semantic_scene_for_a_retired_generation_is_rejected() {
        let mut state = RendererControlSessionStateMachine::new();
        state.accept(&envelope(RendererControlMessage::Bootstrap(bootstrap()), 1)).unwrap();
        state.accept(&envelope(RendererControlMessage::Ready(ready()), 1)).unwrap();
        state
            .accept(&envelope(
                RendererControlMessage::UpsertPresentation(attachment(
                    terminal_a(),
                    presentation_a(),
                    1,
                    vec![],
                )),
                2,
            ))
            .unwrap();
        state
            .accept(&envelope(
                RendererControlMessage::UpsertPresentation(attachment(
                    terminal_a(),
                    presentation_a(),
                    2,
                    vec![],
                )),
                3,
            ))
            .unwrap();

        assert_eq!(
            state
                .accept(&envelope(
                    RendererControlMessage::SemanticScene(scene(
                        terminal_a(),
                        presentation_a(),
                        1,
                        vec![],
                    )),
                    4,
                ))
                .unwrap_err(),
            RendererControlError::InvalidTransition
        );
    }

    #[test]
    fn shutdown_is_terminal() {
        let mut state = RendererControlSessionStateMachine::new();
        state.accept(&envelope(RendererControlMessage::Bootstrap(bootstrap()), 1)).unwrap();
        state.accept(&envelope(RendererControlMessage::Shutdown, 2)).unwrap();
        assert!(state.is_terminal());
        assert_eq!(
            state.accept(&envelope(RendererControlMessage::Shutdown, 3)).unwrap_err(),
            RendererControlError::InvalidTransition
        );
    }
}
