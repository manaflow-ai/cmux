use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::sync::Arc;
use std::time::Duration;
#[cfg(unix)]
use std::time::Instant;

use base64::Engine as _;
use cmux_tui_core::{Rect, SurfaceId};
use ghostty_vt::{KittyImage, KittyImageFormat, KittyPlacement};

const ESC: &str = "\x1b";
const CHUNK: usize = 4096;

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
    Base64(Arc<str>),
    Bytes(Arc<[u8]>),
}

impl GraphicData {
    fn base64(&self) -> String {
        match self {
            Self::Base64(encoded) => encoded.to_string(),
            Self::Bytes(bytes) => base64::engine::general_purpose::STANDARD.encode(bytes),
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
    pub columns: Option<u32>,
    pub rows: Option<u32>,
    pub source: Option<GraphicSourceRect>,
    pub x_offset: u32,
    pub y_offset: u32,
    pub z: i32,
}

impl GraphicPlacement {
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
    let image_left =
        i64::from(placement.viewport_col) * cell_width_i64 + i64::from(placement.x_offset);
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

pub struct GraphicsState {
    next_image_id: u32,
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

impl Default for GraphicsState {
    fn default() -> Self {
        Self {
            next_image_id: 1,
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

        let mut retransmitted_images = HashSet::new();
        for placement in placements {
            let fingerprint = PlacementFingerprint::from(placement);
            let previous = self.placement_fingerprints.get(&placement.key).copied();
            let image_id = self.image_id(placement.image.key);
            let placement_id = self.placement_id(placement.key);
            let mut batch = Vec::new();
            match self.transmitted.get(&placement.image.key).copied() {
                Some(generation) if generation == placement.image.generation => {}
                Some(_) => {
                    batch.extend(delete_image(image_id));
                    batch.extend(transmit_image(image_id, &placement.image));
                    self.transmitted.insert(placement.image.key, placement.image.generation);
                    retransmitted_images.insert(placement.image.key);
                }
                None => {
                    batch.extend(transmit_image(image_id, &placement.image));
                    self.transmitted.insert(placement.image.key, placement.image.generation);
                    retransmitted_images.insert(placement.image.key);
                }
            }
            let image_was_retransmitted = retransmitted_images.contains(&placement.image.key);
            let geometry_changed = previous.is_some_and(|previous| previous != fingerprint);
            if geometry_changed && !image_was_retransmitted {
                batch.extend(delete_placement(image_id, placement_id));
            }
            if previous.is_none() || geometry_changed || image_was_retransmitted {
                batch.extend(place_image(image_id, placement_id, placement));
                self.placement_fingerprints.insert(placement.key, fingerprint);
            }
            if !batch.is_empty() {
                batches.push(batch);
            }
        }

        self.visible = now_visible;
        batches
    }

    fn prepare_image_ids(
        &mut self,
        ordered_images: &[GraphicImageKey],
        batches: &mut Vec<Vec<u8>>,
    ) {
        let mut previous_id = None;
        let mut saw_missing = false;
        let requires_remap = ordered_images.iter().any(|key| match self.image_ids.get(key) {
            Some(&id) => {
                let out_of_order =
                    saw_missing || previous_id.is_some_and(|previous| previous >= id);
                previous_id = Some(id);
                out_of_order
            }
            None => {
                saw_missing = true;
                false
            }
        });

        if requires_remap {
            let ordered_set = ordered_images.iter().copied().collect::<HashSet<_>>();
            let mut old_host_ids = Vec::new();
            for key in ordered_images {
                let was_transmitted = self.transmitted.remove(key).is_some();
                if let Some(image_id) = self.image_ids.remove(key) {
                    let removed = self.used_image_ids.remove(&image_id);
                    debug_assert!(removed, "image ID set must track every image mapping");
                    if was_transmitted {
                        old_host_ids.push(image_id);
                    }
                }
            }
            old_host_ids.sort_unstable();
            for image_id in old_host_ids {
                batches.push(delete_image(image_id));
            }
            self.placement_fingerprints
                .retain(|placement, _| !ordered_set.contains(&placement.image));
        }

        for key in ordered_images {
            self.image_id(*key);
        }
    }

    fn image_id(&mut self, key: GraphicImageKey) -> u32 {
        if let Some(id) = self.image_ids.get(&key) {
            return *id;
        }
        let (id, _allocation_checks) =
            allocate_id(&mut self.next_image_id, &mut self.used_image_ids);
        #[cfg(test)]
        {
            self.operation_counts.image_id_allocation_checks += _allocation_checks;
        }
        self.image_ids.insert(key, id);
        id
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

    #[cfg(test)]
    fn reset_operation_counts(&mut self) {
        self.operation_counts = GraphicsOperationCounts::default();
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

pub fn probe_kitty_graphics() -> bool {
    let mut stdout = std::io::stdout();
    let _ = write!(stdout, "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\\x1b[c");
    let _ = stdout.flush();
    let bytes = read_stdin_for(Duration::from_millis(180));
    kitty_probe_succeeded(&bytes)
}

const FALLBACK_CELL_PIXELS: (u16, u16) = (8, 16);

/// Resolve host cell metrics without treating an absent resize-time ioctl
/// value as a new measurement. Some outer terminals zero `ws_xpixel` and
/// `ws_ypixel` after `TIOCSWINSZ`; in that case the last real measurement is
/// more accurate than the synthetic startup fallback.
pub fn detect_cell_pixels(known: Option<(u16, u16)>, query_fallback: bool) -> (u16, u16) {
    let detected = ioctl_cell_pixels().or_else(|| query_fallback.then(query_cell_pixels).flatten());
    resolve_cell_pixels(known, detected)
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

fn query_cell_pixels() -> Option<(u16, u16)> {
    let (cols, rows) = crossterm::terminal::size().ok()?;
    if cols == 0 || rows == 0 {
        return None;
    }
    let mut stdout = std::io::stdout();
    let _ = write!(stdout, "\x1b[14t");
    let _ = stdout.flush();
    let bytes = read_stdin_for(Duration::from_millis(120));
    let response = String::from_utf8_lossy(&bytes);
    let start = response.find("\x1b[4;")?;
    let tail = &response[start + 4..];
    let end = tail.find('t')?;
    let mut parts = tail[..end].split(';');
    let height = parts.next()?.parse::<u32>().ok()?;
    let width = parts.next()?.parse::<u32>().ok()?;
    Some((((width / cols as u32).max(1)) as u16, ((height / rows as u32).max(1)) as u16))
}

#[cfg(unix)]
fn read_stdin_for(timeout: Duration) -> Vec<u8> {
    let start = Instant::now();
    let mut out = Vec::new();
    while start.elapsed() < timeout {
        let remaining = timeout.saturating_sub(start.elapsed());
        let poll_ms = remaining.min(Duration::from_millis(20)).as_millis() as i32;
        let mut fd = libc::pollfd { fd: libc::STDIN_FILENO, events: libc::POLLIN, revents: 0 };
        let ready = unsafe { libc::poll(&mut fd, 1, poll_ms) };
        if ready <= 0 {
            continue;
        }
        let mut buf = [0u8; 1024];
        let n = unsafe { libc::read(libc::STDIN_FILENO, buf.as_mut_ptr().cast(), buf.len()) };
        if n <= 0 {
            break;
        }
        out.extend_from_slice(&buf[..n as usize]);
        // DA1 is only a progress marker. Drain the full bounded window so a
        // later Kitty reply cannot leak into crossterm input.
    }
    out
}

#[cfg(not(unix))]
fn read_stdin_for(_timeout: Duration) -> Vec<u8> {
    Vec::new()
}

fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|window| window == needle)
}

fn kitty_probe_succeeded(bytes: &[u8]) -> bool {
    find_bytes(bytes, b"_Gi=31;OK").is_some()
}

#[cfg(test)]
mod tests {
    use base64::Engine as _;
    use ghostty_vt::{Callbacks, KittyPlacement, KittyPlacementKey, Terminal};

    use super::*;

    #[test]
    fn zero_pixel_resize_preserves_known_cell_metrics() {
        let detected = cell_pixels_from_terminal_size(120, 40, 0, 0);
        assert_eq!(detected, None);
        assert_eq!(resolve_cell_pixels(Some((11, 23)), detected), (11, 23));
    }

    #[test]
    fn missing_initial_metrics_use_synthetic_fallback() {
        assert_eq!(resolve_cell_pixels(None, None), FALLBACK_CELL_PIXELS);
    }

    #[test]
    fn newly_detected_metrics_replace_known_metrics() {
        assert_eq!(resolve_cell_pixels(Some((8, 16)), Some((11, 23))), (11, 23));
    }

    #[test]
    fn kitty_probe_accepts_ok_before_or_after_da1() {
        assert!(kitty_probe_succeeded(b"\x1b_Gi=31;OK\x1b\\\x1b[?62;c"));
        assert!(kitty_probe_succeeded(b"\x1b[?62;c\x1b_Gi=31;OK\x1b\\"));
    }

    #[test]
    fn kitty_probe_rejects_da1_or_error_without_ok() {
        assert!(!kitty_probe_succeeded(b"\x1b[?62;c"));
        assert!(!kitty_probe_succeeded(b"\x1b_Gi=31;EINVAL\x1b\\"));
    }

    fn image(
        surface: SurfaceId,
        image_id: u32,
        generation: u64,
        format: GraphicFormat,
        data: &[u8],
    ) -> Arc<GraphicImage> {
        Arc::new(GraphicImage {
            key: GraphicImageKey { namespace: 0, surface, image_id },
            generation,
            width: 2,
            height: 2,
            format,
            data: GraphicData::Bytes(Arc::from(data)),
        })
    }

    fn placement(
        image: Arc<GraphicImage>,
        placement_id: u32,
        ordinal: u32,
        rect: Rect,
    ) -> GraphicPlacement {
        GraphicPlacement {
            key: GraphicPlacementKey { image: image.key, placement_id, ordinal },
            image,
            rect,
            columns: Some(u32::from(rect.width)),
            rows: Some(u32::from(rect.height)),
            source: None,
            x_offset: 0,
            y_offset: 0,
            z: 0,
        }
    }

    fn joined(batches: &[Vec<u8>]) -> String {
        String::from_utf8(batches.concat()).unwrap()
    }

    fn decoded_terminal_placement(
        width: u32,
        height: u32,
        sizing: &str,
    ) -> (KittyImage, KittyPlacement) {
        let mut terminal = Terminal::new(20, 8, 100, Callbacks::default()).unwrap();
        terminal.resize(20, 8, 10, 20).unwrap();
        let pixels = vec![255; usize::try_from(width * height * 3).unwrap()];
        let payload = base64::engine::general_purpose::STANDARD.encode(pixels);
        terminal.vt_write(
            format!(
                "\x1b_Ga=T,t=d,f=24,i=201,p=1,s={width},v={height}{sizing},q=2;{payload}\x1b\\"
            )
            .as_bytes(),
        );

        let snapshot = terminal.kitty_graphics_snapshot().unwrap();
        assert_eq!(snapshot.placements.len(), 1);
        (snapshot.image(201).unwrap().clone(), snapshot.placements[0].clone())
    }

    fn translate_terminal_placement(
        image: &KittyImage,
        placement: &KittyPlacement,
        pane: Rect,
    ) -> GraphicPlacement {
        kitty_graphic_placement(pane, (10, 20), kitty_graphic_image(0, 9, image), placement)
            .unwrap()
    }

    fn translated_terminal_placement(
        width: u32,
        height: u32,
        sizing: &str,
        pane: Rect,
    ) -> GraphicPlacement {
        let (image, placement) = decoded_terminal_placement(width, height, sizing);
        translate_terminal_placement(&image, &placement, pane)
    }

    fn emitted_placement(value: GraphicPlacement) -> String {
        let mut state = GraphicsState::default();
        let output = joined(&state.frame_batches(&[value]));
        let start = output.find("\x1b_Ga=p").expect("placement command");
        let command = &output[start..];
        let end = command.find("\x1b\\").expect("placement terminator") + 2;
        command[..end].to_string()
    }

    fn rounded_ratio(value: u32, numerator: u32, denominator: u32) -> u32 {
        u32::try_from(
            (u128::from(value) * u128::from(numerator) + u128::from(denominator) / 2)
                / u128::from(denominator),
        )
        .unwrap()
    }

    fn rendered_pixel_size(value: &GraphicPlacement) -> (u32, u32) {
        let source = value.source.unwrap_or(GraphicSourceRect {
            x: 0,
            y: 0,
            width: value.image.width,
            height: value.image.height,
        });
        match (value.columns, value.rows) {
            (None, None) => (source.width, source.height),
            (Some(columns), None) => {
                let width = columns * 10;
                (width, rounded_ratio(width, source.height, source.width))
            }
            (None, Some(rows)) => {
                let height = rows * 20;
                (rounded_ratio(height, source.width, source.height), height)
            }
            (Some(columns), Some(rows)) => (columns * 10, rows * 20),
        }
    }

    fn assert_pixel_geometry(
        value: &GraphicPlacement,
        pane: Rect,
        source: GraphicSourceRect,
        sizing: (Option<u32>, Option<u32>),
        pixels: (u32, u32),
    ) {
        assert_eq!(value.source, Some(source));
        assert_eq!((value.columns, value.rows), sizing);
        assert_eq!(rendered_pixel_size(value), pixels);
        let left = u32::from(value.rect.x - pane.x) * 10 + value.x_offset;
        let top = u32::from(value.rect.y - pane.y) * 20 + value.y_offset;
        assert!(left + pixels.0 <= u32::from(pane.width) * 10);
        assert!(top + pixels.1 <= u32::from(pane.height) * 20);
    }

    #[test]
    fn raw_rgb_and_rgba_payloads_are_chunked_with_dimensions() {
        let rgb = image(1, 1, 1, GraphicFormat::Rgb, &vec![255; 3_075]);
        let rgba = image(2, 2, 1, GraphicFormat::Rgba, &[255; 16]);
        let mut state = GraphicsState::default();
        let output = joined(&state.frame_batches(&[
            placement(rgb, 0, 0, Rect { x: 0, y: 0, width: 2, height: 2 }),
            placement(rgba, 0, 0, Rect { x: 3, y: 0, width: 2, height: 2 }),
        ]));
        assert!(output.contains("a=t,t=d,f=24,i=1,s=2,v=2,q=2,m=1;"));
        assert!(output.contains("\x1b_Gq=2,m=0;"));
        assert!(output.contains("a=t,t=d,f=32,i=2,s=2,v=2,q=2,m=0;"));
    }

    #[test]
    fn dynamic_ids_do_not_alias_distant_surfaces_or_anonymous_placements() {
        let first = image(1, 7, 1, GraphicFormat::Rgb, &[255; 12]);
        let distant = image(2_000_000_001, 7, 1, GraphicFormat::Rgb, &[0; 12]);
        let mut state = GraphicsState::default();
        let output = joined(&state.frame_batches(&[
            placement(first.clone(), 0, 0, Rect { x: 0, y: 0, width: 1, height: 1 }),
            placement(first, 0, 1, Rect { x: 1, y: 0, width: 1, height: 1 }),
            placement(distant, 0, 0, Rect { x: 2, y: 0, width: 1, height: 1 }),
        ]));
        assert_eq!(state.image_ids.len(), 2);
        assert_eq!(state.placement_ids.len(), 3);
        assert_eq!(output.matches("a=t,t=d").count(), 2, "one transmit per image");
        assert_eq!(output.matches("a=p").count(), 3);
        assert_eq!(state.image_ids.values().copied().collect::<HashSet<_>>().len(), 2);
        assert_eq!(state.placement_ids.values().copied().collect::<HashSet<_>>().len(), 3);
    }

    #[test]
    fn large_scene_id_allocation_performs_linear_work() {
        const IMAGE_COUNT: u32 = 256;
        let placements = (1..=IMAGE_COUNT)
            .rev()
            .map(|image_id| {
                placement(
                    image(19, image_id, 1, GraphicFormat::Rgb, &[255; 12]),
                    image_id,
                    0,
                    Rect {
                        x: u16::try_from(image_id % 80).unwrap(),
                        y: u16::try_from(image_id / 80).unwrap(),
                        width: 1,
                        height: 1,
                    },
                )
            })
            .collect::<Vec<_>>();
        let mut state = GraphicsState::default();

        state.frame_batches(&placements);

        assert_eq!(
            state.operation_counts.image_id_allocation_checks, IMAGE_COUNT as usize,
            "image allocation must perform one used-ID check per image: {:?}",
            state.operation_counts
        );
        assert_eq!(
            state.operation_counts.placement_id_allocation_checks, IMAGE_COUNT as usize,
            "placement allocation must perform one used-ID check per placement: {:?}",
            state.operation_counts
        );
    }

    #[test]
    fn stale_image_cleanup_uses_one_linear_retain_pass() {
        const SURVIVOR_COUNT: u32 = 128;
        let initial = (1..=SURVIVOR_COUNT * 2)
            .map(|image_id| {
                placement(
                    image(20, image_id, 1, GraphicFormat::Rgb, &[255; 12]),
                    image_id,
                    0,
                    Rect {
                        x: u16::try_from(image_id % 80).unwrap(),
                        y: u16::try_from(image_id / 80).unwrap(),
                        width: 1,
                        height: 1,
                    },
                )
            })
            .collect::<Vec<_>>();
        let survivors = initial[..SURVIVOR_COUNT as usize].to_vec();
        let mut state = GraphicsState::default();
        state.frame_batches(&initial);
        state.reset_operation_counts();

        state.frame_batches(&survivors);

        assert_eq!(
            state.operation_counts.stale_image_retain_passes, 1,
            "stale-image cleanup repeated a retain pass: {:?}",
            state.operation_counts
        );
        assert_eq!(
            state.operation_counts.stale_image_retain_visits, SURVIVOR_COUNT as usize,
            "stale-image cleanup must visit each survivor once: {:?}",
            state.operation_counts
        );
    }

    #[test]
    fn late_lower_inner_image_id_remaps_outer_ids_before_equal_z_compositing() {
        let mut lower = placement(
            image(21, 7, 1, GraphicFormat::Rgb, &[7; 12]),
            1,
            0,
            Rect { x: 40, y: 20, width: 1, height: 1 },
        );
        let mut higher = placement(
            image(21, 90, 1, GraphicFormat::Rgb, &[90; 12]),
            1,
            0,
            Rect { x: 0, y: 0, width: 1, height: 1 },
        );
        lower.z = 8;
        higher.z = -8;
        let lower_key = lower.image.key;
        let higher_key = higher.image.key;
        let mut state = GraphicsState::default();

        state.frame_batches(std::slice::from_ref(&higher));
        let old_higher_id = state.image_ids[&higher_key];
        let remap = joined(&state.frame_batches(&[higher.clone(), lower.clone()]));

        assert!(
            state.image_ids[&lower_key] < state.image_ids[&higher_key],
            "outer IDs must preserve inner image-ID order even when allocation first saw another z: {:?}",
            state.image_ids
        );
        assert!(
            remap.contains(&format!("a=d,d=I,i={old_higher_id}")),
            "remapping must delete the old host image: {remap:?}"
        );
        assert_eq!(remap.matches("a=t,t=d").count(), 2, "{remap:?}");
        assert_eq!(remap.matches("a=p").count(), 2, "{remap:?}");
        assert!(
            !state.image_ids.values().any(|image_id| *image_id == old_higher_id),
            "remapping must release the old outer image ID: {:?}",
            state.image_ids
        );

        lower.z = 0;
        higher.z = 0;
        state.frame_batches(&[higher, lower]);
        assert!(
            state.image_ids[&lower_key] < state.image_ids[&higher_key],
            "equal-z outer IDs must ignore input order and y position: {:?}",
            state.image_ids
        );
    }

    #[test]
    fn reconnect_namespace_prevents_surface_and_generation_reuse_from_aliasing() {
        let rect = Rect { x: 0, y: 0, width: 2, height: 2 };
        let first = GraphicPlacement::browser(10, 7, rect, 1, 20, 20, "AAAA".to_string());
        let reconnected = GraphicPlacement::browser(11, 7, rect, 1, 20, 20, "BBBB".to_string());
        assert_ne!(first.image.key, reconnected.image.key);

        let mut state = GraphicsState::default();
        state.frame_batches(&[first]);
        let output = joined(&state.frame_batches(&[reconnected]));
        assert!(output.contains("a=d,d=I"));
        assert!(output.contains("a=t,t=d"));
        assert_eq!(state.image_ids.len(), 1);
    }

    #[test]
    fn placement_preserves_crop_offsets_and_z() {
        let image = image(4, 9, 1, GraphicFormat::Rgba, &[255; 16]);
        let mut value = placement(image, 12, 0, Rect { x: 4, y: 6, width: 2, height: 3 });
        value.source = Some(GraphicSourceRect { x: 1, y: 2, width: 3, height: 4 });
        value.x_offset = 5;
        value.y_offset = 6;
        value.z = -7;
        let mut state = GraphicsState::default();
        let output = joined(&state.frame_batches(&[value]));
        assert!(output.contains(
            "\x1b7\x1b[7;5H\x1b_Ga=p,i=1,p=1,x=1,y=2,w=3,h=4,X=5,Y=6,c=2,r=3,z=-7,C=1,q=2;\x1b\\\x1b8"
        ));
    }

    #[test]
    fn retransmit_deletes_old_generation_before_replacing_pixels() {
        let key_image = image(5, 1, 1, GraphicFormat::Rgb, &[255; 12]);
        let mut state = GraphicsState::default();
        state.frame_batches(&[placement(
            key_image,
            1,
            0,
            Rect { x: 0, y: 0, width: 1, height: 1 },
        )]);
        let replacement = image(5, 1, 2, GraphicFormat::Rgb, &[0; 12]);
        let output = joined(&state.frame_batches(&[placement(
            replacement,
            1,
            0,
            Rect { x: 0, y: 0, width: 1, height: 1 },
        )]));
        let delete = output.find("a=d,d=I").unwrap();
        let transmit = output.find("a=t,t=d").unwrap();
        assert!(delete < transmit);
    }

    #[test]
    fn unchanged_frame_does_not_replace_existing_placement() {
        let image = image(5, 2, 1, GraphicFormat::Rgb, &[255; 12]);
        let value = placement(image, 1, 0, Rect { x: 2, y: 3, width: 1, height: 1 });
        let mut state = GraphicsState::default();
        state.frame_batches(std::slice::from_ref(&value));

        let output = joined(&state.frame_batches(&[value]));
        assert!(!output.contains("a=p"), "{output:?}");
        assert!(output.is_empty(), "{output:?}");
    }

    #[test]
    fn host_scene_invalidation_restores_an_unchanged_image_after_clear() {
        let image = image(5, 20, 1, GraphicFormat::Rgb, &[255; 12]);
        let value = placement(image, 1, 0, Rect { x: 2, y: 3, width: 2, height: 2 });
        let mut state = GraphicsState::default();
        let mut host = Terminal::new(20, 8, 100, Callbacks::default()).unwrap();
        host.resize(20, 8, 10, 20).unwrap();

        for batch in state.frame_batches(std::slice::from_ref(&value)) {
            host.vt_write(&batch);
        }
        assert_eq!(host.kitty_graphics_snapshot().unwrap().placements.len(), 1);

        host.vt_write(b"\x1b[2J");
        assert!(host.kitty_graphics_snapshot().unwrap().is_empty());

        state.invalidate_host_scene();
        for batch in state.frame_batches(&[value]) {
            host.vt_write(&batch);
        }
        let restored = host.kitty_graphics_snapshot().unwrap();
        assert_eq!(restored.images.len(), 1);
        assert_eq!(restored.placements.len(), 1);
    }

    #[test]
    fn changed_geometry_deletes_old_placement_before_replacing_it() {
        let image = image(5, 3, 1, GraphicFormat::Rgb, &[255; 12]);
        let initial = placement(image.clone(), 1, 0, Rect { x: 2, y: 3, width: 1, height: 1 });
        let moved = placement(image, 1, 0, Rect { x: 4, y: 5, width: 2, height: 1 });
        let mut state = GraphicsState::default();
        state.frame_batches(&[initial]);

        let output = joined(&state.frame_batches(&[moved]));
        let delete = output.find("a=d,d=i").expect("old placement deletion");
        let replace = output.find("a=p").expect("replacement placement");
        assert!(delete < replace, "{output:?}");
    }

    #[test]
    fn image_retransmit_restores_every_placement_after_image_deletion() {
        let first = image(5, 4, 1, GraphicFormat::Rgb, &[255; 12]);
        let mut state = GraphicsState::default();
        state.frame_batches(&[
            placement(first.clone(), 1, 0, Rect { x: 0, y: 0, width: 1, height: 1 }),
            placement(first, 2, 0, Rect { x: 2, y: 0, width: 1, height: 1 }),
        ]);

        let replacement = image(5, 4, 2, GraphicFormat::Rgb, &[0; 12]);
        let output = joined(&state.frame_batches(&[
            placement(replacement.clone(), 1, 0, Rect { x: 0, y: 0, width: 1, height: 1 }),
            placement(replacement, 2, 0, Rect { x: 2, y: 0, width: 1, height: 1 }),
        ]));
        let delete = output.find("a=d,d=I").expect("old image deletion");
        let transmit = output.find("a=t,t=d").expect("replacement transmission");
        let first_place = output.find("a=p").expect("first restored placement");
        assert!(delete < transmit && transmit < first_place, "{output:?}");
        assert_eq!(output.matches("a=p").count(), 2, "{output:?}");
    }

    #[test]
    fn stale_placement_is_deleted_without_dropping_shared_image_then_image_is_freed() {
        let shared = image(6, 1, 1, GraphicFormat::Rgb, &[255; 12]);
        let one = placement(shared.clone(), 0, 0, Rect { x: 0, y: 0, width: 1, height: 1 });
        let two = placement(shared, 0, 1, Rect { x: 1, y: 0, width: 1, height: 1 });
        let mut state = GraphicsState::default();
        state.frame_batches(&[one.clone(), two]);

        let placement_cleanup = joined(&state.frame_batches(&[one]));
        assert!(placement_cleanup.contains("a=d,d=i"));
        assert!(!placement_cleanup.contains("d=I"));
        assert_eq!(state.transmitted.len(), 1);

        let image_cleanup = joined(&state.frame_batches(&[]));
        assert!(image_cleanup.contains("a=d,d=I"));
        assert!(state.transmitted.is_empty());
        assert!(state.image_ids.is_empty());
        assert!(state.placement_ids.is_empty());
    }

    #[test]
    fn terminal_placement_clips_to_pane_and_adjusts_source_pixels() {
        let inner_image = KittyImage {
            id: 3,
            number: 0,
            generation: 1,
            width: 100,
            height: 80,
            format: KittyImageFormat::Rgba,
            data: Arc::from(vec![0; 100 * 80 * 4]),
        };
        let inner = KittyPlacement {
            key: KittyPlacementKey { image_id: 3, placement_id: 0, ordinal: 1 },
            image_id: 3,
            placement_id: 0,
            is_internal: true,
            x_offset: 4,
            y_offset: 5,
            source_x: 10,
            source_y: 20,
            source_width: 80,
            source_height: 40,
            columns: 0,
            rows: 0,
            grid_cols: 9,
            grid_rows: 3,
            pixel_width: 80,
            pixel_height: 40,
            viewport_col: -2,
            viewport_row: -1,
            viewport_visible: true,
            z: 3,
        };
        let outer = kitty_graphic_placement(
            Rect { x: 10, y: 5, width: 5, height: 2 },
            (10, 20),
            kitty_graphic_image(0, 9, &inner_image),
            &inner,
        )
        .unwrap();
        assert_eq!(outer.rect, Rect { x: 10, y: 5, width: 5, height: 2 });
        assert_eq!(outer.source, Some(GraphicSourceRect { x: 26, y: 35, width: 50, height: 25 }));
        assert_eq!((outer.columns, outer.rows), (None, None));
        assert_eq!((outer.x_offset, outer.y_offset), (0, 0));
        assert_eq!(outer.z, 3);
    }

    #[test]
    fn terminal_offsets_at_right_and_bottom_edges_are_contained_inside_pane() {
        let inner_image = KittyImage {
            id: 4,
            number: 0,
            generation: 1,
            width: 100,
            height: 100,
            format: KittyImageFormat::Rgba,
            data: Arc::from(vec![0; 100 * 100 * 4]),
        };
        let inner = KittyPlacement {
            key: KittyPlacementKey { image_id: 4, placement_id: 2, ordinal: 0 },
            image_id: 4,
            placement_id: 2,
            is_internal: false,
            x_offset: 4,
            y_offset: 5,
            source_x: 0,
            source_y: 0,
            source_width: 100,
            source_height: 100,
            columns: 2,
            rows: 2,
            grid_cols: 2,
            grid_rows: 2,
            pixel_width: 20,
            pixel_height: 40,
            viewport_col: 3,
            viewport_row: 2,
            viewport_visible: true,
            z: 0,
        };
        let pane = Rect { x: 10, y: 5, width: 5, height: 4 };
        let outer = kitty_graphic_placement(
            pane,
            (10, 20),
            kitty_graphic_image(0, 9, &inner_image),
            &inner,
        )
        .unwrap();
        assert_eq!(outer.rect, Rect { x: 13, y: 7, width: 2, height: 2 });
        assert_eq!(outer.source, Some(GraphicSourceRect { x: 0, y: 0, width: 50, height: 50 }));
        assert_eq!((outer.x_offset, outer.y_offset), (4, 5));
        let pixels = rendered_pixel_size(&outer);
        assert!(
            u32::from(outer.rect.x - pane.x) * 10 + outer.x_offset + pixels.0
                <= u32::from(pane.width) * 10
        );
        assert!(
            u32::from(outer.rect.y - pane.y) * 20 + outer.y_offset + pixels.1
                <= u32::from(pane.height) * 20
        );
    }

    #[test]
    fn terminal_native_size_omits_outer_columns_and_rows() {
        let command = emitted_placement(translated_terminal_placement(
            3,
            2,
            "",
            Rect { x: 0, y: 0, width: 20, height: 8 },
        ));
        assert!(!command.contains(",c="), "{command:?}");
        assert!(!command.contains(",r="), "{command:?}");
    }

    #[test]
    fn terminal_column_only_size_omits_outer_rows() {
        let command = emitted_placement(translated_terminal_placement(
            20,
            10,
            ",c=2",
            Rect { x: 0, y: 0, width: 20, height: 8 },
        ));
        assert!(command.contains(",c=2"), "{command:?}");
        assert!(!command.contains(",r="), "{command:?}");
    }

    #[test]
    fn terminal_row_only_size_omits_outer_columns() {
        let command = emitted_placement(translated_terminal_placement(
            10,
            40,
            ",r=2",
            Rect { x: 0, y: 0, width: 20, height: 8 },
        ));
        assert!(!command.contains(",c="), "{command:?}");
        assert!(command.contains(",r=2"), "{command:?}");
    }

    #[test]
    fn terminal_explicit_cell_size_emits_both_outer_axes() {
        let command = emitted_placement(translated_terminal_placement(
            20,
            40,
            ",c=2,r=2",
            Rect { x: 0, y: 0, width: 20, height: 8 },
        ));
        assert!(command.contains(",c=2,r=2"), "{command:?}");
    }

    #[test]
    fn terminal_clipping_resolves_both_axes_and_crops_source_inside_pane() {
        let outer = translated_terminal_placement(
            20,
            40,
            ",X=4,Y=5,c=2,r=2",
            Rect { x: 0, y: 0, width: 2, height: 2 },
        );
        assert_eq!(outer.rect, Rect { x: 0, y: 0, width: 2, height: 2 });
        assert_eq!(outer.source, Some(GraphicSourceRect { x: 0, y: 0, width: 10, height: 20 }));
        assert_eq!((outer.x_offset, outer.y_offset), (4, 5));

        let command = emitted_placement(outer);
        assert!(command.contains("x=0,y=0,w=10,h=20,X=4,Y=5,c=1,r=1"), "{command:?}");
    }

    #[test]
    fn native_clipping_uses_rendered_pixels_on_every_edge() {
        let horizontal_pane = Rect { x: 10, y: 5, width: 1, height: 1 };
        let (horizontal_image, horizontal) = decoded_terminal_placement(15, 10, ",X=4");

        let right = translate_terminal_placement(&horizontal_image, &horizontal, horizontal_pane);
        assert_eq!((right.x_offset, right.y_offset), (4, 0));
        assert_pixel_geometry(
            &right,
            horizontal_pane,
            GraphicSourceRect { x: 0, y: 0, width: 6, height: 10 },
            (None, None),
            (6, 10),
        );

        let mut left_placement = horizontal;
        left_placement.viewport_col = -1;
        let left =
            translate_terminal_placement(&horizontal_image, &left_placement, horizontal_pane);
        assert_eq!((left.x_offset, left.y_offset), (0, 0));
        assert_pixel_geometry(
            &left,
            horizontal_pane,
            GraphicSourceRect { x: 6, y: 0, width: 9, height: 10 },
            (None, None),
            (9, 10),
        );

        let vertical_pane = Rect { x: 10, y: 5, width: 2, height: 1 };
        let (vertical_image, vertical) = decoded_terminal_placement(15, 10, ",Y=15");
        let bottom = translate_terminal_placement(&vertical_image, &vertical, vertical_pane);
        assert_eq!((bottom.x_offset, bottom.y_offset), (0, 15));
        assert_pixel_geometry(
            &bottom,
            vertical_pane,
            GraphicSourceRect { x: 0, y: 0, width: 15, height: 5 },
            (None, None),
            (15, 5),
        );

        let mut top_placement = vertical;
        top_placement.viewport_row = -1;
        let top = translate_terminal_placement(&vertical_image, &top_placement, vertical_pane);
        assert_eq!((top.x_offset, top.y_offset), (0, 0));
        assert_pixel_geometry(
            &top,
            vertical_pane,
            GraphicSourceRect { x: 0, y: 5, width: 15, height: 5 },
            (None, None),
            (15, 5),
        );
    }

    #[test]
    fn column_only_clipping_preserves_inferred_rows_on_every_edge() {
        let horizontal_pane = Rect { x: 10, y: 5, width: 2, height: 1 };
        let (horizontal_image, horizontal) = decoded_terminal_placement(20, 10, ",X=4,c=2");

        let right = translate_terminal_placement(&horizontal_image, &horizontal, horizontal_pane);
        assert_eq!((right.x_offset, right.y_offset), (4, 0));
        assert_pixel_geometry(
            &right,
            horizontal_pane,
            GraphicSourceRect { x: 0, y: 0, width: 10, height: 10 },
            (Some(1), None),
            (10, 10),
        );

        let mut left_placement = horizontal;
        left_placement.viewport_col = -1;
        let left =
            translate_terminal_placement(&horizontal_image, &left_placement, horizontal_pane);
        assert_eq!((left.x_offset, left.y_offset), (0, 0));
        assert_pixel_geometry(
            &left,
            horizontal_pane,
            GraphicSourceRect { x: 6, y: 0, width: 10, height: 10 },
            (Some(1), None),
            (10, 10),
        );

        let vertical_pane = Rect { x: 10, y: 5, width: 2, height: 1 };
        let (vertical_image, vertical) = decoded_terminal_placement(20, 10, ",Y=15,c=2");
        let bottom = translate_terminal_placement(&vertical_image, &vertical, vertical_pane);
        assert_eq!((bottom.x_offset, bottom.y_offset), (0, 15));
        assert_pixel_geometry(
            &bottom,
            vertical_pane,
            GraphicSourceRect { x: 0, y: 0, width: 20, height: 5 },
            (Some(2), None),
            (20, 5),
        );

        let mut top_placement = vertical;
        top_placement.viewport_row = -1;
        let top = translate_terminal_placement(&vertical_image, &top_placement, vertical_pane);
        assert_eq!((top.x_offset, top.y_offset), (0, 0));
        assert_pixel_geometry(
            &top,
            vertical_pane,
            GraphicSourceRect { x: 0, y: 5, width: 20, height: 5 },
            (Some(2), None),
            (20, 5),
        );
    }

    #[test]
    fn row_only_clipping_preserves_inferred_columns_on_every_edge() {
        let horizontal_pane = Rect { x: 10, y: 5, width: 1, height: 2 };
        let (horizontal_image, horizontal) = decoded_terminal_placement(10, 40, ",X=5,r=2");

        let right = translate_terminal_placement(&horizontal_image, &horizontal, horizontal_pane);
        assert_eq!((right.x_offset, right.y_offset), (5, 0));
        assert_pixel_geometry(
            &right,
            horizontal_pane,
            GraphicSourceRect { x: 0, y: 0, width: 5, height: 40 },
            (None, Some(2)),
            (5, 40),
        );

        let mut left_placement = horizontal;
        left_placement.viewport_col = -1;
        let left =
            translate_terminal_placement(&horizontal_image, &left_placement, horizontal_pane);
        assert_eq!((left.x_offset, left.y_offset), (0, 0));
        assert_pixel_geometry(
            &left,
            horizontal_pane,
            GraphicSourceRect { x: 5, y: 0, width: 5, height: 40 },
            (None, Some(2)),
            (5, 40),
        );

        let vertical_pane = Rect { x: 10, y: 5, width: 1, height: 2 };
        let (vertical_image, vertical) = decoded_terminal_placement(10, 40, ",Y=5,r=2");
        let bottom = translate_terminal_placement(&vertical_image, &vertical, vertical_pane);
        assert_eq!((bottom.x_offset, bottom.y_offset), (0, 5));
        assert_pixel_geometry(
            &bottom,
            vertical_pane,
            GraphicSourceRect { x: 0, y: 0, width: 10, height: 20 },
            (None, Some(1)),
            (10, 20),
        );

        let mut top_placement = vertical;
        top_placement.viewport_row = -1;
        let top = translate_terminal_placement(&vertical_image, &top_placement, vertical_pane);
        assert_eq!((top.x_offset, top.y_offset), (0, 0));
        assert_pixel_geometry(
            &top,
            vertical_pane,
            GraphicSourceRect { x: 0, y: 15, width: 10, height: 20 },
            (None, Some(1)),
            (10, 20),
        );
    }

    #[test]
    fn browser_png_and_terminal_raw_images_share_one_scene() {
        let browser = GraphicPlacement::browser(
            0,
            1,
            Rect { x: 0, y: 0, width: 10, height: 5 },
            4,
            100,
            50,
            "AAAA".to_string(),
        );
        let terminal = placement(
            image(2, 3, 5, GraphicFormat::Rgba, &[255; 16]),
            0,
            0,
            Rect { x: 10, y: 0, width: 2, height: 2 },
        );
        let mut state = GraphicsState::default();
        let output = joined(&state.frame_batches(&[browser, terminal]));
        assert!(output.contains("f=100"));
        assert!(output.contains("f=32"));
        assert_eq!(state.image_ids.len(), 2);
    }
}
