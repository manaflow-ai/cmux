use std::collections::{BTreeMap, HashMap};
use std::ffi::c_void;
use std::io::Cursor;
use std::mem::size_of;
use std::ptr;
use std::sync::{Arc, OnceLock};

use ghostty_vt_sys as sys;

use crate::terminal::Terminal;
use crate::{Error, Result, check};

pub(crate) const MAX_KITTY_IMAGE_BYTES: usize = 10_000_000;
const MAX_KITTY_INFLIGHT_BYTES: usize = (MAX_KITTY_IMAGE_BYTES * 4 + 2) / 3 + 256 * 1024;
const PNG_SIGNATURE: &[u8; 8] = b"\x89PNG\r\n\x1a\n";

#[cfg(test)]
static SNAPSHOT_IMAGE_VISITS: std::sync::atomic::AtomicUsize =
    std::sync::atomic::AtomicUsize::new(0);

#[cfg(test)]
fn record_snapshot_image_visit() {
    SNAPSHOT_IMAGE_VISITS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
}

#[cfg(not(test))]
fn record_snapshot_image_visit() {}

/// Bounded copy of a Kitty direct transmission that libghostty is still
/// assembling. A fresh attach terminal must consume this exact prefix before
/// it can understand later continuation chunks from the live byte stream.
#[derive(Default)]
pub(crate) struct KittyInFlightTracker {
    scan: KittyStreamScan,
    prefix: Vec<u8>,
    loading: bool,
    overflowed: bool,
}

impl KittyInFlightTracker {
    pub(crate) fn write(&mut self, data: &[u8]) {
        for &byte in data {
            let state = std::mem::take(&mut self.scan);
            self.scan = match state {
                KittyStreamScan::Ground => match byte {
                    0x1b => KittyStreamScan::Escape,
                    0x9f => KittyStreamScan::ApcType(KittyApcIntroducer::C1),
                    _ => KittyStreamScan::Ground,
                },
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
                    b'G' => KittyStreamScan::Kitty(KittyCommand::new(introducer)),
                    0x1b => KittyStreamScan::OtherApc { saw_escape: true },
                    0x9c => KittyStreamScan::Ground,
                    _ => KittyStreamScan::OtherApc { saw_escape: false },
                },
                KittyStreamScan::Kitty(mut command) => {
                    command.push(byte);
                    if byte == 0x9c {
                        self.finish_command(command);
                        KittyStreamScan::Ground
                    } else if command.saw_escape && byte == b'\\' {
                        self.finish_command(command);
                        KittyStreamScan::Ground
                    } else {
                        command.saw_escape = byte == 0x1b;
                        KittyStreamScan::Kitty(command)
                    }
                }
                KittyStreamScan::OtherApc { saw_escape } => {
                    if byte == 0x9c || (saw_escape && byte == b'\\') {
                        KittyStreamScan::Ground
                    } else {
                        KittyStreamScan::OtherApc { saw_escape: byte == 0x1b }
                    }
                }
            };
        }
    }

    pub(crate) fn replay_prefix(&self, max_bytes: usize) -> Vec<u8> {
        if self.overflowed {
            return Vec::new();
        }
        let partial = match &self.scan {
            KittyStreamScan::Escape => &b"\x1b"[..],
            KittyStreamScan::ApcType(KittyApcIntroducer::Esc) => &b"\x1b_"[..],
            KittyStreamScan::ApcType(KittyApcIntroducer::C1) => &b"\x9f"[..],
            KittyStreamScan::Kitty(command) if !command.overflowed => &command.bytes,
            _ => &[],
        };
        let prefix = self.loading.then_some(self.prefix.as_slice()).unwrap_or_default();
        let Some(total) = prefix.len().checked_add(partial.len()) else {
            return Vec::new();
        };
        if total > max_bytes {
            return Vec::new();
        }
        let mut replay = Vec::with_capacity(total);
        replay.extend_from_slice(prefix);
        replay.extend_from_slice(partial);
        replay
    }

    fn finish_command(&mut self, command: KittyCommand) {
        let Some(more) = kitty_transmission_more(&command.bytes) else {
            return;
        };
        if more {
            if !self.loading {
                self.prefix.clear();
                self.overflowed = false;
            }
            self.loading = true;
            if self.overflowed || command.overflowed {
                self.prefix.clear();
                self.overflowed = true;
                return;
            }
            let Some(total) = self.prefix.len().checked_add(command.bytes.len()) else {
                self.prefix.clear();
                self.overflowed = true;
                return;
            };
            if total > MAX_KITTY_INFLIGHT_BYTES {
                self.prefix.clear();
                self.overflowed = true;
                return;
            }
            self.prefix.extend_from_slice(&command.bytes);
        } else {
            self.clear_loading();
        }
    }

    fn clear_loading(&mut self) {
        self.prefix.clear();
        self.loading = false;
        self.overflowed = false;
    }
}

#[derive(Default)]
enum KittyStreamScan {
    #[default]
    Ground,
    Escape,
    ApcType(KittyApcIntroducer),
    Kitty(KittyCommand),
    OtherApc {
        saw_escape: bool,
    },
}

enum KittyApcIntroducer {
    Esc,
    C1,
}

struct KittyCommand {
    bytes: Vec<u8>,
    saw_escape: bool,
    overflowed: bool,
}

impl KittyCommand {
    fn new(introducer: KittyApcIntroducer) -> Self {
        let bytes = match introducer {
            KittyApcIntroducer::Esc => b"\x1b_G".to_vec(),
            KittyApcIntroducer::C1 => b"\x9fG".to_vec(),
        };
        Self { bytes, saw_escape: false, overflowed: false }
    }

    fn push(&mut self, byte: u8) {
        if self.bytes.len() < MAX_KITTY_INFLIGHT_BYTES {
            self.bytes.push(byte);
        } else {
            self.overflowed = true;
        }
    }
}

fn kitty_transmission_more(command: &[u8]) -> Option<bool> {
    let header_start = if command.starts_with(b"\x1b_G") {
        3
    } else if command.starts_with(b"\x9fG") {
        2
    } else {
        return None;
    };
    let header_end = command[header_start..].iter().position(|byte| *byte == b';')? + header_start;
    let mut action = b't';
    let mut direct = true;
    let mut more = false;
    for parameter in command[header_start..header_end].split(|byte| *byte == b',') {
        let Some(separator) = parameter.iter().position(|byte| *byte == b'=') else {
            continue;
        };
        let key = &parameter[..separator];
        let value = &parameter[separator + 1..];
        match key {
            b"a" => action = *value.first()?,
            b"t" => direct = value == b"d",
            b"m" => more = value != b"0",
            _ => {}
        }
    }
    matches!(action, b't' | b'T').then_some(more && direct)
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
    pub z: i32,
}

/// Immutable Kitty graphics state captured at the same boundary as text.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct KittyGraphicsSnapshot {
    pub generation: u64,
    pub images: Vec<KittyImage>,
    pub placements: Vec<KittyPlacement>,
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
        unsafe { sys::ghostty_kitty_graphics_image_iterator_free(self.0) };
    }
}

struct PlacementIterator(sys::GhosttyKittyGraphicsPlacementIterator);

impl Drop for PlacementIterator {
    fn drop(&mut self) {
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

pub(crate) fn snapshot(
    terminal: &Terminal,
    pixel_cache: &mut HashMap<u64, Arc<[u8]>>,
    include_unplaced: bool,
) -> Result<KittyGraphicsSnapshot> {
    let mut graphics: sys::GhosttyKittyGraphics = ptr::null_mut();
    match check(unsafe {
        sys::ghostty_terminal_get(
            terminal.raw(),
            sys::GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS,
            (&mut graphics as *mut sys::GhosttyKittyGraphics).cast(),
        )
    }) {
        Ok(()) => {}
        Err(Error::NoValue) => return Ok(KittyGraphicsSnapshot::default()),
        Err(error) => return Err(error),
    }
    if graphics.is_null() {
        return Ok(KittyGraphicsSnapshot::default());
    }

    let mut generation = 0_u64;
    check(unsafe {
        sys::ghostty_kitty_graphics_get(
            graphics,
            sys::GHOSTTY_KITTY_GRAPHICS_DATA_GENERATION,
            (&mut generation as *mut u64).cast(),
        )
    })?;
    if generation == 0 {
        return Ok(KittyGraphicsSnapshot::default());
    }

    let mut images = BTreeMap::<u32, KittyImage>::new();
    if include_unplaced {
        let mut raw_images: sys::GhosttyKittyGraphicsImageIterator = ptr::null_mut();
        check(unsafe {
            sys::ghostty_kitty_graphics_image_iterator_new(ptr::null(), graphics, &mut raw_images)
        })?;
        let images_iterator = ImageIterator(raw_images);
        loop {
            let raw_image = unsafe { sys::ghostty_kitty_graphics_image_next(images_iterator.0) };
            if raw_image.is_null() {
                break;
            }
            record_snapshot_image_visit();
            let image = copy_image(raw_image, pixel_cache)?;
            images.insert(image.id, image);
        }
    }

    let mut raw_iterator: sys::GhosttyKittyGraphicsPlacementIterator = ptr::null_mut();
    check(unsafe {
        sys::ghostty_kitty_graphics_placement_iterator_new(ptr::null(), &mut raw_iterator)
    })?;
    let mut iterator = PlacementIterator(raw_iterator);
    check(unsafe {
        sys::ghostty_kitty_graphics_get(
            graphics,
            sys::GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR,
            (&mut iterator.0 as *mut sys::GhosttyKittyGraphicsPlacementIterator).cast(),
        )
    })?;

    let mut placements = Vec::new();
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
        check(unsafe {
            sys::ghostty_kitty_graphics_placement_render_info(
                iterator.0,
                raw_image,
                terminal.raw(),
                &mut info,
            )
        })?;

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
            z: placement_value(iterator.0, sys::GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Z)?,
        });
    }

    placements.sort_by_key(|placement| PlacementSortKey::from(&*placement));
    let mut ordinals = BTreeMap::<(u32, u32), u32>::new();
    for placement in &mut placements {
        let ordinal = ordinals.entry((placement.image_id, placement.placement_id)).or_default();
        placement.key.ordinal = *ordinal;
        *ordinal = ordinal.saturating_add(1);
    }
    pixel_cache.retain(|image_generation, _| {
        images.values().any(|image| image.generation == *image_generation)
    });

    Ok(KittyGraphicsSnapshot { generation, images: images.into_values().collect(), placements })
}

fn placement_value<T: Default>(
    iterator: sys::GhosttyKittyGraphicsPlacementIterator,
    data: sys::GhosttyKittyGraphicsPlacementData,
) -> Result<T> {
    let mut value = T::default();
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
    check(unsafe {
        sys::ghostty_kitty_graphics_image_get(image, data, (&mut value as *mut T).cast())
    })?;
    Ok(value)
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
    let data_ptr: *const u8 = image_value(image, sys::GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR)?;
    let data_len: usize = image_value(image, sys::GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN)?;

    if let Some(data) = pixel_cache.get(&generation) {
        let format = match raw_format {
            sys::GHOSTTY_KITTY_IMAGE_FORMAT_RGB | sys::GHOSTTY_KITTY_IMAGE_FORMAT_GRAY => {
                KittyImageFormat::Rgb
            }
            _ => KittyImageFormat::Rgba,
        };
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
        unsafe { std::slice::from_raw_parts(data_ptr, data_len) }
    };
    let (format, data): (KittyImageFormat, Arc<[u8]>) = match raw_format {
        sys::GHOSTTY_KITTY_IMAGE_FORMAT_RGB => (KittyImageFormat::Rgb, Arc::from(bytes)),
        sys::GHOSTTY_KITTY_IMAGE_FORMAT_RGBA => (KittyImageFormat::Rgba, Arc::from(bytes)),
        sys::GHOSTTY_KITTY_IMAGE_FORMAT_GRAY => {
            let converted = bytes.iter().flat_map(|value| [*value; 3]).collect::<Vec<_>>();
            (KittyImageFormat::Rgb, converted.into())
        }
        sys::GHOSTTY_KITTY_IMAGE_FORMAT_GRAY_ALPHA => {
            let converted = bytes
                .chunks_exact(2)
                .flat_map(|pixel| [pixel[0], pixel[0], pixel[0], pixel[1]])
                .collect::<Vec<_>>();
            (KittyImageFormat::Rgba, converted.into())
        }
        _ => return Err(Error::InvalidValue),
    };
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
                let source = &decoded[..source_len];
                let mut rgba = Vec::with_capacity(rgba_len);
                match color_type {
                    png::ColorType::Rgb => {
                        for pixel in source.chunks_exact(3) {
                            rgba.extend_from_slice(&[pixel[0], pixel[1], pixel[2], 255]);
                        }
                    }
                    png::ColorType::GrayscaleAlpha => {
                        for pixel in source.chunks_exact(2) {
                            rgba.extend_from_slice(&[pixel[0], pixel[0], pixel[0], pixel[1]]);
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
        let output = unsafe { sys::ghostty_alloc(allocator, rgba.len()) };
        if output.is_null() {
            return false;
        }
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
    let Some(width) = encoded.get(16..20) else {
        return false;
    };
    let Some(height) = encoded.get(20..24) else {
        return false;
    };
    if signature != PNG_SIGNATURE || length != 13_u32.to_be_bytes() || kind != b"IHDR" {
        return false;
    }
    let width = u32::from_be_bytes(width.try_into().unwrap());
    let height = u32::from_be_bytes(height.try_into().unwrap());
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inflight_tracker_replays_completed_and_partial_chunks() {
        let first = b"\x1b_Ga=t,t=d,f=24,i=92,s=1,v=2,m=1;AAAA\x1b\\";
        let partial = b"\x1b_Gm=0;AA";
        let mut tracker = KittyInFlightTracker::default();

        for bytes in first.chunks(3) {
            tracker.write(bytes);
        }
        for bytes in partial.chunks(2) {
            tracker.write(bytes);
        }

        let mut expected = first.to_vec();
        expected.extend_from_slice(partial);
        assert_eq!(tracker.replay_prefix(usize::MAX), expected);
    }

    #[test]
    fn inflight_tracker_clears_only_for_a_final_direct_transmission() {
        let first = b"\x1b_Ga=T,t=d,f=24,i=92,s=1,v=2,m=1;AAAA\x1b\\";
        let placement = b"\x1b_Ga=p,i=92,p=1,c=1,r=1\x1b\\";
        let final_chunk = b"\x1b_Gm=0;AAAA\x1b\\";
        let mut tracker = KittyInFlightTracker::default();

        tracker.write(first);
        tracker.write(placement);
        assert_eq!(tracker.replay_prefix(usize::MAX), first);

        tracker.write(final_chunk);
        assert!(tracker.replay_prefix(usize::MAX).is_empty());
    }

    #[test]
    fn inflight_tracker_handles_c1_apc_and_terminal_reset() {
        let first = b"\x9fGa=t,t=d,f=24,i=92,s=1,v=2,m=1;AAAA\x9c";
        let mut tracker = KittyInFlightTracker::default();

        tracker.write(first);
        assert_eq!(tracker.replay_prefix(usize::MAX), first);

        tracker.write(b"\x1bc");
        assert!(tracker.replay_prefix(usize::MAX).is_empty());
    }

    #[test]
    fn snapshot_enumerates_each_stored_image_once() {
        let mut terminal = Terminal::new(20, 8, 100, crate::Callbacks::default()).unwrap();
        for number in 1..=64 {
            terminal.vt_write(
                format!("\x1b_Ga=t,t=d,f=24,I={number},s=1,v=1,q=2;AAAA\x1b\\").as_bytes(),
            );
        }
        terminal.vt_write(b"\x1b_Ga=t,t=d,f=24,s=1,v=1,q=2;AAEA\x1b\\");

        SNAPSHOT_IMAGE_VISITS.store(0, std::sync::atomic::Ordering::Relaxed);
        let graphics = snapshot(&terminal, &mut HashMap::new(), true).unwrap();

        assert_eq!(graphics.images.len(), 65);
        assert_eq!(
            SNAPSHOT_IMAGE_VISITS.load(std::sync::atomic::Ordering::Relaxed),
            graphics.images.len()
        );
        assert_eq!(graphics.images.iter().filter(|image| image.number == 0).count(), 1);
    }

    #[test]
    fn png_header_rejects_dimensions_above_the_decode_bound() {
        let mut header = Vec::from(*PNG_SIGNATURE);
        header.extend_from_slice(&13_u32.to_be_bytes());
        header.extend_from_slice(b"IHDR");
        header.extend_from_slice(&5_000_u32.to_be_bytes());
        header.extend_from_slice(&5_000_u32.to_be_bytes());
        assert!(!png_header_within_limits(&header));

        header[16..20].copy_from_slice(&1_u32.to_be_bytes());
        header[20..24].copy_from_slice(&1_u32.to_be_bytes());
        assert!(png_header_within_limits(&header));
    }
}
