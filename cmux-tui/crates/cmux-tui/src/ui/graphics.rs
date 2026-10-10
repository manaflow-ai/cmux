use std::borrow::Cow;
use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::sync::Arc;
#[cfg(test)]
use std::sync::{Mutex, OnceLock, mpsc::Sender};
use std::time::Duration;
#[cfg(unix)]
use std::time::Instant;

use base64::Engine as _;
use cmux_tui_core::{BrowserFrame, Rect, SurfaceId};
use ghostty_vt::{KittyImage, KittyImageFormat, KittyPlacement};

const ESC: &str = "\x1b";
const CHUNK: usize = 4096;
pub(crate) const PROCESSING_FENCE_ID_BASE: u32 = 2_000_000_001;
const PROCESSING_FENCE_ID_COUNT: u64 = 2_000_000_000;

#[cfg(test)]
static IMAGE_TRANSMISSION_OBSERVER: OnceLock<Mutex<Option<Sender<GraphicImageKey>>>> =
    OnceLock::new();

#[cfg(test)]
pub(super) fn observe_image_transmissions(observer: Sender<GraphicImageKey>) {
    *IMAGE_TRANSMISSION_OBSERVER.get_or_init(|| Mutex::new(None)).lock().unwrap() = Some(observer);
}

#[cfg(test)]
pub(super) fn clear_image_transmission_observer() {
    *IMAGE_TRANSMISSION_OBSERVER.get_or_init(|| Mutex::new(None)).lock().unwrap() = None;
}

#[cfg(test)]
fn record_image_transmission(key: GraphicImageKey) {
    if let Some(observer) =
        IMAGE_TRANSMISSION_OBSERVER.get_or_init(|| Mutex::new(None)).lock().unwrap().as_ref()
    {
        let _ = observer.send(key);
    }
}

#[cfg(not(test))]
fn record_image_transmission(_key: GraphicImageKey) {}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct GraphicImageKey {
    pub namespace: u64,
    pub surface: SurfaceId,
    pub image_id: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct GraphicPlacementKey {
    pub image: GraphicImageKey,
    pub placement_id: u32,
    pub ordinal: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GraphicFormat {
    Png,
    Rgb,
    Rgba,
}

impl GraphicFormat {
    fn kitty_value(self) -> u8 {
        match self {
            Self::Png => 100,
            Self::Rgb => 24,
            Self::Rgba => 32,
        }
    }
}

#[derive(Debug, Clone)]
pub enum GraphicData {
    #[cfg(test)]
    Base64(Arc<str>),
    BrowserFrame(Arc<BrowserFrame>),
    Bytes(Arc<[u8]>),
}

impl GraphicData {
    fn base64(&self) -> Cow<'_, str> {
        match self {
            #[cfg(test)]
            Self::Base64(encoded) => Cow::Borrowed(encoded),
            Self::BrowserFrame(frame) => Cow::Borrowed(&frame.data_b64),
            Self::Bytes(bytes) => {
                Cow::Owned(base64::engine::general_purpose::STANDARD.encode(bytes))
            }
        }
    }
}

#[derive(Debug, Clone)]
pub struct GraphicImage {
    pub key: GraphicImageKey,
    pub generation: u64,
    pub width: u32,
    pub height: u32,
    pub format: GraphicFormat,
    pub data: GraphicData,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GraphicSourceRect {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Clone)]
pub struct GraphicPlacement {
    pub key: GraphicPlacementKey,
    pub image: Arc<GraphicImage>,
    pub rect: Rect,
    /// Browser input authority paired with these pixels. Terminal images
    /// leave this unset.
    pub pointer_frame_seq: Option<u64>,
    pub columns: Option<u32>,
    pub rows: Option<u32>,
    pub source: Option<GraphicSourceRect>,
    pub x_offset: u32,
    pub y_offset: u32,
    pub z: i32,
}

impl GraphicPlacement {
    pub fn is_browser_frame(&self) -> bool {
        match &self.image.data {
            GraphicData::BrowserFrame(_) => true,
            #[cfg(test)]
            GraphicData::Base64(_) => self.image.key.image_id == 0,
            GraphicData::Bytes(_) => false,
        }
    }

    pub fn browser_frame(
        namespace: u64,
        surface: SurfaceId,
        rect: Rect,
        frame: Arc<BrowserFrame>,
        pointer_frame_seq: Option<u64>,
        source: Option<GraphicSourceRect>,
    ) -> Self {
        let image_key = GraphicImageKey { namespace, surface, image_id: 0 };
        Self {
            key: GraphicPlacementKey { image: image_key, placement_id: 0, ordinal: 0 },
            image: Arc::new(GraphicImage {
                key: image_key,
                generation: frame.seq,
                width: frame.image_width,
                height: frame.image_height,
                format: GraphicFormat::Png,
                data: GraphicData::BrowserFrame(frame),
            }),
            rect,
            pointer_frame_seq,
            columns: Some(u32::from(rect.width)),
            rows: Some(u32::from(rect.height)),
            source,
            x_offset: 0,
            y_offset: 0,
            z: 0,
        }
    }

    #[cfg(test)]
    pub fn browser(
        namespace: u64,
        surface: SurfaceId,
        rect: Rect,
        generation: u64,
        width: u32,
        height: u32,
        data_b64: String,
    ) -> Self {
        let image_key = GraphicImageKey { namespace, surface, image_id: 0 };
        Self {
            key: GraphicPlacementKey { image: image_key, placement_id: 0, ordinal: 0 },
            image: Arc::new(GraphicImage {
                key: image_key,
                generation,
                width,
                height,
                format: GraphicFormat::Png,
                data: GraphicData::Base64(Arc::from(data_b64)),
            }),
            rect,
            pointer_frame_seq: Some(generation),
            columns: Some(u32::from(rect.width)),
            rows: Some(u32::from(rect.height)),
            source: None,
            x_offset: 0,
            y_offset: 0,
            z: 0,
        }
    }
}

pub fn kitty_graphic_image(
    namespace: u64,
    surface: SurfaceId,
    image: &KittyImage,
) -> Arc<GraphicImage> {
    Arc::new(GraphicImage {
        key: GraphicImageKey { namespace, surface, image_id: image.id },
        generation: image.generation,
        width: image.width,
        height: image.height,
        format: match image.format {
            KittyImageFormat::Rgb => GraphicFormat::Rgb,
            KittyImageFormat::Rgba => GraphicFormat::Rgba,
        },
        data: GraphicData::Bytes(image.data.clone()),
    })
}

/// Resolve a libghostty viewport placement into the outer terminal grid.
///
/// Negative origins and right/bottom overflow are cropped proportionally
/// in source-pixel space so images never bleed outside their pane.
pub fn kitty_graphic_placement(
    pane: Rect,
    viewport_col_offset: u16,
    cell_pixels: (u16, u16),
    image: Arc<GraphicImage>,
    placement: &KittyPlacement,
) -> Option<GraphicPlacement> {
    if !placement.viewport_visible
        || pane.width == 0
        || pane.height == 0
        || placement.pixel_width == 0
        || placement.pixel_height == 0
        || placement.source_width == 0
        || placement.source_height == 0
    {
        return None;
    }

    let cell_width = u32::from(cell_pixels.0.max(1));
    let cell_height = u32::from(cell_pixels.1.max(1));
    let cell_width_i64 = i64::from(cell_width);
    let cell_height_i64 = i64::from(cell_height);
    let pane_width = i64::from(pane.width) * cell_width_i64;
    let pane_height = i64::from(pane.height) * cell_height_i64;
    let image_left = (i64::from(placement.viewport_col) - i64::from(viewport_col_offset))
        * cell_width_i64
        + i64::from(placement.x_offset);
    let image_top =
        i64::from(placement.viewport_row) * cell_height_i64 + i64::from(placement.y_offset);
    let image_right = image_left.saturating_add(i64::from(placement.pixel_width));
    let image_bottom = image_top.saturating_add(i64::from(placement.pixel_height));
    let visible_left = image_left.max(0);
    let visible_top = image_top.max(0);
    let mut visible_width = image_right.min(pane_width).saturating_sub(visible_left);
    let mut visible_height = image_bottom.min(pane_height).saturating_sub(visible_top);
    if visible_width <= 0 || visible_height <= 0 {
        return None;
    }

    // Explicit Kitty axes can only occupy whole cells. Keep the inferred axes
    // omitted and conservatively discard only an unrepresentable trailing
    // partial cell on explicit axes.
    if placement.columns > 0 {
        visible_width -= visible_width % cell_width_i64;
    }
    if placement.rows > 0 {
        visible_height -= visible_height % cell_height_i64;
    }
    if visible_width <= 0 || visible_height <= 0 {
        return None;
    }

    let source_left = proportional_boundary(
        placement.source_width,
        u32::try_from(visible_left.saturating_sub(image_left)).ok()?,
        placement.pixel_width,
    );
    let source_right = proportional_boundary(
        placement.source_width,
        u32::try_from(visible_left.saturating_add(visible_width).saturating_sub(image_left))
            .ok()?,
        placement.pixel_width,
    );
    let source_top = proportional_boundary(
        placement.source_height,
        u32::try_from(visible_top.saturating_sub(image_top)).ok()?,
        placement.pixel_height,
    );
    let source_bottom = proportional_boundary(
        placement.source_height,
        u32::try_from(visible_top.saturating_add(visible_height).saturating_sub(image_top)).ok()?,
        placement.pixel_height,
    );
    let mut source = GraphicSourceRect {
        x: placement.source_x.saturating_add(source_left),
        y: placement.source_y.saturating_add(source_top),
        width: source_right.saturating_sub(source_left),
        height: source_bottom.saturating_sub(source_top),
    };
    if source.width == 0 || source.height == 0 {
        return None;
    }

    let columns = if placement.columns > 0 {
        Some(u32::try_from(visible_width).ok()?.checked_div(cell_width)?)
    } else {
        None
    };
    let rows = if placement.rows > 0 {
        Some(u32::try_from(visible_height).ok()?.checked_div(cell_height)?)
    } else {
        None
    };
    if placement.columns > 0 && columns == Some(0) || placement.rows > 0 && rows == Some(0) {
        return None;
    }

    // Source-boundary rounding can make an inferred axis one pixel too large.
    // Trim only the trailing source edge until the actual Kitty result fits.
    if columns.is_some() && rows.is_none() {
        source.height = fit_inferred_source_dimension(
            columns?.saturating_mul(cell_width),
            source.width,
            source.height,
            u32::try_from(visible_height).ok()?,
        );
    } else if columns.is_none() && rows.is_some() {
        source.width = fit_inferred_source_dimension(
            rows?.saturating_mul(cell_height),
            source.height,
            source.width,
            u32::try_from(visible_width).ok()?,
        );
    } else if columns.is_none() && rows.is_none() {
        source.width = source.width.min(u32::try_from(visible_width).ok()?);
        source.height = source.height.min(u32::try_from(visible_height).ok()?);
    }
    if source.width == 0 || source.height == 0 {
        return None;
    }

    let (rendered_width, rendered_height) =
        rendered_pixel_size(source, columns, rows, cell_width, cell_height)?;
    let output_right = visible_left.saturating_add(i64::from(rendered_width));
    let output_bottom = visible_top.saturating_add(i64::from(rendered_height));
    if output_right > pane_width || output_bottom > pane_height {
        return None;
    }
    let cursor_col = u32::try_from(visible_left).ok()?.checked_div(cell_width)?;
    let cursor_row = u32::try_from(visible_top).ok()?.checked_div(cell_height)?;
    let x_offset = u32::try_from(visible_left).ok()? % cell_width;
    let y_offset = u32::try_from(visible_top).ok()? % cell_height;
    let grid_cols = x_offset.saturating_add(rendered_width).div_ceil(cell_width);
    let grid_rows = y_offset.saturating_add(rendered_height).div_ceil(cell_height);

    Some(GraphicPlacement {
        key: GraphicPlacementKey {
            image: image.key,
            placement_id: placement.placement_id,
            ordinal: placement.key.ordinal,
        },
        image,
        rect: Rect {
            x: pane.x.saturating_add(u16::try_from(cursor_col).ok()?),
            y: pane.y.saturating_add(u16::try_from(cursor_row).ok()?),
            width: u16::try_from(grid_cols).ok()?,
            height: u16::try_from(grid_rows).ok()?,
        },
        pointer_frame_seq: None,
        columns,
        rows,
        source: Some(source),
        x_offset,
        y_offset,
        z: placement.z,
    })
}

fn proportional_boundary(source_pixels: u32, output_pixels: u32, rendered_pixels: u32) -> u32 {
    if rendered_pixels == 0 {
        return 0;
    }
    u32::try_from(
        u128::from(source_pixels) * u128::from(output_pixels) / u128::from(rendered_pixels),
    )
    .unwrap_or(source_pixels)
    .min(source_pixels)
}

fn rounded_ratio(value: u32, numerator: u32, denominator: u32) -> Option<u32> {
    if denominator == 0 {
        return None;
    }
    u32::try_from(
        (u128::from(value) * u128::from(numerator) + u128::from(denominator) / 2)
            / u128::from(denominator),
    )
    .ok()
}

fn rendered_pixel_size(
    source: GraphicSourceRect,
    columns: Option<u32>,
    rows: Option<u32>,
    cell_width: u32,
    cell_height: u32,
) -> Option<(u32, u32)> {
    match (columns, rows) {
        (None, None) => Some((source.width, source.height)),
        (Some(columns), None) => {
            let width = columns.checked_mul(cell_width)?;
            Some((width, rounded_ratio(width, source.height, source.width)?))
        }
        (None, Some(rows)) => {
            let height = rows.checked_mul(cell_height)?;
            Some((rounded_ratio(height, source.width, source.height)?, height))
        }
        (Some(columns), Some(rows)) => {
            Some((columns.checked_mul(cell_width)?, rows.checked_mul(cell_height)?))
        }
    }
}

fn fit_inferred_source_dimension(
    explicit_pixels: u32,
    fixed_source: u32,
    inferred_source: u32,
    maximum_pixels: u32,
) -> u32 {
    let mut low = 0;
    let mut high = inferred_source;
    while low < high {
        let candidate = low + (high - low).div_ceil(2);
        if rounded_ratio(explicit_pixels, candidate, fixed_source)
            .is_some_and(|pixels| pixels <= maximum_pixels)
        {
            low = candidate;
        } else {
            high = candidate - 1;
        }
    }
    low
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct PlacementFingerprint {
    rect: Rect,
    columns: Option<u32>,
    rows: Option<u32>,
    source: Option<GraphicSourceRect>,
    x_offset: u32,
    y_offset: u32,
    z: i32,
}

impl From<&GraphicPlacement> for PlacementFingerprint {
    fn from(placement: &GraphicPlacement) -> Self {
        Self {
            rect: placement.rect,
            columns: placement.columns,
            rows: placement.rows,
            source: placement.source,
            x_offset: placement.x_offset,
            y_offset: placement.y_offset,
            z: placement.z,
        }
    }
}

#[cfg(test)]
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
struct GraphicsOperationCounts {
    image_id_allocation_checks: usize,
    placement_id_allocation_checks: usize,
    stale_image_retain_passes: usize,
    stale_image_retain_visits: usize,
}

#[derive(Clone)]
pub struct GraphicsState {
    next_placement_id: u32,
    used_image_ids: HashSet<u32>,
    used_placement_ids: HashSet<u32>,
    image_ids: HashMap<GraphicImageKey, u32>,
    placement_ids: HashMap<GraphicPlacementKey, u32>,
    placement_fingerprints: HashMap<GraphicPlacementKey, PlacementFingerprint>,
    transmitted: HashMap<GraphicImageKey, u64>,
    visible: HashSet<GraphicPlacementKey>,
    #[cfg(test)]
    operation_counts: GraphicsOperationCounts,
}

pub(crate) struct GraphicsFrameBatches<'state, 'placement> {
    state: &'state mut GraphicsState,
    placements: std::vec::IntoIter<&'placement GraphicPlacement>,
    prefix_batches: std::vec::IntoIter<Vec<u8>>,
    now_visible: Option<HashSet<GraphicPlacementKey>>,
    retransmitted_images: HashSet<GraphicImageKey>,
}

impl Iterator for GraphicsFrameBatches<'_, '_> {
    type Item = Vec<u8>;

    fn next(&mut self) -> Option<Self::Item> {
        if let Some(batch) = self.prefix_batches.next() {
            return Some(batch);
        }
        loop {
            let Some(placement) = self.placements.next() else {
                if let Some(now_visible) = self.now_visible.take() {
                    self.state.visible = now_visible;
                }
                return None;
            };
            let fingerprint = PlacementFingerprint::from(placement);
            let previous = self.state.placement_fingerprints.get(&placement.key).copied();
            let image_id = self.state.image_id(placement.image.key);
            let placement_id = self.state.placement_id(placement.key);
            let mut batch = Vec::new();
            match self.state.transmitted.get(&placement.image.key).copied() {
                Some(generation) if generation == placement.image.generation => {}
                Some(_) => {
                    batch.extend(delete_image(image_id));
                    batch.extend(transmit_image(image_id, &placement.image));
                    self.state.transmitted.insert(placement.image.key, placement.image.generation);
                    self.retransmitted_images.insert(placement.image.key);
                }
                None => {
                    batch.extend(transmit_image(image_id, &placement.image));
                    self.state.transmitted.insert(placement.image.key, placement.image.generation);
                    self.retransmitted_images.insert(placement.image.key);
                }
            }
            let image_was_retransmitted = self.retransmitted_images.contains(&placement.image.key);
            let geometry_changed = previous.is_some_and(|previous| previous != fingerprint);
            if geometry_changed && !image_was_retransmitted {
                batch.extend(delete_placement(image_id, placement_id));
            }
            if previous.is_none() || geometry_changed || image_was_retransmitted {
                batch.extend(place_image(image_id, placement_id, placement));
                self.state.placement_fingerprints.insert(placement.key, fingerprint);
            }
            if !batch.is_empty() {
                return Some(batch);
            }
        }
    }
}

impl Default for GraphicsState {
    fn default() -> Self {
        Self {
            next_placement_id: 1,
            used_image_ids: HashSet::new(),
            used_placement_ids: HashSet::new(),
            image_ids: HashMap::new(),
            placement_ids: HashMap::new(),
            placement_fingerprints: HashMap::new(),
            transmitted: HashMap::new(),
            visible: HashSet::new(),
            #[cfg(test)]
            operation_counts: GraphicsOperationCounts::default(),
        }
    }
}

impl GraphicsState {
    /// Forget all host-side Kitty state after the outer terminal clears it.
    ///
    /// The next frame must retransmit both pixels and placements even when
    /// its logical scene is identical to the previous frame.
    pub fn invalidate_host_scene(&mut self) {
        *self = Self::default();
    }

    pub fn frame_batches(&mut self, placements: &[GraphicPlacement]) -> Vec<Vec<u8>> {
        self.frame_batch_stream(placements).collect()
    }

    /// Plan metadata eagerly, then encode at most one bounded image batch
    /// before yielding so the writer can observe cancellation or supersession.
    pub(crate) fn frame_batch_stream<'state, 'placement>(
        &'state mut self,
        placements: &'placement [GraphicPlacement],
    ) -> GraphicsFrameBatches<'state, 'placement> {
        let mut placements = placements
            .iter()
            .filter(|placement| placement.rect.width > 0 && placement.rect.height > 0)
            .collect::<Vec<_>>();
        // Ghostty resolves equal-z Kitty placements by image ID. Allocate the
        // outer IDs in that order so forwarding does not change compositing.
        placements.sort_by_key(|placement| {
            (
                placement.z,
                placement.key.image.image_id,
                placement.key,
                placement.rect.y,
                placement.rect.x,
            )
        });
        let now_visible = placements.iter().map(|placement| placement.key).collect::<HashSet<_>>();
        let now_images =
            placements.iter().map(|placement| placement.image.key).collect::<HashSet<_>>();
        let mut batches = Vec::new();

        let mut stale_placements =
            self.visible.difference(&now_visible).copied().collect::<Vec<_>>();
        stale_placements.sort_unstable();
        for key in stale_placements {
            if let (Some(&image_id), Some(&placement_id)) =
                (self.image_ids.get(&key.image), self.placement_ids.get(&key))
            {
                batches.push(delete_placement(image_id, placement_id));
            }
            if let Some(placement_id) = self.placement_ids.remove(&key) {
                let removed = self.used_placement_ids.remove(&placement_id);
                debug_assert!(removed, "placement ID set must track every placement mapping");
            }
            self.placement_fingerprints.remove(&key);
        }

        let mut stale_images = self
            .transmitted
            .keys()
            .filter(|key| !now_images.contains(key))
            .copied()
            .collect::<Vec<_>>();
        stale_images.sort_unstable();
        let had_stale_images = !stale_images.is_empty();
        for key in stale_images {
            if let Some(image_id) = self.image_ids.remove(&key) {
                let removed = self.used_image_ids.remove(&image_id);
                debug_assert!(removed, "image ID set must track every image mapping");
                batches.push(delete_image(image_id));
            }
            self.transmitted.remove(&key);
        }
        if had_stale_images {
            #[cfg(test)]
            {
                self.operation_counts.stale_image_retain_passes += 1;
                self.operation_counts.stale_image_retain_visits += self.placement_ids.len();
            }
            let used_placement_ids = &mut self.used_placement_ids;
            let placement_fingerprints = &mut self.placement_fingerprints;
            self.placement_ids.retain(|placement, placement_id| {
                let keep = now_images.contains(&placement.image);
                if !keep {
                    let removed = used_placement_ids.remove(placement_id);
                    debug_assert!(removed, "placement ID set must track every placement mapping");
                    placement_fingerprints.remove(placement);
                }
                keep
            });
        }

        let mut ordered_images = now_images.iter().copied().collect::<Vec<_>>();
        ordered_images.sort_unstable_by_key(|key| (key.image_id, *key));
        self.prepare_image_ids(&ordered_images, &mut batches);

        GraphicsFrameBatches {
            state: self,
            placements: placements.into_iter(),
            prefix_batches: batches.into_iter(),
            now_visible: Some(now_visible),
            retransmitted_images: HashSet::new(),
        }
    }

    fn prepare_image_ids(
        &mut self,
        ordered_images: &[GraphicImageKey],
        batches: &mut Vec<Vec<u8>>,
    ) {
        if self.image_ids.is_empty() && !ordered_images.is_empty() {
            let denominator = ordered_images.len() as u64 + 1;
            for (index, key) in ordered_images.iter().enumerate() {
                let image_id = (u64::from(u32::MAX) * (index as u64 + 1) / denominator) as u32;
                let inserted = self.used_image_ids.insert(image_id);
                debug_assert!(inserted, "even image-ID allocation must be unique");
                self.image_ids.insert(*key, image_id);
                #[cfg(test)]
                {
                    self.operation_counts.image_id_allocation_checks += 1;
                }
            }
            return;
        }

        for (index, key) in ordered_images.iter().copied().enumerate() {
            if self.image_ids.contains_key(&key) {
                continue;
            }
            if let Some(image_id) = self.image_id_between_neighbors(ordered_images, index) {
                let inserted = self.used_image_ids.insert(image_id);
                debug_assert!(inserted, "ordered image-ID allocation must be unique");
                self.image_ids.insert(key, image_id);
            } else {
                self.relabel_image_window(ordered_images, index, batches);
            }
            #[cfg(test)]
            {
                self.operation_counts.image_id_allocation_checks += 1;
            }
        }
    }

    fn image_id_between_neighbors(
        &self,
        ordered_images: &[GraphicImageKey],
        index: usize,
    ) -> Option<u32> {
        let previous =
            ordered_images[..index].iter().rev().find_map(|key| self.image_ids.get(key).copied());
        let next =
            ordered_images[index + 1..].iter().find_map(|key| self.image_ids.get(key).copied());
        match (previous, next) {
            (None, None) => Some(u32::MAX / 2),
            (None, Some(next)) => next.checked_sub(1).filter(|id| *id != 0),
            (Some(previous), None) => previous.checked_add(1),
            (Some(previous), Some(next))
                if previous.checked_add(1).is_some_and(|adjacent| adjacent < next) =>
            {
                Some(previous + (next - previous) / 2)
            }
            _ => None,
        }
    }

    fn relabel_image_window(
        &mut self,
        ordered_images: &[GraphicImageKey],
        insertion_index: usize,
        batches: &mut Vec<Vec<u8>>,
    ) {
        let inserted_key = ordered_images[insertion_index];
        let assigned = ordered_images
            .iter()
            .copied()
            .filter(|key| *key == inserted_key || self.image_ids.contains_key(key))
            .collect::<Vec<_>>();
        let insertion_index = assigned
            .iter()
            .position(|key| *key == inserted_key)
            .expect("inserted image is in relabel set");
        let mut radius = 8_usize;
        let (window_start, window_end, lower, upper) = loop {
            let start = insertion_index.saturating_sub(radius);
            let end = (insertion_index + radius + 1).min(assigned.len());
            let lower = if start == 0 { 0 } else { self.image_ids[&assigned[start - 1]] };
            let upper =
                if end == assigned.len() { u32::MAX } else { self.image_ids[&assigned[end]] };
            let count = end - start;
            let available = u64::from(upper) - u64::from(lower) - 1;
            if available >= (count as u64 + 1) * 4 || start == 0 && end == assigned.len() {
                break (start, end, lower, upper);
            }
            radius = radius.saturating_mul(2);
        };

        let window = &assigned[window_start..window_end];
        let available = u64::from(upper) - u64::from(lower) - 1;
        let step = available / (window.len() as u64 + 1);
        debug_assert!(step > 0, "u32 image-ID space must fit the bounded active image set");
        let mut remapped = Vec::new();
        for key in window {
            if let Some(old_id) = self.image_ids.remove(key) {
                let removed = self.used_image_ids.remove(&old_id);
                debug_assert!(removed, "image ID set must track every mapping");
                remapped.push((*key, old_id, self.transmitted.remove(key).is_some()));
            }
        }
        let remapped_keys = remapped.iter().map(|(key, _, _)| *key).collect::<HashSet<_>>();
        self.placement_fingerprints
            .retain(|placement, _| !remapped_keys.contains(&placement.image));
        let mut deleted = remapped
            .iter()
            .filter_map(|(_, old_id, transmitted)| transmitted.then_some(*old_id))
            .collect::<Vec<_>>();
        deleted.sort_unstable();
        for old_id in deleted {
            batches.push(delete_image(old_id));
        }
        for (offset, key) in window.iter().enumerate() {
            let image_id = u32::try_from(u64::from(lower) + step * (offset as u64 + 1))
                .expect("bounded image-ID relabel must fit u32");
            let inserted = self.used_image_ids.insert(image_id);
            debug_assert!(inserted, "relabelled image IDs must be unique");
            self.image_ids.insert(*key, image_id);
        }
    }

    fn image_id(&self, key: GraphicImageKey) -> u32 {
        self.image_ids[&key]
    }

    fn placement_id(&mut self, key: GraphicPlacementKey) -> u32 {
        if let Some(id) = self.placement_ids.get(&key) {
            return *id;
        }
        let (id, _allocation_checks) =
            allocate_id(&mut self.next_placement_id, &mut self.used_placement_ids);
        #[cfg(test)]
        {
            self.operation_counts.placement_id_allocation_checks += _allocation_checks;
        }
        self.placement_ids.insert(key, id);
        id
    }
}

fn allocate_id(next: &mut u32, used: &mut HashSet<u32>) -> (u32, usize) {
    let mut checks = 0;
    loop {
        // Monotonic allocation preserves stable IDs while the maintained set
        // makes wraparound collision checks constant-time.
        let candidate = (*next).max(1);
        *next = candidate.wrapping_add(1).max(1);
        checks += 1;
        if used.insert(candidate) {
            return (candidate, checks);
        }
    }
}

fn transmit_image(image_id: u32, image: &GraphicImage) -> Vec<u8> {
    let data = image.data.base64();
    // Frame data from the daemon is written inside an APC string. Anything
    // outside the base64 alphabet could end that string and inject terminal
    // commands, so such an image is dropped.
    if !data.bytes().all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'+' | b'/' | b'='))
    {
        return Vec::new();
    }
    record_image_transmission(image.key);
    let mut out = Vec::new();
    for (index, chunk) in data.as_bytes().chunks(CHUNK).enumerate() {
        let more = usize::from((index + 1) * CHUNK < data.len());
        let header = if index == 0 {
            match image.format {
                GraphicFormat::Png => format!(
                    "{ESC}_Ga=t,t=d,f={},i={image_id},q=2,m={more};",
                    image.format.kitty_value()
                ),
                GraphicFormat::Rgb | GraphicFormat::Rgba => format!(
                    "{ESC}_Ga=t,t=d,f={},i={image_id},s={},v={},q=2,m={more};",
                    image.format.kitty_value(),
                    image.width,
                    image.height
                ),
            }
        } else {
            format!("{ESC}_Gq=2,m={more};")
        };
        out.extend_from_slice(header.as_bytes());
        out.extend_from_slice(chunk);
        out.extend_from_slice(b"\x1b\\");
    }
    out
}

fn place_image(image_id: u32, placement_id: u32, placement: &GraphicPlacement) -> Vec<u8> {
    let mut command = format!(
        "{ESC}7{ESC}[{};{}H{ESC}_Ga=p,i={image_id},p={placement_id}",
        placement.rect.y.saturating_add(1),
        placement.rect.x.saturating_add(1)
    );
    if let Some(source) = placement.source {
        command.push_str(&format!(
            ",x={},y={},w={},h={}",
            source.x, source.y, source.width, source.height
        ));
    }
    command.push_str(&format!(",X={},Y={}", placement.x_offset, placement.y_offset));
    if let Some(columns) = placement.columns {
        command.push_str(&format!(",c={columns}"));
    }
    if let Some(rows) = placement.rows {
        command.push_str(&format!(",r={rows}"));
    }
    command.push_str(&format!(",z={},C=1,q=2;{ESC}\\{ESC}8", placement.z));
    command.into_bytes()
}

fn delete_placement(image_id: u32, placement_id: u32) -> Vec<u8> {
    format!("{ESC}_Ga=d,d=i,i={image_id},p={placement_id},q=2;{ESC}\\").into_bytes()
}

fn delete_image(image_id: u32) -> Vec<u8> {
    format!("{ESC}_Ga=d,d=I,i={image_id},q=2;{ESC}\\").into_bytes()
}

pub(crate) fn processing_fence_id(submission: u64) -> u32 {
    PROCESSING_FENCE_ID_BASE + (submission.wrapping_sub(1) % PROCESSING_FENCE_ID_COUNT) as u32
}

/// Append a side-effect-free graphics query after one submitted frame. Its
/// immediate reply confirms that the terminal parsed every preceding Kitty
/// graphics command. It does not report compositor presentation.
pub(crate) fn processing_fence(id: u32) -> Vec<u8> {
    format!("{ESC}_Gi={id},s=1,v=1,a=q,t=d,f=24;AAAA{ESC}\\").into_bytes()
}

const FALLBACK_CELL_PIXELS: (u16, u16) = (8, 16);
const TERMINAL_PROBE_TIMEOUT: Duration = Duration::from_millis(180);
const STARTUP_INPUT_MAX_INCOMPLETE_BYTES: usize = 4 * 1024;
#[cfg(unix)]
const STARTUP_INPUT_CONTINUATION_TIMEOUT: Duration = Duration::from_millis(100);

#[derive(Debug, Default)]
pub struct StartupTerminalInput {
    events: Vec<crossterm::event::Event>,
    incomplete: Vec<u8>,
}

impl StartupTerminalInput {
    fn append(&mut self, bytes: &[u8]) {
        let mut remaining = bytes;
        while !remaining.is_empty() {
            let available =
                STARTUP_INPUT_MAX_INCOMPLETE_BYTES.saturating_sub(self.incomplete.len());
            let take = available.min(remaining.len());
            self.incomplete.extend_from_slice(&remaining[..take]);
            remaining = &remaining[take..];

            let parsed = split_pending_input(&self.incomplete);
            self.events.extend(parsed.events);
            self.incomplete = parsed.incomplete;
            if remaining.is_empty() {
                break;
            }
            if self.incomplete.len() >= STARTUP_INPUT_MAX_INCOMPLETE_BYTES {
                self.events.extend(parse_incomplete_input_lossy(&self.incomplete));
                self.incomplete.clear();
            }
        }
    }
}

#[derive(Debug)]
pub struct StartupTerminalProbe {
    pub cell_pixels: (u16, u16),
    pub graphics_supported: bool,
    pub pending_input: StartupTerminalInput,
}

#[derive(Debug, Default, PartialEq, Eq)]
struct ParsedTerminalProbe {
    window_pixels: Option<(u32, u32)>,
    kitty_supported: Option<bool>,
    primary_device_attributes: bool,
    pending_input: Vec<u8>,
}

#[cfg(unix)]
fn write_terminal_probe_queries(stdout: &mut impl Write, query_window_pixels: bool) {
    if query_window_pixels {
        let _ = write!(stdout, "\x1b[14t");
    }
    let _ = write!(stdout, "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\\x1b[c");
    let _ = stdout.flush();
}

#[cfg(not(unix))]
fn write_terminal_probe_queries(_stdout: &mut impl Write, _query_window_pixels: bool) {}

/// Probe terminal capabilities in one exchange and return any user input read
/// alongside the replies. The final DA1 request acts as an ordering marker:
/// any preceding Kitty reply advertises support, while its absence does not
/// make terminals that ignore the Kitty APC wait for the full timeout.
pub fn probe_terminal(known_cell_pixels: Option<(u16, u16)>) -> StartupTerminalProbe {
    let ioctl_pixels = ioctl_cell_pixels();
    // Only ask when the reply can be read back. `read_stdin_until` is a
    // non-unix no-op, so on Windows these queries would be answered by the
    // host terminal and left in stdin, and the normal input loop would then
    // deliver `CSI 4;h;w t` and the DA1 reply to the focused pane as typed
    // input. Nothing is lost by staying quiet: `ioctl_cell_pixels` is already
    // `None` here so the pixel query could not resolve anything, and graphics
    // stay off because `GraphicsWriter::platform_supported()` is `cfg!(unix)`.
    // `host_colors::probe_default_colors` gates its own probe the same way.
    if !cfg!(unix) {
        return StartupTerminalProbe {
            cell_pixels: resolve_cell_pixels(known_cell_pixels, ioctl_pixels),
            graphics_supported: false,
            pending_input: StartupTerminalInput::default(),
        };
    }
    let terminal_size = crossterm::terminal::size().ok();
    let query_window_pixels =
        ioctl_pixels.is_none() && terminal_size.is_some_and(|(cols, rows)| cols > 0 && rows > 0);

    let mut stdout = std::io::stdout();
    write_terminal_probe_queries(&mut stdout, query_window_pixels);

    let bytes = read_stdin_until(TERMINAL_PROBE_TIMEOUT, terminal_probe_complete);
    let parsed = parse_terminal_probe(&bytes);
    let queried_pixels =
        terminal_size.zip(parsed.window_pixels).and_then(|((cols, rows), (width, height))| {
            cell_pixels_from_window_size(cols, rows, width, height)
        });
    StartupTerminalProbe {
        cell_pixels: resolve_cell_pixels(known_cell_pixels, ioctl_pixels.or(queried_pixels)),
        graphics_supported: parsed.kitty_supported.unwrap_or(false),
        pending_input: split_pending_input(&parsed.pending_input),
    }
}

/// Resolve host cell metrics without treating an absent resize-time ioctl
/// value as a new measurement. Some outer terminals zero `ws_xpixel` and
/// `ws_ypixel` after `TIOCSWINSZ`; in that case the last real measurement is
/// more accurate than the synthetic startup fallback.
pub fn detect_cell_pixels(known: Option<(u16, u16)>) -> (u16, u16) {
    resolve_cell_pixels(known, ioctl_cell_pixels())
}

fn resolve_cell_pixels(known: Option<(u16, u16)>, detected: Option<(u16, u16)>) -> (u16, u16) {
    detected.or(known).unwrap_or(FALLBACK_CELL_PIXELS)
}

fn cell_pixels_from_terminal_size(
    cols: u16,
    rows: u16,
    width_px: u16,
    height_px: u16,
) -> Option<(u16, u16)> {
    if cols == 0 || rows == 0 || width_px == 0 || height_px == 0 {
        return None;
    }
    Some(((width_px / cols).max(1), (height_px / rows).max(1)))
}

fn cell_pixels_from_window_size(
    cols: u16,
    rows: u16,
    width_px: u32,
    height_px: u32,
) -> Option<(u16, u16)> {
    if cols == 0 || rows == 0 || width_px == 0 || height_px == 0 {
        return None;
    }
    let width = (width_px / u32::from(cols)).clamp(1, u32::from(u16::MAX));
    let height = (height_px / u32::from(rows)).clamp(1, u32::from(u16::MAX));
    Some((width as u16, height as u16))
}

#[cfg(unix)]
fn ioctl_cell_pixels() -> Option<(u16, u16)> {
    let mut ws: libc::winsize = unsafe { std::mem::zeroed() };
    let ok = unsafe { libc::ioctl(libc::STDOUT_FILENO, libc::TIOCGWINSZ, &mut ws) } == 0;
    ok.then(|| cell_pixels_from_terminal_size(ws.ws_col, ws.ws_row, ws.ws_xpixel, ws.ws_ypixel))
        .flatten()
}

#[cfg(not(unix))]
fn ioctl_cell_pixels() -> Option<(u16, u16)> {
    None
}

#[cfg(unix)]
fn read_stdin_until(timeout: Duration, complete: impl Fn(&[u8]) -> bool) -> Vec<u8> {
    let start = Instant::now();
    let mut out = Vec::new();
    while start.elapsed() < timeout {
        let available = STARTUP_INPUT_MAX_INCOMPLETE_BYTES.saturating_sub(out.len());
        if available == 0 {
            break;
        }
        let remaining = timeout.saturating_sub(start.elapsed());
        let poll_ms = remaining.min(Duration::from_millis(20)).as_millis() as i32;
        let mut fd = libc::pollfd { fd: libc::STDIN_FILENO, events: libc::POLLIN, revents: 0 };
        let ready = unsafe { libc::poll(&mut fd, 1, poll_ms) };
        if ready <= 0 {
            continue;
        }
        let mut buf = [0u8; 1024];
        let n = unsafe {
            libc::read(libc::STDIN_FILENO, buf.as_mut_ptr().cast(), buf.len().min(available))
        };
        if n <= 0 {
            break;
        }
        out.extend_from_slice(&buf[..n as usize]);
        if complete(&out) {
            // Drain bytes that are already queued with the replies so an
            // input sequence split at this read boundary remains intact.
            let mut pending =
                libc::pollfd { fd: libc::STDIN_FILENO, events: libc::POLLIN, revents: 0 };
            if unsafe { libc::poll(&mut pending, 1, 0) } <= 0 {
                break;
            }
        }
    }
    out
}

#[cfg(not(unix))]
fn read_stdin_until(_timeout: Duration, _complete: impl Fn(&[u8]) -> bool) -> Vec<u8> {
    Vec::new()
}

fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|window| window == needle)
}

fn terminal_probe_complete(bytes: &[u8]) -> bool {
    parse_terminal_probe(bytes).primary_device_attributes
}

fn parse_terminal_probe(bytes: &[u8]) -> ParsedTerminalProbe {
    let mut parsed = ParsedTerminalProbe::default();
    let mut offset = 0;
    while offset < bytes.len() {
        if bytes[offset..].starts_with(b"\x1b[")
            && let Some(relative_end) =
                bytes[offset + 2..].iter().position(|byte| (0x40..=0x7e).contains(byte))
        {
            let end = offset + 2 + relative_end + 1;
            let sequence = &bytes[offset..end];
            let parameters = &sequence[2..sequence.len() - 1];
            let final_byte = sequence[sequence.len() - 1];
            if final_byte == b'c' && parameters.starts_with(b"?") {
                parsed.primary_device_attributes = true;
                offset = end;
                continue;
            }
            if final_byte == b't'
                && let Some(pixels) = parse_window_pixel_response(parameters)
            {
                parsed.window_pixels = Some(pixels);
                offset = end;
                continue;
            }
        }
        if bytes[offset..].starts_with(b"\x1b_")
            && let Some(relative_end) = find_bytes(&bytes[offset + 2..], b"\x1b\\")
        {
            let end = offset + 2 + relative_end + 2;
            let sequence = &bytes[offset..end];
            if let Some(supported) = parse_kitty_probe_response(sequence) {
                parsed.kitty_supported = Some(supported);
                offset = end;
                continue;
            }
        }
        parsed.pending_input.push(bytes[offset]);
        offset += 1;
    }
    parsed
}

fn parse_window_pixel_response(parameters: &[u8]) -> Option<(u32, u32)> {
    let response = std::str::from_utf8(parameters).ok()?;
    let mut parts = response.split(';');
    if parts.next()? != "4" {
        return None;
    }
    let height = parts.next()?.parse().ok()?;
    let width = parts.next()?.parse().ok()?;
    (parts.next().is_none() && width > 0 && height > 0).then_some((width, height))
}

fn parse_kitty_probe_response(sequence: &[u8]) -> Option<bool> {
    let marker = b"Gi=31;";
    let status_start = find_bytes(sequence, marker)? + marker.len();
    let status_end = find_bytes(&sequence[status_start..], b"\x1b\\")? + status_start;
    Some(sequence[status_start..status_end].starts_with(b"OK"))
}

fn split_pending_input(bytes: &[u8]) -> StartupTerminalInput {
    let mut events = Vec::new();
    let mut offset = 0;
    while offset < bytes.len() {
        if let Some((event, consumed)) = parse_one_input_event(&bytes[offset..]) {
            events.push(event);
            offset += consumed;
            continue;
        }
        break;
    }
    StartupTerminalInput { events, incomplete: bytes[offset..].to_vec() }
}

fn parse_incomplete_input_lossy(bytes: &[u8]) -> Vec<crossterm::event::Event> {
    let mut events = Vec::new();
    let mut offset = 0;
    while offset < bytes.len() {
        if let Some((event, consumed)) = parse_one_input_event(&bytes[offset..]) {
            events.push(event);
            offset += consumed;
            continue;
        }
        let code = if bytes[offset] == b'\x1b' {
            crossterm::event::KeyCode::Esc
        } else {
            crossterm::event::KeyCode::Char(char::REPLACEMENT_CHARACTER)
        };
        events.push(crossterm::event::Event::Key(crossterm::event::KeyEvent::new(
            code,
            crossterm::event::KeyModifiers::NONE,
        )));
        offset += 1;
    }
    events
}

/// Finish an input sequence whose prefix was consumed while probing the host
/// terminal, then return to crossterm for normal live input. Waiting is
/// bounded so a literal Escape key cannot stall startup indefinitely.
pub(crate) fn finish_startup_input(
    mut pending: StartupTerminalInput,
) -> Vec<crossterm::event::Event> {
    #[cfg(unix)]
    {
        let deadline = Instant::now() + STARTUP_INPUT_CONTINUATION_TIMEOUT;
        while !pending.incomplete.is_empty() {
            let mut read_more = false;
            while Instant::now() < deadline {
                let remaining = deadline.saturating_duration_since(Instant::now());
                let poll_ms = remaining.min(Duration::from_millis(20)).as_millis().max(1) as i32;
                let mut fd =
                    libc::pollfd { fd: libc::STDIN_FILENO, events: libc::POLLIN, revents: 0 };
                let ready = unsafe { libc::poll(&mut fd, 1, poll_ms) };
                if ready < 0 {
                    if std::io::Error::last_os_error().raw_os_error() == Some(libc::EINTR) {
                        continue;
                    }
                    break;
                }
                if ready == 0 {
                    continue;
                }
                let mut bytes = [0_u8; 1024];
                let count = unsafe {
                    libc::read(libc::STDIN_FILENO, bytes.as_mut_ptr().cast(), bytes.len())
                };
                if count <= 0 {
                    break;
                }
                pending.append(&bytes[..count as usize]);
                read_more = true;
                break;
            }
            if !read_more {
                break;
            }
        }
    }

    if !pending.incomplete.is_empty() {
        pending.events.extend(parse_incomplete_input_lossy(&pending.incomplete));
    }
    pending.events
}

fn parse_one_input_event(bytes: &[u8]) -> Option<(crossterm::event::Event, usize)> {
    let minimum = usize::from(bytes.first() == Some(&b'\x1b') && bytes.len() > 1) + 1;
    for end in minimum..=bytes.len() {
        let Some(event) = parse_startup_input_event(&bytes[..end]) else { continue };
        return Some((event, end));
    }
    None
}

#[cfg(unix)]
fn parse_startup_input_event(bytes: &[u8]) -> Option<crossterm::event::Event> {
    crossterm::event::parse_event_from_bytes(bytes, true).ok().flatten()
}

#[cfg(not(unix))]
fn parse_startup_input_event(bytes: &[u8]) -> Option<crossterm::event::Event> {
    let event = terminput::Event::parse_from(bytes).ok().flatten()?;
    terminput_crossterm::to_crossterm(event).ok()
}
