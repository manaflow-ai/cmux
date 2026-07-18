//! Bounded semantic Ghostty scene attachments for renderer workers.
//!
//! Each attachment owns its own encoder cache. This is required because one
//! renderer can miss a delta without invalidating any other renderer's base.

use std::fmt;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc::{
    Receiver, RecvError, RecvTimeoutError, SyncSender, TryRecvError, TrySendError, sync_channel,
};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use ghostty_vt::{
    EncodedRenderScene, RenderSceneEncoder, RenderSceneError, RenderSceneLimits,
    RenderSceneOptions, SceneSectionKind, Terminal,
};

use crate::{PresentationId, SurfaceUuid};

/// Default number of live semantic scene events retained per attachment.
pub const SEMANTIC_SCENE_EVENT_CAPACITY: usize = 2;

/// Hard upper bound for the caller-selected live event capacity.
pub const SEMANTIC_SCENE_MAX_EVENT_CAPACITY: usize = 8;

/// Exact identity of one daemon-owned terminal state lifetime.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SemanticSceneTerminalIdentity {
    pub terminal_id: SurfaceUuid,
    pub runtime_epoch: u64,
}

impl SemanticSceneTerminalIdentity {
    pub(crate) fn random(terminal_id: SurfaceUuid) -> anyhow::Result<Self> {
        loop {
            let mut bytes = [0_u8; 8];
            getrandom::fill(&mut bytes)
                .map_err(|error| anyhow::anyhow!("generate terminal runtime epoch: {error}"))?;
            let runtime_epoch = u64::from_le_bytes(bytes);
            if runtime_epoch != 0 {
                return Ok(Self { terminal_id, runtime_epoch });
            }
        }
    }
}

/// Exact identity of one renderer presentation lifetime.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SemanticScenePresentationIdentity {
    pub presentation_id: PresentationId,
    pub generation: u64,
}

/// Capture settings fixed for one semantic scene attachment.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SemanticSceneCaptureOptions {
    pub focused: bool,
    pub cursor_blink_visible: bool,
    pub custom_shader_count: u32,
    pub limits: RenderSceneLimits,
}

impl Default for SemanticSceneCaptureOptions {
    fn default() -> Self {
        Self {
            focused: true,
            cursor_blink_visible: true,
            custom_shader_count: 0,
            limits: RenderSceneLimits::default(),
        }
    }
}

/// Inputs required to attach one renderer to one exact terminal presentation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SemanticSceneAttachmentOptions {
    pub terminal: SemanticSceneTerminalIdentity,
    pub presentation: SemanticScenePresentationIdentity,
    pub capture: SemanticSceneCaptureOptions,
    /// Initial visual IME marked text. It is never written to the PTY.
    pub preedit: Option<Arc<str>>,
    pub event_capacity: usize,
}

impl SemanticSceneAttachmentOptions {
    pub fn new(
        terminal: SemanticSceneTerminalIdentity,
        presentation: SemanticScenePresentationIdentity,
    ) -> Self {
        Self {
            terminal,
            presentation,
            capture: SemanticSceneCaptureOptions::default(),
            preedit: None,
            event_capacity: SEMANTIC_SCENE_EVENT_CAPACITY,
        }
    }
}

/// A typed semantic capture failure delivered before the attachment closes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SemanticSceneFailure {
    InvalidInput,
    OutOfMemory,
    LimitExceeded,
    UnsupportedKittyImages,
    UnsupportedCustomShaders,
    RequiresFullSnapshot,
    Internal,
    Unknown(i32),
}

impl From<RenderSceneError> for SemanticSceneFailure {
    fn from(value: RenderSceneError) -> Self {
        match value {
            RenderSceneError::InvalidValue => Self::InvalidInput,
            RenderSceneError::OutOfMemory => Self::OutOfMemory,
            RenderSceneError::LimitExceeded => Self::LimitExceeded,
            RenderSceneError::UnsupportedKittyImages => Self::UnsupportedKittyImages,
            RenderSceneError::UnsupportedCustomShaders => Self::UnsupportedCustomShaders,
            RenderSceneError::RequiresFullSnapshot => Self::RequiresFullSnapshot,
            RenderSceneError::Internal => Self::Internal,
            RenderSceneError::Unknown(code) => Self::Unknown(code),
        }
    }
}

impl fmt::Display for SemanticSceneFailure {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::InvalidInput => "invalid semantic scene input",
            Self::OutOfMemory => "semantic scene allocation failed",
            Self::LimitExceeded => "semantic scene resource limit exceeded",
            Self::UnsupportedKittyImages => "live Kitty images are unsupported",
            Self::UnsupportedCustomShaders => "custom shaders are unsupported",
            Self::RequiresFullSnapshot => "a full semantic scene is required",
            Self::Internal => "semantic scene capture failed",
            Self::Unknown(_) => "unknown semantic scene capture failure",
        })?;
        if let Self::Unknown(code) = self {
            write!(formatter, " ({code})")?;
        }
        Ok(())
    }
}

impl std::error::Error for SemanticSceneFailure {}

/// A failure to create a semantic scene attachment.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SemanticSceneAttachError {
    NotPty,
    TerminalIdentityMismatch,
    InvalidRuntimeEpoch,
    InvalidPresentationIdentity,
    InvalidPresentationGeneration,
    InvalidEventCapacity,
    InvalidContentSequence,
    Capture(SemanticSceneFailure),
}

impl fmt::Display for SemanticSceneAttachError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotPty => formatter.write_str("browser surfaces have no semantic terminal scene"),
            Self::TerminalIdentityMismatch => {
                formatter.write_str("semantic scene terminal identity does not match the surface")
            }
            Self::InvalidRuntimeEpoch => {
                formatter.write_str("semantic scene terminal runtime epoch must be nonzero")
            }
            Self::InvalidPresentationIdentity => {
                formatter.write_str("semantic scene presentation identity must be nonzero")
            }
            Self::InvalidPresentationGeneration => {
                formatter.write_str("semantic scene presentation generation must be nonzero")
            }
            Self::InvalidEventCapacity => write!(
                formatter,
                "semantic scene event capacity must be between 1 and {SEMANTIC_SCENE_MAX_EVENT_CAPACITY}",
            ),
            Self::InvalidContentSequence => {
                formatter.write_str("semantic scene content sequence must be nonzero")
            }
            Self::Capture(error) => write!(formatter, "{error}"),
        }
    }
}

impl std::error::Error for SemanticSceneAttachError {}

/// One pointer-free encoded Ghostty scene and its exact routing fence.
#[derive(Debug)]
pub struct SemanticSceneFrame {
    pub terminal: SemanticSceneTerminalIdentity,
    pub content_sequence: u64,
    pub presentation: SemanticScenePresentationIdentity,
    pub presentation_sequence: u64,
    pub canonical_kind: SceneSectionKind,
    encoded: EncodedRenderScene,
}

impl SemanticSceneFrame {
    /// Borrow the complete Ghostty semantic scene wire payload.
    pub fn as_bytes(&self) -> &[u8] {
        self.encoded.as_bytes()
    }

    /// Return the encoded payload size without copying it.
    pub fn len(&self) -> usize {
        self.encoded.len()
    }

    /// Return whether the native scene encoder produced no payload.
    pub fn is_empty(&self) -> bool {
        self.encoded.is_empty()
    }
}

/// A live event for one semantic renderer attachment.
#[derive(Debug)]
pub enum SemanticSceneEvent {
    Scene(SemanticSceneFrame),
    Failed(SemanticSceneFailure),
}

struct SemanticSceneLifecycleState {
    canceled: AtomicBool,
    force_full: AtomicBool,
    needs_full: AtomicBool,
    presentation_dirty: AtomicBool,
    preedit: Mutex<Option<Arc<str>>>,
    queued_events: AtomicUsize,
    event_capacity: usize,
    fallback_failure: Mutex<Option<SemanticSceneFailure>>,
}

#[derive(Clone)]
struct SemanticSceneLifecycle {
    state: Arc<SemanticSceneLifecycleState>,
    wake: SyncSender<u64>,
}

impl SemanticSceneLifecycle {
    fn new(wake: SyncSender<u64>, event_capacity: usize, preedit: Option<Arc<str>>) -> Self {
        Self {
            state: Arc::new(SemanticSceneLifecycleState {
                canceled: AtomicBool::new(false),
                force_full: AtomicBool::new(false),
                needs_full: AtomicBool::new(false),
                presentation_dirty: AtomicBool::new(false),
                preedit: Mutex::new(preedit),
                queued_events: AtomicUsize::new(0),
                event_capacity,
                fallback_failure: Mutex::new(None),
            }),
            wake,
        }
    }

    fn wake_producer(&self) {
        match self.wake.try_send(0) {
            Ok(()) | Err(TrySendError::Full(_)) | Err(TrySendError::Disconnected(_)) => {}
        }
    }

    fn request_full(&self) {
        if self.is_canceled() {
            return;
        }
        self.state.force_full.store(true, Ordering::Release);
        self.wake_producer();
    }

    fn take_force_full(&self) -> bool {
        self.state.force_full.swap(false, Ordering::AcqRel)
    }

    fn mark_needs_full(&self) {
        self.state.needs_full.store(true, Ordering::Release);
    }

    fn clear_needs_full(&self) {
        self.state.needs_full.store(false, Ordering::Release);
    }

    fn needs_full(&self) -> bool {
        self.state.needs_full.load(Ordering::Acquire)
    }

    fn set_preedit(&self, preedit: Option<Arc<str>>) {
        let mut current = self.state.preedit.lock().unwrap();
        if *current == preedit {
            return;
        }
        *current = preedit;
        self.state.presentation_dirty.store(true, Ordering::Release);
        drop(current);
        self.wake_producer();
    }

    fn preedit(&self) -> Option<Arc<str>> {
        self.state.preedit.lock().unwrap().clone()
    }

    fn take_presentation_dirty(&self) -> bool {
        self.state.presentation_dirty.swap(false, Ordering::AcqRel)
    }

    fn reserve_event_slot(&self) -> bool {
        self.state
            .queued_events
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |queued| {
                (queued < self.state.event_capacity).then_some(queued + 1)
            })
            .is_ok()
    }

    fn release_event_slot(&self) {
        let previous = self.state.queued_events.fetch_sub(1, Ordering::AcqRel);
        debug_assert!(previous > 0, "semantic scene event accounting underflow");
    }

    fn event_received(&self) {
        self.release_event_slot();
        self.wake_producer();
    }

    fn cancel(&self) {
        self.state.canceled.store(true, Ordering::Release);
    }

    fn detach(&self) {
        self.cancel();
        self.wake_producer();
    }

    fn is_canceled(&self) -> bool {
        self.state.canceled.load(Ordering::Acquire)
    }

    fn retain_fallback_failure(&self, failure: SemanticSceneFailure) {
        *self.state.fallback_failure.lock().unwrap() = Some(failure);
    }

    fn take_fallback_failure(&self) -> Option<SemanticSceneFailure> {
        self.state.fallback_failure.lock().unwrap().take()
    }
}

/// Cloneable control handle for one semantic scene attachment.
#[derive(Clone)]
pub struct SemanticSceneControl {
    lifecycle: SemanticSceneLifecycle,
}

impl SemanticSceneControl {
    /// Force the latest canonical terminal state to be sent as a full scene.
    ///
    /// The renderer must discard its canonical decode cache first because unchanged terminal
    /// content keeps the same canonical sequence in the replacement full scene.
    pub fn request_full_scene(&self) {
        self.lifecycle.request_full();
    }

    /// Permanently detach this attachment and wake the producer to release its encoder cache.
    pub fn detach(&self) {
        self.lifecycle.detach();
    }

    /// Return whether this attachment has been detached or failed closed.
    pub fn is_detached(&self) -> bool {
        self.lifecycle.is_canceled()
    }

    /// Return whether the next successfully queued scene must be a full snapshot.
    pub fn needs_full_scene(&self) -> bool {
        self.lifecycle.needs_full()
    }

    /// Replace visual IME marked text without writing bytes to the PTY.
    pub fn set_preedit(&self, preedit: Option<String>) {
        self.lifecycle.set_preedit(preedit.map(Arc::<str>::from));
    }
}

/// The bounded live receiver for one semantic scene attachment.
pub struct SemanticSceneReceiver {
    receiver: Receiver<SemanticSceneEvent>,
    lifecycle: SemanticSceneLifecycle,
}

impl SemanticSceneReceiver {
    /// Receive the next scene, or the terminal failure retained during overflow.
    pub fn recv(&self) -> Result<SemanticSceneEvent, RecvError> {
        match self.receiver.recv() {
            Ok(event) => {
                self.lifecycle.event_received();
                Ok(event)
            }
            Err(error) => {
                self.lifecycle.take_fallback_failure().map(SemanticSceneEvent::Failed).ok_or(error)
            }
        }
    }

    /// Receive the next scene before `timeout` expires.
    pub fn recv_timeout(&self, timeout: Duration) -> Result<SemanticSceneEvent, RecvTimeoutError> {
        match self.receiver.recv_timeout(timeout) {
            Ok(event) => {
                self.lifecycle.event_received();
                Ok(event)
            }
            Err(RecvTimeoutError::Disconnected) => self
                .lifecycle
                .take_fallback_failure()
                .map(SemanticSceneEvent::Failed)
                .ok_or(RecvTimeoutError::Disconnected),
            Err(error) => Err(error),
        }
    }

    /// Try to receive one scene without blocking.
    pub fn try_recv(&self) -> Result<SemanticSceneEvent, TryRecvError> {
        match self.receiver.try_recv() {
            Ok(event) => {
                self.lifecycle.event_received();
                Ok(event)
            }
            Err(TryRecvError::Disconnected) => self
                .lifecycle
                .take_fallback_failure()
                .map(SemanticSceneEvent::Failed)
                .ok_or(TryRecvError::Disconnected),
            Err(error) => Err(error),
        }
    }

    /// Force the latest canonical terminal state to be sent as a full scene.
    pub fn request_full_scene(&self) {
        SemanticSceneControl { lifecycle: self.lifecycle.clone() }.request_full_scene();
    }

    /// Permanently detach this receiver and wake the producer to release its cache.
    pub fn detach(&self) {
        SemanticSceneControl { lifecycle: self.lifecycle.clone() }.detach();
    }

    /// Return whether this attachment has been detached or failed closed.
    pub fn is_detached(&self) -> bool {
        SemanticSceneControl { lifecycle: self.lifecycle.clone() }.is_detached()
    }

    /// Return whether the next successfully queued scene must be a full snapshot.
    pub fn needs_full_scene(&self) -> bool {
        SemanticSceneControl { lifecycle: self.lifecycle.clone() }.needs_full_scene()
    }
}

impl Drop for SemanticSceneReceiver {
    fn drop(&mut self) {
        self.lifecycle.detach();
    }
}

/// Full-first semantic scene state and its bounded ordered live receiver.
pub struct SemanticSceneAttachment {
    pub initial: SemanticSceneFrame,
    pub events: SemanticSceneReceiver,
    pub control: SemanticSceneControl,
}

struct SemanticSceneTap {
    encoder: RenderSceneEncoder,
    sender: SyncSender<SemanticSceneEvent>,
    lifecycle: SemanticSceneLifecycle,
    terminal: SemanticSceneTerminalIdentity,
    presentation: SemanticScenePresentationIdentity,
    capture: SemanticSceneCaptureOptions,
    delivered_content_sequence: u64,
    next_presentation_sequence: u64,
    needs_full: bool,
}

#[derive(Default)]
pub(crate) struct SemanticSceneHub {
    attachments: Vec<SemanticSceneTap>,
}

impl SemanticSceneHub {
    pub(crate) fn attach_locked(
        &mut self,
        terminal: &mut Terminal,
        actual_terminal: SemanticSceneTerminalIdentity,
        content_sequence: u64,
        options: SemanticSceneAttachmentOptions,
        wake: SyncSender<u64>,
    ) -> Result<SemanticSceneAttachment, SemanticSceneAttachError> {
        Self::validate_attachment(actual_terminal, content_sequence, &options)?;

        let mut encoder = RenderSceneEncoder::new()
            .map_err(SemanticSceneFailure::from)
            .map_err(SemanticSceneAttachError::Capture)?;
        let presentation_sequence = 1;
        let encoded = encoder
            .encode(
                terminal,
                Self::encode_options(
                    options.terminal,
                    content_sequence,
                    options.presentation,
                    presentation_sequence,
                    SceneSectionKind::Full,
                    options.capture,
                    options.preedit.as_deref(),
                ),
            )
            .map_err(SemanticSceneFailure::from)
            .map_err(SemanticSceneAttachError::Capture)?;
        let initial = SemanticSceneFrame {
            terminal: options.terminal,
            content_sequence,
            presentation: options.presentation,
            presentation_sequence,
            canonical_kind: SceneSectionKind::Full,
            encoded,
        };
        let (sender, receiver) = sync_channel(options.event_capacity);
        let lifecycle = SemanticSceneLifecycle::new(wake, options.event_capacity, options.preedit);
        self.attachments.push(SemanticSceneTap {
            encoder,
            sender,
            lifecycle: lifecycle.clone(),
            terminal: options.terminal,
            presentation: options.presentation,
            capture: options.capture,
            delivered_content_sequence: content_sequence,
            next_presentation_sequence: 2,
            needs_full: false,
        });

        Ok(SemanticSceneAttachment {
            initial,
            events: SemanticSceneReceiver { receiver, lifecycle: lifecycle.clone() },
            control: SemanticSceneControl { lifecycle },
        })
    }

    pub(crate) fn capture_locked(
        &mut self,
        terminal: &mut Terminal,
        actual_terminal: SemanticSceneTerminalIdentity,
        content_sequence: u64,
    ) -> bool {
        if self.attachments.is_empty() {
            return false;
        }

        let mut worked = false;
        self.attachments.retain_mut(|attachment| {
            if attachment.lifecycle.is_canceled() {
                return false;
            }
            if attachment.terminal != actual_terminal || content_sequence == 0 {
                worked = true;
                return Self::fail_attachment(
                    attachment,
                    SemanticSceneFailure::InvalidInput,
                    false,
                );
            }

            let force_full = attachment.lifecycle.take_force_full();
            let presentation_dirty = attachment.lifecycle.take_presentation_dirty();
            if !force_full
                && !attachment.needs_full
                && !presentation_dirty
                && content_sequence <= attachment.delivered_content_sequence
            {
                return true;
            }
            worked = true;

            if !attachment.lifecycle.reserve_event_slot() {
                // A stalled worker still owns every bounded slot. The receive path wakes this
                // producer at the exact capacity transition, so repeated output does no capture.
                attachment.encoder.reset();
                attachment.needs_full = true;
                attachment.lifecycle.mark_needs_full();
                return true;
            }

            if attachment.next_presentation_sequence == u64::MAX {
                return Self::fail_attachment(attachment, SemanticSceneFailure::Internal, true);
            }

            let mut canonical_kind = if force_full || attachment.needs_full {
                SceneSectionKind::Full
            } else if content_sequence <= attachment.delivered_content_sequence {
                SceneSectionKind::Unchanged
            } else {
                SceneSectionKind::Delta
            };
            if canonical_kind == SceneSectionKind::Full {
                attachment.encoder.reset();
            }

            let preedit = attachment.lifecycle.preedit();
            let encoded = match attachment.encoder.encode(
                terminal,
                Self::encode_options(
                    attachment.terminal,
                    content_sequence,
                    attachment.presentation,
                    attachment.next_presentation_sequence,
                    canonical_kind,
                    attachment.capture,
                    preedit.as_deref(),
                ),
            ) {
                Ok(encoded) => encoded,
                Err(RenderSceneError::RequiresFullSnapshot)
                    if canonical_kind == SceneSectionKind::Delta =>
                {
                    canonical_kind = SceneSectionKind::Full;
                    attachment.encoder.reset();
                    match attachment.encoder.encode(
                        terminal,
                        Self::encode_options(
                            attachment.terminal,
                            content_sequence,
                            attachment.presentation,
                            attachment.next_presentation_sequence,
                            canonical_kind,
                            attachment.capture,
                            preedit.as_deref(),
                        ),
                    ) {
                        Ok(encoded) => encoded,
                        Err(error) => {
                            return Self::fail_attachment(attachment, error.into(), true);
                        }
                    }
                }
                Err(error) => return Self::fail_attachment(attachment, error.into(), true),
            };

            let frame = SemanticSceneFrame {
                terminal: attachment.terminal,
                content_sequence,
                presentation: attachment.presentation,
                presentation_sequence: attachment.next_presentation_sequence,
                canonical_kind,
                encoded,
            };
            match attachment.sender.try_send(SemanticSceneEvent::Scene(frame)) {
                Ok(()) => {
                    attachment.delivered_content_sequence = content_sequence;
                    attachment.next_presentation_sequence += 1;
                    attachment.needs_full = false;
                    attachment.lifecycle.clear_needs_full();
                    true
                }
                Err(TrySendError::Full(_)) => {
                    attachment.lifecycle.release_event_slot();
                    // Encoding already advanced this attachment's private cache. Drop it before
                    // any later update so the consumer can never receive a delta from a missed base.
                    attachment.encoder.reset();
                    attachment.needs_full = true;
                    attachment.lifecycle.mark_needs_full();
                    true
                }
                Err(TrySendError::Disconnected(_)) => {
                    attachment.lifecycle.release_event_slot();
                    attachment.lifecycle.cancel();
                    false
                }
            }
        });
        worked
    }

    pub(crate) fn attachment_count(&self) -> usize {
        self.attachments.len()
    }

    fn fail_attachment(
        attachment: &mut SemanticSceneTap,
        failure: SemanticSceneFailure,
        slot_reserved: bool,
    ) -> bool {
        let has_slot = slot_reserved || attachment.lifecycle.reserve_event_slot();
        if has_slot {
            match attachment.sender.try_send(SemanticSceneEvent::Failed(failure)) {
                Ok(()) => {}
                Err(TrySendError::Full(_)) => {
                    attachment.lifecycle.release_event_slot();
                    attachment.lifecycle.retain_fallback_failure(failure);
                }
                Err(TrySendError::Disconnected(_)) => {
                    attachment.lifecycle.release_event_slot();
                }
            }
        } else if !attachment.lifecycle.is_canceled() {
            // The sender is removed immediately below. The receiver drains its bounded scenes,
            // observes disconnect, then consumes this one retained typed terminal event.
            attachment.lifecycle.retain_fallback_failure(failure);
        }
        attachment.lifecycle.cancel();
        false
    }

    fn validate_attachment(
        actual_terminal: SemanticSceneTerminalIdentity,
        content_sequence: u64,
        options: &SemanticSceneAttachmentOptions,
    ) -> Result<(), SemanticSceneAttachError> {
        if options.terminal.runtime_epoch == 0 {
            return Err(SemanticSceneAttachError::InvalidRuntimeEpoch);
        }
        if options.terminal != actual_terminal {
            return Err(SemanticSceneAttachError::TerminalIdentityMismatch);
        }
        if options.presentation.presentation_id.as_uuid().is_nil() {
            return Err(SemanticSceneAttachError::InvalidPresentationIdentity);
        }
        if options.presentation.generation == 0 {
            return Err(SemanticSceneAttachError::InvalidPresentationGeneration);
        }
        if !(1..=SEMANTIC_SCENE_MAX_EVENT_CAPACITY).contains(&options.event_capacity) {
            return Err(SemanticSceneAttachError::InvalidEventCapacity);
        }
        if content_sequence == 0 {
            return Err(SemanticSceneAttachError::InvalidContentSequence);
        }
        Ok(())
    }

    fn encode_options(
        terminal: SemanticSceneTerminalIdentity,
        content_sequence: u64,
        presentation: SemanticScenePresentationIdentity,
        presentation_sequence: u64,
        canonical_kind: SceneSectionKind,
        capture: SemanticSceneCaptureOptions,
        preedit: Option<&str>,
    ) -> RenderSceneOptions<'_> {
        RenderSceneOptions {
            terminal_id: *terminal.terminal_id.as_uuid().as_bytes(),
            terminal_epoch: terminal.runtime_epoch,
            content_sequence,
            presentation_id: *presentation.presentation_id.as_uuid().as_bytes(),
            presentation_generation: presentation.generation,
            presentation_sequence,
            canonical_kind,
            focused: capture.focused,
            cursor_blink_visible: capture.cursor_blink_visible,
            custom_shader_count: capture.custom_shader_count,
            preedit,
            limits: capture.limits,
        }
    }
}
