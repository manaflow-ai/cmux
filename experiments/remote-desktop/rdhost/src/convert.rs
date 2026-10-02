//! BGRX -> I420 (BT.601, video range), one pass per 2-row band, optionally split across threads.

pub struct I420 {
    pub width: usize,
    pub height: usize,
    pub y: Vec<u8>,
    pub u: Vec<u8>,
    pub v: Vec<u8>,
}

impl I420 {
    pub fn new(width: usize, height: usize) -> Self {
        Self {
            width,
            height,
            y: vec![16; width * height],
            u: vec![128; width * height / 4],
            v: vec![128; width * height / 4],
        }
    }
}

struct Band<'a> {
    src: &'a [u8],
    y0: &'a mut [u8],
    y1: &'a mut [u8],
    u: &'a mut [u8],
    v: &'a mut [u8],
}

/// Converts a BGRX rectangle (rows of `w * 4` bytes, `h` rows) into `dst` at (`x`, `y`).
/// `x`, `y`, `w`, `h` must be even and inside `dst`.
pub fn bgrx_rect_to_i420(src: &[u8], dst: &mut I420, x: usize, y: usize, w: usize, h: usize, threads: usize) {
    let (dw, cw) = (dst.width, dst.width / 2);
    let y_rows = dst.y[y * dw..(y + h) * dw].chunks_exact_mut(2 * dw);
    let u_rows = dst.u[(y / 2) * cw..((y + h) / 2) * cw].chunks_exact_mut(cw);
    let v_rows = dst.v[(y / 2) * cw..((y + h) / 2) * cw].chunks_exact_mut(cw);
    let mut bands: Vec<Band> = src
        .chunks_exact(2 * w * 4)
        .zip(y_rows)
        .zip(u_rows.zip(v_rows))
        .map(|((s, yy), (u, v))| {
            let (y0, y1) = yy.split_at_mut(dw);
            Band {
                src: s,
                y0: &mut y0[x..x + w],
                y1: &mut y1[x..x + w],
                u: &mut u[x / 2..(x + w) / 2],
                v: &mut v[x / 2..(x + w) / 2],
            }
        })
        .collect();
    // Small rects (the marker) are cheaper on one thread than the spawn cost.
    if threads <= 1 || w * h < 256 * 1024 {
        bands.iter_mut().for_each(|b| convert_band(b, w));
        return;
    }
    let per = bands.len().div_ceil(threads);
    std::thread::scope(|s| {
        for chunk in bands.chunks_mut(per) {
            s.spawn(move || chunk.iter_mut().for_each(|b| convert_band(b, w)));
        }
    });
}

#[inline(always)]
fn luma(r: i32, g: i32, b: i32) -> u8 {
    (((66 * r + 129 * g + 25 * b + 128) >> 8) + 16) as u8
}

fn convert_band(b: &mut Band, w: usize) {
    let (s0, s1) = b.src.split_at(w * 4);
    let pairs = s0.chunks_exact(8).zip(s1.chunks_exact(8));
    let outs = b.y0.chunks_exact_mut(2).zip(b.y1.chunks_exact_mut(2)).zip(b.u.iter_mut().zip(b.v.iter_mut()));
    for ((p0, p1), ((ya, yb), (u, v))) in pairs.zip(outs) {
        let px = |p: &[u8], o: usize| (i32::from(p[o + 2]), i32::from(p[o + 1]), i32::from(p[o]));
        let (r00, g00, b00) = px(p0, 0);
        let (r01, g01, b01) = px(p0, 4);
        let (r10, g10, b10) = px(p1, 0);
        let (r11, g11, b11) = px(p1, 4);
        ya[0] = luma(r00, g00, b00);
        ya[1] = luma(r01, g01, b01);
        yb[0] = luma(r10, g10, b10);
        yb[1] = luma(r11, g11, b11);
        let r = (r00 + r01 + r10 + r11 + 2) >> 2;
        let g = (g00 + g01 + g10 + g11 + 2) >> 2;
        let bl = (b00 + b01 + b10 + b11 + 2) >> 2;
        *u = (((-38 * r - 74 * g + 112 * bl + 128) >> 8) + 128) as u8;
        *v = (((112 * r - 94 * g - 18 * bl + 128) >> 8) + 128) as u8;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn white_black_gray() {
        let (w, h) = (4usize, 2usize);
        let mut src = vec![0u8; w * h * 4];
        src[..8].fill(255); // two white pixels top-left
        let mut dst = I420::new(8, 4);
        bgrx_rect_to_i420(&src, &mut dst, 2, 2, w, h, 1);
        assert_eq!(dst.y[2 * 8 + 2], 235);
        assert_eq!(dst.y[2 * 8 + 4], 16);
        assert_eq!(dst.y[0], 16); // untouched
        assert_eq!(dst.u[4 + 1], 128);
    }
}
