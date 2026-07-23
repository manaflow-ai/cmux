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
        || placement.grid_cols == 0
        || placement.grid_rows == 0
    {
        return None;
    }

    let origin_col = i64::from(placement.viewport_col);
    let origin_row = i64::from(placement.viewport_row);
    let grid_cols = i64::from(placement.grid_cols);
    let grid_rows = i64::from(placement.grid_rows);
    let pane_cols = i64::from(pane.width);
    let pane_rows = i64::from(pane.height);
    let clip_left = (-origin_col).max(0).min(grid_cols);
    let clip_top = (-origin_row).max(0).min(grid_rows);
    let mut clip_right = (origin_col + grid_cols - pane_cols).max(0).min(grid_cols - clip_left);
    let mut clip_bottom = (origin_row + grid_rows - pane_rows).max(0).min(grid_rows - clip_top);
    let x_offset = if clip_left == 0 { placement.x_offset } else { 0 };
    let y_offset = if clip_top == 0 { placement.y_offset } else { 0 };

    // Kitty applies X/Y after sizing the c/r cell rectangle. At a right or
    // bottom pane edge that sub-cell offset would bleed into a border or
    // sibling. The protocol cannot crop a destination by partial cells, so
    // conservatively crop enough whole trailing cells to contain the offset.
    let initial_cols = grid_cols - clip_left - clip_right;
    let initial_rows = grid_rows - clip_top - clip_bottom;
    let right_slack = (pane_cols - (origin_col.max(0) + initial_cols)).max(0);
    let bottom_slack = (pane_rows - (origin_row.max(0) + initial_rows)).max(0);
    let cell_width = i64::from(cell_pixels.0.max(1));
    let cell_height = i64::from(cell_pixels.1.max(1));
    let x_overflow = (i64::from(x_offset) - right_slack * cell_width).max(0);
    let y_overflow = (i64::from(y_offset) - bottom_slack * cell_height).max(0);
    clip_right += div_ceil(x_overflow, cell_width).min(initial_cols);
    clip_bottom += div_ceil(y_overflow, cell_height).min(initial_rows);
    let visible_cols = grid_cols - clip_left - clip_right;
    let visible_rows = grid_rows - clip_top - clip_bottom;
    if visible_cols <= 0 || visible_rows <= 0 {
        return None;
    }

    let source_left = proportional_pixels(placement.source_width, clip_left, grid_cols)
        .min(placement.source_width);
    let source_right = proportional_pixels(placement.source_width, clip_right, grid_cols)
        .min(placement.source_width.saturating_sub(source_left));
    let source_top = proportional_pixels(placement.source_height, clip_top, grid_rows)
        .min(placement.source_height);
    let source_bottom = proportional_pixels(placement.source_height, clip_bottom, grid_rows)
        .min(placement.source_height.saturating_sub(source_top));
    let source = GraphicSourceRect {
        x: placement.source_x.saturating_add(source_left),
        y: placement.source_y.saturating_add(source_top),
        width: placement.source_width.saturating_sub(source_left).saturating_sub(source_right),
        height: placement.source_height.saturating_sub(source_top).saturating_sub(source_bottom),
    };
    if source.width == 0 || source.height == 0 {
        return None;
    }
    let clipped = clip_left > 0 || clip_top > 0 || clip_right > 0 || clip_bottom > 0;
    let columns = if clipped {
        Some(u32::try_from(visible_cols).ok()?)
    } else {
        (placement.columns > 0).then_some(placement.columns)
    };
    let rows = if clipped {
        Some(u32::try_from(visible_rows).ok()?)
    } else {
        (placement.rows > 0).then_some(placement.rows)
    };

    Some(GraphicPlacement {
        key: GraphicPlacementKey {
            image: image.key,
            placement_id: placement.placement_id,
            ordinal: placement.key.ordinal,
        },
        image,
        rect: Rect {
            x: pane.x.saturating_add(u16::try_from(origin_col.max(0)).ok()?),
            y: pane.y.saturating_add(u16::try_from(origin_row.max(0)).ok()?),
            width: u16::try_from(visible_cols).ok()?,
            height: u16::try_from(visible_rows).ok()?,
        },
        columns,
        rows,
        source: Some(source),
        x_offset,
        y_offset,
        z: placement.z,
    })
}

fn div_ceil(value: i64, divisor: i64) -> i64 {
    if value <= 0 { 0 } else { 1 + (value - 1) / divisor.max(1) }
}

fn proportional_pixels(total: u32, clipped: i64, cells: i64) -> u32 {
    if cells <= 0 || clipped <= 0 {
        return 0;
    }
    u32::try_from(
        u64::from(total).saturating_mul(u64::try_from(clipped).unwrap_or(u64::MAX))
            / u64::try_from(cells).unwrap_or(1),
    )
    .unwrap_or(total)
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

pub struct GraphicsState {
    next_image_id: u32,
    next_placement_id: u32,
    image_ids: HashMap<GraphicImageKey, u32>,
    placement_ids: HashMap<GraphicPlacementKey, u32>,
    placement_fingerprints: HashMap<GraphicPlacementKey, PlacementFingerprint>,
    transmitted: HashMap<GraphicImageKey, u64>,
    visible: HashSet<GraphicPlacementKey>,
}

impl Default for GraphicsState {
    fn default() -> Self {
        Self {
            next_image_id: 1,
            next_placement_id: 1,
            image_ids: HashMap::new(),
            placement_ids: HashMap::new(),
            placement_fingerprints: HashMap::new(),
            transmitted: HashMap::new(),
            visible: HashSet::new(),
        }
    }
}

impl GraphicsState {
    pub fn frame_batches(&mut self, placements: &[GraphicPlacement]) -> Vec<Vec<u8>> {
        let mut placements = placements
            .iter()
            .filter(|placement| placement.rect.width > 0 && placement.rect.height > 0)
            .collect::<Vec<_>>();
        placements.sort_by_key(|placement| {
            (placement.z, placement.rect.y, placement.rect.x, placement.key)
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
            self.placement_ids.remove(&key);
            self.placement_fingerprints.remove(&key);
        }

        let mut stale_images = self
            .transmitted
            .keys()
            .filter(|key| !now_images.contains(key))
            .copied()
            .collect::<Vec<_>>();
        stale_images.sort_unstable();
        for key in stale_images {
            if let Some(image_id) = self.image_ids.remove(&key) {
                batches.push(delete_image(image_id));
            }
            self.transmitted.remove(&key);
            self.placement_ids.retain(|placement, _| placement.image != key);
            self.placement_fingerprints.retain(|placement, _| placement.image != key);
        }

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

    fn image_id(&mut self, key: GraphicImageKey) -> u32 {
        if let Some(id) = self.image_ids.get(&key) {
            return *id;
        }
        let id = allocate_id(&mut self.next_image_id, self.image_ids.values().copied());
        self.image_ids.insert(key, id);
        id
    }

    fn placement_id(&mut self, key: GraphicPlacementKey) -> u32 {
        if let Some(id) = self.placement_ids.get(&key) {
            return *id;
        }
        let id = allocate_id(&mut self.next_placement_id, self.placement_ids.values().copied());
        self.placement_ids.insert(key, id);
        id
    }
}

fn allocate_id(next: &mut u32, used: impl Iterator<Item = u32>) -> u32 {
    let used = used.collect::<HashSet<_>>();
    loop {
        let candidate = (*next).max(1);
        *next = candidate.wrapping_add(1).max(1);
        if !used.contains(&candidate) {
            return candidate;
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
    let ok = find_bytes(&bytes, b"_Gi=31;OK");
    let da = find_da1(&bytes);
    match (ok, da) {
        (Some(ok), Some(da)) => ok < da,
        (Some(_), None) => true,
        _ => false,
    }
}

pub fn detect_cell_pixels(query_fallback: bool) -> (u16, u16) {
    if let Some(cell) = ioctl_cell_pixels() {
        return cell;
    }
    if query_fallback && let Some(cell) = query_cell_pixels() {
        return cell;
    }
    (8, 16)
}

#[cfg(unix)]
fn ioctl_cell_pixels() -> Option<(u16, u16)> {
    let mut ws: libc::winsize = unsafe { std::mem::zeroed() };
    let ok = unsafe { libc::ioctl(libc::STDOUT_FILENO, libc::TIOCGWINSZ, &mut ws) } == 0;
    if !ok || ws.ws_col == 0 || ws.ws_row == 0 || ws.ws_xpixel == 0 || ws.ws_ypixel == 0 {
        return None;
    }
    let w = (ws.ws_xpixel / ws.ws_col).max(1);
    let h = (ws.ws_ypixel / ws.ws_row).max(1);
    Some((w, h))
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
        if find_da1(&out).is_some() {
            break;
        }
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

fn find_da1(bytes: &[u8]) -> Option<usize> {
    bytes.iter().enumerate().find_map(|(idx, byte)| {
        if *byte == b'c' && bytes[..idx].iter().rev().take(16).any(|byte| *byte == b'[') {
            Some(idx)
        } else {
            None
        }
    })
}

#[cfg(test)]
mod tests {
    use base64::Engine as _;
    use ghostty_vt::{Callbacks, KittyPlacement, KittyPlacementKey, Terminal};

    use super::*;

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

    fn translated_terminal_placement(
        width: u32,
        height: u32,
        sizing: &str,
        pane: Rect,
    ) -> GraphicPlacement {
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
        kitty_graphic_placement(
            pane,
            (10, 20),
            kitty_graphic_image(0, 9, snapshot.image(201).unwrap()),
            &snapshot.placements[0],
        )
        .unwrap()
    }

    fn emitted_placement(value: GraphicPlacement) -> String {
        let mut state = GraphicsState::default();
        let output = joined(&state.frame_batches(&[value]));
        let start = output.find("\x1b_Ga=p").expect("placement command");
        let command = &output[start..];
        let end = command.find("\x1b\\").expect("placement terminator") + 2;
        command[..end].to_string()
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
            x_offset: 4,
            y_offset: 5,
            source_x: 10,
            source_y: 20,
            source_width: 80,
            source_height: 40,
            columns: 8,
            rows: 4,
            grid_cols: 8,
            grid_rows: 4,
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
        assert_eq!(outer.source, Some(GraphicSourceRect { x: 30, y: 30, width: 50, height: 20 }));
        assert_eq!((outer.x_offset, outer.y_offset), (0, 0));
        assert_eq!(outer.z, 3);
    }

    #[test]
    fn terminal_offsets_at_right_and_bottom_edges_are_coarsely_cropped_inside_pane() {
        let inner_image = KittyImage {
            id: 4,
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
        assert_eq!(outer.rect, Rect { x: 13, y: 7, width: 1, height: 1 });
        assert_eq!(outer.source, Some(GraphicSourceRect { x: 0, y: 0, width: 50, height: 50 }));
        assert_eq!((outer.x_offset, outer.y_offset), (4, 5));
        assert!(
            u32::from(outer.rect.x - pane.x + outer.rect.width) * 10 + outer.x_offset
                <= u32::from(pane.width) * 10
        );
        assert!(
            u32::from(outer.rect.y - pane.y + outer.rect.height) * 20 + outer.y_offset
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
        assert_eq!(outer.rect, Rect { x: 0, y: 0, width: 1, height: 1 });
        assert_eq!(outer.source, Some(GraphicSourceRect { x: 0, y: 0, width: 10, height: 20 }));
        assert_eq!((outer.x_offset, outer.y_offset), (4, 5));

        let command = emitted_placement(outer);
        assert!(command.contains("x=0,y=0,w=10,h=20,X=4,Y=5,c=1,r=1"), "{command:?}");
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
