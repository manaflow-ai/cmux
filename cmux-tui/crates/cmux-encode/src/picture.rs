//! BGRX -> I420 (BT.601, video range), one pass per 2-row band, optionally split across threads.

/// A planar 4:2:0 picture (BT.601, video range), even width and height.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct I420 {
    pub width: usize,
    pub y: Vec<u8>,
    pub u: Vec<u8>,
    pub v: Vec<u8>,
}

impl I420 {
    pub fn new(width: usize, height: usize) -> Self {
        Self {
            width,
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

/// The converter threads for this machine: [`threads_for_cores`] of the cores this process
/// may run on (its affinity and cgroup quota), read once.
pub fn convert_threads() -> usize {
    static THREADS: std::sync::OnceLock<usize> = std::sync::OnceLock::new();
    *THREADS.get_or_init(|| {
        threads_for_cores(std::thread::available_parallelism().map_or(1, |n| n.get()))
    })
}

/// One thread up to two cores, where a second thread only competes with the encoder and
/// the session's loop thread (a 2-vCPU VM: 1080p convert p95 14.1 ms on two threads, 5.1
/// on one); half the cores past that, at most four (8 cores: 1.3 ms on one, 0.65 on four).
pub fn threads_for_cores(cores: usize) -> usize {
    if cores <= 2 { 1 } else { (cores / 2).min(4) }
}

/// Converts a BGRX rectangle (rows of `w * 4` bytes, `h` rows) into `dst` at (`x`, `y`).
/// `x`, `y`, `w`, `h` must be even and inside `dst`.
pub fn bgrx_rect_to_i420(
    src: &[u8],
    dst: &mut I420,
    x: usize,
    y: usize,
    w: usize,
    h: usize,
    threads: usize,
) {
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
    let outs =
        b.y0.chunks_exact_mut(2)
            .zip(b.y1.chunks_exact_mut(2))
            .zip(b.u.iter_mut().zip(b.v.iter_mut()));
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
    fn a_two_core_machine_converts_on_one_thread() {
        let threads: Vec<usize> = [1, 2, 3, 4, 8, 16, 64].map(threads_for_cores).to_vec();
        assert_eq!(threads, [1, 1, 1, 2, 4, 4, 4]);
    }

    #[test]
    fn every_thread_count_converts_the_same_picture() {
        let (w, h) = (640, 480);
        let src: Vec<u8> = (0..w * h * 4).map(|i| (i * 37 % 251) as u8).collect();
        let mut one = I420::new(w, h);
        bgrx_rect_to_i420(&src, &mut one, 0, 0, w, h, 1);
        for threads in [2, 3, 4] {
            let mut many = I420::new(w, h);
            bgrx_rect_to_i420(&src, &mut many, 0, 0, w, h, threads);
            assert_eq!(many, one, "{threads} threads");
        }
    }
}
