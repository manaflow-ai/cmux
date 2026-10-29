use std::collections::{BTreeMap, HashMap, HashSet};
use std::ffi::c_void;
use std::io::Cursor;
use std::mem::size_of;
use std::ptr;
use std::sync::{Arc, OnceLock};

use ghostty_vt_sys as sys;

use crate::terminal::Terminal;
use crate::{Error, Result, check};

/// Largest decoded image, and the default kitty image storage of one
/// terminal: the daemon memory budget's per-terminal kitty cap.
pub const MAX_KITTY_IMAGE_BYTES: usize = cmux_memory::budget::KITTY_IMAGE_BYTES_PER_TERMINAL;
pub const MAX_KITTY_IMAGES: u64 = 4_096;
pub const MAX_KITTY_PLACEMENTS: u64 = 16_384;
const KITTY_INFLIGHT_REPLAY_FRAMING_MAX_BYTES: u64 = 256 * 1024;

/// Wire bytes reserved for an incomplete direct upload with this decoded-byte
/// allowance. The reservation covers exact base64 expansion and a proportional
/// share of the bounded command-framing headroom.
pub const fn kitty_inflight_replay_limit_for_image_bytes(image_bytes: u64) -> u64 {
    let maximum = MAX_KITTY_IMAGE_BYTES as u64;
    let bounded = if image_bytes < maximum { image_bytes } else { maximum };
    let encoded = bounded.div_ceil(3).saturating_mul(4);
    let framing = bounded.saturating_mul(KITTY_INFLIGHT_REPLAY_FRAMING_MAX_BYTES).div_ceil(maximum);
    encoded.saturating_add(framing)
}

/// Maximum retained byte prefix for a valid incomplete direct Kitty upload.
pub const KITTY_INFLIGHT_REPLAY_MAX_BYTES: usize =
    kitty_inflight_replay_limit_for_image_bytes(MAX_KITTY_IMAGE_BYTES as u64) as usize;
const PNG_SIGNATURE: &[u8; 8] = b"\x89PNG\r\n\x1a\n";

/// Bounded copy of a Kitty direct transmission that libghostty is still
/// assembling. A fresh attach terminal must consume this exact prefix before
/// it can understand later continuation chunks from the live byte stream.
pub(crate) struct KittyInFlightTracker {
    scan: KittyStreamScan,
    prefix: Vec<u8>,
    pub(crate) loading: bool,
    overflowed: bool,
    max_bytes: usize,
}

impl Default for KittyInFlightTracker {
    fn default() -> Self {
        Self {
            scan: KittyStreamScan::Ground,
            prefix: Vec::new(),
            loading: false,
            overflowed: false,
            max_bytes: KITTY_INFLIGHT_REPLAY_MAX_BYTES,
        }
    }
}

impl KittyInFlightTracker {
    pub(crate) fn is_ground(&self) -> bool {
        matches!(self.scan, KittyStreamScan::Ground)
    }

    /// Original byte-at-a-time write, kept as the exactness reference.
    pub(crate) fn write_reference(&mut self, data: &[u8]) {
        for &byte in data {
            self.step(byte);
        }
    }

    #[inline(always)]
    pub(crate) fn step(&mut self, byte: u8) {
        {
            let state = std::mem::take(&mut self.scan);
            self.scan = match state {
                KittyStreamScan::Ground => KittyStreamScan::from_ground(byte),
                KittyStreamScan::Utf8(mut continuation) => {
                    if !(continuation.next_min..=continuation.next_max).contains(&byte) {
                        KittyStreamScan::from_ground(byte)
                    } else if continuation.remaining == 1 {
                        KittyStreamScan::Ground
                    } else {
                        continuation.remaining -= 1;
                        continuation.next_min = 0x80;
                        continuation.next_max = 0xbf;
                        KittyStreamScan::Utf8(continuation)
                    }
                }
                KittyStreamScan::Escape => match byte {
                    b'_' => KittyStreamScan::ApcType(KittyApcIntroducer::Esc),
                    b'c' => {
                        self.clear_loading();
                        KittyStreamScan::Ground
                    }
                    0x1b => KittyStreamScan::Escape,
                    _ => KittyStreamScan::Ground,
                },
                KittyStreamScan::ApcType(introducer) => match byte {
                    b'G' => {
                        let prefix_bytes =
                            if self.loading && !self.overflowed { self.prefix.len() } else { 0 };
                        KittyStreamScan::Kitty(KittyCommand::new(
                            introducer,
                            self.max_bytes.saturating_sub(prefix_bytes),
                        ))
                    }
                    0x1b => KittyStreamScan::OtherApc { saw_escape: true },
                    0x9c => KittyStreamScan::Ground,
                    _ => KittyStreamScan::OtherApc { saw_escape: false },
                },
                KittyStreamScan::Kitty(mut command) => {
                    if matches!(byte, 0x18 | 0x1a) {
                        // CAN and SUB abort only the current control string.
                        // Preserve a previously completed m=1 prefix so a
                        // later continuation can still finish that upload.
                        KittyStreamScan::Ground
                    } else {
                        command.push(byte);
                        if byte == 0x9c || (command.saw_escape && byte == b'\\') {
                            self.finish_command(command);
                            KittyStreamScan::Ground
                        } else {
                            command.saw_escape = byte == 0x1b;
                            KittyStreamScan::Kitty(command)
                        }
                    }
                }
                KittyStreamScan::OtherApc { saw_escape } => {
                    if matches!(byte, 0x18 | 0x1a) || byte == 0x9c || (saw_escape && byte == b'\\')
                    {
                        KittyStreamScan::Ground
                    } else {
                        KittyStreamScan::OtherApc { saw_escape: byte == 0x1b }
                    }
                }
            };
        }
    }

    fn replay_prefix_parts(&self) -> Result<(&[u8], &[u8])> {
        if self.overflowed
            || matches!(&self.scan, KittyStreamScan::Kitty(command) if command.overflowed)
        {
            return Err(Error::OutOfSpace);
        }
        let partial = match &self.scan {
            KittyStreamScan::Escape => &b"\x1b"[..],
            KittyStreamScan::ApcType(KittyApcIntroducer::Esc) => &b"\x1b_"[..],
            KittyStreamScan::ApcType(KittyApcIntroducer::C1) => &b"\x9f"[..],
            KittyStreamScan::Kitty(command) if !command.overflowed => &command.bytes,
            _ => &[],
        };
        let prefix = if self.loading { self.prefix.as_slice() } else { &[] };
        if prefix.len().checked_add(partial.len()).is_none_or(|total| total > self.max_bytes) {
            return Err(Error::OutOfSpace);
        }
        Ok((prefix, partial))
    }

    /// Whether the stream is inside a direct Kitty command this tracker
    /// retains completely.
    pub(crate) fn has_partial_command(&self) -> bool {
        !self.overflowed
            && matches!(&self.scan, KittyStreamScan::Kitty(command) if !command.overflowed)
    }

    pub(crate) fn has_unreplayable_command(&self) -> bool {
        // A tracker-level overflow can also mean that a completed multipart
        // chunk exceeded the retention budget. CAN cannot undo that command
        // after the parser has returned to ground, so only an actively
        // overflowed command is recoverable here.
        !self.overflowed
            && matches!(&self.scan, KittyStreamScan::Kitty(command) if command.overflowed)
    }

    pub(crate) fn has_unreplayable_prefix(&self) -> bool {
        self.overflowed
    }

    pub(crate) fn discard_unreplayable(&mut self) {
        self.scan = KittyStreamScan::Ground;
        self.overflowed = false;
        // CAN aborts only the command that is currently being parsed. Keep a
        // completed m=1 prefix so checkpoint replay can still resume the
        // native upload when a later m=0 chunk arrives. An overflowed first
        // chunk has no prefix to preserve, so leave the tracker idle there.
        if self.prefix.is_empty() {
            self.loading = false;
        }
    }

    /// The completed upload chunks and the partial command, separately, under
    /// the same budget as [`Self::replay_prefix_checked`].
    pub(crate) fn replay_prefix_and_partial_checked(
        &self,
        max_bytes: usize,
    ) -> Result<(Vec<u8>, Vec<u8>)> {
        let (prefix, partial) = self.replay_prefix_parts()?;
        let total = prefix.len().checked_add(partial.len()).ok_or(Error::OutOfSpace)?;
        if total > max_bytes {
            return Err(Error::OutOfSpace);
        }
        Ok((prefix.to_vec(), partial.to_vec()))
    }

    fn finish_command(&mut self, command: KittyCommand) {
        let more = match kitty_transmission_state(&command.bytes) {
            KittyTransmissionState::More(more) => more,
            KittyTransmissionState::NonTransmission => return,
            KittyTransmissionState::Unknown => {
                if command.overflowed {
                    self.prefix = Vec::new();
                    self.loading = true;
                    self.overflowed = true;
                }
                return;
            }
        };
        if more {
            if !self.loading {
                self.prefix = Vec::new();
                self.overflowed = false;
            }
            self.loading = true;
            if self.overflowed || command.overflowed {
                self.prefix = Vec::new();
                self.overflowed = true;
                return;
            }
            let Some(total) = self.prefix.len().checked_add(command.bytes.len()) else {
                self.prefix = Vec::new();
                self.overflowed = true;
                return;
            };
            if total > self.max_bytes {
                self.prefix = Vec::new();
                self.overflowed = true;
                return;
            }
            if self.prefix.is_empty() {
                self.prefix = command.bytes;
            } else {
                if self.prefix.capacity() < total {
                    self.prefix.reserve_exact(total - self.prefix.len());
                }
                self.prefix.extend_from_slice(&command.bytes);
            }
        } else {
            self.clear_loading();
        }
    }

    fn clear_loading(&mut self) {
        self.prefix = Vec::new();
        self.loading = false;
        self.overflowed = false;
    }

    pub(crate) fn set_max_bytes(&mut self, max_bytes: usize) {
        self.max_bytes = max_bytes.min(KITTY_INFLIGHT_REPLAY_MAX_BYTES);
        let prefix_bytes = if self.loading && !self.overflowed { self.prefix.len() } else { 0 };
        if prefix_bytes > self.max_bytes {
            self.prefix = Vec::new();
            self.overflowed = true;
        } else {
            self.prefix.shrink_to_fit();
        }
        let retained_prefix = if self.loading && !self.overflowed { self.prefix.len() } else { 0 };
        if let KittyStreamScan::Kitty(command) = &mut self.scan {
            command.set_max_bytes(self.max_bytes.saturating_sub(retained_prefix));
        }
    }

    pub(crate) fn max_bytes(&self) -> usize {
        self.max_bytes
    }
}

#[derive(Default)]
enum KittyStreamScan {
    #[default]
    Ground,
    Utf8(Utf8Continuation),
    Escape,
    ApcType(KittyApcIntroducer),
    Kitty(KittyCommand),
    OtherApc {
        saw_escape: bool,
    },
}

impl KittyStreamScan {
    fn from_ground(byte: u8) -> Self {
        // Match libghostty's parser and C1Normalizer: after a multibyte lead,
        // every 0x80..=0xbf byte stays text even when strict UTF-8 would reject it.
        match byte {
            0x1b => Self::Escape,
            0x9f => Self::ApcType(KittyApcIntroducer::C1),
            0xc2..=0xdf => Self::utf8(1, 0x80, 0xbf),
            0xe0..=0xef => Self::utf8(2, 0x80, 0xbf),
            0xf0..=0xf4 => Self::utf8(3, 0x80, 0xbf),
            _ => Self::Ground,
        }
    }

    fn utf8(remaining: u8, next_min: u8, next_max: u8) -> Self {
        Self::Utf8(Utf8Continuation { remaining, next_min, next_max })
    }
}

struct Utf8Continuation {
    remaining: u8,
    next_min: u8,
    next_max: u8,
}

enum KittyApcIntroducer {
    Esc,
    C1,
}

struct KittyCommand {
    bytes: Vec<u8>,
    saw_escape: bool,
    overflowed: bool,
    max_bytes: usize,
}

impl KittyCommand {
    fn new(introducer: KittyApcIntroducer, max_bytes: usize) -> Self {
        let introducer = match introducer {
            KittyApcIntroducer::Esc => &b"\x1b_G"[..],
            KittyApcIntroducer::C1 => &b"\x9fG"[..],
        };
        let retained = introducer.iter().take(max_bytes);
        let bytes: Vec<u8> = retained.copied().collect();
        let overflowed = bytes.len() != introducer.len();
        Self { bytes, saw_escape: false, overflowed, max_bytes }
    }

    fn push(&mut self, byte: u8) {
        if self.bytes.len() < self.max_bytes {
            if self.bytes.len() == self.bytes.capacity() {
                let remaining = self.max_bytes - self.bytes.len();
                let growth = remaining.min(self.bytes.capacity().max(64));
                self.bytes.reserve_exact(growth);
            }
            self.bytes.push(byte);
        } else {
            self.overflowed = true;
        }
    }

    fn set_max_bytes(&mut self, max_bytes: usize) {
        self.max_bytes = max_bytes;
        if self.bytes.len() > max_bytes {
            self.bytes.truncate(max_bytes);
            self.overflowed = true;
        }
        self.bytes.shrink_to_fit();
    }
}

enum KittyTransmissionState {
    More(bool),
    NonTransmission,
    Unknown,
}

fn kitty_u32(value: &[u8]) -> Option<u32> {
    if value.is_empty() {
        return None;
    }
    value.iter().try_fold(0_u32, |parsed, byte| {
        let digit = byte.checked_sub(b'0').filter(|digit| *digit <= 9)?;
        parsed.checked_mul(10)?.checked_add(u32::from(digit))
    })
}

fn kitty_transmission_state(command: &[u8]) -> KittyTransmissionState {
    let Some(after_introducer) =
        command.strip_prefix(b"\x1b_G").or_else(|| command.strip_prefix(b"\x9fG"))
    else {
        return KittyTransmissionState::Unknown;
    };
    // The control data runs to the first `;`; a command without one is unknown.
    let mut sections = after_introducer.splitn(2, |byte| *byte == b';');
    let (Some(header), Some(_payload)) = (sections.next(), sections.next()) else {
        return KittyTransmissionState::Unknown;
    };
    let mut action = b't';
    let mut direct = true;
    let mut more = false;
    for parameter in header.split(|byte| *byte == b',') {
        let mut pair = parameter.splitn(2, |byte| *byte == b'=');
        let (Some(key), Some(value)) = (pair.next(), pair.next()) else {
            continue;
        };
        match key {
            b"a" => {
                let Some(value) = value.first() else {
                    return KittyTransmissionState::Unknown;
                };
                action = *value;
            }
            b"t" => direct = value == b"d",
            b"m" => {
                let Some(value) = kitty_u32(value) else {
                    return KittyTransmissionState::Unknown;
                };
                more = value > 0;
            }
            _ => {}
        }
    }
    if matches!(action, b't' | b'T') {
        KittyTransmissionState::More(more && direct)
    } else {
        KittyTransmissionState::NonTransmission
    }
}

/// Pixel format stored in an owned Kitty graphics snapshot.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum KittyImageFormat {
    Rgb,
    Rgba,
}

impl KittyImageFormat {
    pub fn kitty_protocol_value(self) -> u8 {
        match self {
            Self::Rgb => 24,
            Self::Rgba => 32,
        }
    }

    pub fn bytes_per_pixel(self) -> usize {
        match self {
            Self::Rgb => 3,
            Self::Rgba => 4,
        }
    }
}

/// Decoded image pixels copied out of libghostty's borrowed storage.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KittyImage {
    pub id: u32,
    pub number: u32,
    pub generation: u64,
    pub width: u32,
    pub height: u32,
    pub format: KittyImageFormat,
    pub data: Arc<[u8]>,
}

/// The two aliases of a numbered Kitty image.
///
/// Kitty forbids specifying `i` and `I` in one graphics command, so byte
/// replay restores the stable ID and attach transports this alias separately.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KittyImageAlias {
    pub image_id: u32,
    pub image_number: u32,
}

/// Stable identity within one sorted snapshot.
///
/// Kitty permits anonymous placements (`p=0`) and placement ID reuse
/// across images. The ordinal keeps those placements distinct without
/// relying on libghostty's unspecified iterator order.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct KittyPlacementKey {
    pub image_id: u32,
    pub placement_id: u32,
    pub ordinal: u32,
}

/// One non-virtual Kitty placement with resolved viewport geometry.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KittyPlacement {
    pub key: KittyPlacementKey,
    pub image_id: u32,
    pub placement_id: u32,
    /// Whether `placement_id` is a libghostty storage identity for protocol
    /// `p=0` rather than an ID supplied by the terminal application.
    pub is_internal: bool,
    pub x_offset: u32,
    pub y_offset: u32,
    pub source_x: u32,
    pub source_y: u32,
    pub source_width: u32,
    pub source_height: u32,
    /// Protocol `c` value, or zero when the placement omitted it.
    pub columns: u32,
    /// Protocol `r` value, or zero when the placement omitted it.
    pub rows: u32,
    pub grid_cols: u32,
    pub grid_rows: u32,
    pub pixel_width: u32,
    pub pixel_height: u32,
    pub viewport_col: i32,
    pub viewport_row: i32,
    pub viewport_visible: bool,
    /// Absolute cell anchor in the retained screen, counted from its oldest row.
    pub anchor: Option<KittyPlacementAnchor>,
    pub z: i32,
}

/// Immutable Kitty graphics state captured at the same boundary as text.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct KittyGraphicsSnapshot {
    pub generation: u64,
    pub images: Vec<KittyImage>,
    pub placements: Vec<KittyPlacement>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KittyPlacementAnchor {
    pub col: u16,
    pub row: u32,
}

pub(crate) struct KittyReplaySnapshot {
    pub graphics: KittyGraphicsSnapshot,
    pub anchors: BTreeMap<KittyPlacementKey, KittyPlacementAnchor>,
}

impl KittyGraphicsSnapshot {
    pub fn image(&self, id: u32) -> Option<&KittyImage> {
        self.images.iter().find(|image| image.id == id)
    }

    pub fn is_empty(&self) -> bool {
        self.images.is_empty() && self.placements.is_empty()
    }
}

struct ImageIterator(sys::GhosttyKittyGraphicsImageIterator);

impl Drop for ImageIterator {
    fn drop(&mut self) {
        // SAFETY: the iterator came from image_iterator_new and is owned only by
        // this guard, so it is freed once.
        unsafe { sys::ghostty_kitty_graphics_image_iterator_free(self.0) };
    }
}

struct PlacementIterator(sys::GhosttyKittyGraphicsPlacementIterator);

impl Drop for PlacementIterator {
    fn drop(&mut self) {
        // SAFETY: the iterator came from placement_iterator_new and is owned only
        // by this guard, so it is freed once.
        unsafe { sys::ghostty_kitty_graphics_placement_iterator_free(self.0) };
    }
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
struct PlacementSortKey {
    image_id: u32,
    placement_id: u32,
    is_internal: bool,
    z: i32,
    viewport_row: i32,
    viewport_col: i32,
    source_y: u32,
    source_x: u32,
    source_height: u32,
    source_width: u32,
    rows: u32,
    columns: u32,
    grid_rows: u32,
    grid_cols: u32,
    y_offset: u32,
    x_offset: u32,
}

impl From<&KittyPlacement> for PlacementSortKey {
    fn from(value: &KittyPlacement) -> Self {
        Self {
            image_id: value.image_id,
            placement_id: value.placement_id,
            is_internal: value.is_internal,
            z: value.z,
            viewport_row: value.viewport_row,
            viewport_col: value.viewport_col,
            source_y: value.source_y,
            source_x: value.source_x,
            source_height: value.source_height,
            source_width: value.source_width,
            rows: value.rows,
            columns: value.columns,
            grid_rows: value.grid_rows,
            grid_cols: value.grid_cols,
            y_offset: value.y_offset,
            x_offset: value.x_offset,
        }
    }
}

/// Decoded bytes a pixel map holds. Both maps (the renderer's and the replay
/// encoder's) keep only the current image generations (`snapshot_impl`), so
/// this is at most the terminal's native image bytes times the RGB expansion.
pub(crate) fn pixel_cache_bytes(pixel_cache: &HashMap<u64, Arc<[u8]>>) -> usize {
    pixel_cache.values().map(|pixels| pixels.len()).sum()
}

pub(crate) fn snapshot(
    terminal: &Terminal,
    pixel_cache: &mut HashMap<u64, Arc<[u8]>>,
    include_unplaced: bool,
) -> Result<KittyGraphicsSnapshot> {
    Ok(snapshot_impl(terminal, pixel_cache, include_unplaced)?.graphics)
}

/// Consume libghostty's renderer-owned graphics damage and return a complete
/// snapshot only when content or placement geometry changed. `force` binds a
/// reused render state to a different terminal even if another renderer had
/// already cleared that terminal's damage flag.
pub(crate) fn snapshot_for_render(
    terminal: &Terminal,
    pixel_cache: &mut HashMap<u64, Arc<[u8]>>,
    force: bool,
) -> Result<Option<KittyGraphicsSnapshot>> {
    let Some(graphics) = terminal_graphics(terminal)? else {
        if force {
            pixel_cache.clear();
        }
        return Ok(force.then(KittyGraphicsSnapshot::default));
    };
    if !force {
        let mut dirty = false;
        // SAFETY: `graphics` is the terminal's storage, valid while `&Terminal`
        // borrows it; GRAPHICS_DATA_DIRTY writes a bool.
        check(unsafe {
            sys::ghostty_kitty_graphics_get(
                graphics,
                sys::GHOSTTY_KITTY_GRAPHICS_DATA_DIRTY,
                (&mut dirty as *mut bool).cast(),
            )
        })?;
        if !dirty {
            return Ok(None);
        }
    }

    let snapshot = snapshot(terminal, pixel_cache, false)?;
    let clean = false;
    // SAFETY: `graphics` is still the terminal's live storage;
    // GRAPHICS_OPTION_DIRTY reads a bool from the live `clean`.
    check(unsafe {
        sys::ghostty_kitty_graphics_set(
            graphics,
            sys::GHOSTTY_KITTY_GRAPHICS_OPTION_DIRTY,
            (&clean as *const bool).cast(),
        )
    })?;
    Ok(Some(snapshot))
}

pub(crate) fn snapshot_for_replay(
    terminal: &Terminal,
    pixel_cache: &mut HashMap<u64, Arc<[u8]>>,
    include_unplaced: bool,
) -> Result<KittyReplaySnapshot> {
    snapshot_impl(terminal, pixel_cache, include_unplaced)
}

pub(crate) fn generation(terminal: &Terminal) -> Result<u64> {
    let Some(graphics) = terminal_graphics(terminal)? else {
        return Ok(0);
    };
    graphics_generation(graphics)
}

fn snapshot_impl(
    terminal: &Terminal,
    pixel_cache: &mut HashMap<u64, Arc<[u8]>>,
    include_unplaced: bool,
) -> Result<KittyReplaySnapshot> {
    let Some(graphics) = terminal_graphics(terminal)? else {
        return Ok(KittyReplaySnapshot {
            graphics: KittyGraphicsSnapshot::default(),
            anchors: BTreeMap::new(),
        });
    };

    let generation = graphics_generation(graphics)?;
    if generation == 0 {
        pixel_cache.clear();
        return Ok(KittyReplaySnapshot {
            graphics: KittyGraphicsSnapshot::default(),
            anchors: BTreeMap::new(),
        });
    }

    let mut images = BTreeMap::<u32, KittyImage>::new();
    if include_unplaced {
        let mut raw_images: sys::GhosttyKittyGraphicsImageIterator = ptr::null_mut();
        // SAFETY: `graphics` is the terminal's storage, valid while `&Terminal`
        // borrows it; `raw_images` is a writable local and a null allocator selects
        // the default.
        check(unsafe {
            sys::ghostty_kitty_graphics_image_iterator_new(ptr::null(), graphics, &mut raw_images)
        })?;
        let images_iterator = ImageIterator(raw_images);
        loop {
            // SAFETY: the iterator is live (its guard frees it at scope end).
            let raw_image = unsafe { sys::ghostty_kitty_graphics_image_next(images_iterator.0) };
            if raw_image.is_null() {
                break;
            }
            let image = copy_image(raw_image, pixel_cache)?;
            images.insert(image.id, image);
        }
    }

    let mut raw_iterator: sys::GhosttyKittyGraphicsPlacementIterator = ptr::null_mut();
    // SAFETY: `raw_iterator` is a writable local; a null allocator selects the
    // default.
    check(unsafe {
        sys::ghostty_kitty_graphics_placement_iterator_new(ptr::null(), &mut raw_iterator)
    })?;
    let mut iterator = PlacementIterator(raw_iterator);
    // SAFETY: `graphics` is the terminal's storage, valid while `&Terminal`
    // borrows it; PLACEMENT_ITERATOR fills the live iterator `iterator.0`.
    check(unsafe {
        sys::ghostty_kitty_graphics_get(
            graphics,
            sys::GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR,
            (&mut iterator.0 as *mut sys::GhosttyKittyGraphicsPlacementIterator).cast(),
        )
    })?;

    let mut placements = Vec::new();
    // SAFETY: the iterator is live (its guard frees it) and was filled above.
    while unsafe { sys::ghostty_kitty_graphics_placement_next(iterator.0) } {
        let image_id = placement_value::<u32>(
            iterator.0,
            sys::GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID,
        )?;
        let placement_id = placement_value::<u32>(
            iterator.0,
            sys::GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_PLACEMENT_ID,
        )?;
        let is_virtual = placement_value::<bool>(
            iterator.0,
            sys::GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IS_VIRTUAL,
        )?;
        if is_virtual {
            continue;
        }

        // SAFETY: `graphics` is the terminal's storage, unchanged while `&Terminal`
        // borrows it; the result is null or an image borrowed from it.
        let raw_image = unsafe { sys::ghostty_kitty_graphics_image(graphics, image_id) };
        if raw_image.is_null() {
            continue;
        }
        if let std::collections::btree_map::Entry::Vacant(entry) = images.entry(image_id) {
            entry.insert(copy_image(raw_image, pixel_cache)?);
        }

        let mut info = sys::GhosttyKittyGraphicsPlacementRenderInfo {
            size: size_of::<sys::GhosttyKittyGraphicsPlacementRenderInfo>(),
            ..Default::default()
        };
        // SAFETY: the iterator sits on a placement, `raw_image` is non-null from the
        // same storage, `terminal.raw()` is live, and `info` is sized.
        check(unsafe {
            sys::ghostty_kitty_graphics_placement_render_info(
                iterator.0,
                raw_image,
                terminal.raw(),
                &mut info,
            )
        })?;

        let mut rect = sys::GhosttySelection {
            size: size_of::<sys::GhosttySelection>(),
            ..Default::default()
        };
        // SAFETY: as above, and `rect` is a writable GhosttySelection with `size` set.
        check(unsafe {
            sys::ghostty_kitty_graphics_placement_rect(
                iterator.0,
                raw_image,
                terminal.raw(),
                &mut rect,
            )
        })?;
        let mut anchor = sys::GhosttyPointCoordinate::default();
        // SAFETY: `terminal.raw()` is live and `rect.start` came from it with no
        // mutation since; `anchor` is a writable local.
        check(unsafe {
            sys::ghostty_terminal_point_from_grid_ref(
                terminal.raw(),
                &rect.start,
                sys::GHOSTTY_POINT_TAG_SCREEN,
                &mut anchor,
            )
        })?;
        let anchor = KittyPlacementAnchor { col: anchor.x, row: anchor.y };

        placements.push(KittyPlacement {
            key: KittyPlacementKey { image_id, placement_id, ordinal: 0 },
            image_id,
            placement_id,
            is_internal: placement_value(
                iterator.0,
                sys::GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IS_INTERNAL,
            )?,
            x_offset: placement_value(
                iterator.0,
                sys::GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_X_OFFSET,
            )?,
            y_offset: placement_value(
                iterator.0,
                sys::GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Y_OFFSET,
            )?,
            source_x: info.source_x,
            source_y: info.source_y,
            source_width: info.source_width,
            source_height: info.source_height,
            columns: placement_value(
                iterator.0,
                sys::GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_COLUMNS,
            )?,
            rows: placement_value(iterator.0, sys::GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_ROWS)?,
            grid_cols: info.grid_cols,
            grid_rows: info.grid_rows,
            pixel_width: info.pixel_width,
            pixel_height: info.pixel_height,
            viewport_col: info.viewport_col,
            viewport_row: info.viewport_row,
            viewport_visible: info.viewport_visible,
            anchor: Some(anchor),
            z: placement_value(iterator.0, sys::GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Z)?,
        });
    }

    placements.sort_by_key(|placement| PlacementSortKey::from(placement));
    let mut ordinals = BTreeMap::<(u32, u32), u32>::new();
    let mut anchors = BTreeMap::new();
    for placement in &mut placements {
        let ordinal = ordinals.entry((placement.image_id, placement.placement_id)).or_default();
        placement.key.ordinal = *ordinal;
        *ordinal = ordinal.saturating_add(1);
        if let Some(anchor) = placement.anchor {
            anchors.insert(placement.key, anchor);
        }
    }
    let current_generations = images.values().map(|image| image.generation).collect::<HashSet<_>>();
    pixel_cache.retain(|image_generation, _| current_generations.contains(image_generation));

    Ok(KittyReplaySnapshot {
        graphics: KittyGraphicsSnapshot {
            generation,
            images: images.into_values().collect(),
            placements,
        },
        anchors,
    })
}

/// Whether the active screen holds Kitty state that libghostty's replay
/// encoder drops, found without encoding or copying pixels: an image with
/// pixels that no placement uses (the stream sends it without pixels), or a
/// placement whose rectangle is wholly outside the active area (the stream
/// sends only placements that show). The second also matches a relative
/// placement drawn wholly in scrollback by its offsets, which the stream
/// keeps; refusing that one too is the safe side.
pub(crate) fn active_scene_drops_from_replay(terminal: &Terminal) -> Result<bool> {
    let Some(graphics) = terminal_graphics(terminal)? else {
        return Ok(false);
    };

    let mut used = HashSet::new();
    let mut raw_iterator: sys::GhosttyKittyGraphicsPlacementIterator = ptr::null_mut();
    // SAFETY: `raw_iterator` is a writable local; a null allocator selects the
    // default.
    check(unsafe {
        sys::ghostty_kitty_graphics_placement_iterator_new(ptr::null(), &mut raw_iterator)
    })?;
    let mut iterator = PlacementIterator(raw_iterator);
    // SAFETY: `graphics` is the terminal's storage, valid while `&Terminal`
    // borrows it; PLACEMENT_ITERATOR fills the live iterator `iterator.0`.
    check(unsafe {
        sys::ghostty_kitty_graphics_get(
            graphics,
            sys::GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR,
            (&mut iterator.0 as *mut sys::GhosttyKittyGraphicsPlacementIterator).cast(),
        )
    })?;
    // SAFETY: the iterator is live (its guard frees it) and was filled above.
    while unsafe { sys::ghostty_kitty_graphics_placement_next(iterator.0) } {
        let image_id = placement_value::<u32>(
            iterator.0,
            sys::GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID,
        )?;
        used.insert(image_id);
        if placement_value::<bool>(
            iterator.0,
            sys::GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IS_VIRTUAL,
        )? {
            continue;
        }
        // SAFETY: `graphics` is the terminal's storage, unchanged while `&Terminal`
        // borrows it; the result is null or an image borrowed from it.
        let raw_image = unsafe { sys::ghostty_kitty_graphics_image(graphics, image_id) };
        if raw_image.is_null() {
            continue;
        }
        let mut rect = sys::GhosttySelection {
            size: size_of::<sys::GhosttySelection>(),
            ..Default::default()
        };
        // SAFETY: the iterator sits on a placement, `raw_image` is non-null from the
        // same storage, `terminal.raw()` is live, and `rect` is sized.
        check(unsafe {
            sys::ghostty_kitty_graphics_placement_rect(
                iterator.0,
                raw_image,
                terminal.raw(),
                &mut rect,
            )
        })?;
        if !in_active_area(terminal, &rect.start)? && !in_active_area(terminal, &rect.end)? {
            return Ok(true);
        }
    }

    let mut raw_images: sys::GhosttyKittyGraphicsImageIterator = ptr::null_mut();
    // SAFETY: `graphics` is the terminal's storage, valid while `&Terminal`
    // borrows it; `raw_images` is a writable local.
    check(unsafe {
        sys::ghostty_kitty_graphics_image_iterator_new(ptr::null(), graphics, &mut raw_images)
    })?;
    let images = ImageIterator(raw_images);
    loop {
        // SAFETY: the iterator is live (its guard frees it at scope end).
        let raw_image = unsafe { sys::ghostty_kitty_graphics_image_next(images.0) };
        if raw_image.is_null() {
            return Ok(false);
        }
        let id: u32 = image_value(raw_image, sys::GHOSTTY_KITTY_IMAGE_DATA_ID)?;
        let data_len: usize = image_value(raw_image, sys::GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN)?;
        if data_len > 0 && !used.contains(&id) {
            return Ok(true);
        }
    }
}

fn in_active_area(terminal: &Terminal, grid_ref: &sys::GhosttyGridRef) -> Result<bool> {
    // SAFETY: `grid_ref` came from this terminal with no mutation since;
    // a NULL out-pointer is allowed.
    match check(unsafe {
        sys::ghostty_terminal_point_from_grid_ref(
            terminal.raw(),
            grid_ref,
            sys::GHOSTTY_POINT_TAG_ACTIVE,
            ptr::null_mut(),
        )
    }) {
        Ok(()) => Ok(true),
        Err(Error::NoValue) => Ok(false),
        Err(error) => Err(error),
    }
}

fn graphics_generation(graphics: sys::GhosttyKittyGraphics) -> Result<u64> {
    graphics_value(graphics, sys::GHOSTTY_KITTY_GRAPHICS_DATA_GENERATION)
}

fn graphics_value<T: Default>(
    graphics: sys::GhosttyKittyGraphics,
    data: sys::GhosttyKittyGraphicsData,
) -> Result<T> {
    let mut value = T::default();
    // SAFETY: callers pass the live storage of a borrowed terminal and name `T`
    // as the type the header gives for `data` (GENERATION: uint64_t).
    check(unsafe {
        sys::ghostty_kitty_graphics_get(graphics, data, (&mut value as *mut T).cast())
    })?;
    Ok(value)
}

fn terminal_graphics(terminal: &Terminal) -> Result<Option<sys::GhosttyKittyGraphics>> {
    let mut graphics: sys::GhosttyKittyGraphics = ptr::null_mut();
    // SAFETY: `terminal.raw()` is live while `&Terminal` borrows it;
    // KITTY_GRAPHICS writes a GhosttyKittyGraphics handle into the local.
    match check(unsafe {
        sys::ghostty_terminal_get(
            terminal.raw(),
            sys::GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS,
            (&mut graphics as *mut sys::GhosttyKittyGraphics).cast(),
        )
    }) {
        Ok(()) if !graphics.is_null() => Ok(Some(graphics)),
        Ok(()) | Err(Error::NoValue) => Ok(None),
        Err(error) => Err(error),
    }
}

fn placement_value<T: Default>(
    iterator: sys::GhosttyKittyGraphicsPlacementIterator,
    data: sys::GhosttyKittyGraphicsPlacementData,
) -> Result<T> {
    let mut value = T::default();
    // SAFETY: callers pass an iterator sitting on a placement and name `T` as
    // the type the header gives for `data`.
    check(unsafe {
        sys::ghostty_kitty_graphics_placement_get(iterator, data, (&mut value as *mut T).cast())
    })?;
    Ok(value)
}

fn image_value<T: Default>(
    image: sys::GhosttyKittyGraphicsImage,
    data: sys::GhosttyKittyGraphicsImageData,
) -> Result<T> {
    let mut value = T::default();
    // SAFETY: callers pass a non-null image borrowed from unchanged storage and
    // name `T` as the type the header gives for `data`.
    check(unsafe {
        sys::ghostty_kitty_graphics_image_get(image, data, (&mut value as *mut T).cast())
    })?;
    Ok(value)
}

fn snapshot_image_format(raw: sys::GhosttyKittyImageFormat) -> Result<KittyImageFormat> {
    // Ghostty's Kitty parser accepts raw RGB/RGBA and normalizes PNGs to RGBA.
    // Its grayscale enum values cannot reach image storage through that parser,
    // so reject them instead of expanding bytes beyond the transport budget.
    match raw {
        sys::GHOSTTY_KITTY_IMAGE_FORMAT_RGB => Ok(KittyImageFormat::Rgb),
        sys::GHOSTTY_KITTY_IMAGE_FORMAT_RGBA => Ok(KittyImageFormat::Rgba),
        _ => Err(Error::InvalidValue),
    }
}

fn copy_image(
    image: sys::GhosttyKittyGraphicsImage,
    pixel_cache: &mut HashMap<u64, Arc<[u8]>>,
) -> Result<KittyImage> {
    let id = image_value(image, sys::GHOSTTY_KITTY_IMAGE_DATA_ID)?;
    let number = image_value(image, sys::GHOSTTY_KITTY_IMAGE_DATA_NUMBER)?;
    let generation = image_value(image, sys::GHOSTTY_KITTY_IMAGE_DATA_GENERATION)?;
    let width = image_value(image, sys::GHOSTTY_KITTY_IMAGE_DATA_WIDTH)?;
    let height = image_value(image, sys::GHOSTTY_KITTY_IMAGE_DATA_HEIGHT)?;
    let raw_format: sys::GhosttyKittyImageFormat =
        image_value(image, sys::GHOSTTY_KITTY_IMAGE_DATA_FORMAT)?;
    let format = snapshot_image_format(raw_format)?;
    let data_ptr: *const u8 = image_value(image, sys::GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR)?;
    let data_len: usize = image_value(image, sys::GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN)?;

    if let Some(data) = pixel_cache.get(&generation) {
        return Ok(KittyImage {
            id,
            number,
            generation,
            width,
            height,
            format,
            data: data.clone(),
        });
    }
    if data_ptr.is_null() && data_len != 0 {
        return Err(Error::InvalidValue);
    }
    let bytes = if data_len == 0 {
        &[][..]
    } else {
        // SAFETY: DATA_PTR/DATA_LEN describe the image's pixel bytes, checked
        // non-null above and owned by storage that `&Terminal` keeps unchanged.
        unsafe { std::slice::from_raw_parts(data_ptr, data_len) }
    };
    let data: Arc<[u8]> = Arc::from(bytes);
    let expected = usize::try_from(width)
        .ok()
        .and_then(|width| usize::try_from(height).ok().and_then(|height| width.checked_mul(height)))
        .and_then(|pixels| pixels.checked_mul(format.bytes_per_pixel()))
        .ok_or(Error::InvalidValue)?;
    if data.len() != expected {
        return Err(Error::InvalidValue);
    }
    pixel_cache.insert(generation, data.clone());
    Ok(KittyImage { id, number, generation, width, height, format, data })
}

pub(crate) fn install_png_decoder() -> Result<()> {
    static RESULT: OnceLock<sys::GhosttyResult> = OnceLock::new();
    // SAFETY: `decode_png` matches the GhosttySysDecodePngFn signature and lives
    // for the process; OnceLock installs it once.
    check(*RESULT.get_or_init(|| unsafe {
        sys::ghostty_sys_set(
            sys::GHOSTTY_SYS_OPT_DECODE_PNG,
            decode_png as *const () as *const c_void,
        )
    }))
}

unsafe extern "C" fn decode_png(
    _userdata: *mut c_void,
    allocator: *const sys::GhosttyAllocator,
    data: *const u8,
    data_len: usize,
    out: *mut sys::GhosttySysImage,
) -> bool {
    std::panic::catch_unwind(|| {
        if data.is_null() || out.is_null() || data_len > MAX_KITTY_IMAGE_BYTES {
            return false;
        }
        // SAFETY: libghostty passes `data_len` readable bytes at `data`, checked
        // non-null above.
        let encoded = unsafe { std::slice::from_raw_parts(data, data_len) };
        if !png_header_within_limits(encoded) {
            return false;
        }
        let mut decoder = png::Decoder::new(Cursor::new(encoded));
        decoder.set_limits(png::Limits { bytes: MAX_KITTY_IMAGE_BYTES });
        decoder.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
        let mut reader = match decoder.read_info() {
            Ok(reader) => reader,
            Err(_) => return false,
        };
        let decoded_len = reader.output_buffer_size();
        if decoded_len > MAX_KITTY_IMAGE_BYTES {
            return false;
        }
        let mut decoded = vec![0; decoded_len];
        let info = match reader.next_frame(&mut decoded) {
            Ok(info) => info,
            Err(_) => return false,
        };
        let pixel_count = match usize::try_from(info.width).ok().and_then(|width| {
            usize::try_from(info.height).ok().and_then(|height| width.checked_mul(height))
        }) {
            Some(count) => count,
            None => return false,
        };
        let rgba_len = match pixel_count.checked_mul(4) {
            Some(len) if len <= MAX_KITTY_IMAGE_BYTES => len,
            Some(_) | None => return false,
        };
        let source_len = info.buffer_size();
        if source_len > decoded.len() || source_len > MAX_KITTY_IMAGE_BYTES {
            return false;
        }
        let rgba = match info.color_type {
            png::ColorType::Rgba => {
                if source_len != rgba_len {
                    return false;
                }
                decoded.truncate(source_len);
                decoded
            }
            color_type => {
                let Some(source) = decoded.get(..source_len) else {
                    return false;
                };
                let mut rgba = Vec::with_capacity(rgba_len);
                match color_type {
                    png::ColorType::Rgb => {
                        for [red, green, blue] in source.as_chunks::<3>().0 {
                            rgba.extend_from_slice(&[*red, *green, *blue, 255]);
                        }
                    }
                    png::ColorType::GrayscaleAlpha => {
                        for [gray, alpha] in source.as_chunks::<2>().0 {
                            rgba.extend_from_slice(&[*gray, *gray, *gray, *alpha]);
                        }
                    }
                    png::ColorType::Grayscale => {
                        for value in source {
                            rgba.extend_from_slice(&[*value, *value, *value, 255]);
                        }
                    }
                    png::ColorType::Indexed | png::ColorType::Rgba => return false,
                }
                rgba
            }
        };
        if rgba.len() != rgba_len {
            return false;
        }
        // SAFETY: `allocator` is the one libghostty passed for this image (null
        // selects the default).
        let output = unsafe { sys::ghostty_alloc(allocator, rgba.len()) };
        if output.is_null() {
            return false;
        }
        // SAFETY: `output` holds `rgba.len()` bytes and does not overlap `rgba`;
        // `out` was checked non-null and libghostty passes it writable.
        unsafe {
            ptr::copy_nonoverlapping(rgba.as_ptr(), output, rgba.len());
            *out = sys::GhosttySysImage {
                width: info.width,
                height: info.height,
                data: output,
                data_len: rgba.len(),
            };
        }
        true
    })
    .unwrap_or(false)
}

fn png_header_within_limits(encoded: &[u8]) -> bool {
    let Some(signature) = encoded.get(..8) else {
        return false;
    };
    let Some(length) = encoded.get(8..12) else {
        return false;
    };
    let Some(kind) = encoded.get(12..16) else {
        return false;
    };
    let Some(width) = encoded.get(16..20).and_then(|bytes| <[u8; 4]>::try_from(bytes).ok()) else {
        return false;
    };
    let Some(height) = encoded.get(20..24).and_then(|bytes| <[u8; 4]>::try_from(bytes).ok()) else {
        return false;
    };
    if signature != PNG_SIGNATURE || length != 13_u32.to_be_bytes() || kind != b"IHDR" {
        return false;
    }
    let width = u32::from_be_bytes(width);
    let height = u32::from_be_bytes(height);
    width > 0
        && height > 0
        && usize::try_from(width)
            .ok()
            .and_then(|width| {
                usize::try_from(height).ok().and_then(|height| width.checked_mul(height))
            })
            .and_then(|pixels| pixels.checked_mul(4))
            .is_some_and(|bytes| bytes <= MAX_KITTY_IMAGE_BYTES)
}
