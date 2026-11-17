//! Image downscaling that averages light, not sRGB code values.
//!
//! An 8-bit sRGB value is gamma-encoded: 128 is about 22% of the light of 255,
//! not half. Averaging the encoded values (what a plain box or triangle filter
//! over `u8` pixels does) darkens every fine detail: a 1 px black and white
//! checkerboard scaled down becomes 128, a visibly darker grey than the 188
//! the eye sees from a distance (linear 0.5). Text and thin lines in a
//! screenshot get darker and heavier the same way. So every downscale in cmux
//! goes through here: each pixel to 16-bit linear light by a 256-entry table,
//! averaged by area (colour weighted by alpha), and back to sRGB by a
//! 64 KiB table, nearest code. Both tables are built once; the cost per pixel
//! is constant and the memory is two output rows of sums, whatever the image.

use std::sync::OnceLock;

/// Linear light of each 8-bit sRGB value, 0..=65535.
fn to_linear_table() -> &'static [u16; 256] {
    static TABLE: OnceLock<[u16; 256]> = OnceLock::new();
    TABLE.get_or_init(|| {
        let mut table = [0u16; 256];
        for (code, linear) in table.iter_mut().enumerate() {
            *linear = (decode(code as f64 / 255.0) * 65535.0).round() as u16;
        }
        table
    })
}

/// The nearest 8-bit sRGB code of each 16-bit linear value.
fn to_srgb_table() -> &'static [u8] {
    static TABLE: OnceLock<Box<[u8]>> = OnceLock::new();
    TABLE.get_or_init(|| {
        let mut table = vec![255u8; 65536].into_boxed_slice();
        // Code `k` holds every linear value below the light of code k + 0.5.
        let mut start = 0usize;
        for code in 0..255u8 {
            let end = (decode((f64::from(code) + 0.5) / 255.0) * 65535.0).ceil() as usize;
            let end = end.clamp(start, table.len());
            if let Some(run) = table.get_mut(start..end) {
                run.fill(code);
            }
            start = end;
        }
        table
    })
}

/// The sRGB transfer function: encoded 0..=1 to linear 0..=1.
fn decode(v: f64) -> f64 {
    if v <= 0.04045 { v / 12.92 } else { ((v + 0.055) / 1.055).powf(2.4) }
}

/// The 16-bit linear light of 8-bit sRGB `code`.
pub fn to_linear(code: u8) -> u16 {
    // A u8 always indexes the 256 entries.
    to_linear_table().get(usize::from(code)).copied().unwrap_or(0)
}

/// The 8-bit sRGB code nearest 16-bit linear light `linear`.
pub fn to_srgb(linear: u16) -> u8 {
    // A u16 always indexes the 65536 entries.
    to_srgb_table().get(usize::from(linear)).copied().unwrap_or(255)
}

/// Where one input pixel falls among the output pixels: `first` takes `w0` of it and
/// `first + 1` takes `w1` (0 when it lies inside `first`). Weights are in units of
/// 1 / (input extent * output extent) of an output pixel, so every output pixel's
/// weights sum to the input extent exactly.
#[derive(Clone, Copy, Debug)]
struct Span {
    first: usize,
    w0: u64,
    w1: u64,
}

fn span(i: u64, input: u64, output: u64) -> Span {
    let (start, end) = (i * output, (i + 1) * output);
    let first = start / input;
    let boundary = (first + 1) * input;
    if end <= boundary {
        Span { first: first as usize, w0: output, w1: 0 }
    } else {
        Span { first: first as usize, w0: boundary - start, w1: end - boundary }
    }
}

/// A downscale by exact area averaging in linear light, fed one input row at a time.
///
/// Input pixels are straight-alpha RGBA with sRGB colour. Colour is averaged
/// premultiplied (weighted by alpha), so a transparent pixel's colour, which
/// nobody sees, does not tint the opaque ones next to it. The output is RGB, or
/// RGBA when `alpha`, 8-bit sRGB, row by row.
pub struct Downscaler {
    in_w: u64,
    in_h: u64,
    out_h: u64,
    alpha: bool,
    columns: Vec<Span>,
    /// One input row's sums per output column, premultiplied linear R, G, B and alpha.
    across: Vec<[u64; 4]>,
    /// The sums of the output row being filled and of the one after it: premultiplied
    /// linear R, G, B and the alpha weight.
    current: Vec<[u64; 4]>,
    next: Vec<[u64; 4]>,
    /// The next input row, and the output row `current` fills.
    row: u64,
    out_row: u64,
    out: Vec<u8>,
}

impl Downscaler {
    /// A downscale of an `in_w`x`in_h` image to `out_w`x`out_h`. The output is
    /// clamped to the input (never scaled up) and to at least 1x1.
    pub fn new(in_w: u32, in_h: u32, out_w: u32, out_h: u32, alpha: bool) -> Self {
        let (in_w, in_h) = (u64::from(in_w.max(1)), u64::from(in_h.max(1)));
        let out_w = u64::from(out_w).clamp(1, in_w);
        let out_h = u64::from(out_h).clamp(1, in_h);
        let columns = (0..in_w).map(|x| span(x, in_w, out_w)).collect();
        let channels = if alpha { 4 } else { 3 };
        Self {
            in_w,
            in_h,
            out_h,
            alpha,
            columns,
            across: vec![[0; 4]; out_w as usize],
            current: vec![[0; 4]; out_w as usize],
            next: vec![[0; 4]; out_w as usize],
            row: 0,
            out_row: 0,
            out: Vec::with_capacity((out_w * out_h) as usize * channels),
        }
    }

    /// The output width and height.
    pub fn output_size(&self) -> (u32, u32) {
        (self.current.len() as u32, self.out_h as u32)
    }

    /// Adds the next input row, `in_w` RGBA pixels (more are ignored, fewer leave the
    /// rest of the row transparent). Rows past `in_h` are ignored.
    pub fn push_row(&mut self, pixels: impl IntoIterator<Item = [u8; 4]>) {
        if self.row >= self.in_h {
            return;
        }
        // Across first: the row's pixels into its output columns, then that row of sums
        // down into the output rows it covers.
        let table = to_linear_table();
        // A u8 always indexes the 256 entries.
        let lin = |code: u8| u64::from(table.get(usize::from(code)).copied().unwrap_or(0));
        let across = &mut self.across;
        for (column, [r, g, b, a]) in self.columns.iter().zip(pixels) {
            if a == 0 {
                continue;
            }
            let a = u64::from(a);
            let px = [lin(r) * a, lin(g) * a, lin(b) * a, a];
            if let Some(sum) = across.get_mut(column.first) {
                for (s, v) in sum.iter_mut().zip(px) {
                    *s += v * column.w0;
                }
            }
            if column.w1 > 0
                && let Some(sum) = across.get_mut(column.first + 1)
            {
                for (s, v) in sum.iter_mut().zip(px) {
                    *s += v * column.w1;
                }
            }
        }
        let rows = span(self.row, self.in_h, self.out_h);
        for ((sum, current), next) in
            across.iter_mut().zip(self.current.iter_mut()).zip(self.next.iter_mut())
        {
            for ((s, c), n) in sum.iter().zip(current.iter_mut()).zip(next.iter_mut()) {
                *c += s * rows.w0;
                *n += s * rows.w1;
            }
            *sum = [0; 4];
        }
        self.row += 1;
        // The output row is whole once an input row reaches its bottom edge.
        if self.row * self.out_h >= (self.out_row + 1) * self.in_h {
            self.emit();
        }
    }

    /// Writes `current` as the next output row and moves on to `next`.
    fn emit(&mut self) {
        if self.out_row >= self.out_h {
            return;
        }
        let total = self.in_w * self.in_h;
        for sum in &self.current {
            let weight = sum[3];
            for channel in &sum[..3] {
                let linear = (channel + weight / 2).checked_div(weight).unwrap_or(0);
                self.out.push(to_srgb(linear.min(65535) as u16));
            }
            if self.alpha {
                self.out.push((weight / total).min(255) as u8);
            }
        }
        std::mem::swap(&mut self.current, &mut self.next);
        self.next.iter_mut().for_each(|sum| *sum = [0; 4]);
        self.out_row += 1;
    }

    /// The output pixels; rows never pushed come out transparent black.
    pub fn finish(mut self) -> Vec<u8> {
        while self.out_row < self.out_h {
            self.emit();
        }
        self.out
    }
}

/// `pixels`, `channels` (3 RGB or 4 RGBA) 8-bit sRGB bytes of a `w`x`h` image, scaled
/// down to `out_w`x`out_h` in linear light: RGB out of RGB, RGBA out of RGBA.
pub fn downscale(
    pixels: &[u8],
    channels: usize,
    w: u32,
    h: u32,
    out_w: u32,
    out_h: u32,
) -> Vec<u8> {
    let alpha = channels == 4;
    let mut scaler = Downscaler::new(w, h, out_w, out_h, alpha);
    let stride = w as usize * channels;
    if stride == 0 {
        return scaler.finish();
    }
    for row in pixels.chunks_exact(stride).take(h as usize) {
        scaler.push_row(row.chunks_exact(channels).map(|px| match px {
            [r, g, b] => [*r, *g, *b, 255],
            [r, g, b, a] => [*r, *g, *b, *a],
            [g] => [*g, *g, *g, 255],
            [g, a] => [*g, *g, *g, *a],
            _ => [0, 0, 0, 0],
        }));
    }
    scaler.finish()
}

/// The size of a `w`x`h` image scaled to fit `max_edge` on its long side, never up.
pub fn fit(w: u32, h: u32, max_edge: u32) -> (u32, u32) {
    let scale = (f64::from(max_edge) / f64::from(w.max(h).max(1))).min(1.0);
    let side = |v: u32| ((f64::from(v) * scale).round() as u32).max(1);
    (side(w), side(h))
}

#[cfg(test)]
mod tests;
