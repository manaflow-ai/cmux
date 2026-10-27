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

/// The rectangle given to [`bgrx_rect_to_i420`] does not fit in the picture.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RectOutsidePicture {
    pub x: usize,
    pub y: usize,
    pub w: usize,
    pub h: usize,
    pub width: usize,
}

impl std::fmt::Display for RectOutsidePicture {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let Self { x, y, w, h, width } = self;
        write!(f, "rect {w}x{h} at ({x}, {y}) is outside the {width}-pixel-wide picture")
    }
}

impl std::error::Error for RectOutsidePicture {}

struct Band<'a> {
    /// The band's two source rows, `w` BGRX pixels each.
    src0: &'a [u8],
    src1: &'a [u8],
    y0: &'a mut [u8],
    y1: &'a mut [u8],
    u: &'a mut [u8],
    v: &'a mut [u8],
}

/// Converts a BGRX rectangle (rows of `w * 4` bytes, `h` rows) into `dst` at (`x`, `y`).
/// `x`, `y`, `w`, `h` must be even; a rectangle that does not fit in `dst` is an error and
/// leaves `dst` unchanged. A short `src` converts only its whole 2-row bands.
pub fn bgrx_rect_to_i420(
    src: &[u8],
    dst: &mut I420,
    x: usize,
    y: usize,
    w: usize,
    h: usize,
    threads: usize,
) -> Result<(), RectOutsidePicture> {
    let (dw, cw) = (dst.width, dst.width / 2);
    let outside = RectOutsidePicture { x, y, w, h, width: dw };
    if x + w > dw {
        return Err(outside);
    }
    if w == 0 || h == 0 {
        return Ok(());
    }
    let y_plane = dst.y.get_mut(y * dw..(y + h) * dw).ok_or(outside)?;
    let u_plane = dst.u.get_mut((y / 2) * cw..((y + h) / 2) * cw).ok_or(outside)?;
    let v_plane = dst.v.get_mut((y / 2) * cw..((y + h) / 2) * cw).ok_or(outside)?;
    let mut src_rows = src.chunks_exact(w * 4);
    let src_bands = std::iter::from_fn(|| Some((src_rows.next()?, src_rows.next()?)));
    let mut bands: Vec<Band> = src_bands
        .zip(y_plane.chunks_exact_mut(2 * dw))
        .zip(u_plane.chunks_exact_mut(cw).zip(v_plane.chunks_exact_mut(cw)))
        .map(|(((src0, src1), yy), (u, v))| {
            let (y0, y1) = yy.split_at_mut(dw);
            Some(Band {
                src0,
                src1,
                y0: y0.get_mut(x..x + w)?,
                y1: y1.get_mut(x..x + w)?,
                u: u.get_mut(x / 2..(x + w) / 2)?,
                v: v.get_mut(x / 2..(x + w) / 2)?,
            })
        })
        .collect::<Option<_>>()
        .ok_or(outside)?;
    // Small rects (the marker) are cheaper on one thread than the spawn cost.
    if threads <= 1 || w * h < 256 * 1024 {
        bands.iter_mut().for_each(convert_band);
        return Ok(());
    }
    // `chunks_mut` needs a nonzero size, and a `src` shorter than one band leaves no bands.
    let per = bands.len().div_ceil(threads).max(1);
    std::thread::scope(|s| {
        for chunk in bands.chunks_mut(per) {
            s.spawn(move || chunk.iter_mut().for_each(convert_band));
        }
    });
    Ok(())
}

#[inline(always)]
fn luma(r: i32, g: i32, b: i32) -> u8 {
    (((66 * r + 129 * g + 25 * b + 128) >> 8) + 16) as u8
}

fn convert_band(b: &mut Band) {
    let pairs = b.src0.as_chunks::<8>().0.iter().zip(b.src1.as_chunks::<8>().0);
    let outs = b.y0.as_chunks_mut::<2>().0.iter_mut().zip(b.y1.as_chunks_mut::<2>().0.iter_mut());
    let outs = outs.zip(b.u.iter_mut().zip(b.v.iter_mut()));
    for ((p0, p1), ((ya, yb), (u, v))) in pairs.zip(outs) {
        // Two BGRX pixels per row: blue, green, red, unused.
        let [b00, g00, r00, _, b01, g01, r01, _] = p0.map(i32::from);
        let [b10, g10, r10, _, b11, g11, r11, _] = p1.map(i32::from);
        *ya = [luma(r00, g00, b00), luma(r01, g01, b01)];
        *yb = [luma(r10, g10, b10), luma(r11, g11, b11)];
        let r = (r00 + r01 + r10 + r11 + 2) >> 2;
        let g = (g00 + g01 + g10 + g11 + 2) >> 2;
        let bl = (b00 + b01 + b10 + b11 + 2) >> 2;
        *u = (((-38 * r - 74 * g + 112 * bl + 128) >> 8) + 128) as u8;
        *v = (((112 * r - 94 * g - 18 * bl + 128) >> 8) + 128) as u8;
    }
}
