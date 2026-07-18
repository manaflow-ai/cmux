use std::fmt;
use std::mem::size_of;
use std::ptr;

use ghostty_vt_sys as sys;

use crate::Terminal;

/// Canonical section emitted by one semantic render-scene capture.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SceneSectionKind {
    /// Refer to the encoder's exact cached canonical scene.
    Unchanged,
    /// Emit a complete canonical snapshot and replace the cached base.
    Full,
    /// Emit a delta from the exact cached canonical base, then replace it.
    Delta,
}

/// Presentation-local highlight type rendered with Ghostty's search palette.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RenderSceneHighlightKind {
    SearchMatch,
    SearchMatchSelected,
}

/// One inclusive search range in retained terminal row coordinates.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RenderSceneHighlight {
    pub start_row: u64,
    pub start_column: u32,
    pub end_row: u64,
    pub end_column: u32,
    pub kind: RenderSceneHighlightKind,
}

/// Presentation-local IME marked text and AppKit UTF-16 caret semantics.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RenderScenePreedit<'a> {
    pub text: &'a str,
    pub selection_start_utf16: u32,
    pub selection_length_utf16: u32,
    pub caret_utf16: u32,
}

impl SceneSectionKind {
    fn raw(self) -> sys::GhosttyRenderSceneSectionKind {
        match self {
            Self::Unchanged => sys::GHOSTTY_RENDER_SCENE_SECTION_UNCHANGED,
            Self::Full => sys::GHOSTTY_RENDER_SCENE_SECTION_FULL,
            Self::Delta => sys::GHOSTTY_RENDER_SCENE_SECTION_DELTA,
        }
    }
}

/// Hard resource limits applied to semantic scene capture and encoding.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RenderSceneLimits {
    pub max_encoded_bytes: usize,
    pub max_allocation_bytes: usize,
    pub max_rows: u32,
    pub max_columns: u32,
    pub max_cells: usize,
    pub max_grapheme_codepoints_per_cell: usize,
    pub max_total_grapheme_codepoints: usize,
    pub max_preedit_codepoints: usize,
    pub max_highlights: usize,
    pub max_overlay_features: usize,
    pub max_kitty_resources: usize,
    pub max_kitty_frames: usize,
    pub max_kitty_placements: usize,
    pub max_kitty_resource_bytes: usize,
}

impl Default for RenderSceneLimits {
    fn default() -> Self {
        Self {
            max_encoded_bytes: 64 * 1024 * 1024,
            max_allocation_bytes: 128 * 1024 * 1024,
            max_rows: 4096,
            max_columns: 4096,
            max_cells: 4 * 1024 * 1024,
            max_grapheme_codepoints_per_cell: 64,
            max_total_grapheme_codepoints: 4 * 1024 * 1024,
            max_preedit_codepoints: 4096,
            max_highlights: 1024 * 1024,
            max_overlay_features: 16,
            max_kitty_resources: 4096,
            max_kitty_frames: 64 * 1024,
            max_kitty_placements: 64 * 1024,
            max_kitty_resource_bytes: 64 * 1024 * 1024,
        }
    }
}

impl RenderSceneLimits {
    fn raw(self) -> sys::GhosttyRenderSceneLimits {
        sys::GhosttyRenderSceneLimits {
            size: size_of::<sys::GhosttyRenderSceneLimits>(),
            max_encoded_bytes: self.max_encoded_bytes,
            max_allocation_bytes: self.max_allocation_bytes,
            max_rows: self.max_rows,
            max_columns: self.max_columns,
            max_cells: self.max_cells,
            max_grapheme_codepoints_per_cell: self.max_grapheme_codepoints_per_cell,
            max_total_grapheme_codepoints: self.max_total_grapheme_codepoints,
            max_preedit_codepoints: self.max_preedit_codepoints,
            max_highlights: self.max_highlights,
            max_overlay_features: self.max_overlay_features,
            max_kitty_resources: self.max_kitty_resources,
            max_kitty_frames: self.max_kitty_frames,
            max_kitty_placements: self.max_kitty_placements,
            max_kitty_resource_bytes: self.max_kitty_resource_bytes,
        }
    }
}

/// Exact daemon-owned identity and sequence inputs for one scene capture.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RenderSceneOptions<'a> {
    pub terminal_id: [u8; 16],
    pub terminal_epoch: u64,
    pub content_sequence: u64,
    pub presentation_id: [u8; 16],
    pub presentation_generation: u64,
    pub presentation_sequence: u64,
    pub canonical_kind: SceneSectionKind,
    pub focused: bool,
    pub cursor_blink_visible: bool,
    /// Number of resolved renderer-config shaders required by this presentation.
    /// Shader sources remain renderer resources and are never copied into the
    /// canonical terminal section.
    pub custom_shader_count: u32,
    /// Borrowed IME marked text rendered at the scene cursor anchor.
    pub preedit: Option<RenderScenePreedit<'a>>,
    /// Daemon-derived visible search candidates.
    pub highlights: &'a [RenderSceneHighlight],
    pub limits: RenderSceneLimits,
}

impl RenderSceneOptions<'_> {
    fn raw(
        self,
        raw_highlights: &[sys::GhosttyRenderSceneHighlight],
    ) -> sys::GhosttyRenderSceneOptions {
        let (preedit_utf8, preedit_utf8_len) =
            self.preedit.map_or((ptr::null(), 0), |value| (value.text.as_ptr(), value.text.len()));
        let preedit_selection_start_utf16 =
            self.preedit.map_or(0, |value| value.selection_start_utf16);
        let preedit_selection_length_utf16 =
            self.preedit.map_or(0, |value| value.selection_length_utf16);
        let preedit_caret_utf16 = self.preedit.map_or(0, |value| value.caret_utf16);
        sys::GhosttyRenderSceneOptions {
            size: size_of::<sys::GhosttyRenderSceneOptions>(),
            terminal_id: self.terminal_id,
            terminal_epoch: self.terminal_epoch,
            content_sequence: self.content_sequence,
            presentation_id: self.presentation_id,
            presentation_generation: self.presentation_generation,
            presentation_sequence: self.presentation_sequence,
            canonical_kind: self.canonical_kind.raw(),
            focused: self.focused,
            cursor_blink_visible: self.cursor_blink_visible,
            custom_shader_count: self.custom_shader_count,
            preedit_utf8,
            preedit_utf8_len,
            preedit_selection_start_utf16,
            preedit_selection_length_utf16,
            preedit_caret_utf16,
            presentation_highlights: raw_highlights.as_ptr(),
            presentation_highlights_len: raw_highlights.len(),
            limits: self.limits.raw(),
        }
    }
}

/// A typed semantic scene capture failure.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RenderSceneError {
    InvalidValue,
    OutOfMemory,
    LimitExceeded,
    UnsupportedKittyImages,
    UnsupportedCustomShaders,
    RequiresFullSnapshot,
    Internal,
    Unknown(i32),
}

impl fmt::Display for RenderSceneError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidValue => write!(f, "invalid semantic render-scene input"),
            Self::OutOfMemory => write!(f, "semantic render-scene allocation failed"),
            Self::LimitExceeded => write!(f, "semantic render-scene limit exceeded"),
            Self::UnsupportedKittyImages => {
                write!(f, "the Kitty scene requires an unsupported capability")
            }
            Self::UnsupportedCustomShaders => {
                write!(f, "custom shader state cannot be captured semantically")
            }
            Self::RequiresFullSnapshot => write!(f, "a full canonical snapshot is required"),
            Self::Internal => write!(f, "semantic render-scene codec failed"),
            Self::Unknown(code) => write!(f, "unknown semantic render-scene error {code}"),
        }
    }
}

impl std::error::Error for RenderSceneError {}

/// Stateful canonical scene encoder backed by Ghostty's Zig wire codec.
pub struct RenderSceneEncoder {
    raw: sys::GhosttyRenderSceneEncoder,
}

// The C handle has no thread affinity and mutation requires `&mut self`.
unsafe impl Send for RenderSceneEncoder {}

impl RenderSceneEncoder {
    /// Create an encoder with no cached canonical base.
    pub fn new() -> Result<Self, RenderSceneError> {
        let mut raw: sys::GhosttyRenderSceneEncoder = ptr::null_mut();
        let status = unsafe { sys::ghostty_render_scene_encoder_new(ptr::null(), &mut raw) };
        check(status)?;
        if raw.is_null() {
            return Err(RenderSceneError::Internal);
        }
        Ok(Self { raw })
    }

    /// Drop the canonical base so the next changed scene must be full.
    pub fn reset(&mut self) {
        unsafe { sys::ghostty_render_scene_encoder_reset(self.raw) };
    }

    /// Capture and encode one immutable semantic scene update.
    pub fn encode(
        &mut self,
        terminal: &mut Terminal,
        options: RenderSceneOptions<'_>,
    ) -> Result<EncodedRenderScene, RenderSceneError> {
        let raw_highlights = options
            .highlights
            .iter()
            .map(|highlight| sys::GhosttyRenderSceneHighlight {
                start_row: highlight.start_row,
                start_column: highlight.start_column,
                end_row: highlight.end_row,
                end_column: highlight.end_column,
                kind: match highlight.kind {
                    RenderSceneHighlightKind::SearchMatch => {
                        sys::GHOSTTY_RENDER_SCENE_HIGHLIGHT_SEARCH_MATCH
                    }
                    RenderSceneHighlightKind::SearchMatchSelected => {
                        sys::GHOSTTY_RENDER_SCENE_HIGHLIGHT_SEARCH_MATCH_SELECTED
                    }
                },
            })
            .collect::<Vec<_>>();
        let raw_options = options.raw(&raw_highlights);
        let mut raw_buffer: sys::GhosttyRenderSceneBuffer = ptr::null_mut();
        let status = unsafe {
            sys::ghostty_render_scene_encode(
                self.raw,
                terminal.raw(),
                &raw_options,
                &mut raw_buffer,
            )
        };
        check(status)?;
        if raw_buffer.is_null() {
            return Err(RenderSceneError::Internal);
        }
        let result = EncodedRenderScene { raw: raw_buffer };
        if result.is_empty() || result.data().is_null() {
            return Err(RenderSceneError::Internal);
        }
        Ok(result)
    }
}

impl Drop for RenderSceneEncoder {
    fn drop(&mut self) {
        unsafe { sys::ghostty_render_scene_encoder_free(self.raw) };
    }
}

/// Immutable pointer-free Ghostty semantic scene wire bytes.
#[derive(Debug)]
pub struct EncodedRenderScene {
    raw: sys::GhosttyRenderSceneBuffer,
}

// The buffer is immutable, its native allocation is thread-safe, and it owns
// every byte until Drop, independently of its originating encoder.
unsafe impl Send for EncodedRenderScene {}
// Immutable byte access can be shared across threads until the final Drop.
unsafe impl Sync for EncodedRenderScene {}

impl EncodedRenderScene {
    /// Borrow the complete encoded scene.
    pub fn as_bytes(&self) -> &[u8] {
        let len = self.len();
        let data = self.data();
        if len == 0 || data.is_null() {
            return &[];
        }
        // The C buffer owns `len` immutable initialized bytes until Drop.
        unsafe { std::slice::from_raw_parts(data, len) }
    }

    pub fn len(&self) -> usize {
        unsafe { sys::ghostty_render_scene_buffer_size(self.raw) }
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    fn data(&self) -> *const u8 {
        unsafe { sys::ghostty_render_scene_buffer_data(self.raw) }
    }
}

impl AsRef<[u8]> for EncodedRenderScene {
    fn as_ref(&self) -> &[u8] {
        self.as_bytes()
    }
}

impl Drop for EncodedRenderScene {
    fn drop(&mut self) {
        unsafe { sys::ghostty_render_scene_buffer_free(self.raw) };
    }
}

fn check(status: sys::GhosttyRenderSceneStatus) -> Result<(), RenderSceneError> {
    match status {
        sys::GHOSTTY_RENDER_SCENE_SUCCESS => Ok(()),
        sys::GHOSTTY_RENDER_SCENE_INVALID_VALUE => Err(RenderSceneError::InvalidValue),
        sys::GHOSTTY_RENDER_SCENE_OUT_OF_MEMORY => Err(RenderSceneError::OutOfMemory),
        sys::GHOSTTY_RENDER_SCENE_LIMIT_EXCEEDED => Err(RenderSceneError::LimitExceeded),
        sys::GHOSTTY_RENDER_SCENE_UNSUPPORTED_KITTY_IMAGES => {
            Err(RenderSceneError::UnsupportedKittyImages)
        }
        sys::GHOSTTY_RENDER_SCENE_UNSUPPORTED_CUSTOM_SHADERS => {
            Err(RenderSceneError::UnsupportedCustomShaders)
        }
        sys::GHOSTTY_RENDER_SCENE_REQUIRES_FULL_SNAPSHOT => {
            Err(RenderSceneError::RequiresFullSnapshot)
        }
        sys::GHOSTTY_RENDER_SCENE_INTERNAL_ERROR => Err(RenderSceneError::Internal),
        other => Err(RenderSceneError::Unknown(other as i32)),
    }
}
