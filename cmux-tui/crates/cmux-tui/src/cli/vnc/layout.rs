//! Where the remote screen sits in the pane, and the pixel math both ways.

use cmux_vnc::{VncError, framebuffer::MAX_SIDE};

/// The pane in cells and pixels. The last row is the status line.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct Pane {
    pub cols: u16,
    pub rows: u16,
    pub cell_w: u32,
    pub cell_h: u32,
}

/// Cell size when the terminal does not report its pixel size.
const FALLBACK_CELL: (u32, u32) = (8, 16);

impl Pane {
    /// From the terminal's size report; a zero pixel size falls back to 8x16 cells.
    pub fn new(cols: u16, rows: u16, width_px: u16, height_px: u16) -> Self {
        let cols = cols.max(1);
        let rows = rows.max(2);
        let (cell_w, cell_h) = if width_px == 0 || height_px == 0 {
            FALLBACK_CELL
        } else {
            (
                (u32::from(width_px) / u32::from(cols)).max(1),
                (u32::from(height_px) / u32::from(rows)).max(1),
            )
        };
        Self { cols, rows, cell_w, cell_h }
    }

    /// The picture area in pixels: every row but the status line.
    pub fn area(&self) -> (u32, u32) {
        (u32::from(self.cols) * self.cell_w, u32::from(self.rows - 1) * self.cell_h)
    }
}

/// The remote screen fitted into the pane: scaled down to fit (never up),
/// aspect kept, centered.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(super) struct Placement {
    pub remote_w: u32,
    pub remote_h: u32,
    /// The drawn size in pixels.
    pub width: u32,
    pub height: u32,
    /// The drawn picture's top-left corner in pane pixels.
    pub left: u32,
    pub top: u32,
}

impl Placement {
    pub fn fit(pane: &Pane, remote_w: u16, remote_h: u16) -> Self {
        let (area_w, area_h) = pane.area();
        let (remote_w, remote_h) = (u32::from(remote_w).max(1), u32::from(remote_h).max(1));
        let (width, height) = if remote_w <= area_w && remote_h <= area_h {
            (remote_w, remote_h)
        } else if u64::from(remote_w) * u64::from(area_h) > u64::from(remote_h) * u64::from(area_w)
        {
            (
                area_w,
                ((u64::from(remote_h) * u64::from(area_w)) / u64::from(remote_w)).max(1) as u32,
            )
        } else {
            (
                ((u64::from(remote_w) * u64::from(area_h)) / u64::from(remote_h)).max(1) as u32,
                area_h,
            )
        };
        Self {
            remote_w,
            remote_h,
            width,
            height,
            left: area_w.saturating_sub(width) / 2,
            top: area_h.saturating_sub(height) / 2,
        }
    }

    /// The cell (0-based column, row) and pixel offset inside it where the
    /// picture's corner goes (Kitty's `X` and `Y`).
    pub fn anchor(&self, pane: &Pane) -> (u16, u16, u32, u32) {
        (
            (self.left / pane.cell_w) as u16,
            (self.top / pane.cell_h) as u16,
            self.left % pane.cell_w,
            self.top % pane.cell_h,
        )
    }

    /// The remote pixel under pane pixel (`x`, `y`), clamped to the screen.
    pub fn remote_point(&self, x: u32, y: u32) -> (u16, u16) {
        let map = |p: u32, origin: u32, drawn: u32, remote: u32| -> u16 {
            let inside = p.saturating_sub(origin).min(drawn.saturating_sub(1));
            ((u64::from(inside) * u64::from(remote) / u64::from(drawn.max(1))) as u32)
                .min(remote - 1)
                .min(u32::from(u16::MAX)) as u16
        };
        (map(x, self.left, self.width, self.remote_w), map(y, self.top, self.height, self.remote_h))
    }
}

/// Scales an RGBA image to `width` x `height` (not larger than the source)
/// by averaging each destination pixel's source box, which keeps small text
/// readable where nearest-neighbor would drop strokes. Returns RGB.
pub(super) fn scale_rgb(
    src: &[u8],
    src_w: u32,
    src_h: u32,
    width: u32,
    height: u32,
) -> cmux_vnc::Result<Vec<u8>> {
    if src_w == 0
        || src_h == 0
        || src_w > u32::from(MAX_SIDE)
        || src_h > u32::from(MAX_SIDE)
        || width == 0
        || height == 0
        || width > src_w
        || height > src_h
    {
        return Err(VncError::Protocol("scaling dimensions".into()));
    }
    let (src_w, src_h) = (src_w as usize, src_h as usize);
    let (width, height) = (width as usize, height as usize);
    if src.len() != src_w * src_h * 4 {
        return Err(VncError::Protocol("scaling pixel count".into()));
    }
    let mut out = Vec::with_capacity(width * height * 3);
    if width == src_w && height == src_h {
        for pixel in src.chunks_exact(4) {
            out.extend(pixel.iter().take(3).copied());
        }
        return Ok(out);
    }
    let bounds = |i: usize, dst: usize, src: usize| -> (usize, usize) {
        let start = i * src / dst;
        let end = ((i + 1) * src / dst).max(start + 1).min(src);
        (start, end)
    };
    let columns: Vec<(usize, usize)> = (0..width).map(|x| bounds(x, width, src_w)).collect();
    let mut sums = vec![[0u64; 3]; width];
    for y in 0..height {
        let (y0, y1) = bounds(y, height, src_h);
        sums.iter_mut().for_each(|sum| *sum = [0; 3]);
        for row in y0..y1 {
            let line = src
                .get(row * src_w * 4..(row + 1) * src_w * 4)
                .ok_or_else(|| VncError::Protocol("scaling row bounds".into()))?;
            for (sum, &(x0, x1)) in sums.iter_mut().zip(&columns) {
                let pixels = line
                    .get(x0 * 4..x1 * 4)
                    .ok_or_else(|| VncError::Protocol("scaling column bounds".into()))?;
                for pixel in pixels.chunks_exact(4) {
                    for (channel, value) in sum.iter_mut().zip(pixel) {
                        *channel += u64::from(*value);
                    }
                }
            }
        }
        for (sum, &(x0, x1)) in sums.iter().zip(&columns) {
            let count = ((x1 - x0) * (y1 - y0)) as u64;
            out.extend(sum.iter().map(|&channel| (channel / count) as u8));
        }
    }
    Ok(out)
}
