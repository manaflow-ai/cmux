use std::collections::{BTreeMap, BTreeSet, HashMap, VecDeque};
use std::ffi::c_void;
use std::io::Cursor;
use std::mem::size_of;
use std::ptr;
use std::sync::{Arc, OnceLock};

use ghostty_vt_sys as sys;

use crate::terminal::Terminal;
use crate::{Error, Result, check};

pub(crate) const MAX_KITTY_IMAGE_BYTES: usize = 10_000_000;
const MAX_TRACKED_IMAGE_IDS: usize = 65_536;
const MAX_KITTY_HEADER_BYTES: usize = 4_096;
const PNG_SIGNATURE: &[u8; 8] = b"\x89PNG\r\n\x1a\n";

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
    pub generation: u64,
    pub width: u32,
    pub height: u32,
    pub format: KittyImageFormat,
    pub data: Arc<[u8]>,
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
    pub x_offset: u32,
    pub y_offset: u32,
    pub source_x: u32,
    pub source_y: u32,
    pub source_width: u32,
    pub source_height: u32,
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

/// Bounded scanner for explicit image IDs in Kitty APC headers.
///
/// libghostty can look an image up by ID but cannot enumerate images with no
/// placements. Remembering IDs from the byte stream lets attach replay cover
/// the gap between an `a=t` transmission and a later `a=p`.
pub(crate) struct KittyImageIdTracker {
    scan: KittyScanState,
    known: BTreeSet<u32>,
    order: VecDeque<u32>,
}

impl Default for KittyImageIdTracker {
    fn default() -> Self {
        Self { scan: KittyScanState::Ground, known: BTreeSet::new(), order: VecDeque::new() }
    }
}

impl KittyImageIdTracker {
    pub(crate) fn write(&mut self, data: &[u8]) {
        for &byte in data {
            let state = std::mem::replace(&mut self.scan, KittyScanState::Ground);
            self.scan = match state {
                KittyScanState::Ground => match byte {
                    0x1b => KittyScanState::Escape,
                    0x9f => KittyScanState::ApcType,
                    _ => KittyScanState::Ground,
                },
                KittyScanState::Escape => match byte {
                    b'_' => KittyScanState::ApcType,
                    0x1b => KittyScanState::Escape,
                    _ => KittyScanState::Ground,
                },
                KittyScanState::ApcType => match byte {
                    b'G' => KittyScanState::KittyHeader(Vec::new()),
                    0x1b => KittyScanState::OtherEscape,
                    0x9c => KittyScanState::Ground,
                    _ => KittyScanState::Other,
                },
                KittyScanState::KittyHeader(mut header) => match byte {
                    b';' => {
                        if let Some(id) = kitty_header_image_id(&header) {
                            self.remember(id);
                        }
                        KittyScanState::KittyPayload
                    }
                    0x1b => KittyScanState::OtherEscape,
                    0x9c => KittyScanState::Ground,
                    _ if header.len() < MAX_KITTY_HEADER_BYTES => {
                        header.push(byte);
                        KittyScanState::KittyHeader(header)
                    }
                    _ => KittyScanState::Other,
                },
                KittyScanState::KittyPayload => match byte {
                    0x1b => KittyScanState::KittyPayloadEscape,
                    0x9c => KittyScanState::Ground,
                    _ => KittyScanState::KittyPayload,
                },
                KittyScanState::KittyPayloadEscape => match byte {
                    b'\\' | 0x9c => KittyScanState::Ground,
                    0x1b => KittyScanState::KittyPayloadEscape,
                    _ => KittyScanState::KittyPayload,
                },
                KittyScanState::Other => match byte {
                    0x1b => KittyScanState::OtherEscape,
                    0x9c => KittyScanState::Ground,
                    _ => KittyScanState::Other,
                },
                KittyScanState::OtherEscape => match byte {
                    b'\\' | 0x9c => KittyScanState::Ground,
                    0x1b => KittyScanState::OtherEscape,
                    _ => KittyScanState::Other,
                },
            };
        }
    }

    pub(crate) fn ids(&self) -> impl Iterator<Item = u32> + '_ {
        self.known.iter().copied()
    }

    fn remember(&mut self, id: u32) {
        if id == 0 || self.known.contains(&id) {
            return;
        }
        if self.known.len() == MAX_TRACKED_IMAGE_IDS
            && let Some(oldest) = self.order.pop_front()
        {
            self.known.remove(&oldest);
        }
        self.known.insert(id);
        self.order.push_back(id);
    }
}

enum KittyScanState {
    Ground,
    Escape,
    ApcType,
    KittyHeader(Vec<u8>),
    KittyPayload,
    KittyPayloadEscape,
    Other,
    OtherEscape,
}

fn kitty_header_image_id(header: &[u8]) -> Option<u32> {
    header.split(|byte| *byte == b',').find_map(|parameter| {
        let mut parts = parameter.splitn(2, |byte| *byte == b'=');
        let key = parts.next()?;
        let value = parts.next()?;
        (key == b"i").then(|| std::str::from_utf8(value).ok()?.parse().ok()).flatten()
    })
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
    z: i32,
    viewport_row: i32,
    viewport_col: i32,
    source_y: u32,
    source_x: u32,
    source_height: u32,
    source_width: u32,
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
            z: value.z,
            viewport_row: value.viewport_row,
            viewport_col: value.viewport_col,
            source_y: value.source_y,
            source_x: value.source_x,
            source_height: value.source_height,
            source_width: value.source_width,
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

    let mut images = BTreeMap::<u32, KittyImage>::new();
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

    if include_unplaced {
        for image_id in terminal.known_kitty_image_ids() {
            if images.contains_key(&image_id) {
                continue;
            }
            let raw_image = unsafe { sys::ghostty_kitty_graphics_image(graphics, image_id) };
            if !raw_image.is_null() {
                images.insert(image_id, copy_image(raw_image, pixel_cache)?);
            }
        }
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
        return Ok(KittyImage { id, generation, width, height, format, data: data.clone() });
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
    Ok(KittyImage { id, generation, width, height, format, data })
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
    fn scanner_tracks_split_kitty_headers_without_buffering_payloads() {
        let mut tracker = KittyImageIdTracker::default();
        tracker.write(b"before\x1b_Ga=t,t=d,i=");
        tracker.write(b"42,s=1,v=1;");
        tracker.write(&vec![b'A'; MAX_KITTY_HEADER_BYTES * 2]);
        tracker.write(b"\x1b\\after");
        assert_eq!(tracker.ids().collect::<Vec<_>>(), vec![42]);
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
